import Foundation
@testable import KnitNoteCore

@MainActor
struct ConflictRebaseFixture {
    let base: RemoteBatchFixture

    init() throws {
        base = try RemoteBatchFixture()
        try base.acknowledgeBootstrap()
        try base.renameLocally("Local 1")
        try base.renameLocally("Local 2")
        try base.renameLocally("Local 3")
    }

    func input(attemptID: UUID = UUID()) throws -> SyncConflictInput {
        let pending = try base.journal.pending()
        guard let failedMutation = pending.first else {
            throw ConflictRebaseFixtureError.missingPendingMutation
        }
        let serverRecord = try base.renamedBatch("Server", id: UUID()).records[0]
        return try SyncConflictInput(
            accountIDHash: base.account.accountIDHash,
            failedAttemptID: attemptID,
            failedMutation: failedMutation,
            failedVersion: SyncMutationVersionToken(mutation: failedMutation),
            serverRecord: serverRecord,
            expectedRecordQueue: pending,
            expectedVersions: try pending.map {
                try SyncMutationVersionToken(mutation: $0)
            }
        )
    }

    func remove() {
        base.remove()
    }
}

private enum ConflictRebaseFixtureError: Error {
    case missingPendingMutation
}
