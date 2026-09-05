import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

struct SyncBootstrapTransactionTests {
    @Test func consumedRemoteLegacyReminderHasDurableExactDeleteIntent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var archive = fixture.archive
        let counterID = archive.projects[0].mainCounterID
        try archive.projects[0].addKnittingReminder(counterID: counterID,
            draft: .oneTime(kind: .measure, target: 2, text: nil), now: .init(timeIntervalSinceReferenceDate: 100))
        try JSONEncoder().encode(archive).write(to: fixture.live.appendingPathComponent("projects-v1.json"))
        let reminder = archive.projects[0].knittingReminders[0]
        let stamp = SyncMutationStamp(logicalRevision: 0, modifiedAt: reminder.createdAt, deviceID: "legacy")
        let legacy = SyncRecord(schemaVersion: 1, id: .init(kind: .knittingReminder, uuid: reminder.id),
            createdAt: reminder.createdAt, entityRevision: reminder.mutationRevision,
            payload: .init(fields: [:], atomicDomain: .init(value: .knittingReminder(reminder), stamp: stamp)),
            relationships: [.init(role: "counter", target: .init(kind: .projectCounter, uuid: reminder.counterID))],
            deletedAt: .init(value: nil, stamp: stamp))
        let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: fixture.live, deviceID: "local")
        let transaction = try fixture.transaction()
        let prepared = try transaction.prepare(local: package, sourceArchive: archive,
            remote: .init(context: fixture.context, records: [legacy], attachments: [:], isComplete: true))
        try transaction.install(prepared)
        _ = try transaction.commit(prepared)
        let pending = try FileSyncMutationJournal(url: fixture.live.appendingPathComponent("SyncMetadata/bootstrap-journal")).pending()
        #expect(pending.contains { mutation in
            guard case let .delete(value) = mutation else { return false }; return value.recordID == legacy.id
        })
        #expect(try transaction.checkpoint(prepared).legacyRecordIDsToDelete == [legacy.id])
        #expect(try fixture.readArchive().projects[0].knittingReminders.map(\.id) == [reminder.id])
    }

    @Test func legacyPendingJournalRequiresSemanticRepairWithoutChangingOriginal() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let journal = FileSyncMutationJournal(url: fixture.live.appendingPathComponent("SyncMetadata/bootstrap-journal"))
        let old = SyncMutation.delete(.init(kind: .knittingReminder, uuid: UUID()), mutationID: UUID())
        try journal.enqueue([old])
        let pending = try journal.pending()
        let transaction = try fixture.transaction()
        let fingerprint = try transaction.sourceFingerprint()
        #expect(throws: SyncPublicationError.pendingRepair) {
            try transaction.prepare(local: fixture.export(), sourceArchive: fixture.archive,
                remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true),
                pendingSnapshot: .init(mutations: pending, sourceTreeFingerprint: fingerprint))
        }
        #expect(try transaction.sourceFingerprint() == fingerprint)
        #expect(try journal.pending() == pending)
        #expect(!FileManager.default.fileExists(atPath: fixture.live.appendingPathComponent("SyncMetadata/bootstrap-receipt.json").path))
    }
    @Test @MainActor func reopenedStoreAcknowledgesRetainedWatchProofWithoutApplyingAgain() throws {
        let fixture = try Fixture(empty: true)
        defer { fixture.remove() }
        let command = WatchCounterCommand(id: UUID(), projectID: UUID(), counterID: UUID(), operation: .increment, createdAt: .init(timeIntervalSince1970: 40))
        let proof = try SyncProcessedWatchCommandProof(id: command.id, rejection: .projectMissing,
            commandIdentity: .init(command), preparedCommand: nil, effectProof: nil,
            processingStamp: .init(logicalRevision: 0, modifiedAt: .init(timeIntervalSince1970: 41), deviceID: "local"))
        let package = try ProjectArchiveSyncMapper.export(archive: fixture.archive, liveRoot: fixture.live, deviceID: "local", processedWatchProofs: [proof])
        let transaction = try fixture.transaction()
        let prepared = try transaction.prepare(local: package, sourceArchive: fixture.archive,
            remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true))
        try transaction.install(prepared)
        _ = try transaction.commit(prepared)
        let evidence = try SyncAttachmentPublicationEvidenceFile(url: fixture.live.appendingPathComponent("SyncMetadata/attachment-versions.json")).load()
        #expect(evidence.watchCommandProofs == [proof])
        let store = JSONProjectStore(url: fixture.live.appendingPathComponent("projects-v1.json"),
            syncMutationSink: JournalSyncMutationSink(journal: FileSyncMutationJournal(url: fixture.live.appendingPathComponent("SyncMetadata/bootstrap-journal"))))
        try store.hydrateSyncBootstrap(transaction.checkpoint(prepared))
        let acknowledgement = try store.persistedWatchCommandAcknowledgement(for: command, entitlement: .permanentlyUnlocked,
            ledgerURL: fixture.live.appendingPathComponent("Watch/processed.json"), now: .init(timeIntervalSince1970: 50))
        #expect(acknowledgement?.rejection == .projectMissing)
        #expect(store.projects.isEmpty)
    }
    @Test func existingPendingJournalRequiresBoundSnapshotAndPreservesExactSources() throws {
        let fixture = try Fixture(completeMedia: true)
        defer { fixture.remove() }
        let package = try fixture.export()
        let attachment = try #require(package.records.first { $0.id.kind == .attachment })
        let oldMutation = try SyncMutation.save(recordVersion: SyncRecordVersion(record: attachment),
            attachmentSource: package.attachments[attachment.id.uuid], mutationID: UUID())
        let journalURL = fixture.live.appendingPathComponent("SyncMetadata/bootstrap-journal")
        let journal = FileSyncMutationJournal(url: journalURL)
        try journal.enqueue([oldMutation])
        let originalPending = try journal.pending()
        let transaction = try fixture.transaction()
        let remote = SyncBootstrapRemoteSnapshot(context: fixture.context, records: [], attachments: [:], isComplete: true)
        #expect(throws: (any Error).self) { try transaction.prepare(local: package, sourceArchive: fixture.archive, remote: remote) }
        let snapshot = SyncBootstrapPendingSnapshot(mutations: originalPending, sourceTreeFingerprint: try transaction.sourceFingerprint())
        let prepared = try transaction.prepare(local: package, sourceArchive: fixture.archive, remote: remote, pendingSnapshot: snapshot)
        try transaction.install(prepared)
        _ = try transaction.commit(prepared)
        let reopened = try FileSyncMutationJournal(url: journalURL).pending()
        #expect(reopened.contains(originalPending[0]))
        #expect(reopened.count > originalPending.count)
        let source = try #require(originalPending[0].attachmentSource)
        #expect(Data(SHA256.hash(data: try Data(contentsOf: source.fileURL))) == source.contentSHA256)
    }

    @Test func accountMismatchAndRevokedFreezeCannotReplaceLiveData() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transaction = try fixture.transaction()
        let otherContext = SyncBootstrapContext(accountIDHash: String(repeating: "b", count: 64), epoch: UUID(), freezeID: UUID())
        #expect(throws: (any Error).self) {
            try transaction.prepare(local: fixture.export(), sourceArchive: fixture.archive,
                remote: .init(context: otherContext, records: [], attachments: [:], isComplete: true))
        }
        var frozen = true
        let guarded = try SyncBootstrapTransaction(liveRoot: fixture.live, context: fixture.context,
            journalRelativePath: "SyncMetadata/bootstrap-journal", validateContext: { _ in
                guard frozen else { throw SyncBootstrapError.contextChanged }
            })
        let prepared = try guarded.prepare(local: fixture.export(), sourceArchive: fixture.archive,
            remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true))
        frozen = false
        #expect(throws: (any Error).self) { try guarded.install(prepared) }
        #expect(throws: (any Error).self) { try guarded.recoverInterruptedInstallation() }
        #expect(try fixture.readArchive().projects == fixture.archive.projects)
    }

    @Test func corruptManifestAndSymlinkSourcesFailClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let alias = fixture.root.appendingPathComponent("parentAlias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
        #expect(throws: (any Error).self) {
            try SyncBootstrapTransaction(liveRoot: alias.appendingPathComponent("Live"), context: fixture.context,
                journalRelativePath: "SyncMetadata/bootstrap-journal", validateContext: { _ in })
        }
        let transaction = try fixture.transaction()
        let prepared = try transaction.prepare(local: fixture.export(), sourceArchive: fixture.archive,
            remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true))
        let manifest = prepared.accountOwnedRoots[0].appendingPathComponent("active.json")
        try Data("corrupt".utf8).write(to: manifest)
        #expect(throws: (any Error).self) { try transaction.recoverInterruptedInstallation() }
        #expect(try fixture.readArchive().projects == fixture.archive.projects)
        let unsafe = try Fixture()
        defer { unsafe.remove() }
        try FileManager.default.createSymbolicLink(at: unsafe.live.appendingPathComponent("outside"), withDestinationURL: fixture.live)
        #expect(throws: (any Error).self) {
            try unsafe.transaction().prepare(local: unsafe.export(), sourceArchive: unsafe.archive,
                remote: .init(context: unsafe.context, records: [], attachments: [:], isComplete: true))
        }
    }
    @Test(arguments: SyncBootstrapBoundary.allCases) func interruptionsRecoverOriginal(_ point: SyncBootstrapBoundary) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var fired = false
        let transaction = try fixture.transaction(boundary: { current in
            if current == point && !fired { fired = true; throw SyncBootstrapError.corrupt }
            if fired && current == .afterRollbackIntent { throw SyncBootstrapError.corrupt }
        })
        do {
            let prepared = try transaction.prepare(local: fixture.export(), sourceArchive: fixture.archive,
                remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true))
            try transaction.install(prepared)
            if [.afterRollbackIntent, .afterFailedMove, .afterOriginalRestore].contains(point) {
                try transaction.rollback(prepared)
            } else { _ = try transaction.commit(prepared) }
        } catch {}
        #expect(fired)
        let reopened = try fixture.transaction()
        #expect(try reopened.recoverInterruptedInstallation() == nil)
        #expect(try fixture.readArchive().projects == fixture.archive.projects)
        #expect(try Data(contentsOf: fixture.live.appendingPathComponent("private-unsent.bin")) == Data([1, 2, 3]))
    }

    @Test func completeMediaSurvivesSwapAndOriginalStagingRemainsAfterAcknowledgement() throws {
        let fixture = try Fixture(completeMedia: true)
        defer { fixture.remove() }
        let transaction = try fixture.transaction()
        let package = try fixture.export()
        let prepared = try transaction.prepare(local: package, sourceArchive: fixture.archive,
            remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true))
        try transaction.install(prepared)
        _ = try transaction.commit(prepared)
        let journal = FileSyncMutationJournal(url: fixture.live.appendingPathComponent("SyncMetadata/bootstrap-journal"))
        let pending = try journal.pending()
        let sources = pending.compactMap { mutation -> SyncAttachmentSource? in
            guard case let .save(save) = mutation else { return nil }; return save.attachmentSource
        }
        #expect(sources.count == 6)
        for source in sources {
            #expect(Data(SHA256.hash(data: try Data(contentsOf: source.fileURL))) == source.contentSHA256)
        }
        #expect(try transaction.checkpoint(prepared).records.filter { $0.id.kind == .attachment }.count == 6)
        try journal.acknowledge(Set(pending.map(\.identity)))
        for id in package.attachments.keys {
            #expect(FileManager.default.fileExists(atPath: prepared.originalBackupRoot.deletingLastPathComponent().appendingPathComponent("Attachments/\(id.uuidString)").path))
        }
    }

    @Test func emptyLocalAndThreeDeviceUnionPublishOnlyNeededRecords() throws {
        let fixture = try Fixture(empty: true)
        defer { fixture.remove() }
        let first = try StoredProject(name: "One")
        let second = try StoredProject(name: "Two")
        let third = try StoredProject(name: "Three")
        let cloud = try [first, second, third].enumerated().flatMap { index, project in
            try SyncCanonicalPublicationSnapshot(archive: .init(version: 14, projects: [project]), deviceID: "device-\(index)").records.values
        }
        let transaction = try fixture.transaction()
        let prepared = try transaction.prepare(local: fixture.export(), sourceArchive: fixture.archive,
            remote: .init(context: fixture.context, records: cloud, attachments: [:], isComplete: true))
        try transaction.install(prepared)
        _ = try transaction.commit(prepared)
        #expect(Set(try fixture.readArchive().projects.map(\.id)) == Set([first.id, second.id, third.id]))
        #expect(try FileSyncMutationJournal(url: fixture.live.appendingPathComponent("SyncMetadata/bootstrap-journal")).pending().isEmpty)
    }

    @Test @MainActor func reopenedStoreConsumesRemoteRevisionThroughHydration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let local = try fixture.export()
        let remote = local.records.map { original -> SyncRecord in
            guard original.id.kind == .project else { return original }
            var record = original
            let stamp = SyncMutationStamp(logicalRevision: 99, modifiedAt: Date(timeIntervalSinceReferenceDate: 999), deviceID: "cloud")
            record.entityRevision = 99
            record.payload.fields = record.payload.fields.mapValues { .init(value: $0.value, stamp: stamp) }
            record.deletedAt = .init(value: nil, stamp: stamp)
            return record
        }
        let transaction = try fixture.transaction()
        let prepared = try transaction.prepare(local: local, sourceArchive: fixture.archive,
            remote: .init(context: fixture.context, records: remote, attachments: [:], isComplete: true))
        try transaction.install(prepared)
        _ = try transaction.commit(prepared)
        let journal = FileSyncMutationJournal(url: fixture.live.appendingPathComponent("SyncMetadata/bootstrap-journal"))
        let store = JSONProjectStore(url: fixture.live.appendingPathComponent("projects-v1.json"), syncMutationSink: JournalSyncMutationSink(journal: journal))
        #expect(throws: (any Error).self) {
            try store.updateProject(id: fixture.archive.projects[0].id, name: "Blocked", toolType: nil, toolSize: nil, toolNotes: nil, photoChange: .unchanged)
        }
        try store.hydrateSyncBootstrap(transaction.checkpoint(prepared))
        try store.updateProject(id: fixture.archive.projects[0].id, name: "Edited", toolType: nil, toolSize: nil, toolNotes: nil, photoChange: .unchanged)
        let changed = try #require(journal.pending().compactMap(\.savedRecordVersion?.record).last { $0.id.kind == .project })
        #expect(changed.entityRevision > 99)
    }

    @Test func mismatchedExportCannotEraseOriginalDomain() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transaction = try fixture.transaction()
        let empty = try ProjectArchiveSyncMapper.export(archive: .init(version: 14, projects: []), liveRoot: fixture.live, deviceID: "local")
        #expect(throws: (any Error).self) {
            try transaction.prepare(local: empty, sourceArchive: fixture.archive,
                remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true))
        }
        #expect(try fixture.readArchive().projects == fixture.archive.projects)
    }

    @Test func localAndCloudUnionRetainsUUIDsAndDurableJournal() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let other = try StoredProject(name: "Same name")
        let remote = try SyncCanonicalPublicationSnapshot(archive: .init(version: 14, projects: [other]), deviceID: "cloud").records.values
        let transaction = try fixture.transaction()
        let prepared = try transaction.prepare(local: fixture.export(), sourceArchive: fixture.archive,
            remote: .init(context: fixture.context, records: Array(remote), attachments: [:], isComplete: true))
        #expect(try fixture.readArchive().projects.map(\.id) == [fixture.archive.projects[0].id])
        try transaction.install(prepared)
        let receipt = try transaction.commit(prepared)
        #expect(Set(try fixture.readArchive().projects.map(\.id)) == Set([fixture.archive.projects[0].id, other.id]))
        #expect(receipt.accountIDHash == fixture.context.accountIDHash)
        #expect(try transaction.commit(prepared) == receipt)
        let journal = FileSyncMutationJournal(url: fixture.live.appendingPathComponent("SyncMetadata/bootstrap-journal"))
        #expect(try journal.pending().contains { $0.recordID.uuid == fixture.archive.projects[0].id })
        #expect(try Data(contentsOf: prepared.originalBackupRoot.appendingPathComponent("private-unsent.bin")) == Data([1, 2, 3]))
    }

    @Test func incompleteFetchAndChangedSourceNeverInstall() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transaction = try fixture.transaction()
        #expect(throws: (any Error).self) {
            try transaction.prepare(local: fixture.export(), sourceArchive: fixture.archive,
                remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: false))
        }
        let prepared = try transaction.prepare(local: fixture.export(), sourceArchive: fixture.archive,
            remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true))
        try Data([4]).write(to: fixture.live.appendingPathComponent("private-unsent.bin"))
        #expect(throws: (any Error).self) { try transaction.install(prepared) }
        #expect(try Data(contentsOf: fixture.live.appendingPathComponent("private-unsent.bin")) == Data([4]))
    }

    @Test func installationRollbackRestoresEveryOriginalByte() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transaction = try fixture.transaction()
        let prepared = try transaction.prepare(local: fixture.export(), sourceArchive: fixture.archive,
            remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true))
        try transaction.install(prepared)
        try transaction.rollback(prepared)
        #expect(try fixture.readArchive().projects == fixture.archive.projects)
        #expect(try Data(contentsOf: fixture.live.appendingPathComponent("private-unsent.bin")) == Data([1, 2, 3]))
        #expect(!FileManager.default.fileExists(atPath: fixture.live.appendingPathComponent("SyncMetadata/bootstrap-receipt.json").path))
    }

    private struct Fixture {
        let root: URL
        let live: URL
        let archive: ProjectArchive
        let context = SyncBootstrapContext(accountIDHash: String(repeating: "a", count: 64), epoch: UUID(), freezeID: UUID())
        init(completeMedia: Bool = false, empty: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
            live = root.appendingPathComponent("Live")
            try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
            if completeMedia {
                _ = try BackupFixture.writeCompleteArchive(to: live)
                archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: live.appendingPathComponent("projects-v1.json")))
            } else {
                archive = .init(version: 14, projects: empty ? [] : [try StoredProject(name: "Same name")])
                try JSONEncoder().encode(archive).write(to: live.appendingPathComponent("projects-v1.json"))
            }
            try Data([1, 2, 3]).write(to: live.appendingPathComponent("private-unsent.bin"))
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func readArchive() throws -> ProjectArchive { try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: live.appendingPathComponent("projects-v1.json"))) }
        func export() throws -> SyncExportPackage { try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: live, deviceID: "local") }
        func transaction(boundary: @escaping (SyncBootstrapBoundary) throws -> Void = { _ in }) throws -> SyncBootstrapTransaction {
            try .init(liveRoot: live, context: context, journalRelativePath: "SyncMetadata/bootstrap-journal", validateContext: { candidate in
                guard candidate == context else { throw SyncBootstrapError.contextChanged }
            }, boundary: boundary)
        }
    }
}
