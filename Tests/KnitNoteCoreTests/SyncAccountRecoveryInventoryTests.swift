import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct SyncAccountRecoveryInventoryTests {
    @Test func canonicalCandidateDirectoryCannotAuthorizeCleanup() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let url = f.paths.workingSet.appendingPathComponent("SyncMetadata/.canonical-next.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(throws: SyncAccountRecoveryInventory.Error.unresolvedRecovery) { try f.capture() }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func canonicalCheckpointIsBoundButAcknowledgedRecordsStayOutOfPendingPacket() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let canonical = try f.installCanonicalCheckpoint()
        let mutations = try canonical.records.map { try SyncMutation.save(recordVersion: .init(record: $0), mutationID: UUID()) }
        try f.journal.enqueue(mutations)
        try f.journal.acknowledge(Set(mutations.dropFirst().map(\.identity)))
        let inventory = try f.capture()
        let entry = try #require(inventory.entries.first { $0.relativePath == "working-set/SyncMetadata/canonical.json" })
        #expect(entry.sha256 == Data(SHA256.hash(data: try canonical.encoded())))
        #expect(entry.byteCount == Int64(try canonical.encoded().count))
        #expect(inventory.packet.mutations == [mutations[0]])
        #expect(inventory.packet.files.isEmpty)
        #expect(canonical.records.count == 7)
    }

    @Test(arguments: [Data("{\"formatVersion\":".utf8), Data("unresolved candidate".utf8)])
    func canonicalFixedTemporaryRefusesInventoryWithoutChangingBytes(bytes: Data) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        try f.write("working-set/SyncMetadata/.canonical-next.json", bytes)
        let before = try f.diskBytes()
        #expect(throws: SyncAccountRecoveryInventory.Error.unresolvedRecovery) { try f.capture() }
        #expect(try f.diskBytes() == before)
    }

    @Test func capturesExactPendingAndEveryPlaintextRootWithoutChangingFiles() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let mutation = SyncMutation.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID())
        try f.journal.enqueue(mutation)
        try f.write("staging/pending", Data("pending".utf8))
        try f.write("quarantine/retained", Data("retained".utf8))
        try f.write("vault/encrypted.vault", Data("ciphertext".utf8))
        try Data("decoded".utf8).write(to: f.paths.decryptedTemporary.appendingPathComponent("copy"))
        let before = try f.diskBytes()
        let result = try f.capture()
        #expect(result.packet.mutations == [mutation])
        #expect(result.journalURL == f.journalURL)
        let names = Set(result.entries.map(\.relativePath))
        #expect(names.contains("working-set/projects-v1.json"))
        #expect(names.contains("staging/pending"))
        #expect(names.contains("journal/pending.json.segment"))
        #expect(names.contains("quarantine/retained"))
        #expect(names.contains(where: { $0.hasSuffix("/copy") }))
        let excluded = names.filter { $0 == "vault" || $0.hasPrefix("vault/") || $0 == ".storage-lock" || $0 == ".decrypted-temporary/.owner-v1" }
        #expect(excluded.isEmpty)
        #expect(try f.diskBytes() == before)
        #expect(try f.capture().fingerprint == result.fingerprint)
    }

    @Test func partiallyAcknowledgedDeletionRetainsWholeSelectedGroupOnly() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        let selected = try f.addDeletion(ledger: ledger, name: "pending project")
        let acknowledged = try f.addDeletion(ledger: ledger, name: "acknowledged project")
        let all = try (selected.versions + acknowledged.versions).map { try SyncMutation.save(recordVersion: $0, mutationID: UUID()) }
        try f.journal.enqueue(all)
        try f.journal.acknowledge(Set(all.dropFirst().map(\.identity)))
        let before = try f.diskBytes()
        let result = try f.capture()
        #expect(result.packet.mutations == [all[0]])
        let export = try #require(result.deletionLedger)
        let envelope = try JSONSerialization.jsonObject(with: export) as! [String: Any]
        let payload = try JSONSerialization.jsonObject(with: Data(base64Encoded: envelope["payload"] as! String)!) as! [String: Any]
        let groups = payload["groups"] as! [[String: Any]]
        #expect(groups.count == 1)
        let entry = groups[0]["entry"] as! [String: Any]
        #expect(entry["id"] as? String == selected.id.uuidString)
        #expect((entry["exactRemovalVersions"] as! [Any]).count == selected.versions.count)
        #expect(try f.diskBytes() == before)
    }

    @Test func capturesPendingMarkersAndIgnoresValidatedUnboundHistoricalStage() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        let deleted = try f.addDeletion(ledger: ledger, name: "expired")
        try ledger.purge(now: Date(timeIntervalSince1970: 2_592_100), references: .init(acknowledgedRemovalVersionIDs: Set(deleted.versions.map(\.versionID))))
        let markerVersions = try ledger.pendingDeletionMarkerVersions()
        _ = try ledger.stage(domain: f.domain("abandoned stage"), attachments: [:], restoreRelativePaths: [:], deletedAt: .now)
        let before = try f.diskBytes()
        let result = try f.capture()
        #expect(result.pendingMarkerVersions == markerVersions)
        #expect(!markerVersions.isEmpty)
        #expect(result.packet.mutations.isEmpty)
        #expect(try f.diskBytes() == before)
    }

    @Test func refusesBootstrapPublicationAndUnsafeBindingWithoutMutation() throws {
        for name in [".KnitNote-SyncBootstrap/original/data", "working-set/.projects-v1.json.sync-publication.json"] {
            let f = try RecoveryInventoryFixture(); defer { f.remove() }
            try f.write(name, Data("unresolved".utf8))
            let before = try f.diskBytes()
            #expect(throws: (any Error).self) { try f.capture() }
            #expect(try f.diskBytes() == before)
        }
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let before = try f.diskBytes()
        let other = try SyncAccountIdentity(containerIdentifier: "test", userRecordName: "B")
        #expect(throws: (any Error).self) {
            try SyncAccountRecoveryInventory.capture(storage: f.storage, paths: f.paths, account: other,
                journal: f.journal, archiveURL: f.archiveURL)
        }
        #expect(throws: (any Error).self) {
            try SyncAccountRecoveryInventory.capture(storage: f.storage, paths: f.paths, account: f.account,
                journal: FileSyncMutationJournal(url: f.base.appendingPathComponent("outside")), archiveURL: f.archiveURL)
        }
        #expect(try f.diskBytes() == before)
    }

    @Test func aggregateBudgetAndInterruptedJournalRefuseWithoutRepair() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        try f.journal.enqueue(.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID()))
        let before = try f.diskBytes()
        #expect(throws: (any Error).self) { try f.capture(maximumBytes: 1) }
        #expect(try f.diskBytes() == before)
        let segment = f.journalURL.appendingPathExtension("segment")
        var damaged = try Data(contentsOf: segment); damaged.append(contentsOf: [1, 2, 3])
        try damaged.write(to: segment)
        let interrupted = try f.diskBytes()
        #expect(throws: (any Error).self) { try f.capture() }
        #expect(try f.diskBytes() == interrupted)
    }

    @Test(arguments: ["committed", "rolledBack", "prepared", "corrupt", "wrongAccount"])
    func bootstrapTerminalProofIsReadOnlyAndBoundToCurrentAccount(state: String) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [try StoredProject(name: "bootstrap project")])
        try JSONEncoder().encode(archive).write(to: f.archiveURL)
        let context = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let bootstrap = try SyncBootstrapTransaction(liveRoot: f.paths.workingSet, context: context,
            journalRelativePath: "SyncMetadata/bootstrap-journal", validateContext: { _ in })
        let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: f.paths.workingSet, deviceID: "fixture")
        let prepared = try bootstrap.prepare(local: package, sourceArchive: archive,
            remote: .init(context: context, records: [], attachments: [:], isComplete: true))
        if state == "rolledBack" { try bootstrap.rollback(prepared) }
        else if state != "prepared" { try bootstrap.install(prepared); _ = try bootstrap.commit(prepared) }
        if state == "corrupt" {
            try Data("invalid receipt".utf8).write(to: f.paths.workingSet.appendingPathComponent("SyncMetadata/bootstrap-receipt.json"))
        }
        if state == "wrongAccount" {
            let active = prepared.accountOwnedRoots[0].appendingPathComponent("active.json")
            var envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: active)) as! [String: Any]
            var payload = try JSONSerialization.jsonObject(with: Data(base64Encoded: envelope["payload"] as! String)!) as! [String: Any]
            var context = payload["context"] as! [String: Any]; context["accountIDHash"] = String(repeating: "b", count: 64)
            payload["context"] = context
            let bytes = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
            envelope["payload"] = bytes.base64EncodedString(); envelope["digest"] = Data(SHA256.hash(data: bytes)).base64EncodedString()
            try JSONSerialization.data(withJSONObject: envelope).write(to: active)
        }
        let before = try f.diskBytes()
        let journal = FileSyncMutationJournal(url: f.paths.workingSet.appendingPathComponent("SyncMetadata/bootstrap-journal"))
        if ["committed", "rolledBack"].contains(state) {
            let result = try SyncAccountRecoveryInventory.capture(storage: f.storage, paths: f.paths, account: f.account, journal: journal, archiveURL: f.archiveURL)
            #expect(result.entries.contains { $0.relativePath.hasPrefix(".KnitNote-SyncBootstrap/") })
            #expect(state == "rolledBack" || !result.packet.mutations.isEmpty)
        } else {
            #expect(throws: (any Error).self) {
                try SyncAccountRecoveryInventory.capture(storage: f.storage, paths: f.paths, account: f.account, journal: journal, archiveURL: f.archiveURL)
            }
        }
        #expect(try f.diskBytes() == before)
    }

    @Test func excludedVaultStillRequiresNoFollowOwnedDirectory() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let outside = f.base.appendingPathComponent("outside-vault")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let source = outside.appendingPathComponent("important")
        try Data("untouched".utf8).write(to: source)
        try FileManager.default.removeItem(at: f.paths.vault)
        try FileManager.default.createSymbolicLink(at: f.paths.vault, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try f.capture() }
        #expect(try Data(contentsOf: source) == Data("untouched".utf8))
    }

    @Test func selectedRetainedBytesRoundtripAndAggregateLimitIncludesDependencies() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        let selected = try f.addDeletion(ledger: ledger, name: "with photo", attachment: true)
        let mutation = try SyncMutation.save(recordVersion: selected.versions[0], mutationID: UUID())
        try f.journal.enqueue(mutation)
        let before = try f.diskBytes()
        let result = try f.capture()
        #expect(result.packet.mutations == [mutation])
        let file = try #require(result.deletionFiles.first)
        #expect(result.deletionFiles.count == 1)
        #expect(file.bytes == Data("retained photograph".utf8))
        let limit = try result.encoded().count
        #expect(throws: (any Error).self) { try f.capture(maximumBytes: limit - 1) }
        #expect(try f.capture(maximumBytes: limit).encoded(maximumBytes: limit).count == limit)
        #expect(try f.diskBytes() == before)
        let copy = f.base.appendingPathComponent("exported-ledger")
        let relative = String(file.relativePath.dropFirst("working-set/.sync-deletions/".count))
        let target = copy.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file.bytes.write(to: target)
        try #require(result.deletionLedger).write(to: copy.appendingPathComponent("ledger.json"))
        let restored = try SyncDeletionLedger(root: copy)
        #expect(try restored.recentlyDeleted().map(\.id) == [selected.id])
        #expect(try restored.recentlyDeleted().first?.exactRemovalVersions == selected.versions)
    }

    @Test(arguments: ["completed", "canceled", "prepared", "publication"])
    func ledgerRestorationHistoryRequiresTerminalDiskAuthority(state: String) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        let deleted = try f.addDeletion(ledger: ledger, name: "restored project")
        let entry = try #require(ledger.recentlyDeleted().first)
        let mutations = try entry.domain.ownedRecords.map { try SyncMutation.save(recordVersion: SyncRecordVersion(record: $0), mutationID: UUID()) }
        let beforeHash = Data(SHA256.hash(data: try Data(contentsOf: f.archiveURL)))
        let publication = try SyncPublicationTransaction(expectedArchiveSHA256: Data(repeating: 9, count: 32),
            mutations: mutations, revisionReceipts: mutations.map { .init(entityID: $0.recordID, mutationID: $0.mutationID, logicalRevision: 1, deviceID: "fixture") },
            restorationWitness: .init(entryID: deleted.id, attemptID: UUID(), beforeArchiveSHA256: beforeHash))
        let publicationFile = SyncPublicationTransactionFile(archiveURL: f.archiveURL)
        try publicationFile.write(publication)
        try ledger.beginRestore(publication: publication)
        if state == "completed" || state == "publication" { try ledger.finishRestore(publication: publication) }
        if state == "canceled" {
            try ledger.recover(archiveSHA256: beforeHash, publication: publication, publicationStatus: .uncommitted)
        }
        if state != "publication" { try publicationFile.remove() }
        try f.journal.enqueue(SyncMutation.save(recordVersion: deleted.versions[0], mutationID: UUID()))
        let before = try f.diskBytes()
        if ["completed", "canceled"].contains(state) {
            let result = try f.capture()
            let bytes = try #require(result.deletionLedger)
            let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            let payload = try JSONSerialization.jsonObject(with: Data(base64Encoded: object["payload"] as! String)!) as! [String: Any]
            let groups = payload["groups"] as! [[String: Any]]
            #expect(groups.count == (state == "canceled" ? 1 : 0))
            #expect(groups.first?["restoration"] == nil)
        } else { #expect(throws: (any Error).self) { try f.capture() } }
        #expect(try f.diskBytes() == before)
    }

    @Test func pendingPurgeAndUnknownLedgerFileAreNotRecoveredByCapture() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        let deleted = try f.addDeletion(ledger: ledger, name: "purging", attachment: true)
        do {
            try ledger.purge(now: Date(timeIntervalSince1970: 2_592_100),
                references: .init(acknowledgedRemovalVersionIDs: Set(deleted.versions.map(\.versionID))),
                afterIntent: { throw SyncDeletionLedgerError.unavailable })
            Issue.record("Expected injected interruption")
        } catch {}
        let before = try f.diskBytes()
        #expect(throws: (any Error).self) { try f.capture() }
        #expect(try f.diskBytes() == before)
        let other = try RecoveryInventoryFixture(); defer { other.remove() }
        _ = try SyncDeletionLedger(root: other.ledgerRoot)
        try Data("unknown repair".utf8).write(to: other.ledgerRoot.appendingPathComponent("unknown"))
        let unchanged = try other.diskBytes()
        #expect(throws: (any Error).self) { try other.capture() }
        #expect(try other.diskBytes() == unchanged)
    }

    @Test func concreteSnapshotBoundsJournalReadsAndPreservesStagedAttachmentURLs() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        _ = try f.addDeletion(ledger: ledger, name: "photo", attachment: true)
        let entry = try #require(ledger.recentlyDeleted().first)
        let record = try #require(entry.domain.ownedRecords.first { $0.id.kind == .attachment })
        let proof = try #require(entry.files.first)
        let source = try SyncAttachmentSource(fileURL: f.ledgerRoot.appendingPathComponent(proof.retainedRelativePath), contentSHA256: proof.sha256, byteCount: proof.byteCount)
        try f.journal.enqueue(SyncMutation.save(recordVersion: SyncRecordVersion(record: record), attachmentSource: source, mutationID: UUID()))
        let pending = try f.journal.pending()
        let before = try f.diskBytes()
        #expect(throws: (any Error).self) { try f.journal.recoverySnapshot(maximumBytes: 1) }
        let result = try f.capture()
        #expect(result.packet.mutations == pending)
        #expect(result.packet.files.first?.bytes == Data("retained photograph".utf8))
        #expect(result.packet.mutations.first?.attachmentSource?.fileURL == pending[0].attachmentSource?.fileURL)
        #expect(try f.diskBytes() == before)
    }

    @Test(arguments: ["completed", "canceled", "changedBytes", "unknownPath"])
    func terminalRestorationRecognizesOnlyItsExactStagedSources(state: String) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        let deleted = try f.addDeletion(ledger: ledger, name: "restored photo", attachment: true)
        let entry = try #require(ledger.recentlyDeleted().first)
        let restored = try entry.domain.restoring(into: entry.exactRemovalVersions.map(\.record),
            now: Date(timeIntervalSince1970: 200), deviceID: "fixture")
        let record = try #require(restored.records.first { restored.changedIDs.contains($0.id) && $0.id.kind == .attachment })
        let proof = try #require(entry.files.first)
        let original = try SyncAttachmentSource(fileURL: f.ledgerRoot.appendingPathComponent(proof.retainedRelativePath), contentSHA256: proof.sha256, byteCount: proof.byteCount)
        let staged = try ledger.stageRestoreSources(id: deleted.id, sources: [record.id.uuid: original])
        let mutations = try restored.records.filter { restored.changedIDs.contains($0.id) }.map {
            try SyncMutation.save(recordVersion: SyncRecordVersion(record: $0), attachmentSource: staged[$0.id.uuid], mutationID: UUID())
        }
        let beforeHash = Data(SHA256.hash(data: try Data(contentsOf: f.archiveURL)))
        let publication = try SyncPublicationTransaction(expectedArchiveSHA256: Data(repeating: 9, count: 32), mutations: mutations,
            revisionReceipts: mutations.map { .init(entityID: $0.recordID, mutationID: $0.mutationID, logicalRevision: 101, deviceID: "fixture") },
            restorationWitness: .init(entryID: deleted.id, attemptID: UUID(), beforeArchiveSHA256: beforeHash))
        try ledger.beginRestore(publication: publication)
        if state == "canceled" { try ledger.recover(archiveSHA256: beforeHash, publication: publication, publicationStatus: .uncommitted) }
        else { try ledger.finishRestore(publication: publication) }
        let stagedURL = try #require(staged[record.id.uuid]?.fileURL)
        if state == "changedBytes" { try Data("changed photograph!".utf8).write(to: stagedURL) }
        if state == "unknownPath" {
            try FileManager.default.moveItem(at: stagedURL, to: stagedURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString))
        }
        let before = try f.diskBytes()
        if state == "completed" || state == "canceled" {
            let result = try f.capture()
            #expect(result.packet.files.isEmpty)
            #expect(result.deletionFiles.isEmpty)
            #expect(result.entries.contains { $0.relativePath.contains("/restore-") && !$0.isDirectory })
        } else { #expect(throws: (any Error).self) { try f.capture() } }
        #expect(try f.diskBytes() == before)
    }

    @Test func recoveryAttachmentReadCannotExceedRemainingCaptureBudget() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let bytes = Data(repeating: 42, count: 1_048_576)
        let file = f.paths.staging.appendingPathComponent("large-photo")
        try bytes.write(to: file)
        let owner = SyncEntityID(kind: .project, uuid: UUID())
        let version = try SyncAttachmentVersion.issuing(slot: .init(owner: owner, role: "project-photo", slotID: "cover"),
            contentSHA256: Data(SHA256.hash(data: bytes)), byteCount: Int64(bytes.count), mediaType: "image/jpeg", displayFilename: "cover.jpg")
        let stamp = SyncMutationStamp(logicalRevision: 1, modifiedAt: Date(timeIntervalSince1970: 1), deviceID: "fixture")
        let record = SyncRecord(schemaVersion: 1, id: .init(kind: .attachment, uuid: version.versionID), createdAt: stamp.modifiedAt,
            entityRevision: 1, payload: .init(fields: [:], attachment: version), relationships: [.init(role: "owner", target: owner)],
            deletedAt: .init(value: nil, stamp: stamp))
        try f.journal.enqueue(SyncMutation.save(recordVersion: SyncRecordVersion(record: record),
            attachmentSource: .init(fileURL: file, contentSHA256: version.contentSHA256, byteCount: version.byteCount), mutationID: UUID()))
        let counters = SyncRegularFileReaderIOCounters()
        let observed = FileSyncMutationJournal(url: f.journalURL, reader: SyncRegularFileReader(ioCounters: counters))
        let before = try f.diskBytes()
        let budget = 8_192
        #expect(throws: (any Error).self) {
            try SyncAccountRecoveryInventory.capture(storage: f.storage, paths: f.paths, account: f.account,
                journal: observed, archiveURL: f.archiveURL, maximumBytes: budget)
        }
        // Counters belong to the real regular-file reader, including checkpoint,
        // segment and attachment reads. Streaming inventory uses bounded chunks.
        #expect(counters.bytesRead <= budget)
        #expect(try f.diskBytes() == before)
    }

    @Test(arguments: ["base", "account", "lock", "owner", "temporary", "session", "vault"])
    func finalInventoryRevalidatesPathAndExcludedControlBindings(target: String) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let location: URL
        switch target {
        case "base": location = f.base
        case "account": location = f.paths.accountRoot
        case "lock": location = f.paths.accountRoot.appendingPathComponent(".storage-lock")
        case "owner": location = f.paths.decryptedTemporary.deletingLastPathComponent().appendingPathComponent(".owner-v1")
        case "temporary": location = f.paths.decryptedTemporary.deletingLastPathComponent()
        case "session": location = f.paths.decryptedTemporary
        default: location = f.paths.vault
        }
        let moved = f.base.deletingLastPathComponent().appendingPathComponent("recovery-binding-moved-" + UUID().uuidString)
        let regular = target == "lock" || target == "owner"
        let original = regular ? try Data(contentsOf: location) : nil
        var relocated = false
        defer {
            if relocated {
                try? FileManager.default.removeItem(at: location)
                try? FileManager.default.moveItem(at: moved, to: location)
            }
        }
        #expect(throws: (any Error).self) {
            try f.storage.withRecoveryInventory(paths: f.paths, account: f.account, maximumBytes: 100_000_000) { _ in
                try FileManager.default.moveItem(at: location, to: moved)
                relocated = true
                if let original { try original.write(to: location) }
                else { try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true) }
            }
        }
        #expect(FileManager.default.fileExists(atPath: moved.path))
        if let original { #expect(try Data(contentsOf: moved) == original) }
    }
}

struct RecoveryInventoryFixture {
    let base: URL
    let account = try! SyncAccountIdentity(containerIdentifier: "test", userRecordName: "A")
    let storage: SyncAccountStorage
    let paths: SyncAccountStorage.Paths
    let journal: FileSyncMutationJournal
    let journalURL: URL
    var archiveURL: URL { paths.workingSet.appendingPathComponent("projects-v1.json") }
    var ledgerRoot: URL { paths.workingSet.appendingPathComponent(".sync-deletions") }
    init() throws {
        base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("recovery-inventory-" + UUID().uuidString)
        storage = SyncAccountStorage(baseURL: base)
        paths = try storage.open(identity: account)
        journalURL = paths.journal.appendingPathComponent("pending.json")
        journal = FileSyncMutationJournal(url: journalURL)
        try Data("canonical archive".utf8).write(to: paths.workingSet.appendingPathComponent("projects-v1.json"))
    }
    func capture(maximumBytes: Int = 100_000_000) throws -> SyncAccountRecoveryInventory {
        try .capture(storage: storage, paths: paths, account: account, journal: journal, archiveURL: archiveURL, maximumBytes: maximumBytes)
    }
    func installCanonicalCheckpoint() throws -> SyncCanonicalCheckpoint {
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [try StoredProject(name: "Canonical account A")])
        let bytes = try JSONEncoder().encode(archive)
        try bytes.write(to: archiveURL)
        let exported = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: paths.workingSet, deviceID: "account-fixture")
        let checkpoint = try SyncCanonicalCheckpoint(accountIDHash: account.accountIDHash, commitID: UUID(),
            archiveSHA256: Data(SHA256.hash(data: bytes)), records: exported.records, legacyRecordIDsToDelete: [])
        let store = try SyncCanonicalCheckpointStore(liveRoot: paths.workingSet, account: account, validateOwnership: {})
        try store.install(checkpoint, replacing: nil)
        return checkpoint
    }
    func write(_ path: String, _ bytes: Data) throws {
        let file = paths.accountRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
    }
    func diskBytes() throws -> [String: Data] {
        let items = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey])!
        var result: [String: Data] = [:]
        for case let url as URL in items where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[url.path] = try Data(contentsOf: url)
        }
        return result
    }
    func domain(_ name: String) throws -> SyncDeletedDomain {
        let project = try StoredProject(name: name)
        let records = try SyncCanonicalPublicationSnapshot(archive: .init(version: ProjectArchive.currentVersion, projects: [project]), deviceID: "fixture").records
        return .init(rootIDs: [.init(kind: .project, uuid: project.id)], ownedRecords: Array(records.values), supportingParentIDs: [], removedReminders: [:])
    }
    func addDeletion(ledger: SyncDeletionLedger, name: String, attachment: Bool = false) throws -> (id: UUID, versions: [SyncRecordVersion]) {
        var domain = try domain(name)
        var sources: [UUID: SyncAttachmentSource] = [:]
        var restorePaths: [UUID: String] = [:]
        if attachment {
            let bytes = Data("retained photograph".utf8)
            let source = paths.staging.appendingPathComponent(UUID().uuidString)
            try bytes.write(to: source)
            let owner = domain.rootIDs.first!
            let version = try SyncAttachmentVersion.issuing(slot: .init(owner: owner, role: "project-photo", slotID: "cover"),
                contentSHA256: Data(SHA256.hash(data: bytes)), byteCount: Int64(bytes.count), mediaType: "image/jpeg", displayFilename: "cover.jpg")
            let stamp = SyncMutationStamp(logicalRevision: 1, modifiedAt: Date(timeIntervalSince1970: 1), deviceID: "fixture")
            let record = SyncRecord(schemaVersion: 1, id: .init(kind: .attachment, uuid: version.versionID), createdAt: stamp.modifiedAt,
                entityRevision: 1, payload: .init(fields: [:], attachment: version), relationships: [.init(role: "owner", target: owner)],
                deletedAt: .init(value: nil, stamp: stamp))
            domain = .init(rootIDs: domain.rootIDs, ownedRecords: domain.ownedRecords + [record], supportingParentIDs: [], removedReminders: [:])
            sources[version.versionID] = try .init(fileURL: source, contentSHA256: version.contentSHA256, byteCount: version.byteCount)
            restorePaths[version.versionID] = "photos/cover.jpg"
        }
        let versions = try domain.ownedRecords.map { record in
            var deleted = record
            deleted.deletedAt = .init(value: Date(timeIntervalSince1970: 100), stamp: .init(logicalRevision: 100, modifiedAt: Date(timeIntervalSince1970: 100), deviceID: "fixture"))
            return try SyncRecordVersion(record: deleted)
        }
        let id = try ledger.stage(domain: domain, attachments: sources, restoreRelativePaths: restorePaths, deletedAt: Date(timeIntervalSince1970: 100))
        let witness = Data(repeating: 3, count: 32)
        try ledger.prepare(id: id, beforeArchiveSHA256: Data(repeating: 1, count: 32), afterArchiveSHA256: Data(repeating: 2, count: 32), exactRemovalVersions: versions, publicationSHA256: witness)
        try ledger.activate(id: id, publicationSHA256: witness)
        return (id, versions)
    }
    func remove() { try? storage.close(); try? FileManager.default.removeItem(at: base) }
}
