import Foundation

public struct WatchOptimisticState: Equatable, Sendable {
    private var authoritativeSnapshot: WatchSyncSnapshot?
    public private(set) var pendingCommands: [WatchCounterCommand]
    public private(set) var selectedProjectID: UUID?
    public private(set) var selectedCounterID: UUID?

    public init(cache: WatchSyncCache) {
        authoritativeSnapshot = cache.snapshot
        // Old cached schema-2 commands lack the identity/revision token added
        // for the temporary card bridge. Drop them rather than delivering a
        // mutation that cannot be proven fresh; the coordinator refreshes the
        // snapshot before enabling a card action.
        pendingCommands = cache.pendingCommands.filter {
            $0.schemaVersion == WatchCounterCommand.currentSchemaVersion
                ? $0.hasValidPayload
                : $0.isTrustedLegacyWatchUICommand
        }
        selectedProjectID = cache.selectedProjectID
        selectedCounterID = cache.selectedCounterID
        repairSelection()
    }

    public var snapshot: WatchSyncSnapshot? {
        pendingCommands.reduce(authoritativeSnapshot) { current, command in
            guard let current else { return nil }
            return Self.applying(command, to: current)
        }
    }

    public var cache: WatchSyncCache {
        WatchSyncCache(
            snapshot: authoritativeSnapshot,
            pendingCommands: pendingCommands,
            selectedProjectID: selectedProjectID,
            selectedCounterID: selectedCounterID
        )
    }

    public var nextPendingCommand: WatchCounterCommand? {
        pendingCommands.first
    }

    public func nextDeliverableCommand(now: Date = .now) -> WatchCounterCommand? {
        guard canMutate(now: now) else { return nil }
        guard let command = nextPendingCommand,
              command.schemaVersion == WatchCounterCommand.currentSchemaVersion
                || command.isTrustedLegacyWatchUICommand
        else { return nil }
        return command
    }

    public var pendingCounterIDs: Set<UUID> {
        Set(pendingCommands.map(\.counterID))
    }

    public func canMutate(now: Date = .now) -> Bool {
        authoritativeSnapshot?.entitlement.canMutate(now: now) == true
    }

    public func hasPending(projectID: UUID, counterID: UUID) -> Bool {
        pendingCommands.contains {
            $0.projectID == projectID && $0.counterID == counterID
        }
    }

    @discardableResult
    public mutating func makeAndEnqueue(
        projectID: UUID,
        counterID: UUID,
        operation: WatchCounterOperation,
        reminderPayload: WatchReminderActionPayload? = nil,
        id: UUID = UUID(),
        createdAt: Date = .now
    ) throws -> WatchCounterCommand {
        let command = try WatchCounterCommand(
            validating: WatchCounterCommand.currentSchemaVersion,
            id: id,
            projectID: projectID,
            counterID: counterID,
            operation: operation,
            reminderPayload: reminderPayload,
            createdAt: createdAt
        )
        _ = enqueue(command)
        return command
    }

    @discardableResult
    public mutating func enqueue(
        _ command: WatchCounterCommand,
        now: Date = .now
    ) -> WatchCommandRejection? {
        let isCurrentCommand = command.schemaVersion == WatchCounterCommand.currentSchemaVersion
        let isLegacyCompatibilityCommand = command.isTrustedLegacyWatchUICommand
        guard isCurrentCommand || isLegacyCompatibilityCommand else {
            return .unsupportedSchema
        }
        guard command.hasValidPayload else { return .unsupportedSchema }
        guard canMutate(now: now) else { return .entitlementRequired }
        guard let project = snapshot?.projects.first(where: {
            $0.id == command.projectID
        }) else {
            return .projectMissing
        }
        guard !project.isCompleted else { return .projectCompleted }
        guard let counter = project.counters.first(where: { $0.id == command.counterID }) else {
            return .counterMissing
        }
        switch command.operation {
        case .increment, .decrement, .reset:
            break
        case .completeReminder, .deferReminderOnce, .skipReminder:
            // A counter mutation serialised before this command can change both
            // visibility and Core's reminder revision. Never transmit a payload
            // that is already known stale against that earlier command.
            guard !pendingCommands.contains(where: {
                $0.projectID == command.projectID && $0.counterID == command.counterID &&
                ($0.operation == .increment || $0.operation == .decrement || $0.operation == .reset)
            }) else { return .pendingCounterMutation }
            if isLegacyCompatibilityCommand {
                guard let reminderID = command.reminderID,
                      let occurrenceID = command.legacyOccurrenceIDForCompatibility,
                      let revision = command.legacyObservedMutationRevisionForCompatibility,
                      let observedCount = command.observedPendingCount,
                      let reminder = project.knittingReminders.first(where: {
                          $0.id == reminderID && $0.counterID == counter.id
                      }),
                      reminder.mutationRevision == revision,
                      reminder.visibleOccurrences(at: counter.value).count == observedCount,
                      reminder.visibleOccurrences(at: counter.value).contains(where: { $0.id == occurrenceID }),
                      !pendingCommands.contains(where: { $0.reminderID == reminderID })
                else { return .reminderMismatch }
            } else {
                guard let payload = command.reminderPayload,
                      let reminder = project.knittingReminders.first(where: {
                          $0.id == payload.reminderID && $0.counterID == counter.id
                      }),
                      reminder.mutationRevision == payload.observedRevision,
                      reminder.visibleOccurrences(at: counter.value).contains(where: {
                          $0.id == payload.occurrenceID
                      }),
                      !pendingCommands.contains(where: {
                          $0.reminderPayload?.reminderID == payload.reminderID
                      })
                else { return .reminderMismatch }
            }
        case .stopReminder:
            guard isLegacyCompatibilityCommand,
                  let reminderID = command.reminderID,
                  let occurrenceID = command.legacyOccurrenceIDForCompatibility,
                  let revision = command.legacyObservedMutationRevisionForCompatibility,
                  let reminder = project.knittingReminders.first(where: {
                      $0.id == reminderID && $0.counterID == counter.id
                  }),
                  reminder.mutationRevision == revision,
                  reminder.visibleOccurrences(at: counter.value).contains(where: { $0.id == occurrenceID }),
                  !pendingCommands.contains(where: { $0.reminderID == reminderID })
            else { return .reminderMismatch }
        }
        guard !pendingCommands.contains(where: { $0.id == command.id }) else { return nil }

        pendingCommands.append(command)
        return nil
    }

    @discardableResult
    public mutating func acknowledge(_ acknowledgement: WatchCommandAcknowledgement) -> Bool {
        guard pendingCommands.first?.id == acknowledgement.commandID else {
            return false
        }
        pendingCommands.removeFirst()
        if authoritativeSnapshot.map({
            acknowledgement.snapshot.generatedAt >= $0.generatedAt
        }) ?? true {
            authoritativeSnapshot = acknowledgement.snapshot
        }
        repairSelection()
        return true
    }

    public mutating func replaceSnapshot(_ snapshot: WatchSyncSnapshot) {
        guard authoritativeSnapshot.map({
            snapshot.generatedAt >= $0.generatedAt
        }) ?? true else { return }
        authoritativeSnapshot = snapshot
        repairSelection()
    }

    @discardableResult
    public mutating func selectProject(_ projectID: UUID?) -> Bool {
        guard let projectID else {
            repairSelection()
            return true
        }
        guard let project = authoritativeSnapshot?.projects.first(where: { $0.id == projectID }) else {
            return false
        }
        selectedProjectID = project.id
        selectedCounterID = project.selectedCounterID
        return true
    }

    @discardableResult
    public mutating func selectCounter(_ counterID: UUID?) -> Bool {
        guard let projectID = selectedProjectID,
              let project = authoritativeSnapshot?.projects.first(where: { $0.id == projectID })
        else {
            return false
        }
        guard let counterID else {
            selectedCounterID = project.selectedCounterID
            return true
        }
        guard project.counters.contains(where: { $0.id == counterID }) else { return false }
        selectedCounterID = counterID
        return true
    }

    public func displayedValue(projectID: UUID, counterID: UUID) -> Int? {
        snapshot?.projects
            .first(where: { $0.id == projectID })?.counters
            .first(where: { $0.id == counterID })?.value
    }

    private mutating func repairSelection() {
        let validated = WatchSyncCache(
            snapshot: authoritativeSnapshot,
            pendingCommands: pendingCommands,
            selectedProjectID: selectedProjectID,
            selectedCounterID: selectedCounterID
        )
        selectedProjectID = validated.selectedProjectID
        selectedCounterID = validated.selectedCounterID
    }

    private static func applying(
        _ command: WatchCounterCommand,
        to snapshot: WatchSyncSnapshot
    ) -> WatchSyncSnapshot {
        let projects = snapshot.projects.map { project in
            guard project.id == command.projectID,
                  !project.isCompleted,
                  project.counters.contains(where: { $0.id == command.counterID })
            else {
                return project
            }

            let counters = project.counters.map { counter in
                guard counter.id == command.counterID else { return counter }
                var value = counter.value
                switch command.operation {
                case .increment:
                    let result = counter.value.addingReportingOverflow(1)
                    if !result.overflow { value = result.partialValue }
                case .decrement:
                    let result = counter.value.subtractingReportingOverflow(1)
                    value = result.overflow ? counter.value : max(0, result.partialValue)
                case .reset:
                    value = 0
                case .completeReminder, .deferReminderOnce, .skipReminder, .stopReminder:
                    break
                }
                return WatchCounterSnapshot(id: counter.id, name: counter.name, value: value, reminder: counter.reminder)
            }

            let oldCounterValue = project.counters.first(where: { $0.id == command.counterID })?.value
            let newCounterValue = counters.first(where: { $0.id == command.counterID })?.value
            let reminders = applyingReminderCommand(command, project: project, counters: counters, didIncrease: oldCounterValue.map { old in newCounterValue.map { $0 > old } ?? false } ?? false)

            return (try? WatchProjectSnapshot(
                id: project.id,
                name: project.name,
                isCompleted: project.isCompleted,
                updatedAt: project.updatedAt,
                counters: counters,
                selectedCounterID: project.selectedCounterID,
                knittingReminders: reminders
            )) ?? project
        }

        return WatchSyncSnapshot(
            schemaVersion: snapshot.schemaVersion,
            generatedAt: snapshot.generatedAt,
            entitlement: snapshot.entitlement,
            projects: projects,
            languageCode: snapshot.languageCode
        )
    }

    private static func applyingReminderCommand(
        _ command: WatchCounterCommand,
        project: WatchProjectSnapshot,
        counters: [WatchCounterSnapshot],
        didIncrease: Bool
    ) -> [WatchKnittingReminderSnapshot] {
        guard let counter = counters.first(where: { $0.id == command.counterID }) else {
            return project.knittingReminders
        }
        if command.operation == .increment, didIncrease {
            return project.knittingReminders.map { reminder in
                guard reminder.counterID == counter.id else { return reminder }
                var projected = reminder
                for index in projected.pending.indices where projected.pending[index].awaitsNextUpwardChange {
                    projected.pending[index].awaitsNextUpwardChange = false
                    projected.pending[index].displayAt = counter.value
                }
                return projected
            }
        }
        guard let payload = command.reminderPayload else { return project.knittingReminders }

        return project.knittingReminders.map { reminder in
            guard reminder.id == payload.reminderID,
                  reminder.counterID == counter.id,
                  reminder.mutationRevision == payload.observedRevision,
                  let occurrenceIndex = reminder.visibleOccurrences(at: counter.value).firstIndex(where: {
                      $0.id == payload.occurrenceID
                  }),
                  let pendingIndex = reminder.pending.firstIndex(where: {
                      $0.id == reminder.visibleOccurrences(at: counter.value)[occurrenceIndex].id
                  })
            else { return reminder }

            var projected = reminder
            switch command.operation {
            case .completeReminder, .skipReminder:
                let updatedCount = (command.operation == .completeReminder ? projected.completedCount : projected.skippedCount).addingReportingOverflow(1)
                guard !updatedCount.overflow else { return reminder }
                projected.pending.remove(at: pendingIndex)
                if command.operation == .completeReminder {
                    projected.completedCount = updatedCount.partialValue
                } else {
                    projected.skippedCount = updatedCount.partialValue
                }
                if projected.pending.isEmpty, projected.nextTarget == nil {
                    projected.state = .completed
                }
            case .deferReminderOnce:
                guard projected.pending[pendingIndex].phase == .initial,
                      counter.value < Int.max
                else { return reminder }
                projected.pending[pendingIndex].displayAt = counter.value + 1
                projected.pending[pendingIndex].phase = .deferredOnce
                projected.pending[pendingIndex].awaitsNextUpwardChange = true
            case .increment, .decrement, .reset, .stopReminder:
                return reminder
            }
            return projected
        }
    }
}

public struct WatchHeadDeliveryState: Equatable, Sendable {
    public private(set) var headCommandID: UUID?
    public private(set) var interactiveAttemptID: UUID?
    private var backgroundTransferPrepared = false

    public init() {}

    public mutating func prepareBackgroundTransfer(for commandID: UUID) -> Bool {
        if let headCommandID {
            guard headCommandID == commandID else { return false }
        } else {
            headCommandID = commandID
        }
        guard !backgroundTransferPrepared else { return false }
        backgroundTransferPrepared = true
        return true
    }

    public mutating func beginInteractiveDelivery(
        for commandID: UUID,
        attemptID: UUID = UUID()
    ) -> UUID? {
        guard headCommandID == commandID, interactiveAttemptID == nil else { return nil }
        interactiveAttemptID = attemptID
        return attemptID
    }

    @discardableResult
    public mutating func failBackgroundTransfer(for commandID: UUID) -> Bool {
        guard headCommandID == commandID, backgroundTransferPrepared else { return false }
        backgroundTransferPrepared = false
        return true
    }

    @discardableResult
    public mutating func finishInteractiveDelivery(
        commandID: UUID,
        attemptID: UUID
    ) -> Bool {
        guard headCommandID == commandID, interactiveAttemptID == attemptID else { return false }
        interactiveAttemptID = nil
        return true
    }

    public mutating func cancelInteractiveDelivery() {
        interactiveAttemptID = nil
    }

    @discardableResult
    public mutating func acknowledge(_ commandID: UUID) -> Bool {
        guard headCommandID == commandID else { return false }
        self = WatchHeadDeliveryState()
        return true
    }
}
