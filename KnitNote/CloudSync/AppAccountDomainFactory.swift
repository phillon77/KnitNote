import CloudKit
import Foundation

@MainActor struct AppAccountDomainContext {
    let account: CloudAccountBinding
    let paths: SyncAccountStorage.Paths
    let journal: FileSyncMutationJournal
    let validateOwnership: () throws -> Void
}

@MainActor struct AppAccountDomainRuntime {
    let assets: CloudAssetStagingService
    let incoming: FileCloudIncomingBatchStore
    let zoneID: CKRecordZone.ID
}

@MainActor struct AppAccountInstalledDomain {
    let resources: AppSessionResources
    let recordProvider: any SyncRecordProvider
    let fetchedBatchCommitter: any SyncFetchedBatchCommitting
    fileprivate init(resources: AppSessionResources, recordProvider: any SyncRecordProvider,
        fetchedBatchCommitter: any SyncFetchedBatchCommitting) {
        self.resources = resources; self.recordProvider = recordProvider
        self.fetchedBatchCommitter = fetchedBatchCommitter
    }
}

struct AppAccountRecordSnapshot: SyncRecordProvider {
    let recordsByID: [SyncEntityID: SyncRecord]
    func record(for id: SyncEntityID) throws -> SyncRecord? { recordsByID[id] }
}

@MainActor final class AppAccountDomainFactory {
    private let entitlement: EntitlementCoordinator
    private let backupHistory: BackupHistory
    init(entitlement: EntitlementCoordinator, backupHistory: BackupHistory) {
        self.entitlement = entitlement; self.backupHistory = backupHistory
    }

    func install(context: AppAccountDomainContext, runtime: AppAccountDomainRuntime,
        bootstrap: SyncCanonicalBootstrapHandoff?) throws -> AppAccountInstalledDomain {
        try context.validateOwnership()
        guard runtime.assets.accountIdentifier == context.account.userRecordName else { throw SyncRemoteBatchError.missingAuthority }
        let root = context.paths.workingSet
        if let bootstrap {
            guard bootstrap.accountIDHash == context.account.identity.accountIDHash,
                  bootstrap.liveRoot.standardizedFileURL == root.standardizedFileURL else {
                throw SyncPublicationError.corruptTransaction
            }
            try bootstrap.revalidate()
        }
        let checkpoints = try SyncCanonicalCheckpointStore(liveRoot: root, account: context.account.identity,
            validateOwnership: context.validateOwnership)
        let archiveURL = root.appendingPathComponent("projects-v1.json")
        let store = JSONProjectStore(url: archiveURL, syncMutationSink: JournalSyncMutationSink(journal: context.journal),
            authorizeMutation: { [entitlement] in entitlement.authorize($0) },
            commitSuccessfulMutation: { [entitlement] in entitlement.commitSuccessfulMutation($0) })
        let resolver = AppAccountAttachmentResolver(account: context.account.identity,
            installedDownload: { try runtime.assets.installedDownload(version: $0) }, validateOwnership: context.validateOwnership)
        try store.activateSyncCanonicalState(checkpointStore: checkpoints, bootstrap: bootstrap,
            attachmentSourceResolver: { checkpoint in
                try context.validateOwnership()
                guard checkpoint.accountIDHash == context.account.identity.accountIDHash else { throw SyncPublicationError.corruptTransaction }
                let bytes = try SyncRegularFileReader().read(archiveURL, maximumBytes: SyncCanonicalCheckpoint.maximumBytes,
                    expected: .init(sha256: checkpoint.archiveSHA256)).data
                let archive = try JSONDecoder().decode(ProjectArchive.self, from: bytes)
                let references = try SyncArchiveAttachmentReferences(liveRoot: root).references(in: archive)
                return try resolver.canonical(records: checkpoint.records, references: references,
                    pending: context.journal.pending(), bootstrap: bootstrap)
            })
        guard store.loadError == nil, store.syncPublicationError == nil,
              let checkpoint = try checkpoints.load() else { throw SyncPublicationError.pendingRepair }
        let records = try SyncRecordValidator().validate(checkpoint.records)
        let snapshot = AppAccountRecordSnapshot(recordsByID: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }))
        let committer = JSONProjectStoreRemoteBatchCommitter(store: store, expectedAccount: context.account.identity,
            attachmentSources: { try resolver.fetched(batch: $0) },
            verifyAcknowledgement: { identity in
                try context.validateOwnership()
                try runtime.incoming.verifyAcknowledgement(identity, accountIdentifier: context.account.userRecordName,
                    zoneID: runtime.zoneID, account: context.account.identity)
                try context.validateOwnership()
            })
        try context.validateOwnership()
        return try .init(resources: AppSessionComposition.make(store: store, backupHistory: backupHistory, makeWatch: { _ in nil }),
            recordProvider: snapshot, fetchedBatchCommitter: committer)
    }
}
