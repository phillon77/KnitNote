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

    init() throws {
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

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum SyncRemoteBatchFixtureError: Error {
    case missingCanonicalCheckpoint
}
