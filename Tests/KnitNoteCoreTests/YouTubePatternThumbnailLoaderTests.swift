import Foundation
import Testing
@testable import KnitNoteCore

@Suite @MainActor struct YouTubePatternThumbnailLoaderTests {
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
            await loader.thumbnailURL(patternID: patternID, assetID: assetID)
        }
        guard await gate.waitUntilStarted(timeout: .seconds(10)) else {
            request.cancel()
            await gate.release()
            Issue.record("The utility-priority metadata fetch did not start within 10 seconds")
            return
        }

        request.cancel()
        let didCancelMetadataFetch = await gate.waitUntilCancelled(timeout: .seconds(1))
        #expect(didCancelMetadataFetch)
        // If cancellation propagation regresses, release the fetch explicitly
        // so this test reports its failed expectation instead of hanging.
        await gate.release()

        #expect(await request.value == nil)
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
        await gate.recordStarted()
        return try await withTaskCancellationHandler {
            try await gate.waitForRelease()
        } onCancel: {
            Task { await self.gate.recordCancellation() }
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

private actor MetadataFetchGate {
    private var started = false
    private var cancelled = false
    private var released = false

    func recordStarted() {
        started = true
    }

    func recordCancellation() {
        cancelled = true
    }

    func waitUntilStarted(timeout: Duration) async -> Bool {
        await waitUntil(timeout: timeout) { started }
    }

    func waitUntilCancelled(timeout: Duration) async -> Bool {
        await waitUntil(timeout: timeout) { cancelled }
    }

    func release() {
        released = true
    }

    func waitForRelease() async throws -> YouTubePatternPresentationMetadata {
        while !released {
            try Task.checkCancellation()
            await Task.yield()
        }
        return YouTubePatternPresentationMetadata(title: nil, thumbnailData: nil)
    }

    private func waitUntil(
        timeout: Duration,
        condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            guard clock.now < deadline else { return false }
            guard !condition() else { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
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
