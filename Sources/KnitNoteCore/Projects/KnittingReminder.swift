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
    public var awaitsNextUpwardChange: Bool
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

public enum KnittingReminderDraftValidationIssue: Equatable, Sendable {
    case firstTarget
    case interval
    case limit
}

public enum KnittingReminderDraftValidation {
    public static func issue(
        firstTarget: Int?,
        isRepeating: Bool,
        interval: Int?,
        hasFiniteLimit: Bool,
        limit: Int?
    ) -> KnittingReminderDraftValidationIssue? {
        guard let firstTarget, firstTarget >= 0 else { return .firstTarget }
        guard isRepeating else { return nil }
        guard let interval, interval >= 1 else { return .interval }
        guard !hasFiniteLimit || (limit.map { $0 >= 1 } ?? false) else { return .limit }
        return nil
    }
}

public enum KnittingReminderState: String, Codable, Hashable, Sendable {
    case active, completed, stopped
}

public struct KnittingReminderProgress: Codable, Hashable, Sendable {
    public private(set) var scheduledCount: Int
    public private(set) var completedCount: Int
    public private(set) var skippedCount: Int
    public private(set) var nextTarget: Int?
    public private(set) var nextOccurrenceIndex: Int
    public private(set) var lastObservedCounterValue: Int?
    public private(set) var pending: [KnittingReminderOccurrence]
    public private(set) var latestHandled: KnittingReminderOccurrence?

    init(nextTarget: Int?) {
        scheduledCount = 0
        completedCount = 0
        skippedCount = 0
        self.nextTarget = nextTarget
        nextOccurrenceIndex = 1
        lastObservedCounterValue = nil
        pending = []
        latestHandled = nil
    }

    mutating func schedule(
        _ occurrence: KnittingReminderOccurrence,
        scheduledCount: Int,
        nextTarget: Int?,
        nextOccurrenceIndex: Int
    ) {
        pending.append(occurrence)
        self.scheduledCount = scheduledCount
        self.nextTarget = nextTarget
        self.nextOccurrenceIndex = nextOccurrenceIndex
    }

    mutating func advanceCandidate(nextTarget: Int?, nextOccurrenceIndex: Int) {
        self.nextTarget = nextTarget
        self.nextOccurrenceIndex = nextOccurrenceIndex
    }

    mutating func recordObservedCounterValue(_ counterValue: Int) -> Bool {
        guard lastObservedCounterValue != counterValue else { return false }
        lastObservedCounterValue = counterValue
        return true
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

    mutating func releaseDeferredOccurrences(at counterValue: Int) -> [UUID] {
        var releasedIDs = [UUID]()
        for index in pending.indices where pending[index].awaitsNextUpwardChange {
            pending[index].awaitsNextUpwardChange = false
            pending[index].displayAt = counterValue
            releasedIDs.append(pending[index].id)
        }
        return releasedIDs
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
            phase: .initial,
            awaitsNextUpwardChange: false
        )
        pending.append(occurrence)
        self.latestHandled = nil
        return occurrence
    }

    var hasPendingOccurrences: Bool {
        !pending.isEmpty
    }

    var hasLatestHandledOccurrence: Bool {
        latestHandled != nil
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
    case revisionExhausted
    case newReminderRequiresMainCounter
}

public struct KnittingReminderEvaluationResult: Equatable, Sendable {
    public let reminders: [KnittingReminder]
    public let pending: [KnittingReminderOccurrence]
    public let rejectedReminderIDs: [UUID]
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

    private enum CodingKeys: String, CodingKey {
        case id, counterID, kind, text, rule, progress, state, mutationRevision, createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let counterID = try container.decode(UUID.self, forKey: .counterID)
        let kind = try container.decode(KnittingReminderKind.self, forKey: .kind)
        let text = try container.decodeIfPresent(String.self, forKey: .text)
        let rule = try container.decode(KnittingReminderRule.self, forKey: .rule)
        let progress = try container.decode(KnittingReminderProgress.self, forKey: .progress)
        let state = try container.decode(KnittingReminderState.self, forKey: .state)
        let mutationRevision = try container.decode(UInt64.self, forKey: .mutationRevision)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)

        self.id = id
        self.counterID = counterID
        self.kind = kind
        self.text = text
        self.rule = rule
        self.progress = progress
        self.state = state
        self.mutationRevision = mutationRevision
        self.createdAt = createdAt

        guard isValidDecodedState else {
            throw DecodingError.dataCorruptedError(
                forKey: .progress,
                in: container,
                debugDescription: "Invalid knitting reminder state"
            )
        }
    }

    public func applying(_ mutation: KnittingReminderMutation) throws -> KnittingReminder {
        var copy = self
        switch mutation {
        case let .trigger(through):
            try copy.trigger(through: through)
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

    public func replacingRule(with draft: KnittingReminderDraft) throws -> KnittingReminder {
        guard mutationRevision < .max else {
            throw KnittingReminderMutationError.revisionExhausted
        }
        guard var replacement = KnittingReminder(
            id: id,
            counterID: counterID,
            draft: draft,
            createdAt: createdAt
        ) else {
            throw KnittingReminderMutationError.invalidDraft
        }
        replacement.mutationRevision = mutationRevision + 1
        return replacement
    }

    public func visibleOccurrences(at counterValue: Int) -> [KnittingReminderOccurrence] {
        progress.pending.filter { occurrence in
            occurrence.phase == .initial
                || (!occurrence.awaitsNextUpwardChange && occurrence.displayAt <= counterValue)
        }
    }

    private mutating func trigger(through counterValue: Int) throws {
        guard state == .active else { return }

        var didChange = false
        while let scheduledTarget = progress.nextTarget, scheduledTarget <= counterValue {
            let occurrence = KnittingReminderOccurrence(
                id: UUID(),
                reminderID: id,
                kind: kind,
                text: text,
                originalTarget: scheduledTarget,
                displayAt: scheduledTarget,
                phase: .initial,
                awaitsNextUpwardChange: false
            )
            let (scheduledCount, countOverflow) = progress.scheduledCount.addingReportingOverflow(1)
            guard !countOverflow else {
                progress.stopScheduling()
                didChange = true
                break
            }
            let (nextTarget, nextOccurrenceIndex) = nextCandidate()
            progress.schedule(
                occurrence,
                scheduledCount: scheduledCount,
                nextTarget: nextTarget,
                nextOccurrenceIndex: nextOccurrenceIndex
            )
            didChange = true
        }
        didChange = progress.recordObservedCounterValue(counterValue) || didChange
        try incrementRevisionIfNeeded(didChange)
    }

    mutating func evaluateCounterChange(from oldValue: Int, to newValue: Int) throws {
        guard state == .active else { return }

        var didChange = false
        if newValue > oldValue {
            didChange = !progress.releaseDeferredOccurrences(at: newValue).isEmpty
            while let staleTarget = progress.nextTarget, staleTarget <= oldValue {
                advanceCandidate()
                didChange = true
            }

            while let scheduledTarget = progress.nextTarget, scheduledTarget <= newValue {
                let occurrence = KnittingReminderOccurrence(
                    id: UUID(),
                    reminderID: id,
                    kind: kind,
                    text: text,
                    originalTarget: scheduledTarget,
                    displayAt: scheduledTarget,
                    phase: .initial,
                    awaitsNextUpwardChange: false
                )
                let (scheduledCount, countOverflow) = progress.scheduledCount.addingReportingOverflow(1)
                guard !countOverflow else {
                    progress.stopScheduling()
                    didChange = true
                    break
                }
                let (nextTarget, nextOccurrenceIndex) = nextCandidate()
                progress.schedule(
                    occurrence,
                    scheduledCount: scheduledCount,
                    nextTarget: nextTarget,
                    nextOccurrenceIndex: nextOccurrenceIndex
                )
                didChange = true
            }
        }

        didChange = progress.recordObservedCounterValue(newValue) || didChange
        try incrementRevisionIfNeeded(didChange)
    }

    private mutating func advanceCandidate() {
        let (nextTarget, nextOccurrenceIndex) = nextCandidate()
        progress.advanceCandidate(nextTarget: nextTarget, nextOccurrenceIndex: nextOccurrenceIndex)
    }

    private func nextCandidate() -> (target: Int?, occurrenceIndex: Int) {
        let (nextOccurrenceIndex, overflow) = progress.nextOccurrenceIndex.addingReportingOverflow(1)
        guard !overflow else { return (nil, progress.nextOccurrenceIndex) }
        return (target(forOccurrence: nextOccurrenceIndex), nextOccurrenceIndex)
    }

    private mutating func handle(
        occurrenceID: UUID,
        observedRevision: UInt64,
        wasSkipped: Bool
    ) throws {
        try validate(observedRevision: observedRevision)
        guard progress.pending.contains(where: { $0.id == occurrenceID }) else {
            throw KnittingReminderMutationError.occurrenceNotFound
        }
        try incrementRevisionIfNeeded(true)
        _ = try progress.removePending(id: occurrenceID, wasSkipped: wasSkipped)
        if !progress.hasPendingOccurrences, progress.nextTarget == nil {
            state = .completed
        }
    }

    private mutating func deferOnce(occurrenceID: UUID, observedRevision: UInt64) throws {
        try validate(observedRevision: observedRevision)
        guard var occurrence = progress.pending.first(where: { $0.id == occurrenceID }) else {
            throw KnittingReminderMutationError.occurrenceNotFound
        }
        guard occurrence.phase == .initial else {
            throw KnittingReminderMutationError.alreadyDeferred
        }
        let observedCounterValue = progress.lastObservedCounterValue ?? occurrence.originalTarget
        let (displayAt, overflow) = observedCounterValue.addingReportingOverflow(1)
        guard !overflow else { throw KnittingReminderMutationError.arithmeticOverflow }
        try incrementRevisionIfNeeded(true)
        occurrence.displayAt = displayAt
        occurrence.phase = .deferredOnce
        occurrence.awaitsNextUpwardChange = true
        progress.replacePending(occurrence)
    }

    private mutating func stop(observedRevision: UInt64) throws {
        try validate(observedRevision: observedRevision)
        guard state == .active else { throw KnittingReminderMutationError.invalidAction }
        try incrementRevisionIfNeeded(true)
        progress.stopScheduling()
        progress.clearPending()
        state = .stopped
    }

    private mutating func resetLatest(observedRevision: UInt64) throws {
        try validateRevision(observedRevision)
        guard progress.hasLatestHandledOccurrence else { throw KnittingReminderMutationError.invalidAction }
        try incrementRevisionIfNeeded(true)
        _ = progress.resetLatest()
        state = .active
    }

    private func validate(observedRevision: UInt64) throws {
        try validateRevision(observedRevision)
        guard state != .stopped else { throw KnittingReminderMutationError.invalidAction }
    }

    private func validateRevision(_ observedRevision: UInt64) throws {
        guard observedRevision == mutationRevision else { throw KnittingReminderMutationError.staleRevision }
    }

    private mutating func incrementRevisionIfNeeded(_ didChange: Bool) throws {
        guard didChange else { return }
        guard mutationRevision < .max else { throw KnittingReminderMutationError.revisionExhausted }
        mutationRevision += 1
    }

    private var isValidDecodedState: Bool {
        let pendingIDs = Set(progress.pending.map(\.id))
        let hasConsistentNextTarget: Bool
        switch state {
        case .active:
            hasConsistentNextTarget = progress.nextTarget == target(forOccurrence: progress.nextOccurrenceIndex)
        case .completed, .stopped:
            hasConsistentNextTarget = progress.nextTarget == nil
        }
        guard rule.isValid,
              progress.scheduledCount >= 0,
              progress.completedCount >= 0,
              progress.skippedCount >= 0,
              progress.nextOccurrenceIndex > 0,
              progress.nextTarget.map({ $0 >= 0 }) ?? true,
              progress.lastObservedCounterValue.map({ $0 >= 0 }) ?? true,
              progress.pending.count <= progress.scheduledCount,
              pendingIDs.count == progress.pending.count,
              progress.pending.allSatisfy(isValidOccurrence),
              progress.latestHandled.map(isValidOccurrence) ?? true,
              progress.latestHandled.map({ !pendingIDs.contains($0.id) }) ?? true,
              progress.pending.allSatisfy({ occurrenceIsScheduledByRule($0) }),
              progress.latestHandled.map(occurrenceIsScheduledByRule) ?? true,
              hasConsistentNextTarget
        else { return false }

        switch state {
        case .active:
            return true
        case .completed, .stopped:
            return progress.nextTarget == nil && progress.pending.isEmpty
        }
    }

    private func isValidOccurrence(_ occurrence: KnittingReminderOccurrence) -> Bool {
        guard occurrence.reminderID == id,
              occurrence.kind == kind,
              occurrence.text == text,
              occurrence.originalTarget >= 0,
              occurrence.displayAt >= 0
        else { return false }

        switch occurrence.phase {
        case .initial:
            return occurrence.displayAt == occurrence.originalTarget && !occurrence.awaitsNextUpwardChange
        case .deferredOnce:
            if occurrence.awaitsNextUpwardChange {
                return occurrence.displayAt > occurrence.originalTarget
            }
            return occurrence.displayAt >= occurrence.originalTarget
        }
    }

    private func occurrenceIsScheduledByRule(_ occurrence: KnittingReminderOccurrence) -> Bool {
        guard let occurrenceIndex = occurrenceIndex(for: occurrence.originalTarget),
              occurrenceIndex < progress.nextOccurrenceIndex else {
            return false
        }
        return true
    }

    private func occurrenceIndex(for target: Int) -> Int? {
        switch rule {
        case let .oneTime(expectedTarget):
            return target == expectedTarget ? 1 : nil
        case let .repeating(firstTarget, interval, limit):
            guard target >= firstTarget else { return nil }
            let difference = target - firstTarget
            guard difference % interval == 0 else { return nil }
            let (index, overflow) = difference.quotientAndRemainder(dividingBy: interval)
                .quotient.addingReportingOverflow(1)
            guard !overflow,
                  limit.map({ index <= $0 }) ?? true else { return nil }
            return index
        }
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
        var pendingWithOrdering = [(occurrence: KnittingReminderOccurrence, createdAt: Date)]()
        var rejectedReminderIDs = [UUID]()
        let updatedReminders = reminders.map { reminder -> KnittingReminder in
            let priorPending = Dictionary(uniqueKeysWithValues: reminder.progress.pending.map { ($0.id, $0) })
            var candidate = reminder
            do {
                try candidate.evaluateCounterChange(from: oldValue, to: newValue)
            } catch {
                rejectedReminderIDs.append(reminder.id)
                return reminder
            }
            let updated = candidate
            pendingWithOrdering += updated.progress.pending
                .filter { occurrence in
                    guard let previous = priorPending[occurrence.id] else { return true }
                    return previous.awaitsNextUpwardChange && !occurrence.awaitsNextUpwardChange
                }
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

        return KnittingReminderEvaluationResult(
            reminders: updatedReminders,
            pending: pending,
            rejectedReminderIDs: rejectedReminderIDs
        )
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

    var isValid: Bool {
        switch self {
        case let .oneTime(target):
            target >= 0
        case let .repeating(firstTarget, interval, limit):
            firstTarget >= 0 && interval > 0 && (limit.map { $0 > 0 } ?? true)
        }
    }
}
