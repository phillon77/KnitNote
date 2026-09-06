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
        let versioned = try base.journal.pendingVersioned()
        guard let failed = versioned.first else {
            throw ConflictRebaseFixtureError.missingPendingMutation
        }
        let serverRecord = try base.renamedBatch("Server", id: UUID()).records[0]
        return try SyncConflictInput(
            accountIDHash: base.account.accountIDHash,
            failedAttemptID: attemptID,
            failedMutation: failed.mutation,
            failedVersion: failed.token,
            serverRecord: serverRecord,
            expectedRecordQueue: versioned.map(\.mutation),
            expectedVersions: versioned.map(\.token)
        )
    }

    func remove() {
        base.remove()
    }
}

private enum ConflictRebaseFixtureError: Error {
    case missingPendingMutation
}
