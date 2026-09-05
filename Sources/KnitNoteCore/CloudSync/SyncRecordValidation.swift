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
    case cyclicAttachmentReplacement(UUID)
}

struct SyncAttachmentLineage: Sendable {
    let recordsByVersionID: [UUID: SyncRecord]
    let headsBySlot: [SyncAttachmentSlot: [SyncRecord]]

    init(records: [SyncRecord]) throws {
        var recordsByVersionID: [UUID: SyncRecord] = [:]
        var immutableSnapshotSHA256ByVersionID: [UUID: Data] = [:]
        for record in records {
            guard let attachment = record.payload.attachment else { continue }
            let snapshotSHA256 = try SyncAttachmentImmutableSnapshot(record: record).sha256
            if let existingSHA256 = immutableSnapshotSHA256ByVersionID[attachment.versionID],
               existingSHA256 != snapshotSHA256 {
                throw SyncRecordValidationError.corruptAttachmentVersion(attachment.versionID)
            }
            immutableSnapshotSHA256ByVersionID[attachment.versionID] = snapshotSHA256
            recordsByVersionID[attachment.versionID] = record
        }

        for record in recordsByVersionID.values {
            guard let attachment = record.payload.attachment,
                  let parentID = attachment.replacesVersionID,
                  let parent = recordsByVersionID[parentID]?.payload.attachment else { continue }
            guard parent.slot == attachment.slot else {
                throw SyncRecordValidationError.crossSlotAttachmentReplacement(
                    attachment.versionID
                )
            }
        }

        var completelyVisited: Set<UUID> = []
        for start in recordsByVersionID.keys.sorted(by: Self.uuidLess) {
            guard !completelyVisited.contains(start) else { continue }
            var path: [UUID] = []
            var pathOffsets: [UUID: Int] = [:]
            var cursor: UUID? = start
            while let id = cursor, let record = recordsByVersionID[id],
                  let attachment = record.payload.attachment {
                if let offset = pathOffsets[id] {
                    let cycle = path[offset...]
                    let canonical = cycle.min(by: Self.uuidLess) ?? id
                    throw SyncRecordValidationError.cyclicAttachmentReplacement(canonical)
                }
                if completelyVisited.contains(id) { break }
                pathOffsets[id] = path.count
                path.append(id)
                cursor = attachment.replacesVersionID
            }
            completelyVisited.formUnion(path)
        }

        let replacedIDs = Set(recordsByVersionID.values.compactMap {
            $0.payload.attachment?.replacesVersionID
        })
        var headsBySlot: [SyncAttachmentSlot: [SyncRecord]] = [:]
        for (versionID, record) in recordsByVersionID where !replacedIDs.contains(versionID) {
            guard let slot = record.payload.attachment?.slot else { continue }
            headsBySlot[slot, default: []].append(record)
        }
        self.recordsByVersionID = recordsByVersionID
        self.headsBySlot = headsBySlot.mapValues { records in
            records.sorted(by: Self.recordLess)
        }
    }

    func resolvedLiveVersionIDs() -> [SyncAttachmentSlot: UUID] {
        resolvedHeadsBySlot().compactMapValues { winner in
            guard winner.deletedAt.value == nil else { return nil }
            return winner.id.uuid
        }
    }

    /// Includes tombstone winners so a later issuance can retain its exact
    /// predecessor while all concurrent immutable heads remain in history.
    func resolvedHeadsBySlot() -> [SyncAttachmentSlot: SyncRecord] {
        headsBySlot.compactMapValues { $0.max(by: Self.recordLess) }
    }

    private static func recordLess(_ lhs: SyncRecord, _ rhs: SyncRecord) -> Bool {
        if lhs.deletedAt.stamp != rhs.deletedAt.stamp {
            return lhs.deletedAt.stamp < rhs.deletedAt.stamp
        }
        return uuidLess(lhs.id.uuid, rhs.id.uuid)
    }

    private static func uuidLess(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }
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
        if record.id.kind == .deletionMarker { _ = try DeletionMarker(record: record) }
        return record
    }

    /// Applies the historical standalone-reminder rules only while loading an
    /// already-durable mutation journal. Canonical validation and publication
    /// continue to reject this record kind as a live synchronization authority.
    @discardableResult
    func validateLegacyStandaloneReminderForMigration(
        _ record: SyncRecord
    ) throws -> SyncRecord {
        guard record.schemaVersion == currentSchemaVersion else {
            throw SyncRecordValidationError.unsupportedSchema(record.schemaVersion)
        }
        try validateScalars(in: record)
        try validateRelationships(in: record)
        try validateRelatedDeletions(in: record)
        try validateAttachment(in: record)
        guard record.id.kind == .knittingReminder,
              case let .knittingReminder(reminder)? = record.payload.atomicDomain?.value,
              reminder.id == record.id.uuid,
              reminder.mutationRevision == record.entityRevision,
              record.payload.atomicDomain?.stamp.logicalRevision == record.entityRevision,
              record.relationships.contains(where: {
                  $0.role == "counter"
                      && $0.target == SyncEntityID(
                          kind: .projectCounter,
                          uuid: reminder.counterID
                      )
              }) else {
            throw SyncRecordValidationError.illegalAtomicDomain(record.id)
        }
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
        _ = try SyncAttachmentLineage(records: records)
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
        case let (.projectCounter, .projectCounter(state)):
            let reminderIDs = Set(state.reminders.map(\.id))
            guard state.counter.id == record.id.uuid,
                  record.payload.atomicDomain?.stamp.logicalRevision == record.entityRevision,
                  state.counter.mutationRevision <= record.entityRevision,
                  reminderIDs.count == state.reminders.count,
                  state.reminders.allSatisfy({ $0.counterID == state.counter.id }),
                  Set(state.processedCommandProofs.map(\.id)).count
                    == state.processedCommandProofs.count,
                  Set(state.processedCommandProofs.map(\.id))
                    .isSubset(of: state.processedCommandIDs),
                  state.processedCommandProofs.allSatisfy({ proof in
                      proof.counterID == state.counter.id
                          && (try? proof.validated()) != nil
                          && SyncCounterReminderMergePolicy().processedCommandIsProven(
                              proof.id,
                              in: state,
                              context: .init()
                          )
                  }),
                  state.occurrence.map({ occurrence in
                      state.reminders.contains {
                          $0.progress.nextOccurrenceIndex == occurrence
                      }
                  }) ?? true,
                  preparedCommandIsAligned(state.preparedCommand, with: state) else {
                throw SyncRecordValidationError.illegalAtomicDomain(record.id)
            }
            guard state.reminders.allSatisfy({
                $0.mutationRevision <= record.entityRevision
            }) else {
                throw SyncRecordValidationError.illegalAtomicDomain(record.id)
            }
        case (.knittingReminder, .knittingReminder):
            throw SyncRecordValidationError.illegalAtomicDomain(record.id)
        case let (.watchCommandProof, .orphanWatchCommandProof(orphan)):
            guard record.id.uuid == orphan.proof.id,
                  record.payload.atomicDomain?.stamp.logicalRevision == record.entityRevision,
                  (try? SyncOrphanWatchCommandProof(proof: orphan.proof)) == orphan else {
                throw SyncRecordValidationError.illegalAtomicDomain(record.id)
            }
        case (.projectCounter, nil), (.knittingReminder, nil):
            throw SyncRecordValidationError.missingAtomicDomain(record.id)
        case (.projectCounter, _), (.knittingReminder, _), (.watchCommandProof, _):
            throw SyncRecordValidationError.illegalAtomicDomain(record.id)
        case (_, nil):
            break
        case (_, _):
            throw SyncRecordValidationError.illegalAtomicDomain(record.id)
        }
    }

    private func preparedCommandIsAligned(
        _ prepared: PreparedWatchCommand?,
        with state: SyncCounterReminderState
    ) -> Bool {
        guard let prepared else { return true }
        guard prepared.command.counterID == state.counter.id,
              prepared.expectedCounterRevision <= state.counter.mutationRevision else {
            return false
        }
        if prepared.expectedCounterRevision == state.counter.mutationRevision,
           let expectedValue = prepared.expectedCounterValue,
           expectedValue != state.counter.value {
            return false
        }
        switch prepared.command.operation {
        case .increment, .decrement, .reset:
            return prepared.expectedReminderID == nil
                && prepared.expectedOccurrenceID == nil
                && prepared.expectedReminderRevision == nil
        case .completeReminder, .deferReminderOnce, .skipReminder, .stopReminder:
            guard let expectedReminderID = prepared.expectedReminderID,
                  let reminder = state.reminders.first(where: {
                      $0.id == expectedReminderID
                  }),
                  prepared.expectedReminderRevision.map({ $0 <= reminder.mutationRevision }) == true
            else {
                return false
            }
            if let expectedOccurrenceID = prepared.expectedOccurrenceID {
                return reminder.progress.pending.contains { $0.id == expectedOccurrenceID }
                    || reminder.progress.latestHandled?.id == expectedOccurrenceID
                    || reminder.state != .active
            }
            return true
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
