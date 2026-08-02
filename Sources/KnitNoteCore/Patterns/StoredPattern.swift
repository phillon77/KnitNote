import Foundation

private struct PatternProjectUsagePair: Hashable {
    let patternID: UUID
    let projectID: UUID
}

public struct StoredPattern: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let assetID: UUID
    public var displayName: String
    public var note: String?
    public let createdAt: Date
    public var lastOpenedAt: Date?
    public var prefersOriginalColorsInDarkMode: Bool

    public init(
        id: UUID = UUID(),
        assetID: UUID,
        displayName: String,
        note: String? = nil,
        createdAt: Date = .now,
        lastOpenedAt: Date? = nil,
        prefersOriginalColorsInDarkMode: Bool = false
    ) {
        self.id = id
        self.assetID = assetID
        self.displayName = displayName
        self.note = note
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.prefersOriginalColorsInDarkMode = prefersOriginalColorsInDarkMode
    }

    private enum CodingKeys: String, CodingKey {
        case id, assetID, displayName, note, createdAt, lastOpenedAt
        case prefersOriginalColorsInDarkMode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        assetID = try container.decode(UUID.self, forKey: .assetID)
        displayName = try container.decode(String.self, forKey: .displayName)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastOpenedAt = try container.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        prefersOriginalColorsInDarkMode = try container.decodeIfPresent(
            Bool.self,
            forKey: .prefersOriginalColorsInDarkMode
        ) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(assetID, forKey: .assetID)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastOpenedAt, forKey: .lastOpenedAt)
        try container.encode(
            prefersOriginalColorsInDarkMode,
            forKey: .prefersOriginalColorsInDarkMode
        )
    }
}

public enum PatternLibraryValidationError: Error, Equatable, Sendable {
    case duplicateAssetID
    case duplicatePatternID
    case duplicateUsageID
    case duplicateProjectID
    case missingAsset
    case missingPattern
    case missingProject
    case duplicateUsage
}

public struct PatternLibrarySnapshot: Sendable {
    public let assets: [PatternAsset]
    public let patterns: [StoredPattern]
    public let usages: [PatternProjectUsage]
    public let validProjectIDs: [UUID]

    public init(
        assets: [PatternAsset],
        patterns: [StoredPattern],
        usages: [PatternProjectUsage],
        validProjectIDs: [UUID]
    ) {
        self.assets = assets
        self.patterns = patterns
        self.usages = usages
        self.validProjectIDs = validProjectIDs
    }

    public func validated() throws -> PatternLibrarySnapshot {
        guard Set(assets.map(\.id)).count == assets.count else {
            throw PatternLibraryValidationError.duplicateAssetID
        }
        guard Set(patterns.map(\.id)).count == patterns.count else {
            throw PatternLibraryValidationError.duplicatePatternID
        }
        guard Set(usages.map(\.id)).count == usages.count else {
            throw PatternLibraryValidationError.duplicateUsageID
        }
        guard Set(validProjectIDs).count == validProjectIDs.count else {
            throw PatternLibraryValidationError.duplicateProjectID
        }

        let usagePairs = usages.map {
            PatternProjectUsagePair(patternID: $0.patternID, projectID: $0.projectID)
        }
        guard Set(usagePairs).count == usagePairs.count else {
            throw PatternLibraryValidationError.duplicateUsage
        }

        let assetIDs = Set(assets.map(\.id))
        guard patterns.allSatisfy({ assetIDs.contains($0.assetID) }) else {
            throw PatternLibraryValidationError.missingAsset
        }

        let patternIDs = Set(patterns.map(\.id))
        guard usages.allSatisfy({ patternIDs.contains($0.patternID) }) else {
            throw PatternLibraryValidationError.missingPattern
        }

        let projectIDs = Set(validProjectIDs)
        guard usages.allSatisfy({ projectIDs.contains($0.projectID) }) else {
            throw PatternLibraryValidationError.missingProject
        }

        return self
    }
}
