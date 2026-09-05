import Foundation

@MainActor final class JSONProjectStoreRemoteBatchCommitter: SyncFetchedBatchCommitting {
    private let store: JSONProjectStore
    private let account: SyncAccountIdentity
    private let attachmentSources: (SyncRemoteBatch) async throws -> [UUID: SyncAttachmentSource]
    private let verifyAcknowledgement: (SyncRemoteBatchIdentity) throws -> Void

    init(store: JSONProjectStore, expectedAccount: SyncAccountIdentity,
        attachmentSources: @escaping (SyncRemoteBatch) async throws -> [UUID: SyncAttachmentSource],
        verifyAcknowledgement: @escaping (SyncRemoteBatchIdentity) throws -> Void) {
        self.store = store; account = expectedAccount
        self.attachmentSources = attachmentSources; self.verifyAcknowledgement = verifyAcknowledgement
    }

    func commitFetchedBatch(batch: SyncRemoteBatch, accountEpoch: CloudSyncAccountEpoch) async throws {
        try validate(batch.identity, epoch: accountEpoch)
        let sources = try await attachmentSources(batch)
        for _ in 0..<3 {
            try validate(batch.identity, epoch: accountEpoch)
            do {
                let preparation = try store.prepareRemoteBatch(batch, attachmentSources: sources)
                let result = try store.commitRemoteBatch(preparation) { commit in
                    try accountEpoch.withCurrent {
                        try validateIdentity(batch.identity, epoch: accountEpoch)
                        return try commit()
                    }
                }
                if result != .stalePredecessor { return }
            } catch SyncBootstrapError.sourceChanged {
                continue
            }
        }
        throw SyncBootstrapError.sourceChanged
    }

    private func validateIdentity(_ identity: SyncRemoteBatchIdentity, epoch: CloudSyncAccountEpoch) throws {
        guard try epoch.verifiedAccountIdentity() == account, identity.accountIDHash == account.accountIDHash else {
            throw SyncRemoteBatchError.missingAuthority
        }
    }

    private func validate(_ identity: SyncRemoteBatchIdentity, epoch: CloudSyncAccountEpoch) throws {
        try epoch.requireCurrent()
        try validateIdentity(identity, epoch: epoch)
    }

    func didAcknowledgeFetchedBatch(batch: SyncRemoteBatchIdentity, accountEpoch: CloudSyncAccountEpoch) async throws {
        try accountEpoch.withCurrent {
            try validateIdentity(batch, epoch: accountEpoch)
            try store.retireRemoteBatchReceipt(batch) { try verifyAcknowledgement(batch) }
        }
    }

    func commitServerRecordChanged(failedMutation: SyncMutation, accountEpoch: CloudSyncAccountEpoch,
        expectedRecordQueue: [SyncMutationIdentity], mergeResult: SyncMergeResult) async throws -> SyncFailedMutationCommitResult {
        throw SyncRemoteBatchError.unsupportedConflictReplacement
    }
}
