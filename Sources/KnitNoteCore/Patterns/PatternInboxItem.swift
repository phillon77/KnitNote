import Foundation

public enum PatternImportOrigin: String, Codable, Sendable {
    case library
    case project
    case shareExtension
}

public struct PatternInboxItem: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let originalFilename: String
    public let receivedAt: Date
    public let origin: PatternImportOrigin
    public let targetProjectID: UUID?
    public let stagedFilename: String

    public init(
        id: UUID = UUID(),
        originalFilename: String,
        receivedAt: Date,
        origin: PatternImportOrigin,
        targetProjectID: UUID?,
        stagedFilename: String
    ) {
        self.id = id
        self.originalFilename = originalFilename
        self.receivedAt = receivedAt
        self.origin = origin
        self.targetProjectID = targetProjectID
        self.stagedFilename = stagedFilename
    }
}

public enum PatternImportOutcome: Equatable, Sendable {
    case created(patternID: UUID)
    case existing(patternID: UUID)
    case needsSelection(itemID: UUID, candidatePatternIDs: [UUID])
}

public enum PatternImportDuplicateResolution: Equatable, Sendable {
    case automatic
    case existing(UUID)
    case createNew
}
