import Foundation

public enum WatchSyncValidationError: Error, Equatable {
    case unsupportedSchema, invalidCounterCount, duplicateCounterID
    case invalidSelectedCounter, invalidReminderSnapshot, invalidCommandPayload
}

/// Legacy schema-3 shape. New v4 builders never populate it; it remains until
/// Task 8 replaces the old Watch card and to keep old caches decodable.
public struct WatchCounterReminderSnapshot: Codable, Equatable, Sendable {
    public let id: UUID
    public let nextTarget: Int?
    public let pending: CounterReminderPending?
    public let message: String?
    public let isActive: Bool
    public init(id: UUID, nextTarget: Int?, pending: CounterReminderPending?, message: String?, isActive: Bool) {
        self.id = id; self.nextTarget = nextTarget; self.pending = pending
        self.message = message; self.isActive = isActive
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

    public init(id: UUID, reminderID: UUID, kind: KnittingReminderKind, text: String?, originalTarget: Int, displayAt: Int, phase: KnittingReminderOccurrencePhase, awaitsNextUpwardChange: Bool) {
        self.id = id; self.reminderID = reminderID; self.kind = kind; self.text = text
        self.originalTarget = originalTarget; self.displayAt = displayAt; self.phase = phase
        self.awaitsNextUpwardChange = awaitsNextUpwardChange
    }

    init(_ occurrence: KnittingReminderOccurrence) {
        self.init(id: occurrence.id, reminderID: occurrence.reminderID, kind: occurrence.kind, text: occurrence.text, originalTarget: occurrence.originalTarget, displayAt: occurrence.displayAt, phase: occurrence.phase, awaitsNextUpwardChange: occurrence.awaitsNextUpwardChange)
    }

    fileprivate var isValid: Bool {
        guard originalTarget >= 0, displayAt >= 0 else { return false }
        switch phase {
        case .initial: return displayAt == originalTarget && !awaitsNextUpwardChange
        case .deferredOnce: return awaitsNextUpwardChange ? displayAt > originalTarget : displayAt >= originalTarget
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

    public init(id: UUID, counterID: UUID, kind: KnittingReminderKind, text: String?, rule: KnittingReminderRule, state: KnittingReminderState, mutationRevision: UInt64, createdAt: Date, scheduledCount: Int, completedCount: Int, skippedCount: Int, nextTarget: Int?, nextOccurrenceIndex: Int, lastObservedCounterValue: Int?, pending: [WatchKnittingReminderOccurrenceSnapshot]) throws {
        self.id = id; self.counterID = counterID; self.kind = kind; self.text = text; self.rule = rule
        self.state = state; self.mutationRevision = mutationRevision; self.createdAt = createdAt
        self.scheduledCount = scheduledCount; self.completedCount = completedCount; self.skippedCount = skippedCount
        self.nextTarget = nextTarget; self.nextOccurrenceIndex = nextOccurrenceIndex
        self.lastObservedCounterValue = lastObservedCounterValue; self.pending = pending
        guard isValid else { throw WatchSyncValidationError.invalidReminderSnapshot }
    }

    init(_ reminder: KnittingReminder) throws {
        try self.init(id: reminder.id, counterID: reminder.counterID, kind: reminder.kind, text: reminder.text, rule: reminder.rule, state: reminder.state, mutationRevision: reminder.mutationRevision, createdAt: reminder.createdAt, scheduledCount: reminder.progress.scheduledCount, completedCount: reminder.progress.completedCount, skippedCount: reminder.progress.skippedCount, nextTarget: reminder.progress.nextTarget, nextOccurrenceIndex: reminder.progress.nextOccurrenceIndex, lastObservedCounterValue: reminder.progress.lastObservedCounterValue, pending: reminder.progress.pending.map(WatchKnittingReminderOccurrenceSnapshot.init))
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), counterID: c.decode(UUID.self, forKey: .counterID), kind: c.decode(KnittingReminderKind.self, forKey: .kind), text: c.decodeIfPresent(String.self, forKey: .text), rule: c.decode(KnittingReminderRule.self, forKey: .rule), state: c.decode(KnittingReminderState.self, forKey: .state), mutationRevision: c.decode(UInt64.self, forKey: .mutationRevision), createdAt: c.decode(Date.self, forKey: .createdAt), scheduledCount: c.decode(Int.self, forKey: .scheduledCount), completedCount: c.decode(Int.self, forKey: .completedCount), skippedCount: c.decode(Int.self, forKey: .skippedCount), nextTarget: c.decodeIfPresent(Int.self, forKey: .nextTarget), nextOccurrenceIndex: c.decode(Int.self, forKey: .nextOccurrenceIndex), lastObservedCounterValue: c.decodeIfPresent(Int.self, forKey: .lastObservedCounterValue), pending: c.decode([WatchKnittingReminderOccurrenceSnapshot].self, forKey: .pending))
    }

    public func visibleOccurrences(at counterValue: Int) -> [WatchKnittingReminderOccurrenceSnapshot] {
        pending.filter { $0.phase == .initial || (!$0.awaitsNextUpwardChange && $0.displayAt <= counterValue) }
    }

    fileprivate var isValid: Bool {
        let pendingIDs = Set(pending.map(\.id))
        guard rule.isValidForWatchSnapshot, scheduledCount >= 0, completedCount >= 0, skippedCount >= 0,
              nextTarget.map({ $0 >= 0 }) ?? true, nextOccurrenceIndex > 0,
              lastObservedCounterValue.map({ $0 >= 0 }) ?? true,
              pending.count <= scheduledCount, pendingIDs.count == pending.count,
              pending.allSatisfy({ $0.reminderID == id && $0.kind == kind && $0.text == text && $0.isValid })
        else { return false }
        switch state {
        case .active: return true
        case .completed, .stopped: return nextTarget == nil && pending.isEmpty
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
}

public struct WatchProjectSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let isCompleted: Bool
    public let updatedAt: Date
    public let counters: [WatchCounterSnapshot]
    public let selectedCounterID: UUID
    public var knittingReminders: [WatchKnittingReminderSnapshot]

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
    public init(schemaVersion: Int = currentSchemaVersion, generatedAt: Date, entitlement: WatchEntitlementSnapshot, projects: [WatchProjectSnapshot], languageCode: String? = nil) { self.schemaVersion = schemaVersion; self.generatedAt = generatedAt; self.entitlement = entitlement; self.projects = projects; self.languageCode = languageCode }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion || schemaVersion == 3 else { throw WatchSyncValidationError.unsupportedSchema }
        self.init(schemaVersion: schemaVersion, generatedAt: try c.decode(Date.self, forKey: .generatedAt), entitlement: try c.decode(WatchEntitlementSnapshot.self, forKey: .entitlement), projects: try c.decode([WatchProjectSnapshot].self, forKey: .projects), languageCode: try c.decodeIfPresent(String.self, forKey: .languageCode))
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
    public let createdAt: Date
    public var reminderID: UUID? { reminderPayload?.reminderID ?? legacyReminderID }
    public var observedPendingCount: Int? { legacyObservedPendingCount }
    public init(schemaVersion: Int = currentSchemaVersion, id: UUID = UUID(), projectID: UUID, counterID: UUID, operation: WatchCounterOperation, reminderPayload: WatchReminderActionPayload? = nil, reminderID: UUID? = nil, observedPendingCount: Int? = nil, createdAt: Date = .now) { self.schemaVersion = schemaVersion; self.id = id; self.projectID = projectID; self.counterID = counterID; self.operation = operation; self.reminderPayload = reminderPayload; self.legacyReminderID = reminderID; self.legacyObservedPendingCount = observedPendingCount; self.createdAt = createdAt }
    public var hasValidPayload: Bool {
        switch schemaVersion {
        case Self.currentSchemaVersion:
            switch operation {
            case .increment, .decrement, .reset: return reminderPayload == nil && legacyReminderID == nil && legacyObservedPendingCount == nil
            case .completeReminder, .deferReminderOnce, .skipReminder: return reminderPayload != nil && legacyReminderID == nil && legacyObservedPendingCount == nil
            case .stopReminder: return false
            }
        case 2:
            guard reminderPayload == nil else { return false }
            switch operation {
            case .increment, .decrement, .reset: return legacyReminderID == nil && legacyObservedPendingCount == nil
            case .completeReminder: return legacyReminderID != nil && (legacyObservedPendingCount ?? 0) > 0
            case .stopReminder: return legacyReminderID != nil && legacyObservedPendingCount == nil
            case .deferReminderOnce, .skipReminder: return false
            }
        default: return false
        }
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, id, projectID, counterID, operation, reminderPayload, reminderID, observedPendingCount, createdAt }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion || schemaVersion == 2 else { throw WatchSyncValidationError.unsupportedSchema }
        self.init(schemaVersion: schemaVersion, id: try c.decode(UUID.self, forKey: .id), projectID: try c.decode(UUID.self, forKey: .projectID), counterID: try c.decode(UUID.self, forKey: .counterID), operation: try c.decode(WatchCounterOperation.self, forKey: .operation), reminderPayload: try c.decodeIfPresent(WatchReminderActionPayload.self, forKey: .reminderPayload), reminderID: try c.decodeIfPresent(UUID.self, forKey: .reminderID), observedPendingCount: try c.decodeIfPresent(Int.self, forKey: .observedPendingCount), createdAt: try c.decode(Date.self, forKey: .createdAt))
        guard hasValidPayload else { throw WatchSyncValidationError.invalidCommandPayload }
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
        try c.encode(createdAt, forKey: .createdAt)
    }
}

public enum WatchCommandRejection: String, Codable, Equatable, Sendable { case unsupportedSchema, projectMissing, counterMissing, reminderMismatch, projectCompleted, entitlementRequired, storageFailure }
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
