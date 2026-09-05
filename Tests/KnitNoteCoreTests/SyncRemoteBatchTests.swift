import Foundation
import Testing
@testable import KnitNoteCore

struct SyncRemoteBatchTests {
    @Test @MainActor func inputOrderDoesNotChangeIdentity() throws {
        let f = try RemoteBatchFixture(); defer { f.remove() }
        let id = UUID()
        let a = try f.batch(records: f.records, id: id)
        let b = try f.batch(records: Array(f.records.reversed()), id: id)
        #expect(a.identity == b.identity)
        #expect(a.identity.contentSHA256.count == 32)
    }

    @Test @MainActor func deletionOrderDoesNotChangeIdentity() throws {
        let f = try RemoteBatchFixture(); defer { f.remove() }
        let ids = Array(f.records.prefix(2).map(\.id))
        #expect(ids.count == 2)
        let batchID = UUID()
        let a = try SyncRemoteBatch(
            accountIDHash: f.account.accountIDHash,
            batchID: batchID,
            records: [],
            deletedRecordIDs: ids
        )
        let b = try SyncRemoteBatch(
            accountIDHash: f.account.accountIDHash,
            batchID: batchID,
            records: [],
            deletedRecordIDs: Array(ids.reversed())
        )
        #expect(a.identity == b.identity)
    }

    @Test(arguments: ["ABC123", String(repeating: "A", count: 64)])
    @MainActor func invalidAccountHashIsRejected(hash: String) throws {
        let f = try RemoteBatchFixture(); defer { f.remove() }
        #expect(throws: SyncRemoteBatchError.invalidBatch) {
            try SyncRemoteBatch(
                accountIDHash: hash,
                batchID: UUID(),
                records: f.records,
                deletedRecordIDs: []
            )
        }
    }

    @Test @MainActor func duplicateSavedRecordIDsAreRejected() throws {
        let f = try RemoteBatchFixture(); defer { f.remove() }
        let record = try #require(f.records.first)
        #expect(throws: SyncRemoteBatchError.invalidBatch) {
            try f.batch(records: [record, record], id: UUID())
        }
    }

    @Test @MainActor func duplicateDeletedRecordIDsAreRejected() throws {
        let f = try RemoteBatchFixture(); defer { f.remove() }
        let id = try #require(f.records.first?.id)
        #expect(throws: SyncRemoteBatchError.invalidBatch) {
            try SyncRemoteBatch(
                accountIDHash: f.account.accountIDHash,
                batchID: UUID(),
                records: [],
                deletedRecordIDs: [id, id]
            )
        }
    }

    @Test @MainActor func malformedRecordIsRejected() throws {
        let f = try RemoteBatchFixture(); defer { f.remove() }
        let source = try #require(f.records.first)
        let malformed = SyncRecord(
            schemaVersion: 2,
            id: source.id,
            createdAt: source.createdAt,
            entityRevision: source.entityRevision,
            payload: source.payload,
            relationships: source.relationships,
            deletedAt: source.deletedAt
        )
        #expect(throws: SyncRemoteBatchError.invalidBatch) {
            try f.batch(records: [malformed], id: UUID())
        }
    }

    @Test @MainActor func savingAndDeletingSameIDIsRejected() throws {
        let f = try RemoteBatchFixture(); defer { f.remove() }
        let record = try #require(f.records.first)
        #expect(throws: SyncRemoteBatchError.invalidBatch) {
            try SyncRemoteBatch(
                accountIDHash: f.account.accountIDHash,
                batchID: UUID(),
                records: [record],
                deletedRecordIDs: [record.id]
            )
        }
    }

    @Test @MainActor func changedContentWithSameBatchIDChangesIdentity() throws {
        let f = try RemoteBatchFixture(); defer { f.remove() }
        let id = UUID()
        var changed = try #require(f.records.first { $0.id.kind == .project })
        let name = try #require(changed.payload.fields["name"])
        changed.payload.fields["name"] = .init(value: .string("Changed"), stamp: name.stamp)

        let original = try f.batch(records: f.records, id: id)
        let replacement = f.records.map { $0.id == changed.id ? changed : $0 }
        let modified = try f.batch(records: replacement, id: id)

        #expect(original.identity.batchID == modified.identity.batchID)
        #expect(original.identity.contentSHA256 != modified.identity.contentSHA256)
    }

    @Test func encodedInputLargerThanPersistentAuthorityLimitIsRejected() throws {
        let account = try SyncAccountIdentity(
            containerIdentifier: "test.container",
            userRecordName: "remote-batch-capacity-test"
        )
        let stamp = SyncMutationStamp(
            logicalRevision: 1,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 1),
            deviceID: "capacity-test"
        )
        let scalar = SyncFieldVersion<SyncScalar>(
            value: .data(Data(repeating: 0, count: SyncRecordValidator.maximumScalarByteCount)),
            stamp: stamp
        )
        let records = (0..<300).map { _ in
            SyncRecord(
                schemaVersion: 1,
                id: .init(kind: .project, uuid: UUID()),
                createdAt: Date(timeIntervalSinceReferenceDate: 0),
                entityRevision: 1,
                payload: .init(fields: ["payload": scalar]),
                relationships: [],
                deletedAt: .init(value: nil, stamp: stamp)
            )
        }

        #expect(throws: SyncRemoteBatchError.invalidBatch) {
            try SyncRemoteBatch(
                accountIDHash: account.accountIDHash,
                batchID: UUID(),
                records: records,
                deletedRecordIDs: []
            )
        }
    }
}
