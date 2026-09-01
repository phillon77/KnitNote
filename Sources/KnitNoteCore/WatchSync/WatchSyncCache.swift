import Foundation

public struct WatchSyncCache: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public static let empty = WatchSyncCache(snapshot: nil, pendingCommands: [])

    public let schemaVersion: Int
    public let snapshot: WatchSyncSnapshot?
    public let pendingCommands: [WatchCounterCommand]
    public let selectedProjectID: UUID?
    public let selectedCounterID: UUID?
    public let announcedQueueHeadOccurrenceIDs: Set<UUID>

    public init(
        schemaVersion: Int = currentSchemaVersion,
        snapshot: WatchSyncSnapshot?,
        pendingCommands: [WatchCounterCommand],
        selectedProjectID: UUID? = nil,
        selectedCounterID: UUID? = nil,
        announcedQueueHeadOccurrenceIDs: Set<UUID> = []
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
        self.announcedQueueHeadOccurrenceIDs = announcedQueueHeadOccurrenceIDs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else {
            throw WatchSyncValidationError.unsupportedSchema
        }
        self.init(
            schemaVersion: Self.currentSchemaVersion,
            snapshot: try container.decodeIfPresent(WatchSyncSnapshot.self, forKey: .snapshot),
            pendingCommands: try container.decode([WatchCounterCommand].self, forKey: .pendingCommands),
            selectedProjectID: try container.decodeIfPresent(UUID.self, forKey: .selectedProjectID),
            selectedCounterID: try container.decodeIfPresent(UUID.self, forKey: .selectedCounterID),
            announcedQueueHeadOccurrenceIDs: try container.decodeIfPresent(Set<UUID>.self, forKey: .announcedQueueHeadOccurrenceIDs) ?? []
        )
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
            announcedQueueHeadOccurrenceIDs: announcedQueueHeadOccurrenceIDs
        )
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
