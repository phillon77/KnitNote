import Foundation

public enum SyncMergeError: Error, Equatable, Sendable {
    case corruptEqualStamp(entity: SyncEntityID, field: String)
}

public enum SyncConflict: Codable, Equatable, Sendable {
    case corruptEqualStamp(entity: SyncEntityID, field: String)
    case attachmentVersions(owner: SyncEntityID, role: String, ids: [SyncEntityID])
    case possibleDuplicate(ids: [SyncEntityID])
}

public struct SyncMergeResult: Equatable, Sendable {
    public let records: [SyncRecord]
    public let conflicts: [SyncConflict]
    public let recordsToUpload: Set<SyncEntityID>

    public init(
        records: [SyncRecord],
        conflicts: [SyncConflict],
        recordsToUpload: Set<SyncEntityID>
    ) {
        self.records = records
        self.conflicts = conflicts
        self.recordsToUpload = recordsToUpload
    }
}

public struct SyncMergeEngine: Sendable {
    private let validator: SyncRecordValidator

    public init(validator: SyncRecordValidator = SyncRecordValidator()) {
        self.validator = validator
    }

    public func merge(
        local: some Sequence<SyncRecord>,
        remote: some Sequence<SyncRecord>,
        pendingLocal: Set<SyncEntityID>
    ) throws -> SyncMergeResult {
        let localGroups = try groupedRecords(local)
        let remoteGroups = try groupedRecords(remote)
        let ids = Set(localGroups.keys).union(remoteGroups.keys).sorted(by: Self.entityIDLess)
        var mergedRecords: [SyncRecord] = []
        var recordsToUpload: Set<SyncEntityID> = []

        for id in ids {
            let merged = try merge((localGroups[id] ?? []) + (remoteGroups[id] ?? []))
            let validated = try validator.validate(merged)
            mergedRecords.append(validated)
            let remoteRecord = try remoteGroups[id].map(merge)
            if remoteRecord != validated || pendingLocal.contains(id) {
                recordsToUpload.insert(id)
            }
        }

        let conflicts = attachmentConflicts(in: mergedRecords)
            + possibleDuplicateConflicts(in: mergedRecords)

        return SyncMergeResult(
            records: mergedRecords,
            conflicts: conflicts.sorted(by: Self.conflictLess),
            recordsToUpload: recordsToUpload
        )
    }

    private func groupedRecords<S: Sequence>(_ records: S) throws -> [SyncEntityID: [SyncRecord]]
    where S.Element == SyncRecord {
        var result: [SyncEntityID: [SyncRecord]] = [:]
        for candidate in records {
            let normalized = try validator.validate(normalize(candidate))
            result[normalized.id, default: []].append(normalized)
        }
        return result
    }

    private func merge(_ records: [SyncRecord]) throws -> SyncRecord {
        precondition(!records.isEmpty)
        let first = records[0]
        precondition(records.allSatisfy { $0.id == first.id })
        let fieldNames = Set(records.flatMap { $0.payload.fields.keys }).sorted()
        var fields: [String: SyncFieldVersion<SyncScalar>] = [:]

        for field in fieldNames {
            fields[field] = try newest(
                records.compactMap { $0.payload.fields[field] },
                entity: first.id,
                field: field
            )
        }

        let deletedAt = try newest(
            records.map(\.deletedAt),
            entity: first.id,
            field: "deletedAt"
        )
        let merged = SyncRecord(
            schemaVersion: records.map(\.schemaVersion).max() ?? first.schemaVersion,
            id: first.id,
            createdAt: records.map(\.createdAt).min() ?? first.createdAt,
            entityRevision: records.map(\.entityRevision).max() ?? first.entityRevision,
            payload: SyncRecordPayload(
                fields: fields,
                deletedRelatedEntityIDs: Self.sortedEntityIDs(
                    Set(records.flatMap { $0.payload.deletedRelatedEntityIDs })
                )
            ),
            relationships: Self.sortedRelationships(records.flatMap(\.relationships)),
            deletedAt: deletedAt
        )
        return try validator.validate(merged)
    }

    private func newest<Value: Codable & Equatable & Sendable>(
        _ versions: [SyncFieldVersion<Value>],
        entity: SyncEntityID,
        field: String
    ) throws -> SyncFieldVersion<Value> {
        precondition(!versions.isEmpty)
        var valuesByStamp: [SyncMutationStamp: Value] = [:]
        for version in versions {
            if let existingValue = valuesByStamp[version.stamp], existingValue != version.value {
                throw SyncMergeError.corruptEqualStamp(entity: entity, field: field)
            }
            valuesByStamp[version.stamp] = version.value
        }
        return versions.max { $0.stamp < $1.stamp } ?? versions[0]
    }

    private func normalize(_ record: SyncRecord) -> SyncRecord {
        SyncRecord(
            schemaVersion: record.schemaVersion,
            id: record.id,
            createdAt: record.createdAt,
            entityRevision: record.entityRevision,
            payload: SyncRecordPayload(
                fields: record.payload.fields,
                deletedRelatedEntityIDs: Self.sortedEntityIDs(Set(record.payload.deletedRelatedEntityIDs))
            ),
            relationships: Self.sortedRelationships(record.relationships),
            deletedAt: record.deletedAt
        )
    }

    private func attachmentConflicts(in records: [SyncRecord]) -> [SyncConflict] {
        var groups: [AttachmentSlot: [SyncEntityID]] = [:]
        for record in records where record.id.kind == .attachment && record.deletedAt.value == nil {
            guard
                let owner = record.relationships.first(where: { $0.role == "owner" })?.target,
                let role = attachmentRole(in: record)
            else { continue }
            groups[AttachmentSlot(owner: owner, role: role), default: []].append(record.id)
        }

        return groups.compactMap { slot, ids in
            let sortedIDs = Self.sortedEntityIDs(Set(ids))
            guard sortedIDs.count > 1 else { return nil }
            return .attachmentVersions(owner: slot.owner, role: slot.role, ids: sortedIDs)
        }
    }

    private func possibleDuplicateConflicts(in records: [SyncRecord]) -> [SyncConflict] {
        var groups: [DuplicateKey: [SyncEntityID]] = [:]
        for record in records where record.deletedAt.value == nil {
            guard let name = recordName(in: record) else { continue }
            groups[DuplicateKey(kind: record.id.kind, normalizedName: name), default: []].append(record.id)
        }

        return groups.compactMap { _, ids in
            let sortedIDs = Self.sortedEntityIDs(Set(ids))
            guard sortedIDs.count > 1 else { return nil }
            return .possibleDuplicate(ids: sortedIDs)
        }
    }

    private func attachmentRole(in record: SyncRecord) -> String? {
        for field in ["role", "semanticRole", "attachmentRole"] {
            if case let .string(role)? = record.payload.fields[field]?.value, !role.isEmpty {
                return role
            }
        }
        return nil
    }

    private func recordName(in record: SyncRecord) -> String? {
        for field in ["name", "displayName"] {
            if case let .string(value)? = record.payload.fields[field]?.value {
                let normalized = value
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .folding(
                        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                        locale: Locale(identifier: "en_US_POSIX")
                    )
                if !normalized.isEmpty { return normalized }
            }
        }
        return nil
    }

    private static func sortedRelationships(_ relationships: [SyncRelationship]) -> [SyncRelationship] {
        var unique: [SyncRelationship] = []
        for relationship in relationships where !unique.contains(relationship) {
            unique.append(relationship)
        }
        return unique.sorted {
            if $0.role != $1.role { return $0.role < $1.role }
            return entityIDLess($0.target, $1.target)
        }
    }

    private static func sortedEntityIDs(_ ids: Set<SyncEntityID>) -> [SyncEntityID] {
        ids.sorted(by: entityIDLess)
    }

    private static func entityIDLess(_ lhs: SyncEntityID, _ rhs: SyncEntityID) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.uuid.uuidString < rhs.uuid.uuidString
    }

    private static func conflictLess(_ lhs: SyncConflict, _ rhs: SyncConflict) -> Bool {
        conflictKey(lhs) < conflictKey(rhs)
    }

    private static func conflictKey(_ conflict: SyncConflict) -> String {
        switch conflict {
        case let .corruptEqualStamp(entity, field):
            return "0|\(entity.kind.rawValue)|\(entity.uuid.uuidString)|\(field)"
        case let .attachmentVersions(owner, role, ids):
            return "1|\(owner.kind.rawValue)|\(owner.uuid.uuidString)|\(role)|\(ids.map { $0.uuid.uuidString }.joined(separator: ","))"
        case let .possibleDuplicate(ids):
            return "2|\(ids.map { "\($0.kind.rawValue):\($0.uuid.uuidString)" }.joined(separator: ","))"
        }
    }
}

private struct AttachmentSlot: Hashable {
    let owner: SyncEntityID
    let role: String
}

private struct DuplicateKey: Hashable {
    let kind: SyncEntityKind
    let normalizedName: String
}
