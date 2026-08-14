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
    public var folderID: UUID?

    public init(
        id: UUID = UUID(),
        assetID: UUID,
        displayName: String,
        note: String? = nil,
        createdAt: Date = .now,
        lastOpenedAt: Date? = nil,
        prefersOriginalColorsInDarkMode: Bool = false,
        folderID: UUID? = nil
    ) {
        self.id = id
        self.assetID = assetID
        self.displayName = displayName
        self.note = note
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.prefersOriginalColorsInDarkMode = prefersOriginalColorsInDarkMode
        self.folderID = folderID
    }

    private enum CodingKeys: String, CodingKey {
        case id, assetID, displayName, note, createdAt, lastOpenedAt
        case prefersOriginalColorsInDarkMode
        case folderID
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
        folderID = try container.decodeIfPresent(UUID.self, forKey: .folderID)
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
        try container.encodeIfPresent(folderID, forKey: .folderID)
    }
}

public enum PatternLibraryValidationError: Error, Equatable, Sendable {
    case duplicateFolderID
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
    public let folders: [PatternFolder]
    public let assets: [PatternAsset]
    public let patterns: [StoredPattern]
    public let usages: [PatternProjectUsage]
    public let validProjectIDs: [UUID]

    public init(
        folders: [PatternFolder] = [],
        assets: [PatternAsset],
        patterns: [StoredPattern],
        usages: [PatternProjectUsage],
        validProjectIDs: [UUID]
    ) {
        self.folders = folders
        self.assets = assets
        self.patterns = patterns
        self.usages = usages
        self.validProjectIDs = validProjectIDs
    }

    public func normalizedAndValidated(
        nameContext: PatternFolderNameContext? = nil
    ) throws -> PatternLibrarySnapshot {
        guard Set(folders.map(\.id)).count == folders.count else {
            throw PatternLibraryValidationError.duplicateFolderID
        }
        let normalizedFolders = try folders.map { folder in
            var folder = folder
            folder.displayName = folder.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !folder.displayName.isEmpty else {
                throw PatternFolderValidationError.emptyName
            }
            return folder
        }
        if !normalizedFolders.isEmpty {
            guard let nameContext else {
                throw PatternFolderValidationError.missingNameContext
            }
            var validatedFolders: [PatternFolder] = []
            for folder in normalizedFolders {
                _ = try PatternFolderNamePolicy.validatedName(
                    folder.displayName,
                    folders: validatedFolders,
                    excluding: nil,
                    nameContext: nameContext
                )
                validatedFolders.append(folder)
            }
        }
        let folderIDs = Set(normalizedFolders.map(\.id))
        let normalizedPatterns = patterns.map { pattern in
            var pattern = pattern
            if let folderID = pattern.folderID, !folderIDs.contains(folderID) {
                pattern.folderID = nil
            }
            return pattern
        }
        return try PatternLibrarySnapshot(
            folders: normalizedFolders,
            assets: assets,
            patterns: normalizedPatterns,
            usages: usages,
            validProjectIDs: validProjectIDs
        ).validatedReferences()
    }

    public func validated(
        nameContext: PatternFolderNameContext? = nil
    ) throws -> PatternLibrarySnapshot {
        try normalizedAndValidated(nameContext: nameContext)
    }

    private func validatedReferences() throws -> PatternLibrarySnapshot {
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
