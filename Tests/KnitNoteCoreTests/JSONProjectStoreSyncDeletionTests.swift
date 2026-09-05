import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

@Suite(.serialized) @MainActor struct JSONProjectStoreSyncDeletionTests {
    @Test func projectDeletionRetainsSelectedContentAndPreservesSharedYarn() throws {
        let fixture = try DeletionStoreFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        try fixture.hydrate(store)
        try store.delete(id: fixture.projectID)
        let entries = try fixture.ledger().recentlyDeleted()
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.domain.rootIDs.contains(.init(kind: .project, uuid: fixture.projectID)))
        #expect(!entry.domain.ownedRecords.contains { $0.id.kind == .yarn })
        #expect(store.yarn(id: fixture.yarnID)?.name == "Shared yarn")
        #expect(store.project(id: fixture.projectID) == nil)
        #expect(try fixture.ledger().recentlyDeleted().count == 1)
    }

    @Test func missingHydrationRefusesDeletionWithoutChangingArchive() throws {
        let fixture = try DeletionStoreFixture()
        defer { fixture.cleanUp() }
        let before = try Data(contentsOf: fixture.url)
        let store = fixture.store()
        #expect(throws: (any Error).self) { try store.delete(id: fixture.projectID) }
        #expect(try Data(contentsOf: fixture.url) == before)
        #expect(store.project(id: fixture.projectID) != nil)
    }

    @Test func disabledSyncStillDeletesWithoutRetention() throws {
        let fixture = try DeletionStoreFixture()
        defer { fixture.cleanUp() }
        let store = JSONProjectStore(url: fixture.url)
        try store.delete(id: fixture.projectID)
        #expect(store.project(id: fixture.projectID) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.ledgerRoot.path))
    }

    @Test func archiveFailureDoesNotActivatePreparedDeletion() throws {
        let fixture = try DeletionStoreFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store(writer: { _, _ in throw DeletionInjectedFailure() })
        try fixture.hydrate(store)
        #expect(throws: (any Error).self) { try store.delete(id: fixture.projectID) }
        #expect(store.project(id: fixture.projectID) != nil)
        #expect(try fixture.ledger().recentlyDeleted().isEmpty)
        let reopened = fixture.store()
        #expect(reopened.project(id: fixture.projectID) != nil)
        #expect(try fixture.ledger().recentlyDeleted().isEmpty)
    }

    @Test(arguments: [false, true]) func unrelatedFailedWriteDoesNotBorrowActiveDeletionWitness(deletingYarn: Bool) throws {
        let fixture = try DeletionStoreFixture()
        defer { fixture.cleanUp() }
        let first = fixture.store()
        try fixture.hydrate(first)
        try first.setProjectYarns(projectID: fixture.projectID, yarnIDs: [])
        let retained = try #require(try fixture.ledger().recentlyDeleted().first)
        let activeID = retained.id
        let before = try Data(contentsOf: fixture.url)
        let failing = fixture.store(writer: { _, url in
            let marker = try #require(try SyncPublicationTransactionFile(archiveURL: url).load())
            #expect(marker.deletionLedgerID != activeID)
            #expect((marker.deletionLedgerID != nil) == deletingYarn)
            throw DeletionInjectedFailure()
        })
        try fixture.hydrate(failing)
        #expect(throws: (any Error).self) {
            if deletingYarn { try failing.deleteYarn(id: fixture.yarnID) }
            else { try failing.rename(id: fixture.projectID, to: "Must not commit") }
        }
        #expect(try Data(contentsOf: fixture.url) == before)
        let reopened = fixture.store()
        #expect(reopened.syncPublicationError == nil)
        try reopened.repairSyncPublication()
        #expect(try SyncPublicationTransactionFile(archiveURL: fixture.url).load() == nil)
        #expect(try fixture.ledger().recentlyDeleted().map(\.id) == [activeID])
        #expect(reopened.yarn(id: fixture.yarnID) != nil)
        try reopened.rename(id: fixture.projectID, to: "Subsequent write succeeds")
        #expect(reopened.project(id: fixture.projectID)?.name == "Subsequent write succeeds")
        #expect(try fixture.ledger().recentlyDeleted().map(\.id) == [activeID])
    }

    @Test(arguments: [false, true]) func canceledDeletionWitnessSurvivesInterruptionBeforeMarkerReclamation(artifact: Bool) throws {
        let fixture = try DeletionStoreFixture()
        defer { fixture.cleanUp() }
        _ = try BackupFixture.writePatternLibraryArchive(to: fixture.root, includeLinkedYarn: true)
        let first = fixture.store()
        try fixture.hydrate(first)
        let projectID = try #require(first.projects.first?.id)
        let yarnID = try #require(first.yarns.first?.id)
        let usageID = try #require(first.patternUsages.first?.id)
        _ = try first.linkPattern(patternID: #require(first.patterns.first?.id), to: projectID)
        try first.setProjectYarns(projectID: projectID, yarnIDs: [])
        let activeID = try #require(try fixture.ledger().recentlyDeleted().first?.id)
        let before = try Data(contentsOf: fixture.url)
        let failing = fixture.store(writer: { _, url in
            let marker = SyncPublicationTransactionFile(archiveURL: url)
            try Data(contentsOf: marker.url).write(to: url.appendingPathExtension("interrupted-marker"))
            throw DeletionInjectedFailure()
        })
        try fixture.hydrate(failing)
        #expect(throws: (any Error).self) {
            if artifact {
                try failing.savePatternMarkup(PatternMarkupDocument(), usageID: usageID, pageIndex: 2,
                    expectedDataGeneration: failing.dataGeneration)
            } else { try failing.deleteYarn(id: yarnID) }
        }
        let canceled = try JSONDecoder().decode(SyncPublicationTransaction.self,
            from: Data(contentsOf: fixture.url.appendingPathExtension("interrupted-marker")))
        #expect(canceled.deletionLedgerID != nil && canceled.deletionLedgerID != activeID)
        #expect(canceled.commitBoundary == (artifact ? .artifacts : .archive))
        #expect(try Data(contentsOf: fixture.url) == before)
        // Recreate exactly the crash point after durable ledger cancellation
        // but before the original publication marker was reclaimed.
        try SyncPublicationTransactionFile(archiveURL: fixture.url).write(canceled)
        let reopened = fixture.store()
        #expect(reopened.syncPublicationError == nil)
        try reopened.repairSyncPublication()
        #expect(try SyncPublicationTransactionFile(archiveURL: fixture.url).load() == nil)
        #expect(try fixture.ledger().recentlyDeleted().map(\.id) == [activeID])
        #expect(reopened.yarn(id: yarnID) != nil)
        #expect(!(try reopened.loadPatternMarkup(usageID: usageID, pageIndex: 2)).strokes.isEmpty)
        try reopened.rename(id: projectID, to: "Cancellation replay completed")
        #expect(reopened.project(id: projectID)?.name == "Cancellation replay completed")
        let unknown = try SyncPublicationTransaction(expectedArchiveSHA256: canceled.expectedArchiveSHA256,
            mutations: canceled.mutations, commitBoundary: canceled.commitBoundary,
            artifactEvidence: canceled.artifactEvidence, revisionReceipts: canceled.revisionReceipts,
            candidateAttachmentManifest: canceled.candidateAttachmentManifest, deletionLedgerID: UUID())
        #expect(throws: (any Error).self) {
            try fixture.ledger().recover(archiveSHA256: Data(SHA256.hash(data: before)), publication: unknown,
                publicationStatus: .uncommitted)
        }
    }

    @Test func postRenameFailureAndJournalFailureRetainUntilRepair() throws {
        for renameFailure in [false, true] {
            let fixture = try DeletionStoreFixture()
            defer { fixture.cleanUp() }
            let store = fixture.store(sink: DeletionSink(fails: !renameFailure), writer: { bytes, url in
                try bytes.write(to: url, options: .atomic)
                if renameFailure { throw DeletionInjectedFailure() }
            })
            try fixture.hydrate(store)
            try store.delete(id: fixture.projectID)
            #expect(store.project(id: fixture.projectID) == nil)
            #expect(store.syncPublicationError == .pendingRepair)
            #expect(try fixture.ledger().recentlyDeleted().isEmpty)
            let reopened = fixture.store()
            try reopened.repairSyncPublication()
            #expect(try fixture.ledger().recentlyDeleted().count == 1)
            #expect(try SyncPublicationTransactionFile(archiveURL: fixture.url).load() == nil)
        }
    }

    @Test func completeProjectMediaSurvivesOriginalCollectionAndReplacement() throws {
        let fixture = try DeletionStoreFixture()
        defer { fixture.cleanUp() }
        try fixture.installCompleteArchive()
        let store = fixture.store()
        try fixture.hydrate(store)
        let project = try #require(store.projects.first)
        let yarn = try #require(store.yarns.first)
        try store.delete(id: project.id)
        let entry = try #require(try fixture.ledger().recentlyDeleted().first)
        #expect(entry.files.count == 5)
        #expect(store.yarn(id: yarn.id) != nil)
        for proof in entry.files {
            let retained = fixture.ledgerRoot.appendingPathComponent(proof.retainedRelativePath)
            let original = fixture.root.appendingPathComponent(proof.restoreRelativePath)
            try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("replacement must not affect retained bytes".utf8).write(to: original)
            #expect(Data(SHA256.hash(data: try Data(contentsOf: retained))) == proof.sha256)
        }
        #expect(try fixture.ledger().recentlyDeleted().first?.files.count == 5)
    }

    @Test func selectedJournalLegacyPatternAndYarnRemovalsRetainOnlyTheirDomain() throws {
        for kind in ["journal", "legacy", "yarn"] {
            let fixture = try DeletionStoreFixture()
            defer { fixture.cleanUp() }
            try fixture.installCompleteArchive()
            let store = fixture.store()
            try fixture.hydrate(store)
            let project = try #require(store.projects.first)
            switch kind {
            case "journal": try store.deleteJournalEntry(projectID: project.id, entryID: project.journalEntries[0].id)
            case "legacy": try store.deletePattern(projectID: project.id, id: project.patterns[0].id)
            default: try store.deleteYarn(id: store.yarns[0].id)
            }
            let entry = try #require(try fixture.ledger().recentlyDeleted().first)
            #expect(entry.files.count == (kind == "yarn" ? 1 : 2))
            #expect(!entry.domain.ownedRecords.contains { $0.id.kind == .project })
            #expect(store.project(id: project.id) != nil)
            if kind == "legacy" {
                #expect(entry.domain.removedLegacyPatterns[project.id]?.first?.id == project.patterns[0].id)
            }
        }
    }

    @Test func directReminderRetainsOnlyRemovedValueAndLinkRetainsNoYarn() throws {
        let fixture = try DeletionStoreFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        try fixture.hydrate(store)
        let reminderID = try store.addKnittingReminder(projectID: fixture.projectID,
            draft: .oneTime(kind: .cable, target: 3, text: "Selected reminder"), now: .now)
        let revision = try #require(store.projects.first?.knittingReminders.first?.mutationRevision)
        try store.deleteKnittingReminder(projectID: fixture.projectID, reminderID: reminderID, observedRevision: revision)
        let reminder = try #require(try fixture.ledger().recentlyDeleted().first)
        #expect(reminder.domain.ownedRecords.isEmpty)
        #expect(reminder.domain.removedReminders.values.flatMap { $0 }.map(\.id) == [reminderID])
        try store.setProjectYarns(projectID: fixture.projectID, yarnIDs: [])
        let link = try #require(try fixture.ledger().recentlyDeleted().last)
        #expect(link.domain.ownedRecords.map(\.id.kind) == [.projectYarnLink])
        #expect(store.yarn(id: fixture.yarnID) != nil)
    }

    @Test func patternDeletionStagesCopiesBeforeMovingUsageMarkupAndAsset() throws {
        let fixture = try DeletionStoreFixture()
        defer { fixture.cleanUp() }
        _ = try BackupFixture.writePatternLibraryArchive(to: fixture.root)
        let store = fixture.store()
        try fixture.hydrate(store)
        let pattern = try #require(store.patterns.first)
        let project = try #require(store.projects.first)
        try store.unlinkPattern(patternID: pattern.id, from: project.id)
        try store.deletePatternPermanently(id: pattern.id)
        let entry = try #require(try fixture.ledger().recentlyDeleted().last)
        #expect(entry.files.count == 2)
        #expect(entry.domain.ownedRecords.contains { $0.id == .init(kind: .pattern, uuid: pattern.id) })
        #expect(store.project(id: project.id) != nil)
    }

    @Test func staleDiskAndRestartWithoutCheckpointRefuseDeletion() throws {
        let fixture = try DeletionStoreFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        try fixture.hydrate(store)
        let other = JSONProjectStore(url: fixture.url)
        try other.rename(id: fixture.projectID, to: "External change")
        let changed = try Data(contentsOf: fixture.url)
        #expect(throws: (any Error).self) { try store.delete(id: fixture.projectID) }
        #expect(try Data(contentsOf: fixture.url) == changed)
        let restarted = fixture.store()
        #expect(throws: (any Error).self) { try restarted.delete(id: fixture.projectID) }
    }

    @Test func savedTombstonesPreserveUUIDContentAndOwnedCascadeAcrossRemoteMerge() throws {
        let fixture = try DeletionStoreFixture()
        defer { fixture.cleanUp() }
        let journal = FileSyncMutationJournal(url: fixture.root.appendingPathComponent("journal.json"))
        let store = fixture.store(sink: JournalSyncMutationSink(journal: journal))
        let initial = try fixture.hydrate(store)
        let before = try #require(initial.records.first { $0.id.kind == .project })
        try store.delete(id: fixture.projectID)
        let mutations = try journal.pending()
        #expect(mutations.allSatisfy { $0.savedRecordVersion?.record.deletedAt.value != nil })
        let root = try #require(mutations.compactMap(\.savedRecordVersion?.record).first { $0.id == before.id })
        #expect(root.payload.fields.mapValues(\.value) == before.payload.fields.mapValues(\.value))
        #expect(root.payload.deletionCascade?.value.contains(where: { $0.kind == .projectCounter }) == true)
        #expect(root.payload.deletionCascade?.value.contains(where: { $0.kind == .yarn }) != true)
        let merged = try SyncMergeEngine().merge(local: initial.records,
            remote: mutations.compactMap(\.savedRecordVersion?.record), pendingLocal: [])
        #expect(merged.records.first { $0.id == before.id }?.deletedAt.value != nil)
        #expect(merged.records.first { $0.id.kind == .yarn }?.deletedAt.value == nil)
    }

    @Test func activationPrecedesMarkerReclamationAndExactMarkerReplayIsIdempotent() throws {
        let fixture = try DeletionStoreFixture()
        defer { fixture.cleanUp() }
        let sink = DeletionWitnessSink(archiveURL: fixture.url, ledgerRoot: fixture.ledgerRoot)
        let store = fixture.store(sink: sink)
        try fixture.hydrate(store)
        try store.delete(id: fixture.projectID)
        #expect(sink.visibleDuringPublication == 0)
        let transaction = try #require(sink.transaction)
        #expect(transaction.deletionLedgerID != nil)
        #expect(try fixture.ledger().recentlyDeleted().count == 1)
        let falseClaim = try SyncPublicationTransaction(expectedArchiveSHA256: transaction.expectedArchiveSHA256,
            mutations: transaction.mutations,
            artifactEvidence: [.init(relativePath: "unrelated", expectedSHA256: nil)],
            revisionReceipts: transaction.revisionReceipts, deletionLedgerID: transaction.deletionLedgerID)
        #expect(throws: (any Error).self) {
            try fixture.ledger().recover(archiveSHA256: transaction.expectedArchiveSHA256, publication: falseClaim)
        }
        // Recreate the exact disk state of a crash after ledger activation but
        // before marker reclamation. Startup must replay and keep one group.
        try SyncPublicationTransactionFile(archiveURL: fixture.url).write(transaction)
        let restarted = fixture.store()
        try restarted.repairSyncPublication()
        #expect(try fixture.ledger().recentlyDeleted().count == 1)
        #expect(try SyncPublicationTransactionFile(archiveURL: fixture.url).load() == nil)
    }

    @Test func emptyLegacyMarkupRetainsBytesAcrossSameArchiveCommitAndJournalRepair() throws {
        let fixture = try DeletionStoreFixture()
        defer { fixture.cleanUp() }
        try fixture.installCompleteArchive()
        let store = fixture.store(sink: DeletionSink(fails: true))
        try fixture.hydrate(store)
        let project = try #require(store.projects.first)
        let pattern = try #require(project.patterns.first)
        let before = try Data(contentsOf: fixture.url)
        try store.savePatternMarkup(PatternMarkupDocument(), projectID: project.id, patternID: pattern.id,
            pageIndex: 0, expectedDataGeneration: store.dataGeneration)
        #expect(try Data(contentsOf: fixture.url) == before)
        #expect(store.syncPublicationError == .pendingRepair)
        let reopened = fixture.store()
        try reopened.repairSyncPublication()
        let entry = try #require(try fixture.ledger().recentlyDeleted().first)
        #expect(entry.files.count == 1)
        #expect(entry.domain.ownedRecords.allSatisfy { $0.id.kind == .attachment })
        #expect(entry.domain.removedLegacyPatterns.isEmpty)
    }

    @Test func emptyUsageMarkupArchiveFailureKeepsOriginalAndDoesNotActivate() throws {
        let fixture = try DeletionStoreFixture()
        defer { fixture.cleanUp() }
        _ = try BackupFixture.writePatternLibraryArchive(to: fixture.root)
        let setup = JSONProjectStore(url: fixture.url)
        _ = try setup.linkPattern(patternID: #require(setup.patterns.first?.id), to: #require(setup.projects.first?.id))
        let store = fixture.store(writer: { _, _ in throw DeletionInjectedFailure() })
        try fixture.hydrate(store)
        let usage = try #require(store.patternUsages.first)
        let original = try store.loadPatternMarkup(usageID: usage.id, pageIndex: 2)
        #expect(throws: (any Error).self) {
            try store.savePatternMarkup(PatternMarkupDocument(), usageID: usage.id, pageIndex: 2,
                expectedDataGeneration: store.dataGeneration)
        }
        #expect(try store.loadPatternMarkup(usageID: usage.id, pageIndex: 2) == original)
        let restarted = fixture.store()
        #expect(restarted.syncPublicationError == nil)
        #expect(try fixture.ledger().recentlyDeleted().isEmpty)
    }

    @Test func unresolvedHeadRequiresExplicitFrozenSourceBeforeAnyProjectRemoval() throws {
        for provideSource in [false, true] {
            let fixture = try DeletionStoreFixture()
            defer { fixture.cleanUp() }
            try fixture.installCompleteArchive()
            let store = fixture.store()
            let package = try fixture.hydrate(store)
            let project = try #require(store.projects.first)
            let original = try #require(package.records.first { $0.payload.attachment?.slot.role == "project-photo" })
            let originalVersion = try #require(original.payload.attachment)
            let bytes = Data("nonwinning conflict bytes".utf8)
            let sourceURL = fixture.root.appendingPathComponent("frozen-conflict")
            try bytes.write(to: sourceURL)
            let version = try SyncAttachmentVersion(slot: originalVersion.slot, versionID: UUID(),
                conflictGroupID: originalVersion.conflictGroupID, contentSHA256: Data(SHA256.hash(data: bytes)),
                byteCount: Int64(bytes.count), mediaType: "image/jpeg", displayFilename: "conflict.jpg", replacesVersionID: nil)
            let sibling = SyncRecord(schemaVersion: 1, id: .init(kind: .attachment, uuid: version.versionID),
                createdAt: Date(timeIntervalSinceReferenceDate: -1), entityRevision: 0,
                payload: .init(fields: [:], attachment: version), relationships: original.relationships,
                deletedAt: .init(value: nil, stamp: .init(logicalRevision: 0,
                    modifiedAt: Date(timeIntervalSinceReferenceDate: -1), deviceID: "other")))
            let records = package.records + [sibling]
            let attachments = records.filter { $0.id.kind == .attachment }
            try SyncAttachmentPublicationEvidenceFile(url: fixture.root.appendingPathComponent("SyncMetadata/attachment-versions.json")).save(
                .init(versions: attachments.compactMap { $0.payload.attachment }, attachmentRecords: attachments))
            let before = try Data(contentsOf: fixture.url)
            let states = Dictionary(uniqueKeysWithValues: records.compactMap { record -> (UUID, SyncCounterReminderState)? in
                guard case let .projectCounter(state)? = record.payload.atomicDomain?.value else { return nil }
                return (record.id.uuid, state)
            })
            let source = try SyncAttachmentSource(fileURL: sourceURL, contentSHA256: version.contentSHA256, byteCount: version.byteCount)
            try store.hydrateSyncBootstrap(.init(archiveSHA256: Data(SHA256.hash(data: before)), records: records,
                counterStates: states, legacyRecordIDsToDelete: []),
                attachmentSources: provideSource ? [version.versionID: source] : [:])
            if provideSource {
                try store.delete(id: project.id)
                let entry = try #require(try fixture.ledger().recentlyDeleted().first)
                #expect(entry.files.count == 6)
                let proof = try #require(entry.files.first { $0.attachmentVersionID == version.versionID })
                try Data("changed frozen source".utf8).write(to: sourceURL)
                #expect(try Data(contentsOf: fixture.ledgerRoot.appendingPathComponent(proof.retainedRelativePath)) == bytes)
                let evidence = try SyncAttachmentPublicationEvidenceFile(url: fixture.root.appendingPathComponent("SyncMetadata/attachment-versions.json")).load()
                let history = evidence.retainedAttachmentRecords
                #expect(history.contains { $0.id == sibling.id && $0.deletedAt.value != nil })
                #expect(history.contains { $0.id == original.id && $0.deletedAt.value != nil })
                let reversed = try SyncAttachmentPublicationEvidence(
                    versions: history.reversed().compactMap { $0.payload.attachment },
                    deletedVersionIDs: Set(history.filter { $0.deletedAt.value != nil }.map(\.id.uuid)),
                    attachmentRecords: history.reversed()).validated()
                #expect(evidence.version(for: version.slot) == reversed.version(for: version.slot))
                #expect(try fixture.ledger().recentlyDeleted().first?.files.count == 6)
            } else {
                #expect(throws: (any Error).self) { try store.delete(id: project.id) }
                #expect(try Data(contentsOf: fixture.url) == before)
                #expect(store.project(id: project.id) != nil)
                #expect(try fixture.ledger().recentlyDeleted().isEmpty)
            }
        }
    }

    @Test func projectDeletionPreservesSharedPatternAssetAndOtherUsage() throws {
        let fixture = try DeletionStoreFixture()
        defer { fixture.cleanUp() }
        _ = try BackupFixture.writePatternLibraryArchive(to: fixture.root, includeLinkedYarn: true)
        let setup = JSONProjectStore(url: fixture.url)
        let selected = try #require(setup.projects.first)
        let sharedPattern = try #require(setup.patterns.first)
        try setup.add(name: "Other project")
        let other = try #require(setup.projects.first { $0.name == "Other project" })
        _ = try setup.linkPattern(patternID: sharedPattern.id, to: other.id)
        let assetURL = try setup.patternAssetURL(patternID: sharedPattern.id)
        let bytes = try Data(contentsOf: assetURL)
        let store = fixture.store()
        try fixture.hydrate(store)
        try store.delete(id: selected.id)
        #expect(store.project(id: other.id) != nil)
        #expect(store.patterns.contains { $0.id == sharedPattern.id })
        #expect(store.patternUsages.contains { $0.projectID == other.id && $0.patternID == sharedPattern.id })
        #expect(try Data(contentsOf: assetURL) == bytes)
        let entry = try #require(try fixture.ledger().recentlyDeleted().first)
        #expect(!entry.domain.ownedRecords.contains { $0.id == .init(kind: .pattern, uuid: sharedPattern.id) })
        #expect(entry.domain.supportingParentIDs.contains(.init(kind: .pattern, uuid: sharedPattern.id)))
    }

    @Test func missingWitnessAfterJournalFailureBlocksReopenAndKeepsRetainedMedia() throws {
        let fixture = try DeletionStoreFixture()
        defer { fixture.cleanUp() }
        try fixture.installCompleteArchive()
        let store = fixture.store(sink: DeletionSink(fails: true))
        try fixture.hydrate(store)
        try store.delete(id: #require(store.projects.first?.id))
        #expect(store.syncPublicationError == .pendingRepair)
        try SyncPublicationTransactionFile(archiveURL: fixture.url).remove()
        let reopened = fixture.store()
        #expect(reopened.syncPublicationError == .pendingRepair)
        #expect(throws: (any Error).self) { try reopened.repairSyncPublication() }
        #expect(try fixture.ledger().recentlyDeleted().isEmpty)
        let directories = try FileManager.default.contentsOfDirectory(at: fixture.ledgerRoot, includingPropertiesForKeys: nil)
        let retained = directories.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { $0.pathExtension == "retained" }
        #expect(retained.count == 5)
        #expect(try retained.allSatisfy { !(try Data(contentsOf: $0)).isEmpty })
    }
}

private struct DeletionInjectedFailure: Error {}
private struct DeletionSink: SyncMutationSink {
    var fails = false
    func publish(_ mutation: SyncMutation) throws {
        if fails { throw DeletionInjectedFailure() }
    }
}

private final class DeletionWitnessSink: SyncMutationSink, @unchecked Sendable {
    let archiveURL: URL
    let ledgerRoot: URL
    private let lock = NSLock()
    private var captured: SyncPublicationTransaction?
    private var visible: Int?
    init(archiveURL: URL, ledgerRoot: URL) { self.archiveURL = archiveURL; self.ledgerRoot = ledgerRoot }
    func publish(_ mutation: SyncMutation) throws {
        let transaction = try SyncPublicationTransactionFile(archiveURL: archiveURL).load()
        let count = try SyncDeletionLedger(root: ledgerRoot).recentlyDeleted().count
        lock.withLock { captured = transaction; visible = count }
    }
    var transaction: SyncPublicationTransaction? { lock.withLock { captured } }
    var visibleDuringPublication: Int? { lock.withLock { visible } }
}

@MainActor private struct DeletionStoreFixture {
    let root: URL
    let url: URL
    let projectID = UUID()
    let yarnID = UUID()
    var ledgerRoot: URL { root.appendingPathComponent(".sync-deletions") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("deletion-store-\(UUID())")
        url = root.appendingPathComponent("projects-v1.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = try StoredProject(id: projectID, name: "Selected project")
        var yarn = try StoredYarn(id: yarnID, name: "Shared yarn")
        yarn.setLinkedProjectIDs([projectID])
        try JSONEncoder().encode(ProjectArchive(version: ProjectArchive.currentVersion,
            projects: [project], yarns: [yarn])).write(to: url)
    }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
    func installCompleteArchive() throws {
        _ = try BackupFixture.writeCompleteArchive(to: root)
        let old = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: url))
        // Keep the existing legacy embedded shape; version 9 would migrate it
        // into a shared library pattern before the deletion under test.
        try JSONEncoder().encode(ProjectArchive(version: ProjectArchive.currentVersion,
            projects: old.projects, yarns: old.yarns)).write(to: url)
    }
    func ledger() throws -> SyncDeletionLedger { try .init(root: ledgerRoot) }
    func store(sink: any SyncMutationSink = DeletionSink(),
               writer: @escaping @Sendable (Data, URL) throws -> Void = {
                   try $0.write(to: $1, options: .atomic)
               }) -> JSONProjectStore {
        JSONProjectStore(url: url,
            backupService: KnitNoteBackupService(liveRoot: root, workRoot: root.appendingPathComponent("work")),
            archiveWrite: writer, syncMutationSink: sink)
    }
    @discardableResult func hydrate(_ store: JSONProjectStore) throws -> SyncExportPackage {
        let data = try Data(contentsOf: url)
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: data)
        let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: root, deviceID: "known-local")
        let attachments = package.records.filter { $0.id.kind == .attachment }
        try SyncAttachmentPublicationEvidenceFile(url: root.appendingPathComponent("SyncMetadata/attachment-versions.json")).save(
            .init(versions: attachments.compactMap { $0.payload.attachment }, attachmentRecords: attachments))
        let states = Dictionary(uniqueKeysWithValues: package.records.compactMap { record -> (UUID, SyncCounterReminderState)? in
            guard case let .projectCounter(state)? = record.payload.atomicDomain?.value else { return nil }
            return (record.id.uuid, state)
        })
        try store.hydrateSyncBootstrap(.init(archiveSHA256: Data(SHA256.hash(data: data)),
            records: package.records, counterStates: states, legacyRecordIDsToDelete: []))
        return package
    }
}
