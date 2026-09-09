import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct SyncBootstrapOwnedHandoffTests {
    // Catches a committed owner validating its files but failing to issue the
    // native capability needed to adopt the canonical archive.
    @Test(arguments: [false, true]) func committedRecoveryIssuesCanonicalAuthority(newFreeze: Bool) throws {
        let f = try OwnedMatrixFixture(media: false); defer { f.remove() }
        let tx = try f.transaction(), token = try tx.prepare(f.input())
        try tx.install(token); _ = try tx.commit(token)
        let current = newFreeze ? SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID()) : f.context
        let owner = try f.transaction(context: current)
        let recovered = try #require(try owner.recover())
        #expect(recovered.transactionID == token.transactionID)
        #expect(recovered.accountIDHash == f.account.accountIDHash)
        let archive = try JSONDecoder().decode(ProjectArchive.self,
            from: Data(contentsOf: recovered.liveRoot.appendingPathComponent("projects-v1.json")))
        #expect(archive.projects.map(\.name) == ["Matrix source"])
        #expect(recovered.checkpoint.records.contains { $0.payload.fields["name"]?.value == .string("Matrix source") })
        try recovered.revalidate()
    }

    @Test(arguments: ["selector", "receipt", "checkpoint", "archive", "authority", "original", "asset", "root", "stale", "control"])
    func issuedAuthorityRejectsChangedImmutableEvidence(damage: String) throws {
        let f = try OwnedMatrixFixture(media: damage == "asset"); defer { f.remove() }
        var current = true
        let tx = try SyncBootstrapOwnedTransaction(storage: f.storage, paths: f.paths, account: f.account,
            context: f.context, validateContext: { _ in guard current else { throw SyncBootstrapError.contextChanged } })
        let prepared = try tx.prepare(f.input()); try tx.install(prepared); _ = try tx.commit(prepared)
        let handoff = try #require(try tx.recover())
        if damage == "stale" { current = false }
        else if damage == "root" {
            let old = f.paths.accountRoot.appendingPathComponent("former-working-set")
            try FileManager.default.moveItem(at: f.paths.workingSet, to: old)
            try FileManager.default.copyItem(at: old, to: f.paths.workingSet)
        } else {
            let url: URL
            switch damage {
            case "control": url = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
            case "selector": url = f.namespace.appendingPathComponent("active.json")
            case "receipt": url = f.paths.workingSet.appendingPathComponent("SyncMetadata/bootstrap-receipt.json")
            case "checkpoint": url = f.paths.workingSet.appendingPathComponent("SyncMetadata/bootstrap-canonical.json")
            case "archive": url = f.paths.workingSet.appendingPathComponent("projects-v1.json")
            case "authority": url = f.paths.workingSet.appendingPathComponent("SyncMetadata/revision-ledger.unexpected")
            case "original": url = prepared.originalBackupRoot.appendingPathComponent("projects-v1.json")
            default:
                let version = try #require(handoff.checkpoint.records.compactMap(\.payload.attachment).first)
                let source = try #require(try handoff.stagedAttachmentSource(version))
                url = source.fileURL
            }
            if damage == "control" {
                let other = try OwnedBootstrapFixture(); defer { other.remove() }
                try Data(contentsOf: other.source.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")).write(to: url)
            } else { try Data("changed retained evidence".utf8).write(to: url) }
        }
        #expect(throws: (any Error).self) { try handoff.revalidate() }
        #expect(throws: (any Error).self) { _ = try tx.recover() }
    }

    @Test func retainedHistoryCannotBeChangedAfterCapabilityIssuance() throws {
        let f = try OwnedMatrixFixture(media: false); defer { f.remove() }
        let abandoned = try f.transaction(); _ = try abandoned.prepare(f.input()); _ = try abandoned.recover()
        let tx = try f.transaction(), prepared = try tx.prepare(f.input())
        try tx.install(prepared); _ = try tx.commit(prepared)
        let handoff = try #require(try tx.recover())
        let history = try #require(FileManager.default.enumerator(at: f.namespace.appendingPathComponent("History"),
            includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.first { $0.pathExtension == "json" })
        try Data("changed history".utf8).write(to: history)
        #expect(throws: (any Error).self) { try handoff.revalidate() }
        #expect(throws: (any Error).self) { try tx.recover() }
    }

    @Test func dailyJournalEvolutionDoesNotRevokeUnchangedBootstrapAuthority() throws {
        let f = try OwnedMatrixFixture(media: true); defer { f.remove() }
        let tx = try f.transaction(), prepared = try tx.prepare(f.input())
        try tx.install(prepared); _ = try tx.commit(prepared)
        let handoff = try #require(try tx.recover())
        let before = try f.journal.pending()
        for mutation in before { try f.journal.acknowledge(recordID: mutation.recordID, mutationID: mutation.mutationID) }
        try handoff.revalidate()
        #expect(try f.journal.pending().isEmpty)
        let version = try #require(handoff.checkpoint.records.compactMap(\.payload.attachment).first)
        let source = try #require(try handoff.stagedAttachmentSource(version))
        #expect(try Data(contentsOf: source.fileURL).count == version.byteCount)
    }
}
