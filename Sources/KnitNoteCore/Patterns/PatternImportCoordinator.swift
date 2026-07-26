import Foundation

public struct PatternImportCoordinator: Sendable {
    public init() {}

    public func prepare(
        item: PatternInboxItem,
        inbox: PatternInboxFileService,
        fileService: PatternFileService
    ) throws -> PreparedPatternImport {
        let source = try inbox.stagedURL(for: item)
        let metadata = try fileService.inspect(source)
        return PreparedPatternImport(
            item: item,
            data: try Data(contentsOf: source, options: .mappedIfSafe),
            metadata: metadata
        )
    }

    public func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
    }

    public func deterministicAssetID(for sha256: String) -> UUID {
        let value = String(sha256.prefix(32))
        let formatted = "\(value.prefix(8))-\(value.dropFirst(8).prefix(4))-\(value.dropFirst(12).prefix(4))-\(value.dropFirst(16).prefix(4))-\(value.dropFirst(20))"
        guard let id = UUID(uuidString: formatted) else {
            preconditionFailure("SHA-256 must have at least 32 hexadecimal characters.")
        }
        return id
    }
}

public struct PreparedPatternImport: Sendable {
    public let item: PatternInboxItem
    public let data: Data
    public let metadata: PatternFileMetadata
}
