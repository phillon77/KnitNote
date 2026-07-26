import Foundation

public enum PatternInboxError: Error, Equatable, Sendable {
    case appGroupUnavailable
    case itemNotFound
    case invalidItem
    case invalidSelection
}

public struct PatternStorageLocations: Sendable {
    public let assetRoot: URL
    public let inboxRoot: URL

    public init(assetRoot: URL, inboxRoot: URL) {
        self.assetRoot = assetRoot
        self.inboxRoot = inboxRoot
    }

    public static func live() throws -> PatternStorageLocations {
        let manager = FileManager.default
        let applicationSupport = try manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let assets = applicationSupport
            .appendingPathComponent("KnitNote", isDirectory: true)
            .appendingPathComponent("Patterns", isDirectory: true)

        #if os(iOS)
        guard let group = manager.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.phillon.KnitNote"
        ) else {
            throw PatternInboxError.appGroupUnavailable
        }
        return PatternStorageLocations(
            assetRoot: assets,
            inboxRoot: group.appendingPathComponent("PatternInbox", isDirectory: true)
        )
        #else
        return PatternStorageLocations(
            assetRoot: assets,
            inboxRoot: applicationSupport
                .appendingPathComponent("KnitNote", isDirectory: true)
                .appendingPathComponent("PatternInbox", isDirectory: true)
        )
        #endif
    }
}
