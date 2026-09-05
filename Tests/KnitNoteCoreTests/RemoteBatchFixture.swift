import Foundation
@testable import KnitNoteCore

@MainActor
struct RemoteBatchFixture {
    let root: URL
    let account: SyncAccountIdentity
    let records: [SyncRecord]
    let projectID: UUID
    let store: JSONProjectStore
    let journal: FileSyncMutationJournal
    let checkpoints: SyncCanonicalCheckpointStore

    init(boundary: @escaping (SyncCanonicalPublicationBoundary) throws -> Void = { _ in }) throws {
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

        journal = FileSyncMutationJournal(
            url: live.appendingPathComponent("SyncMetadata/pending.json")
        )
        checkpoints = try SyncCanonicalCheckpointStore(
            liveRoot: live,
            account: account,
            validateOwnership: {}
        )
        store = JSONProjectStore(
            url: archiveURL,
            backupService: KnitNoteBackupService(
                liveRoot: live,
                workRoot: root.appendingPathComponent("BackupWork")
            ),
            syncCanonicalPublicationBoundary: boundary,
            syncMutationSink: JournalSyncMutationSink(journal: journal)
        )
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

    func renameLocally(_ name: String) throws {
        try store.updateProject(id: projectID, name: name, toolType: nil,
            toolSize: nil, toolNotes: nil, photoChange: .unchanged)
    }

    func acknowledgeBootstrap() throws {
        try journal.acknowledge(Set(try journal.pending().map { .init(recordID: $0.recordID, mutationID: $0.mutationID) }))
    }

    func reopen() throws -> JSONProjectStore {
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
