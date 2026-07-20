import Foundation

public enum ProjectJournalEntryError: Error, Equatable, Sendable {
    case invalidFilename
    case duplicateIdentifier
}

public enum ProjectJournalMutationError: Error, Equatable, Sendable {
    case projectCompleted
    case entryNotFound
}

public struct ProjectJournalEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let photoFilename: String
    public let thumbnailFilename: String
    public private(set) var caption: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        photoFilename: String,
        thumbnailFilename: String,
        caption: String?,
        createdAt: Date = .now
    ) throws {
        let photo = photoFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        let thumbnail = thumbnailFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProjectJournalPhotoFilename.isMatchingPair(
            full: photo,
            thumbnail: thumbnail,
            entryID: id
        ) else {
            throw ProjectJournalEntryError.invalidFilename
        }

        self.id = id
        self.photoFilename = photo
        self.thumbnailFilename = thumbnail
        self.caption = Self.normalizedCaption(caption)
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(UUID.self, forKey: .id),
            photoFilename: values.decode(String.self, forKey: .photoFilename),
            thumbnailFilename: values.decode(String.self, forKey: .thumbnailFilename),
            caption: values.decodeIfPresent(String.self, forKey: .caption),
            createdAt: values.decode(Date.self, forKey: .createdAt)
        )
    }

    @discardableResult
    public mutating func updateCaption(_ value: String?) -> Bool {
        let normalized = Self.normalizedCaption(value)
        guard caption != normalized else { return false }
        caption = normalized
        return true
    }

    private static func normalizedCaption(_ value: String?) -> String? {
        guard let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty else {
            return nil
        }
        return clean
    }
}
