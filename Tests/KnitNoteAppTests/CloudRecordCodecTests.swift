import CloudKit
import Foundation
import Testing
@testable import KnitNote

@Suite struct CloudRecordCodecTests {
    @Test func booleanCannotImpersonateSchemaVersionOne() throws {
        let codec = CloudRecordCodec()
        let record = try encodedProjectYarnLinkRecord(using: codec)
        record["schemaVersion"] = NSNumber(value: true)
        #expect(throws: CloudRecordCodecError.malformedRecord) { try codec.decode(record) }
    }

    @Test func roundTripsVersionedFieldsAndExplicitRelationships() throws {
        let source = try projectYarnLinkRecord()
        let codec = CloudRecordCodec()
        let zoneID = CKRecordZone.ID(zoneName: "sync", ownerName: CKCurrentUserDefaultName)

        let encoded = try codec.encode(source, zoneID: zoneID)

        #expect(encoded.recordType == "projectYarnLink")
        #expect(encoded.recordID.recordName == "projectYarnLink-00000000-0000-0000-0000-000000000010")
        #expect(encoded.recordID.zoneID == zoneID)
        #expect(encoded["relationshipRoles"] as? [String] == ["project", "yarn"])
        #expect(encoded["relationshipKinds"] as? [String] == ["project", "yarn"])
        #expect(encoded["relationshipUUIDs"] as? [String] == [
            "00000000-0000-0000-0000-000000000001",
            "00000000-0000-0000-0000-000000000002",
        ])
        #expect(encoded.recordID.recordName.contains("kept exactly") == false)
        #expect(try codec.decode(encoded) == source)
    }

    @Test func decodesRecordWithUnknownOptionalFields() throws {
        let source = try projectYarnLinkRecord()
        let codec = CloudRecordCodec()
        let encoded = try codec.encode(
            source,
            zoneID: CKRecordZone.ID(zoneName: "sync", ownerName: CKCurrentUserDefaultName)
        )
        encoded["futureOptionalField"] = "ignored" as NSString

        #expect(try codec.decode(encoded) == source)
    }

    @Test(arguments: KnownOptionalField.allCases)
    func rejectsWronglyTypedKnownOptionalFields(_ field: KnownOptionalField) throws {
        let codec = CloudRecordCodec()
        let encoded = try encodedProjectYarnLinkRecord(using: codec)
        encoded[field.recordKey] = "wrong type" as NSString

        #expect(throws: CloudRecordCodecError.malformedRecord) {
            try codec.decode(encoded)
        }
    }

    @Test func rejectsOversizedUnknownOptionalField() throws {
        let codec = CloudRecordCodec()
        let encoded = try encodedProjectYarnLinkRecord(using: codec)
        encoded["futureOptionalField"] = Data(
            repeating: 0,
            count: CloudRecordCodec.maximumNonAssetPayloadByteCount
        )

        #expect(throws: CloudRecordCodecError.payloadTooLarge) {
            try codec.decode(encoded)
        }
    }

    @Test func rejectsUnsupportedSchemaInsteadOfGuessingItsMeaning() throws {
        let source = try projectYarnLinkRecord()
        let codec = CloudRecordCodec()
        let encoded = try codec.encode(
            source,
            zoneID: CKRecordZone.ID(zoneName: "sync", ownerName: CKCurrentUserDefaultName)
        )
        encoded["schemaVersion"] = 2 as NSNumber

        #expect(throws: SyncRecordValidationError.unsupportedSchema(2)) {
            try codec.decode(encoded)
        }
    }

    @Test func rejectsFractionalSchemaMetadataInsteadOfTruncatingIt() throws {
        let source = try projectYarnLinkRecord()
        let codec = CloudRecordCodec()
        let encoded = try codec.encode(
            source,
            zoneID: CKRecordZone.ID(zoneName: "sync", ownerName: CKCurrentUserDefaultName)
        )
        encoded["schemaVersion"] = 1.5 as NSNumber

        #expect(throws: CloudRecordCodecError.malformedRecord) {
            try codec.decode(encoded)
        }
    }

    @Test func rejectsNonAssetPayloadsLargerThanApplicationLimit() throws {
        let stamp = SyncMutationStamp(
            logicalRevision: 1,
            modifiedAt: Date(timeIntervalSince1970: 1),
            deviceID: "device-a"
        )
        let source = SyncRecord(
            schemaVersion: 1,
            id: .init(kind: .project, uuid: UUID()),
            createdAt: Date(timeIntervalSince1970: 0),
            entityRevision: 1,
            payload: .init(fields: [
                "payload": .init(
                    value: .data(Data(repeating: 1, count: 256 * 1024)),
                    stamp: stamp
                ),
            ]),
            relationships: [],
            deletedAt: .init(value: nil, stamp: stamp)
        )

        #expect(throws: CloudRecordCodecError.payloadTooLarge) {
            try CloudRecordCodec().encode(
                source,
                zoneID: CKRecordZone.ID(zoneName: "sync", ownerName: CKCurrentUserDefaultName)
            )
        }
    }

    @Test func mapsEveryCurrentEntityKindToItsOwnCloudRecordType() {
        let expected: Set<String> = [
            "project", "projectCounter", "rowNote", "knittingReminder", "journalEntry",
            "yarn", "projectYarnLink", "patternFolder", "pattern", "patternUsage",
            "attachment", "deletionMarker", "watchCommandProof",
        ]

        #expect(Set(SyncEntityKind.allCases.map {
            CloudRecordCodec.recordType(for: $0)
        }) == expected)
        #expect(SyncEntityKind.allCases.count == expected.count)
    }

    @Test func roundTripsAttachmentMetadataWithoutAddingAnAsset() throws {
        let stamp = SyncMutationStamp(
            logicalRevision: 3,
            modifiedAt: Date(timeIntervalSince1970: 3),
            deviceID: "device-a"
        )
        let owner = SyncEntityID(
            kind: .project,
            uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let attachment = try SyncAttachmentVersion.issuing(
            slot: .init(owner: owner, role: "project-photo", slotID: "cover"),
            contentSHA256: Data(repeating: 7, count: 32),
            byteCount: 42,
            mediaType: "image/jpeg",
            displayFilename: "cover.jpg",
            versionID: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        )
        let source = SyncRecord(
            schemaVersion: 1,
            id: .init(kind: .attachment, uuid: attachment.versionID),
            createdAt: stamp.modifiedAt,
            entityRevision: stamp.logicalRevision,
            payload: .init(fields: [:], attachment: attachment),
            relationships: [.init(role: "owner", target: owner)],
            deletedAt: .init(value: nil, stamp: stamp)
        )
        let encoded = try CloudRecordCodec().encode(
            source,
            zoneID: CKRecordZone.ID(zoneName: "sync", ownerName: CKCurrentUserDefaultName)
        )

        #expect(encoded["attachment"] is Data)
        #expect(encoded.allKeys().contains("asset") == false)
        #expect(try CloudRecordCodec().decode(encoded) == source)
    }
}

enum KnownOptionalField: CaseIterable, Sendable {
    case deletedAt
    case deletionCascade
    case atomicDomain
    case attachment

    var recordKey: String {
        switch self {
        case .deletedAt:
            "deletedAt"
        case .deletionCascade:
            "deletionCascade"
        case .atomicDomain:
            "atomicDomain"
        case .attachment:
            "attachment"
        }
    }
}

private func projectYarnLinkRecord() throws -> SyncRecord {
    let stamp = SyncMutationStamp(
        logicalRevision: 7,
        modifiedAt: Date(timeIntervalSince1970: 7),
        deviceID: "device-a"
    )
    return SyncRecord(
        schemaVersion: 1,
        id: .init(
            kind: .projectYarnLink,
            uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        ),
        createdAt: Date(timeIntervalSince1970: 1),
        entityRevision: 7,
        payload: .init(fields: [
            "note": .init(value: .string("kept exactly"), stamp: stamp),
            "quantity": .init(value: .decimal(2.5), stamp: stamp),
        ]),
        relationships: [
            .init(
                role: "project",
                target: .init(
                    kind: .project,
                    uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
                )
            ),
            .init(
                role: "yarn",
                target: .init(
                    kind: .yarn,
                    uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
                )
            ),
        ],
        deletedAt: .init(value: nil, stamp: stamp)
    )
}

private func encodedProjectYarnLinkRecord(using codec: CloudRecordCodec) throws -> CKRecord {
    try codec.encode(
        projectYarnLinkRecord(),
        zoneID: CKRecordZone.ID(zoneName: "sync", ownerName: CKCurrentUserDefaultName)
    )
}
