import Foundation

public enum WatchSyncValidationError: Error, Equatable {
    case unsupportedSchema
    case invalidCounterCount
    case duplicateCounterID
    case invalidSelectedCounter
    case invalidReminderSnapshot
    case invalidCommandPayload
}

public struct WatchCounterReminderSnapshot: Codable, Equatable, Sendable {
    public let id: UUID
    public let nextTarget: Int?
    public let pending: CounterReminderPending?
    public let message: String?
    public let isActive: Bool

    public init(
        id: UUID,
        nextTarget: Int?,
        pending: CounterReminderPending?,
        message: String?,
        isActive: Bool
    ) {
        self.id = id
        self.nextTarget = nextTarget
        self.pending = pending
        self.message = message
        self.isActive = isActive
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let nextTarget = try container.decodeIfPresent(Int.self, forKey: .nextTarget)
        let pending = try container.decodeIfPresent(CounterReminderPending.self, forKey: .pending)
        let isActive = try container.decode(Bool.self, forKey: .isActive)
        guard nextTarget.map({ $0 >= 0 }) ?? true,
              pending.map({
                  $0.reminderID == id
                      && $0.occurrenceCount > 0
                      && $0.firstTarget >= 0
                      && $0.lastTarget >= $0.firstTarget
              }) ?? true,
              isActive || (nextTarget == nil && pending == nil)
        else {
            throw WatchSyncValidationError.invalidReminderSnapshot
        }

        self.id = id
        self.nextTarget = nextTarget
        self.pending = pending
        self.message = try container.decodeIfPresent(String.self, forKey: .message)
        self.isActive = isActive
    }
}

public struct WatchCounterSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public var value: Int
    public var reminder: WatchCounterReminderSnapshot?

    public init(
        id: UUID,
        name: String,
        value: Int,
        reminder: WatchCounterReminderSnapshot? = nil
    ) {
        self.id = id
        self.name = name
        let normalizedValue = max(0, value)
        self.value = normalizedValue
        self.reminder = reminder.flatMap { candidate in
            guard candidate.nextTarget.map({ $0 > normalizedValue }) ?? true,
                  candidate.pending.map({ $0.lastTarget <= normalizedValue }) ?? true
            else { return nil }
            return candidate
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            value: try container.decode(Int.self, forKey: .value),
            reminder: try? container.decodeIfPresent(
                WatchCounterReminderSnapshot.self,
                forKey: .reminder
            )
        )
    }
}

public struct WatchProjectSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let isCompleted: Bool
    public let updatedAt: Date
    public let counters: [WatchCounterSnapshot]
    public let selectedCounterID: UUID

    public init(
        id: UUID,
        name: String,
        isCompleted: Bool,
        updatedAt: Date,
        counters: [WatchCounterSnapshot],
        selectedCounterID: UUID
    ) throws {
        guard counters.count == 6 else {
            throw WatchSyncValidationError.invalidCounterCount
        }
        guard Set(counters.map(\.id)).count == 6 else {
            throw WatchSyncValidationError.duplicateCounterID
        }
        guard counters.contains(where: { $0.id == selectedCounterID }) else {
            throw WatchSyncValidationError.invalidSelectedCounter
        }

        self.id = id
        self.name = name
        self.isCompleted = isCompleted
        self.updatedAt = updatedAt
        self.counters = counters
        self.selectedCounterID = selectedCounterID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            isCompleted: container.decode(Bool.self, forKey: .isCompleted),
            updatedAt: container.decode(Date.self, forKey: .updatedAt),
            counters: container.decode([WatchCounterSnapshot].self, forKey: .counters),
            selectedCounterID: container.decode(UUID.self, forKey: .selectedCounterID)
        )
    }
}

public struct WatchEntitlementSnapshot: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case trialNotStarted
        case trial
        case permanentlyUnlocked
        case legacyPaidOwner
    }

    public let kind: Kind
    public let expiresAt: Date?
    public let generatedAt: Date

    public init(kind: Kind, expiresAt: Date?, generatedAt: Date) {
        self.kind = kind
        self.expiresAt = expiresAt
        self.generatedAt = generatedAt
    }

    public func canMutate(now: Date) -> Bool {
        switch kind {
        case .trial:
            guard let expiresAt else { return false }
            _ = now
            return generatedAt < expiresAt
        case .permanentlyUnlocked, .legacyPaidOwner:
            return expiresAt == nil
        case .trialNotStarted:
            return false
        }
    }
}

public struct WatchSyncSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    public let generatedAt: Date
    public let entitlement: WatchEntitlementSnapshot
    public let projects: [WatchProjectSnapshot]
    public let languageCode: String?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        generatedAt: Date,
        entitlement: WatchEntitlementSnapshot,
        projects: [WatchProjectSnapshot],
        languageCode: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.entitlement = entitlement
        self.projects = projects
        self.languageCode = languageCode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw WatchSyncValidationError.unsupportedSchema
        }

        self.schemaVersion = schemaVersion
        self.generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        self.entitlement = try container.decode(
            WatchEntitlementSnapshot.self,
            forKey: .entitlement
        )
        self.projects = try container.decode([WatchProjectSnapshot].self, forKey: .projects)
        self.languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode)
    }
}

public enum WatchCounterOperation: String, Codable, Equatable, Sendable {
    case increment
    case decrement
    case reset
    case completeReminder
    case stopReminder
}

public struct WatchCounterCommand: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let id: UUID
    public let projectID: UUID
    public let counterID: UUID
    public let operation: WatchCounterOperation
    public let reminderID: UUID?
    public let observedPendingCount: Int?
    public let createdAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        id: UUID = UUID(),
        projectID: UUID,
        counterID: UUID,
        operation: WatchCounterOperation,
        reminderID: UUID? = nil,
        observedPendingCount: Int? = nil,
        createdAt: Date = .now
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.projectID = projectID
        self.counterID = counterID
        self.operation = operation
        self.reminderID = reminderID
        self.observedPendingCount = observedPendingCount
        self.createdAt = createdAt
    }

    public var hasValidPayload: Bool {
        switch operation {
        case .increment, .decrement, .reset:
            reminderID == nil && observedPendingCount == nil
        case .completeReminder:
            reminderID != nil && observedPendingCount.map({ $0 > 0 }) == true
        case .stopReminder:
            reminderID != nil && observedPendingCount == nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw WatchSyncValidationError.unsupportedSchema
        }

        let operation = try container.decode(WatchCounterOperation.self, forKey: .operation)
        let reminderID = try container.decodeIfPresent(UUID.self, forKey: .reminderID)
        let observedPendingCount = try container.decodeIfPresent(
            Int.self,
            forKey: .observedPendingCount
        )
        self.init(
            schemaVersion: schemaVersion,
            id: try container.decode(UUID.self, forKey: .id),
            projectID: try container.decode(UUID.self, forKey: .projectID),
            counterID: try container.decode(UUID.self, forKey: .counterID),
            operation: operation,
            reminderID: reminderID,
            observedPendingCount: observedPendingCount,
            createdAt: try container.decode(Date.self, forKey: .createdAt)
        )
        guard hasValidPayload else {
            throw WatchSyncValidationError.invalidCommandPayload
        }
    }
}

public enum WatchCommandRejection: String, Codable, Equatable, Sendable {
    case unsupportedSchema
    case projectMissing
    case counterMissing
    case reminderMismatch
    case projectCompleted
    case entitlementRequired
    case storageFailure
}

public struct WatchCommandAcknowledgement: Codable, Equatable, Sendable {
    public let commandID: UUID
    public let rejection: WatchCommandRejection?
    public let snapshot: WatchSyncSnapshot
}

public enum WatchSyncCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}
