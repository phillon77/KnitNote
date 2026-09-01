import Foundation

public enum WatchSyncValidationError: Error, Equatable {
    case unsupportedSchema, invalidCounterCount, duplicateCounterID
    case invalidSelectedCounter, invalidCounterValue, invalidReminderSnapshot, invalidCommandPayload
}

/// Legacy schema-3 shape. New v4 builders never populate it; it remains until
/// Task 8 replaces the old Watch card and to keep old caches decodable.
public struct WatchCounterReminderSnapshot: Codable, Equatable, Sendable {
    public let id: UUID
    public let nextTarget: Int?
    public let pending: CounterReminderPending?
    public let message: String?
    public let isActive: Bool
    /// Task-8 bridge token. Missing tokens identify old cache data and are
    /// intentionally non-mutable until a fresh snapshot arrives.
    private let occurrenceID: UUID?
    private let observedMutationRevision: UInt64?
    /// Read-only bridge token for the existing Watch card. Callers cannot use
    /// this to construct an old-schema command.
    public var legacyOccurrenceID: UUID? { occurrenceID }
    public var legacyObservedMutationRevision: UInt64? { observedMutationRevision }
    public init(id: UUID, nextTarget: Int?, pending: CounterReminderPending?, message: String?, isActive: Bool) {
        self.init(id: id, nextTarget: nextTarget, pending: pending, message: message,
                  isActive: isActive, occurrenceID: nil, observedMutationRevision: nil)
    }
    init(id: UUID, nextTarget: Int?, pending: CounterReminderPending?, message: String?, isActive: Bool, occurrenceID: UUID?, observedMutationRevision: UInt64?) {
        self.id = id; self.nextTarget = nextTarget; self.pending = pending
        self.message = message; self.isActive = isActive
        self.occurrenceID = occurrenceID; self.observedMutationRevision = observedMutationRevision
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(UUID.self, forKey: .id)
        let nextTarget = try c.decodeIfPresent(Int.self, forKey: .nextTarget)
        let pending = try c.decodeIfPresent(CounterReminderPending.self, forKey: .pending)
        let isActive = try c.decode(Bool.self, forKey: .isActive)
        guard nextTarget.map({ $0 >= 0 }) ?? true,
              pending.map({ $0.reminderID == id && $0.occurrenceCount > 0 && $0.firstTarget >= 0 && $0.lastTarget >= $0.firstTarget }) ?? true,
              isActive || (nextTarget == nil && pending == nil)
        else { throw WatchSyncValidationError.invalidReminderSnapshot }
        self.init(id: id, nextTarget: nextTarget, pending: pending,
                  message: try c.decodeIfPresent(String.self, forKey: .message), isActive: isActive,
                  occurrenceID: try c.decodeIfPresent(UUID.self, forKey: .occurrenceID), observedMutationRevision: try c.decodeIfPresent(UInt64.self, forKey: .observedMutationRevision))
    }
}

public struct WatchKnittingReminderOccurrenceSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let reminderID: UUID
    public let kind: KnittingReminderKind
    public let text: String?
    public let originalTarget: Int
    public var displayAt: Int
    public var phase: KnittingReminderOccurrencePhase
    public var awaitsNextUpwardChange: Bool

    public init(id: UUID, reminderID: UUID, kind: KnittingReminderKind, text: String?, originalTarget: Int, displayAt: Int, phase: KnittingReminderOccurrencePhase, awaitsNextUpwardChange: Bool) throws {
        self.id = id; self.reminderID = reminderID; self.kind = kind; self.text = text
        self.originalTarget = originalTarget; self.displayAt = displayAt; self.phase = phase
        self.awaitsNextUpwardChange = awaitsNextUpwardChange
        guard isValid else { throw WatchSyncValidationError.invalidReminderSnapshot }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), reminderID: c.decode(UUID.self, forKey: .reminderID), kind: c.decode(KnittingReminderKind.self, forKey: .kind), text: c.decodeIfPresent(String.self, forKey: .text), originalTarget: c.decode(Int.self, forKey: .originalTarget), displayAt: c.decode(Int.self, forKey: .displayAt), phase: c.decode(KnittingReminderOccurrencePhase.self, forKey: .phase), awaitsNextUpwardChange: c.decode(Bool.self, forKey: .awaitsNextUpwardChange))
    }

    init(_ occurrence: KnittingReminderOccurrence) {
        self.init(trustedID: occurrence.id, reminderID: occurrence.reminderID, kind: occurrence.kind, text: occurrence.text, originalTarget: occurrence.originalTarget, displayAt: occurrence.displayAt, phase: occurrence.phase, awaitsNextUpwardChange: occurrence.awaitsNextUpwardChange)
    }

    private init(trustedID id: UUID, reminderID: UUID, kind: KnittingReminderKind, text: String?, originalTarget: Int, displayAt: Int, phase: KnittingReminderOccurrencePhase, awaitsNextUpwardChange: Bool) {
        self.id = id; self.reminderID = reminderID; self.kind = kind; self.text = text
        self.originalTarget = originalTarget; self.displayAt = displayAt; self.phase = phase
        self.awaitsNextUpwardChange = awaitsNextUpwardChange
    }

    fileprivate var isValid: Bool {
        guard originalTarget >= 0, displayAt >= 0 else { return false }
        switch phase {
        case .initial: return displayAt == originalTarget && !awaitsNextUpwardChange
        case .deferredOnce: return displayAt > originalTarget
        }
    }
}

public struct WatchKnittingReminderSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let counterID: UUID
    public let kind: KnittingReminderKind
    public let text: String?
    public let rule: KnittingReminderRule
    public var state: KnittingReminderState
    public let mutationRevision: UInt64
    public let createdAt: Date
    public var scheduledCount: Int
    public var completedCount: Int
    public var skippedCount: Int
    public var nextTarget: Int?
    public var nextOccurrenceIndex: Int
    public var lastObservedCounterValue: Int?
    public var pending: [WatchKnittingReminderOccurrenceSnapshot]
    public var latestHandled: WatchKnittingReminderOccurrenceSnapshot?

    public init(id: UUID, counterID: UUID, kind: KnittingReminderKind, text: String?, rule: KnittingReminderRule, state: KnittingReminderState, mutationRevision: UInt64, createdAt: Date, scheduledCount: Int, completedCount: Int, skippedCount: Int, nextTarget: Int?, nextOccurrenceIndex: Int, lastObservedCounterValue: Int?, pending: [WatchKnittingReminderOccurrenceSnapshot], latestHandled: WatchKnittingReminderOccurrenceSnapshot? = nil) throws {
        self.id = id; self.counterID = counterID; self.kind = kind; self.text = text; self.rule = rule
        self.state = state; self.mutationRevision = mutationRevision; self.createdAt = createdAt
        self.scheduledCount = scheduledCount; self.completedCount = completedCount; self.skippedCount = skippedCount
        self.nextTarget = nextTarget; self.nextOccurrenceIndex = nextOccurrenceIndex
        self.lastObservedCounterValue = lastObservedCounterValue; self.pending = pending; self.latestHandled = latestHandled
        guard isValid else { throw WatchSyncValidationError.invalidReminderSnapshot }
    }

    init(_ reminder: KnittingReminder) throws {
        try self.init(id: reminder.id, counterID: reminder.counterID, kind: reminder.kind, text: reminder.text, rule: reminder.rule, state: reminder.state, mutationRevision: reminder.mutationRevision, createdAt: reminder.createdAt, scheduledCount: reminder.progress.scheduledCount, completedCount: reminder.progress.completedCount, skippedCount: reminder.progress.skippedCount, nextTarget: reminder.progress.nextTarget, nextOccurrenceIndex: reminder.progress.nextOccurrenceIndex, lastObservedCounterValue: reminder.progress.lastObservedCounterValue, pending: reminder.progress.pending.map(WatchKnittingReminderOccurrenceSnapshot.init), latestHandled: reminder.progress.latestHandled.map(WatchKnittingReminderOccurrenceSnapshot.init))
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), counterID: c.decode(UUID.self, forKey: .counterID), kind: c.decode(KnittingReminderKind.self, forKey: .kind), text: c.decodeIfPresent(String.self, forKey: .text), rule: c.decode(KnittingReminderRule.self, forKey: .rule), state: c.decode(KnittingReminderState.self, forKey: .state), mutationRevision: c.decode(UInt64.self, forKey: .mutationRevision), createdAt: c.decode(Date.self, forKey: .createdAt), scheduledCount: c.decode(Int.self, forKey: .scheduledCount), completedCount: c.decode(Int.self, forKey: .completedCount), skippedCount: c.decode(Int.self, forKey: .skippedCount), nextTarget: c.decodeIfPresent(Int.self, forKey: .nextTarget), nextOccurrenceIndex: c.decode(Int.self, forKey: .nextOccurrenceIndex), lastObservedCounterValue: c.decodeIfPresent(Int.self, forKey: .lastObservedCounterValue), pending: c.decode([WatchKnittingReminderOccurrenceSnapshot].self, forKey: .pending), latestHandled: c.decodeIfPresent(WatchKnittingReminderOccurrenceSnapshot.self, forKey: .latestHandled))
    }

    public func visibleOccurrences(at counterValue: Int) -> [WatchKnittingReminderOccurrenceSnapshot] {
        pending.filter { $0.phase == .initial || (!$0.awaitsNextUpwardChange && $0.displayAt <= counterValue) }
    }

    fileprivate var isValid: Bool {
        let pendingIDs = Set(pending.map(\.id))
        let expectedNext = target(forOccurrence: nextOccurrenceIndex)
        guard rule.isValidForWatchSnapshot, scheduledCount >= 0, completedCount >= 0, skippedCount >= 0,
              nextTarget.map({ $0 >= 0 }) ?? true, nextOccurrenceIndex > 0,
              lastObservedCounterValue.map({ $0 >= 0 }) ?? true,
              pending.count <= scheduledCount,
              pendingIDs.count == pending.count,
              pending.allSatisfy(isValidOccurrence),
              latestHandled.map(isValidOccurrence) ?? true,
              latestHandled.map({ !pendingIDs.contains($0.id) }) ?? true,
              pending.allSatisfy(isScheduledByRule), latestHandled.map(isScheduledByRule) ?? true
        else { return false }
        switch state {
        case .active: return nextTarget == expectedNext
        case .completed, .stopped: return nextTarget == nil && pending.isEmpty
        }
    }

    private func isValidOccurrence(_ occurrence: WatchKnittingReminderOccurrenceSnapshot) -> Bool {
        occurrence.reminderID == id && occurrence.kind == kind && occurrence.text == text && occurrence.isValid
    }

    private func isScheduledByRule(_ occurrence: WatchKnittingReminderOccurrenceSnapshot) -> Bool {
        guard let index = occurrenceIndex(for: occurrence.originalTarget) else { return false }
        return index < nextOccurrenceIndex
    }

    private func occurrenceIndex(for target: Int) -> Int? {
        switch rule {
        case let .oneTime(expected): return target == expected ? 1 : nil
        case let .repeating(first, interval, limit):
            guard target >= first else { return nil }
            let difference = target - first
            guard difference % interval == 0 else { return nil }
            let (index, overflow) = (difference / interval).addingReportingOverflow(1)
            guard !overflow, limit.map({ index <= $0 }) ?? true else { return nil }
            return index
        }
    }

    private func target(forOccurrence occurrence: Int) -> Int? {
        guard occurrence > 0 else { return nil }
        switch rule {
        case let .oneTime(target): return occurrence == 1 ? target : nil
        case let .repeating(first, interval, limit):
            guard limit.map({ occurrence <= $0 }) ?? true else { return nil }
            let (offset, overflow) = interval.multipliedReportingOverflow(by: occurrence - 1)
            guard !overflow else { return nil }
            let (target, addOverflow) = first.addingReportingOverflow(offset)
            return addOverflow ? nil : target
        }
    }
}

public struct WatchCounterSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public var value: Int
    public var reminder: WatchCounterReminderSnapshot?
    public init(id: UUID, name: String, value: Int, reminder: WatchCounterReminderSnapshot? = nil) {
        self.id = id; self.name = name; self.value = max(0, value); self.reminder = reminder
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let value = try c.decode(Int.self, forKey: .value)
        guard value >= 0 else { throw WatchSyncValidationError.invalidCounterValue }
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name), value: value, reminder: try? c.decode(WatchCounterReminderSnapshot.self, forKey: .reminder))
    }
}

public struct WatchProjectSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let isCompleted: Bool
    public let updatedAt: Date
    public let counters: [WatchCounterSnapshot]
    public let selectedCounterID: UUID
    public var knittingReminders: [WatchKnittingReminderSnapshot]

    /// Core-equivalent global occurrence queue. Nested reminders remain for ownership,
    /// but consumers must render this order rather than flattening nested arrays.
    public var reminderQueue: [WatchKnittingReminderOccurrenceSnapshot] {
        var queue: [(occurrence: WatchKnittingReminderOccurrenceSnapshot, createdAt: Date, reminderID: UUID)] = []
        for reminder in knittingReminders where reminder.state == .active {
            guard let counter = counters.first(where: { $0.id == reminder.counterID }) else { continue }
            queue += reminder.visibleOccurrences(at: counter.value).map {
                (occurrence: $0, createdAt: reminder.createdAt, reminderID: reminder.id)
            }
        }
        return queue.sorted { lhs, rhs in
            if lhs.occurrence.originalTarget != rhs.occurrence.originalTarget { return lhs.occurrence.originalTarget < rhs.occurrence.originalTarget }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            if lhs.reminderID != rhs.reminderID { return lhs.reminderID.uuidString < rhs.reminderID.uuidString }
            return lhs.occurrence.id.uuidString < rhs.occurrence.id.uuidString
        }.map(\.occurrence)
    }

    public init(id: UUID, name: String, isCompleted: Bool, updatedAt: Date, counters: [WatchCounterSnapshot], selectedCounterID: UUID, knittingReminders: [WatchKnittingReminderSnapshot] = []) throws {
        guard counters.count == 6 else { throw WatchSyncValidationError.invalidCounterCount }
        guard Set(counters.map(\.id)).count == 6 else { throw WatchSyncValidationError.duplicateCounterID }
        guard counters.contains(where: { $0.id == selectedCounterID }) else { throw WatchSyncValidationError.invalidSelectedCounter }
        let reminderIDs = Set(knittingReminders.map(\.id))
        let occurrenceIDs = Set(knittingReminders.flatMap { $0.pending.map(\.id) })
        guard reminderIDs.count == knittingReminders.count,
              occurrenceIDs.count == knittingReminders.reduce(0, { $0 + $1.pending.count }),
              knittingReminders.allSatisfy({ reminder in counters.contains(where: { $0.id == reminder.counterID }) && reminder.isValid })
        else { throw WatchSyncValidationError.invalidReminderSnapshot }
        self.id = id; self.name = name; self.isCompleted = isCompleted; self.updatedAt = updatedAt
        self.counters = counters; self.selectedCounterID = selectedCounterID; self.knittingReminders = knittingReminders
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), name: c.decode(String.self, forKey: .name), isCompleted: c.decode(Bool.self, forKey: .isCompleted), updatedAt: c.decode(Date.self, forKey: .updatedAt), counters: c.decode([WatchCounterSnapshot].self, forKey: .counters), selectedCounterID: c.decode(UUID.self, forKey: .selectedCounterID), knittingReminders: c.decodeIfPresent([WatchKnittingReminderSnapshot].self, forKey: .knittingReminders) ?? [])
    }
}

public struct WatchEntitlementSnapshot: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable { case trialNotStarted, trial, permanentlyUnlocked, legacyPaidOwner }
    public let kind: Kind
    public let expiresAt: Date?
    public let generatedAt: Date
    public init(kind: Kind, expiresAt: Date?, generatedAt: Date) { self.kind = kind; self.expiresAt = expiresAt; self.generatedAt = generatedAt }
    public func canMutate(now: Date) -> Bool {
        switch kind {
        case .trial: guard let expiresAt else { return false }; _ = now; return generatedAt < expiresAt
        case .permanentlyUnlocked, .legacyPaidOwner: return expiresAt == nil
        case .trialNotStarted: return false
        }
    }
}

public struct WatchSyncSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 4
    public let schemaVersion: Int
    public let generatedAt: Date
    public let entitlement: WatchEntitlementSnapshot
    public let projects: [WatchProjectSnapshot]
    public let languageCode: String?
    public init(validatingSchemaVersion schemaVersion: Int, generatedAt: Date, entitlement: WatchEntitlementSnapshot, projects: [WatchProjectSnapshot], languageCode: String? = nil) throws {
        guard schemaVersion == Self.currentSchemaVersion else { throw WatchSyncValidationError.unsupportedSchema }
        self.init(schemaVersion: schemaVersion, generatedAt: generatedAt, entitlement: entitlement, projects: projects, languageCode: languageCode)
    }

    init(schemaVersion: Int = currentSchemaVersion, generatedAt: Date, entitlement: WatchEntitlementSnapshot, projects: [WatchProjectSnapshot], languageCode: String? = nil) { self.schemaVersion = schemaVersion; self.generatedAt = generatedAt; self.entitlement = entitlement; self.projects = projects; self.languageCode = languageCode }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        switch schemaVersion {
        case Self.currentSchemaVersion:
            self.init(schemaVersion: schemaVersion, generatedAt: try c.decode(Date.self, forKey: .generatedAt), entitlement: try c.decode(WatchEntitlementSnapshot.self, forKey: .entitlement), projects: try c.decode([WatchProjectSnapshot].self, forKey: .projects), languageCode: try c.decodeIfPresent(String.self, forKey: .languageCode))
        case 3:
            let legacy = try LegacySchemaThreeSnapshot(from: decoder)
            self.init(schemaVersion: 3, generatedAt: legacy.generatedAt, entitlement: legacy.entitlement, projects: try legacy.projects.map(WatchProjectSnapshot.init), languageCode: legacy.languageCode)
        default:
            throw WatchSyncValidationError.unsupportedSchema
        }
    }
}

/// Explicit recovery-only schema-3 wire models. Their deliberately forgiving
/// counter/reminder conversion preserves the old cache's clamping/drop policy.
private struct LegacySchemaThreeSnapshot: Decodable {
    let generatedAt: Date
    let entitlement: WatchEntitlementSnapshot
    let projects: [Project]
    let languageCode: String?
    struct Project: Decodable {
        let id: UUID; let name: String; let isCompleted: Bool; let updatedAt: Date
        let counters: [Counter]; let selectedCounterID: UUID
        struct Counter: Decodable {
            let id: UUID; let name: String; let value: Int
            let reminder: WatchCounterReminderSnapshot?
            private enum CodingKeys: String, CodingKey { case id, name, value, reminder }
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decode(UUID.self, forKey: .id)
                name = try c.decode(String.self, forKey: .name)
                value = try c.decode(Int.self, forKey: .value)
                reminder = try? c.decode(WatchCounterReminderSnapshot.self, forKey: .reminder)
            }
        }
    }
}

private extension WatchProjectSnapshot {
    init(_ legacy: LegacySchemaThreeSnapshot.Project) throws {
        try self.init(id: legacy.id, name: legacy.name, isCompleted: legacy.isCompleted, updatedAt: legacy.updatedAt, counters: legacy.counters.map { WatchCounterSnapshot(id: $0.id, name: $0.name, value: $0.value, reminder: $0.reminder) }, selectedCounterID: legacy.selectedCounterID, knittingReminders: [])
    }
}

public enum WatchCounterOperation: String, Codable, Equatable, Sendable { case increment, decrement, reset, completeReminder, deferReminderOnce, skipReminder, stopReminder }
public struct WatchReminderActionPayload: Codable, Equatable, Sendable {
    public let reminderID: UUID; public let occurrenceID: UUID; public let observedRevision: UInt64
    public init(reminderID: UUID, occurrenceID: UUID, observedRevision: UInt64) { self.reminderID = reminderID; self.occurrenceID = occurrenceID; self.observedRevision = observedRevision }
}

public struct WatchCounterCommand: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 3
    public let schemaVersion: Int
    public let id: UUID
    public let projectID: UUID
    public let counterID: UUID
    public let operation: WatchCounterOperation
    public let reminderPayload: WatchReminderActionPayload?
    private let legacyReminderID: UUID?
    private let legacyObservedPendingCount: Int?
    private let legacyOccurrenceID: UUID?
    private let legacyObservedMutationRevision: UInt64?
    public let createdAt: Date
    public var reminderID: UUID? { reminderPayload?.reminderID ?? legacyReminderID }
    public var observedPendingCount: Int? { legacyObservedPendingCount }
    /// Validates all wire-level schema and payload combinations before a command
    /// can cross the public module boundary.
    public init(validating schemaVersion: Int, id: UUID = UUID(), projectID: UUID, counterID: UUID, operation: WatchCounterOperation, reminderPayload: WatchReminderActionPayload? = nil, reminderID: UUID? = nil, observedPendingCount: Int? = nil, createdAt: Date = .now) throws {
        guard schemaVersion == Self.currentSchemaVersion else { throw WatchSyncValidationError.unsupportedSchema }
        self.init(uncheckedSchemaVersion: schemaVersion, id: id, projectID: projectID, counterID: counterID, operation: operation, reminderPayload: reminderPayload, reminderID: reminderID, observedPendingCount: observedPendingCount, createdAt: createdAt)
        guard hasValidPayload else { throw WatchSyncValidationError.invalidCommandPayload }
    }

    /// Internal-only compatibility escape hatch for old cache fixture recovery.
    init(schemaVersion: Int = currentSchemaVersion, id: UUID = UUID(), projectID: UUID, counterID: UUID, operation: WatchCounterOperation, reminderPayload: WatchReminderActionPayload? = nil, reminderID: UUID? = nil, observedPendingCount: Int? = nil, occurrenceID: UUID? = nil, observedMutationRevision: UInt64? = nil, createdAt: Date = .now) {
        self.init(uncheckedSchemaVersion: schemaVersion, id: id, projectID: projectID, counterID: counterID, operation: operation, reminderPayload: reminderPayload, reminderID: reminderID, observedPendingCount: observedPendingCount, occurrenceID: occurrenceID, observedMutationRevision: observedMutationRevision, createdAt: createdAt)
    }

#if DEBUG
    /// Test-only recovery fixture for archived schema-2 command decoding.
    static func legacyWatchUICommand(
        id: UUID = UUID(), projectID: UUID, counterID: UUID,
        operation: WatchCounterOperation, reminderID: UUID,
        observedPendingCount: Int? = nil, occurrenceID: UUID, observedMutationRevision: UInt64, createdAt: Date = .now
    ) -> WatchCounterCommand? {
        guard operation == .completeReminder || operation == .stopReminder else { return nil }
        let command = WatchCounterCommand(schemaVersion: 2, id: id, projectID: projectID, counterID: counterID, operation: operation, reminderID: reminderID, observedPendingCount: observedPendingCount, occurrenceID: occurrenceID, observedMutationRevision: observedMutationRevision, createdAt: createdAt)
        return command.hasValidPayload ? command : nil
    }
#endif

    private init(uncheckedSchemaVersion schemaVersion: Int, id: UUID, projectID: UUID, counterID: UUID, operation: WatchCounterOperation, reminderPayload: WatchReminderActionPayload?, reminderID: UUID?, observedPendingCount: Int?, occurrenceID: UUID? = nil, observedMutationRevision: UInt64? = nil, createdAt: Date) { self.schemaVersion = schemaVersion; self.id = id; self.projectID = projectID; self.counterID = counterID; self.operation = operation; self.reminderPayload = reminderPayload; self.legacyReminderID = reminderID; self.legacyObservedPendingCount = observedPendingCount; self.legacyOccurrenceID = occurrenceID; self.legacyObservedMutationRevision = observedMutationRevision; self.createdAt = createdAt }

    public var hasValidPayload: Bool {
        switch schemaVersion {
        case Self.currentSchemaVersion:
            switch operation {
            case .increment, .decrement, .reset: return reminderPayload == nil && legacyReminderID == nil && legacyObservedPendingCount == nil && legacyOccurrenceID == nil && legacyObservedMutationRevision == nil
            case .completeReminder, .deferReminderOnce, .skipReminder: return reminderPayload != nil && legacyReminderID == nil && legacyObservedPendingCount == nil && legacyOccurrenceID == nil && legacyObservedMutationRevision == nil
            case .stopReminder: return false
            }
        case 2:
            guard reminderPayload == nil else { return false }
            switch operation {
            case .increment, .decrement, .reset: return legacyReminderID == nil && legacyObservedPendingCount == nil && legacyOccurrenceID == nil && legacyObservedMutationRevision == nil
            case .completeReminder: return legacyReminderID != nil && (legacyObservedPendingCount ?? 0) > 0
            case .stopReminder: return legacyReminderID != nil && legacyObservedPendingCount == nil
            case .deferReminderOnce, .skipReminder: return false
            }
        default: return false
        }
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, id, projectID, counterID, operation, reminderPayload, reminderID, observedPendingCount, occurrenceID, observedMutationRevision, createdAt }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        switch schemaVersion {
        case Self.currentSchemaVersion:
            try self.init(validating: schemaVersion, id: try c.decode(UUID.self, forKey: .id), projectID: try c.decode(UUID.self, forKey: .projectID), counterID: try c.decode(UUID.self, forKey: .counterID), operation: try c.decode(WatchCounterOperation.self, forKey: .operation), reminderPayload: try c.decodeIfPresent(WatchReminderActionPayload.self, forKey: .reminderPayload), reminderID: try c.decodeIfPresent(UUID.self, forKey: .reminderID), observedPendingCount: try c.decodeIfPresent(Int.self, forKey: .observedPendingCount), createdAt: try c.decode(Date.self, forKey: .createdAt))
        case 2:
            let command = WatchCounterCommand(schemaVersion: 2, id: try c.decode(UUID.self, forKey: .id), projectID: try c.decode(UUID.self, forKey: .projectID), counterID: try c.decode(UUID.self, forKey: .counterID), operation: try c.decode(WatchCounterOperation.self, forKey: .operation), reminderPayload: nil, reminderID: try c.decodeIfPresent(UUID.self, forKey: .reminderID), observedPendingCount: try c.decodeIfPresent(Int.self, forKey: .observedPendingCount), occurrenceID: try c.decodeIfPresent(UUID.self, forKey: .occurrenceID), observedMutationRevision: try c.decodeIfPresent(UInt64.self, forKey: .observedMutationRevision), createdAt: try c.decode(Date.self, forKey: .createdAt))
            guard command.hasValidPayload else { throw WatchSyncValidationError.invalidCommandPayload }
            self = command
        default:
            throw WatchSyncValidationError.unsupportedSchema
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(projectID, forKey: .projectID)
        try c.encode(counterID, forKey: .counterID)
        try c.encode(operation, forKey: .operation)
        try c.encodeIfPresent(reminderPayload, forKey: .reminderPayload)
        try c.encodeIfPresent(legacyReminderID, forKey: .reminderID)
        try c.encodeIfPresent(legacyObservedPendingCount, forKey: .observedPendingCount)
        try c.encodeIfPresent(legacyOccurrenceID, forKey: .occurrenceID)
        try c.encodeIfPresent(legacyObservedMutationRevision, forKey: .observedMutationRevision)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

public enum WatchCommandRejection: String, Codable, Equatable, Sendable { case unsupportedSchema, projectMissing, counterMissing, reminderMismatch, pendingCounterMutation, projectCompleted, entitlementRequired, storageFailure }
public struct WatchCommandAcknowledgement: Codable, Equatable, Sendable { public let commandID: UUID; public let rejection: WatchCommandRejection?; public let snapshot: WatchSyncSnapshot }
public enum WatchSyncCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data { let e = JSONEncoder(); e.dateEncodingStrategy = .millisecondsSince1970; return try e.encode(value) }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970; return try d.decode(type, from: data) }
}

private extension KnittingReminderRule {
    var isValidForWatchSnapshot: Bool {
        switch self { case let .oneTime(target): return target >= 0; case let .repeating(firstTarget, interval, limit): return firstTarget >= 0 && interval > 0 && (limit.map { $0 > 0 } ?? true) }
    }
}
