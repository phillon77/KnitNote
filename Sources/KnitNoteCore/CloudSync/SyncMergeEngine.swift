import Foundation

public enum SyncMergeError: Error, Equatable, Sendable {
    case corruptEqualStamp(entity: SyncEntityID, field: String)
    case corruptAtomicDomain(entity: SyncEntityID, revision: UInt64)
    case corruptAttachmentVersion(UUID)
    case processedWatchCommandWouldRegress(UUID)
}

public enum SyncConflict: Codable, Equatable, Sendable {
    case corruptEqualStamp(entity: SyncEntityID, field: String)
    case counterValues(entity: SyncEntityID, revision: UInt64, values: [Int])
    case attachmentVersions(owner: SyncEntityID, role: String, ids: [SyncEntityID])
    case possibleDuplicate(ids: [SyncEntityID])
}

public struct SyncMergeResult: Equatable, Sendable {
    public let records: [SyncRecord]
    public let conflicts: [SyncConflict]
    public let recordsToUpload: Set<SyncEntityID>
    /// Exact pending operations, including immutable save payloads and delete
    /// intent. This prevents a later current-state lookup from changing what a
    /// previously committed mutation uploads.
    public let mutationsToUpload: [SyncMutation]

    public init(
        records: [SyncRecord],
        conflicts: [SyncConflict],
        recordsToUpload: Set<SyncEntityID>,
        mutationsToUpload: [SyncMutation] = []
    ) {
        self.records = records
        self.conflicts = conflicts
        self.recordsToUpload = recordsToUpload
        self.mutationsToUpload = mutationsToUpload
    }
}

public struct SyncCounterReminderMergeContext: Sendable {
    public let preparedCommands: [PreparedWatchCommand]
    public let processedLedger: ProcessedWatchCommandLedger

    public init(
        preparedCommands: [PreparedWatchCommand] = [],
        processedLedger: ProcessedWatchCommandLedger = .init()
    ) {
        self.preparedCommands = preparedCommands
        self.processedLedger = processedLedger
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
        pendingLocal: Set<SyncEntityID>,
        counterReminderContext: SyncCounterReminderMergeContext = .init()
    ) throws -> SyncMergeResult {
        try mergeRecords(
            local: Array(local),
            remote: Array(remote),
            pendingLocal: pendingLocal,
            pendingMutations: [],
            counterReminderContext: counterReminderContext
        )
    }

    public func merge(
        local: some Sequence<SyncRecord>,
        remote: some Sequence<SyncRecord>,
        pendingLocalMutations: [SyncMutation],
        counterReminderContext: SyncCounterReminderMergeContext = .init()
    ) throws -> SyncMergeResult {
        let pendingSaveRecords = pendingLocalMutations.compactMap {
            $0.savedRecordVersion?.record
        }
        return try mergeRecords(
            local: Array(local) + pendingSaveRecords,
            remote: Array(remote),
            pendingLocal: Set(pendingLocalMutations.map(\.recordID)),
            pendingMutations: pendingLocalMutations,
            counterReminderContext: counterReminderContext
        )
    }

    private func mergeRecords(
        local: [SyncRecord],
        remote: [SyncRecord],
        pendingLocal: Set<SyncEntityID>,
        pendingMutations: [SyncMutation],
        counterReminderContext: SyncCounterReminderMergeContext
    ) throws -> SyncMergeResult {
        let localGroups = try groupedRecords(local)
        let remoteGroups = try groupedRecords(remote)
        let ids = Set(localGroups.keys).union(remoteGroups.keys).sorted(by: Self.entityIDLess)
        var mergedRecords: [SyncRecord] = []
        var recordsToUpload: Set<SyncEntityID> = []
        var atomicConflicts: [SyncConflict] = []

        for id in ids {
            let candidates = (localGroups[id] ?? []) + (remoteGroups[id] ?? [])
            let merged = try merge(candidates)
            let validated = try validator.validate(merged)
            mergedRecords.append(validated)
            if let conflict = counterConflict(in: candidates, entity: id) {
                atomicConflicts.append(conflict)
            }
            let remoteRecord = try remoteGroups[id].map(merge)
            if remoteRecord != validated || pendingLocal.contains(id) {
                recordsToUpload.insert(id)
            }
        }

        mergedRecords = try validator.validate(mergedRecords)
        try validateCounterReminderContext(
            records: mergedRecords,
            context: counterReminderContext
        )

        let conflicts = atomicConflicts
            + attachmentConflicts(in: mergedRecords)
            + possibleDuplicateConflicts(in: mergedRecords)

        return SyncMergeResult(
            records: mergedRecords,
            conflicts: conflicts.sorted(by: Self.conflictLess),
            recordsToUpload: recordsToUpload,
            mutationsToUpload: pendingMutations
        )
    }

    private func groupedRecords<S: Sequence>(_ records: S) throws -> [SyncEntityID: [SyncRecord]]
    where S.Element == SyncRecord {
        var result: [SyncEntityID: [SyncRecord]] = [:]
        for candidate in records {
            // Validate the wire value before canonicalizing collections; doing
            // this in the opposite order could silently erase duplicate-parent
            // or duplicate-cascade corruption.
            let normalized = normalize(try validator.validate(candidate))
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
        let atomicDomain = try newestAtomicDomain(
            records.compactMap(\.payload.atomicDomain),
            entity: first.id
        )
        let cascades = records.compactMap(\.payload.deletionCascade)
        let newestCascade = cascades.isEmpty ? nil : try newest(
            cascades,
            entity: first.id,
            field: "deletionCascade"
        )
        let deletionCascade = newestCascade?.stamp == deletedAt.stamp
            ? newestCascade
            : nil
        let entityRevision = atomicDomain?.value.mutationRevision
            ?? (records.map(\.entityRevision).max() ?? first.entityRevision)
        let merged = SyncRecord(
            schemaVersion: records.map(\.schemaVersion).max() ?? first.schemaVersion,
            id: first.id,
            createdAt: records.map(\.createdAt).min() ?? first.createdAt,
            entityRevision: entityRevision,
            payload: SyncRecordPayload(
                fields: fields,
                deletionCascade: deletionCascade.map {
                    .init(
                        value: Self.sortedEntityIDs(Set($0.value)),
                        stamp: $0.stamp
                    )
                },
                atomicDomain: atomicDomain,
                attachment: try newestAttachment(records, entity: first.id)
            ),
            relationships: Self.sortedRelationships(records.flatMap(\.relationships)),
            deletedAt: deletedAt
        )
        return try validator.validate(merged)
    }

    private func newestAtomicDomain(
        _ versions: [SyncFieldVersion<SyncAtomicDomainValue>],
        entity: SyncEntityID
    ) throws -> SyncFieldVersion<SyncAtomicDomainValue>? {
        guard !versions.isEmpty else { return nil }
        let revision = versions.map(\.value.mutationRevision).max()!
        let candidates = versions.filter { $0.value.mutationRevision == revision }
        guard let first = candidates.first else { return nil }
        if candidates.allSatisfy({ $0.value == first.value }) {
            return candidates.max { $0.stamp < $1.stamp }
        }

        switch first.value {
        case .projectCounter:
            guard candidates.allSatisfy({
                if case .projectCounter = $0.value { return true }
                return false
            }) else {
                throw SyncMergeError.corruptAtomicDomain(entity: entity, revision: revision)
            }
            // Concurrent absolute counter assignments from one base are never
            // added. The mutation stamp chooses one complete value.
            return candidates.max { $0.stamp < $1.stamp }
        case .knittingReminder:
            guard candidates.allSatisfy({
                if case .knittingReminder = $0.value { return true }
                return false
            }) else {
                throw SyncMergeError.corruptAtomicDomain(entity: entity, revision: revision)
            }
            return candidates.max { lhs, rhs in
                let lhsKey = reminderPrecedence(lhs.value)
                let rhsKey = reminderPrecedence(rhs.value)
                if lhsKey != rhsKey { return lhsKey.lexicographicallyPrecedes(rhsKey) }
                return lhs.stamp < rhs.stamp
            }
        }
    }

    private func newestAttachment(
        _ records: [SyncRecord],
        entity: SyncEntityID
    ) throws -> SyncAttachmentVersion? {
        let attachments = records.compactMap(\.payload.attachment)
        guard let first = attachments.first else { return nil }
        guard attachments.allSatisfy({ $0 == first }) else {
            throw SyncMergeError.corruptAttachmentVersion(first.versionID)
        }
        return first
    }

    private func counterConflict(
        in records: [SyncRecord],
        entity: SyncEntityID
    ) -> SyncConflict? {
        let counters = records.compactMap { record -> ProjectCounter? in
            guard case let .projectCounter(counter)? = record.payload.atomicDomain?.value else {
                return nil
            }
            return counter
        }
        guard let revision = counters.map(\.mutationRevision).max() else { return nil }
        let values = Set(counters.lazy
            .filter { $0.mutationRevision == revision }
            .map(\.value))
            .sorted()
        guard values.count > 1 else { return nil }
        return .counterValues(entity: entity, revision: revision, values: values)
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
                deletionCascade: record.payload.deletionCascade.map {
                    .init(
                        value: Self.sortedEntityIDs(Set($0.value)),
                        stamp: $0.stamp
                    )
                },
                atomicDomain: record.payload.atomicDomain,
                attachment: record.payload.attachment
            ),
            relationships: Self.sortedRelationships(record.relationships),
            deletedAt: record.deletedAt
        )
    }

    private func attachmentConflicts(in records: [SyncRecord]) -> [SyncConflict] {
        var groups: [AttachmentSlot: [SyncEntityID]] = [:]
        for record in records where record.id.kind == .attachment && record.deletedAt.value == nil {
            guard let attachment = record.payload.attachment else { continue }
            groups[AttachmentSlot(
                owner: attachment.slot.owner,
                role: attachment.slot.role,
                slotID: attachment.slot.slotID
            ), default: []].append(record.id)
        }

        return groups.compactMap { slot, ids in
            let sortedIDs = Self.sortedEntityIDs(Set(ids))
            guard sortedIDs.count > 1 else { return nil }
            return .attachmentVersions(owner: slot.owner, role: slot.role, ids: sortedIDs)
        }
    }

    private func validateCounterReminderContext(
        records: [SyncRecord],
        context: SyncCounterReminderMergeContext
    ) throws {
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        for prepared in context.preparedCommands {
            guard let entry = context.processedLedger.entry(for: prepared.command.id),
                  entry.rejection == nil else { continue }
            switch prepared.command.operation {
            case .increment, .decrement, .reset:
                let id = SyncEntityID(kind: .projectCounter, uuid: prepared.command.counterID)
                guard let record = byID[id],
                      case let .projectCounter(counter)? = record.payload.atomicDomain?.value else {
                    throw SyncMergeError.processedWatchCommandWouldRegress(prepared.command.id)
                }
                let acceptedNoOp: Bool
                switch prepared.command.operation {
                case .increment: acceptedNoOp = prepared.expectedCounterValue == Int.max
                case .decrement, .reset: acceptedNoOp = prepared.expectedCounterValue == 0
                default: acceptedNoOp = false
                }
                let minimumRevision: UInt64
                if acceptedNoOp {
                    minimumRevision = prepared.expectedCounterRevision
                } else {
                    guard prepared.expectedCounterRevision < .max else {
                        throw SyncMergeError.processedWatchCommandWouldRegress(prepared.command.id)
                    }
                    minimumRevision = prepared.expectedCounterRevision + 1
                }
                guard counter.mutationRevision >= minimumRevision else {
                    throw SyncMergeError.processedWatchCommandWouldRegress(prepared.command.id)
                }
            case .completeReminder, .deferReminderOnce, .skipReminder:
                guard let reminderID = prepared.expectedReminderID,
                      let expectedRevision = prepared.expectedReminderRevision,
                      let record = byID[.init(kind: .knittingReminder, uuid: reminderID)],
                      case let .knittingReminder(reminder)? = record.payload.atomicDomain?.value,
                      reminder.mutationRevision > expectedRevision else {
                    throw SyncMergeError.processedWatchCommandWouldRegress(prepared.command.id)
                }
            case .stopReminder:
                throw SyncMergeError.processedWatchCommandWouldRegress(prepared.command.id)
            }
        }
    }

    private func reminderPrecedence(_ value: SyncAtomicDomainValue) -> [UInt64] {
        guard case let .knittingReminder(reminder) = value else { return [] }
        let terminal = UInt64(reminder.progress.completedCount)
            + UInt64(reminder.progress.skippedCount)
        let deferred = UInt64(reminder.progress.pending.filter { $0.phase == .deferredOnce }.count)
        let released = UInt64(reminder.progress.pending.filter {
            $0.phase == .deferredOnce && !$0.awaitsNextUpwardChange
        }.count)
        return [
            terminal,
            reminder.progress.latestHandled == nil ? 0 : 1,
            UInt64(reminder.progress.skippedCount),
            UInt64(reminder.progress.completedCount),
            released,
            deferred,
            reminder.state == .active ? 0 : 1
        ]
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
        case let .counterValues(entity, revision, values):
            return "1|\(entity.kind.rawValue)|\(entity.uuid.uuidString)|\(revision)|\(values.map(String.init).joined(separator: ","))"
        case let .attachmentVersions(owner, role, ids):
            return "2|\(owner.kind.rawValue)|\(owner.uuid.uuidString)|\(role)|\(ids.map { $0.uuid.uuidString }.joined(separator: ","))"
        case let .possibleDuplicate(ids):
            return "3|\(ids.map { "\($0.kind.rawValue):\($0.uuid.uuidString)" }.joined(separator: ","))"
        }
    }
}

private struct AttachmentSlot: Hashable {
    let owner: SyncEntityID
    let role: String
    let slotID: String
}

private struct DuplicateKey: Hashable {
    let kind: SyncEntityKind
    let normalizedName: String
}
