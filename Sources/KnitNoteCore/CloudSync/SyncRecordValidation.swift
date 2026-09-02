import Foundation

public enum SyncRecordValidationError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case missingRequiredRelationship(SyncEntityID, String)
    case duplicateSingularRelationship(SyncEntityID, String)
    case illegalRelationshipKind(SyncEntityID, String, SyncEntityKind)
    case scalarValueTooLarge(String, Int)
    case illegalRelatedDeletion(SyncEntityID, SyncEntityID)
}

public struct SyncRecordValidator: Sendable {
    public static let maximumScalarByteCount = 256 * 1024

    public let currentSchemaVersion: Int

    public init(currentSchemaVersion: Int = 1) {
        self.currentSchemaVersion = currentSchemaVersion
    }

    @discardableResult
    public func validate(_ record: SyncRecord) throws -> SyncRecord {
        guard record.schemaVersion == currentSchemaVersion else {
            throw SyncRecordValidationError.unsupportedSchema(record.schemaVersion)
        }

        try validateScalars(in: record)
        try validateRelationships(in: record)
        try validateRelatedDeletions(in: record)
        return record
    }

    private func validateScalars(in record: SyncRecord) throws {
        for (field, version) in record.payload.fields {
            let byteCount = version.value.byteCount
            guard byteCount <= Self.maximumScalarByteCount else {
                throw SyncRecordValidationError.scalarValueTooLarge(field, byteCount)
            }
        }
    }

    private func validateRelationships(in record: SyncRecord) throws {
        guard let rules = Self.relationshipRules[record.id.kind] else {
            return
        }

        for rule in rules {
            let relationships = record.relationships.filter { $0.role == rule.role }
            if rule.required, relationships.isEmpty {
                throw SyncRecordValidationError.missingRequiredRelationship(record.id, rule.role)
            }
            if rule.isSingular, relationships.count > 1 {
                throw SyncRecordValidationError.duplicateSingularRelationship(record.id, rule.role)
            }
            for relationship in relationships where !rule.allowedTargetKinds.contains(relationship.target.kind) {
                throw SyncRecordValidationError.illegalRelationshipKind(
                    record.id,
                    rule.role,
                    relationship.target.kind
                )
            }
        }
    }

    private func validateRelatedDeletions(in record: SyncRecord) throws {
        guard record.id.kind == .projectYarnLink else {
            return
        }

        if let yarnID = record.payload.deletedRelatedEntityIDs.first(where: { $0.kind == .yarn }) {
            throw SyncRecordValidationError.illegalRelatedDeletion(record.id, yarnID)
        }
    }

    private struct RelationshipRule: Sendable {
        let role: String
        let allowedTargetKinds: Set<SyncEntityKind>
        let required: Bool
        let isSingular: Bool
        static let projectParent = Self(
            role: "project",
            allowedTargetKinds: [.project],
            required: true,
            isSingular: true
        )

        static let yarn = Self(
            role: "yarn",
            allowedTargetKinds: [.yarn],
            required: true,
            isSingular: true
        )

        static let pattern = Self(
            role: "pattern",
            allowedTargetKinds: [.pattern],
            required: true,
            isSingular: true
        )

        static let owner = Self(
            role: "owner",
            allowedTargetKinds: [.project, .yarn, .journalEntry, .pattern, .patternUsage],
            required: true,
            isSingular: true
        )
    }

    private static let relationshipRules: [SyncEntityKind: [RelationshipRule]] = [
        .projectCounter: [RelationshipRule.projectParent],
        .rowNote: [RelationshipRule.projectParent],
        .knittingReminder: [RelationshipRule.projectParent],
        .journalEntry: [RelationshipRule.projectParent],
        .projectYarnLink: [RelationshipRule.projectParent, RelationshipRule.yarn],
        .patternUsage: [RelationshipRule.projectParent, RelationshipRule.pattern],
        .attachment: [RelationshipRule.owner]
    ]
}
