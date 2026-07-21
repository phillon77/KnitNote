import Foundation

public struct AtomicWatchSyncFile<Value: Codable & Sendable>: Sendable {
    public let url: URL
    private let writer: @Sendable (Data, URL) throws -> Void

    public init(url: URL) {
        self.init(url: url) { data, destination in
            try data.write(to: destination, options: .atomic)
        }
    }

    init(url: URL, writer: @escaping @Sendable (Data, URL) throws -> Void) {
        self.url = url
        self.writer = writer
    }

    public func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try WatchSyncCodec.decode(Value.self, from: Data(contentsOf: url))
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writer(WatchSyncCodec.encode(value), url)
    }

    public func quarantineCorruptFile() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let quarantineURL = WatchSyncPaths.quarantineURL(for: url)
        try FileManager.default.moveItem(at: url, to: quarantineURL)
    }
}

public enum WatchSyncPaths {
    public static func watchCache(in directory: URL) -> URL {
        directory.appendingPathComponent("watch-sync-cache.json")
    }

    public static func processedLedger(in directory: URL) -> URL {
        directory.appendingPathComponent("processed-watch-commands.json")
    }

    public static func preparedCommand(in directory: URL) -> URL {
        directory.appendingPathComponent("prepared-watch-command.json")
    }

    static func quarantineURL(for url: URL, now: Date = .now) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: now)
        let stem = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent(
            "\(stem).corrupt-\(timestamp).json"
        )
    }
}
