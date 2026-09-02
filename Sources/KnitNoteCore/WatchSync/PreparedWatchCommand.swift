import Foundation

public struct PreparedWatchReminderOutcome: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case complete
        case deferOnce
        case skip
    }

    public let action: Action
    public let completedCount: Int
    public let skippedCount: Int
    public let deferredDisplayAt: Int?

    public init(
        action: Action,
        completedCount: Int,
        skippedCount: Int,
        deferredDisplayAt: Int? = nil
    ) {
        self.action = action
        self.completedCount = completedCount
        self.skippedCount = skippedCount
        self.deferredDisplayAt = deferredDisplayAt
    }
}

public struct PreparedWatchCommand: Codable, Equatable, Sendable {
    public let command: WatchCounterCommand
    public let expectedCounterRevision: UInt64
    public let expectedCounterValue: Int?
    public let expectedReminderID: UUID?
    public let expectedOccurrenceID: UUID?
    public let expectedReminderRevision: UInt64?
    public let expectedReminderOutcome: PreparedWatchReminderOutcome?

    public init(
        command: WatchCounterCommand,
        expectedCounterRevision: UInt64,
        expectedCounterValue: Int? = nil,
        expectedReminderID: UUID? = nil,
        expectedOccurrenceID: UUID? = nil,
        expectedReminderRevision: UInt64? = nil,
        expectedReminderOutcome: PreparedWatchReminderOutcome? = nil
    ) {
        self.command = command
        self.expectedCounterRevision = expectedCounterRevision
        self.expectedCounterValue = expectedCounterValue
        self.expectedReminderID = expectedReminderID
        self.expectedOccurrenceID = expectedOccurrenceID
        self.expectedReminderRevision = expectedReminderRevision
        self.expectedReminderOutcome = expectedReminderOutcome
    }
}

public enum WatchCommandRecoveryState: Equatable, Sendable {
    case ready
    case requiresFreshHandshake
}

public enum WatchCommandPersistenceError: Error, Equatable, Sendable {
    case requiresFreshHandshake
}

public enum WatchCommandPersistenceBoundary: CaseIterable, Equatable, Sendable {
    case afterPreparedCommandSave
    case afterProjectArchiveSave
    case afterLedgerSave
    case afterPreparedCommandDeletion
}

@MainActor extension JSONProjectStore {
    public func recoverWatchCommandPersistence(
        entitlement: EntitlementSnapshot = .permanentlyUnlocked,
        ledgerURL: URL,
        preparedCommandURL: URL,
        now: Date = .now
    ) throws -> WatchCommandRecoveryState {
        try requireWatchEntitlement(entitlement, now: now)
        try authorizeWatchCounterMutation()
        return try recoverAuthorizedWatchCommandPersistence(
            ledgerURL: ledgerURL,
            preparedCommandURL: preparedCommandURL,
            now: now
        )
    }

    private func recoverAuthorizedWatchCommandPersistence(
        ledgerURL: URL,
        preparedCommandURL: URL,
        now: Date
    ) throws -> WatchCommandRecoveryState {
        let ledgerFile = AtomicWatchSyncFile<ProcessedWatchCommandLedger>(url: ledgerURL)
        var ledger = try loadLedgerRecoveringCorruption(from: ledgerFile)

        let preparedFile = AtomicWatchSyncFile<PreparedWatchCommand>(url: preparedCommandURL)
        let prepared: PreparedWatchCommand?
        do {
            prepared = try preparedFile.load()
        } catch {
            try preparedFile.quarantineCorruptFile()
            try requireFreshHandshake(ledger: &ledger, file: ledgerFile)
            return .requiresFreshHandshake
        }
        if ledger.requiresFreshHandshake { return .requiresFreshHandshake }
        guard let prepared else {
            try publishWatchSyncMetadata(preparedCommand: nil, processedLedger: ledger)
            return .ready
        }

        if ledger.contains(prepared.command.id) {
            try removePreparedCommand(at: preparedCommandURL)
            try publishWatchSyncMetadata(preparedCommand: nil, processedLedger: ledger)
            return .ready
        }
        guard prepared.command.schemaVersion == WatchCounterCommand.currentSchemaVersion,
              prepared.command.hasValidPayload else {
            ledger.record(prepared.command.id, rejection: .unsupportedSchema, at: now)
            try ledgerFile.save(ledger)
            try removePreparedCommand(at: preparedCommandURL)
            return .ready
        }
        guard
            let project = project(id: prepared.command.projectID),
            !project.isCompleted,
            let counter = project.counters.first(where: { $0.id == prepared.command.counterID })
        else {
            try requireFreshHandshake(ledger: &ledger, file: ledgerFile)
            return .requiresFreshHandshake
        }

        if counter.mutationRevision == prepared.expectedCounterRevision {
            if let expectedValue = prepared.expectedCounterValue {
                guard counter.value == expectedValue else {
                    try requireFreshHandshake(ledger: &ledger, file: ledgerFile)
                    return .requiresFreshHandshake
                }
                if prepared.reminderMutationWasApplied(in: project, counterID: counter.id) {
                    ledger.record(
                        prepared.command.id,
                        preparedCommand: prepared,
                        effectProof: watchCommandEffectProof(for: prepared),
                        at: now
                    )
                } else if !prepared.hasExpectedReminderState(in: project, counterID: counter.id) {
                    try requireFreshHandshake(ledger: &ledger, file: ledgerFile)
                    return .requiresFreshHandshake
                } else if prepared.isAcceptedNoOp {
                    ledger.record(
                        prepared.command.id,
                        preparedCommand: prepared,
                        effectProof: watchCommandEffectProof(for: prepared),
                        at: now
                    )
                } else {
                    _ = try withWatchSyncPublicationMetadata(
                        preparedCommand: prepared,
                        processedLedger: ledger
                    ) {
                        try applyAuthorizedWatchCommand(prepared.command, ledger: &ledger, now: now)
                    }
                    ledger.record(
                        prepared.command.id,
                        preparedCommand: prepared,
                        effectProof: watchCommandEffectProof(for: prepared),
                        at: now
                    )
                }
            } else {
                _ = try withWatchSyncPublicationMetadata(
                    preparedCommand: prepared,
                    processedLedger: ledger
                ) {
                    try applyAuthorizedWatchCommand(prepared.command, ledger: &ledger, now: now)
                }
                ledger.record(
                    prepared.command.id,
                    preparedCommand: prepared,
                    effectProof: watchCommandEffectProof(for: prepared),
                    at: now
                )
            }
        } else if
            prepared.isCounterOperation &&
            prepared.expectedCounterRevision != UInt64.max,
            counter.mutationRevision == prepared.expectedCounterRevision + 1
        {
            ledger.record(
                prepared.command.id,
                preparedCommand: prepared,
                effectProof: watchCommandEffectProof(for: prepared),
                at: now
            )
        } else {
            try requireFreshHandshake(ledger: &ledger, file: ledgerFile)
            return .requiresFreshHandshake
        }

        try ledgerFile.save(ledger)
        try removePreparedCommand(at: preparedCommandURL)
        try publishWatchSyncMetadata(preparedCommand: nil, processedLedger: ledger)
        return .ready
    }

    public func applyWatchCommandDurably(
        _ command: WatchCounterCommand,
        entitlement: EntitlementSnapshot = .permanentlyUnlocked,
        ledgerURL: URL,
        preparedCommandURL: URL,
        now: Date = .now,
        failureInjector: (WatchCommandPersistenceBoundary) throws -> Void = { _ in }
    ) throws -> WatchCommandAcknowledgement {
        if let acknowledgement = try persistedWatchCommandAcknowledgement(
            for: command,
            entitlement: entitlement,
            ledgerURL: ledgerURL,
            now: now
        ) {
            return acknowledgement
        }
        guard command.schemaVersion == WatchCounterCommand.currentSchemaVersion,
              command.hasValidPayload else {
            let ledgerFile = AtomicWatchSyncFile<ProcessedWatchCommandLedger>(url: ledgerURL)
            var ledger = try loadLedgerRecoveringCorruption(from: ledgerFile)
            guard !ledger.requiresFreshHandshake else {
                throw WatchCommandPersistenceError.requiresFreshHandshake
            }
            ledger.record(command.id, rejection: .unsupportedSchema, at: now)
            try ledgerFile.save(ledger)
            return try watchAcknowledgement(
                for: command.id,
                rejection: .unsupportedSchema,
                entitlement: entitlement,
                now: now
            )
        }
        try requireWatchEntitlement(entitlement, now: now)
        try authorizeWatchCounterMutation()
        guard try recoverAuthorizedWatchCommandPersistence(
            ledgerURL: ledgerURL,
            preparedCommandURL: preparedCommandURL,
            now: now
        ) == .ready else {
            throw WatchCommandPersistenceError.requiresFreshHandshake
        }

        let ledgerFile = AtomicWatchSyncFile<ProcessedWatchCommandLedger>(url: ledgerURL)
        var ledger = try loadLedgerRecoveringCorruption(from: ledgerFile)
        guard !ledger.requiresFreshHandshake else {
            throw WatchCommandPersistenceError.requiresFreshHandshake
        }
        if ledger.contains(command.id) {
            return try applyAuthorizedWatchCommand(
                command,
                entitlement: entitlement,
                ledger: &ledger,
                now: now
            )
        }

        guard
            command.schemaVersion == WatchCounterCommand.currentSchemaVersion,
            command.hasValidPayload,
            let project = project(id: command.projectID),
            !project.isCompleted,
            let counter = project.counters.first(where: { $0.id == command.counterID })
        else {
            let acknowledgement = try applyAuthorizedWatchCommand(
                command,
                entitlement: entitlement,
                ledger: &ledger,
                now: now
            )
            try ledgerFile.save(ledger)
            return acknowledgement
        }

        if command.reminderPayload != nil,
           !reminderCommandIsCurrent(command, project: project, counter: counter) {
            let acknowledgement = try applyAuthorizedWatchCommand(
                command,
                entitlement: entitlement,
                ledger: &ledger,
                now: now
            )
            try ledgerFile.save(ledger)
            return acknowledgement
        }

        let preparedFile = AtomicWatchSyncFile<PreparedWatchCommand>(url: preparedCommandURL)
        let reminderOutcome = preparedReminderOutcome(
            for: command,
            project: project,
            counter: counter
        )
        let prepared = PreparedWatchCommand(
            command: command,
            expectedCounterRevision: counter.mutationRevision,
            expectedCounterValue: counter.value,
            expectedReminderID: command.reminderPayload?.reminderID,
            expectedOccurrenceID: command.reminderPayload?.occurrenceID,
            expectedReminderRevision: command.reminderPayload?.observedRevision,
            expectedReminderOutcome: reminderOutcome
        )
        try preparedFile.save(prepared)
        try failureInjector(.afterPreparedCommandSave)

        let acknowledgement = try withWatchSyncPublicationMetadata(
            preparedCommand: prepared,
            processedLedger: ledger
        ) {
            try applyAuthorizedWatchCommand(
                command,
                entitlement: entitlement,
                ledger: &ledger,
                now: now
            )
        }
        ledger.record(
            command.id,
            rejection: acknowledgement.rejection,
            preparedCommand: prepared,
            effectProof: acknowledgement.rejection == nil
                ? watchCommandEffectProof(for: prepared)
                : nil,
            at: now
        )
        try failureInjector(.afterProjectArchiveSave)
        try ledgerFile.save(ledger)
        try failureInjector(.afterLedgerSave)
        try removePreparedCommand(at: preparedCommandURL)
        try publishWatchSyncMetadata(preparedCommand: nil, processedLedger: ledger)
        try failureInjector(.afterPreparedCommandDeletion)
        return acknowledgement
    }

    public func completeWatchQueueHandshake(
        queuedCommandIDs: [UUID],
        entitlement: EntitlementSnapshot = .permanentlyUnlocked,
        ledgerURL: URL,
        now: Date = .now
    ) throws {
        try requireWatchEntitlement(entitlement, now: now)
        try authorizeWatchCounterMutation()
        let ledgerFile = AtomicWatchSyncFile<ProcessedWatchCommandLedger>(url: ledgerURL)
        var ledger = try loadLedgerRecoveringCorruption(from: ledgerFile)
        for id in queuedCommandIDs where !ledger.contains(id) {
            ledger.record(id, at: now)
        }
        if ledger.requiresFreshHandshake {
            ledger.markHandshakeComplete()
        }
        try ledgerFile.save(ledger)
    }

    public func reconcileWatchQueueHandshakeDurably(
        queuedCommandIDs: [UUID],
        entitlement: EntitlementSnapshot = .permanentlyUnlocked,
        ledgerURL: URL,
        preparedCommandURL: URL,
        now: Date = .now
    ) throws -> WatchCommandRecoveryState {
        try requireWatchEntitlement(entitlement, now: now)
        try authorizeWatchCounterMutation()
        let ledgerFile = AtomicWatchSyncFile<ProcessedWatchCommandLedger>(url: ledgerURL)
        var ledger = try loadLedgerRecoveringCorruption(from: ledgerFile)
        guard ledger.requiresFreshHandshake else { return .ready }

        let preparedFile = AtomicWatchSyncFile<PreparedWatchCommand>(url: preparedCommandURL)
        let prepared: PreparedWatchCommand?
        do {
            prepared = try preparedFile.load()
        } catch {
            try preparedFile.quarantineCorruptFile()
            prepared = nil
        }

        let queuedIDs = Set(queuedCommandIDs)
        if let prepared, !queuedIDs.contains(prepared.command.id) {
            // This receipt cannot be correlated with work the Watch can replay.
            // Move it aside before clearing the handshake so recovery cannot loop.
            try preparedFile.quarantineCorruptFile()
        }

        for id in queuedCommandIDs where !ledger.contains(id) {
            ledger.record(id, at: now)
        }
        ledger.markHandshakeComplete()
        try ledgerFile.save(ledger)

        if let prepared, queuedIDs.contains(prepared.command.id) {
            try removePreparedCommand(at: preparedCommandURL)
        }
        return .ready
    }

    func loadLedgerRecoveringCorruption(
        from file: AtomicWatchSyncFile<ProcessedWatchCommandLedger>
    ) throws -> ProcessedWatchCommandLedger {
        do {
            return try file.load() ?? ProcessedWatchCommandLedger()
        } catch {
            try file.quarantineCorruptFile()
            let ledger = ProcessedWatchCommandLedger(requiresFreshHandshake: true)
            try file.save(ledger)
            return ledger
        }
    }

    private func requireFreshHandshake(
        ledger: inout ProcessedWatchCommandLedger,
        file: AtomicWatchSyncFile<ProcessedWatchCommandLedger>
    ) throws {
        ledger.markRequiresFreshHandshake()
        try file.save(ledger)
    }

    private func removePreparedCommand(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func watchCommandEffectProof(
        for prepared: PreparedWatchCommand
    ) -> ProcessedWatchCommandEffectProof? {
        guard let project = project(id: prepared.command.projectID),
              let counter = project.counters.first(where: {
                  $0.id == prepared.command.counterID
              }) else { return nil }
        let reminder = prepared.expectedReminderID.flatMap { reminderID in
            project.knittingReminders.first { $0.id == reminderID }
        }
        return ProcessedWatchCommandEffectProof(counter: counter, reminder: reminder)
    }
}

private extension PreparedWatchCommand {
    func hasExpectedReminderState(in project: StoredProject, counterID: UUID) -> Bool {
        guard let expectedReminderID,
              let expectedOccurrenceID,
              let expectedReminderRevision,
              expectedReminderOutcome != nil
        else {
            return command.reminderPayload == nil
        }
        return project.knittingReminders.contains { reminder in
            reminder.id == expectedReminderID
                && reminder.counterID == counterID
                && reminder.mutationRevision == expectedReminderRevision
                && reminder.progress.pending.contains(where: { $0.id == expectedOccurrenceID })
        }
    }

    func reminderMutationWasApplied(in project: StoredProject, counterID: UUID) -> Bool {
        guard let expectedReminderID,
              let expectedOccurrenceID,
              let expectedReminderRevision,
              let expectedReminderOutcome
        else { return false }
        let (nextRevision, overflow) = expectedReminderRevision.addingReportingOverflow(1)
        guard !overflow else { return false }
        guard let reminder = project.knittingReminders.first(where: {
            $0.id == expectedReminderID
                && $0.counterID == counterID
                && $0.mutationRevision == nextRevision
        }) else { return false }
        switch command.operation {
        case .completeReminder:
            return expectedReminderOutcome.action == .complete
                && reminder.progress.completedCount == expectedReminderOutcome.completedCount
                && reminder.progress.skippedCount == expectedReminderOutcome.skippedCount
                && reminder.progress.latestHandled?.id == expectedOccurrenceID
        case .deferReminderOnce:
            return expectedReminderOutcome.action == .deferOnce
                && reminder.progress.completedCount == expectedReminderOutcome.completedCount
                && reminder.progress.skippedCount == expectedReminderOutcome.skippedCount
                && reminder.progress.pending.contains {
                    $0.id == expectedOccurrenceID
                        && $0.phase == .deferredOnce
                        && $0.awaitsNextUpwardChange
                        && $0.displayAt == expectedReminderOutcome.deferredDisplayAt
                }
        case .skipReminder:
            return expectedReminderOutcome.action == .skip
                && reminder.progress.completedCount == expectedReminderOutcome.completedCount
                && reminder.progress.skippedCount == expectedReminderOutcome.skippedCount
                && reminder.progress.latestHandled?.id == expectedOccurrenceID
        case .increment, .decrement, .reset, .stopReminder:
            return false
        }
    }

    var isCounterOperation: Bool {
        switch command.operation {
        case .increment, .decrement, .reset:
            true
        case .completeReminder, .deferReminderOnce, .skipReminder, .stopReminder:
            false
        }
    }

    var isAcceptedNoOp: Bool {
        guard let expectedCounterValue else { return false }
        return switch command.operation {
        case .increment:
            expectedCounterValue == Int.max
        case .decrement, .reset:
            expectedCounterValue == 0
        case .completeReminder, .stopReminder:
            false
        case .deferReminderOnce, .skipReminder:
            false
        }
    }
}
