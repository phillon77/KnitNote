import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct SyncRecordValidationTests {
    @Test func yarnLinkRequiresProjectAndYarnWithoutDeletingYarn() throws {
        let link = SyncRecord.fixture(kind: .projectYarnLink, relationships: [
            .init(role: "project", target: .init(kind: .project, uuid: UUID())),
            .init(role: "yarn", target: .init(kind: .yarn, uuid: UUID()))
        ])

        #expect(try SyncRecordValidator().validate(link) == link)
        #expect(link.payload.deletedRelatedEntityIDs.isEmpty)
    }

    @Test func futureSchemaIsRejected() {
        #expect(throws: SyncRecordValidationError.unsupportedSchema(2)) {
            try SyncRecordValidator(currentSchemaVersion: 1).validate(.fixture(schemaVersion: 2))
        }
    }

    @Test func missingProjectRelationshipIsRejectedWithoutSynthesizingIt() {
        let link = SyncRecord.fixture(kind: .projectYarnLink, relationships: [
            .init(role: "yarn", target: .init(kind: .yarn, uuid: UUID()))
        ])

        #expect(throws: SyncRecordValidationError.missingRequiredRelationship(link.id, "project")) {
            try SyncRecordValidator().validate(link)
        }
    }

    @Test func duplicateSingularProjectRelationshipIsRejected() {
        let link = SyncRecord.fixture(kind: .projectYarnLink, relationships: [
            .init(role: "project", target: .init(kind: .project, uuid: UUID())),
            .init(role: "project", target: .init(kind: .project, uuid: UUID())),
            .init(role: "yarn", target: .init(kind: .yarn, uuid: UUID()))
        ])

        #expect(throws: SyncRecordValidationError.duplicateSingularRelationship(link.id, "project")) {
            try SyncRecordValidator().validate(link)
        }
    }

    @Test func crossKindYarnLinkRelationshipIsRejected() {
        let link = SyncRecord.fixture(kind: .projectYarnLink, relationships: [
            .init(role: "project", target: .init(kind: .yarn, uuid: UUID())),
            .init(role: "yarn", target: .init(kind: .yarn, uuid: UUID()))
        ])

        #expect(throws: SyncRecordValidationError.illegalRelationshipKind(link.id, "project", .yarn)) {
            try SyncRecordValidator().validate(link)
        }
    }

    @Test func oversizedScalarIsRejected() {
        let record = SyncRecord.fixture(fields: [
            "note": .init(
                value: .string(String(repeating: "a", count: 256 * 1024 + 1)),
                stamp: .fixture
            )
        ])

        #expect(throws: SyncRecordValidationError.scalarValueTooLarge("note", 256 * 1024 + 1)) {
            try SyncRecordValidator().validate(record)
        }
    }

    @Test func scalarValuesAtTheSizeLimitAreAccepted() throws {
        let record = SyncRecord.fixture(fields: [
            "photoBytes": .init(
                value: .data(Data(repeating: 0, count: 256 * 1024)),
                stamp: .fixture
            )
        ])

        #expect(try SyncRecordValidator().validate(record) == record)
    }

    @Test func yarnLinkCannotRequestYarnDeletion() {
        let yarnID = SyncEntityID(kind: .yarn, uuid: UUID())
        var link = SyncRecord.fixture(kind: .projectYarnLink, relationships: [
            .init(role: "project", target: .init(kind: .project, uuid: UUID())),
            .init(role: "yarn", target: yarnID)
        ])
        link.payload.deletedRelatedEntityIDs = [yarnID]

        #expect(throws: SyncRecordValidationError.illegalRelatedDeletion(link.id, yarnID)) {
            try SyncRecordValidator().validate(link)
        }
    }
}

private extension SyncMutationStamp {
    static let fixture = SyncMutationStamp(
        logicalRevision: 1,
        modifiedAt: Date(timeIntervalSince1970: 1),
        deviceID: "test-device"
    )
}

private extension SyncRecord {
    static func fixture(
        kind: SyncEntityKind = .project,
        schemaVersion: Int = 1,
        fields: [String: SyncFieldVersion<SyncScalar>] = [:],
        relationships: [SyncRelationship] = []
    ) -> SyncRecord {
        SyncRecord(
            schemaVersion: schemaVersion,
            id: .init(kind: kind, uuid: UUID()),
            entityRevision: 1,
            payload: .init(fields: fields),
            relationships: relationships,
            deletedAt: .init(value: nil, stamp: .fixture)
        )
    }
}
