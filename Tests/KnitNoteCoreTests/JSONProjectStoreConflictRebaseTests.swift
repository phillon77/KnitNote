import Foundation
import Testing
@testable import KnitNoteCore

@MainActor
struct JSONProjectStoreConflictRebaseTests {
    enum Fault: Error { case injected }
    @Test func laterEditRejectsPreparedConflictWithoutMutation() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let p = try f.base.store.prepareConflictRebase(f.input(), attachmentSources: [:])
        try f.base.renameLocally("After preparation")
        let archive = try Data(contentsOf: f.base.archiveURL)
        let checkpoint = try f.base.checkpoints.load()
        let pending = try f.base.journal.pending()
        #expect(try f.base.store.commitConflictRebase(p) == .stalePredecessor)
        #expect(try Data(contentsOf: f.base.archiveURL) == archive)
        #expect(try f.base.checkpoints.load() == checkpoint)
        #expect(try f.base.journal.pending() == pending)
    }

    @Test func threeSavesCommitExactVersionsAndPreserveUnrelatedFIFO() throws {
        let f = try ConflictRebaseFixture(interleave: true); defer { f.remove() }
        let other = try #require(f.base.store.projects.first { $0.id != f.base.projectID })
        try f.base.store.updateProject(id: other.id, name: "Unrelated", toolType: nil,
            toolSize: nil, toolNotes: nil, photoChange: .unchanged)
        let before = try #require(try f.base.checkpoints.load())
        let input = try f.input()
        let pending = try f.base.journal.pendingVersioned()
        var notifications: [UUID] = []
        var owned = false
        f.base.store.onRemoteDomainCommitted = { id in
            #expect(!owned)
            #expect((try? f.base.journal.pendingVersioned()) != nil)
            notifications.append(id)
        }
        let p = try f.base.store.prepareConflictRebase(input, attachmentSources: [:])
        let result = try f.base.store.commitConflictRebase(p) { work in
            owned = true; defer { owned = false }
            return try work()
        }
        guard case let .committed(resolution) = result else { Issue.record("Expected commit"); return }
        let after = try f.base.journal.pendingVersioned()
        #expect(after.map(\.mutation.identity) == pending.map(\.mutation.identity))
        #expect(after.filter { $0.mutation.recordID != input.serverRecord.id }
            == pending.filter { $0.mutation.recordID != input.serverRecord.id })
        let selected = after.filter { $0.mutation.recordID == input.serverRecord.id }
        #expect(selected.count == 3)
        #expect(selected.map(\.token.journalRevision) == [1, 1, 1])
        #expect(selected.map { $0.mutation.savedRecordVersion?.record.payload.fields["name"]?.value }
            == [.string("Server"), .string("Server"), .string("Server")])
        #expect(resolution.versions == selected.map(\.token))
        #expect(f.base.store.project(id: f.base.projectID)?.name == "Server")
        let checkpoint = try #require(try f.base.checkpoints.load())
        #expect(checkpoint.records.filter { $0.id != input.serverRecord.id }
            == before.records.filter { $0.id != input.serverRecord.id })
        #expect(checkpoint.remoteBatchReceipts == before.remoteBatchReceipts)
        #expect(notifications == [resolution.transactionID])
        #expect(!FileManager.default.fileExists(atPath: f.base.publicationIntentURL.path))
        #expect(try f.base.reopen().project(id: f.base.projectID)?.name == "Server")
    }

    @Test func identicalDurableRetryDoesNotAdvanceJournalOrCanonical() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let input = try f.input()
        let p = try f.base.store.prepareConflictRebase(input, attachmentSources: [:])
        let first = try f.base.store.commitConflictRebase(p)
        let checkpoint = try f.base.checkpoints.load()
        let journal = try f.base.journalAuthority()
        let again = try f.base.store.prepareConflictRebase(input, attachmentSources: [:])
        #expect(try f.base.store.commitConflictRebase(again) == first)
        #expect(try f.base.checkpoints.load() == checkpoint)
        #expect(try f.base.journalAuthority() == journal)
    }

    @Test func sameStampDifferentPayloadFailsBeforeIntent() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let input = try f.input()
        var server = input.failedMutation.savedRecordVersion!.record
        server.payload.fields["name"] = .init(value: .string("Corrupt"),
            stamp: server.payload.fields["name"]!.stamp)
        let collision = try SyncConflictInput(accountIDHash: input.accountIDHash,
            failedAttemptID: input.failedAttemptID, failedMutation: input.failedMutation,
            failedVersion: input.failedVersion, serverRecord: server,
            expectedRecordQueue: input.expectedRecordQueue, expectedVersions: input.expectedVersions)
        let pending = try f.base.journal.pendingVersioned()
        #expect(throws: (any Error).self) {
            try f.base.store.prepareConflictRebase(collision, attachmentSources: [:])
        }
        #expect(try f.base.journal.pendingVersioned() == pending)
        #expect(!FileManager.default.fileExists(atPath: f.base.publicationIntentURL.path))
    }

    @Test func metadataOnlyConflictDoesNotNotifyOrIncrementGeneration() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let input = try f.input()
        let server = input.failedMutation.savedRecordVersion!.record
        let metadata = try SyncConflictInput(accountIDHash: input.accountIDHash,
            failedAttemptID: input.failedAttemptID, failedMutation: input.failedMutation,
            failedVersion: input.failedVersion, serverRecord: server,
            expectedRecordQueue: input.expectedRecordQueue, expectedVersions: input.expectedVersions)
        var notifications = 0
        f.base.store.onRemoteDomainCommitted = { _ in notifications += 1 }
        let generation = f.base.store.dataGeneration
        let archive = try Data(contentsOf: f.base.archiveURL)
        let p = try f.base.store.prepareConflictRebase(metadata, attachmentSources: [:])
        guard case .committed = try f.base.store.commitConflictRebase(p) else { Issue.record("Expected commit"); return }
        #expect(try Data(contentsOf: f.base.archiveURL) == archive)
        #expect(f.base.store.dataGeneration == generation)
        #expect(notifications == 0)
        #expect(try f.base.journal.pendingVersioned().map(\.token.journalRevision) == [1, 1, 1])
        #expect(try f.base.journal.pending().map { $0.savedRecordVersion?.record.payload.fields["name"]?.value }
            == [.string("Local 1"), .string("Local 2"), .string("Local 3")])
    }

    @Test(arguments: [SyncCanonicalPublicationBoundary.afterIntent, .afterArchive, .afterJournal,
        .afterCheckpoint, .beforeIntentRemoval])
    func interruptedConflictRecoversExactCandidateTwice(boundary: SyncCanonicalPublicationBoundary) throws {
        var armed = false
        let f = try ConflictRebaseFixture { if armed && $0 == boundary { throw Fault.injected } }
        defer { f.remove() }
        let input = try f.input()
        let p = try f.base.store.prepareConflictRebase(input, attachmentSources: [:])
        let transaction = try #require(p.transaction)
        let candidate = try #require(transaction.canonicalTransition?.candidate)
        armed = true
        #expect(throws: (any Error).self) { try f.base.store.commitConflictRebase(p) }
        #expect(try SyncPublicationTransactionFile(archiveURL: f.base.archiveURL).load() == transaction)
        f.base.dropInitialHandles()
        for _ in 0..<2 {
            let fresh = try f.base.reopen()
            #expect(fresh.project(id: f.base.projectID)?.name == "Server")
            #expect(try f.base.freshCheckpointStore().load() == candidate)
            #expect(try f.base.freshJournal().pendingVersioned().map(\.token.journalRevision) == [1, 1, 1])
            let again = try fresh.prepareConflictRebase(input, attachmentSources: [:])
            guard case let .committed(resolution) = try fresh.commitConflictRebase(again) else {
                Issue.record("Expected retained resolution"); return
            }
            #expect(resolution.transactionID == candidate.commitID)
            #expect(!FileManager.default.fileExists(atPath: f.base.publicationIntentURL.path))
        }
    }

    @Test(arguments: [UInt64(0), UInt64(1000)])
    func laterLocalEditExtendsSameEventOnceAndDifferentEventObsoletesOldFailure(serverRevision: UInt64) throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let issued = try f.input()
        var server = issued.serverRecord
        server.entityRevision = serverRevision
        let original = try SyncConflictInput(accountIDHash: issued.accountIDHash,
            failedAttemptID: issued.failedAttemptID, failedMutation: issued.failedMutation,
            failedVersion: issued.failedVersion, serverRecord: server,
            expectedRecordQueue: issued.expectedRecordQueue, expectedVersions: issued.expectedVersions)
        let first = try f.base.store.prepareConflictRebase(original, attachmentSources: [:])
        guard case let .committed(firstResolution) = try f.base.store.commitConflictRebase(first) else {
            Issue.record("Expected first commit"); return
        }
        try f.base.renameLocally("Local after handoff")
        #expect(try f.base.journal.pending().last!.savedRecordVersion!.record.payload.fields["name"]!.stamp.logicalRevision > 1000)
        let retry = try f.base.store.prepareConflictRebase(original, attachmentSources: [:])
        guard case let .committed(retryResolution) = try f.base.store.commitConflictRebase(retry) else {
            Issue.record("Expected extended commit"); return
        }
        #expect(retryResolution.transactionID != firstResolution.transactionID)
        #expect(retryResolution.versions.map(\.journalRevision) == [2, 2, 2, 1])
        #expect(f.base.store.project(id: f.base.projectID)?.name == "Local after handoff")
        let again = try f.base.store.prepareConflictRebase(original, attachmentSources: [:])
        #expect(try f.base.store.commitConflictRebase(again) == .committed(retryResolution))
        let different = try f.input(serverRecord: server)
        let newer = try f.base.store.prepareConflictRebase(different, attachmentSources: [:])
        guard case .committed = try f.base.store.commitConflictRebase(newer) else {
            Issue.record("Expected new event"); return
        }
        let obsolete = try f.base.store.prepareConflictRebase(original, attachmentSources: [:])
        #expect(try f.base.store.commitConflictRebase(obsolete) == .obsoleteFailure)
    }

    @Test(arguments: ["processed-watch-commands.json", "SyncMetadata/attachment-versions.json"])
    func changedAuthorityRejectsCommitBeforeIntent(path: String) throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let p = try f.base.store.prepareConflictRebase(f.input(), attachmentSources: [:])
        try Data("Changed".utf8).write(to: f.base.root.appendingPathComponent("Live/" + path))
        let archive = try Data(contentsOf: f.base.archiveURL)
        #expect(try f.base.store.commitConflictRebase(p) == .stalePredecessor)
        #expect(try Data(contentsOf: f.base.archiveURL) == archive)
        #expect(!FileManager.default.fileExists(atPath: f.base.publicationIntentURL.path))
    }

    @Test func failedOwnershipDoesNotWriteIntent() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let p = try f.base.store.prepareConflictRebase(f.input(), attachmentSources: [:])
        let before = try f.base.journalAuthority()
        #expect(throws: Fault.injected) {
            try f.base.store.commitConflictRebase(p) { _ in throw Fault.injected }
        }
        #expect(try f.base.journalAuthority() == before)
        #expect(!FileManager.default.fileExists(atPath: f.base.publicationIntentURL.path))
    }

    @Test(arguments: [false, true])
    func liveOverlayPreparesExactEvidenceAndPreservesAttemptSource(relocatedAttempt: Bool) throws {
        let f = try ConflictAttachmentFixture(deleted: false, relocatedAttempt: relocatedAttempt)
        defer { f.base.remove() }
        let archive = try Data(contentsOf: f.base.archiveURL)
        let pending = try f.base.journal.pendingVersioned()
        let generation = f.base.store.dataGeneration
        let p = try f.base.store.prepareConflictRebase(f.input, attachmentSources: [:])
        let plan = try #require(p.transaction?.conflictSource?.plan)
        #expect(plan.files.map(\.version) == [f.version])
        guard case .committed = try f.base.store.commitConflictRebase(p) else { Issue.record("Expected commit"); return }
        #expect(try Data(contentsOf: f.base.archiveURL) == archive)
        #expect(f.base.store.dataGeneration == generation)
        #expect(try f.base.journal.pendingVersioned().map(\.mutation.attachmentSource)
            == pending.map(\.mutation.attachmentSource))
        let evidence = try SyncAttachmentPublicationEvidenceFile(
            url: f.base.root.appendingPathComponent("Live/SyncMetadata/attachment-versions.json")).load()
        #expect(evidence.retainedAttachmentRecords.first { $0.id == f.input.serverRecord.id } == f.input.serverRecord)
        f.base.dropInitialHandles()
        #expect(try f.base.reopen().project(id: f.base.projectID)?.photoFilename != nil)
    }

    @Test(arguments: [false, true])
    func rawOnlyAttachmentIsRetainedAtAccountPathWithoutResurrection(interrupted: Bool) throws {
        var armed = false
        let f = try ConflictAttachmentFixture(deleted: true) {
            if armed && interrupted && $0 == .afterJournal { throw Fault.injected }
        }
        defer { f.base.remove() }
        let before = try #require(try f.base.checkpoints.load())
        let evidenceFile = SyncAttachmentPublicationEvidenceFile(
            url: f.base.root.appendingPathComponent("Live/SyncMetadata/attachment-versions.json"))
        let evidence = try evidenceFile.load()
        let p = try f.base.store.prepareConflictRebase(f.input, attachmentSources: [f.version.versionID: f.source])
        let path = "SyncMetadata/conflict-source-attachments/" + f.input.accountIDHash
            + "/" + f.version.versionID.uuidString.lowercased()
        #expect(p.transaction?.conflictSource?.plan.files.map(\.relativePath) == [path])
        armed = true
        if interrupted {
            #expect(throws: (any Error).self) { try f.base.store.commitConflictRebase(p) }
        } else {
            guard case .committed = try f.base.store.commitConflictRebase(p) else { Issue.record("Expected commit"); return }
        }
        f.base.dropInitialHandles()
        for _ in 0..<2 {
            let fresh = try f.base.reopen()
            #expect(fresh.project(id: f.base.projectID) == nil)
            #expect(try f.base.freshCheckpointStore().load()?.records == before.records)
            #expect(try evidenceFile.load() == evidence)
            #expect(try Data(contentsOf: f.base.root.appendingPathComponent("Live/" + path))
                == Data(contentsOf: f.source.fileURL))
        }
    }

    @Test func rawOnlyExistingDifferentBytesBlockBeforeIntent() throws {
        let f = try ConflictAttachmentFixture(deleted: true); defer { f.base.remove() }
        let target = f.base.root.appendingPathComponent("Live/SyncMetadata/conflict-source-attachments/"
            + f.input.accountIDHash + "/" + f.version.versionID.uuidString.lowercased())
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("collision".utf8).write(to: target)
        let pending = try f.base.journal.pendingVersioned()
        #expect(throws: SyncConflictError.identityCollision) {
            try f.base.store.prepareConflictRebase(f.input, attachmentSources: [f.version.versionID: f.source])
        }
        #expect(try f.base.journal.pendingVersioned() == pending)
        #expect(!FileManager.default.fileExists(atPath: f.base.publicationIntentURL.path))
    }

    @Test func rawOnlyMissingBytesBlockBeforeIntent() throws {
        let f = try ConflictAttachmentFixture(deleted: true); defer { f.base.remove() }
        #expect(throws: (any Error).self) {
            try f.base.store.prepareConflictRebase(f.input, attachmentSources: [:])
        }
        #expect(!FileManager.default.fileExists(atPath: f.base.publicationIntentURL.path))
    }

    @Test func missingCanonicalAuthorityBlocksPreparation() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        try FileManager.default.removeItem(at: f.base.root.appendingPathComponent("Live/SyncMetadata/canonical.json"))
        #expect(throws: (any Error).self) { try f.base.store.prepareConflictRebase(f.input(), attachmentSources: [:]) }
        #expect(!FileManager.default.fileExists(atPath: f.base.publicationIntentURL.path))
    }

    @Test func observedMaximumStampBlocksLaterLocalPublicationWithoutWrapping() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let issued = try f.input()
        var server = issued.serverRecord
        server.payload.fields["name"] = .init(value: .string("Last remote revision"),
            stamp: .init(logicalRevision: UInt64.max, modifiedAt: Date(timeIntervalSince1970: 2_300_000_000),
                deviceID: "remote-max"))
        let p = try f.base.store.prepareConflictRebase(f.input(serverRecord: server), attachmentSources: [:])
        guard case .committed = try f.base.store.commitConflictRebase(p) else { Issue.record("Expected commit"); return }
        let checkpoint = try f.base.checkpoints.load()
        let archive = try Data(contentsOf: f.base.archiveURL)
        let pending = try f.base.journal.pendingVersioned()
        #expect(throws: (any Error).self) { try f.base.renameLocally("Cannot wrap") }
        #expect(try f.base.checkpoints.load() == checkpoint)
        #expect(try Data(contentsOf: f.base.archiveURL) == archive)
        #expect(try f.base.journal.pendingVersioned() == pending)
        #expect(!FileManager.default.fileExists(atPath: f.base.publicationIntentURL.path))
    }

    @Test func journalAcknowledgementAndUnrelatedAppendAfterCommitRecoverWithoutReplay() throws {
        var armed = false
        let f = try ConflictRebaseFixture { if armed && $0 == .afterJournal { throw Fault.injected } }
        defer { f.remove() }
        let p = try f.base.store.prepareConflictRebase(f.input(), attachmentSources: [:])
        armed = true
        #expect(throws: (any Error).self) { try f.base.store.commitConflictRebase(p) }
        let pending = try f.base.journal.pendingVersioned()
        #expect(try f.base.journal.acknowledgeCurrentVersion(pending[0].token) == .acknowledged)
        let record = try #require(p.predecessor.records.first {
            $0.id.kind == .project && $0.id.uuid != f.base.projectID
        })
        let appended = try SyncMutation.save(recordVersion: .init(record: record), mutationID: UUID())
        try f.base.journal.enqueue([appended])
        let expected = try f.base.journal.pendingVersioned()
        f.base.dropInitialHandles()
        #expect(try f.base.reopen().project(id: f.base.projectID)?.name == "Server")
        #expect(try f.base.freshJournal().pendingVersioned() == expected)
        #expect(try f.base.freshJournal().acknowledgeCurrentVersion(pending[0].token) == .alreadyAcknowledged)
    }

    @Test func completeWatchReceiptAndMediaAuthoritiesSurviveConflict() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let other = try #require(f.base.store.projects.first { $0.id != f.base.projectID })
        try f.base.store.updateProject(id: other.id, name: other.name, toolType: nil,
            toolSize: nil, toolNotes: nil, photoChange: .replace(BackupFixture.jpegData(red: 0.6)))
        let live = f.base.root.appendingPathComponent("Live")
        let command = WatchCounterCommand(projectID: other.id, counterID: other.counters[0].id,
            operation: .increment, createdAt: Date(timeIntervalSince1970: 2_000_000_000))
        _ = try f.base.store.applyWatchCommandDurably(command,
            ledgerURL: WatchSyncPaths.processedLedger(in: live),
            preparedCommandURL: WatchSyncPaths.preparedCommand(in: live))
        let batch = try f.base.batch(records: [], id: UUID())
        let remote = try f.base.store.prepareRemoteBatch(batch, attachmentSources: [:])
        _ = try f.base.store.commitRemoteBatch(remote)
        let checkpoint = try #require(try f.base.checkpoints.load())
        let evidenceFile = SyncAttachmentPublicationEvidenceFile(url: live.appendingPathComponent("SyncMetadata/attachment-versions.json"))
        let evidence = try evidenceFile.load()
        let watch = try Data(contentsOf: WatchSyncPaths.processedLedger(in: live))
        let photo = live.appendingPathComponent("ProjectPhotos")
            .appendingPathComponent(try #require(f.base.store.project(id: other.id)?.photoFilename))
        let media = try SyncRegularFileReader().read(photo, maximumBytes: 100_000_000)
        let pending = try f.base.journal.pendingVersioned()
        let input = try f.input()
        let p = try f.base.store.prepareConflictRebase(input, attachmentSources: [:])
        guard case .committed = try f.base.store.commitConflictRebase(p) else { Issue.record("Expected commit"); return }
        let current = try #require(try f.base.checkpoints.load())
        #expect(current.records.filter { $0.id != input.serverRecord.id }
            == checkpoint.records.filter { $0.id != input.serverRecord.id })
        #expect(current.remoteBatchReceipts == checkpoint.remoteBatchReceipts)
        #expect(try f.base.journal.pendingVersioned().filter { $0.mutation.recordID != input.serverRecord.id }
            == pending.filter { $0.mutation.recordID != input.serverRecord.id })
        #expect(try evidenceFile.load() == evidence)
        #expect(try Data(contentsOf: WatchSyncPaths.processedLedger(in: live)) == watch)
        let after = try SyncRegularFileReader().read(photo, maximumBytes: 100_000_000)
        #expect(after.data == media.data && after.inode == media.inode && after.device == media.device)
    }

    @Test func incomingDeletionWithoutLocalAuthorityBlocksBeforeIntent() throws {
        let f = try ConflictAttachmentFixture(deleted: false); defer { f.base.remove() }
        var server = f.input.serverRecord
        server.deletedAt = .init(value: Date(timeIntervalSince1970: 2_200_000_000), stamp: server.deletedAt.stamp)
        let input = try SyncConflictInput(accountIDHash: f.input.accountIDHash,
            failedAttemptID: f.input.failedAttemptID, failedMutation: f.input.failedMutation,
            failedVersion: f.input.failedVersion, serverRecord: server,
            expectedRecordQueue: f.input.expectedRecordQueue, expectedVersions: f.input.expectedVersions)
        #expect(throws: SyncRemoteBatchError.unprovenDeletion) {
            try f.base.store.prepareConflictRebase(input, attachmentSources: [:])
        }
        #expect(!FileManager.default.fileExists(atPath: f.base.publicationIntentURL.path))
    }

    @Test func replacedRawOnlyFileIdentityMakesPreparationStale() throws {
        let f = try ConflictAttachmentFixture(deleted: true); defer { f.base.remove() }
        let path = "Live/SyncMetadata/conflict-source-attachments/" + f.input.accountIDHash
            + "/" + f.version.versionID.uuidString.lowercased()
        let target = f.base.root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: f.source.fileURL).write(to: target)
        let p = try f.base.store.prepareConflictRebase(f.input, attachmentSources: [f.version.versionID: f.source])
        let inode = try SyncRegularFileReader().read(target, maximumBytes: 100_000_000).inode
        try Data(contentsOf: target).write(to: target, options: .atomic)
        #expect(try SyncRegularFileReader().read(target, maximumBytes: 100_000_000).inode != inode)
        #expect(try f.base.store.commitConflictRebase(p) == .stalePredecessor)
        #expect(!FileManager.default.fileExists(atPath: f.base.publicationIntentURL.path))
    }

    @Test(arguments: [false, true])
    func recoveryRejectsReplacementOfCapturedRawOnlyFileOrParent(replaceParent: Bool) throws {
        var armed = false
        let f = try ConflictAttachmentFixture(deleted: true) {
            if armed && $0 == .afterIntent { throw Fault.injected }
        }
        defer { f.base.remove() }
        let target = f.base.root.appendingPathComponent("Live/SyncMetadata/conflict-source-attachments/"
            + f.input.accountIDHash + "/" + f.version.versionID.uuidString.lowercased())
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data(contentsOf: f.source.fileURL).write(to: target)
        let p = try f.base.store.prepareConflictRebase(f.input, attachmentSources: [f.version.versionID: f.source])
        armed = true
        #expect(throws: Fault.injected) { try f.base.store.commitConflictRebase(p) }
        if replaceParent {
            let held = f.base.root.appendingPathComponent("held-parent")
            try FileManager.default.moveItem(at: parent, to: held)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            try FileManager.default.moveItem(at: held.appendingPathComponent(target.lastPathComponent), to: target)
            try FileManager.default.removeItem(at: held)
        } else {
            try Data(contentsOf: target).write(to: target, options: .atomic)
        }
        let archive = try Data(contentsOf: f.base.archiveURL)
        let pending = try f.base.journal.pendingVersioned()
        f.base.dropInitialHandles()
        #expect(throws: (any Error).self) { try f.base.reopen() }
        #expect(try Data(contentsOf: f.base.archiveURL) == archive)
        #expect(try f.base.freshJournal().pendingVersioned() == pending)
        #expect(try SyncPublicationTransactionFile(archiveURL: f.base.archiveURL).load() == p.transaction)
    }
}
