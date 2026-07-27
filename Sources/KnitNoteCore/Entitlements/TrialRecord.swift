import Foundation

public struct TrialRecord: Codable, Equatable, Sendable {
    public static let duration: TimeInterval = 7 * 24 * 60 * 60

    public let version: Int
    public let startedAt: Date

    public init(startedAt: Date) {
        version = 1
        self.startedAt = startedAt
    }

    public var expiresAt: Date {
        startedAt.addingTimeInterval(Self.duration)
    }
}

public protocol TrialStore: Sendable {
    func load() throws -> TrialRecord?
    func startIfNeeded(now: Date) throws -> TrialRecord
}
