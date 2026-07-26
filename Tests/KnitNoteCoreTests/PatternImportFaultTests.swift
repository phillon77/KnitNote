import Foundation
import Testing
@testable import KnitNoteCore

private struct PatternImportInjectedFailure: Error {}
private final class PatternImportWriteGate: @unchecked Sendable {
    private var writes = 0
    func write(_ data: Data, to url: URL) throws {
        writes += 1
        if writes == 2 { throw PatternImportInjectedFailure() }
        try data.write(to: url, options: .atomic)
    }
}

private final class PatternStorageAvailabilityGate: @unchecked Sendable {
    var locations: PatternStorageLocations?

    func resolve() throws -> PatternStorageLocations {
        guard let locations else { throw PatternInboxError.appGroupUnavailable }
        return locations
    }
}

@MainActor
@Test func freshStartupRemovesUnreferencedFinalAssetAndCandidateCrashArtifacts() throws {
    let harness = try PatternImportHarness()
    let source = try harness.makePDF(named: "crash.pdf")
    let metadata = try PatternFileService(root: harness.assetsRoot).inspect(source)
    let id = PatternImportCoordinator().deterministicAssetID(for: metadata.sha256)
    let asset = PatternAsset(id: id, sha256: metadata.sha256, kind: metadata.kind, storedFilename: "\(id.uuidString).pdf", byteCount: metadata.byteCount, pageCount: metadata.pageCount)
    let files = PatternFileService(root: harness.assetsRoot)
    try files.beginImportTransaction(itemID: UUID(), asset: asset)
    _ = try files.installAsset(data: Data(contentsOf: source), metadata: metadata, id: id, transactionID: UUID())

    let restarted = try harness.reopenedStore()

    #expect(restarted.patternAssets.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: try files.assetURL(asset).path))
}

@MainActor
@Test func freshStartupProactivelyRecoversOrphanedInboxItem() throws {
    let harness = try PatternImportHarness()
    let orphanID = UUID()
    let orphan = harness.inbox.root
        .appendingPathComponent("Items", isDirectory: true)
        .appendingPathComponent("\(orphanID.uuidString).pdf")
    try FileManager.default.createDirectory(at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
    try makeTestPatternPDF(at: orphan)

    let restarted = try harness.reopenedStore()

    #expect(restarted.loadError == nil)
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
}

@MainActor
@Test func unavailableLiveDependenciesKeepRetryAndMutationsBlockedUntilTheyResolve() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = PatternStorageAvailabilityGate()
    let archiveURL = root.appendingPathComponent("KnitNote/projects-v1.json")
    let store = JSONProjectStore(
        url: archiveURL,
        backupService: KnitNoteBackupService(
            liveRoot: root.appendingPathComponent("KnitNote", isDirectory: true),
            workRoot: root.appendingPathComponent("Work", isDirectory: true)
        ),
        initialLoadError: .archiveUnavailable,
        patternStorageLocationsProvider: { try gate.resolve() }
    )

    store.retryLoad()
    #expect(store.loadError == .archiveUnavailable)
    #expect(throws: ProjectStoreError.archiveUnavailable) { try store.add(name: "Blocked") }

    gate.locations = PatternStorageLocations(
        assetRoot: root.appendingPathComponent("KnitNote/Patterns", isDirectory: true),
        inboxRoot: root.appendingPathComponent("KnitNote/PatternInbox", isDirectory: true)
    )
    store.retryLoad()

    #expect(store.loadError == nil)
    try store.add(name: "Available")
    #expect(store.projects.map(\.name) == ["Available"])
}

@MainActor
@Test func committedManifestWriteFailureStillReturnsSuccessAndStartupReconcilesIt() async throws {
    let gate = PatternImportWriteGate()
    let harness = try PatternImportHarness(inboxWrite: { try gate.write($0, to: $1) })
    let source = try harness.makePDF(named: "mark.pdf")
    let item = try harness.inbox.enqueue(source: source, origin: .library, targetProjectID: nil, now: .now)

    let outcome = try await harness.store.processPatternInboxItem(id: item.id)
    let restarted = try harness.reopenedStore()

    #expect(outcome == .created(patternID: harness.store.patterns[0].id))
    #expect(restarted.patterns.count == 1)
    #expect(try PatternInboxFileService(root: harness.inbox.root).item(id: item.id) == nil)
}

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
