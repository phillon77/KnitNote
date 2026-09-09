import Darwin
import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct SyncBootstrapSourceAccessTests {
    @Test func verifiedFreshAbsenceDoesNotCreateArchiveOrJournal() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let before = try f.source.capture(), disk = try f.source.diskBytes()
        let value = try SyncBootstrapSourceAccess(storage: f.source.storage, paths: f.source.paths,
            account: f.source.account, maximumBytes: 100_000_000).capture(deviceID: "source-access-test")
        #expect(value.local == nil)
        #expect(value.archive.projects.isEmpty)
        #expect(value.pending == nil)
        let after = try f.source.capture()
        #expect(after.entries == before.entries)
        #expect(after.packet.mutations == before.packet.mutations)
        #expect(try f.source.diskBytes() == disk)
    }

    @Test(arguments: [false, true])
    func realArchiveAndNativeJournalRemainReadOnly(emptyJournal: Bool) throws {
        let f = try OwnedMatrixFixture(legacyJournal: !emptyJournal, media: false); defer { f.remove() }
        if emptyJournal {
            let mutation = OwnedMatrixFixture.mutation(1)
            try f.journal.enqueue([mutation])
            try f.journal.acknowledge(recordID: mutation.recordID, mutationID: mutation.mutationID)
        }
        let before = try OwnedMatrixFixture.files(f.paths.accountRoot)
        let value = try SyncBootstrapSourceAccess(storage: f.storage, paths: f.paths,
            account: f.account, maximumBytes: 100_000_000).capture(deviceID: "matrix")
        #expect(value.archive.projects.map(\.id) == f.archive.projects.map(\.id))
        #expect(value.local?.records == f.local?.records)
        let pending = try f.journal.recoverySnapshot().mutations
        #expect(value.pending?.mutations == pending)
        // The returned fingerprint must actually be accepted by owned planning.
        _ = try f.transaction().plan(.init(local: value.local, sourceArchive: value.archive,
            remote: f.input().remote, pending: value.pending, counterReminderContext: value.counterReminderContext))
        #expect(try OwnedMatrixFixture.files(f.paths.accountRoot) == before)
    }

    @Test func restoredPendingPayloadAndDeletionSourceRetainExactFIFO() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        let deleted = try f.addDeletion(ledger: ledger, name: "Retained", attachment: true)
        let native = FileSyncMutationJournal(url: f.paths.mutationJournalURL)
        try native.enqueue(deleted.versions.map { try SyncMutation.save(recordVersion: $0, mutationID: UUID()) })
        _ = try f.makeMissingArchiveRollback(withMedia: true)
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: OwnedBootstrapTestKeys())
        let recovery = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: vault, journal: native)
        let now = Date(), sealed = try recovery.seal(recovery.prepare(now: now), now: now)
        try recovery.cleanup(sealed); try recovery.restore(vaultID: sealed.vaultID, now: now)
        #expect(try recovery.consumeRestoredSelection(vaultID: sealed.vaultID, now: now))
        let pending = try native.recoverySnapshot().mutations
        let before = try f.diskBytes()
        let value = try SyncBootstrapSourceAccess(storage: f.storage, paths: f.paths, account: f.account,
            maximumBytes: 100_000_000).capture(deviceID: "restored")
        #expect(value.local == nil)
        #expect(value.pending?.mutations == pending)
        #expect(pending.contains { $0.attachmentSource != nil })
        #expect(pending.contains { $0.savedRecordVersion?.record.deletedAt.value != nil })
        #expect(try f.diskBytes() == before)
    }

    @Test(arguments: ["archive", "foreign-control", "next", "fifo", "watch-prepared", "watch-ledger", "watch-alias"])
    func corruptOrUnresolvedEvidenceIsRejectedWithoutWrites(damage: String) throws {
        let f = try OwnedMatrixFixture(media: false); defer { f.remove() }
        if damage == "archive" { try Data("corrupt".utf8).write(to: f.paths.workingSet.appendingPathComponent("projects-v1.json")) }
        else if damage == "fifo" { #expect(mkfifo(f.paths.workingSet.appendingPathComponent("unsafe").path, 0o600) == 0) }
        else if damage.hasPrefix("watch-") {
            let url = damage == "watch-alias" ? f.paths.workingSet.appendingPathComponent("PREPARED-WATCH-COMMAND.JSON")
                : damage == "watch-prepared" ? WatchSyncPaths.preparedCommand(in: f.paths.workingSet)
                    : WatchSyncPaths.processedLedger(in: f.paths.workingSet)
            try Data("corrupt".utf8).write(to: url)
        } else {
            let control = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1")
            try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
            try Data("foreign".utf8).write(to: control.appendingPathComponent(damage == "next" ? "intent-next.json" : "intent.json"))
        }
        let before = try OwnedMatrixFixture.files(f.paths.accountRoot)
        #expect(throws: (any Error).self) {
            try SyncBootstrapSourceAccess(storage: f.storage, paths: f.paths, account: f.account,
                maximumBytes: 100_000_000).capture(deviceID: "rejected")
        }
        #expect(try OwnedMatrixFixture.files(f.paths.accountRoot) == before)
    }

    @Test(arguments: [false, true])
    func validButForeignOrUnresolvedSourceControlCannotIssueSnapshot(derivative: Bool) throws {
        let f = try SourceInventoryFixture(); defer { f.remove() }
        let other = try SourceInventoryFixture(); defer { other.remove() }
        let main = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        if derivative {
            let bytes = try Data(contentsOf: main)
            let state = try SyncAccountRecoveryControlFile.decode(bytes)
            let next = try SyncAccountRecoveryControlFile.encode(state, predecessorSHA256: OwnedBootstrapCodec.hash(bytes))
            try next.write(to: main.deletingLastPathComponent().appendingPathComponent("intent-next.json"))
        } else {
            try Data(contentsOf: other.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")).write(to: main)
        }
        let before = try f.diskBytes()
        #expect(throws: (any Error).self) {
            try SyncBootstrapSourceAccess(storage: f.storage, paths: f.paths, account: f.account,
                maximumBytes: 100_000_000).capture(deviceID: "rejected")
        }
        #expect(try f.diskBytes() == before)
    }

    @Test func nativeWatchMetadataIsPreservedInMergeContext() throws {
        let f = try OwnedMatrixFixture(media: false); defer { f.remove() }
        let command = WatchCounterCommand(id: UUID(), projectID: UUID(), counterID: UUID(), operation: .increment,
            createdAt: Date(timeIntervalSince1970: 40))
        let prepared = PreparedWatchCommand(command: command, expectedCounterRevision: 2, expectedCounterValue: 1)
        let ledger = ProcessedWatchCommandLedger(entries: [.init(id: UUID(), processedAt: Date(timeIntervalSince1970: 41),
            rejection: nil)], requiresFreshHandshake: true)
        try AtomicWatchSyncFile<PreparedWatchCommand>(url: WatchSyncPaths.preparedCommand(in: f.paths.workingSet)).save(prepared)
        try AtomicWatchSyncFile<ProcessedWatchCommandLedger>(url: WatchSyncPaths.processedLedger(in: f.paths.workingSet)).save(ledger)
        let before = try OwnedMatrixFixture.files(f.paths.accountRoot)
        let value = try SyncBootstrapSourceAccess(storage: f.storage, paths: f.paths, account: f.account,
            maximumBytes: 100_000_000).capture(deviceID: "watch")
        #expect(value.counterReminderContext.preparedCommands == [prepared])
        #expect(value.counterReminderContext.processedLedger == ledger)
        #expect(try OwnedMatrixFixture.files(f.paths.accountRoot) == before)
    }

    @Test(arguments: ["valid", "absent-head-retained-history", "corrupt", "alias", "head-alias", "root-alias", "missing-record"])
    func nativeAttachmentEvidenceWithoutLockNeverCreatesOne(damage: String) throws {
        let f = try OwnedMatrixFixture(media: true); defer { f.remove() }
        let records = try #require(f.local).records.filter { $0.payload.attachment != nil }
        try #require(!records.isEmpty)
        let head = f.paths.workingSet.appendingPathComponent("SyncMetadata/attachment-versions.json")
        let historicalCommand = WatchCounterCommand(id: UUID(), projectID: UUID(), counterID: UUID(), operation: .increment,
            createdAt: Date(timeIntervalSince1970: 71))
        let historicalProof = try SyncProcessedWatchCommandProof(id: historicalCommand.id, rejection: .projectMissing,
            commandIdentity: .init(historicalCommand), preparedCommand: nil, effectProof: nil,
            processingStamp: .init(logicalRevision: 0, modifiedAt: Date(timeIntervalSince1970: 72), deviceID: "retained-watch-history"))
        try SyncAttachmentPublicationEvidenceFile(url: head).save(.init(versions: records.compactMap(\.payload.attachment),
            watchCommandProofs: damage == "absent-head-retained-history" ? [historicalProof] : [],
            attachmentRecords: damage == "missing-record" ? [] : records))
        let lock = head.deletingLastPathComponent().appendingPathComponent(".attachment-versions.json.lock")
        try FileManager.default.removeItem(at: lock)
        let root = head.deletingPathExtension().appendingPathExtension("attachment-records")
        let proof = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.first { $0.pathExtension == "json" })
        var retainedWatch: ProcessedWatchCommandLedger?
        if damage == "absent-head-retained-history" {
            try FileManager.default.removeItem(at: head)
            let ledger = ProcessedWatchCommandLedger(entries: [.init(id: UUID(), processedAt: Date(timeIntervalSince1970: 73), rejection: nil)], requiresFreshHandshake: true)
            try AtomicWatchSyncFile<ProcessedWatchCommandLedger>(url: WatchSyncPaths.processedLedger(in: f.paths.workingSet)).save(ledger)
            retainedWatch = ledger
        }
        if damage == "corrupt" { try Data("broken authority".utf8).write(to: proof) }
        if damage == "alias" {
            try FileManager.default.moveItem(at: proof, to: proof.deletingLastPathComponent()
                .appendingPathComponent(proof.deletingPathExtension().lastPathComponent.uppercased() + ".json"))
        }
        if damage == "head-alias" {
            try FileManager.default.moveItem(at: head, to: head.deletingLastPathComponent()
                .appendingPathComponent(head.lastPathComponent.uppercased()))
        }
        if damage == "root-alias" {
            try FileManager.default.moveItem(at: root, to: root.deletingLastPathComponent()
                .appendingPathComponent(root.lastPathComponent.uppercased()))
        }
        let before = try OwnedMatrixFixture.files(f.paths.accountRoot)
        let access = SyncBootstrapSourceAccess(storage: f.storage, paths: f.paths, account: f.account, maximumBytes: 100_000_000)
        if damage == "valid" || damage == "absent-head-retained-history" {
            var value: SyncBootstrapSourceSnapshot?
            #expect(throws: Never.self) { value = try access.capture(deviceID: "matrix") }
            #expect(value?.local?.records.filter { $0.payload.attachment != nil } == records)
            if let retainedWatch {
                #expect(value?.counterReminderContext.processedLedger == retainedWatch)
                #expect(value?.local?.records.contains { $0.id.kind == .watchCommandProof && $0.id.uuid == historicalCommand.id } == true)
                #expect(!FileManager.default.fileExists(atPath: head.path))
                #expect(FileManager.default.fileExists(atPath: proof.path))
                #expect(before.keys.contains { $0.contains("attachment-versions.watch-proofs/") && $0.hasSuffix(".json") })
            }
        } else { #expect(throws: (any Error).self) { try access.capture(deviceID: "matrix") } }
        #expect(!FileManager.default.fileExists(atPath: lock.path))
        #expect(try OwnedMatrixFixture.files(f.paths.accountRoot) == before)
    }
}
