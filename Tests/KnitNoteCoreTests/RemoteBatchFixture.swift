import Foundation
@testable import KnitNoteCore

@MainActor
struct RemoteBatchFixture {
    private final class InitialHandles {
        var store: JSONProjectStore?
        var journal: FileSyncMutationJournal?

        init(store: JSONProjectStore, journal: FileSyncMutationJournal) {
            self.store = store
            self.journal = journal
        }
    }

    let root: URL
    let account: SyncAccountIdentity
    let records: [SyncRecord]
    let projectID: UUID
    let checkpoints: SyncCanonicalCheckpointStore
    private let initialHandles: InitialHandles

    var store: JSONProjectStore { initialHandles.store! }
    var journal: FileSyncMutationJournal { initialHandles.journal! }

    init(
        boundary: @escaping (SyncCanonicalPublicationBoundary) throws -> Void = { _ in },
        remoteInstallBoundary: @escaping (SyncDurableFileWriteBoundary) throws -> Void = { _ in }
    ) throws {
        root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("remote-batch-test-" + UUID().uuidString)
        let live = root.appendingPathComponent("Live")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)

        let projects = [
            try StoredProject(name: "First"),
            try StoredProject(name: "Second"),
        ]
        projectID = projects[0].id
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: projects)
        let archiveURL = live.appendingPathComponent("projects-v1.json")
        try JSONEncoder().encode(archive).write(to: archiveURL)

        let exported = try ProjectArchiveSyncMapper.export(
            archive: archive,
            liveRoot: live,
            deviceID: "remote-batch-test-device"
        )
        account = try SyncAccountIdentity(
            containerIdentifier: "test.container",
            userRecordName: "remote-batch-test-user"
        )
        let context = SyncBootstrapContext(
            accountIDHash: account.accountIDHash,
            epoch: UUID(),
            freezeID: UUID()
        )
        let bootstrap = try SyncBootstrapTransaction(
            liveRoot: live,
            context: context,
            validateContext: { candidate in
                guard candidate == context else { throw SyncBootstrapError.contextChanged }
            }
        )
        let prepared = try bootstrap.prepare(
            local: exported,
            sourceArchive: archive,
            remote: .init(context: context, records: [], attachments: [:], isComplete: true)
        )
        try bootstrap.install(prepared)
        _ = try bootstrap.commit(prepared)
        let handoff = try bootstrap.canonicalHandoff(prepared)

        let journal = FileSyncMutationJournal(
            url: live.appendingPathComponent("SyncMetadata/pending.json")
        )
        checkpoints = try SyncCanonicalCheckpointStore(
            liveRoot: live,
            account: account,
            validateOwnership: {}
        )
        let store = JSONProjectStore(
            url: archiveURL,
            backupService: KnitNoteBackupService(
                liveRoot: live,
                workRoot: root.appendingPathComponent("BackupWork")
            ),
            syncRemoteInstallBeforeDurabilityBoundary: remoteInstallBoundary,
            syncCanonicalPublicationBoundary: boundary,
            syncMutationSink: JournalSyncMutationSink(journal: journal)
        )
        initialHandles = InitialHandles(store: store, journal: journal)
        try store.activateSyncCanonicalState(
            checkpointStore: checkpoints,
            bootstrap: handoff,
            attachmentSources: [:]
        )
        guard let canonical = try checkpoints.load() else {
            throw SyncRemoteBatchFixtureError.missingCanonicalCheckpoint
        }
        records = canonical.records
    }

    func batch(records: [SyncRecord], id: UUID) throws -> SyncRemoteBatch {
        try SyncRemoteBatch(
            accountIDHash: account.accountIDHash,
            batchID: id,
            records: records,
            deletedRecordIDs: []
        )
    }

    var archiveURL: URL { root.appendingPathComponent("Live/projects-v1.json") }
    var publicationIntentURL: URL { SyncPublicationTransactionFile(archiveURL: archiveURL).url }
    var journalURL: URL { root.appendingPathComponent("Live/SyncMetadata/pending.json") }

    func renamedBatch(_ name: String, id: UUID) throws -> SyncRemoteBatch {
        var archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: archiveURL))
        let index = archive.projects.firstIndex { $0.id == projectID }!
        archive.projects[index].name = name
        let exported = try ProjectArchiveSyncMapper.export(archive: archive,
            liveRoot: root.appendingPathComponent("Live"), deviceID: "remote")
        var record = exported.records.first { $0.id == .init(kind: .project, uuid: projectID) }!
        let stamp = SyncMutationStamp(logicalRevision: 1000, modifiedAt: Date(timeIntervalSince1970: 2_000_000_000), deviceID: "remote")
        record.payload.fields = record.payload.fields.mapValues { .init(value: $0.value, stamp: stamp) }
        record.deletedAt = .init(value: nil, stamp: stamp)
        return try batch(records: [record], id: id)
    }

    func photoBatch(
        id: UUID,
        sourceDirectoryName: String = "RemoteSource"
    ) throws -> (batch: SyncRemoteBatch, attachments: [UUID: SyncAttachmentSource]) {
        let remoteRoot = root.appendingPathComponent(sourceDirectoryName)
        let service = ProjectPhotoFileService(directory: remoteRoot.appendingPathComponent("ProjectPhotos"))
        var archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: archiveURL))
        let index = archive.projects.firstIndex { $0.id == projectID }!
        let filename = try service.save(data: BackupFixture.jpegData(red: 0.75), projectID: projectID)
        archive.projects[index].setPhotoFilename(filename)
        let exported = try ProjectArchiveSyncMapper.export(
            archive: archive,
            liveRoot: remoteRoot,
            deviceID: "remote-media"
        )
        let stamp = SyncMutationStamp(
            logicalRevision: 1_000,
            modifiedAt: Date(timeIntervalSince1970: 2_000_000_000),
            deviceID: "remote-media"
        )
        let records = exported.records.compactMap { original -> SyncRecord? in
            guard original.id == .init(kind: .project, uuid: projectID)
                    || original.payload.attachment?.slot.owner == .init(kind: .project, uuid: projectID) else {
                return nil
            }
            var record = original
            record.entityRevision = 1_000
            record.payload.fields = record.payload.fields.mapValues {
                .init(value: $0.value, stamp: stamp)
            }
            record.payload.atomicDomain = record.payload.atomicDomain.map {
                .init(value: $0.value, stamp: stamp)
            }
            record.deletedAt = .init(value: nil, stamp: stamp)
            return record
        }
        return (try batch(records: records, id: id), exported.attachments)
    }

    func renameLocally(_ name: String) throws {
        try store.updateProject(id: projectID, name: name, toolType: nil,
            toolSize: nil, toolNotes: nil, photoChange: .unchanged)
    }

    func acknowledgeBootstrap() throws {
        try journal.acknowledge(Set(try journal.pending().map { .init(recordID: $0.recordID, mutationID: $0.mutationID) }))
    }

    func freshJournal() -> FileSyncMutationJournal {
        FileSyncMutationJournal(url: journalURL)
    }

    func dropInitialHandles() {
        initialHandles.store = nil
        initialHandles.journal = nil
    }

    func reopen() throws -> JSONProjectStore {
        let journal = freshJournal()
        let fresh = JSONProjectStore(url: archiveURL,
            backupService: KnitNoteBackupService(liveRoot: root.appendingPathComponent("Live"),
                workRoot: root.appendingPathComponent("BackupWork")),
            syncMutationSink: JournalSyncMutationSink(journal: journal))
        try fresh.activateSyncCanonicalState(checkpointStore: checkpoints, bootstrap: nil, attachmentSources: [:])
        return fresh
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum SyncRemoteBatchFixtureError: Error {
    case missingCanonicalCheckpoint
}
