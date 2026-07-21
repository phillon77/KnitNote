import Foundation

public struct ProcessedWatchCommandLedger: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let id: UUID
        public let processedAt: Date

        public init(id: UUID, processedAt: Date) {
            self.id = id
            self.processedAt = processedAt
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

    public mutating func record(_ id: UUID, at date: Date) {
        entries.removeAll { $0.id == id }
        entries.append(Entry(id: id, processedAt: date))
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
