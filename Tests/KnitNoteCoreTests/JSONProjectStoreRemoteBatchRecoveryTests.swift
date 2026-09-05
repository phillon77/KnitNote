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

    @Test
    func partialRemoteProjectUpdatePreservesSixCounterWatchProofsAndExactFIFO() throws {
        let fixture = try RemoteBatchFixture(); defer { fixture.remove() }
        try fixture.acknowledgeBootstrap()
        let live = fixture.root.appendingPathComponent("Live")
        let project = try #require(fixture.store.project(id: fixture.projectID))
        #expect(project.counters.count == 6)
        let commands = project.counters.enumerated().map { index, counter in
            WatchCounterCommand(
                id: UUID(),
                projectID: project.id,
                counterID: counter.id,
                operation: .increment,
                createdAt: Date(timeIntervalSinceReferenceDate: 900_000_000 + Double(index))
            )
        }
        for (index, command) in commands.enumerated() {
            let acknowledgement = try fixture.store.applyWatchCommandDurably(
                command,
                ledgerURL: WatchSyncPaths.processedLedger(in: live),
                preparedCommandURL: WatchSyncPaths.preparedCommand(in: live),
                now: Date(timeIntervalSinceReferenceDate: 900_000_100 + Double(index))
            )
            #expect(acknowledgement.rejection == nil)
        }
        let watchLedger = try Data(contentsOf: WatchSyncPaths.processedLedger(in: live))
        let before = try #require(try fixture.checkpoints.load())
        let exactPending = try fixture.journal.pending()
        let projectRecordID = SyncEntityID(kind: .project, uuid: project.id)
        let expectedPendingRecordIDs = commands.flatMap { command in
            let counterRecordID = SyncEntityID(kind: .projectCounter, uuid: command.counterID)
            return [projectRecordID, counterRecordID, counterRecordID]
        }
        #expect(exactPending.count == commands.count * 3)
        #expect(exactPending.map(\.recordID) == expectedPendingRecordIDs)

        let otherProject = try #require(fixture.store.projects.first { $0.id != project.id })
        var remote = try #require(before.records.first {
            $0.id == .init(kind: .project, uuid: otherProject.id)
        })
        let remoteStamp = SyncMutationStamp(
            logicalRevision: 2_000,
            modifiedAt: Date(timeIntervalSince1970: 2_100_000_000),
            deviceID: "combined-remote"
        )
        remote.payload.fields["name"] = .init(
            value: .string("Remote Second"),
            stamp: remoteStamp
        )
        let batch = try SyncRemoteBatch(
            accountIDHash: fixture.account.accountIDHash,
            batchID: UUID(),
            records: [remote],
            deletedRecordIDs: []
        )
        let prepared = try fixture.store.prepareRemoteBatch(batch, attachmentSources: [:])
        guard case .committed = try fixture.store.commitRemoteBatch(prepared) else {
            Issue.record("Expected combined partial remote commit")
            return
        }

        let after = try #require(try fixture.checkpoints.load())
        let expectedRecords = before.records.map { $0.id == remote.id ? remote : $0 }
        #expect(after.records == expectedRecords)
        #expect(after.records.first { $0.id == remote.id } == remote)
        #expect(fixture.store.project(id: otherProject.id)?.name == "Remote Second")
        #expect(fixture.store.project(id: project.id)?.counters.map(\.value) == [1, 1, 1, 1, 1, 1])
        let counterStates = after.records.compactMap { record -> SyncCounterReminderState? in
            guard commands.contains(where: { $0.counterID == record.id.uuid }),
                  case let .projectCounter(state)? = record.payload.atomicDomain?.value else {
                return nil
            }
            return state
        }
        #expect(counterStates.count == 6)
        for command in commands {
            let state = try #require(counterStates.first { $0.counter.id == command.counterID })
            #expect(state.counter.value == 1)
            #expect(state.processedCommandIDs == [command.id])
            #expect(state.processedCommandProofs.map(\.commandIdentity)
                == [ProcessedWatchCommandIdentity(command)])
        }
        #expect(try fixture.journal.pending() == exactPending)
        #expect(try Data(contentsOf: WatchSyncPaths.processedLedger(in: live)) == watchLedger)
    }

    @Test
    func stagedRemoteAttachmentInstallsExactBytesAndPreservesHistoricalHeads() throws {
        let fixture = try RemoteBatchFixture(); defer { fixture.remove() }
        try fixture.acknowledgeBootstrap()
        let project = try #require(fixture.store.project(id: fixture.projectID))
        try fixture.store.updateProject(
            id: project.id,
            name: project.name,
            toolType: project.toolType,
            toolSize: project.toolSize,
            toolNotes: project.toolNotes,
            photoChange: .replace(BackupFixture.jpegData(red: 0.2))
        )
        try fixture.journal.acknowledge(Set(try fixture.journal.pending().map(\.identity)))
        let firstPhoto = try #require(fixture.store.project(id: project.id)?.photoFilename)
        try fixture.store.updateProject(
            id: project.id,
            name: project.name,
            toolType: project.toolType,
            toolSize: project.toolSize,
            toolNotes: project.toolNotes,
            photoChange: .replace(BackupFixture.jpegData(red: 0.4))
        )
        try fixture.journal.acknowledge(Set(try fixture.journal.pending().map(\.identity)))
        let secondPhoto = try #require(fixture.store.project(id: project.id)?.photoFilename)
        #expect(firstPhoto != secondPhoto)
        let before = try #require(try fixture.checkpoints.load())
        let historical = before.records.filter { $0.id.kind == .attachment }
        #expect(historical.count == 2)
        #expect(try fixture.journal.pending().isEmpty)

        let remoteRoot = fixture.root.appendingPathComponent("RemoteStaging")
        let remotePhotos = ProjectPhotoFileService(
            directory: remoteRoot.appendingPathComponent("ProjectPhotos")
        )
        var remoteArchive = try JSONDecoder().decode(
            ProjectArchive.self,
            from: Data(contentsOf: fixture.archiveURL)
        )
        let remoteIndex = try #require(remoteArchive.projects.firstIndex { $0.id == project.id })
        let remoteFilename = try remotePhotos.save(
            data: BackupFixture.jpegData(red: 0.8),
            projectID: project.id
        )
        remoteArchive.projects[remoteIndex].setPhotoFilename(remoteFilename)
        let exported = try ProjectArchiveSyncMapper.export(
            archive: remoteArchive,
            liveRoot: remoteRoot,
            deviceID: "combined-remote-media",
            issuedAttachmentRecords: historical
        )
        let attachmentID = try #require(exported.attachments.keys.first {
            candidate in !historical.contains { $0.id.uuid == candidate }
        })
        let originalSource = try #require(exported.attachments[attachmentID])
        var remoteRecords = exported.records.filter {
            $0.id == .init(kind: .project, uuid: project.id)
                || $0.id == .init(kind: .attachment, uuid: attachmentID)
        }
        let remoteStamp = SyncMutationStamp(
            logicalRevision: 3_000,
            modifiedAt: Date(timeIntervalSince1970: 2_200_000_000),
            deviceID: "combined-remote-media"
        )
        let remoteProjectIndex = try #require(remoteRecords.firstIndex {
            $0.id == .init(kind: .project, uuid: project.id)
        })
        remoteRecords[remoteProjectIndex].payload.fields = remoteRecords[remoteProjectIndex]
            .payload.fields.mapValues { .init(value: $0.value, stamp: remoteStamp) }
        remoteRecords[remoteProjectIndex].deletedAt = .init(value: nil, stamp: remoteStamp)
        let incoming = try SyncRemoteBatch(
            accountIDHash: fixture.account.accountIDHash,
            batchID: UUID(),
            records: remoteRecords,
            deletedRecordIDs: []
        )
        let stagedDirectory = fixture.root.appendingPathComponent("VerifiedIncoming")
        try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
        let stagedURL = stagedDirectory.appendingPathComponent("remote-photo.bin")
        try FileManager.default.copyItem(at: originalSource.fileURL, to: stagedURL)
        let stagedBytes = try Data(contentsOf: stagedURL)
        let stagedSource = try SyncAttachmentSource(
            fileURL: stagedURL,
            contentSHA256: originalSource.contentSHA256,
            byteCount: originalSource.byteCount
        )
        let prepared = try fixture.store.prepareRemoteBatch(
            incoming,
            attachmentSources: [attachmentID: stagedSource]
        )
        let retainedCandidate = try #require(prepared.transaction?.canonicalTransition?.candidate)
        let expectedDependentRecord = try #require(retainedCandidate.records.first {
            $0.id == .init(kind: .project, uuid: project.id)
        })
        let expectedDependentVersion = try SyncRecordVersion(record: expectedDependentRecord)
        guard case let .committed(receipt) = try fixture.store.commitRemoteBatch(prepared) else {
            Issue.record("Expected staged attachment commit")
            return
        }

        let after = try #require(try fixture.checkpoints.load())
        #expect(after.records == retainedCandidate.records)
        let afterAttachments = after.records.filter { $0.id.kind == .attachment }
        for prior in historical {
            let expected = try #require(retainedCandidate.records.first { $0.id == prior.id })
            let retained = try #require(afterAttachments.first { $0.id == prior.id })
            #expect(retained == expected)
        }
        let expectedAttachment = try #require(retainedCandidate.records.first {
            $0.id == .init(kind: .attachment, uuid: attachmentID)
        })
        #expect(afterAttachments.first { $0.id == expectedAttachment.id } == expectedAttachment)
        #expect(Set(afterAttachments.map(\.id)) == Set(historical.map(\.id)).union([
            .init(kind: .attachment, uuid: attachmentID),
        ]))
        let selectedFilename = try #require(fixture.store.project(id: project.id)?.photoFilename)
        let installedURL = fixture.root.appendingPathComponent("Live/ProjectPhotos/")
            .appendingPathComponent(selectedFilename)
        #expect(try Data(contentsOf: installedURL) == stagedBytes)
        #expect(try Data(contentsOf: stagedURL) == stagedBytes)
        let exactPending = try fixture.journal.pending()
        #expect(exactPending.count == 1)
        let dependentSave = try #require(exactPending.first)
        #expect(dependentSave.recordID == .init(kind: .project, uuid: project.id))
        #expect(dependentSave.intent == .save)
        #expect(dependentSave.attachmentSource == nil)
        #expect(dependentSave.savedRecordVersion == expectedDependentVersion)
        #expect(after.records.first { $0.id == dependentSave.recordID }
            == expectedDependentRecord)
        let exactArchive = try Data(contentsOf: fixture.archiveURL)
        let replay = try fixture.store.prepareRemoteBatch(
            incoming,
            attachmentSources: [attachmentID: stagedSource]
        )
        #expect(try fixture.store.commitRemoteBatch(replay) == .alreadyCommitted(receipt))
        #expect(try fixture.journal.pending() == exactPending)
        #expect(try fixture.checkpoints.load() == after)
        #expect(try Data(contentsOf: fixture.archiveURL) == exactArchive)
        #expect(try Data(contentsOf: installedURL) == stagedBytes)
        #expect(try Data(contentsOf: stagedURL) == stagedBytes)
    }

    @Test
    func retainedTombstoneCommitsButUnprovenRawDeletePreservesEveryAuthority() throws {
        let fixture = try RemoteBatchFixture(); defer { fixture.remove() }
        try fixture.acknowledgeBootstrap()
        let deletedID = fixture.projectID
        let unsupportedProject = try #require(
            fixture.store.projects.first { $0.id != deletedID }
        )
        let unsupportedID = unsupportedProject.id
        try fixture.store.delete(id: deletedID)
        let ledger = try SyncDeletionLedger(
            root: SyncDeletionLedger.root(archiveURL: fixture.archiveURL)
        )
        let retainedEntry = try #require(try ledger.recentlyDeleted().first)
        let retainedFiles = try Dictionary(uniqueKeysWithValues: retainedEntry.files.map {
            ($0.retainedRelativePath, try Data(contentsOf: ledger.root.appendingPathComponent($0.retainedRelativePath)))
        })
        let deletedRecordID = SyncEntityID(kind: .project, uuid: deletedID)
        let tombstones = retainedEntry.exactRemovalVersions.map(\.record)
        #expect(tombstones.contains { $0.id == deletedRecordID && $0.deletedAt.value != nil })
        let pending = try fixture.journal.pending()
        let batch = try SyncRemoteBatch(
            accountIDHash: fixture.account.accountIDHash,
            batchID: UUID(),
            records: tombstones,
            deletedRecordIDs: []
        )
        guard case .committed = try fixture.store.commitRemoteBatch(
            fixture.store.prepareRemoteBatch(batch, attachmentSources: [:])
        ) else {
            Issue.record("Expected retained tombstone commit")
            return
        }
        let accepted = try #require(try fixture.checkpoints.load())
        for tombstone in tombstones {
            #expect(accepted.records.first { $0.id == tombstone.id } == tombstone)
        }
        #expect(try fixture.journal.pending() == pending)
        #expect(try ledger.recentlyDeleted().contains { $0.id == retainedEntry.id })
        for (relativePath, bytes) in retainedFiles {
            #expect(try Data(contentsOf: ledger.root.appendingPathComponent(relativePath)) == bytes)
        }

        let archive = try Data(contentsOf: fixture.archiveURL)
        let journal = try fixture.journalAuthority()
        let ledgerBytes = try Data(contentsOf: ledger.root.appendingPathComponent("ledger.json"))
        let unsupported = try SyncRemoteBatch(
            accountIDHash: fixture.account.accountIDHash,
            batchID: UUID(),
            records: [],
            deletedRecordIDs: [.init(kind: .project, uuid: unsupportedID)]
        )
        #expect(throws: SyncRemoteBatchError.unprovenDeletion) {
            _ = try fixture.store.prepareRemoteBatch(unsupported, attachmentSources: [:])
        }
        #expect(try fixture.checkpoints.load() == accepted)
        #expect(try Data(contentsOf: fixture.archiveURL) == archive)
        #expect(try fixture.journalAuthority() == journal)
        #expect(try Data(contentsOf: ledger.root.appendingPathComponent("ledger.json")) == ledgerBytes)
        for (relativePath, bytes) in retainedFiles {
            #expect(try Data(contentsOf: ledger.root.appendingPathComponent(relativePath)) == bytes)
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
