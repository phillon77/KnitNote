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
    /// Decode-only standalone reminder records consumed by migration. The
    /// transport must delete these IDs so replay cannot restore a second live
    /// synchronization authority.
    public let legacyRecordIDsToDelete: Set<SyncEntityID>
    /// Exact pending operations, including immutable save payloads and delete
    /// intent. This prevents a later current-state lookup from changing what a
    /// previously committed mutation uploads.
    public let mutationsToUpload: [SyncMutation]
    /// The causally selected live head for every attachment slot. Ancestors
    /// remain in `records` as immutable history and are never presented as
    /// additional live attachments.
    public let resolvedAttachmentVersionIDs: [SyncAttachmentSlot: UUID]

    public init(
        records: [SyncRecord],
        conflicts: [SyncConflict],
        recordsToUpload: Set<SyncEntityID>,
        legacyRecordIDsToDelete: Set<SyncEntityID> = [],
        mutationsToUpload: [SyncMutation] = [],
        resolvedAttachmentVersionIDs: [SyncAttachmentSlot: UUID] = [:]
    ) {
        self.records = records
        self.conflicts = conflicts
        self.recordsToUpload = recordsToUpload
        self.legacyRecordIDsToDelete = legacyRecordIDsToDelete
        self.mutationsToUpload = mutationsToUpload
        self.resolvedAttachmentVersionIDs = resolvedAttachmentVersionIDs
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
            let lhsWithoutProofs = replacing(
                lhs.value,
                reminders: lhs.value.reminders,
                processedCommandIDs: [],
                processedCommandProofs: []
            )
            let rhsWithoutProofs = replacing(
                rhs.value,
                reminders: rhs.value.reminders,
                processedCommandIDs: [],
                processedCommandProofs: []
            )
            guard lhsWithoutProofs == rhsWithoutProofs else {
                throw SyncMergeError.corruptEqualStamp(
                    entity: .init(kind: .projectCounter, uuid: lhs.value.counter.id),
                    field: "counterReminderState"
                )
            }
            let merged = try mergingProcessedProofs(
                winner: lhs.value,
                older: rhs.value,
                context: context
            )
            return .init(value: merged, stamp: lhs.stamp)
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

        let candidate = try mergingProcessedProofs(
            winner: winner.value,
            older: older.value,
            context: context
        )
        return candidate == winner.value ? winner : .init(value: candidate, stamp: winner.stamp)
    }

    private func mergingProcessedProofs(
        winner: SyncCounterReminderState,
        older: SyncCounterReminderState,
        context: SyncCounterReminderMergeContext
    ) throws -> SyncCounterReminderState {
        let mergedIDs = winner.processedCommandIDs.union(older.processedCommandIDs)
        var proofsByID = Dictionary(uniqueKeysWithValues: winner.processedCommandProofs.map {
            ($0.id, $0)
        })
        for proof in older.processedCommandProofs {
            if let existing = proofsByID[proof.id], existing != proof {
                throw SyncMergeError.processedWatchCommandWouldRegress(proof.id)
            }
            proofsByID[proof.id] = proof
        }
        let candidate = replacing(
            winner,
            reminders: winner.reminders,
            processedCommandIDs: mergedIDs,
            processedCommandProofs: Array(proofsByID.values)
        )
        for commandID in mergedIDs where !processedCommandIsProven(
            commandID,
            in: candidate,
            context: context
        ) {
            throw SyncMergeError.processedWatchCommandWouldRegress(commandID)
        }
        return candidate
    }

    public func applyingStop(
        _ prepared: PreparedWatchCommand,
        to state: SyncCounterReminderState,
        processedLedger: ProcessedWatchCommandLedger
    ) throws -> SyncReminderStopOutcome {
        guard prepared.command.operation == .stopReminder,
              let entry = processedLedger.entry(for: prepared.command.id),
              entry.rejection == nil,
              entry.preparedCommand == prepared,
              let effectProof = entry.effectProof,
              processedEffectProof(effectProof, reflects: prepared),
              prepared.command.counterID == state.counter.id,
              let expectedReminderID = prepared.expectedReminderID,
              let expectedRevision = prepared.expectedReminderRevision,
              let reminder = state.reminders.first(where: {
                  $0.id == expectedReminderID
              }) else {
            throw SyncMergeError.processedWatchCommandWouldRegress(prepared.command.id)
        }

        guard preparedCommandTargetsMatch(prepared) else {
            throw SyncMergeError.processedWatchCommandWouldRegress(prepared.command.id)
        }
        let processedIDs = state.processedCommandIDs.union([prepared.command.id])
        let processedProof = try SyncProcessedWatchCommandProof(
            id: entry.id,
            counterID: prepared.command.counterID,
            rejection: entry.rejection,
            commandIdentity: entry.commandIdentity,
            preparedCommand: entry.preparedCommand,
            effectProof: entry.effectProof
        )
        var processedProofs = state.processedCommandProofs.filter { $0.id != entry.id }
        processedProofs.append(processedProof)
        if reminder.state == .stopped {
            guard commandIsReflected(prepared, in: state),
                  effectProof.reminder == reminder else {
                throw SyncMergeError.processedWatchCommandWouldRegress(prepared.command.id)
            }
            return .noOp(replacing(
                state,
                reminders: state.reminders,
                processedCommandIDs: processedIDs,
                processedCommandProofs: processedProofs
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
        guard effectProof.counter == state.counter,
              effectProof.reminder == stopped else {
            throw SyncMergeError.processedWatchCommandWouldRegress(prepared.command.id)
        }
        return .persisted(replacing(
            state,
            reminders: state.reminders.map {
                $0.id == stopped.id ? stopped : $0
            },
            processedCommandIDs: processedIDs,
            processedCommandProofs: processedProofs
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

    private func preparedCommandTargetsMatch(_ prepared: PreparedWatchCommand) -> Bool {
        switch prepared.command.operation {
        case .increment, .decrement, .reset:
            return prepared.expectedReminderID == nil
                && prepared.expectedOccurrenceID == nil
                && prepared.expectedReminderRevision == nil
        case .completeReminder, .deferReminderOnce, .skipReminder:
            guard let payload = prepared.command.reminderPayload else { return false }
            return payload.reminderID == prepared.expectedReminderID
                && payload.occurrenceID == prepared.expectedOccurrenceID
                && payload.observedRevision == prepared.expectedReminderRevision
        case .stopReminder:
            return prepared.command.reminderID == prepared.expectedReminderID
                && prepared.command.occurrenceID == prepared.expectedOccurrenceID
                && prepared.command.observedMutationRevision
                    == prepared.expectedReminderRevision
        }
    }

    func processedCommandIsProven(
        _ commandID: UUID,
        in state: SyncCounterReminderState,
        context: SyncCounterReminderMergeContext
    ) -> Bool {
        let embedded = state.processedCommandProofs.first { $0.id == commandID }
        let ledgerProof: SyncProcessedWatchCommandProof? = context.processedLedger
            .entry(for: commandID).flatMap { try? SyncProcessedWatchCommandProof(entry: $0) }
        guard let proofRecord = embedded ?? ledgerProof,
              proofRecord.counterID == state.counter.id else { return false }
        if proofRecord.rejection != nil {
            guard proofRecord.effectProof == nil,
                  proofRecord.commandIdentity != nil
                    || proofRecord.preparedCommand != nil else { return false }
            if let identity = proofRecord.commandIdentity {
                guard identity.id == commandID,
                      identity.counterID == state.counter.id else { return false }
            }
            if let prepared = proofRecord.preparedCommand {
                guard prepared.command.id == commandID,
                      prepared.command.counterID == state.counter.id,
                      proofRecord.commandIdentity == nil
                        || proofRecord.commandIdentity
                            == ProcessedWatchCommandIdentity(prepared.command),
                      preparedCommandTargetsMatch(prepared) else { return false }
            }
            if let transient = context.preparedCommands.first(where: {
                $0.command.id == commandID
            }) {
                guard transient.command.counterID == state.counter.id,
                      proofRecord.commandIdentity == nil
                        || proofRecord.commandIdentity
                            == ProcessedWatchCommandIdentity(transient.command),
                      proofRecord.preparedCommand == nil
                        || proofRecord.preparedCommand == transient else { return false }
            }
            return true
        }
        guard let prepared = proofRecord.preparedCommand,
            prepared.command.id == commandID,
            prepared.command.counterID == state.counter.id,
            preparedCommandTargetsMatch(prepared) else { return false }
        if let transient = context.preparedCommands.first(where: {
            $0.command.id == commandID
        }), transient != prepared {
            return false
        }
        guard let proof = proofRecord.effectProof else { return false }
        return processedEffectProof(proof, reflects: prepared)
            && stateHasNotRegressedBelowProof(state, proof: proof)
    }

    private func stateHasNotRegressedBelowProof(
        _ state: SyncCounterReminderState,
        proof: ProcessedWatchCommandEffectProof
    ) -> Bool {
        guard state.counter.id == proof.counter.id,
              state.counter.mutationRevision >= proof.counter.mutationRevision else {
            return false
        }
        if state.counter.mutationRevision == proof.counter.mutationRevision,
           state.counter.value != proof.counter.value {
            return false
        }
        guard let proofReminder = proof.reminder,
              let reminder = state.reminders.first(where: {
                  $0.id == proofReminder.id
              }) else {
            return true
        }
        guard reminder.mutationRevision >= proofReminder.mutationRevision else {
            return false
        }
        return reminder.mutationRevision != proofReminder.mutationRevision
            || reminder == proofReminder
    }

    private func processedEffectProof(
        _ proof: ProcessedWatchCommandEffectProof,
        reflects prepared: PreparedWatchCommand
    ) -> Bool {
        let proofState = SyncCounterReminderState(
            counter: proof.counter,
            reminder: proof.reminder,
            preparedCommand: prepared,
            processedCommandIDs: [prepared.command.id],
            occurrence: proof.reminder?.progress.nextOccurrenceIndex
        )
        return commandIsReflected(prepared, in: proofState)
    }

    private func replacingProcessedIDs(
        in state: SyncCounterReminderState,
        with ids: Set<UUID>
    ) -> SyncCounterReminderState {
        replacing(
            state,
            reminders: state.reminders,
            processedCommandIDs: ids,
            processedCommandProofs: state.processedCommandProofs
        )
    }

    private func replacing(
        _ state: SyncCounterReminderState,
        reminders: [KnittingReminder],
        processedCommandIDs: Set<UUID>,
        processedCommandProofs: [SyncProcessedWatchCommandProof]? = nil
    ) -> SyncCounterReminderState {
        SyncCounterReminderState(
            counter: state.counter,
            reminders: reminders,
            preparedCommand: state.preparedCommand,
            processedCommandIDs: processedCommandIDs,
            processedCommandProofs: processedCommandProofs ?? state.processedCommandProofs,
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
            pendingCanonicalSaveRecords: [],
            counterReminderContext: counterReminderContext
        )
    }

    public func merge(
        local: some Sequence<SyncRecord>,
        remote: some Sequence<SyncRecord>,
        pendingLocalMutations: [SyncMutation],
        counterReminderContext: SyncCounterReminderMergeContext = .init()
    ) throws -> SyncMergeResult {
        let pendingCanonicalSaveRecords: [SyncRecord] = pendingLocalMutations.compactMap {
            guard let record = $0.savedRecordVersion?.record,
                  record.id.kind != .knittingReminder else { return nil }
            return record
        }
        return try mergeRecords(
            local: Array(local),
            remote: Array(remote),
            pendingLocal: Set(pendingLocalMutations.map(\.recordID)),
            pendingMutations: pendingLocalMutations,
            pendingCanonicalSaveRecords: pendingCanonicalSaveRecords,
            counterReminderContext: counterReminderContext
        )
    }

    private func mergeRecords(
        local: [SyncRecord],
        remote: [SyncRecord],
        pendingLocal: Set<SyncEntityID>,
        pendingMutations: [SyncMutation],
        pendingCanonicalSaveRecords: [SyncRecord],
        counterReminderContext: SyncCounterReminderMergeContext
    ) throws -> SyncMergeResult {
        let legacyPlan = try legacyReminderMigrationPlan(records: local + remote)
        let canonicalLocal = local.filter { $0.id.kind != .knittingReminder }
        let canonicalRemote = remote.filter { $0.id.kind != .knittingReminder }
        let localGroups = try groupedRecords(canonicalLocal)
        let remoteGroups = try groupedRecords(canonicalRemote)
        let pendingCanonicalGroups = try groupedRecords(pendingCanonicalSaveRecords)
        let ids = Set(localGroups.keys).union(remoteGroups.keys).sorted(by: Self.entityIDLess)
        var mergedRecords: [SyncRecord] = []
        var recordsToUpload: Set<SyncEntityID> = []
        var atomicConflicts: [SyncConflict] = []
        let conflictIDs = Set(ids).union(pendingCanonicalGroups.keys)
            .sorted(by: Self.entityIDLess)
        for id in conflictIDs {
            let candidates = (localGroups[id] ?? [])
                + (remoteGroups[id] ?? [])
                + (pendingCanonicalGroups[id] ?? [])
            if let conflict = counterConflict(in: candidates, entity: id) {
                atomicConflicts.append(conflict)
            }
        }

        for id in ids {
            let candidates = (localGroups[id] ?? []) + (remoteGroups[id] ?? [])
            var merged = try merge(candidates, counterReminderContext: counterReminderContext)
            if let resolutions = legacyPlan.resolutionsByCounter[id] {
                merged = try applyingLegacyReminderResolutions(
                    resolutions,
                    to: merged
                )
            }
            let validated = try validator.validate(merged)
            mergedRecords.append(validated)
            let remoteRecord = try remoteGroups[id].map {
                try merge($0, counterReminderContext: counterReminderContext)
            }
            if remoteRecord != validated || pendingLocal.contains(id)
                || legacyPlan.migratedCounterIDs.contains(id) {
                recordsToUpload.insert(id)
            }
        }

        let converted = try replayingPendingMutations(
            pendingMutations,
            records: mergedRecords,
            plan: legacyPlan,
            counterReminderContext: counterReminderContext
        )
        mergedRecords = try validator.validate(converted.records)
        recordsToUpload.formUnion(converted.mutations.map(\.recordID))
        try validateCounterReminderContext(
            records: mergedRecords,
            context: counterReminderContext
        )
        let attachmentLineage = try SyncAttachmentLineage(records: mergedRecords)
        let conflicts = atomicConflicts
            + attachmentConflicts(in: attachmentLineage)
            + possibleDuplicateConflicts(in: mergedRecords)

        return SyncMergeResult(
            records: mergedRecords,
            conflicts: conflicts.sorted(by: Self.conflictLess),
            recordsToUpload: recordsToUpload,
            legacyRecordIDsToDelete: legacyPlan.consumedLegacyRecordIDs,
            mutationsToUpload: converted.mutations,
            resolvedAttachmentVersionIDs: attachmentLineage.resolvedLiveVersionIDs()
        )
    }

    private func legacyReminderMigrationPlan(
        records: [SyncRecord]
    ) throws -> LegacyReminderMigrationPlan {
        let counterRecords = records.filter { $0.id.kind == .projectCounter }
        var candidatesByReminderID: [UUID: [LegacyReminderCandidate]] = [:]
        for record in records where record.id.kind == .knittingReminder {
            guard case let .knittingReminder(reminder)? = record.payload.atomicDomain?.value,
                  reminder.id == record.id.uuid,
                  reminder.mutationRevision == record.entityRevision,
                  record.payload.atomicDomain?.stamp.logicalRevision == record.entityRevision,
                  record.relationships.filter({ $0.role == "counter" }).count == 1,
                  record.relationships.contains(where: {
                      $0.role == "counter"
                          && $0.target == .init(kind: .projectCounter, uuid: reminder.counterID)
                  }) else {
                throw SyncRecordValidationError.illegalAtomicDomain(record.id)
            }
            let counterID = SyncEntityID(kind: .projectCounter, uuid: reminder.counterID)
            guard counterRecords.contains(where: {
                $0.id == counterID
                    && $0.payload.atomicDomain?.value.projectCounterState != nil
            }) else {
                throw SyncRecordValidationError.illegalAtomicDomain(record.id)
            }
            candidatesByReminderID[reminder.id, default: []].append(.init(
                reminder: reminder,
                counterID: counterID,
                stamp: max(record.payload.atomicDomain!.stamp, record.deletedAt.stamp),
                isDeleted: record.deletedAt.value != nil
            ))
        }

        var counterByReminderID: [UUID: SyncEntityID] = [:]
        for record in counterRecords {
            guard let state = record.payload.atomicDomain?.value.projectCounterState else {
                continue
            }
            for reminder in state.reminders {
                let counterID = SyncEntityID(kind: .projectCounter, uuid: state.counter.id)
                if let existing = counterByReminderID[reminder.id], existing != counterID {
                    throw SyncRecordValidationError.illegalAtomicDomain(
                        .init(kind: .knittingReminder, uuid: reminder.id)
                    )
                }
                counterByReminderID[reminder.id] = counterID
            }
        }

        var resolutionsByCounter: [SyncEntityID: [LegacyReminderResolution]] = [:]
        for (reminderID, candidates) in candidatesByReminderID {
            guard let firstCounterID = candidates.first?.counterID,
                  candidates.allSatisfy({ $0.counterID == firstCounterID }) else {
                throw SyncRecordValidationError.illegalAtomicDomain(
                    .init(kind: .knittingReminder, uuid: reminderID)
                )
            }
            let newestStamp = candidates.map(\.stamp).max()!
            let newest = candidates.filter { $0.stamp == newestStamp }
            guard let first = newest.first,
                  newest.allSatisfy({
                      $0.reminder == first.reminder && $0.isDeleted == first.isDeleted
                  }) else {
                throw SyncMergeError.corruptEqualStamp(
                    entity: .init(kind: .knittingReminder, uuid: reminderID),
                    field: "counterReminderState"
                )
            }
            counterByReminderID[reminderID] = firstCounterID
            resolutionsByCounter[firstCounterID, default: []].append(.init(
                reminder: first.reminder,
                stamp: newestStamp,
                isDeleted: first.isDeleted
            ))
        }

        return LegacyReminderMigrationPlan(
            resolutionsByCounter: resolutionsByCounter,
            counterByReminderID: counterByReminderID,
            consumedLegacyRecordIDs: Set(records.compactMap {
                $0.id.kind == .knittingReminder ? $0.id : nil
            })
        )
    }

    private func applyingLegacyReminderResolutions(
        _ resolutions: [LegacyReminderResolution],
        to record: SyncRecord
    ) throws -> SyncRecord {
        guard case let .projectCounter(state)? = record.payload.atomicDomain?.value,
              let baseVersion = record.payload.atomicDomain else {
            throw SyncRecordValidationError.illegalAtomicDomain(record.id)
        }
        var migratedState = state
        var aggregateStamp = baseVersion.stamp
        let ordered = resolutions.sorted {
            if $0.stamp != $1.stamp { return $0.stamp < $1.stamp }
            return $0.reminder.id.uuidString < $1.reminder.id.uuidString
        }
        var index = ordered.startIndex
        while index < ordered.endIndex {
            let groupStamp = ordered[index].stamp
            var end = ordered.index(after: index)
            while end < ordered.endIndex, ordered[end].stamp == groupStamp {
                end = ordered.index(after: end)
            }
            let group = ordered[index..<end]
            index = end
            guard groupStamp >= aggregateStamp else { continue }

            var reminders = migratedState.reminders
            for resolution in group {
                reminders.removeAll { $0.id == resolution.reminder.id }
                if !resolution.isDeleted { reminders.append(resolution.reminder) }
            }
            let candidate = replacingReminderCollection(
                in: migratedState,
                with: reminders
            )
            if groupStamp == aggregateStamp {
                guard candidate == migratedState else {
                    let reminderID = group.first!.reminder.id
                    throw SyncMergeError.corruptEqualStamp(
                        entity: .init(kind: .knittingReminder, uuid: reminderID),
                        field: "counterReminderState"
                    )
                }
                continue
            }
            migratedState = candidate
            aggregateStamp = groupStamp
        }
        return SyncRecord(
            schemaVersion: record.schemaVersion,
            id: record.id,
            createdAt: record.createdAt,
            entityRevision: aggregateStamp.logicalRevision,
            payload: .init(
                fields: record.payload.fields,
                deletionCascade: record.payload.deletionCascade,
                atomicDomain: .init(value: .projectCounter(migratedState), stamp: aggregateStamp),
                attachment: record.payload.attachment
            ),
            relationships: record.relationships,
            deletedAt: record.deletedAt
        )
    }

    private func replayingPendingMutations(
        _ mutations: [SyncMutation],
        records: [SyncRecord],
        plan: LegacyReminderMigrationPlan,
        counterReminderContext: SyncCounterReminderMergeContext
    ) throws -> (records: [SyncRecord], mutations: [SyncMutation]) {
        var rollingRecords = Dictionary(uniqueKeysWithValues: records.map {
            ($0.id, $0)
        })
        var counterByReminderID = plan.counterByReminderID
        var converted: [SyncMutation] = []
        converted.reserveCapacity(mutations.count)

        for mutation in mutations {
            guard mutation.recordID.kind == .knittingReminder else {
                switch mutation {
                case let .save(save):
                    let validated = try save.validated()
                    let savedRecord = normalize(try validator.validate(
                        validated.recordVersion.record
                    ))
                    let nextRecord: SyncRecord
                    if let base = rollingRecords[savedRecord.id] {
                        nextRecord = try merge(
                            [base, savedRecord],
                            counterReminderContext: counterReminderContext
                        )
                    } else {
                        nextRecord = savedRecord
                    }
                    rollingRecords[savedRecord.id] = nextRecord
                    try recordReminderOwnership(
                        in: nextRecord,
                        counterByReminderID: &counterByReminderID
                    )
                case let .delete(delete):
                    if delete.recordID.kind == .attachment {
                        guard var attachmentRecord = rollingRecords[delete.recordID],
                              attachmentRecord.payload.attachment != nil else {
                            // A legacy bare delete does not carry the immutable
                            // attachment snapshot. It can only be upgraded when
                            // that exact version is still available; guessing a
                            // version or lineage would make retries unsafe.
                            throw SyncRecordValidationError.invalidAttachment(delete.recordID)
                        }
                        if attachmentRecord.deletedAt.value == nil {
                            let (nextRevision, overflow) = attachmentRecord.entityRevision
                                .addingReportingOverflow(1)
                            guard !overflow else {
                                throw SyncMergeError.corruptAttachmentVersion(
                                    delete.recordID.uuid
                                )
                            }
                            let tombstoneStamp = SyncMutationStamp(
                                logicalRevision: nextRevision,
                                modifiedAt: attachmentRecord.deletedAt.stamp.modifiedAt,
                                deviceID: "legacy-attachment-delete-\(delete.mutationID.uuidString.lowercased())"
                            )
                            attachmentRecord.entityRevision = nextRevision
                            attachmentRecord.deletedAt = .init(
                                value: tombstoneStamp.modifiedAt,
                                stamp: tombstoneStamp
                            )
                        }
                        let tombstone = try validator.validate(attachmentRecord)
                        rollingRecords[delete.recordID] = tombstone
                        converted.append(try .save(
                            recordVersion: SyncRecordVersion(record: tombstone),
                            mutationID: delete.mutationID
                        ))
                        continue
                    }
                    rollingRecords.removeValue(forKey: delete.recordID)
                }
                converted.append(mutation)
                continue
            }
            let counterID: SyncEntityID
            let reminder: KnittingReminder?
            let isDeleted: Bool
            let sourceStamp: SyncMutationStamp?
            switch mutation {
            case let .save(save):
                let validated = try save.validatedForJournalLoad()
                guard case let .knittingReminder(value)? =
                        validated.recordVersion.record.payload.atomicDomain?.value,
                      value.id == mutation.recordID.uuid,
                      let atomicStamp = validated.recordVersion.record.payload.atomicDomain?.stamp
                else {
                    throw SyncRecordValidationError.illegalAtomicDomain(mutation.recordID)
                }
                counterID = SyncEntityID(
                    kind: .projectCounter,
                    uuid: value.counterID
                )
                if let existing = counterByReminderID[value.id], existing != counterID {
                    throw SyncRecordValidationError.illegalAtomicDomain(mutation.recordID)
                }
                counterByReminderID[value.id] = counterID
                reminder = value
                isDeleted = validated.recordVersion.record.deletedAt.value != nil
                sourceStamp = max(
                    atomicStamp,
                    validated.recordVersion.record.deletedAt.stamp
                )
            case .delete:
                guard let existing = counterByReminderID[mutation.recordID.uuid] else {
                    throw SyncRecordValidationError.illegalAtomicDomain(mutation.recordID)
                }
                counterID = existing
                reminder = nil
                isDeleted = true
                sourceStamp = nil
            }

            guard let base = rollingRecords[counterID] else {
                throw SyncRecordValidationError.illegalAtomicDomain(mutation.recordID)
            }
            guard case let .projectCounter(baseState)? = base.payload.atomicDomain?.value,
                  let baseStamp = base.payload.atomicDomain?.stamp else {
                throw SyncRecordValidationError.illegalAtomicDomain(counterID)
            }
            let nextState = replacingReminder(
                reminder,
                reminderID: mutation.recordID.uuid,
                isDeleted: isDeleted,
                in: baseState
            )
            let nextStamp = try legacyMutationStamp(
                after: baseStamp,
                source: sourceStamp,
                mutationID: mutation.mutationID,
                changesState: nextState != baseState,
                counterID: counterID
            )
            let exactCounterRecord = replacingCounterReminderState(
                nextState,
                stamp: nextStamp,
                in: base
            )
            let validatedCounter = try validator.validate(exactCounterRecord)
            rollingRecords[counterID] = validatedCounter
            converted.append(try SyncMutation.save(
                recordVersion: SyncRecordVersion(record: validatedCounter),
                mutationID: mutation.mutationID
            ))
        }
        return (
            rollingRecords.values.sorted { Self.entityIDLess($0.id, $1.id) },
            converted
        )
    }

    private func recordReminderOwnership(
        in record: SyncRecord,
        counterByReminderID: inout [UUID: SyncEntityID]
    ) throws {
        guard case let .projectCounter(state)? = record.payload.atomicDomain?.value else {
            return
        }
        let counterID = SyncEntityID(kind: .projectCounter, uuid: state.counter.id)
        guard record.id == counterID else {
            throw SyncRecordValidationError.illegalAtomicDomain(record.id)
        }
        for reminder in state.reminders {
            if let existing = counterByReminderID[reminder.id], existing != counterID {
                throw SyncRecordValidationError.illegalAtomicDomain(
                    .init(kind: .knittingReminder, uuid: reminder.id)
                )
            }
            counterByReminderID[reminder.id] = counterID
        }
    }

    private func legacyMutationStamp(
        after base: SyncMutationStamp,
        source: SyncMutationStamp?,
        mutationID: UUID,
        changesState: Bool,
        counterID: SyncEntityID
    ) throws -> SyncMutationStamp {
        if !changesState { return max(base, source ?? base) }
        if let source, source > base { return source }
        let (revision, overflow) = base.logicalRevision.addingReportingOverflow(1)
        guard !overflow else {
            throw SyncMergeError.corruptAtomicDomain(
                entity: counterID,
                revision: base.logicalRevision
            )
        }
        return SyncMutationStamp(
            logicalRevision: revision,
            modifiedAt: max(base.modifiedAt, source?.modifiedAt ?? base.modifiedAt),
            deviceID: "legacy-reminder-mutation-\(mutationID.uuidString.lowercased())"
        )
    }

    private func replacingReminder(
        _ reminder: KnittingReminder?,
        reminderID: UUID,
        isDeleted: Bool,
        in state: SyncCounterReminderState
    ) -> SyncCounterReminderState {
        var reminders = state.reminders.filter { $0.id != reminderID }
        if !isDeleted, let reminder { reminders.append(reminder) }
        return replacingReminderCollection(in: state, with: reminders)
    }

    private func replacingReminderCollection(
        in state: SyncCounterReminderState,
        with reminders: [KnittingReminder]
    ) -> SyncCounterReminderState {
        let occurrence = state.occurrence.flatMap { candidate in
            reminders.contains { $0.progress.nextOccurrenceIndex == candidate }
                ? candidate
                : nil
        }
        return SyncCounterReminderState(
            counter: state.counter,
            reminders: reminders,
            preparedCommand: state.preparedCommand,
            processedCommandIDs: state.processedCommandIDs,
            processedCommandProofs: state.processedCommandProofs,
            occurrence: occurrence
        )
    }

    private func replacingCounterReminderState(
        _ state: SyncCounterReminderState,
        stamp: SyncMutationStamp,
        in record: SyncRecord
    ) -> SyncRecord {
        SyncRecord(
            schemaVersion: record.schemaVersion,
            id: record.id,
            createdAt: record.createdAt,
            entityRevision: stamp.logicalRevision,
            payload: .init(
                fields: record.payload.fields,
                deletionCascade: record.payload.deletionCascade,
                atomicDomain: .init(value: .projectCounter(state), stamp: stamp),
                attachment: record.payload.attachment
            ),
            relationships: record.relationships,
            deletedAt: record.deletedAt
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

        let orphanProofVersions = versions.compactMap {
            version -> SyncFieldVersion<SyncOrphanWatchCommandProof>? in
            guard case let .orphanWatchCommandProof(proof) = version.value else { return nil }
            return .init(value: proof, stamp: version.stamp)
        }
        if orphanProofVersions.count == versions.count {
            guard let first = orphanProofVersions.first,
                  orphanProofVersions.allSatisfy({ $0.value == first.value }) else {
                throw SyncMergeError.corruptEqualStamp(entity: entity, field: "orphanWatchCommandProof")
            }
            let newest = orphanProofVersions.max { $0.stamp < $1.stamp } ?? first
            return .init(value: .orphanWatchCommandProof(newest.value), stamp: newest.stamp)
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

    private func attachmentConflicts(in lineage: SyncAttachmentLineage) -> [SyncConflict] {
        lineage.headsBySlot.compactMap { slot, records in
            let sortedIDs = Self.sortedEntityIDs(Set(records.map(\.id)))
            guard sortedIDs.count > 1 else { return nil }
            return .attachmentVersions(
                owner: slot.owner,
                role: slot.role,
                ids: sortedIDs
            )
        }
    }

    private func validateCounterReminderContext(
        records: [SyncRecord],
        context: SyncCounterReminderMergeContext
    ) throws {
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        for record in records {
            guard case let .projectCounter(state)? = record.payload.atomicDomain?.value else {
                continue
            }
            for commandID in state.processedCommandIDs {
                guard counterReminderPolicy.processedCommandIsProven(
                    commandID,
                    in: state,
                    context: context
                ) else {
                    throw SyncMergeError.processedWatchCommandWouldRegress(commandID)
                }
            }
        }
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
            guard counterReminderPolicy.processedCommandIsProven(
                prepared.command.id,
                in: state,
                context: context
            ) else {
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

private struct LegacyReminderCandidate {
    let reminder: KnittingReminder
    let counterID: SyncEntityID
    let stamp: SyncMutationStamp
    let isDeleted: Bool
}

private struct LegacyReminderResolution {
    let reminder: KnittingReminder
    let stamp: SyncMutationStamp
    let isDeleted: Bool
}

private struct LegacyReminderMigrationPlan {
    let resolutionsByCounter: [SyncEntityID: [LegacyReminderResolution]]
    let counterByReminderID: [UUID: SyncEntityID]
    let consumedLegacyRecordIDs: Set<SyncEntityID>

    var migratedCounterIDs: Set<SyncEntityID> {
        Set(resolutionsByCounter.keys)
    }
}

private extension SyncAtomicDomainValue {
    var projectCounterState: SyncCounterReminderState? {
        guard case let .projectCounter(state) = self else { return nil }
        return state
    }
}

private struct DuplicateKey: Hashable {
    let kind: SyncEntityKind
    let normalizedName: String
}
