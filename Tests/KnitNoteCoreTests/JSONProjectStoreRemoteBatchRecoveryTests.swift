import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

@MainActor
struct JSONProjectStoreRemoteBatchRecoveryTests {
    private enum Fault: Error { case injected }
    private final class WeakBox<Value: AnyObject> {
        weak var value: Value?

        init(_ value: Value) {
            self.value = value
        }
    }

    @Test(arguments: SyncCanonicalPublicationBoundary.allCases)
    func everyPublicationBoundaryRecoversTheRetainedRemoteCandidateExactly(
        boundary: SyncCanonicalPublicationBoundary
    ) throws {
        var fired = false
        let fixture = try RemoteBatchFixture { reached in
            if reached == boundary, !fired {
                fired = true
                throw Fault.injected
            }
        }
        defer { fixture.remove() }

        let predecessor = try #require(try fixture.checkpoints.load())
        let predecessorArchive = try Data(contentsOf: fixture.archiveURL)
        let originalPending = try fixture.journal.pending()
        let batch = try fixture.renamedBatch("Recovered exactly", id: UUID())
        let prepared = try fixture.store.prepareRemoteBatch(batch, attachmentSources: [:])

        #expect(throws: (any Error).self) {
            try fixture.store.commitRemoteBatch(prepared)
        }
        #expect(fired)

        let retained = try #require(
            try SyncPublicationTransactionFile(archiveURL: fixture.archiveURL).load()
        )
        let candidate = try #require(retained.canonicalTransition?.candidate)
        #expect(retained.mutations.count == 1)
        let retainedMutation = try #require(retained.mutations.first)
        let retainedRecord = try #require(retainedMutation.savedRecordVersion?.record)
        #expect(retainedMutation.recordID == batch.records[0].id)
        #expect(retainedRecord == candidate.records.first { $0.id == retainedMutation.recordID })
        let receipt = try #require(
            candidate.remoteBatchReceipts.first { $0.identity == batch.identity }
        )
        let committedPending = originalPending + retained.mutations
        let candidateArchive = try #require(retained.remoteSource?.durablePlan?.archive)

        switch boundary {
        case .afterIntent:
            #expect(try Data(contentsOf: fixture.archiveURL) == predecessorArchive)
            #expect(try fixture.checkpoints.load() == predecessor)
            #expect(try fixture.journal.pending() == originalPending)
        case .afterArchive:
            #expect(try Data(contentsOf: fixture.archiveURL) == candidateArchive)
            #expect(try fixture.checkpoints.load() == predecessor)
            #expect(try fixture.journal.pending() == originalPending)
        case .afterJournal:
            #expect(try Data(contentsOf: fixture.archiveURL) == candidateArchive)
            #expect(try fixture.checkpoints.load() == predecessor)
            #expect(try fixture.journal.pending() == committedPending)
        case .afterCheckpoint, .beforeIntentRemoval:
            #expect(try Data(contentsOf: fixture.archiveURL) == candidateArchive)
            #expect(try fixture.checkpoints.load() == candidate)
            #expect(try fixture.journal.pending() == committedPending)
        }

        let droppedCheckpointStore = WeakBox(fixture.checkpoints)
        #expect(droppedCheckpointStore.value != nil)
        fixture.dropInitialHandles()
        #expect(droppedCheckpointStore.value == nil)
        for _ in 0..<2 {
            let reopened = try fixture.reopen()
            let reopenedCheckpoints = try fixture.freshCheckpointStore()
            let replay = try reopened.prepareRemoteBatch(batch, attachmentSources: [:])
            #expect(try reopened.commitRemoteBatch(replay) == .alreadyCommitted(receipt))
            #expect(try reopenedCheckpoints.load() == candidate)
            #expect(try fixture.freshJournal().pending() == committedPending)
            #expect(try Data(contentsOf: fixture.archiveURL) == candidateArchive)
            #expect(try SyncPublicationTransactionFile(archiveURL: fixture.archiveURL).load() == nil)
        }
    }

    @Test(arguments: [false, true])
    func corruptOrPartialIntentNeverFallsBackToThePredecessor(
        partial: Bool
    ) throws {
        let fixture = try RemoteBatchFixture { if $0 == .afterIntent { throw Fault.injected } }
        defer { fixture.remove() }
        try fixture.acknowledgeBootstrap()
        let predecessor = try #require(try fixture.checkpoints.load())
        let archive = try Data(contentsOf: fixture.archiveURL)
        let pending = try fixture.journal.pending()
        let prepared = try fixture.store.prepareRemoteBatch(
            fixture.renamedBatch("Interrupted", id: UUID()),
            attachmentSources: [:]
        )
        #expect(throws: (any Error).self) { try fixture.store.commitRemoteBatch(prepared) }
        let validIntent = try Data(contentsOf: fixture.publicationIntentURL)
        let damaged = partial
            ? Data(validIntent.prefix(max(1, validIntent.count / 2)))
            : Data("{\"version\":6,\"integrity\":\"not-valid\"}".utf8)
        try damaged.write(to: fixture.publicationIntentURL)

        fixture.dropInitialHandles()
        #expect(throws: (any Error).self) { try fixture.reopen() }
        let reopenedCheckpoints = try fixture.freshCheckpointStore()
        #expect(try Data(contentsOf: fixture.archiveURL) == archive)
        #expect(try reopenedCheckpoints.load() == predecessor)
        #expect(try fixture.freshJournal().pending() == pending)
        #expect(try Data(contentsOf: fixture.publicationIntentURL) == damaged)
    }

    @Test
    func missingCheckpointAfterIntentRetainsEveryOtherRecoveryAuthority() throws {
        let fixture = try RemoteBatchFixture { if $0 == .afterIntent { throw Fault.injected } }
        defer { fixture.remove() }
        let archive = try Data(contentsOf: fixture.archiveURL)
        let pending = try fixture.journal.pending()
        let prepared = try fixture.store.prepareRemoteBatch(
            fixture.renamedBatch("Interrupted", id: UUID()),
            attachmentSources: [:]
        )
        #expect(throws: (any Error).self) { try fixture.store.commitRemoteBatch(prepared) }
        let intent = try Data(contentsOf: fixture.publicationIntentURL)
        let checkpointURL = fixture.root.appendingPathComponent("Live/SyncMetadata/canonical.json")
        try FileManager.default.removeItem(at: checkpointURL)

        fixture.dropInitialHandles()
        #expect(throws: (any Error).self) { try fixture.reopen() }
        let reopenedCheckpoints = try fixture.freshCheckpointStore()
        #expect(try Data(contentsOf: fixture.archiveURL) == archive)
        #expect(try fixture.freshJournal().pending() == pending)
        #expect(try Data(contentsOf: fixture.publicationIntentURL) == intent)
        #expect(try reopenedCheckpoints.load() == nil)
    }

    @Test
    func replacementRootAfterIntentCannotConsumeCopiedAuthority() throws {
        let fixture = try RemoteBatchFixture { if $0 == .afterIntent { throw Fault.injected } }
        defer { fixture.remove() }
        let prepared = try fixture.store.prepareRemoteBatch(
            fixture.renamedBatch("Interrupted", id: UUID()),
            attachmentSources: [:]
        )
        #expect(throws: (any Error).self) { try fixture.store.commitRemoteBatch(prepared) }
        let archive = try Data(contentsOf: fixture.archiveURL)
        let intent = try Data(contentsOf: fixture.publicationIntentURL)
        let checkpoint = try #require(try fixture.checkpoints.load())
        let journal = try fixture.journalAuthority()
        fixture.dropInitialHandles()

        let live = fixture.root.appendingPathComponent("Live")
        let displaced = fixture.root.appendingPathComponent("DisplacedLive")
        try FileManager.default.moveItem(at: live, to: displaced)
        try FileManager.default.copyItem(at: displaced, to: live)

        #expect(throws: (any Error).self) { try fixture.reopen() }
        let replacementCheckpoints = try fixture.freshCheckpointStore(at: live)
        let displacedCheckpoints = try fixture.freshCheckpointStore(at: displaced)
        let displacedArchive = displaced.appendingPathComponent("projects-v1.json")
        let displacedIntent = SyncPublicationTransactionFile(archiveURL: displacedArchive).url
        #expect(try Data(contentsOf: fixture.archiveURL) == archive)
        #expect(try Data(contentsOf: fixture.publicationIntentURL) == intent)
        #expect(try replacementCheckpoints.load() == checkpoint)
        #expect(try displacedCheckpoints.load() == checkpoint)
        #expect(try fixture.journalAuthority(at: live) == journal)
        #expect(try fixture.journalAuthority(at: displaced) == journal)
        #expect(try Data(contentsOf: displacedArchive) == archive)
        #expect(try Data(contentsOf: displacedIntent) == intent)
    }

    @Test
    func archiveSymlinkAfterIntentIsRejectedWithoutTouchingItsTarget() throws {
        let fixture = try RemoteBatchFixture { if $0 == .afterIntent { throw Fault.injected } }
        defer { fixture.remove() }
        let prepared = try fixture.store.prepareRemoteBatch(
            fixture.renamedBatch("Interrupted", id: UUID()),
            attachmentSources: [:]
        )
        #expect(throws: (any Error).self) { try fixture.store.commitRemoteBatch(prepared) }
        let intent = try Data(contentsOf: fixture.publicationIntentURL)
        let checkpoint = try #require(try fixture.checkpoints.load())
        let journal = try fixture.journalAuthority()
        let target = fixture.root.appendingPathComponent("outside-archive.json")
        let targetBytes = Data("outside must remain unchanged".utf8)
        try targetBytes.write(to: target)
        try FileManager.default.removeItem(at: fixture.archiveURL)
        try FileManager.default.createSymbolicLink(at: fixture.archiveURL, withDestinationURL: target)

        fixture.dropInitialHandles()
        #expect(throws: (any Error).self) { try fixture.reopen() }
        let reopenedCheckpoints = try fixture.freshCheckpointStore()
        #expect(try Data(contentsOf: target) == targetBytes)
        #expect(try Data(contentsOf: fixture.publicationIntentURL) == intent)
        #expect(try reopenedCheckpoints.load() == checkpoint)
        #expect(try fixture.journalAuthority() == journal)
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: fixture.archiveURL.path)
        #expect(URL(fileURLWithPath: destination).lastPathComponent == target.lastPathComponent)
    }

    @Test
    func unrelatedJournalAppendAfterIntentIsNotMistakenForAcknowledgement() throws {
        let fixture = try RemoteBatchFixture { if $0 == .afterIntent { throw Fault.injected } }
        defer { fixture.remove() }
        let prepared = try fixture.store.prepareRemoteBatch(
            fixture.renamedBatch("Interrupted", id: UUID()),
            attachmentSources: [:]
        )
        #expect(throws: (any Error).self) { try fixture.store.commitRemoteBatch(prepared) }
        let intent = try #require(
            try SyncPublicationTransactionFile(archiveURL: fixture.archiveURL).load()
        )
        let predecessorArchive = try Data(contentsOf: fixture.archiveURL)
        let unrelated = SyncMutation.delete(
            .init(kind: .project, uuid: UUID()),
            mutationID: UUID()
        )
        try fixture.journal.enqueue(unrelated)
        let pending = try fixture.journal.pending()
        let checkpoint = try #require(try fixture.checkpoints.load())
        let journal = try fixture.journalAuthority()

        fixture.dropInitialHandles()
        #expect(throws: (any Error).self) { try fixture.reopen() }
        let reopenedCheckpoints = try fixture.freshCheckpointStore()
        #expect(try Data(contentsOf: fixture.archiveURL) == predecessorArchive)
        #expect(try fixture.freshJournal().pending() == pending)
        #expect(try fixture.journalAuthority() == journal)
        #expect(try reopenedCheckpoints.load() == checkpoint)
        #expect(try SyncPublicationTransactionFile(archiveURL: fixture.archiveURL).load() == intent)
    }

    @Test
    func receiptCapacityFailureHappensBeforeIntentOrLiveMutation() throws {
        let fixture = try RemoteBatchFixture(); defer { fixture.remove() }
        try fixture.acknowledgeBootstrap()
        let predecessor = try #require(try fixture.checkpoints.load())
        let receipts = (0..<4_096).map { index in
            SyncRemoteBatchReceipt(
                identity: .init(
                    accountIDHash: predecessor.accountIDHash,
                    batchID: UUID(),
                    contentSHA256: Data(SHA256.hash(data: Data(String(index).utf8)))
                ),
                commitID: predecessor.commitID,
                domainChanged: false
            )
        }
        let full = try SyncCanonicalCheckpoint(
            accountIDHash: predecessor.accountIDHash,
            commitID: predecessor.commitID,
            archiveSHA256: predecessor.archiveSHA256,
            records: predecessor.records,
            legacyRecordIDsToDelete: predecessor.legacyRecordIDsToDelete,
            remoteBatchReceipts: receipts
        )
        try fixture.checkpoints.install(
            full,
            replacing: Data(SHA256.hash(data: predecessor.encoded()))
        )
        let archive = try Data(contentsOf: fixture.archiveURL)
        let pending = try fixture.journal.pending()
        fixture.dropInitialHandles()
        let reopened = try fixture.reopen()
        let reopenedCheckpoints = try fixture.freshCheckpointStore()
        let batch = try fixture.batch(records: [], id: UUID())

        #expect(throws: (any Error).self) {
            try reopened.prepareRemoteBatch(batch, attachmentSources: [:])
        }
        #expect(try reopenedCheckpoints.load() == full)
        #expect(try Data(contentsOf: fixture.archiveURL) == archive)
        #expect(try fixture.freshJournal().pending() == pending)
        #expect(!FileManager.default.fileExists(atPath: fixture.publicationIntentURL.path))

        try reopened.retireRemoteBatchReceipt(receipts[0].identity) {}
        let fresh = try reopened.prepareRemoteBatch(batch, attachmentSources: [:])
        guard case .committed = try reopened.commitRemoteBatch(fresh) else {
            Issue.record("Expected a fresh commit after explicit receipt retirement")
            return
        }
    }

    @Test
    func interruptedReceiptRetirementRecoversItsExactCandidate() throws {
        var armed = false
        let fixture = try RemoteBatchFixture { reached in
            if armed, reached == .afterIntent { throw Fault.injected }
        }
        defer { fixture.remove() }
        try fixture.acknowledgeBootstrap()
        let batch = try fixture.batch(records: [], id: UUID())
        let prepared = try fixture.store.prepareRemoteBatch(batch, attachmentSources: [:])
        guard case let .committed(receipt) = try fixture.store.commitRemoteBatch(prepared) else {
            Issue.record("Expected receipt insertion")
            return
        }
        armed = true
        #expect(throws: (any Error).self) {
            try fixture.store.retireRemoteBatchReceipt(batch.identity) {}
        }
        let retained = try #require(
            try SyncPublicationTransactionFile(archiveURL: fixture.archiveURL).load()
        )
        let candidate = try #require(retained.canonicalTransition?.candidate)
        #expect(candidate.remoteBatchReceipts.isEmpty)
        #expect(try fixture.checkpoints.load()?.remoteBatchReceipts == [receipt])

        fixture.dropInitialHandles()
        for _ in 0..<2 {
            _ = try fixture.reopen()
            let reopenedCheckpoints = try fixture.freshCheckpointStore()
            #expect(try reopenedCheckpoints.load() == candidate)
            #expect(try reopenedCheckpoints.load()?.remoteBatchReceipts.isEmpty == true)
            #expect(try SyncPublicationTransactionFile(archiveURL: fixture.archiveURL).load() == nil)
        }
    }

    @Test
    func unconfirmedReceiptRetirementPersistsNothingAndKeepsTheReceipt() throws {
        let fixture = try RemoteBatchFixture(); defer { fixture.remove() }
        try fixture.acknowledgeBootstrap()
        let batch = try fixture.batch(records: [], id: UUID())
        let prepared = try fixture.store.prepareRemoteBatch(batch, attachmentSources: [:])
        guard case let .committed(receipt) = try fixture.store.commitRemoteBatch(prepared) else {
            Issue.record("Expected receipt insertion")
            return
        }
        let checkpoint = try #require(try fixture.checkpoints.load())
        let archive = try Data(contentsOf: fixture.archiveURL)
        let pending = try fixture.journal.pending()

        #expect(throws: Fault.injected) {
            try fixture.store.retireRemoteBatchReceipt(batch.identity) { throw Fault.injected }
        }
        #expect(try fixture.checkpoints.load() == checkpoint)
        #expect(try Data(contentsOf: fixture.archiveURL) == archive)
        #expect(try fixture.journal.pending() == pending)
        #expect(!FileManager.default.fileExists(atPath: fixture.publicationIntentURL.path))

        fixture.dropInitialHandles()
        _ = try fixture.reopen()
        #expect(try fixture.freshCheckpointStore().load()?.remoteBatchReceipts == [receipt])
    }

    @Test
    func redeliveryAfterRestartAndLaterLocalEditCannotReplayDomainEffect() throws {
        let fixture = try RemoteBatchFixture(); defer { fixture.remove() }
        try fixture.acknowledgeBootstrap()
        let batch = try fixture.renamedBatch("Remote", id: UUID())
        let prepared = try fixture.store.prepareRemoteBatch(batch, attachmentSources: [:])
        guard case let .committed(receipt) = try fixture.store.commitRemoteBatch(prepared) else {
            Issue.record("Expected remote commit")
            return
        }
        try fixture.renameLocally("Later local edit")
        let exactLater = try #require(try fixture.checkpoints.load())
        let archive = try Data(contentsOf: fixture.archiveURL)
        let pending = try fixture.journal.pending()

        fixture.dropInitialHandles()
        let reopened = try fixture.reopen()
        var notifications: [UUID] = []
        reopened.onRemoteDomainCommitted = { notifications.append($0) }
        let replay = try reopened.prepareRemoteBatch(batch, attachmentSources: [:])

        #expect(try reopened.commitRemoteBatch(replay) == .alreadyCommitted(receipt))
        #expect(reopened.project(id: fixture.projectID)?.name == "Later local edit")
        #expect(try fixture.freshCheckpointStore().load() == exactLater)
        #expect(try Data(contentsOf: fixture.archiveURL) == archive)
        #expect(try fixture.freshJournal().pending() == pending)
        #expect(notifications.isEmpty)
    }

    @Test(arguments: SyncDurableFileWriteBoundary.allCases)
    func remoteMediaDurabilityFaultRecoversEmbeddedCandidateBytes(
        boundary: SyncDurableFileWriteBoundary
    ) throws {
        var armed = false
        var fired = false
        let fixture = try RemoteBatchFixture(remoteInstallBoundary: { reached in
            if armed, reached == boundary, !fired {
                fired = true
                throw Fault.injected
            }
        })
        defer { fixture.remove() }
        try fixture.acknowledgeBootstrap()
        let input = try fixture.photoBatch(id: UUID())
        let predecessor = try #require(try fixture.checkpoints.load())
        let predecessorArchive = try Data(contentsOf: fixture.archiveURL)
        let originalPending = try fixture.journal.pending()
        let prepared = try fixture.store.prepareRemoteBatch(
            input.batch,
            attachmentSources: input.attachments
        )
        armed = true

        #expect(throws: (any Error).self) { try fixture.store.commitRemoteBatch(prepared) }
        #expect(fired)
        let retained = try #require(
            try SyncPublicationTransactionFile(archiveURL: fixture.archiveURL).load()
        )
        let candidate = try #require(retained.canonicalTransition?.candidate)
        let receipt = try #require(
            candidate.remoteBatchReceipts.first { $0.identity == input.batch.identity }
        )
        let file = try #require(retained.remoteSource?.durablePlan?.files.first)
        let target = fixture.root.appendingPathComponent("Live/" + file.relativePath)
        #expect(try Data(contentsOf: fixture.archiveURL) == predecessorArchive)
        #expect(try fixture.checkpoints.load() == predecessor)
        #expect(try fixture.journal.pending() == originalPending)
        if boundary == .beforeDirectorySync {
            #expect(try Data(contentsOf: target) == file.data)
        } else {
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }

        fixture.dropInitialHandles()
        for _ in 0..<2 {
            let reopened = try fixture.reopen()
            let reopenedCheckpoints = try fixture.freshCheckpointStore()
            let replay = try reopened.prepareRemoteBatch(
                input.batch,
                attachmentSources: input.attachments
            )
            #expect(try reopened.commitRemoteBatch(replay) == .alreadyCommitted(receipt))
            #expect(try reopenedCheckpoints.load() == candidate)
            #expect(try Data(contentsOf: target) == file.data)
            #expect(try fixture.freshJournal().pending() == originalPending + retained.mutations)
            #expect(try SyncPublicationTransactionFile(archiveURL: fixture.archiveURL).load() == nil)
        }
    }

    @Test
    func changedSiblingPrefixMediaSourceFailsBeforeIntentThenFreshCommitSucceeds() throws {
        let fixture = try RemoteBatchFixture(); defer { fixture.remove() }
        try fixture.acknowledgeBootstrap()
        let input = try fixture.photoBatch(
            id: UUID(),
            sourceDirectoryName: "LiveUntrustedSibling"
        )
        let prepared = try fixture.store.prepareRemoteBatch(
            input.batch,
            attachmentSources: input.attachments
        )
        let predecessor = try fixture.checkpoints.load()
        let archive = try Data(contentsOf: fixture.archiveURL)
        let pending = try fixture.journal.pending()
        let source = try #require(input.attachments.values.first?.fileURL)
        let sourceBytes = try Data(contentsOf: source)
        try Data("changed after preparation".utf8).write(to: source, options: .atomic)

        #expect(try fixture.store.commitRemoteBatch(prepared) == .stalePredecessor)
        #expect(try fixture.checkpoints.load() == predecessor)
        #expect(try Data(contentsOf: fixture.archiveURL) == archive)
        #expect(try fixture.journal.pending() == pending)
        #expect(!FileManager.default.fileExists(atPath: fixture.publicationIntentURL.path))

        try sourceBytes.write(to: source, options: .atomic)
        let fresh = try fixture.store.prepareRemoteBatch(
            input.batch,
            attachmentSources: input.attachments
        )
        guard case .committed = try fixture.store.commitRemoteBatch(fresh) else {
            Issue.record("Expected a fresh commit after recapturing the restored source")
            return
        }
    }

    @Test(arguments: [false, true])
    func substitutedRemoteMediaTargetAfterIntentIsRejected(
        symlink: Bool
    ) throws {
        let fixture = try RemoteBatchFixture { if $0 == .afterIntent { throw Fault.injected } }
        defer { fixture.remove() }
        try fixture.acknowledgeBootstrap()
        let input = try fixture.photoBatch(id: UUID())
        let prepared = try fixture.store.prepareRemoteBatch(
            input.batch,
            attachmentSources: input.attachments
        )
        #expect(throws: (any Error).self) { try fixture.store.commitRemoteBatch(prepared) }
        let retained = try #require(
            try SyncPublicationTransactionFile(archiveURL: fixture.archiveURL).load()
        )
        let file = try #require(retained.remoteSource?.durablePlan?.files.first)
        let target = fixture.root.appendingPathComponent("Live/" + file.relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let substituted = Data("unrelated media".utf8)
        let outside = fixture.root.appendingPathComponent("outside-media")
        if symlink {
            try substituted.write(to: outside)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        } else {
            try substituted.write(to: target)
        }
        let archive = try Data(contentsOf: fixture.archiveURL)
        let intent = try Data(contentsOf: fixture.publicationIntentURL)
        let checkpoint = try #require(try fixture.checkpoints.load())
        let journal = try fixture.journalAuthority()

        fixture.dropInitialHandles()
        #expect(throws: (any Error).self) { try fixture.reopen() }
        let reopenedCheckpoints = try fixture.freshCheckpointStore()
        #expect(try Data(contentsOf: fixture.archiveURL) == archive)
        #expect(try Data(contentsOf: fixture.publicationIntentURL) == intent)
        #expect(try Data(contentsOf: symlink ? outside : target) == substituted)
        #expect(try reopenedCheckpoints.load() == checkpoint)
        #expect(try fixture.journalAuthority() == journal)
    }
}
