import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct SyncMergeEngineTests {
    @Test func concurrentDifferentFieldsMergeAndSameFieldUsesStamp() throws {
        let id = SyncEntityID(kind: .project, uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let local = SyncRecord.project(
            id: id,
            name: "Local",
            note: "Base",
            nameRevision: 4,
            noteRevision: 1
        )
        let remote = SyncRecord.project(
            id: id,
            name: "Base",
            note: "Remote",
            nameRevision: 1,
            noteRevision: 5
        )

        let result = try SyncMergeEngine().merge(
            local: [local],
            remote: [remote],
            pendingLocal: []
        )

        #expect(result.records.single.string("name") == "Local")
        #expect(result.records.single.string("note") == "Remote")
        #expect(result.recordsToUpload == [id])
    }

    @Test func unequalValuesWithEqualStampAreRejectedAsCorrupt() {
        let id = SyncEntityID(kind: .project, uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let local = SyncRecord.project(id: id, name: "Local", note: "", nameRevision: 3, noteRevision: 1)
        let remote = SyncRecord.project(id: id, name: "Remote", note: "", nameRevision: 3, noteRevision: 1)

        #expect(throws: SyncMergeError.corruptEqualStamp(entity: id, field: "name")) {
            try SyncMergeEngine().merge(local: [local], remote: [remote], pendingLocal: [])
        }
    }

    @Test func repeatedIDFieldCorruptionIsRejectedInEveryInputOrder() {
        let id = SyncEntityID(kind: .project, uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!)
        let olderA = SyncRecord.project(id: id, name: "A", note: "", nameRevision: 1, noteRevision: 1)
        let olderB = SyncRecord.project(id: id, name: "B", note: "", nameRevision: 1, noteRevision: 1)
        let newer = SyncRecord.project(id: id, name: "C", note: "", nameRevision: 2, noteRevision: 1)
        let permutations = [
            [olderA, olderB, newer],
            [olderA, newer, olderB],
            [olderB, olderA, newer],
            [olderB, newer, olderA],
            [newer, olderA, olderB],
            [newer, olderB, olderA]
        ]

        for records in permutations {
            #expect(throws: SyncMergeError.corruptEqualStamp(entity: id, field: "name")) {
                try SyncMergeEngine().merge(local: records, remote: [], pendingLocal: [])
            }
        }
    }

    @Test func repeatedIDDeletedAtCorruptionIsRejectedInEveryInputOrder() {
        let id = SyncEntityID(kind: .project, uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!)
        var olderNil = SyncRecord.project(id: id, name: "Project", note: "", nameRevision: 1, noteRevision: 1)
        var olderDeleted = olderNil
        var newerDeleted = olderNil
        olderNil.deletedAt = .init(value: nil, stamp: .test(revision: 1))
        olderDeleted.deletedAt = .init(
            value: Date(timeIntervalSince1970: 100),
            stamp: .test(revision: 1)
        )
        newerDeleted.deletedAt = .init(
            value: Date(timeIntervalSince1970: 200),
            stamp: .test(revision: 2)
        )
        let permutations = [
            [olderNil, olderDeleted, newerDeleted],
            [olderNil, newerDeleted, olderDeleted],
            [olderDeleted, olderNil, newerDeleted],
            [olderDeleted, newerDeleted, olderNil],
            [newerDeleted, olderNil, olderDeleted],
            [newerDeleted, olderDeleted, olderNil]
        ]

        for records in permutations {
            #expect(throws: SyncMergeError.corruptEqualStamp(entity: id, field: "deletedAt")) {
                try SyncMergeEngine().merge(local: records, remote: [], pendingLocal: [])
            }
        }
    }

    @Test func deletePlusModifyStaysDeletedAndRetainsMergedPayload() throws {
        let id = SyncEntityID(kind: .project, uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        let local = SyncRecord.project(id: id, name: "Project", note: "Offline edit", nameRevision: 1, noteRevision: 8)
        var remote = SyncRecord.project(id: id, name: "Project", note: "Base", nameRevision: 1, noteRevision: 1)
        remote.deletedAt = .init(
            value: Date(timeIntervalSince1970: 500),
            stamp: .init(logicalRevision: 7, modifiedAt: Date(timeIntervalSince1970: 500), deviceID: "remote")
        )

        let result = try SyncMergeEngine().merge(local: [local], remote: [remote], pendingLocal: [id])

        #expect(result.records.single.deletedAt.value == Date(timeIntervalSince1970: 500))
        #expect(result.records.single.string("note") == "Offline edit")
        #expect(result.recordsToUpload == [id])
    }

    @Test func concurrentAttachmentVersionsAreBothRetainedAndSurfaced() throws {
        let owner = SyncEntityID(kind: .project, uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
        let first = try SyncRecord.attachment(
            owner: owner,
            role: "projectPhoto",
            slotID: "primary",
            bytes: Data("first".utf8)
        )
        let second = try SyncRecord.attachment(
            owner: owner,
            role: "projectPhoto",
            slotID: "primary",
            bytes: Data("second".utf8)
        )
        let firstID = first.id
        let secondID = second.id
        let orderedIDs = [firstID, secondID].sorted {
            ($0.kind.rawValue, $0.uuid.uuidString) < ($1.kind.rawValue, $1.uuid.uuidString)
        }

        let result = try SyncMergeEngine().merge(local: [second], remote: [first], pendingLocal: [secondID])

        #expect(result.records.map(\.id) == orderedIDs)
        #expect(result.conflicts == [
            .attachmentVersions(owner: owner, role: "projectPhoto", ids: orderedIDs)
        ])
    }

    @Test func sameNormalizedNameWithDifferentIDsIsOnlyFlaggedAsPossibleDuplicate() throws {
        let firstID = SyncEntityID(kind: .project, uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!)
        let secondID = SyncEntityID(kind: .project, uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000008")!)
        let first = SyncRecord.project(id: firstID, name: "  Cardigan ", note: "First", nameRevision: 1, noteRevision: 1)
        let second = SyncRecord.project(id: secondID, name: "cardigan", note: "Second", nameRevision: 1, noteRevision: 1)

        let result = try SyncMergeEngine().merge(local: [first], remote: [second], pendingLocal: [])

        #expect(result.records.map(\.id) == [firstID, secondID])
        #expect(result.conflicts == [.possibleDuplicate(ids: [firstID, secondID])])
    }

    @Test func inputOrderNeverChangesMergeOutput() throws {
        let firstID = SyncEntityID(kind: .project, uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!)
        let secondID = SyncEntityID(kind: .project, uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!)
        let fixtures = [
            SyncRecord.project(id: secondID, name: "Second", note: "B", nameRevision: 2, noteRevision: 2),
            SyncRecord.project(id: firstID, name: "First", note: "A", nameRevision: 1, noteRevision: 1)
        ]

        let a = try SyncMergeEngine().merge(local: fixtures, remote: fixtures.reversed(), pendingLocal: [])
        let b = try SyncMergeEngine().merge(local: fixtures.reversed(), remote: fixtures, pendingLocal: [])

        #expect(a == b)
        #expect(a.records.map(\.id) == [firstID, secondID])
    }

    @Test func localOnlyAndPendingRecordsUploadWhileRemoteOnlyRecordDoesNot() throws {
        let localID = SyncEntityID(kind: .project, uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!)
        let remoteID = SyncEntityID(kind: .project, uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!)
        let local = SyncRecord.project(id: localID, name: "Local", note: "", nameRevision: 1, noteRevision: 1)
        let remote = SyncRecord.project(id: remoteID, name: "Remote", note: "", nameRevision: 1, noteRevision: 1)

        let result = try SyncMergeEngine().merge(
            local: [local],
            remote: [remote],
            pendingLocal: [localID]
        )

        #expect(result.records.map(\.id) == [localID, remoteID])
        #expect(result.recordsToUpload == [localID])
    }
}

private extension SyncRecord {
    static func project(
        id: SyncEntityID,
        name: String,
        note: String,
        nameRevision: UInt64,
        noteRevision: UInt64
    ) -> SyncRecord {
        SyncRecord(
            schemaVersion: 1,
            id: id,
            createdAt: Date(timeIntervalSince1970: 0),
            entityRevision: max(nameRevision, noteRevision),
            payload: .init(fields: [
                "name": .init(value: .string(name), stamp: .test(revision: nameRevision)),
                "note": .init(value: .string(note), stamp: .test(revision: noteRevision))
            ]),
            relationships: [],
            deletedAt: .init(value: nil, stamp: .test(revision: 1))
        )
    }

    static func attachment(
        owner: SyncEntityID,
        role: String,
        slotID: String,
        bytes: Data
    ) throws -> SyncRecord {
        let attachment = try SyncAttachmentVersion.issuing(
            slot: .init(owner: owner, role: role, slotID: slotID),
            contentSHA256: Data(SHA256.hash(data: bytes)),
            byteCount: Int64(bytes.count),
            mediaType: "image/jpeg",
            displayFilename: "photo.jpg"
        )
        return SyncRecord(
            schemaVersion: 1,
            id: .init(kind: .attachment, uuid: attachment.versionID),
            createdAt: Date(timeIntervalSince1970: 0),
            entityRevision: 1,
            payload: .init(fields: [
                "role": .init(value: .string(role), stamp: .test(revision: 1))
            ], attachment: attachment),
            relationships: [.init(role: "owner", target: owner)],
            deletedAt: .init(value: nil, stamp: .test(revision: 1))
        )
    }

    func string(_ field: String) -> String? {
        guard case let .string(value)? = payload.fields[field]?.value else { return nil }
        return value
    }
}

private extension SyncMutationStamp {
    static func test(revision: UInt64) -> SyncMutationStamp {
        SyncMutationStamp(
            logicalRevision: revision,
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(revision)),
            deviceID: "test-device"
        )
    }
}

private extension Array where Element == SyncRecord {
    var single: SyncRecord {
        precondition(count == 1)
        return self[0]
    }
}
