import Foundation
import Testing
@testable import KnitNoteCore

private struct PatternImportInjectedFailure: Error {}

@MainActor
@Test func archiveWriteFailureRollsBackNewAssetAndRetryPublishesExactlyOnePattern() async throws {
    let harness = try PatternImportHarness(archiveWrite: { _, _ in throw PatternImportInjectedFailure() })
    let source = try harness.makePDF(named: "retry.pdf")
    let item = try harness.inbox.enqueue(source: source, origin: .library, targetProjectID: nil, now: .now)

    await #expect(throws: ProjectStoreError.persistenceFailed) {
        try await harness.store.processPatternInboxItem(id: item.id)
    }
    #expect(harness.store.patternAssets.isEmpty)
    #expect(try harness.inbox.item(id: item.id) != nil)
    let assetURL = try harness.assetURLFor(source: source)
    #expect(!FileManager.default.fileExists(atPath: assetURL.path))

    let retried = try harness.reopenedStore()
    let outcome = try await retried.processPatternInboxItem(id: item.id)

    #expect(harness.archivePatternCount() == 1)
    #expect(outcome == .created(patternID: retried.patterns[0].id))
}

@MainActor
@Test func assetMoveFailureLeavesInboxPendingForRestartRetry() async throws {
    let harness = try PatternImportHarness(assetMove: { _, _ in throw PatternImportInjectedFailure() })
    let source = try harness.makePDF(named: "move.pdf")
    let item = try harness.inbox.enqueue(source: source, origin: .library, targetProjectID: nil, now: .now)

    await #expect(throws: PatternImportInjectedFailure.self) {
        try await harness.store.processPatternInboxItem(id: item.id)
    }
    #expect(harness.store.patternAssets.isEmpty)
    #expect(try harness.inbox.item(id: item.id) != nil)

    let retried = try harness.reopenedStore()
    _ = try await retried.processPatternInboxItem(id: item.id)
    #expect(retried.patternAssets.count == 1)
    #expect(retried.patterns.count == 1)
}

@MainActor
@Test func cleanupFailureDoesNotUndoPublishedOutcomeAndRecoveryIsIdempotent() async throws {
    let harness = try PatternImportHarness(inboxRemove: { _ in throw PatternImportInjectedFailure() })
    let source = try harness.makePDF(named: "cleanup.pdf")
    let item = try harness.inbox.enqueue(source: source, origin: .library, targetProjectID: nil, now: .now)

    let outcome = try await harness.store.processPatternInboxItem(id: item.id)

    #expect(harness.store.patterns.count == 1)
    #expect(outcome == .created(patternID: harness.store.patterns[0].id))
    #expect(try harness.inbox.item(id: item.id) == nil)
    let retried = try harness.reopenedStore()
    await #expect(throws: PatternInboxError.itemNotFound) {
        try await retried.processPatternInboxItem(id: item.id)
    }
    #expect(retried.patterns.count == 1)
}

@MainActor
@Test func cancelledImportKeepsDurableInboxForARealRestart() async throws {
    let harness = try PatternImportHarness()
    let source = try harness.makePDF(named: "cancel.pdf")
    let item = try harness.inbox.enqueue(source: source, origin: .library, targetProjectID: nil, now: .now)
    let task = Task { try await harness.store.processPatternInboxItem(id: item.id) }
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try harness.inbox.item(id: item.id) != nil)
    let retried = try harness.reopenedStore()
    _ = try await retried.processPatternInboxItem(id: item.id)
    #expect(retried.patterns.count == 1)
}

@MainActor
@Test func ownedAssetExportPreservesEveryByteAfterStoreRestart() async throws {
    let harness = try PatternImportHarness()
    let source = try harness.makePDF(named: "export.pdf")
    let expected = try Data(contentsOf: source)
    let item = try harness.inbox.enqueue(source: source, origin: .library, targetProjectID: nil, now: .now)
    _ = try await harness.store.processPatternInboxItem(id: item.id)

    let reopened = try harness.reopenedStore()
    let asset = try #require(reopened.patternAssets.first)
    let exported = try PatternFileService(root: harness.assetsRoot).exportURL(asset)

    #expect(try Data(contentsOf: exported) == expected)
}
