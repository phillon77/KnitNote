import Foundation

public struct PatternFolder: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String
    public let createdAt: Date

    public init(id: UUID = UUID(), displayName: String, createdAt: Date = .now) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
    }
}

public enum PatternLibraryScope: Hashable, Sendable {
    case all
    case uncategorized
    case folder(UUID)
}

public struct PatternFolderNameContext: Sendable {
    public let locale: Locale
    public let reservedNames: Set<String>

    public init(locale: Locale, reservedNames: Set<String>) {
        self.locale = locale
        self.reservedNames = reservedNames
    }
}

public enum PatternFolderValidationError: Error, Equatable, Sendable {
    case emptyName
    case duplicateName
    case reservedName
}

public enum PatternFolderNamePolicy {
    public static func validatedName(
        _ proposed: String,
        folders: [PatternFolder],
        excluding excludedID: UUID?,
        nameContext: PatternFolderNameContext
    ) throws -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PatternFolderValidationError.emptyName }

        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        func matches(_ value: String) -> Bool {
            value.compare(trimmed, options: options, locale: nameContext.locale) == .orderedSame
        }

        guard !nameContext.reservedNames.contains(where: matches) else {
            throw PatternFolderValidationError.reservedName
        }
        guard !folders.contains(where: { $0.id != excludedID && matches($0.displayName) }) else {
            throw PatternFolderValidationError.duplicateName
        }
        return trimmed
    }
}
