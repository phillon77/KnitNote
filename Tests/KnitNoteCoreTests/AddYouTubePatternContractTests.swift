import Foundation
import Testing
@testable import KnitNoteCore

@MainActor
@Suite struct AddYouTubePatternContractTests {
    @Test func timeoutReturnsManualFallbackWhenFetcherNeverCompletes() async throws {
        let coordinator = YouTubePatternAddCoordinator()
        coordinator.urlText = "https://youtu.be/abcdefghijk"

        coordinator.readMetadata(using: NeverCompletingMetadataFetcher(), timeout: .milliseconds(10))
        await waitForTimeoutFallback(coordinator)

        #expect(coordinator.fetchState == .manualEntry(messageKey: "patterns.youtube.metadataUnavailable"))
    }

    @Test func changingURLAndDisappearingCancelTheOutstandingMetadataFetch() async throws {
        let probe = MetadataCancellationProbe()
        let coordinator = YouTubePatternAddCoordinator()
        coordinator.urlText = "https://youtu.be/abcdefghijk"
        coordinator.readMetadata(using: CancellableMetadataFetcher(probe: probe))
        await probe.waitUntilStarted()

        coordinator.urlText = "https://youtu.be/zyxwvutsrqp"
        await probe.waitUntilCancelled()
        #expect(coordinator.fetchState == .idle)

        coordinator.readMetadata(using: CancellableMetadataFetcher(probe: probe))
        await probe.waitUntilStarted(count: 2)
        coordinator.cancelMetadataRequest()
        await probe.waitUntilCancelled(count: 2)
    }

    @Test func metadataUsesEditableTitleAndDropsMalformedPreviewBytes() async throws {
        let coordinator = YouTubePatternAddCoordinator()
        coordinator.urlText = "https://youtu.be/abcdefghijk"
        coordinator.readMetadata(
            using: StaticMetadataFetcher(title: "Fetched title", thumbnailData: Data("not an image".utf8))
        )
        await waitForMetadataToSettle(coordinator)

        #expect(coordinator.title == "Fetched title")
        #expect(coordinator.fetchState == .loaded(thumbnailData: nil))
        #expect(coordinator.isAddEnabled)

        coordinator.title = "Edited title"
        #expect(coordinator.title == "Edited title")
        coordinator.title = "  \n"
        #expect(!coordinator.isAddEnabled)
    }

    @Test func duplicateAddAttemptStartsOnlyOneStoreOperationAndCachesOnlyAfterSuccess() async throws {
        let probe = AddOperationProbe()
        let coordinator = YouTubePatternAddCoordinator()
        coordinator.urlText = "https://youtu.be/abcdefghijk"
        coordinator.title = "Video pattern"

        async let first: YouTubePatternAddResult? = coordinator.add(
            add: { link, title, projectID in
                await probe.recordAdd(link: link, title: title, projectID: projectID)
                try await Task.sleep(for: .milliseconds(30))
                return YouTubePatternAddResult(resolution: .created, patternID: UUID())
            },
            cache: { _, _ in await probe.recordCache() }
        )
        async let second: YouTubePatternAddResult? = coordinator.add(
            add: { _, _, _ in
                await probe.recordUnexpectedSecondAdd()
                return YouTubePatternAddResult(resolution: .created, patternID: UUID())
            },
            cache: { _, _ in await probe.recordCache() }
        )
        _ = await (first, second)

        #expect(await probe.events == [.add])
    }

    @Test func failedAddNeverCachesAndSuccessfulAddCachesAfterTheStoreResult() async throws {
        let failedProbe = AddOperationProbe()
        let failed = YouTubePatternAddCoordinator()
        failed.urlText = "https://youtu.be/abcdefghijk"
        failed.title = "Video pattern"

        _ = await failed.add(
            add: { _, _, _ in
                await failedProbe.recordAdd()
                throw AddFailure.expected
            },
            cache: { _, _ in await failedProbe.recordCache() }
        )
        #expect(await failedProbe.events == [.add])
        #expect(failed.addErrorKey == "patterns.youtube.addFailed")

        let successProbe = AddOperationProbe()
        let success = YouTubePatternAddCoordinator()
        success.urlText = "https://youtu.be/abcdefghijk"
        success.title = "Video pattern"
        success.setPreviewThumbnailData(try makeCoordinatorPNG())

        _ = await success.add(
            add: { _, _, _ in
                await successProbe.recordAdd()
                return YouTubePatternAddResult(resolution: .created, patternID: UUID())
            },
            cache: { _, _ in await successProbe.recordCache() }
        )
        #expect(await successProbe.events == [.add, .cache])
    }
}

private enum AddFailure: Error { case expected }

private final class NeverCompletingMetadataFetcher: YouTubePatternMetadataFetching {
    func fetch(for url: URL) async throws -> YouTubePatternPresentationMetadata {
        await neverCompletingMetadataGate.wait()
    }
}

private let neverCompletingMetadataGate = NeverCompletingMetadataGate()

private actor NeverCompletingMetadataGate {
    private var continuations: [CheckedContinuation<YouTubePatternPresentationMetadata, Never>] = []

    func wait() async -> YouTubePatternPresentationMetadata {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

private final class StaticMetadataFetcher: YouTubePatternMetadataFetching {
    private let metadata: YouTubePatternPresentationMetadata

    init(title: String?, thumbnailData: Data?) {
        metadata = .init(title: title, thumbnailData: thumbnailData)
    }

    func fetch(for url: URL) async throws -> YouTubePatternPresentationMetadata { metadata }
}

private final class CancellableMetadataFetcher: YouTubePatternMetadataFetching {
    private let probe: MetadataCancellationProbe

    init(probe: MetadataCancellationProbe) { self.probe = probe }

    func fetch(for url: URL) async throws -> YouTubePatternPresentationMetadata {
        await probe.recordStarted()
        return try await withTaskCancellationHandler {
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        } onCancel: {
            Task { await self.probe.recordCancelled() }
        }
    }
}

private actor MetadataCancellationProbe {
    private var started = 0
    private var cancelled = 0

    func recordStarted() { started += 1 }
    func recordCancelled() { cancelled += 1 }

    func waitUntilStarted(count: Int = 1) async {
        while started < count { await Task.yield() }
    }

    func waitUntilCancelled(count: Int = 1) async {
        while cancelled < count { await Task.yield() }
    }
}

private enum AddEvent: Equatable { case add, cache, unexpectedSecondAdd }

private actor AddOperationProbe {
    private(set) var events: [AddEvent] = []

    func recordAdd(link: YouTubePatternLink? = nil, title: String? = nil, projectID: UUID? = nil) {
        events.append(.add)
    }
    func recordUnexpectedSecondAdd() { events.append(.unexpectedSecondAdd) }
    func recordCache() { events.append(.cache) }
}

private func makeCoordinatorPNG() throws -> Data {
    let service = PatternThumbnailFileService(directory: FileManager.default.temporaryDirectory)
    let data = try makeCoordinatorImageData()
    return try service.sanitizedExternalThumbnailData(data)
}

private func makeCoordinatorImageData() throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns"))
}

@MainActor
private func waitForMetadataToSettle(_ coordinator: YouTubePatternAddCoordinator) async {
    for _ in 0..<100 {
        guard coordinator.fetchState == .loading else { return }
        await Task.yield()
    }
}

@MainActor
private func waitForTimeoutFallback(_ coordinator: YouTubePatternAddCoordinator) async {
    for _ in 0..<100 {
        guard coordinator.fetchState == .loading else { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}
