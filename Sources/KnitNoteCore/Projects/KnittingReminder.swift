import Foundation

public enum KnittingReminderKind: String, Codable, CaseIterable, Hashable, Sendable {
    case increase, decrease, changeYarn, cable, buttonhole, measure, custom
}

public enum KnittingReminderRule: Codable, Hashable, Sendable {
    case oneTime(target: Int)
    case repeating(firstTarget: Int, interval: Int, limit: Int?)
}

public enum KnittingReminderOccurrencePhase: String, Codable, Hashable, Sendable {
    case initial, deferredOnce
}

public struct KnittingReminderOccurrence: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let reminderID: UUID
    public let kind: KnittingReminderKind
    public let text: String?
    public let originalTarget: Int
    public var displayAt: Int
    public var phase: KnittingReminderOccurrencePhase
}

public enum KnittingReminderAction: Sendable {
    case complete, deferOnce, skip, stop, resetLatest
}

public enum KnittingReminderDraft: Equatable, Sendable {
    case oneTime(kind: KnittingReminderKind, target: Int, text: String?)
    case repeating(
        kind: KnittingReminderKind,
        firstTarget: Int,
        interval: Int,
        limit: Int?,
        text: String?
    )
}

public enum KnittingReminderState: String, Codable, Hashable, Sendable {
    case active, completed, stopped
}

public struct KnittingReminderProgress: Codable, Hashable, Sendable {
    public private(set) var scheduledCount: Int
    public private(set) var completedCount: Int
    public private(set) var skippedCount: Int
    public private(set) var nextTarget: Int?
    public private(set) var pending: [KnittingReminderOccurrence]
    public private(set) var latestHandled: KnittingReminderOccurrence?

    init(nextTarget: Int?) {
        scheduledCount = 0
        completedCount = 0
        skippedCount = 0
        self.nextTarget = nextTarget
        pending = []
        latestHandled = nil
    }

    mutating func schedule(
        _ occurrence: KnittingReminderOccurrence,
        scheduledCount: Int,
        nextTarget: Int?
    ) {
        pending.append(occurrence)
        self.scheduledCount = scheduledCount
        self.nextTarget = nextTarget
    }

    mutating func stopScheduling() {
        nextTarget = nil
    }

    mutating func clearPending() {
        pending.removeAll()
    }

    mutating func replacePending(_ occurrence: KnittingReminderOccurrence) {
        guard let index = pending.firstIndex(where: { $0.id == occurrence.id }) else { return }
        pending[index] = occurrence
    }

    mutating func removePending(id: UUID, wasSkipped: Bool) throws -> KnittingReminderOccurrence? {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return nil }
        let (updatedCount, overflow) = (wasSkipped ? skippedCount : completedCount).addingReportingOverflow(1)
        guard !overflow else { throw KnittingReminderMutationError.arithmeticOverflow }
        let occurrence = pending.remove(at: index)
        if wasSkipped { skippedCount = updatedCount } else { completedCount = updatedCount }
        latestHandled = occurrence
        return occurrence
    }

    mutating func resetLatest() -> KnittingReminderOccurrence? {
        guard let latestHandled else { return nil }
        let occurrence = KnittingReminderOccurrence(
            id: UUID(),
            reminderID: latestHandled.reminderID,
            kind: latestHandled.kind,
            text: latestHandled.text,
            originalTarget: latestHandled.originalTarget,
            displayAt: latestHandled.originalTarget,
            phase: .initial
        )
        pending.append(occurrence)
        self.latestHandled = nil
        return occurrence
    }

    var hasPendingOccurrences: Bool {
        !pending.isEmpty
    }
}

public enum KnittingReminderMutation: Equatable, Sendable {
    case trigger(through: Int)
    case complete(occurrenceID: UUID, observedRevision: UInt64)
    case deferOnce(occurrenceID: UUID, observedRevision: UInt64)
    case skip(occurrenceID: UUID, observedRevision: UInt64)
    case stop(observedRevision: UInt64)
    case resetLatest(observedRevision: UInt64)
}

public enum KnittingReminderMutationError: Error, Equatable, Sendable {
    case invalidDraft
    case staleRevision
    case occurrenceNotFound
    case alreadyDeferred
    case invalidAction
    case arithmeticOverflow
    case newReminderRequiresMainCounter
}

public struct KnittingReminderEvaluationResult: Equatable, Sendable {
    public let reminders: [KnittingReminder]
    public let pending: [KnittingReminderOccurrence]
}

public struct KnittingReminder: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let counterID: UUID
    public private(set) var kind: KnittingReminderKind
    public private(set) var text: String?
    public private(set) var rule: KnittingReminderRule
    public private(set) var progress: KnittingReminderProgress
    public private(set) var state: KnittingReminderState
    public private(set) var mutationRevision: UInt64
    public let createdAt: Date

    public init?(
        id: UUID = UUID(),
        counterID: UUID,
        draft: KnittingReminderDraft,
        createdAt: Date
    ) {
        let kind: KnittingReminderKind
        let text: String?
        let rule: KnittingReminderRule

        switch draft {
        case let .oneTime(draftKind, target, draftText):
            guard target >= 0 else { return nil }
            kind = draftKind
            text = draftText
            rule = .oneTime(target: target)
        case let .repeating(draftKind, firstTarget, interval, limit, draftText):
            guard firstTarget >= 0, interval > 0, limit.map({ $0 > 0 }) ?? true else {
                return nil
            }
            kind = draftKind
            text = draftText
            rule = .repeating(firstTarget: firstTarget, interval: interval, limit: limit)
        }

        self.id = id
        self.counterID = counterID
        self.kind = kind
        self.text = text
        self.rule = rule
        progress = KnittingReminderProgress(nextTarget: rule.initialTarget)
        state = .active
        mutationRevision = 0
        self.createdAt = createdAt
    }

    public func applying(_ mutation: KnittingReminderMutation) throws -> KnittingReminder {
        var copy = self
        switch mutation {
        case let .trigger(through):
            copy.trigger(through: through)
        case let .complete(occurrenceID, observedRevision):
            try copy.handle(
                occurrenceID: occurrenceID,
                observedRevision: observedRevision,
                wasSkipped: false
            )
        case let .deferOnce(occurrenceID, observedRevision):
            try copy.deferOnce(occurrenceID: occurrenceID, observedRevision: observedRevision)
        case let .skip(occurrenceID, observedRevision):
            try copy.handle(
                occurrenceID: occurrenceID,
                observedRevision: observedRevision,
                wasSkipped: true
            )
        case let .stop(observedRevision):
            try copy.stop(observedRevision: observedRevision)
        case let .resetLatest(observedRevision):
            try copy.resetLatest(observedRevision: observedRevision)
        }
        return copy
    }

    public func visibleOccurrences(at counterValue: Int) -> [KnittingReminderOccurrence] {
        progress.pending.filter { occurrence in
            occurrence.phase == .initial || occurrence.displayAt <= counterValue
        }
    }

    private mutating func trigger(through counterValue: Int) {
        guard state == .active else { return }

        var didSchedule = false
        while let scheduledTarget = progress.nextTarget, scheduledTarget <= counterValue {
            let occurrence = KnittingReminderOccurrence(
                id: UUID(),
                reminderID: id,
                kind: kind,
                text: text,
                originalTarget: scheduledTarget,
                displayAt: scheduledTarget,
                phase: .initial
            )
            let (scheduledCount, countOverflow) = progress.scheduledCount.addingReportingOverflow(1)
            guard !countOverflow else {
                progress.stopScheduling()
                break
            }
            let (nextOccurrence, nextOccurrenceOverflow) = scheduledCount.addingReportingOverflow(1)
            progress.schedule(
                occurrence,
                scheduledCount: scheduledCount,
                nextTarget: nextOccurrenceOverflow ? nil : target(forOccurrence: nextOccurrence)
            )
            didSchedule = true
        }
        if didSchedule { mutationRevision &+= 1 }
    }

    private mutating func handle(
        occurrenceID: UUID,
        observedRevision: UInt64,
        wasSkipped: Bool
    ) throws {
        try validate(observedRevision: observedRevision)
        guard try progress.removePending(id: occurrenceID, wasSkipped: wasSkipped) != nil else {
            throw KnittingReminderMutationError.occurrenceNotFound
        }
        if !progress.hasPendingOccurrences, progress.nextTarget == nil {
            state = .completed
        }
        mutationRevision &+= 1
    }

    private mutating func deferOnce(occurrenceID: UUID, observedRevision: UInt64) throws {
        try validate(observedRevision: observedRevision)
        guard var occurrence = progress.pending.first(where: { $0.id == occurrenceID }) else {
            throw KnittingReminderMutationError.occurrenceNotFound
        }
        guard occurrence.phase == .initial else {
            throw KnittingReminderMutationError.alreadyDeferred
        }
        let (displayAt, overflow) = occurrence.originalTarget.addingReportingOverflow(1)
        guard !overflow else { throw KnittingReminderMutationError.arithmeticOverflow }
        occurrence.displayAt = displayAt
        occurrence.phase = .deferredOnce
        progress.replacePending(occurrence)
        mutationRevision &+= 1
    }

    private mutating func stop(observedRevision: UInt64) throws {
        try validate(observedRevision: observedRevision)
        guard state == .active else { throw KnittingReminderMutationError.invalidAction }
        progress.stopScheduling()
        progress.clearPending()
        state = .stopped
        mutationRevision &+= 1
    }

    private mutating func resetLatest(observedRevision: UInt64) throws {
        try validateRevision(observedRevision)
        guard progress.resetLatest() != nil else { throw KnittingReminderMutationError.invalidAction }
        state = .active
        mutationRevision &+= 1
    }

    private func validate(observedRevision: UInt64) throws {
        try validateRevision(observedRevision)
        guard state != .stopped else { throw KnittingReminderMutationError.invalidAction }
    }

    private func validateRevision(_ observedRevision: UInt64) throws {
        guard observedRevision == mutationRevision else { throw KnittingReminderMutationError.staleRevision }
    }

    private func target(forOccurrence occurrence: Int) -> Int? {
        guard occurrence > 0 else { return nil }
        switch rule {
        case let .oneTime(target):
            return occurrence == 1 ? target : nil
        case let .repeating(firstTarget, interval, limit):
            guard limit.map({ occurrence <= $0 }) ?? true else { return nil }
            let (offset, multiplyOverflow) = interval.multipliedReportingOverflow(by: occurrence - 1)
            guard !multiplyOverflow else { return nil }
            let (target, addOverflow) = firstTarget.addingReportingOverflow(offset)
            return addOverflow ? nil : target
        }
    }
}

public enum KnittingReminderEvaluator {
    public static func evaluate(
        oldValue: Int,
        newValue: Int,
        reminders: [KnittingReminder]
    ) -> KnittingReminderEvaluationResult {
        guard newValue > oldValue else {
            return KnittingReminderEvaluationResult(reminders: reminders, pending: [])
        }

        var pendingWithOrdering = [(occurrence: KnittingReminderOccurrence, createdAt: Date)]()
        let updatedReminders = reminders.map { reminder -> KnittingReminder in
            let pendingIDs = Set(reminder.progress.pending.map(\.id))
            guard let updated = try? reminder.applying(.trigger(through: newValue)) else {
                return reminder
            }
            pendingWithOrdering += updated.progress.pending
                .filter { !pendingIDs.contains($0.id) }
                .map { ($0, updated.createdAt) }
            return updated
        }

        let pending = pendingWithOrdering
            .sorted {
                if $0.occurrence.originalTarget != $1.occurrence.originalTarget {
                    return $0.occurrence.originalTarget < $1.occurrence.originalTarget
                }
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.occurrence.reminderID.uuidString < $1.occurrence.reminderID.uuidString
            }
            .map(\.occurrence)

        return KnittingReminderEvaluationResult(reminders: updatedReminders, pending: pending)
    }
}

private extension KnittingReminderRule {
    var initialTarget: Int {
        switch self {
        case let .oneTime(target):
            target
        case let .repeating(firstTarget, _, _):
            firstTarget
        }
    }
}
