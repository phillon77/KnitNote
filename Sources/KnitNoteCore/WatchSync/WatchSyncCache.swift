import Foundation

public struct WatchReminderQueueHapticKey: Codable, Hashable, Sendable {
    public let projectID: UUID
    public let occurrenceID: UUID

    public init(projectID: UUID, occurrenceID: UUID) {
        self.projectID = projectID
        self.occurrenceID = occurrenceID
    }
}

public struct WatchSyncCache: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3
    public static let empty = WatchSyncCache(snapshot: nil, pendingCommands: [])

    public let schemaVersion: Int
    public let snapshot: WatchSyncSnapshot?
    public let pendingCommands: [WatchCounterCommand]
    public let selectedProjectID: UUID?
    public let selectedCounterID: UUID?
    public let announcedQueueHeadKeys: Set<WatchReminderQueueHapticKey>

    public init(
        schemaVersion: Int = currentSchemaVersion,
        snapshot: WatchSyncSnapshot?,
        pendingCommands: [WatchCounterCommand],
        selectedProjectID: UUID? = nil,
        selectedCounterID: UUID? = nil,
        announcedQueueHeadKeys: Set<WatchReminderQueueHapticKey> = []
    ) {
        self.schemaVersion = schemaVersion
        self.snapshot = snapshot
        self.pendingCommands = pendingCommands
        let selection = Self.validSelection(
            snapshot: snapshot,
            projectID: selectedProjectID,
            counterID: selectedCounterID
        )
        self.selectedProjectID = selection.projectID
        self.selectedCounterID = selection.counterID
        self.announcedQueueHeadKeys = announcedQueueHeadKeys
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else {
            throw WatchSyncValidationError.unsupportedSchema
        }
        // Schema 2 stored occurrence IDs without their project identity. They
        // cannot safely suppress a same-ID occurrence in another project, so
        // migration deliberately fails open and clears them.
        let hapticKeys = schemaVersion == Self.currentSchemaVersion
            ? try container.decodeIfPresent(
                Set<WatchReminderQueueHapticKey>.self,
                forKey: .announcedQueueHeadKeys
            ) ?? []
            : []
        self.init(
            schemaVersion: Self.currentSchemaVersion,
            snapshot: try container.decodeIfPresent(WatchSyncSnapshot.self, forKey: .snapshot),
            pendingCommands: try container.decode([WatchCounterCommand].self, forKey: .pendingCommands),
            selectedProjectID: try container.decodeIfPresent(UUID.self, forKey: .selectedProjectID),
            selectedCounterID: try container.decodeIfPresent(UUID.self, forKey: .selectedCounterID),
            announcedQueueHeadKeys: hapticKeys
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(snapshot, forKey: .snapshot)
        try container.encode(pendingCommands, forKey: .pendingCommands)
        try container.encodeIfPresent(selectedProjectID, forKey: .selectedProjectID)
        try container.encodeIfPresent(selectedCounterID, forKey: .selectedCounterID)
        try container.encode(announcedQueueHeadKeys, forKey: .announcedQueueHeadKeys)
    }

    public static func loadRecoveringCorruption(in directory: URL) throws -> WatchSyncCacheRecovery {
        let file = AtomicWatchSyncFile<WatchSyncCache>(url: WatchSyncPaths.watchCache(in: directory))
        do {
            guard let cache = try file.load() else {
                return WatchSyncCacheRecovery(cache: .empty, requiresSnapshot: true)
            }
            let sanitized = cache.droppingNonSchemaThreePendingCommands()
            if sanitized != cache {
                try file.save(sanitized)
            }
            return WatchSyncCacheRecovery(
                cache: sanitized,
                requiresSnapshot: sanitized.snapshot == nil
            )
        } catch {
            try file.quarantineCorruptFile()
            return WatchSyncCacheRecovery(cache: .empty, requiresSnapshot: true)
        }
    }

    /// Recovery may decode old command bytes so a cache can be inspected and
    /// rewritten safely, but only schema-3 commands are durable Watch work.
    public func droppingNonSchemaThreePendingCommands() -> WatchSyncCache {
        let commands = pendingCommands.filter {
            $0.schemaVersion == WatchCounterCommand.currentSchemaVersion
                && $0.hasValidPayload
        }
        guard commands != pendingCommands else { return self }
        return WatchSyncCache(
            snapshot: snapshot,
            pendingCommands: commands,
            selectedProjectID: selectedProjectID,
            selectedCounterID: selectedCounterID,
            announcedQueueHeadKeys: announcedQueueHeadKeys
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, snapshot, pendingCommands, selectedProjectID, selectedCounterID
        case announcedQueueHeadKeys, announcedQueueHeadOccurrenceIDs
    }

    private static func validSelection(
        snapshot: WatchSyncSnapshot?,
        projectID: UUID?,
        counterID: UUID?
    ) -> (projectID: UUID?, counterID: UUID?) {
        guard let snapshot, !snapshot.projects.isEmpty else { return (nil, nil) }
        let project = snapshot.projects.first(where: { $0.id == projectID }) ?? snapshot.projects[0]
        let counter = project.counters.first(where: { $0.id == counterID })
        return (project.id, counter?.id ?? project.selectedCounterID)
    }
}

public struct WatchSyncCacheRecovery: Equatable, Sendable {
    public let cache: WatchSyncCache
    public let requiresSnapshot: Bool

    public init(cache: WatchSyncCache, requiresSnapshot: Bool) {
        self.cache = cache
        self.requiresSnapshot = requiresSnapshot
    }
}
