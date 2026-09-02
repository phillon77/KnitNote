import Foundation

public enum SyncEntityKind: String, Codable, CaseIterable, Sendable {
    case project, projectCounter, rowNote, knittingReminder, journalEntry
    case yarn, projectYarnLink, patternFolder, pattern, patternUsage, attachment, deletionMarker
}

public struct SyncEntityID: Hashable, Codable, Sendable {
    public let kind: SyncEntityKind
    public let uuid: UUID

    public init(kind: SyncEntityKind, uuid: UUID) {
        self.kind = kind
        self.uuid = uuid
    }
}

public struct SyncMutationStamp: Hashable, Codable, Comparable, Sendable {
    public let logicalRevision: UInt64
    public let modifiedAt: Date
    public let deviceID: String

    public init(logicalRevision: UInt64, modifiedAt: Date, deviceID: String) {
        self.logicalRevision = logicalRevision
        self.modifiedAt = modifiedAt
        self.deviceID = deviceID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.logicalRevision, lhs.modifiedAt, lhs.deviceID) <
        (rhs.logicalRevision, rhs.modifiedAt, rhs.deviceID)
    }
}

public struct SyncFieldVersion<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let value: Value
    public let stamp: SyncMutationStamp

    public init(value: Value, stamp: SyncMutationStamp) {
        self.value = value
        self.stamp = stamp
    }
}
