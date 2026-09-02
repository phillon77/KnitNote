import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KnitNoteCore

@Suite(.serialized) @MainActor struct JSONProjectStoreSyncPublicationTests {
    @Test func rebuiltLedgerUsesProjectedEntityRevisionAsItsCausalFloor() throws {
        let fixture = try SyncPublicationFixture()
        let sink = RecordingSyncMutationSink()
        let store = fixture.store(sink: sink)

        try store.rename(id: fixture.projectID, to: "First")
        let firstRevision = try #require(sink.mutations.last?.savedRecordVersion?.record.entityRevision)
        try FileManager.default.removeItem(
            at: fixture.liveRoot.appendingPathComponent("SyncMetadata/revision-ledger.json")
        )
        try store.rename(id: fixture.projectID, to: "Second")
        let secondRevision = try #require(sink.mutations.last?.savedRecordVersion?.record.entityRevision)

        #expect(firstRevision > 0)
        #expect(secondRevision == firstRevision + 1)
    }

    @Test func newPublicationTransactionRejectsMissingV3Receipts() throws {
        let fixture = try SyncPublicationFixture()
        let first = fixture.store(sink: RecordingSyncMutationSink(shouldFail: true))
        try first.rename(id: fixture.projectID, to: "Receipt source")
        let transaction = try #require(try SyncPublicationTransactionFile(
            archiveURL: fixture.archiveURL
        ).load())

        #expect(throws: SyncPublicationTransactionFileError.corrupt) {
            _ = try SyncPublicationTransaction(
                expectedArchiveSHA256: transaction.expectedArchiveSHA256,
                mutations: transaction.mutations,
                revisionReceipts: []
            )
        }
    }

    @Test func publicationMarkerPersistsCausalReceiptForRestartRecovery() throws {
        let fixture = try SyncPublicationFixture()
        let first = fixture.store(sink: RecordingSyncMutationSink(shouldFail: true))

        try first.rename(id: fixture.projectID, to: "Causal")

        let transaction = try #require(try SyncPublicationTransactionFile(
            archiveURL: fixture.archiveURL
        ).load())
        let saved = try #require(transaction.mutations.first?.savedRecordVersion?.record)
        let receipt = try #require(transaction.revisionReceipts.first)
        #expect(receipt.entityID == saved.id)
        #expect(receipt.logicalRevision == saved.entityRevision)
        #expect(receipt.deviceID == saved.deletedAt.stamp.deviceID)

        let repairSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: repairSink)
        try restarted.repairSyncPublication()
        #expect(repairSink.mutations == transaction.mutations)
    }

    @Test func successfulMutationPublishesOnlyAfterArchiveCommit() throws {
        let fixture = try SyncPublicationFixture()
        let sink = RecordingSyncMutationSink(archiveURL: fixture.archiveURL)
        let store = fixture.store(sink: sink)

        try store.rename(id: fixture.projectID, to: "Committed")

        #expect(sink.archiveProjectNamesAtPublication == ["Committed"])
        #expect(sink.mutations.map(\.recordKind) == [.project])
        #expect(store.syncPublicationError == nil)
    }

    @Test func archiveFailurePublishesNothingAndClearsPreparedTransaction() throws {
        let fixture = try SyncPublicationFixture()
        let sink = RecordingSyncMutationSink()
        let store = fixture.store(
            sink: sink,
            archiveWrite: { _, _ in throw SyncPublicationInjectedFailure() }
        )
        let archiveBefore = try Data(contentsOf: fixture.archiveURL)
        let filesBefore = try fixture.regularFiles()

        #expect(throws: ProjectStoreError.persistenceFailed) {
            try store.rename(id: fixture.projectID, to: "Rejected")
        }

        #expect(sink.mutations.isEmpty)
        #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)
        #expect(try fixture.regularFiles() == filesBefore)
        #expect(store.syncPublicationError == nil)
    }

    @Test func unlinkPublishesOnlyLinkDeletionAndNeverYarnDeletion() throws {
        let fixture = try SyncPublicationFixture(linkYarn: true)
        let sink = RecordingSyncMutationSink()
        let store = fixture.store(sink: sink)

        try store.setYarnProjects(yarnID: fixture.yarnID, projectIDs: [])

        #expect(sink.mutations.count == 1)
        #expect(sink.mutations.map(\.operation) == [.delete])
        #expect(sink.mutations.map(\.recordKind) == [.projectYarnLink])
        #expect(store.yarn(id: fixture.yarnID) != nil)
        #expect(store.yarn(id: fixture.yarnID)?.linkedProjectIDs.isEmpty == true)
    }

    @Test func publicationFailurePreservesCommittedPhotoAndBlocksUntilRestartRepair() throws {
        let fixture = try SyncPublicationFixture()
        let failingSink = RecordingSyncMutationSink(shouldFail: true)
        let store = fixture.store(sink: failingSink)
        let project = try #require(store.project(id: fixture.projectID))

        try store.updateProject(
            id: project.id,
            name: "Committed with photo",
            toolType: project.toolType,
            toolSize: project.toolSize,
            toolNotes: project.toolNotes,
            photoChange: .replace(try makeSyncPublicationJPEG(red: 0.3))
        )

        #expect(store.syncPublicationError == .pendingRepair)
        let committed = try #require(store.project(id: fixture.projectID))
        let committedPhotoURL = try #require(store.photoURL(for: committed))
        #expect(FileManager.default.fileExists(atPath: committedPhotoURL.path))
        let persisted = try fixture.archive()
        #expect(persisted.projects.first?.name == "Committed with photo")
        #expect(persisted.projects.first?.photoFilename == committed.photoFilename)

        let archiveBeforeRejectedMutation = try Data(contentsOf: fixture.archiveURL)
        let photoFilesBeforeRejectedMutation = try fixture.projectPhotoFiles()
        #expect(throws: SyncPublicationError.pendingRepair) {
            try store.updateProject(
                id: committed.id,
                name: "Must not commit",
                toolType: committed.toolType,
                toolSize: committed.toolSize,
                toolNotes: committed.toolNotes,
                photoChange: .replace(try makeSyncPublicationJPEG(red: 0.8))
            )
        }
        #expect(try Data(contentsOf: fixture.archiveURL) == archiveBeforeRejectedMutation)
        #expect(try fixture.projectPhotoFiles() == photoFilesBeforeRejectedMutation)

        let loadedTransaction = try SyncPublicationTransactionFile(
            archiveURL: fixture.archiveURL
        ).load()
        let exactPendingMutations = try #require(loadedTransaction).mutations
        let repairSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: repairSink)
        #expect(restarted.syncPublicationError == .pendingRepair)
        #expect(restarted.project(id: fixture.projectID)?.name == "Committed with photo")
        #expect(FileManager.default.fileExists(atPath: committedPhotoURL.path))

        try restarted.repairSyncPublication()

        #expect(repairSink.mutations == exactPendingMutations)
        #expect(restarted.syncPublicationError == nil)
        try restarted.rename(id: fixture.projectID, to: "Unblocked")
        #expect(restarted.project(id: fixture.projectID)?.name == "Unblocked")
        #expect(restarted.syncPublicationError == nil)
    }

    @Test func pendingPublicationBlocksBackupRestoreBeforeItTouchesLiveData() async throws {
        let fixture = try SyncPublicationFixture()
        let store = fixture.store(sink: RecordingSyncMutationSink(shouldFail: true))
        try store.rename(id: fixture.projectID, to: "Committed before restore")
        let archiveBefore = try Data(contentsOf: fixture.archiveURL)
        let filesBefore = try fixture.regularFiles()
        let unavailableBackup = StagedKnitNoteBackup(
            root: fixture.root.appendingPathComponent("must-not-be-opened.knitnote-backup"),
            preview: KnitNoteBackupPreview(
                createdAt: .now,
                projectCount: 0,
                yarnCount: 0
            )
        )

        await #expect(throws: SyncPublicationError.pendingRepair) {
            try await store.restoreBackup(unavailableBackup)
        }

        #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)
        #expect(try fixture.regularFiles() == filesBefore)
        #expect(store.syncPublicationError == .pendingRepair)
    }

    @Test func restartFailsClosedWhenArchiveCommittedAttachmentEvidenceIsMissing() throws {
        let fixture = try SyncPublicationFixture()
        let first = fixture.store(sink: RecordingSyncMutationSink(shouldFail: true))
        let project = try #require(first.project(id: fixture.projectID))
        try first.updateProject(
            id: project.id,
            name: project.name,
            toolType: project.toolType,
            toolSize: project.toolSize,
            toolNotes: project.toolNotes,
            photoChange: .replace(try makeSyncPublicationJPEG(red: 0.35))
        )
        let committed = try #require(first.project(id: fixture.projectID))
        let photoURL = try #require(first.photoURL(for: committed))
        try FileManager.default.removeItem(at: photoURL)

        let restartedSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: restartedSink)

        #expect(restarted.syncPublicationError == .corruptTransaction)
        #expect(throws: SyncPublicationError.corruptTransaction) {
            try restarted.rename(id: fixture.projectID, to: "Blocked")
        }
        #expect(restartedSink.mutations.isEmpty)
    }

    @Test func projectPhotoPublishesStableAttachmentSaveAndDelete() throws {
        let fixture = try SyncPublicationFixture()
        let firstSink = RecordingSyncMutationSink()
        let first = fixture.store(sink: firstSink)
        let project = try #require(first.project(id: fixture.projectID))

        try first.updateProject(
            id: project.id,
            name: project.name,
            toolType: project.toolType,
            toolSize: project.toolSize,
            toolNotes: project.toolNotes,
            photoChange: .replace(try makeSyncPublicationJPEG(red: 0.2))
        )

        let firstAttachment = try #require(firstSink.mutations.first {
            $0.recordKind == .attachment
        })
        #expect(firstAttachment.operation == .save)

        let secondSink = RecordingSyncMutationSink()
        let second = fixture.store(sink: secondSink)
        let committed = try #require(second.project(id: fixture.projectID))
        try second.updateProject(
            id: committed.id,
            name: committed.name,
            toolType: committed.toolType,
            toolSize: committed.toolSize,
            toolNotes: committed.toolNotes,
            photoChange: .remove
        )

        let attachmentDeletes = secondSink.mutations.filter {
            $0.recordKind == .attachment && $0.operation == .delete
        }
        #expect(attachmentDeletes.count == 1)
        #expect(attachmentDeletes.first?.recordID == firstAttachment.recordID)
    }

    @Test func realJournalRetainsSaveReplaceDeleteVersionsAcrossStoreAndJournalRestarts() throws {
        let fixture = try SyncPublicationFixture()
        let journalURL = fixture.root.appendingPathComponent("sync-mutations.json")
        let firstBytes = try makeSyncPublicationJPEG(red: 0.15)
        let secondBytes = try makeSyncPublicationJPEG(red: 0.85)

        let firstJournal = FileSyncMutationJournal(url: journalURL)
        let firstStore = fixture.store(sink: JournalSyncMutationSink(journal: firstJournal))
        let original = try #require(firstStore.project(id: fixture.projectID))
        try firstStore.updateProject(
            id: original.id,
            name: original.name,
            toolType: original.toolType,
            toolSize: original.toolSize,
            toolNotes: original.toolNotes,
            photoChange: .replace(firstBytes)
        )
        let firstSave = try #require(try firstJournal.pending().first(where: {
            $0.attachmentSource != nil
                && $0.savedRecordVersion?.record.payload.attachment?.slot.role == "project-photo"
        }))
        let firstSource = try #require(firstSave.attachmentSource)
        let firstCommittedProject = try #require(firstStore.project(id: fixture.projectID))
        let firstCommittedURL = try #require(firstStore.photoURL(for: firstCommittedProject))
        let firstCommittedBytes = try Data(contentsOf: firstCommittedURL)
        #expect(firstSource.isJournalStaged)
        #expect(try Data(contentsOf: firstSource.fileURL) == firstCommittedBytes)

        let secondJournal = FileSyncMutationJournal(url: journalURL)
        let secondStore = fixture.store(sink: JournalSyncMutationSink(journal: secondJournal))
        let withFirstPhoto = try #require(secondStore.project(id: fixture.projectID))
        try secondStore.updateProject(
            id: withFirstPhoto.id,
            name: withFirstPhoto.name,
            toolType: withFirstPhoto.toolType,
            toolSize: withFirstPhoto.toolSize,
            toolNotes: withFirstPhoto.toolNotes,
            photoChange: .replace(secondBytes)
        )
        let photoSaves = try secondJournal.pending().filter {
            $0.savedRecordVersion?.record.payload.attachment?.slot.role == "project-photo"
        }
        #expect(photoSaves.count == 2)
        let replacement = try #require(photoSaves.last)
        #expect(replacement.recordID != firstSave.recordID)
        #expect(
            replacement.savedRecordVersion?.record.payload.attachment?.replacesVersionID
                == firstSave.recordID.uuid
        )
        let secondCommittedProject = try #require(secondStore.project(id: fixture.projectID))
        let secondCommittedURL = try #require(secondStore.photoURL(for: secondCommittedProject))
        let secondCommittedBytes = try Data(contentsOf: secondCommittedURL)
        let replacementSource = try #require(replacement.attachmentSource)
        #expect(try Data(contentsOf: firstSource.fileURL) == firstCommittedBytes)
        #expect(try Data(contentsOf: replacementSource.fileURL) == secondCommittedBytes)

        let thirdJournal = FileSyncMutationJournal(url: journalURL)
        let thirdStore = fixture.store(sink: JournalSyncMutationSink(journal: thirdJournal))
        let withReplacement = try #require(thirdStore.project(id: fixture.projectID))
        try thirdStore.updateProject(
            id: withReplacement.id,
            name: withReplacement.name,
            toolType: withReplacement.toolType,
            toolSize: withReplacement.toolSize,
            toolNotes: withReplacement.toolNotes,
            photoChange: .remove
        )

        let restartedJournal = FileSyncMutationJournal(url: journalURL)
        let restartedPending = try restartedJournal.pending()
        #expect(restartedPending.contains(firstSave))
        #expect(restartedPending.contains(replacement))
        #expect(restartedPending.contains {
            $0.intent == .delete && $0.recordID == replacement.recordID
        })
        #expect(!restartedPending.contains {
            $0.intent == .delete && $0.recordID == firstSave.recordID
        })
        #expect(try Data(contentsOf: firstSource.fileURL) == firstCommittedBytes)

        try restartedJournal.acknowledge([firstSave.identity])
        #expect(!FileManager.default.fileExists(atPath: firstSource.fileURL.path))
        #expect(try restartedJournal.pending().contains(replacement))
    }

    @Test func yarnPhotoAndLabelsPublishStableAttachmentSavesAndDeletes() throws {
        let fixture = try SyncPublicationFixture()
        let firstSink = RecordingSyncMutationSink()
        let first = fixture.store(sink: firstSink)
        let yarn = try #require(first.yarn(id: fixture.yarnID))

        try first.updateYarn(
            yarn,
            photoChange: .replace(try makeSyncPublicationJPEG(red: 0.2)),
            labelPhotoChange: .replace(
                first: try makeSyncPublicationJPEG(red: 0.4),
                second: try makeSyncPublicationJPEG(red: 0.6)
            )
        )

        let savedAttachmentIDs = Set(firstSink.mutations.compactMap {
            $0.recordKind == .attachment && $0.operation == .save ? $0.recordID : nil
        })
        #expect(savedAttachmentIDs.count == 3)

        let secondSink = RecordingSyncMutationSink()
        let second = fixture.store(sink: secondSink)
        let committed = try #require(second.yarn(id: fixture.yarnID))
        try second.updateYarn(
            committed,
            photoChange: .remove,
            labelPhotoChange: .removeAll
        )

        let deletedAttachmentIDs = Set(secondSink.mutations.compactMap {
            $0.recordKind == .attachment && $0.operation == .delete ? $0.recordID : nil
        })
        #expect(deletedAttachmentIDs == savedAttachmentIDs)
    }

    @Test func journalPhotoPairPublishesStableAttachmentSavesAndDeletes() async throws {
        let fixture = try SyncPublicationFixture()
        let firstSink = RecordingSyncMutationSink()
        let first = fixture.store(sink: firstSink)

        try await first.addJournalEntry(
            projectID: fixture.projectID,
            photoData: try makeSyncPublicationJPEG(red: 0.7),
            caption: "Committed"
        )

        let entry = try #require(first.project(id: fixture.projectID)?.journalEntries.first)
        let savedAttachmentIDs = Set(firstSink.mutations.compactMap {
            $0.recordKind == .attachment && $0.operation == .save ? $0.recordID : nil
        })
        #expect(savedAttachmentIDs.count == 2)

        let secondSink = RecordingSyncMutationSink()
        let second = fixture.store(sink: secondSink)
        try second.deleteJournalEntry(projectID: fixture.projectID, entryID: entry.id)

        let deletedAttachmentIDs = Set(secondSink.mutations.compactMap {
            $0.recordKind == .attachment && $0.operation == .delete ? $0.recordID : nil
        })
        #expect(deletedAttachmentIDs == savedAttachmentIDs)
    }

    @Test func usageMarkupPublishesStableAttachmentSaveAndDelete() throws {
        let fixture = try SyncPublicationFixture()
        let usageID = try fixture.installPatternUsage()
        let firstSink = RecordingSyncMutationSink()
        let first = fixture.store(sink: firstSink)
        let markup = syncPublicationMarkup(color: .blue)

        try first.savePatternMarkup(
            markup,
            usageID: usageID,
            pageIndex: 2,
            expectedDataGeneration: first.dataGeneration
        )

        let saved = try #require(firstSink.mutations.onlyAttachment)
        #expect(saved.operation == .save)
        #expect(try first.loadPatternMarkup(usageID: usageID, pageIndex: 2) == markup)

        let secondSink = RecordingSyncMutationSink()
        let second = fixture.store(sink: secondSink)
        try second.savePatternMarkup(
            PatternMarkupDocument(),
            usageID: usageID,
            pageIndex: 2,
            expectedDataGeneration: second.dataGeneration
        )

        let deleted = try #require(secondSink.mutations.onlyAttachment)
        #expect(deleted.operation == .delete)
        #expect(deleted.recordID == saved.recordID)
        #expect(try second.loadPatternMarkup(usageID: usageID, pageIndex: 2).strokes.isEmpty)
    }

    @Test func legacyMarkupPublishesStableAttachmentSaveAndDelete() throws {
        let fixture = try SyncPublicationFixture()
        let patternID = try fixture.installLegacyPattern()
        let firstSink = RecordingSyncMutationSink()
        let first = fixture.store(sink: firstSink)
        let markup = syncPublicationMarkup(color: .green)

        try first.savePatternMarkup(
            markup,
            projectID: fixture.projectID,
            patternID: patternID,
            pageIndex: 3,
            expectedDataGeneration: first.dataGeneration
        )

        let saved = try #require(firstSink.mutations.onlyAttachment)
        #expect(saved.operation == .save)
        #expect(try first.loadPatternMarkup(
            projectID: fixture.projectID,
            patternID: patternID,
            pageIndex: 3
        ) == markup)

        let secondSink = RecordingSyncMutationSink()
        let second = fixture.store(sink: secondSink)
        try second.savePatternMarkup(
            PatternMarkupDocument(),
            projectID: fixture.projectID,
            patternID: patternID,
            pageIndex: 3,
            expectedDataGeneration: second.dataGeneration
        )

        let deleted = try #require(secondSink.mutations.onlyAttachment)
        #expect(deleted.operation == .delete)
        #expect(deleted.recordID == saved.recordID)
    }

    @Test func usageMarkupSinkFailurePersistsAcrossRestartAndBlocksLaterFileWrites() throws {
        let fixture = try SyncPublicationFixture()
        let usageID = try fixture.installPatternUsage()
        let failingSink = RecordingSyncMutationSink(shouldFail: true)
        let first = fixture.store(sink: failingSink)
        let committedMarkup = syncPublicationMarkup(color: .red)

        try first.savePatternMarkup(
            committedMarkup,
            usageID: usageID,
            pageIndex: 4,
            expectedDataGeneration: first.dataGeneration
        )

        #expect(first.syncPublicationError == .pendingRepair)
        #expect(try first.loadPatternMarkup(usageID: usageID, pageIndex: 4) == committedMarkup)
        #expect(throws: SyncPublicationError.pendingRepair) {
            try first.savePatternMarkup(
                syncPublicationMarkup(color: .blue),
                usageID: usageID,
                pageIndex: 5,
                expectedDataGeneration: first.dataGeneration
            )
        }
        #expect(try first.loadPatternMarkup(usageID: usageID, pageIndex: 5).strokes.isEmpty)

        let repairSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: repairSink)
        #expect(restarted.syncPublicationError == .pendingRepair)
        #expect(try restarted.loadPatternMarkup(usageID: usageID, pageIndex: 4) == committedMarkup)

        try restarted.repairSyncPublication()

        #expect(repairSink.mutations == failingSink.mutations)
        #expect(restarted.syncPublicationError == nil)
    }

    @Test func usageMarkupArchiveFailureRestoresOriginalFileAndPublishesNothing() throws {
        let fixture = try SyncPublicationFixture()
        let usageID = try fixture.installPatternUsage()
        let setup = fixture.store(sink: RecordingSyncMutationSink())
        let original = syncPublicationMarkup(color: .green)
        try setup.savePatternMarkup(
            original,
            usageID: usageID,
            pageIndex: 6,
            expectedDataGeneration: setup.dataGeneration
        )
        let sink = RecordingSyncMutationSink()
        let failing = fixture.store(
            sink: sink,
            archiveWrite: { _, _ in throw SyncPublicationInjectedFailure() }
        )

        #expect(throws: ProjectStoreError.persistenceFailed) {
            try failing.savePatternMarkup(
                syncPublicationMarkup(color: .blue),
                usageID: usageID,
                pageIndex: 6,
                expectedDataGeneration: failing.dataGeneration
            )
        }

        #expect(try failing.loadPatternMarkup(usageID: usageID, pageIndex: 6) == original)
        #expect(sink.mutations.isEmpty)
        #expect(failing.syncPublicationError == nil)
        #expect(fixture.store(sink: RecordingSyncMutationSink()).syncPublicationError == nil)
    }

    @Test func legacyMarkupSinkFailureSurvivesRestartForExactRepair() throws {
        let fixture = try SyncPublicationFixture()
        let patternID = try fixture.installLegacyPattern()
        let failingSink = RecordingSyncMutationSink(shouldFail: true)
        let first = fixture.store(sink: failingSink)
        let markup = syncPublicationMarkup(color: .black)
        try first.savePatternMarkup(
            markup,
            projectID: fixture.projectID,
            patternID: patternID,
            pageIndex: 7,
            expectedDataGeneration: first.dataGeneration
        )
        #expect(first.syncPublicationError == .pendingRepair)

        let repairSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: repairSink)
        #expect(restarted.syncPublicationError == .pendingRepair)
        #expect(try restarted.loadPatternMarkup(
            projectID: fixture.projectID,
            patternID: patternID,
            pageIndex: 7
        ) == markup)

        try restarted.repairSyncPublication()

        #expect(repairSink.mutations == failingSink.mutations)
        #expect(restarted.syncPublicationError == nil)
    }

    @Test func deletingProjectPublishesDeletesForItsUsageMarkupPages() throws {
        let fixture = try SyncPublicationFixture()
        let usageID = try fixture.installPatternUsage()
        let setupSink = RecordingSyncMutationSink()
        let setup = fixture.store(sink: setupSink)
        try setup.savePatternMarkup(
            syncPublicationMarkup(color: .green),
            usageID: usageID,
            pageIndex: 8,
            expectedDataGeneration: setup.dataGeneration
        )
        let markupID = try #require(setupSink.mutations.onlyAttachment?.recordID)

        let deletionSink = RecordingSyncMutationSink()
        let deleting = fixture.store(sink: deletionSink)
        try deleting.delete(id: fixture.projectID)

        #expect(deletionSink.mutations.contains {
            $0.operation == .delete && $0.recordID == markupID
        })
        #expect(!FileManager.default.fileExists(
            atPath: fixture.usageMarkupURL(usageID: usageID, pageIndex: 8).path
        ))
    }

    @Test func deletingLegacyPatternPublishesMarkupAndSourceAttachmentDeletes() throws {
        let fixture = try SyncPublicationFixture()
        let patternID = try fixture.installLegacyPattern()
        let setupSink = RecordingSyncMutationSink()
        let setup = fixture.store(sink: setupSink)
        try setup.savePatternMarkup(
            syncPublicationMarkup(color: .red),
            projectID: fixture.projectID,
            patternID: patternID,
            pageIndex: 9,
            expectedDataGeneration: setup.dataGeneration
        )
        let markupID = try #require(setupSink.mutations.onlyAttachment?.recordID)

        let deletionSink = RecordingSyncMutationSink()
        let deleting = fixture.store(sink: deletionSink)
        try deleting.deletePattern(projectID: fixture.projectID, id: patternID)

        let attachmentDeletes = deletionSink.mutations.filter {
            $0.operation == .delete && $0.recordKind == .attachment
        }
        #expect(attachmentDeletes.count == 2)
        #expect(attachmentDeletes.contains { $0.recordID == markupID })
        #expect(!FileManager.default.fileExists(
            atPath: fixture.legacyMarkupURL(
                projectID: fixture.projectID,
                patternID: patternID,
                pageIndex: 9
            ).path
        ))
    }

    @Test func restartDiscardsValidMarkerWhenArchiveDoesNotMatchExpectedCommit() throws {
        let fixture = try SyncPublicationFixture()
        let originalArchive = try Data(contentsOf: fixture.archiveURL)
        let failingSink = RecordingSyncMutationSink(shouldFail: true)
        let first = fixture.store(sink: failingSink)
        try first.rename(id: fixture.projectID, to: "Committed only in newer archive")
        #expect(first.syncPublicationError == .pendingRepair)

        try originalArchive.write(to: fixture.archiveURL, options: .atomic)
        let restartedSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: restartedSink)

        #expect(restarted.syncPublicationError == nil)
        #expect(restartedSink.mutations.isEmpty)
        #expect(restarted.project(id: fixture.projectID)?.name == "Original")
        try restarted.rename(id: fixture.projectID, to: "Fresh mutation")
        #expect(restartedSink.mutations.map(\.recordKind) == [.project])
    }

    @Test func startupReconcilesPendingMarkerBeforeArchiveMigrationCanRewriteIt() throws {
        let fixture = try SyncPublicationFixture()
        let current = try fixture.archive()
        let oldArchive = ProjectArchive(
            version: ProjectArchive.currentVersion - 1,
            projects: current.projects,
            yarns: current.yarns,
            patternFolders: current.patternFolders,
            patternAssets: current.patternAssets,
            patterns: current.patterns,
            patternUsages: current.patternUsages
        )
        let oldBytes = try JSONEncoder().encode(oldArchive)
        try oldBytes.write(to: fixture.archiveURL, options: .atomic)
        let mutation = SyncMutation.save(
            SyncEntityID(kind: .project, uuid: fixture.projectID),
            mutationID: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        )
        let transactionFile = SyncPublicationTransactionFile(archiveURL: fixture.archiveURL)
        try transactionFile.write(try SyncPublicationTransaction.legacy(
            expectedArchiveSHA256: SyncPublicationTransactionFile.fingerprint(of: oldBytes),
            mutations: [mutation]
        ))
        let sink = RecordingSyncMutationSink()

        let restarted = fixture.store(sink: sink)

        #expect(restarted.syncPublicationError == .pendingRepair)
        #expect(try Data(contentsOf: fixture.archiveURL) == oldBytes)
        #expect(throws: SyncPublicationError.pendingRepair) {
            try restarted.rename(id: fixture.projectID, to: "Blocked before migration")
        }
        #expect(sink.mutations.isEmpty)

        try restarted.repairSyncPublication()

        #expect(sink.mutations == [mutation])
        #expect(restarted.syncPublicationError == nil)
        #expect(try fixture.archive().version == ProjectArchive.currentVersion)
    }

    @Test func liveStartupDefersInterruptedBackupRecoveryWhilePublicationIsPending() throws {
        let fixture = try SyncPublicationFixture()
        let committedBytes = try Data(contentsOf: fixture.archiveURL)
        let mutation = SyncMutation.save(
            SyncEntityID(kind: .project, uuid: fixture.projectID),
            mutationID: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
        )
        let transactionFile = SyncPublicationTransactionFile(archiveURL: fixture.archiveURL)
        try transactionFile.write(try SyncPublicationTransaction.legacy(
            expectedArchiveSHA256: SyncPublicationTransactionFile.fingerprint(of: committedBytes),
            mutations: [mutation]
        ))
        let replacementJournalURL = try installInterruptedBackupRollback(
            baseDirectory: fixture.root,
            replacementProjectName: "Recovery must wait"
        )

        let restarted = JSONProjectStore.live(baseDirectory: fixture.root)

        #expect(restarted.syncPublicationError == .pendingRepair)
        #expect(restarted.project(id: fixture.projectID)?.name == "Original")
        #expect(try Data(contentsOf: fixture.archiveURL) == committedBytes)
        #expect(FileManager.default.fileExists(atPath: transactionFile.url.path))
        #expect(FileManager.default.fileExists(atPath: replacementJournalURL.path))
    }

    @Test func liveStartupRecoversBackupAfterDiscardingUncommittedPublication() throws {
        let fixture = try SyncPublicationFixture()
        let mutation = SyncMutation.save(
            SyncEntityID(kind: .project, uuid: fixture.projectID),
            mutationID: UUID(uuidString: "10000000-0000-0000-0000-000000000005")!
        )
        let transactionFile = SyncPublicationTransactionFile(archiveURL: fixture.archiveURL)
        try transactionFile.write(try SyncPublicationTransaction.legacy(
            expectedArchiveSHA256: SyncPublicationTransactionFile.fingerprint(
                of: Data("archive that never committed".utf8)
            ),
            mutations: [mutation]
        ))
        let replacementJournalURL = try installInterruptedBackupRollback(
            baseDirectory: fixture.root,
            replacementProjectName: "Recovered replacement"
        )

        let restarted = JSONProjectStore.live(baseDirectory: fixture.root)

        #expect(restarted.syncPublicationError == nil)
        #expect(restarted.project(id: fixture.projectID)?.name == "Recovered replacement")
        #expect(!FileManager.default.fileExists(atPath: transactionFile.url.path))
        #expect(!FileManager.default.fileExists(atPath: replacementJournalURL.path))
    }

    @Test func publicReloadReconcilesPendingMarkerBeforeMigration() throws {
        let fixture = try SyncPublicationFixture()
        let sink = RecordingSyncMutationSink()
        let store = fixture.store(sink: sink)
        let current = try fixture.archive()
        let oldArchive = ProjectArchive(
            version: ProjectArchive.currentVersion - 1,
            projects: current.projects,
            yarns: current.yarns,
            patternFolders: current.patternFolders,
            patternAssets: current.patternAssets,
            patterns: current.patterns,
            patternUsages: current.patternUsages
        )
        let oldBytes = try JSONEncoder().encode(oldArchive)
        try oldBytes.write(to: fixture.archiveURL, options: .atomic)
        let mutation = SyncMutation.save(
            SyncEntityID(kind: .project, uuid: fixture.projectID),
            mutationID: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        )
        try SyncPublicationTransactionFile(archiveURL: fixture.archiveURL).write(
            try SyncPublicationTransaction.legacy(
                expectedArchiveSHA256: SyncPublicationTransactionFile.fingerprint(of: oldBytes),
                mutations: [mutation]
            )
        )

        #expect(throws: SyncPublicationError.pendingRepair) {
            try store.reloadFromDisk()
        }

        #expect(store.syncPublicationError == .pendingRepair)
        #expect(try Data(contentsOf: fixture.archiveURL) == oldBytes)
        #expect(sink.mutations.isEmpty)
        try store.repairSyncPublication()
        #expect(sink.mutations == [mutation])
        #expect(try fixture.archive().version == ProjectArchive.currentVersion)
    }

    @Test func corruptPublicationTransactionSurvivesAndFailsClosed() throws {
        let fixture = try SyncPublicationFixture()
        let filesBefore = try fixture.regularFiles()
        let failingSink = RecordingSyncMutationSink(shouldFail: true)
        let first = fixture.store(sink: failingSink)
        try first.rename(id: fixture.projectID, to: "Committed")
        let newRegularFile = try fixture.newRegularFile(comparedWith: filesBefore)
        let transactionURL = try #require(newRegularFile)
        let corruptBytes = Data("not a publication transaction".utf8)
        try corruptBytes.write(to: transactionURL, options: .atomic)

        let restartedSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: restartedSink)

        #expect(restarted.syncPublicationError == .corruptTransaction)
        #expect(throws: SyncPublicationError.corruptTransaction) {
            try restarted.rename(id: fixture.projectID, to: "Blocked")
        }
        #expect(throws: SyncPublicationError.corruptTransaction) {
            try restarted.repairSyncPublication()
        }
        #expect(restartedSink.mutations.isEmpty)
        #expect(try Data(contentsOf: transactionURL) == corruptBytes)
    }

    @Test func fifoPublicationTransactionIsRejectedWithoutOpeningIt() throws {
        let fixture = try SyncPublicationFixture()
        let transactionURL = SyncPublicationTransactionFile(
            archiveURL: fixture.archiveURL
        ).url
        let created = transactionURL.path.withCString {
            Darwin.mkfifo($0, S_IRUSR | S_IWUSR)
        }
        #expect(created == 0)

        let restarted = fixture.store(sink: RecordingSyncMutationSink())

        #expect(restarted.syncPublicationError == .corruptTransaction)
        #expect(throws: SyncPublicationError.corruptTransaction) {
            try restarted.rename(id: fixture.projectID, to: "Blocked")
        }
    }

    @Test func oversizedPublicationTransactionIsRejectedFailClosed() throws {
        let fixture = try SyncPublicationFixture()
        let transactionURL = SyncPublicationTransactionFile(
            archiveURL: fixture.archiveURL
        ).url
        try Data(repeating: 0x41, count: 1_024 * 1_024 + 1).write(
            to: transactionURL,
            options: .atomic
        )

        let restarted = fixture.store(sink: RecordingSyncMutationSink())

        #expect(restarted.syncPublicationError == .corruptTransaction)
        #expect(throws: SyncPublicationError.corruptTransaction) {
            try restarted.repairSyncPublication()
        }
    }

    @Test func partialPublicationRetainsWholeIdempotentBatchForLinearRepair() throws {
        let fixture = try SyncPublicationFixture()
        let partialSink = RecordingSyncMutationSink(failureAtAttempt: 2)
        let first = fixture.store(sink: partialSink)
        let project = try #require(first.project(id: fixture.projectID))

        try first.updateProject(
            id: project.id,
            name: "Two records",
            toolType: project.toolType,
            toolSize: project.toolSize,
            toolNotes: project.toolNotes,
            photoChange: .replace(try makeSyncPublicationJPEG(red: 0.45))
        )

        #expect(first.syncPublicationError == .pendingRepair)
        #expect(partialSink.mutations.count == 2)
        let loadedTransaction = try SyncPublicationTransactionFile(
            archiveURL: fixture.archiveURL
        ).load()
        let pending = try #require(loadedTransaction).mutations
        #expect(pending == partialSink.mutations)

        let repairSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: repairSink)
        try restarted.repairSyncPublication()

        #expect(repairSink.mutations == pending)
        #expect(restarted.syncPublicationError == nil)
    }

    @Test func writeThenThrowKeepsReceiptMarkerAndDoesNotPublish() throws {
        let fixture = try SyncPublicationFixture()
        let sink = RecordingSyncMutationSink()
        let store = fixture.store(
            sink: sink,
            archiveWrite: { data, url in
                try data.write(to: url, options: .atomic)
                throw SyncPublicationInjectedFailure()
            }
        )

        try store.rename(id: fixture.projectID, to: "Durable but uncertain")

        #expect(store.project(id: fixture.projectID)?.name == "Durable but uncertain")
        #expect(store.syncPublicationError == .pendingRepair)
        #expect(sink.mutations.isEmpty)
        let loaded = try SyncPublicationTransactionFile(
            archiveURL: fixture.archiveURL
        ).load()
        let pending = try #require(loaded).mutations
        #expect(!pending.isEmpty)

        let repairSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: repairSink)
        #expect(restarted.syncPublicationError == .pendingRepair)
        try restarted.repairSyncPublication()
        #expect(repairSink.mutations == pending)
        #expect(restarted.syncPublicationError == nil)
    }

    @Test func liveFactoryInjectsOneAtomicBatchWhileDefaultScreenshotStyleStoreIsDisabled() throws {
        let enabledFixture = try SyncPublicationFixture()
        let batchSink = BatchRecordingSyncMutationSink()
        let enabled = JSONProjectStore.live(
            baseDirectory: enabledFixture.root,
            syncMutationSink: batchSink
        )

        try enabled.rename(id: enabledFixture.projectID, to: "Enabled")

        #expect(batchSink.batchCount == 1)
        #expect(batchSink.mutations.contains { $0.recordKind == .project })

        let disabledFixture = try SyncPublicationFixture()
        let disabled = JSONProjectStore.live(baseDirectory: disabledFixture.root)
        try disabled.rename(id: disabledFixture.projectID, to: "Screenshot")
        #expect(try SyncPublicationTransactionFile(
            archiveURL: disabledFixture.archiveURL
        ).load() == nil)
    }

    @Test func largeDeletionUsesCachedProjectionAndOneBoundedBatch() throws {
        let fixture = try SyncPublicationFixture()
        let current = try fixture.archive()
        let yarns = try (0..<1_500).map { index in
            try StoredYarn(
                id: syncPerformanceUUID(index),
                name: "Performance yarn \(index)"
            )
        }
        try JSONEncoder().encode(ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: current.projects,
            yarns: yarns
        )).write(to: fixture.archiveURL, options: .atomic)
        let sink = BatchRecordingSyncMutationSink()
        let store = fixture.store(sink: sink)
        let clock = ContinuousClock()

        let firstStart = clock.now
        try store.deleteYarn(id: yarns[0].id)
        let firstDuration = firstStart.duration(to: clock.now)
        let secondStart = clock.now
        try store.deleteYarn(id: yarns[1].id)
        let secondDuration = secondStart.duration(to: clock.now)

        #expect(firstDuration < .seconds(3))
        #expect(secondDuration < .seconds(3))
        #expect(sink.batchCount == 2)
        #expect(sink.mutations.filter {
            $0.intent == .delete && $0.recordKind == .yarn
        }.count == 2)
    }

    @Test func journalSinkSynchronouslyEnqueuesExactMutation() throws {
        let fixture = try SyncPublicationFixture()
        let journal = FileSyncMutationJournal(
            url: fixture.root.appendingPathComponent("sync-mutations.json")
        )
        let sink = JournalSyncMutationSink(journal: journal)
        let mutation = SyncMutation.save(
            SyncEntityID(kind: .project, uuid: fixture.projectID),
            mutationID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        )

        try sink.publish(mutation)

        #expect(try journal.pending() == [mutation])
    }
}

private struct SyncPublicationInjectedFailure: Error {}

private func syncPerformanceUUID(_ value: Int) -> UUID {
    UUID(uuidString: String(
        format: "00000000-0000-0000-0000-%012x",
        value + 1
    ))!
}

private final class RecordingSyncMutationSink: SyncMutationSink, @unchecked Sendable {
    private let lock = NSLock()
    private let archiveURL: URL?
    private let shouldFail: Bool
    private let failureAtAttempt: Int?
    private var recordedMutations: [SyncMutation] = []
    private var recordedArchiveProjectNames: [String] = []

    init(
        shouldFail: Bool = false,
        archiveURL: URL? = nil,
        failureAtAttempt: Int? = nil
    ) {
        self.shouldFail = shouldFail
        self.archiveURL = archiveURL
        self.failureAtAttempt = failureAtAttempt
    }

    func publish(_ mutation: SyncMutation) throws {
        let archiveName: String? = try archiveURL.map { url in
            let archive = try JSONDecoder().decode(
                ProjectArchive.self,
                from: Data(contentsOf: url)
            )
            return try #require(archive.projects.first?.name)
        }
        lock.lock()
        recordedMutations.append(mutation)
        if let archiveName {
            recordedArchiveProjectNames.append(archiveName)
        }
        let attempt = recordedMutations.count
        lock.unlock()
        if shouldFail || failureAtAttempt == attempt {
            throw SyncPublicationInjectedFailure()
        }
    }

    var mutations: [SyncMutation] {
        lock.withLock { recordedMutations }
    }

    var archiveProjectNamesAtPublication: [String] {
        lock.withLock { recordedArchiveProjectNames }
    }
}

private final class BatchRecordingSyncMutationSink: SyncMutationSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SyncMutation] = []
    private var batches = 0

    func publish(_ mutation: SyncMutation) throws {
        lock.withLock { recorded.append(mutation) }
    }

    func publish(_ mutations: [SyncMutation]) throws {
        lock.withLock {
            batches += 1
            recorded.append(contentsOf: mutations)
        }
    }

    var mutations: [SyncMutation] { lock.withLock { recorded } }
    var batchCount: Int { lock.withLock { batches } }
}

private extension SyncMutation {
    enum TestOperation: Equatable {
        case save
        case delete
    }

    var recordKind: SyncEntityKind {
        recordID.kind
    }

    var operation: TestOperation {
        switch self {
        case .save: .save
        case .delete: .delete
        }
    }

}

private extension Array where Element == SyncMutation {
    var onlyAttachment: SyncMutation? {
        let attachments = filter { $0.recordKind == .attachment }
        return attachments.count == 1 ? attachments[0] : nil
    }
}

@MainActor private final class SyncPublicationFixture {
    let root: URL
    let liveRoot: URL
    let archiveURL: URL
    let projectID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    let yarnID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    let assetID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
    let patternID = UUID(uuidString: "00000000-0000-0000-0000-000000000104")!
    let usageID = UUID(uuidString: "00000000-0000-0000-0000-000000000105")!
    let legacyPatternID = UUID(uuidString: "00000000-0000-0000-0000-000000000106")!

    init(linkYarn: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "json-project-store-sync-publication-\(UUID().uuidString)",
            isDirectory: true
        )
        liveRoot = root.appendingPathComponent("KnitNote", isDirectory: true)
        archiveURL = liveRoot.appendingPathComponent("projects-v1.json")
        try FileManager.default.createDirectory(at: liveRoot, withIntermediateDirectories: true)
        let project = try StoredProject(id: projectID, name: "Original")
        var yarn = try StoredYarn(id: yarnID, name: "Merino")
        if linkYarn {
            yarn.setLinkedProjectIDs([projectID])
        }
        try JSONEncoder().encode(ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: [project],
            yarns: [yarn]
        )).write(to: archiveURL, options: .atomic)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func store(
        sink: any SyncMutationSink,
        archiveWrite: @escaping @Sendable (Data, URL) throws -> Void = {
            try $0.write(to: $1, options: .atomic)
        }
    ) -> JSONProjectStore {
        JSONProjectStore(
            url: archiveURL,
            backupService: KnitNoteBackupService(
                liveRoot: liveRoot,
                workRoot: root.appendingPathComponent("BackupWork", isDirectory: true)
            ),
            archiveWrite: archiveWrite,
            syncMutationSink: sink
        )
    }

    func archive() throws -> ProjectArchive {
        try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: archiveURL))
    }

    func installPatternUsage() throws -> UUID {
        let patternsRoot = liveRoot.appendingPathComponent("Patterns", isDirectory: true)
        let assetsRoot = patternsRoot.appendingPathComponent("Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsRoot, withIntermediateDirectories: true)
        let filename = "\(assetID.uuidString).pdf"
        let assetURL = assetsRoot.appendingPathComponent(filename)
        try makeTestPatternPDF(at: assetURL)
        let bytes = try Data(contentsOf: assetURL)
        let asset = PatternAsset(
            id: assetID,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            kind: .pdf,
            storedFilename: filename,
            byteCount: Int64(bytes.count),
            pageCount: 1
        )
        let pattern = StoredPattern(
            id: patternID,
            assetID: assetID,
            displayName: "Fixture pattern"
        )
        let usage = PatternProjectUsage(
            id: usageID,
            patternID: patternID,
            projectID: projectID,
            sortOrder: 0
        )
        let current = try archive()
        try JSONEncoder().encode(ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: current.projects,
            yarns: current.yarns,
            patternAssets: [asset],
            patterns: [pattern],
            patternUsages: [usage]
        )).write(to: archiveURL, options: .atomic)
        return usageID
    }

    func installLegacyPattern() throws -> UUID {
        let current = try archive()
        var project = try #require(current.projects.first)
        project.addPattern(PatternDocument(
            id: legacyPatternID,
            displayName: "Legacy fixture",
            kind: .pdf,
            storedFilename: "\(legacyPatternID.uuidString).pdf"
        ))
        let sourceURL = liveRoot
            .appendingPathComponent("Patterns", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("\(legacyPatternID.uuidString).pdf")
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makeTestPatternPDF(at: sourceURL)
        try JSONEncoder().encode(ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: [project],
            yarns: current.yarns
        )).write(to: archiveURL, options: .atomic)
        return legacyPatternID
    }

    func usageMarkupURL(usageID: UUID, pageIndex: Int) -> URL {
        liveRoot.appendingPathComponent("Patterns/UsageMarkup/\(usageID.uuidString)/\(pageIndex).json")
    }

    func legacyMarkupURL(projectID: UUID, patternID: UUID, pageIndex: Int) -> URL {
        liveRoot.appendingPathComponent(
            "Patterns/\(projectID.uuidString)/Markup/\(patternID.uuidString)/\(pageIndex).json"
        )
    }

    func regularFiles() throws -> Set<URL> {
        let children = try FileManager.default.contentsOfDirectory(
            at: liveRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )
        return try Set(children.filter {
            try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        })
    }

    func newRegularFile(comparedWith original: Set<URL>) throws -> URL? {
        let candidates = try regularFiles().subtracting(original).filter { $0 != archiveURL }
        return candidates.count == 1 ? candidates.first : nil
    }

    func projectPhotoFiles() throws -> Set<String> {
        let directory = liveRoot.appendingPathComponent("ProjectPhotos", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }
}

private struct TestBackupReplacementPayload: Codable {
    let version: Int
    let transactionID: UUID
    let rollbackName: String
    let hadLiveRoot: Bool
    let phase: String
}

private struct TestBackupReplacementJournal: Codable {
    let version: Int
    let transactionID: UUID
    let rollbackName: String
    let hadLiveRoot: Bool
    let phase: String
    let integrity: String
}

private func installInterruptedBackupRollback(
    baseDirectory: URL,
    replacementProjectName: String
) throws -> URL {
    let liveRoot = baseDirectory.appendingPathComponent("KnitNote", isDirectory: true)
    let archiveURL = liveRoot.appendingPathComponent("projects-v1.json")
    let current = try JSONDecoder().decode(
        ProjectArchive.self,
        from: Data(contentsOf: archiveURL)
    )
    let originalProject = try #require(current.projects.first)
    let replacementProject = try StoredProject(
        id: originalProject.id,
        name: replacementProjectName
    )
    let transactionID = UUID()
    let rollbackName = "Rollback-\(transactionID.uuidString)"
    let workRoot = baseDirectory.appendingPathComponent(
        ".KnitNote-BackupWork",
        isDirectory: true
    )
    let rollbackRoot = workRoot.appendingPathComponent(rollbackName, isDirectory: true)
    try FileManager.default.createDirectory(
        at: rollbackRoot,
        withIntermediateDirectories: true
    )
    try JSONEncoder().encode(ProjectArchive(
        version: ProjectArchive.currentVersion,
        projects: [replacementProject],
        yarns: current.yarns
    )).write(
        to: rollbackRoot.appendingPathComponent("projects-v1.json"),
        options: .atomic
    )

    let payload = TestBackupReplacementPayload(
        version: 1,
        transactionID: transactionID,
        rollbackName: rollbackName,
        hadLiveRoot: true,
        phase: "rollingBack"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let integrity = SHA256.hash(data: try encoder.encode(payload))
        .map { String(format: "%02x", $0) }
        .joined()
    let journal = TestBackupReplacementJournal(
        version: payload.version,
        transactionID: payload.transactionID,
        rollbackName: payload.rollbackName,
        hadLiveRoot: payload.hadLiveRoot,
        phase: payload.phase,
        integrity: integrity
    )
    let journalURL = workRoot.appendingPathComponent(".ReplacementJournal.json")
    try encoder.encode(journal).write(to: journalURL, options: .atomic)
    return journalURL
}

private func syncPublicationMarkup(color: MarkupColor) -> PatternMarkupDocument {
    PatternMarkupDocument(strokes: [.init(
        points: [.init(x: 0.25, y: 0.75)],
        color: color,
        width: 0.008
    )])
}

private func makeSyncPublicationJPEG(red: CGFloat) throws -> Data {
    let context = try #require(CGContext(
        data: nil,
        width: 16,
        height: 16,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: red, green: 0.4, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}
