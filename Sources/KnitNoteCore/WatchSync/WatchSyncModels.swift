import Foundation

public enum WatchSyncValidationError: Error, Equatable {
    case unsupportedSchema
    case invalidCounterCount
    case duplicateCounterID
    case invalidSelectedCounter
}

public struct WatchCounterSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public var value: Int

    public init(id: UUID, name: String, value: Int) {
        self.id = id
        self.name = name
        self.value = max(0, value)
    }
}

public struct WatchProjectSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let isCompleted: Bool
    public let updatedAt: Date
    public var counters: [WatchCounterSnapshot]
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

public struct WatchSyncSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let projects: [WatchProjectSnapshot]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        generatedAt: Date,
        projects: [WatchProjectSnapshot]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.projects = projects
    }
}

public enum WatchCounterOperation: String, Codable, Equatable, Sendable {
    case increment
    case decrement
    case reset
}

public struct WatchCounterCommand: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let projectID: UUID
    public let counterID: UUID
    public let operation: WatchCounterOperation
    public let createdAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        id: UUID = UUID(),
        projectID: UUID,
        counterID: UUID,
        operation: WatchCounterOperation,
        createdAt: Date = .now
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.projectID = projectID
        self.counterID = counterID
        self.operation = operation
        self.createdAt = createdAt
    }
}

public enum WatchCommandRejection: String, Codable, Equatable, Sendable {
    case unsupportedSchema
    case projectMissing
    case counterMissing
    case projectCompleted
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
        let value = try decoder.decode(type, from: data)

        if let snapshot = value as? WatchSyncSnapshot,
           snapshot.schemaVersion != WatchSyncSnapshot.currentSchemaVersion {
            throw WatchSyncValidationError.unsupportedSchema
        }
        if let command = value as? WatchCounterCommand,
           command.schemaVersion != WatchCounterCommand.currentSchemaVersion {
            throw WatchSyncValidationError.unsupportedSchema
        }

        return value
    }
}
