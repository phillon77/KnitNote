import Foundation

public struct PatternProjectUsage: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let patternID: UUID
    public let projectID: UUID
    public var isActive: Bool
    public let linkedAt: Date
    public var unlinkedAt: Date?
    public var sortOrder: Int
    public var readingState: PatternReadingState

    public init(
        id: UUID = UUID(),
        patternID: UUID,
        projectID: UUID,
        isActive: Bool = true,
        linkedAt: Date = .now,
        unlinkedAt: Date? = nil,
        sortOrder: Int,
        readingState: PatternReadingState = .init()
    ) {
        self.id = id
        self.patternID = patternID
        self.projectID = projectID
        self.isActive = isActive
        self.linkedAt = linkedAt
        self.unlinkedAt = unlinkedAt
        self.sortOrder = sortOrder
        self.readingState = readingState
    }

    public mutating func updateReadingState(
        _ state: PatternReadingState,
        now: Date = .now
    ) {
        readingState = state
        _ = now
    }

    public mutating func updateBrowsingState(
        _ state: PatternBrowsingState,
        now: Date = .now
    ) {
        readingState.applyBrowsingState(state)
        _ = now
    }
}
