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

private final class PatternImportSecondRemoveGate: @unchecked Sendable {
    private var removes = 0

    func remove(_ url: URL) throws {
        removes += 1
        if removes == 2 { throw PatternImportInjectedFailure() }
        try FileManager.default.removeItem(at: url)
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
    let item = PatternInboxItem(
        originalFilename: source.lastPathComponent,
        receivedAt: .now,
        origin: .library,
        targetProjectID: nil,
        stagedFilename: "\(UUID().uuidString).pdf"
    )
    try files.beginImportTransaction(item: item, metadata: metadata, asset: asset)
    _ = try files.installAsset(data: Data(contentsOf: source), metadata: metadata, id: id, transactionID: item.id)

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
@Test func committedManifestWriteFailureReturnsErrorAndStartupReconcilesIt() async throws {
    let gate = PatternImportWriteGate()
    let harness = try PatternImportHarness(inboxWrite: { try gate.write($0, to: $1) })
    let source = try harness.makePDF(named: "mark.pdf")
    let item = try harness.inbox.enqueue(source: source, origin: .library, targetProjectID: nil, now: .now)

    await #expect(throws: PatternImportInjectedFailure.self) {
        try await harness.store.processPatternInboxItem(id: item.id)
    }
    let restarted = try harness.reopenedStore()

    #expect(restarted.patterns.count == 1)
    #expect(try PatternInboxFileService(root: harness.inbox.root).item(id: item.id) == nil)
}

@MainActor
@Test func cleanupFailureRetainsJournalUntilFreshRecoveryFinishesInboxCleanup() async throws {
    let harness = try PatternImportHarness(inboxRemove: { _ in throw PatternImportInjectedFailure() })
    let source = try harness.makePDF(named: "cleanup-journal.pdf")
    let item = try harness.inbox.enqueue(source: source, origin: .library, targetProjectID: nil, now: .now)
    let journal = harness.assetsRoot
        .appendingPathComponent("Assets/.Transactions", isDirectory: true)
        .appendingPathComponent("\(item.id.uuidString).json")

    _ = try await harness.store.processPatternInboxItem(id: item.id)
    #expect(FileManager.default.fileExists(atPath: journal.path))

    let restarted = try harness.reopenedStore()

    #expect(restarted.patterns.count == 1)
    #expect(!FileManager.default.fileExists(atPath: journal.path))
    #expect(try PatternInboxFileService(root: harness.inbox.root).item(id: item.id) == nil)
}

@MainActor
@Test func tamperedAssetJournalCannotCommitAnUnrelatedPendingInboxItem() async throws {
    let gate = PatternImportWriteGate()
    let harness = try PatternImportHarness(inboxWrite: { try gate.write($0, to: $1) })
    let firstSource = try harness.makePDF(named: "first.pdf")
    let first = try harness.inbox.enqueue(source: firstSource, origin: .library, targetProjectID: nil, now: .now)
    await #expect(throws: PatternImportInjectedFailure.self) {
        try await harness.store.processPatternInboxItem(id: first.id)
    }
    let secondSource = try harness.makePDF(named: "second.pdf")
    let second = try harness.inbox.enqueue(source: secondSource, origin: .library, targetProjectID: nil, now: .now)
    let journal = harness.assetsRoot
        .appendingPathComponent("Assets/.Transactions", isDirectory: true)
        .appendingPathComponent("\(first.id.uuidString).json")
    let journalData = try Data(contentsOf: journal)
    let tampered = try #require(String(data: journalData, encoding: .utf8))
        .replacingOccurrences(of: first.id.uuidString, with: second.id.uuidString)
    try Data(tampered.utf8).write(to: journal, options: .atomic)

    let restarted = try harness.reopenedStore()

    #expect(restarted.patterns.count == 1)
    #expect(try PatternInboxFileService(root: harness.inbox.root).item(id: first.id) == nil)
    #expect(try PatternInboxFileService(root: harness.inbox.root).item(id: second.id) != nil)
    #expect(!FileManager.default.fileExists(atPath: journal.path))
}

@MainActor
@Test func startupRecoveryRejectsSymlinkedAssetTreeWithoutTouchingExternalFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let patternRoot = root.appendingPathComponent("Patterns", isDirectory: true)
    let assets = patternRoot.appendingPathComponent("Assets", isDirectory: true)
    let outside = root.appendingPathComponent("Outside", isDirectory: true)
    let candidateID = UUID()
    let assetID = UUID()
    try FileManager.default.createDirectory(at: outside.appendingPathComponent(".Candidates"), withIntermediateDirectories: true)
    let candidate = outside.appendingPathComponent(".Candidates/\(candidateID.uuidString)")
    let final = outside.appendingPathComponent("\(assetID.uuidString).pdf")
    let candidateBytes = Data("external-candidate".utf8)
    let finalBytes = Data("external-final".utf8)
    try candidateBytes.write(to: candidate, options: .atomic)
    try finalBytes.write(to: final, options: .atomic)
    try FileManager.default.createDirectory(at: patternRoot, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: assets, withDestinationURL: outside)

    let store = JSONProjectStore(url: root.appendingPathComponent("projects-v1.json"))

    #expect(store.loadError == .unreadableArchive)
    #expect(try Data(contentsOf: candidate) == candidateBytes)
    #expect(try Data(contentsOf: final) == finalBytes)
    #expect(throws: ProjectStoreError.archiveUnavailable) { try store.add(name: "Blocked") }
}

@MainActor
@Test func startupRecoveryRejectsSymlinkedInboxCandidateDirectoryWithoutTouchingExternalFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let inboxRoot = root.appendingPathComponent("PatternInbox", isDirectory: true)
    let outside = root.appendingPathComponent("Outside", isDirectory: true)
    let externalCandidate = outside.appendingPathComponent(UUID().uuidString)
    let externalBytes = Data("external-inbox-candidate".utf8)
    try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try externalBytes.write(to: externalCandidate, options: .atomic)
    try FileManager.default.createSymbolicLink(
        at: inboxRoot.appendingPathComponent(".Candidates", isDirectory: true),
        withDestinationURL: outside
    )

    #expect(throws: PatternInboxError.invalidItem) {
        _ = try PatternInboxFileService(root: inboxRoot).recover()
    }

    let store = JSONProjectStore(
        url: root.appendingPathComponent("projects-v1.json"),
        patternFileService: PatternFileService(root: root.appendingPathComponent("Patterns", isDirectory: true)),
        patternInboxFileService: PatternInboxFileService(root: inboxRoot)
    )

    #expect(store.loadError == .unreadableArchive)
    #expect(try Data(contentsOf: externalCandidate) == externalBytes)
    #expect(throws: ProjectStoreError.archiveUnavailable) { try store.add(name: "Blocked") }
}

@MainActor
@Test func partialCommittedCleanupRetriesManifestRemovalAndThenCompletesJournal() async throws {
    let gate = PatternImportSecondRemoveGate()
    let harness = try PatternImportHarness(inboxRemove: { try gate.remove($0) })
    let source = try harness.makePDF(named: "partial-committed.pdf")
    let item = try harness.inbox.enqueue(source: source, origin: .library, targetProjectID: nil, now: .now)
    let journal = harness.assetsRoot
        .appendingPathComponent("Assets/.Transactions", isDirectory: true)
        .appendingPathComponent("\(item.id.uuidString).json")
    let staged = harness.inbox.root
        .appendingPathComponent("Items/\(item.stagedFilename)")
    let manifest = harness.inbox.root
        .appendingPathComponent("Manifests/\(item.id.uuidString).json")

    _ = try await harness.store.processPatternInboxItem(id: item.id)
    #expect(!FileManager.default.fileExists(atPath: staged.path))
    #expect(FileManager.default.fileExists(atPath: manifest.path))
    #expect(FileManager.default.fileExists(atPath: journal.path))

    let restarted = try harness.reopenedStore()

    #expect(restarted.patterns.count == 1)
    #expect(!FileManager.default.fileExists(atPath: manifest.path))
    #expect(!FileManager.default.fileExists(atPath: journal.path))
}

@MainActor
@Test func corruptInboxManifestQuarantinesJournalAndStagedBytesWithoutInvalidatingArchive() async throws {
    let gate = PatternImportWriteGate()
    let harness = try PatternImportHarness(inboxWrite: { try gate.write($0, to: $1) })
    let source = try harness.makePDF(named: "corrupt-manifest.pdf")
    let item = try harness.inbox.enqueue(source: source, origin: .library, targetProjectID: nil, now: .now)
    await #expect(throws: PatternImportInjectedFailure.self) {
        try await harness.store.processPatternInboxItem(id: item.id)
    }
    let manifest = harness.inbox.root.appendingPathComponent("Manifests/\(item.id.uuidString).json")
    let staged = harness.inbox.root.appendingPathComponent("Items/\(item.stagedFilename)")
    let journal = harness.assetsRoot.appendingPathComponent("Assets/.Transactions/\(item.id.uuidString).json")
    try Data("corrupt".utf8).write(to: manifest, options: .atomic)

    let restarted = try harness.reopenedStore()

    #expect(restarted.loadError == nil)
    #expect(restarted.patternAssets.count == 1)
    #expect(!FileManager.default.fileExists(atPath: staged.path))
    #expect(try FileManager.default.contentsOfDirectory(
        at: harness.inbox.root.appendingPathComponent(".Quarantine", isDirectory: true),
        includingPropertiesForKeys: nil
    ).contains { $0.pathExtension == "staged" })
    #expect(!FileManager.default.fileExists(atPath: journal.path))
}

@MainActor
@Test func unknownInboxManifestVersionQuarantinesJournalAndStagedBytesWithoutInvalidatingArchive() async throws {
    let gate = PatternImportWriteGate()
    let harness = try PatternImportHarness(inboxWrite: { try gate.write($0, to: $1) })
    let source = try harness.makePDF(named: "unknown-manifest.pdf")
    let item = try harness.inbox.enqueue(source: source, origin: .library, targetProjectID: nil, now: .now)
    await #expect(throws: PatternImportInjectedFailure.self) {
        try await harness.store.processPatternInboxItem(id: item.id)
    }
    let manifest = harness.inbox.root.appendingPathComponent("Manifests/\(item.id.uuidString).json")
    let staged = harness.inbox.root.appendingPathComponent("Items/\(item.stagedFilename)")
    let journal = harness.assetsRoot.appendingPathComponent("Assets/.Transactions/\(item.id.uuidString).json")
    var payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
    payload["version"] = 99
    try JSONSerialization.data(withJSONObject: payload).write(to: manifest, options: .atomic)

    let restarted = try harness.reopenedStore()

    #expect(restarted.loadError == nil)
    #expect(restarted.patternAssets.count == 1)
    #expect(!FileManager.default.fileExists(atPath: staged.path))
    #expect(try FileManager.default.contentsOfDirectory(
        at: harness.inbox.root.appendingPathComponent(".Quarantine", isDirectory: true),
        includingPropertiesForKeys: nil
    ).contains { $0.pathExtension == "staged" })
    #expect(!FileManager.default.fileExists(atPath: journal.path))
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
