import Foundation

public enum SyncScalar: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case decimal(Double)
    case boolean(Bool)
    case date(Date)
    case uuid(UUID)
    case data(Data)

    var byteCount: Int {
        switch self {
        case let .string(value):
            value.lengthOfBytes(using: .utf8)
        case let .data(value):
            value.count
        case .integer, .decimal, .boolean, .date, .uuid:
            0
        }
    }
}

public struct SyncRecordPayload: Codable, Equatable, Sendable {
    public var fields: [String: SyncFieldVersion<SyncScalar>]
    public var deletedRelatedEntityIDs: [SyncEntityID]

    public init(
        fields: [String: SyncFieldVersion<SyncScalar>],
        deletedRelatedEntityIDs: [SyncEntityID] = []
    ) {
        self.fields = fields
        self.deletedRelatedEntityIDs = deletedRelatedEntityIDs
    }
}

public struct SyncRelationship: Codable, Equatable, Sendable {
    public let role: String
    public let target: SyncEntityID

    public init(role: String, target: SyncEntityID) {
        self.role = role
        self.target = target
    }
}

public struct SyncRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: SyncEntityID
    public let createdAt: Date
    public var entityRevision: UInt64
    public var payload: SyncRecordPayload
    public var relationships: [SyncRelationship]
    public var deletedAt: SyncFieldVersion<Date?>

    public init(
        schemaVersion: Int,
        id: SyncEntityID,
        createdAt: Date,
        entityRevision: UInt64,
        payload: SyncRecordPayload,
        relationships: [SyncRelationship],
        deletedAt: SyncFieldVersion<Date?>
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.entityRevision = entityRevision
        self.payload = payload
        self.relationships = relationships
        self.deletedAt = deletedAt
    }
}
