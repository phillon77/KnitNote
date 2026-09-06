import Foundation
import Testing
@testable import KnitNoteCore

@Suite @MainActor struct YouTubePatternThumbnailLoaderTests {
    @Test func metadataGateBuffersPreobservedStartAndCancellation() async {
        let gate = MetadataFetchGate()
        gate.recordStarted()
        gate.recordCancellation()
        #expect(await gate.waitUntilStarted())
        #expect(await gate.waitUntilCancelled())
        gate.release()
    }

    @Test func metadataGateReportsRequestCompletionWithoutExpectedEvents() async {
        let gate = MetadataFetchGate()
        gate.finishStartObservation(started: false)
        gate.finishCancellationObservation(cancelled: false)
        #expect(await gate.waitUntilStarted() == false)
        #expect(await gate.waitUntilCancelled() == false)
        gate.release()
    }

    @Test func metadataGateBuffersReleaseWithoutPolling() async throws {
        let gate = MetadataFetchGate()
        gate.release()
        _ = try await gate.waitForRelease()
    }

    @Test func cancellingTheRowRequestCancelsTheInFlightMetadataFetchAndDoesNotCache() async {
        let gate = MetadataFetchGate()
        let tracker = ThumbnailLoaderTracker()
        let patternID = UUID()
        let assetID = UUID()
        let loader = YouTubePatternThumbnailLoader(
            fetcher: BlockingMetadataFetcher(gate: gate),
            cachedThumbnailURL: { _ in await tracker.cachedThumbnailURL() },
            linkForPattern: { _ in try YouTubePatternLink(videoID: "abcdefghijk") },
            cacheThumbnail: { _, _ in await tracker.recordCache() },
            isCurrentYouTubeAsset: { _, _ in await tracker.isCurrentYouTubeAsset() }
        )

        let request = Task { @MainActor in
            defer {
                gate.finishStartObservation(started: false)
                gate.finishCancellationObservation(cancelled: false)
            }
            return await loader.thumbnailURL(patternID: patternID, assetID: assetID)
        }
        let didStartMetadataFetch = await gate.waitUntilStarted()
        request.cancel()
        gate.release()
        let result = await request.value
        let didCancelMetadataFetch = await gate.waitUntilCancelled()

        #expect(didStartMetadataFetch)
        #expect(didCancelMetadataFetch)
        #expect(result == nil)
        #expect(await tracker.cacheCallCount() == 0)
        #expect(await tracker.cachedURLReadCount() == 1)
    }

    @Test func stalePatternAssetDoesNotCauseACacheRereadOrPublication() async {
        let tracker = ThumbnailLoaderTracker(
            isCurrentYouTubeAsset: false,
            metadata: YouTubePatternPresentationMetadata(
                title: "Fetched title must stay out of the stored pattern",
                thumbnailData: Data([1, 2, 3])
            )
        )
        let loader = YouTubePatternThumbnailLoader(
            fetcher: ImmediateMetadataFetcher(metadata: await tracker.metadata()),
            cachedThumbnailURL: { _ in await tracker.cachedThumbnailURL() },
            linkForPattern: { _ in try YouTubePatternLink(videoID: "abcdefghijk") },
            cacheThumbnail: { _, _ in await tracker.recordCache() },
            isCurrentYouTubeAsset: { _, _ in await tracker.isCurrentYouTubeAsset() }
        )

        let thumbnail = await loader.thumbnailURL(patternID: UUID(), assetID: UUID())

        #expect(thumbnail == nil)
        #expect(await tracker.cacheCallCount() == 1)
        #expect(await tracker.cachedURLReadCount() == 1)
    }
}

@MainActor
private final class BlockingMetadataFetcher: YouTubePatternMetadataFetching {
    private let gate: MetadataFetchGate

    init(gate: MetadataFetchGate) {
        self.gate = gate
    }

    func fetch(for url: URL) async throws -> YouTubePatternPresentationMetadata {
        let gate = gate
        gate.recordStarted()
        return try await withTaskCancellationHandler {
            try await gate.waitForRelease()
        } onCancel: {
            gate.recordCancellation()
        }
    }
}

@MainActor
private struct ImmediateMetadataFetcher: YouTubePatternMetadataFetching {
    let metadata: YouTubePatternPresentationMetadata

    func fetch(for url: URL) async throws -> YouTubePatternPresentationMetadata {
        metadata
    }
}

private final class MetadataFetchGate: @unchecked Sendable {
    private let startEvents: AsyncStream<Bool>
    private let startContinuation: AsyncStream<Bool>.Continuation
    private let cancellationEvents: AsyncStream<Bool>
    private let cancellationContinuation: AsyncStream<Bool>.Continuation
    private let releaseEvents: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var startObservationFinished = false
    private var cancellationObservationFinished = false
    private var releaseFinished = false

    init() {
        let start = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        startEvents = start.stream
        startContinuation = start.continuation
        let cancellation = AsyncStream<Bool>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        cancellationEvents = cancellation.stream
        cancellationContinuation = cancellation.continuation
        let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        releaseEvents = release.stream
        releaseContinuation = release.continuation
    }

    func recordStarted() {
        finishStartObservation(started: true)
    }

    func recordCancellation() {
        finishCancellationObservation(cancelled: true)
    }

    func finishStartObservation(started: Bool) {
        lock.lock()
        guard !startObservationFinished else {
            lock.unlock()
            return
        }
        startObservationFinished = true
        lock.unlock()
        startContinuation.yield(started)
        startContinuation.finish()
    }

    func waitUntilStarted() async -> Bool {
        for await started in startEvents { return started }
        return false
    }

    func finishCancellationObservation(cancelled: Bool) {
        lock.lock()
        guard !cancellationObservationFinished else {
            lock.unlock()
            return
        }
        cancellationObservationFinished = true
        lock.unlock()
        cancellationContinuation.yield(cancelled)
        cancellationContinuation.finish()
    }

    func waitUntilCancelled() async -> Bool {
        for await cancelled in cancellationEvents { return cancelled }
        return false
    }

    func release() {
        lock.lock()
        guard !releaseFinished else {
            lock.unlock()
            return
        }
        releaseFinished = true
        lock.unlock()
        releaseContinuation.yield(())
        releaseContinuation.finish()
    }

    func waitForRelease() async throws -> YouTubePatternPresentationMetadata {
        for await _ in releaseEvents {
            try Task.checkCancellation()
            return YouTubePatternPresentationMetadata(title: nil, thumbnailData: nil)
        }
        throw CancellationError()
    }
}

private actor ThumbnailLoaderTracker {
    private var cachedURLReads = 0
    private var cacheCalls = 0
    private let currentAsset: Bool
    private let providedMetadata: YouTubePatternPresentationMetadata

    init(
        isCurrentYouTubeAsset: Bool = true,
        metadata: YouTubePatternPresentationMetadata = .init(title: nil, thumbnailData: nil)
    ) {
        currentAsset = isCurrentYouTubeAsset
        providedMetadata = metadata
    }

    func cachedThumbnailURL() -> URL? {
        cachedURLReads += 1
        return nil
    }

    func recordCache() {
        cacheCalls += 1
    }

    func isCurrentYouTubeAsset() -> Bool {
        currentAsset
    }

    func cacheCallCount() -> Int {
        cacheCalls
    }

    func cachedURLReadCount() -> Int {
        cachedURLReads
    }

    func metadata() -> YouTubePatternPresentationMetadata {
        providedMetadata
    }
}
