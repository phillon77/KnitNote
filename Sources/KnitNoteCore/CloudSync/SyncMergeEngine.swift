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

public struct SyncCounterReminderMergePolicy: Sendable {
    public init() {}

    public func merge(
        _ lhs: SyncFieldVersion<SyncCounterReminderState>,
        _ rhs: SyncFieldVersion<SyncCounterReminderState>,
        context: SyncCounterReminderMergeContext
    ) throws -> SyncFieldVersion<SyncCounterReminderState> {
        if lhs.stamp == rhs.stamp {
            guard lhs.value == rhs.value else {
                throw SyncMergeError.corruptEqualStamp(
                    entity: .init(kind: .projectCounter, uuid: lhs.value.counter.id),
                    field: "counterReminderState"
                )
            }
            return lhs
        }

        var winner = lhs.stamp < rhs.stamp ? rhs : lhs
        let older = lhs.stamp < rhs.stamp ? lhs : rhs
        guard winner.value.counter.id == older.value.counter.id,
              winner.value.counter.mutationRevision >= older.value.counter.mutationRevision,
              !reminderRevisionRegressed(from: older.value, to: winner.value) else {
            throw SyncMergeError.corruptAtomicDomain(
                entity: .init(kind: .projectCounter, uuid: winner.value.counter.id),
                revision: winner.value.counter.mutationRevision
            )
        }

        if let prepared = winner.value.preparedCommand,
           prepared.command.operation == .stopReminder,
           context.processedLedger.contains(prepared.command.id) {
            let outcome = try applyingStop(
                prepared,
                to: winner.value,
                processedLedger: context.processedLedger
            )
            winner = .init(value: outcome.state, stamp: winner.stamp)
        }

        var mergedIDs = winner.value.processedCommandIDs
        for commandID in older.value.processedCommandIDs.subtracting(mergedIDs) {
            guard let entry = context.processedLedger.entry(for: commandID) else {
                throw SyncMergeError.processedWatchCommandWouldRegress(commandID)
            }
            if entry.rejection == nil {
                guard let prepared = entry.preparedCommand
                    ?? context.preparedCommands.first(where: { $0.command.id == commandID }),
                    commandIsReflected(prepared, in: winner.value) else {
                    throw SyncMergeError.processedWatchCommandWouldRegress(commandID)
                }
            }
            mergedIDs.insert(commandID)
        }
        guard mergedIDs != winner.value.processedCommandIDs else { return winner }
        return .init(
            value: replacingProcessedIDs(in: winner.value, with: mergedIDs),
            stamp: winner.stamp
        )
    }

    public func applyingStop(
        _ prepared: PreparedWatchCommand,
        to state: SyncCounterReminderState,
        processedLedger: ProcessedWatchCommandLedger
    ) throws -> SyncReminderStopOutcome {
        guard prepared.command.operation == .stopReminder,
              let entry = processedLedger.entry(for: prepared.command.id),
              entry.rejection == nil,
              prepared.command.counterID == state.counter.id,
              let expectedReminderID = prepared.expectedReminderID,
              let expectedRevision = prepared.expectedReminderRevision,
              let reminder = state.reminders.first(where: {
                  $0.id == expectedReminderID
              }) else {
            throw SyncMergeError.processedWatchCommandWouldRegress(prepared.command.id)
        }

        let processedIDs = state.processedCommandIDs.union([prepared.command.id])
        if reminder.state == .stopped {
            return .noOp(replacing(
                state,
                reminders: state.reminders,
                processedCommandIDs: processedIDs
            ))
        }
        guard reminder.mutationRevision == expectedRevision else {
            throw SyncMergeError.processedWatchCommandWouldRegress(prepared.command.id)
        }
        if let expectedOccurrenceID = prepared.expectedOccurrenceID,
           !reminder.progress.pending.contains(where: { $0.id == expectedOccurrenceID }) {
            throw SyncMergeError.processedWatchCommandWouldRegress(prepared.command.id)
        }
        let stopped: KnittingReminder
        do {
            stopped = try reminder.applying(.stop(observedRevision: expectedRevision))
        } catch {
            throw SyncMergeError.processedWatchCommandWouldRegress(prepared.command.id)
        }
        return .persisted(replacing(
            state,
            reminders: state.reminders.map {
                $0.id == stopped.id ? stopped : $0
            },
            processedCommandIDs: processedIDs
        ))
    }

    private func reminderRevisionRegressed(
        from older: SyncCounterReminderState,
        to newer: SyncCounterReminderState
    ) -> Bool {
        let newerByID = Dictionary(uniqueKeysWithValues: newer.reminders.map {
            ($0.id, $0)
        })
        for olderReminder in older.reminders {
            guard let newerReminder = newerByID[olderReminder.id] else {
                continue
            }
            if newerReminder.mutationRevision < olderReminder.mutationRevision {
                return true
            }
        }
        return false
    }

    func commandIsReflected(
        _ prepared: PreparedWatchCommand,
        in state: SyncCounterReminderState
    ) -> Bool {
        guard prepared.command.counterID == state.counter.id else { return false }
        switch prepared.command.operation {
        case .increment, .decrement, .reset:
            guard let value = prepared.expectedCounterValue else { return false }
            let expected: (value: Int, revision: UInt64)
            let (nextRevision, revisionOverflow) =
                prepared.expectedCounterRevision.addingReportingOverflow(1)
            switch prepared.command.operation {
            case .increment where value == .max:
                expected = (value, prepared.expectedCounterRevision)
            case .increment:
                guard !revisionOverflow else { return false }
                expected = (value + 1, nextRevision)
            case .decrement where value == 0, .reset where value == 0:
                expected = (value, prepared.expectedCounterRevision)
            case .decrement:
                guard !revisionOverflow else { return false }
                expected = (value - 1, nextRevision)
            case .reset:
                guard !revisionOverflow else { return false }
                expected = (0, nextRevision)
            default:
                return false
            }
            return state.counter.value == expected.value
                && state.counter.mutationRevision == expected.revision
        case .completeReminder, .deferReminderOnce, .skipReminder:
            guard let expectedReminderID = prepared.expectedReminderID,
                  let reminder = state.reminders.first(where: {
                      $0.id == expectedReminderID
                  }),
                  let occurrenceID = prepared.expectedOccurrenceID,
                  let expectedRevision = prepared.expectedReminderRevision,
                  let outcome = prepared.expectedReminderOutcome,
                  expectedRevision != .max,
                  reminder.mutationRevision == expectedRevision + 1 else {
                return false
            }
            guard reminder.progress.completedCount == outcome.completedCount,
                  reminder.progress.skippedCount == outcome.skippedCount else { return false }
            switch prepared.command.operation {
            case .completeReminder:
                return outcome.action == .complete
                    && reminder.progress.latestHandled?.id == occurrenceID
            case .skipReminder:
                return outcome.action == .skip
                    && reminder.progress.latestHandled?.id == occurrenceID
            case .deferReminderOnce:
                return outcome.action == .deferOnce
                    && reminder.progress.pending.contains {
                        $0.id == occurrenceID && $0.phase == .deferredOnce
                            && $0.awaitsNextUpwardChange
                            && $0.displayAt == outcome.deferredDisplayAt
                    }
            default:
                return false
            }
        case .stopReminder:
            guard let revision = prepared.expectedReminderRevision,
                  let occurrenceID = prepared.expectedOccurrenceID,
                  revision != .max else {
                return false
            }
            return state.reminders.contains {
                $0.id == prepared.expectedReminderID && $0.state == .stopped
                    && $0.mutationRevision == revision + 1
                    && !$0.progress.pending.contains { $0.id == occurrenceID }
            }
        }
    }

    private func replacingProcessedIDs(
        in state: SyncCounterReminderState,
        with ids: Set<UUID>
    ) -> SyncCounterReminderState {
        replacing(state, reminders: state.reminders, processedCommandIDs: ids)
    }

    private func replacing(
        _ state: SyncCounterReminderState,
        reminders: [KnittingReminder],
        processedCommandIDs: Set<UUID>
    ) -> SyncCounterReminderState {
        SyncCounterReminderState(
            counter: state.counter,
            reminders: reminders,
            preparedCommand: state.preparedCommand,
            processedCommandIDs: processedCommandIDs,
            occurrence: state.occurrence
        )
    }
}

public struct SyncMergeEngine: Sendable {
    private let validator: SyncRecordValidator
    private let counterReminderPolicy: SyncCounterReminderMergePolicy

    public init(
        validator: SyncRecordValidator = SyncRecordValidator(),
        counterReminderPolicy: SyncCounterReminderMergePolicy = .init()
    ) {
        self.validator = validator
        self.counterReminderPolicy = counterReminderPolicy
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
        let fallback = local + remote
        let (canonicalLocal, migratedLocalCounterIDs) = try migrateLegacyReminders(
            in: local, counterFallback: fallback
        )
        let (canonicalRemote, migratedRemoteCounterIDs) = try migrateLegacyReminders(
            in: remote, counterFallback: fallback
        )
        let localGroups = try groupedRecords(canonicalLocal)
        let remoteGroups = try groupedRecords(canonicalRemote)
        let ids = Set(localGroups.keys).union(remoteGroups.keys).sorted(by: Self.entityIDLess)
        var mergedRecords: [SyncRecord] = []
        var recordsToUpload: Set<SyncEntityID> = []
        var atomicConflicts: [SyncConflict] = []

        for id in ids {
            let candidates = (localGroups[id] ?? []) + (remoteGroups[id] ?? [])
            let merged = try merge(candidates, counterReminderContext: counterReminderContext)
            let validated = try validator.validate(merged)
            mergedRecords.append(validated)
            if let conflict = counterConflict(in: candidates, entity: id) {
                atomicConflicts.append(conflict)
            }
            let remoteRecord = try remoteGroups[id].map {
                try merge($0, counterReminderContext: counterReminderContext)
            }
            if remoteRecord != validated || pendingLocal.contains(id)
                || migratedLocalCounterIDs.contains(id)
                || migratedRemoteCounterIDs.contains(id) {
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
            mutationsToUpload: pendingMutations.filter {
                $0.recordID.kind != .knittingReminder
            }
        )
    }

    private func migrateLegacyReminders(
        in records: [SyncRecord],
        counterFallback: [SyncRecord]
    ) throws -> ([SyncRecord], Set<SyncEntityID>) {
        var canonical = records.filter { $0.id.kind != .knittingReminder }
        var migratedCounterIDs: Set<SyncEntityID> = []
        let legacy = records.filter { $0.id.kind == .knittingReminder }.sorted {
            let lhs = $0.payload.atomicDomain?.stamp ?? $0.deletedAt.stamp
            let rhs = $1.payload.atomicDomain?.stamp ?? $1.deletedAt.stamp
            if lhs != rhs { return lhs < rhs }
            return $0.id.uuid.uuidString < $1.id.uuid.uuidString
        }
        var legacyValuesByIdentityAndStamp: [String: SyncAtomicDomainValue] = [:]
        for record in legacy {
            guard case let .knittingReminder(reminder)? = record.payload.atomicDomain?.value,
                  reminder.id == record.id.uuid,
                  reminder.mutationRevision == record.entityRevision,
                  record.payload.atomicDomain?.stamp.logicalRevision == record.entityRevision,
                  record.relationships.contains(where: {
                      $0.role == "counter"
                          && $0.target == .init(kind: .projectCounter, uuid: reminder.counterID)
                  }) else {
                throw SyncRecordValidationError.illegalAtomicDomain(record.id)
            }
            let atomicStamp = record.payload.atomicDomain!.stamp
            let identityAndStamp = "\(record.id.uuid.uuidString)|\(atomicStamp.logicalRevision)|\(atomicStamp.modifiedAt.timeIntervalSinceReferenceDate)|\(atomicStamp.deviceID)"
            if let existing = legacyValuesByIdentityAndStamp[identityAndStamp],
               existing != record.payload.atomicDomain!.value {
                throw SyncMergeError.corruptEqualStamp(
                    entity: record.id, field: "counterReminderState"
                )
            }
            legacyValuesByIdentityAndStamp[identityAndStamp] = record.payload.atomicDomain!.value
            let counterID = SyncEntityID(kind: .projectCounter, uuid: reminder.counterID)
            let ownCounters = canonical.filter { $0.id == counterID }
            let candidates = ownCounters.isEmpty
                ? counterFallback.filter { $0.id == counterID }
                : ownCounters
            guard let counterRecord = candidates.max(by: {
                ($0.payload.atomicDomain?.stamp ?? $0.deletedAt.stamp)
                    < ($1.payload.atomicDomain?.stamp ?? $1.deletedAt.stamp)
            }), case .projectCounter? = counterRecord.payload.atomicDomain?.value,
                  let reminderVersion = record.payload.atomicDomain else {
                throw SyncRecordValidationError.illegalAtomicDomain(record.id)
            }
            let existing = canonical.firstIndex { $0.id == counterID }
            let base = existing.map { canonical[$0] } ?? counterRecord
            guard case let .projectCounter(baseState)? = base.payload.atomicDomain?.value,
                  let baseVersion = base.payload.atomicDomain else {
                throw SyncRecordValidationError.illegalAtomicDomain(record.id)
            }
            let reminders = baseState.reminders.filter { $0.id != reminder.id } + [reminder]
            let stamp = max(baseVersion.stamp, reminderVersion.stamp)
            let migratedState = SyncCounterReminderState(
                counter: baseState.counter,
                reminders: reminders,
                preparedCommand: baseState.preparedCommand,
                processedCommandIDs: baseState.processedCommandIDs,
                occurrence: baseState.occurrence
            )
            let migrated = SyncRecord(
                schemaVersion: base.schemaVersion,
                id: counterID,
                createdAt: min(base.createdAt, record.createdAt),
                entityRevision: max(stamp.logicalRevision, reminder.mutationRevision),
                payload: .init(
                    fields: base.payload.fields,
                    deletionCascade: base.payload.deletionCascade,
                    atomicDomain: .init(value: .projectCounter(migratedState), stamp: stamp),
                    attachment: base.payload.attachment
                ),
                relationships: base.relationships,
                deletedAt: base.deletedAt
            )
            if let existing { canonical[existing] = migrated } else { canonical.append(migrated) }
            migratedCounterIDs.insert(counterID)
        }
        return (canonical, migratedCounterIDs)
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

    private func merge(
        _ records: [SyncRecord],
        counterReminderContext: SyncCounterReminderMergeContext
    ) throws -> SyncRecord {
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
            entity: first.id,
            context: counterReminderContext
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
        let entityRevision = atomicDomain?.stamp.logicalRevision
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
        entity: SyncEntityID,
        context: SyncCounterReminderMergeContext
    ) throws -> SyncFieldVersion<SyncAtomicDomainValue>? {
        guard !versions.isEmpty else { return nil }
        let aggregateVersions = versions.compactMap {
            version -> SyncFieldVersion<SyncCounterReminderState>? in
            guard case let .projectCounter(state) = version.value else { return nil }
            return .init(value: state, stamp: version.stamp)
        }
        if aggregateVersions.count == versions.count {
            let ordered = aggregateVersions.sorted { $0.stamp < $1.stamp }
            let merged = try ordered.dropFirst().reduce(ordered[0]) {
                try counterReminderPolicy.merge($0, $1, context: context)
            }
            return .init(value: .projectCounter(merged.value), stamp: merged.stamp)
        }

        let legacyReminderVersions = versions.filter {
            if case .knittingReminder = $0.value { return true }
            return false
        }
        guard legacyReminderVersions.count == versions.count else {
            throw SyncMergeError.corruptAtomicDomain(
                entity: entity,
                revision: versions.map(\.value.mutationRevision).max() ?? 0
            )
        }
        var valuesByStamp: [SyncMutationStamp: SyncAtomicDomainValue] = [:]
        for version in legacyReminderVersions {
            if let existing = valuesByStamp[version.stamp], existing != version.value {
                throw SyncMergeError.corruptEqualStamp(
                    entity: entity,
                    field: "counterReminderState"
                )
            }
            valuesByStamp[version.stamp] = version.value
        }
        return legacyReminderVersions.max { $0.stamp < $1.stamp }
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
            guard case let .projectCounter(state)? = record.payload.atomicDomain?.value else {
                return nil
            }
            return state.counter
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
        var preparedByID = Dictionary(uniqueKeysWithValues: context.preparedCommands.map {
            ($0.command.id, $0)
        })
        for entry in context.processedLedger.entries {
            if let prepared = entry.preparedCommand {
                preparedByID[prepared.command.id] = prepared
            }
        }
        for prepared in preparedByID.values {
            guard let entry = context.processedLedger.entry(for: prepared.command.id),
                  entry.rejection == nil else { continue }
            guard let record = byID[.init(
                kind: .projectCounter,
                uuid: prepared.command.counterID
            )], case let .projectCounter(state)? = record.payload.atomicDomain?.value else {
                throw SyncMergeError.processedWatchCommandWouldRegress(prepared.command.id)
            }
            if state.processedCommandIDs.contains(prepared.command.id) { continue }
            guard counterReminderPolicy.commandIsReflected(prepared, in: state) else {
                throw SyncMergeError.processedWatchCommandWouldRegress(prepared.command.id)
            }
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
