import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PatternFileError: Error, Equatable, Sendable {
    case empty
    case tooLarge
    case unsupported
    case invalidContent
    case unsafeStoredFilename
}

public struct PatternFileMetadata: Equatable, Sendable {
    public let kind: PatternKind
    public let fileExtension: String
    public let byteCount: Int64
    public let pageCount: Int?
    public let sha256: String
}

private struct PatternAssetImportJournal: Codable, Sendable {
    let itemID: UUID
    let asset: PatternAsset
}

public struct PatternFileService: Sendable {
    public let root: URL
    private let copyFile: @Sendable (URL, URL) throws -> Void
    private let moveFile: @Sendable (URL, URL) throws -> Void

    public init(root: URL) {
        self.root = root
        copyFile = { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
        }
        moveFile = { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    init(
        root: URL,
        copyFile: @escaping @Sendable (URL, URL) throws -> Void = {
            try FileManager.default.copyItem(at: $0, to: $1)
        },
        moveFile: @escaping @Sendable (URL, URL) throws -> Void = {
            try FileManager.default.moveItem(at: $0, to: $1)
        }
    ) {
        self.root = root
        self.copyFile = copyFile
        self.moveFile = moveFile
    }

    public static func live() throws -> PatternFileService {
        .init(root: try PatternStorageLocations.live().assetRoot)
    }

    public var assetsRoot: URL {
        root.appendingPathComponent("Assets", isDirectory: true)
    }

    private var assetCandidatesRoot: URL { assetsRoot.appendingPathComponent(".Candidates", isDirectory: true) }
    private var assetTransactionsRoot: URL { assetsRoot.appendingPathComponent(".Transactions", isDirectory: true) }

    public func inspect(_ source: URL, fileExtension declaredExtension: String? = nil) throws -> PatternFileMetadata {
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw PatternFileError.invalidContent
        }
        let byteCount = Int64(values.fileSize ?? 0)
        guard byteCount > 0 else { throw PatternFileError.empty }
        guard byteCount <= 100_000_000 else { throw PatternFileError.tooLarge }

        let fileExtension = (declaredExtension ?? source.pathExtension).lowercased()
        let kind: PatternKind
        let pageCount: Int?
        switch fileExtension {
        case "pdf":
            guard let document = CGPDFDocument(source as CFURL), document.numberOfPages > 0 else {
                throw PatternFileError.invalidContent
            }
            kind = .pdf
            pageCount = document.numberOfPages
        case "png", "jpg", "jpeg", "heic":
            guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
                  CGImageSourceGetCount(image) > 0,
                  let actualType = CGImageSourceGetType(image) as String? else {
                throw PatternFileError.invalidContent
            }
            let expectedType: String
            switch fileExtension {
            case "png": expectedType = UTType.png.identifier
            case "jpg", "jpeg": expectedType = UTType.jpeg.identifier
            case "heic": expectedType = UTType.heic.identifier
            default: preconditionFailure("Image extension was already checked")
            }
            guard actualType == expectedType else { throw PatternFileError.invalidContent }
            kind = .image
            pageCount = nil
        default:
            throw PatternFileError.unsupported
        }

        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        return PatternFileMetadata(
            kind: kind,
            fileExtension: fileExtension,
            byteCount: byteCount,
            pageCount: pageCount,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }

    public func installAsset(
        data: Data,
        metadata: PatternFileMetadata,
        id: UUID,
        transactionID: UUID? = nil
    ) throws -> PatternAsset {
        guard Int64(data.count) == metadata.byteCount,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == metadata.sha256 else {
            throw PatternFileError.invalidContent
        }
        let filename = "\(id.uuidString).\(metadata.fileExtension)"
        let destination = assetsRoot.appendingPathComponent(filename)
        let manager = FileManager.default
        try manager.createDirectory(at: assetsRoot, withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.path) {
            let existing = try inspect(destination)
            guard existing == metadata else { throw PatternFileError.invalidContent }
        } else {
            try manager.createDirectory(at: assetCandidatesRoot, withIntermediateDirectories: true)
            let candidate = assetCandidatesRoot.appendingPathComponent((transactionID ?? UUID()).uuidString)
            do {
                try data.write(to: candidate, options: .atomic)
                try moveFile(candidate, destination)
            } catch {
                try? manager.removeItem(at: candidate)
                throw error
            }
        }
        return PatternAsset(
            id: id,
            sha256: metadata.sha256,
            kind: metadata.kind,
            storedFilename: filename,
            byteCount: metadata.byteCount,
            pageCount: metadata.pageCount
        )
    }

    func beginImportTransaction(itemID: UUID, asset: PatternAsset) throws {
        try FileManager.default.createDirectory(at: assetTransactionsRoot, withIntermediateDirectories: true)
        try JSONEncoder().encode(PatternAssetImportJournal(itemID: itemID, asset: asset)).write(
            to: transactionURL(itemID),
            options: .atomic
        )
    }

    func completeImportTransaction(itemID: UUID) throws {
        let url = transactionURL(itemID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func rollbackImportTransaction(itemID: UUID) throws {
        guard let journal = try journal(itemID: itemID) else { return }
        try? removeIfOwned(candidateURL(itemID))
        try? deleteAsset(journal.asset)
        try? completeImportTransaction(itemID: itemID)
    }

    /// Returns inbox item identifiers whose journal proves that archive publication
    /// completed before its inbox manifest could be committed.
    func recoverImportTransactions(referencedAssetIDs: Set<UUID>) throws -> Set<UUID> {
        let manager = FileManager.default
        try manager.createDirectory(at: assetCandidatesRoot, withIntermediateDirectories: true)
        try manager.createDirectory(at: assetTransactionsRoot, withIntermediateDirectories: true)
        var publishedItems = Set<UUID>()
        for url in try manager.contentsOfDirectory(at: assetTransactionsRoot, includingPropertiesForKeys: nil) {
            guard let itemID = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  url.pathExtension == "json",
                  let journal = try? JSONDecoder().decode(PatternAssetImportJournal.self, from: Data(contentsOf: url)),
                  journal.itemID == itemID else { continue }
            if referencedAssetIDs.contains(journal.asset.id) {
                publishedItems.insert(itemID)
                try? removeIfOwned(candidateURL(itemID))
            } else {
                try? removeIfOwned(candidateURL(itemID))
                try? deleteAsset(journal.asset)
                try? manager.removeItem(at: url)
            }
        }
        // UUID-named asset candidates that have no durable journal are pre-publication
        // artifacts and are safe to remove without following links.
        for candidate in try manager.contentsOfDirectory(at: assetCandidatesRoot, includingPropertiesForKeys: nil) {
            if UUID(uuidString: candidate.lastPathComponent) != nil { try? removeIfOwned(candidate) }
        }
        // A final UUID-named file with no archive reference is owned but unpublished.
        for url in try manager.contentsOfDirectory(at: assetsRoot, includingPropertiesForKeys: nil) {
            guard let assetID = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  allowedExtensions.contains(url.pathExtension.lowercased()),
                  !referencedAssetIDs.contains(assetID) else { continue }
            try? removeIfOwned(url)
        }
        return publishedItems
    }

    public func assetURL(_ asset: PatternAsset) throws -> URL {
        let filename = asset.storedFilename
        let pieces = filename.split(separator: ".", maxSplits: 1)
        guard pieces.count == 2,
              UUID(uuidString: String(pieces[0])) == asset.id,
              String(pieces[0]) == asset.id.uuidString,
              allowedExtensions(for: asset.kind).contains(String(pieces[1]).lowercased()),
              filename == "\(asset.id.uuidString).\(pieces[1])" else {
            throw PatternFileError.unsafeStoredFilename
        }
        let root = assetsRoot.standardizedFileURL
        let physicalRoot = root.resolvingSymlinksInPath()
        guard physicalRoot.path == root.path else { throw PatternFileError.unsafeStoredFilename }
        let candidate = root.appendingPathComponent(filename).standardizedFileURL
        guard candidate.deletingLastPathComponent().path == root.path else {
            throw PatternFileError.unsafeStoredFilename
        }
        guard candidate.deletingLastPathComponent().resolvingSymlinksInPath().path == physicalRoot.path else {
            throw PatternFileError.unsafeStoredFilename
        }
        if FileManager.default.fileExists(atPath: candidate.path) {
            let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw PatternFileError.unsafeStoredFilename
            }
        }
        return candidate
    }

    public func exportURL(_ asset: PatternAsset) throws -> URL {
        try assetURL(asset)
    }

    public func deleteAsset(_ asset: PatternAsset) throws {
        let url = try assetURL(asset)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func allowedExtensions(for kind: PatternKind) -> Set<String> {
        switch kind {
        case .pdf: return ["pdf"]
        case .image: return ["png", "jpg", "jpeg", "heic"]
        }
    }

    private var allowedExtensions: Set<String> { ["pdf", "png", "jpg", "jpeg", "heic"] }
    private func transactionURL(_ id: UUID) -> URL { assetTransactionsRoot.appendingPathComponent("\(id.uuidString).json") }
    private func candidateURL(_ id: UUID) -> URL { assetCandidatesRoot.appendingPathComponent(id.uuidString) }
    private func journal(itemID: UUID) throws -> PatternAssetImportJournal? {
        let url = transactionURL(itemID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(PatternAssetImportJournal.self, from: Data(contentsOf: url))
    }
    private func removeIfOwned(_ url: URL) throws {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        guard [assetsRoot.standardizedFileURL.path, assetCandidatesRoot.standardizedFileURL.path].contains(parent) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // These compatibility APIs keep existing pre-library callers functional until Task 4 moves them.
    public func importFile(from source: URL, projectID: UUID) throws -> PatternDocument {
        let metadata = try inspect(source)
        let id = UUID()
        let dir = root.appendingPathComponent(projectID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = "\(id.uuidString).\(metadata.fileExtension)"
        try copyFile(source, dir.appendingPathComponent(filename))
        return PatternDocument(
            id: id,
            displayName: source.deletingPathExtension().lastPathComponent,
            kind: metadata.kind,
            storedFilename: filename
        )
    }

    public func url(projectID: UUID, pattern: PatternDocument) -> URL {
        root.appendingPathComponent(projectID.uuidString).appendingPathComponent(pattern.storedFilename)
    }

    public func delete(projectID: UUID, pattern: PatternDocument) throws {
        try FileManager.default.removeItem(at: url(projectID: projectID, pattern: pattern))
        try? PatternMarkupFileService(root: root).deletePatternMarkup(projectID: projectID, patternID: pattern.id)
    }
}
