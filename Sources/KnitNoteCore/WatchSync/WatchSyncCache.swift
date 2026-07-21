import Foundation

public struct WatchSyncCache: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let empty = WatchSyncCache(snapshot: nil, pendingCommands: [])

    public let schemaVersion: Int
    public let snapshot: WatchSyncSnapshot?
    public let pendingCommands: [WatchCounterCommand]
    public let selectedProjectID: UUID?
    public let selectedCounterID: UUID?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        snapshot: WatchSyncSnapshot?,
        pendingCommands: [WatchCounterCommand],
        selectedProjectID: UUID? = nil,
        selectedCounterID: UUID? = nil
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
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw WatchSyncValidationError.unsupportedSchema
        }
        self.init(
            schemaVersion: schemaVersion,
            snapshot: try container.decodeIfPresent(WatchSyncSnapshot.self, forKey: .snapshot),
            pendingCommands: try container.decode([WatchCounterCommand].self, forKey: .pendingCommands),
            selectedProjectID: try container.decodeIfPresent(UUID.self, forKey: .selectedProjectID),
            selectedCounterID: try container.decodeIfPresent(UUID.self, forKey: .selectedCounterID)
        )
    }

    public static func loadRecoveringCorruption(in directory: URL) throws -> WatchSyncCacheRecovery {
        let file = AtomicWatchSyncFile<WatchSyncCache>(url: WatchSyncPaths.watchCache(in: directory))
        do {
            guard let cache = try file.load() else {
                return WatchSyncCacheRecovery(cache: .empty, requiresSnapshot: true)
            }
            return WatchSyncCacheRecovery(cache: cache, requiresSnapshot: cache.snapshot == nil)
        } catch {
            try file.quarantineCorruptFile()
            return WatchSyncCacheRecovery(cache: .empty, requiresSnapshot: true)
        }
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
