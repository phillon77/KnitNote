import Foundation
@testable import KnitNoteCore

@MainActor
struct ConflictRebaseFixture {
    let base: RemoteBatchFixture

    init(interleave: Bool = false,
        boundary: @escaping (SyncCanonicalPublicationBoundary) throws -> Void = { _ in }) throws {
        base = try RemoteBatchFixture(boundary: boundary)
        try base.acknowledgeBootstrap()
        try base.renameLocally("Local 1")
        if interleave { try renameOther("Other 1") }
        try base.renameLocally("Local 2")
        if interleave { try renameOther("Other 2") }
        try base.renameLocally("Local 3")
    }

    private func renameOther(_ name: String) throws {
        let other = base.store.projects.first { $0.id != base.projectID }!
        try base.store.updateProject(id: other.id, name: name, toolType: nil,
            toolSize: nil, toolNotes: nil, photoChange: .unchanged)
    }

    func input(attemptID: UUID = UUID(), serverRecord suppliedRecord: SyncRecord? = nil) throws -> SyncConflictInput {
        let versioned = try base.journal.pendingVersioned()
            .filter { $0.mutation.recordID == .init(kind: .project, uuid: base.projectID) }
        guard let failed = versioned.first else {
            throw ConflictRebaseFixtureError.missingPendingMutation
        }
        let serverRecord = try suppliedRecord ?? base.renamedBatch("Server", id: UUID()).records[0]
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

@MainActor
struct ConflictAttachmentFixture {
    let base: RemoteBatchFixture
    let input: SyncConflictInput
    let source: SyncAttachmentSource
    let version: SyncAttachmentVersion

    init(deleted: Bool, relocatedAttempt: Bool = false,
        boundary: @escaping (SyncCanonicalPublicationBoundary) throws -> Void = { _ in }) throws {
        base = try RemoteBatchFixture(boundary: boundary)
        try base.store.updateProject(id: base.projectID, name: "With photo", toolType: nil,
            toolSize: nil, toolNotes: nil, photoChange: .replace(BackupFixture.jpegData(red: 0.3)))
        let checkpoint = try base.checkpoints.load()!
        let original = checkpoint.records.first { $0.id.kind == .attachment }!
        version = original.payload.attachment!
        let photo = base.root.appendingPathComponent("Live/ProjectPhotos")
            .appendingPathComponent(base.store.project(id: base.projectID)!.photoFilename!)
        let retained = base.root.appendingPathComponent("raw-photo.bin")
        try Data(contentsOf: photo).write(to: retained)
        source = try .init(fileURL: retained, contentSHA256: version.contentSHA256, byteCount: version.byteCount)
        try base.acknowledgeBootstrap()
        if deleted { try base.store.delete(id: base.projectID) }
        else {
            try base.journal.enqueue([.save(recordVersion: .init(record: original), attachmentSource: source, mutationID: UUID())])
        }
        let queue = try base.journal.pendingVersioned().filter { $0.mutation.recordID == original.id }
        let failed = queue[0]
        var server = original
        if !deleted {
            server.deletedAt = .init(value: nil, stamp: .init(logicalRevision: 10_000,
                modifiedAt: Date(timeIntervalSince1970: 2_200_000_000), deviceID: "remote-overlay"))
        }
        let attempted = relocatedAttempt ? try SyncMutation.save(recordVersion: failed.mutation.savedRecordVersion!,
            attachmentSource: source, mutationID: failed.mutation.mutationID) : failed.mutation
        input = try .init(accountIDHash: base.account.accountIDHash, failedAttemptID: UUID(),
            failedMutation: attempted, failedVersion: failed.token, serverRecord: server,
            expectedRecordQueue: queue.map(\.mutation), expectedVersions: queue.map(\.token))
    }
}
