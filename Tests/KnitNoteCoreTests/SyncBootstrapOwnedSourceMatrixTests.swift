import Foundation
import Testing
@testable import KnitNoteCore

@Suite(.serialized) struct SyncBootstrapOwnedSourceMatrixTests {
    @Test func archiveAppearingAfterPreparingCannotBecomeSelectedSource() throws {
        let f = try OwnedMatrixFixture(missing: true, media: false); defer { f.remove() }
        var changed: [String: Data]?, hit = false
        let failing = try f.transaction(boundary: { point in
            if point == .afterPreparingPublication {
                hit = true
                try JSONEncoder().encode(f.archive).write(to: f.paths.workingSet.appendingPathComponent("projects-v1.json"))
                changed = try OwnedMatrixFixture.files(f.paths.accountRoot)
            }
        })
        #expect(throws: (any Error).self) { try failing.prepare(f.input()) }
        #expect(hit)
        #expect(try OwnedMatrixFixture.files(f.paths.accountRoot) == changed)
        let selected = try OwnedMatrixFixture.manifest(f.paths, account: f.account)
        guard case .preparing = selected.body else { Issue.record("appeared archive certified"); return }
        #expect(!FileManager.default.fileExists(atPath: f.paths.accountRoot.appendingPathComponent(selected.transactionRelativePath).path))
        #expect(throws: (any Error).self) { try f.transaction().recover() }
        #expect(try OwnedMatrixFixture.files(f.paths.accountRoot) == changed)
    }

    @Test(arguments: ["pending-order", "pending-payload", "archive-remove", "archive-directory", "archive-bytes", "live-root-inode", "selected-attachment"])
    func changedRealSourceAfterPreparingBarrierCannotIssueOutputs(change: String) throws {
        let f = try OwnedMatrixFixture(legacyJournal: true, media: change == "selected-attachment")
        defer { f.remove() }
        let input = try f.input()
        var changed: [String: Data]?, hit = false
        let tx = try f.transaction(boundary: { point in
            guard point == .afterPreparingPublication else { return }
            hit = true
            let archive = f.paths.workingSet.appendingPathComponent("projects-v1.json")
            switch change {
            case "pending-order", "pending-payload":
                struct Envelope: Encodable { let version = 1; let checkpoint: Data; let checksum: Data }
                let initial = try f.journal.recoverySnapshot().mutations
                let pending = change == "pending-order" ? Array(initial.reversed()) : [OwnedMatrixFixture.mutation(303)] + initial.dropFirst()
                #expect(pending != initial)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(SyncJournalCheckpoint(version: 1, throughSequence: 0, pending: pending))
                try encoder.encode(Envelope(checkpoint: data, checksum: OwnedBootstrapCodec.hash(data)))
                    .write(to: f.paths.mutationJournalURL.appendingPathExtension("checkpoint"))
                #expect(try f.journal.recoverySnapshot().mutations == pending)
            case "archive-remove": try FileManager.default.removeItem(at: archive)
            case "archive-directory":
                try FileManager.default.moveItem(at: archive, to: f.root.appendingPathComponent("held-archive.json"))
                try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
            case "archive-bytes": try Data("changed canonical archive".utf8).write(to: archive)
            case "live-root-inode":
                let held = f.root.appendingPathComponent("held-live")
                try FileManager.default.moveItem(at: f.paths.workingSet, to: held)
                try FileManager.default.copyItem(at: held, to: f.paths.workingSet)
            case "selected-attachment":
                let source = try #require(f.local?.attachments.values.first)
                try Data(repeating: 0x58, count: Int(source.byteCount)).write(to: source.fileURL)
            default: throw OwnedFixtureFailure.injected
            }
            changed = try OwnedMatrixFixture.files(f.paths.accountRoot)
        })
        #expect(throws: (any Error).self) { try tx.prepare(input) }
        #expect(hit)
        #expect(try OwnedMatrixFixture.files(f.paths.accountRoot) == changed)
        let selected = try OwnedMatrixFixture.manifest(f.paths, account: f.account)
        guard case .preparing = selected.body else { Issue.record("changed source was incorrectly certified"); return }
        #expect(!FileManager.default.fileExists(atPath: f.paths.accountRoot.appendingPathComponent(selected.transactionRelativePath).path))
        if change == "live-root-inode" {
            // The live inode is pinned within the executing issuer and later
            // persisted by prepared, not by this portable preparing source.
            let live = try OwnedMatrixFixture.files(f.paths.workingSet)
            _ = try f.transaction().recover()
            let terminal = try OwnedMatrixFixture.manifest(f.paths, account: f.account)
            guard case let .abortedPreparation(abort) = terminal.body else {
                Issue.record("recover did not freeze the exact empty abort"); return
            }
            #expect(abort.frozenOutputEntries.isEmpty)
            #expect(try OwnedMatrixFixture.files(f.paths.workingSet) == live)
            #expect(!FileManager.default.fileExists(atPath: f.paths.accountRoot.appendingPathComponent(selected.transactionRelativePath).path))
        } else {
            #expect(throws: (any Error).self) { try f.transaction().recover() }
            #expect(try OwnedMatrixFixture.files(f.paths.accountRoot) == changed)
        }
    }

    @Test func selectedRetainedDeletionMutationRejectsAtPreparingBarrier() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        let deleted = try f.addDeletion(ledger: ledger, name: "selected retained source", attachment: true)
        try FileSyncMutationJournal(url: f.paths.mutationJournalURL).enqueue(deleted.versions.map {
            try SyncMutation.save(recordVersion: $0, mutationID: UUID())
        })
        let journal = try f.makeMissingArchiveRollback(withMedia: false)
        let context = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let healthy = try SyncBootstrapOwnedTransaction(storage: f.storage, paths: f.paths, account: f.account,
            context: context, validateContext: { #expect($0 == context) })
        _ = try healthy.recover()
        let captured = try SyncAccountRecoveryInventory.capture(storage: f.storage, paths: f.paths, account: f.account,
            journal: journal, archiveURL: f.archiveURL)
        let file = try #require(captured.deletionFiles.first)
        let selected = f.paths.accountRoot.appendingPathComponent(file.relativePath)
        let ordinary = try SyncBootstrapTransaction(liveRoot: f.paths.workingSet, context: context, validateContext: { _ in })
        let input = try SyncBootstrapOwnedInput(local: nil, sourceArchive: .init(version: ProjectArchive.currentVersion, projects: []),
            remote: .init(context: context, records: [], attachments: [:], isComplete: true),
            pending: .init(mutations: journal.recoverySnapshot().mutations, sourceTreeFingerprint: ordinary.sourceFingerprint()),
            counterReminderContext: .init())
        var changed: [String: Data]?, hit = false
        let failing = try SyncBootstrapOwnedTransaction(storage: f.storage, paths: f.paths, account: f.account,
            context: context, validateContext: { #expect($0 == context) }, boundary: { point in
                if point == .afterPreparingPublication {
                    hit = true
                    try Data(repeating: 0x58, count: file.bytes.count).write(to: selected)
                    changed = try f.diskBytes()
                }
            })
        #expect(throws: (any Error).self) { try failing.prepare(input) }
        #expect(hit)
        #expect(try f.diskBytes() == changed)
        let manifest = try OwnedMatrixFixture.manifest(f.paths, account: f.account)
        guard case .preparing = manifest.body else { Issue.record("changed retained source certified"); return }
        #expect(!FileManager.default.fileExists(atPath: f.paths.accountRoot.appendingPathComponent(manifest.transactionRelativePath).path))
        #expect(throws: (any Error).self) { try healthy.recover() }
        #expect(try f.diskBytes() == changed)
    }

    @Test(arguments: [false, true])
    func expiredVaultCannotIssueSourceButDurableHandoffSurvives(consumed: Bool) throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let vault = SyncRecoveryVault(directory: f.source.paths.vault, keychain: OwnedBootstrapTestKeys())
        let recovery = SyncAccountRecoveryTransaction(storage: f.source.storage, paths: f.source.paths,
            account: f.source.account, vault: vault, journal: f.source.journal)
        let now = Date(), later = now.addingTimeInterval(366 * 24 * 60 * 60)
        let sealed = try recovery.seal(recovery.prepare(now: now), now: now)
        try recovery.cleanup(sealed); try recovery.restore(vaultID: sealed.vaultID, now: now)
        if consumed { #expect(try recovery.consumeRestoredSelection(vaultID: sealed.vaultID, now: now)) }
        let before = try f.source.diskBytes()
        if consumed {
            #expect(try recovery.consumeRestoredSelection(vaultID: sealed.vaultID, now: later))
            _ = try f.transaction(now: later).plan(f.input())
        } else {
            #expect(throws: (any Error).self) { try recovery.consumeRestoredSelection(vaultID: sealed.vaultID, now: later) }
            #expect(throws: (any Error).self) { try f.transaction(now: later).prepare(f.input()) }
        }
        #expect(try f.source.diskBytes() == before)
        #expect(!FileManager.default.fileExists(atPath: f.namespace.path))
    }
}
