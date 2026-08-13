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
    public let targetFolderID: UUID?
    public let stagedFilename: String

    private enum CodingKeys: String, CodingKey {
        case id
        case originalFilename
        case receivedAt
        case origin
        case targetProjectID
        case targetFolderID
        case stagedFilename
    }

    public init(
        id: UUID = UUID(),
        originalFilename: String,
        receivedAt: Date,
        origin: PatternImportOrigin,
        targetProjectID: UUID?,
        targetFolderID: UUID? = nil,
        stagedFilename: String
    ) {
        self.id = id
        self.originalFilename = originalFilename
        self.receivedAt = receivedAt
        self.origin = origin
        self.targetProjectID = targetProjectID
        self.targetFolderID = targetFolderID
        self.stagedFilename = stagedFilename
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        originalFilename = try container.decode(String.self, forKey: .originalFilename)
        receivedAt = try container.decode(Date.self, forKey: .receivedAt)
        origin = try container.decode(PatternImportOrigin.self, forKey: .origin)
        targetProjectID = try container.decodeIfPresent(UUID.self, forKey: .targetProjectID)
        targetFolderID = try container.decodeIfPresent(UUID.self, forKey: .targetFolderID)
        stagedFilename = try container.decode(String.self, forKey: .stagedFilename)
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
