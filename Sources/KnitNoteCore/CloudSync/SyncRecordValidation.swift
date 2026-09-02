import Foundation

public enum SyncRecordValidationError: Error, Equatable, Sendable {
    case duplicateRecord(SyncEntityID)
    case unsupportedSchema(Int)
    case missingRequiredRelationship(SyncEntityID, String)
    case duplicateSingularRelationship(SyncEntityID, String)
    case unsupportedRelationshipRole(SyncEntityID, String)
    case illegalRelationshipKind(SyncEntityID, String, SyncEntityKind)
    case scalarValueTooLarge(String, Int)
    case illegalRelatedDeletion(SyncEntityID, SyncEntityID)
    case deletionCascadeStampMismatch(SyncEntityID)
    case liveRecordHasDeletionCascade(SyncEntityID)
    case duplicateRelatedDeletion(SyncEntityID, SyncEntityID)
    case unownedRelatedDeletion(SyncEntityID, SyncEntityID)
    case missingAtomicDomain(SyncEntityID)
    case illegalAtomicDomain(SyncEntityID)
    case invalidAttachment(SyncEntityID)
    case corruptAttachmentVersion(UUID)
    case crossSlotAttachmentReplacement(UUID)
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
        try validateAtomicDomain(in: record)
        try validateAttachment(in: record)
        return record
    }

    /// Validates relationship ownership once all records in a merge batch are
    /// available. Missing or unrelated cascade targets are staged/rejected by
    /// callers instead of being interpreted as authority to delete them.
    @discardableResult
    public func validate(_ records: [SyncRecord]) throws -> [SyncRecord] {
        let validated = try records.map(validate)
        try validateAttachmentVersions(in: validated)
        var byID: [SyncEntityID: SyncRecord] = [:]
        for record in validated {
            guard byID.updateValue(record, forKey: record.id) == nil else {
                throw SyncRecordValidationError.duplicateRecord(record.id)
            }
        }
        for owner in validated {
            for targetID in owner.payload.deletionCascade?.value ?? [] {
                guard isOwned(targetID, by: owner.id, records: byID) else {
                    throw SyncRecordValidationError.unownedRelatedDeletion(owner.id, targetID)
                }
            }
        }
        return validated
    }

    private func validateAttachmentVersions(in records: [SyncRecord]) throws {
        var versions: [UUID: SyncAttachmentVersion] = [:]
        for record in records {
            guard let attachment = record.payload.attachment else { continue }
            if let existing = versions[attachment.versionID], existing != attachment {
                throw SyncRecordValidationError.corruptAttachmentVersion(attachment.versionID)
            }
            versions[attachment.versionID] = attachment
        }
        for attachment in versions.values {
            guard let replaced = attachment.replacesVersionID,
                  let prior = versions[replaced],
                  prior.slot != attachment.slot else {
                continue
            }
            throw SyncRecordValidationError.crossSlotAttachmentReplacement(attachment.versionID)
        }
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
        let rules = Self.relationshipRules[record.id.kind] ?? []

        for relationship in record.relationships {
            guard let rule = rules.first(where: { $0.role == relationship.role }) else {
                throw SyncRecordValidationError.unsupportedRelationshipRole(record.id, relationship.role)
            }
            guard rule.allowedTargetKinds.contains(relationship.target.kind) else {
                throw SyncRecordValidationError.illegalRelationshipKind(
                    record.id,
                    rule.role,
                    relationship.target.kind
                )
            }
        }

        for rule in rules {
            let relationships = record.relationships.filter { $0.role == rule.role }
            if rule.required, relationships.isEmpty {
                throw SyncRecordValidationError.missingRequiredRelationship(record.id, rule.role)
            }
            if rule.isSingular, relationships.count > 1 {
                throw SyncRecordValidationError.duplicateSingularRelationship(record.id, rule.role)
            }
        }
    }

    private func validateRelatedDeletions(in record: SyncRecord) throws {
        guard let cascade = record.payload.deletionCascade else { return }
        let allowedKinds = Self.allowedRelatedDeletionKinds[record.id.kind] ?? []
        var seen: Set<SyncEntityID> = []
        for targetID in cascade.value {
            guard seen.insert(targetID).inserted else {
                throw SyncRecordValidationError.duplicateRelatedDeletion(record.id, targetID)
            }
            guard allowedKinds.contains(targetID.kind), targetID != record.id else {
                throw SyncRecordValidationError.illegalRelatedDeletion(record.id, targetID)
            }
        }
        guard cascade.stamp == record.deletedAt.stamp else {
            throw SyncRecordValidationError.deletionCascadeStampMismatch(record.id)
        }
        if record.deletedAt.value == nil, !cascade.value.isEmpty {
            throw SyncRecordValidationError.liveRecordHasDeletionCascade(record.id)
        }
    }

    private func validateAtomicDomain(in record: SyncRecord) throws {
        switch (record.id.kind, record.payload.atomicDomain?.value) {
        case let (.projectCounter, .projectCounter(counter)):
            guard counter.id == record.id.uuid,
                  counter.mutationRevision == record.entityRevision,
                  record.payload.atomicDomain?.stamp.logicalRevision == counter.mutationRevision else {
                throw SyncRecordValidationError.illegalAtomicDomain(record.id)
            }
        case let (.knittingReminder, .knittingReminder(reminder)):
            guard reminder.id == record.id.uuid,
                  reminder.mutationRevision == record.entityRevision,
                  record.payload.atomicDomain?.stamp.logicalRevision == reminder.mutationRevision,
                  record.relationships.contains(where: {
                      $0.role == "counter"
                          && $0.target == SyncEntityID(
                              kind: .projectCounter,
                              uuid: reminder.counterID
                          )
                  }) else {
                throw SyncRecordValidationError.illegalAtomicDomain(record.id)
            }
        case (.projectCounter, nil), (.knittingReminder, nil):
            throw SyncRecordValidationError.missingAtomicDomain(record.id)
        case (.projectCounter, _), (.knittingReminder, _):
            throw SyncRecordValidationError.illegalAtomicDomain(record.id)
        case (_, nil):
            break
        case (_, _):
            throw SyncRecordValidationError.illegalAtomicDomain(record.id)
        }
    }

    private func validateAttachment(in record: SyncRecord) throws {
        guard record.id.kind == .attachment else {
            guard record.payload.attachment == nil else {
                throw SyncRecordValidationError.invalidAttachment(record.id)
            }
            return
        }
        guard let attachment = try? record.payload.attachment?.validated(),
              record.id.uuid == attachment.versionID,
              record.relationships.contains(where: {
                  $0.role == "owner" && $0.target == attachment.slot.owner
              }) else {
            throw SyncRecordValidationError.invalidAttachment(record.id)
        }
    }

    private func isOwned(
        _ targetID: SyncEntityID,
        by ownerID: SyncEntityID,
        records: [SyncEntityID: SyncRecord]
    ) -> Bool {
        var pending = [targetID]
        var visited: Set<SyncEntityID> = []
        while let candidate = pending.popLast() {
            if candidate == ownerID { return true }
            guard visited.insert(candidate).inserted,
                  let record = records[candidate] else { continue }
            pending.append(contentsOf: record.relationships.compactMap { relationship in
                switch relationship.role {
                case "project", "owner", "pattern", "yarn": relationship.target
                default: nil
                }
            })
        }
        return false
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

        static let counter = Self(
            role: "counter",
            allowedTargetKinds: [.projectCounter],
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
        .knittingReminder: [RelationshipRule.projectParent, RelationshipRule.counter],
        .journalEntry: [RelationshipRule.projectParent],
        .projectYarnLink: [RelationshipRule.projectParent, RelationshipRule.yarn],
        .patternUsage: [RelationshipRule.projectParent, RelationshipRule.pattern],
        .attachment: [RelationshipRule.owner]
    ]

    private static let allowedRelatedDeletionKinds: [SyncEntityKind: Set<SyncEntityKind>] = [
        .project: [
            .projectCounter, .rowNote, .knittingReminder, .journalEntry,
            .projectYarnLink, .patternUsage, .attachment
        ],
        .journalEntry: [.attachment],
        .yarn: [.attachment],
        .pattern: [.attachment],
        .patternUsage: [.attachment]
    ]
}
