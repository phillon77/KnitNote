import Foundation

public enum CounterReminderRule: Codable, Hashable, Sendable {
    case oneTime(target: Int)
    case repeating(interval: Int, limit: Int?)
}

public enum CounterReminderDraft: Equatable, Sendable {
    case oneTime(target: Int, message: String?)
    case repeating(interval: Int, limit: Int?, message: String?)
}

public enum CounterReminderEdit: Equatable, Sendable {
    case unchanged
    case replace(CounterReminderDraft)
    case remove(expectedReminderID: UUID?)
}

public struct CounterReminderPending: Codable, Hashable, Sendable {
    public let reminderID: UUID
    public let occurrenceCount: Int
    public let firstTarget: Int
    public let lastTarget: Int
}

public struct CounterReminder: Codable, Hashable, Sendable {
    public let id: UUID
    public let anchorValue: Int
    public private(set) var rule: CounterReminderRule
    public private(set) var message: String?
    public private(set) var acknowledgedCount: Int
    public private(set) var nextTarget: Int?
    public private(set) var pending: CounterReminderPending?
    public private(set) var isActive: Bool
    public private(set) var mutationRevision: UInt64

    public init?(draft: CounterReminderDraft, anchorValue: Int, id: UUID = UUID()) {
        let rule: CounterReminderRule
        let message: String?
        switch draft {
        case let .oneTime(target, draftMessage):
            rule = .oneTime(target: target)
            message = draftMessage
        case let .repeating(interval, limit, draftMessage):
            rule = .repeating(interval: interval, limit: limit)
            message = draftMessage
        }

        guard Self.isValid(rule: rule, anchorValue: anchorValue, acknowledgedCount: 0),
              let nextTarget = Self.initialTarget(for: rule, anchorValue: anchorValue)
        else { return nil }

        self.id = id
        self.anchorValue = anchorValue
        self.rule = rule
        self.message = message
        self.acknowledgedCount = 0
        self.nextTarget = nextTarget
        self.pending = nil
        self.isActive = true
        self.mutationRevision = 0
    }

    static func isValid(_ reminder: CounterReminder) -> Bool {
        guard reminder.anchorValue >= 0,
              Self.isValid(
                  rule: reminder.rule,
                  anchorValue: reminder.anchorValue,
                  acknowledgedCount: reminder.acknowledgedCount
              )
        else { return false }

        if let pending = reminder.pending {
            guard pending.reminderID == reminder.id,
                  pending.occurrenceCount > 0,
                  pending.firstTarget <= pending.lastTarget
            else { return false }
        }
        return true
    }

    private static func isValid(
        rule: CounterReminderRule,
        anchorValue: Int,
        acknowledgedCount: Int
    ) -> Bool {
        guard anchorValue >= 0, acknowledgedCount >= 0 else { return false }
        switch rule {
        case let .oneTime(target):
            return target > anchorValue && acknowledgedCount <= 1
        case let .repeating(interval, limit):
            let (_, overflow) = anchorValue.addingReportingOverflow(interval)
            guard interval > 0, !overflow else {
                return false
            }
            return limit.map { $0 > 0 && acknowledgedCount <= $0 } ?? true
        }
    }

    private static func initialTarget(for rule: CounterReminderRule, anchorValue: Int) -> Int? {
        switch rule {
        case let .oneTime(target):
            return target > anchorValue ? target : nil
        case let .repeating(interval, _):
            let (target, overflow) = anchorValue.addingReportingOverflow(interval)
            return overflow ? nil : target
        }
    }

    mutating func applyUpwardChange(to newValue: Int) -> CounterReminderPending? {
        guard isActive else { return nil }

        var firstTarget: Int?
        var lastTarget: Int?
        var occurrenceCount = 0

        while let target = nextTarget, target <= newValue {
            if let limit = rule.limit, acknowledgedCount + pendingOccurrenceCount + occurrenceCount >= limit {
                nextTarget = nil
                break
            }

            firstTarget = firstTarget ?? target
            lastTarget = target
            occurrenceCount += 1
            nextTarget = followingTarget(after: target)
        }

        guard let firstTarget, let lastTarget else { return nil }

        let newlyPending: CounterReminderPending
        if let pending {
            newlyPending = CounterReminderPending(
                reminderID: id,
                occurrenceCount: pending.occurrenceCount + occurrenceCount,
                firstTarget: pending.firstTarget,
                lastTarget: lastTarget
            )
        } else {
            newlyPending = CounterReminderPending(
                reminderID: id,
                occurrenceCount: occurrenceCount,
                firstTarget: firstTarget,
                lastTarget: lastTarget
            )
        }
        pending = newlyPending
        mutationRevision &+= 1
        return newlyPending
    }

    mutating func completePending(id: UUID, observedCount: Int) -> Bool {
        guard id == self.id,
              let pending,
              observedCount == pending.occurrenceCount
        else { return false }

        acknowledgedCount += pending.occurrenceCount
        self.pending = nil
        if nextTarget == nil { isActive = false }
        mutationRevision &+= 1
        return true
    }

    mutating func stop(id: UUID) -> Bool {
        guard id == self.id, isActive else { return false }
        isActive = false
        pending = nil
        mutationRevision &+= 1
        return true
    }

    private var pendingOccurrenceCount: Int {
        pending?.occurrenceCount ?? 0
    }

    private func followingTarget(after target: Int) -> Int? {
        switch rule {
        case .oneTime:
            return nil
        case let .repeating(interval, _):
            let (next, overflow) = target.addingReportingOverflow(interval)
            return overflow ? nil : next
        }
    }
}

public struct CounterMutationOutcome: Equatable, Sendable {
    public let oldValue: Int
    public let newValue: Int
    public let pendingReminder: CounterReminderPending?
}

public struct CounterReminderEvaluation: Equatable, Sendable {
    public let updatedReminder: CounterReminder
    public let newlyPending: CounterReminderPending?
}

public enum CounterReminderEvaluator {
    public static func applyingUpwardChange(
        from oldValue: Int,
        to newValue: Int,
        reminder: CounterReminder
    ) -> CounterReminderEvaluation {
        var updatedReminder = reminder
        let newlyPending = newValue > oldValue
            ? updatedReminder.applyUpwardChange(to: newValue)
            : nil
        return CounterReminderEvaluation(
            updatedReminder: updatedReminder,
            newlyPending: newlyPending
        )
    }
}

private extension CounterReminderRule {
    var limit: Int? {
        switch self {
        case .oneTime:
            1
        case let .repeating(_, limit):
            limit
        }
    }
}
