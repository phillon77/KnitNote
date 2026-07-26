import CryptoKit
import Foundation

private struct PatternInboxPublicationReceipt: Codable, Sendable {
    private struct Payload: Codable {
        let version: Int
        let item: PatternInboxItem
        let normalizedOriginalFilename: String
        let patternID: UUID
        let assetID: UUID
        let targetProjectID: UUID?
    }

    let version: Int
    let item: PatternInboxItem
    let normalizedOriginalFilename: String
    let patternID: UUID
    let assetID: UUID
    let targetProjectID: UUID?
    let integrity: String

    init(item: PatternInboxItem, pattern: StoredPattern) {
        version = 1
        self.item = item
        normalizedOriginalFilename = Self.normalizedFilename(item.originalFilename)
        patternID = pattern.id
        assetID = pattern.assetID
        targetProjectID = item.targetProjectID
        integrity = Self.integrity(for: .init(
            version: version,
            item: item,
            normalizedOriginalFilename: normalizedOriginalFilename,
            patternID: pattern.id,
            assetID: pattern.assetID,
            targetProjectID: item.targetProjectID
        ))
    }

    var hasValidIntegrity: Bool {
        version == 1 && integrity == Self.integrity(for: .init(
            version: version,
            item: item,
            normalizedOriginalFilename: normalizedOriginalFilename,
            patternID: patternID,
            assetID: assetID,
            targetProjectID: targetProjectID
        ))
    }

    private static func integrity(for payload: Payload) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(payload)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func normalizedFilename(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .init(identifier: "en_US_POSIX")
            )
    }
}

public struct PatternInboxPublicationReceiptService: Sendable {
    public let root: URL
    private let removeItem: @Sendable (URL) throws -> Void

    public init(root: URL) {
        self.root = root
        removeItem = { try FileManager.default.removeItem(at: $0) }
    }

    init(
        root: URL,
        removeItem: @escaping @Sendable (URL) throws -> Void
    ) {
        self.root = root
        self.removeItem = removeItem
    }

    func begin(item: PatternInboxItem, pattern: StoredPattern) throws {
        try validateOwnedTree()
        try FileManager.default.createDirectory(at: receiptsRoot, withIntermediateDirectories: true)
        try JSONEncoder().encode(
            PatternInboxPublicationReceipt(item: item, pattern: pattern)
        ).write(to: receiptURL(item.id), options: .atomic)
    }

    func complete(itemID: UUID) throws {
        try validateOwnedTree()
        let url = receiptURL(itemID)
        if FileManager.default.fileExists(atPath: url.path) {
            try removeItem(url)
        }
    }

    func recover(
        patterns: [StoredPattern],
        usages: [PatternProjectUsage],
        inbox: PatternInboxFileService
    ) throws -> Set<UUID> {
        try validateOwnedTree()
        let manager = FileManager.default
        try manager.createDirectory(at: receiptsRoot, withIntermediateDirectories: true)
        var publishedItems = Set<UUID>()

        for url in try manager.contentsOfDirectory(at: receiptsRoot, includingPropertiesForKeys: nil) {
            guard url.pathExtension == "json" else { continue }
            guard let itemID = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  try isRegularNonSymlink(url),
                  let receipt = try? JSONDecoder().decode(
                    PatternInboxPublicationReceipt.self,
                    from: Data(contentsOf: url)
                  ),
                  receipt.hasValidIntegrity,
                  receipt.item.id == itemID,
                  receipt.normalizedOriginalFilename
                    == PatternInboxPublicationReceipt.normalizedFilename(
                        receipt.item.originalFilename
                    ) else {
                try quarantine(url)
                continue
            }

            guard let staged = try inbox.journalVerificationItem(id: itemID) else {
                try manager.removeItem(at: url)
                continue
            }
            guard staged.item == receipt.item else {
                try quarantine(url)
                continue
            }

            let exactPatternExists = patterns.contains {
                $0.id == receipt.patternID && $0.assetID == receipt.assetID
            }
            let requiredUsageExists = receipt.targetProjectID.map { projectID in
                usages.contains {
                    $0.patternID == receipt.patternID
                        && $0.projectID == projectID
                        && $0.isActive
                }
            } ?? true

            if exactPatternExists && requiredUsageExists {
                publishedItems.insert(itemID)
            } else {
                try manager.removeItem(at: url)
            }
        }
        return publishedItems
    }

    private var receiptsRoot: URL {
        root.appendingPathComponent("Assets/.PublicationReceipts", isDirectory: true)
    }

    private var quarantineRoot: URL {
        receiptsRoot.appendingPathComponent(".Quarantine", isDirectory: true)
    }

    private func receiptURL(_ id: UUID) -> URL {
        receiptsRoot.appendingPathComponent("\(id.uuidString).json")
    }

    private func validateOwnedTree() throws {
        let assetsRoot = root.appendingPathComponent("Assets", isDirectory: true).standardizedFileURL
        guard assetsRoot.resolvingSymlinksInPath().path == assetsRoot.path else {
            throw PatternFileError.unsafeStoredFilename
        }
        for directory in [receiptsRoot, quarantineRoot] {
            let lexical = directory.standardizedFileURL
            guard lexical.resolvingSymlinksInPath().path == lexical.path else {
                throw PatternFileError.unsafeStoredFilename
            }
        }
    }

    private func isRegularNonSymlink(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func quarantine(_ url: URL) throws {
        try validateOwnedTree()
        guard url.deletingLastPathComponent().standardizedFileURL.path
                == receiptsRoot.standardizedFileURL.path,
              UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
              url.pathExtension == "json" else { return }
        try FileManager.default.createDirectory(at: quarantineRoot, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: url,
            to: quarantineRoot.appendingPathComponent("\(UUID().uuidString).receipt")
        )
    }
}
