import Foundation

public struct ProcessedWatchCommandEffectProof: Codable, Equatable, Sendable {
    public let counter: ProjectCounter
    public let reminder: KnittingReminder?

    public init(counter: ProjectCounter, reminder: KnittingReminder? = nil) {
        self.counter = counter
        self.reminder = reminder
    }
}

/// A schema-independent identity for a processed Watch command. Keeping the
/// operation as its wire string and copying only bounded scalar fields lets an
/// app retain and transfer rejection evidence even when it cannot decode the
/// command's full schema.
public struct ProcessedWatchCommandIdentity: Codable, Equatable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public let counterID: UUID
    public let schemaVersion: Int
    public let operation: String
    public let reminderID: UUID?
    public let occurrenceID: UUID?
    public let observedMutationRevision: UInt64?
    public let observedPendingCount: Int?
    public let createdAt: Date

    public init(_ command: WatchCounterCommand) {
        id = command.id
        projectID = command.projectID
        counterID = command.counterID
        schemaVersion = command.schemaVersion
        operation = command.operation.rawValue
        reminderID = command.reminderID
        occurrenceID = command.occurrenceID
        observedMutationRevision = command.observedMutationRevision
        observedPendingCount = command.observedPendingCount
        createdAt = command.createdAt
    }
}

public struct ProcessedWatchCommandLedger: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let id: UUID
        public let processedAt: Date
        public let rejection: WatchCommandRejection?
        public let commandIdentity: ProcessedWatchCommandIdentity?
        public let preparedCommand: PreparedWatchCommand?
        public let effectProof: ProcessedWatchCommandEffectProof?
        public let processingStamp: SyncMutationStamp?

        public init(
            id: UUID,
            processedAt: Date,
            rejection: WatchCommandRejection? = nil,
            command: WatchCounterCommand? = nil,
            preparedCommand: PreparedWatchCommand? = nil,
            effectProof: ProcessedWatchCommandEffectProof? = nil,
            processingStamp: SyncMutationStamp? = nil
        ) {
            self.id = id
            self.processedAt = processedAt
            self.rejection = rejection
            commandIdentity = (command ?? preparedCommand?.command).map(
                ProcessedWatchCommandIdentity.init
            )
            self.preparedCommand = preparedCommand
            self.effectProof = effectProof
            self.processingStamp = processingStamp
        }
    }

    public private(set) var entries: [Entry]
    public private(set) var requiresFreshHandshake: Bool

    public init(entries: [Entry] = [], requiresFreshHandshake: Bool = false) {
        self.entries = entries
        self.requiresFreshHandshake = requiresFreshHandshake
    }

    public func contains(_ id: UUID) -> Bool {
        entries.contains { $0.id == id }
    }

    public func entry(for id: UUID) -> Entry? {
        entries.first { $0.id == id }
    }

    public mutating func record(
        _ id: UUID,
        rejection: WatchCommandRejection? = nil,
        command: WatchCounterCommand? = nil,
        preparedCommand: PreparedWatchCommand? = nil,
        effectProof: ProcessedWatchCommandEffectProof? = nil,
        processingStamp: SyncMutationStamp? = nil,
        at date: Date
    ) {
        entries.removeAll { $0.id == id }
        entries.append(Entry(
            id: id,
            processedAt: date,
            rejection: rejection,
            command: command,
            preparedCommand: preparedCommand,
            effectProof: effectProof,
            processingStamp: processingStamp
        ))
        prune(now: date)
    }

    public mutating func prune(now: Date) {
        let newest = entries.sorted { $0.processedAt > $1.processedAt }
        let protectedIDs = Set(newest.prefix(1_000).map(\.id))
        let cutoff = now.addingTimeInterval(-90 * 86_400)
        entries = newest.filter {
            protectedIDs.contains($0.id) || $0.processedAt >= cutoff
        }
    }

    public mutating func markRequiresFreshHandshake() {
        requiresFreshHandshake = true
    }

    public mutating func markHandshakeComplete() {
        requiresFreshHandshake = false
    }

    private enum CodingKeys: String, CodingKey {
        case entries
        case requiresFreshHandshake
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decode([Entry].self, forKey: .entries)
        requiresFreshHandshake = try container.decodeIfPresent(
            Bool.self,
            forKey: .requiresFreshHandshake
        ) ?? false
    }
}
