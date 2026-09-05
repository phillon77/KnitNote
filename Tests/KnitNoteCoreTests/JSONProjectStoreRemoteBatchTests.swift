import Foundation
import Testing
@testable import KnitNoteCore

@MainActor
struct JSONProjectStoreRemoteBatchTests {
    enum Fault: Error { case injected }
    @Test func partialDownloadPreservesUnrelatedCanonicalAndDoesNotUpload() throws {
        let f = try RemoteBatchFixture(); defer { f.remove() }
        try f.acknowledgeBootstrap()
        let before = try #require(try f.checkpoints.load())
        let batch = try f.renamedBatch("Remote", id: UUID())
        let p = try f.store.prepareRemoteBatch(batch, attachmentSources: [:])
        guard case .committed = try f.store.commitRemoteBatch(p) else { Issue.record("Expected commit"); return }
        let after = try #require(try f.checkpoints.load())
        #expect(after.records.filter { $0.id != batch.records[0].id } == before.records.filter { $0.id != batch.records[0].id })
        #expect(f.store.project(id: f.projectID)?.name == "Remote")
        #expect(try f.journal.pending().isEmpty)
    }

    @Test func localEditMakesPreparationStaleWithoutChangingAuthorities() throws {
        let f = try RemoteBatchFixture(); defer { f.remove() }
        let p = try f.store.prepareRemoteBatch(f.renamedBatch("Remote", id: UUID()), attachmentSources: [:])
        try f.renameLocally("Local")
        let archive = try Data(contentsOf: f.archiveURL)
        let canonical = try f.checkpoints.load()
        let pending = try f.journal.pending()
        #expect(try f.store.commitRemoteBatch(p) == .stalePredecessor)
        #expect(try Data(contentsOf: f.archiveURL) == archive)
        #expect(try f.checkpoints.load() == canonical)
        #expect(try f.journal.pending() == pending)
    }

    @Test func ackChangesPredecessor() throws {
        let f = try RemoteBatchFixture(); defer { f.remove() }
        let p = try f.store.prepareRemoteBatch(f.renamedBatch("Remote", id: UUID()), attachmentSources: [:])
        try f.acknowledgeBootstrap()
        let bytes = try Data(contentsOf: f.archiveURL)
        #expect(try f.store.commitRemoteBatch(p) == .stalePredecessor)
        #expect(try Data(contentsOf: f.archiveURL) == bytes)
        #expect(try f.journal.pending().isEmpty)
    }

    @Test(arguments: ["processed-watch-commands.json", "SyncMetadata/attachment-versions.json"])
    func changedDurableAuthorityMakesCandidateStale(path: String) throws {
        let f = try RemoteBatchFixture(); defer { f.remove() }
        let p = try f.store.prepareRemoteBatch(f.renamedBatch("Remote", id: UUID()), attachmentSources: [:])
        let authority = f.root.appendingPathComponent("Live/" + path)
        try Data("changed authority".utf8).write(to: authority)
        let bytes = try Data(contentsOf: f.archiveURL)
        #expect(try f.store.commitRemoteBatch(p) == .stalePredecessor)
        #expect(try Data(contentsOf: f.archiveURL) == bytes)
    }

    @Test func redeliveryAfterLaterEditDoesNotRollbackOrNotify() throws {
        let f = try RemoteBatchFixture(); defer { f.remove() }
        try f.acknowledgeBootstrap()
        var notifications: [UUID] = []
        f.store.onRemoteDomainCommitted = {
            notifications.append($0)
            #expect((try? f.journal.pending()) != nil)
        }
        let batch = try f.renamedBatch("Remote", id: UUID())
        let p = try f.store.prepareRemoteBatch(batch, attachmentSources: [:])
        guard case let .committed(receipt) = try f.store.commitRemoteBatch(p) else { Issue.record("Expected commit"); return }
        try f.renameLocally("Later")
        let pending = try f.journal.pending()
        #expect(try f.store.commitRemoteBatch(p) == .alreadyCommitted(receipt))
        #expect(f.store.project(id: f.projectID)?.name == "Later")
        #expect(try f.journal.pending() == pending)
        #expect(notifications == [receipt.commitID])
        #expect(throws: SyncRemoteBatchError.identityCollision) {
            try f.store.prepareRemoteBatch(f.renamedBatch("Collision", id: batch.identity.batchID), attachmentSources: [:])
        }
    }

    @Test func metadataOnlyReceiptAndProvenRetirementDoNotNotify() throws {
        let f = try RemoteBatchFixture(); defer { f.remove() }
        try f.acknowledgeBootstrap()
        var notifications = 0
        f.store.onRemoteDomainCommitted = { _ in notifications += 1 }
        let batch = try f.batch(records: [], id: UUID())
        let p = try f.store.prepareRemoteBatch(batch, attachmentSources: [:])
        let generation = f.store.dataGeneration
        guard case let .committed(receipt) = try f.store.commitRemoteBatch(p) else { Issue.record("Expected commit"); return }
        #expect(!receipt.domainChanged)
        #expect(f.store.dataGeneration == generation)
        let before = try f.checkpoints.load()
        #expect(throws: Fault.injected) { try f.store.retireRemoteBatchReceipt(batch.identity) { throw Fault.injected } }
        #expect(try f.checkpoints.load() == before)
        var verified = 0
        try f.store.retireRemoteBatchReceipt(batch.identity) { verified += 1 }
        #expect(verified == 2)
        #expect(try f.checkpoints.load()?.remoteBatchReceipts.isEmpty == true)
        #expect(notifications == 0)
    }

    @Test(arguments: [SyncCanonicalPublicationBoundary.afterIntent, .afterArchive, .afterJournal, .afterCheckpoint])
    func interruptedCommitReopensWithExactReceipt(boundary: SyncCanonicalPublicationBoundary) throws {
        let f = try RemoteBatchFixture { if $0 == boundary { throw Fault.injected } }
        defer { f.remove() }
        try f.acknowledgeBootstrap()
        let batch = try f.renamedBatch("Recovered", id: UUID())
        let p = try f.store.prepareRemoteBatch(batch, attachmentSources: [:])
        #expect(throws: (any Error).self) { try f.store.commitRemoteBatch(p) }
        let first = try f.reopen()
        let receipt = try #require(try f.checkpoints.load()?.remoteBatchReceipts.first)
        #expect(first.project(id: f.projectID)?.name == "Recovered")
        let second = try f.reopen()
        let replay = try second.prepareRemoteBatch(batch, attachmentSources: [:])
        #expect(try second.commitRemoteBatch(replay) == .alreadyCommitted(receipt))
        #expect(try f.journal.pending().isEmpty)
    }

    @Test func recoveryRefusesUnrelatedArchiveAfterIntent() throws {
        let f = try RemoteBatchFixture { if $0 == .afterIntent { throw Fault.injected } }
        defer { f.remove() }
        let p = try f.store.prepareRemoteBatch(f.renamedBatch("Remote", id: UUID()), attachmentSources: [:])
        #expect(throws: (any Error).self) { try f.store.commitRemoteBatch(p) }
        let unrelated = Data("unrelated archive authority".utf8)
        try unrelated.write(to: f.archiveURL)
        #expect(throws: (any Error).self) { try f.reopen() }
        #expect(try Data(contentsOf: f.archiveURL) == unrelated)
        #expect(try SyncPublicationTransactionFile(archiveURL: f.archiveURL).load() != nil)
    }

    @Test func recoveryRefusesChangedWatchAuthorityAfterIntent() throws {
        let f = try RemoteBatchFixture { if $0 == .afterIntent { throw Fault.injected } }
        defer { f.remove() }
        let p = try f.store.prepareRemoteBatch(f.renamedBatch("Remote", id: UUID()), attachmentSources: [:])
        #expect(throws: (any Error).self) { try f.store.commitRemoteBatch(p) }
        let archive = try Data(contentsOf: f.archiveURL)
        try AtomicWatchSyncFile<ProcessedWatchCommandLedger>(url: WatchSyncPaths.processedLedger(in: f.root.appendingPathComponent("Live")))
            .save(.init())
        #expect(throws: (any Error).self) { try f.reopen() }
        #expect(try Data(contentsOf: f.archiveURL) == archive)
        #expect(try SyncPublicationTransactionFile(archiveURL: f.archiveURL).load() != nil)
    }

    @Test func expiredLeaseCannotReadOrWrite() throws {
        let f = try RemoteBatchFixture(); defer { f.remove() }
        var escaped: SyncJournalWriteLease?
        try f.journal.withExclusivePending { escaped = $0 }
        let lease = try #require(escaped)
        #expect(throws: SyncMutationJournalError.corrupt) { try lease.pending() }
        #expect(throws: SyncMutationJournalError.corrupt) { try lease.enqueue([]) }
    }

    @Test func durableDeletionMarkersBlockIncomingAfterJournalACK() throws {
        let f = try RemoteBatchFixture(); defer { f.remove() }
        let incoming = try f.renamedBatch("Resurrect", id: UUID())
        try f.store.delete(id: f.projectID)
        let ledger = try SyncDeletionLedger(root: SyncDeletionLedger.root(archiveURL: f.archiveURL))
        let entry = try #require(try ledger.recentlyDeleted().first)
        let ack = Set(entry.exactRemovalVersions.map(\.versionID))
        try f.acknowledgeBootstrap()
        try f.store.purgeRecentlyDeleted(now: entry.deletedAt.addingTimeInterval(2_592_000), acknowledgedVersions: ack) {
            .init(acknowledgedRemovalVersionIDs: ack)
        }
        let markers = try SyncDeletionLedger.remoteBatchMarkers(archiveURL: f.archiveURL)
        #expect(markers.contains { $0.targetID == .init(kind: .project, uuid: f.projectID) })
        #expect(try f.journal.pending().isEmpty)
        let archive = try Data(contentsOf: f.archiveURL)
        #expect(throws: (any Error).self) { try f.store.prepareRemoteBatch(incoming, attachmentSources: [:]) }
        #expect(try Data(contentsOf: f.archiveURL) == archive)
        #expect(f.store.project(id: f.projectID) == nil)
    }

    @Test func freshRemoteTombstoneWithoutRetentionAuthorityIsRejected() throws {
        let f = try RemoteBatchFixture(); defer { f.remove() }
        let original = try #require(f.records.first { $0.id.kind == .project })
        let tombstone = SyncRecord(schemaVersion: original.schemaVersion,
            id: .init(kind: .project, uuid: UUID()), createdAt: original.createdAt,
            entityRevision: original.entityRevision, payload: original.payload,
            relationships: original.relationships, deletedAt: .init(value: .now, stamp: original.deletedAt.stamp))
        let batch = try f.batch(records: [tombstone], id: UUID())
        #expect(throws: SyncRemoteBatchError.unprovenDeletion) {
            _ = try f.store.prepareRemoteBatch(batch, attachmentSources: [:])
        }
        #expect(try f.checkpoints.load()?.remoteBatchReceipts.isEmpty == true)
    }
}
