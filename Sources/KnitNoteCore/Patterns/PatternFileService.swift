import CryptoKit
import CoreGraphics
import Foundation
import ImageIO

public enum PatternFileError: Error, Equatable, Sendable {
    case empty
    case tooLarge
    case unsupported
    case invalidContent
}

public struct PatternFileMetadata: Equatable, Sendable {
    public let kind: PatternKind
    public let fileExtension: String
    public let byteCount: Int64
    public let pageCount: Int?
    public let sha256: String
}

public struct PatternFileService: Sendable {
    public let root: URL
    private let copyFile: @Sendable (URL, URL) throws -> Void

    public init(root: URL) {
        self.root = root
        copyFile = { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    init(root: URL, copyFile: @escaping @Sendable (URL, URL) throws -> Void) {
        self.root = root
        self.copyFile = copyFile
    }

    public static func live() -> PatternFileService {
        let locations = try? PatternStorageLocations.live()
        return .init(root: locations?.assetRoot ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("KnitNote/Patterns"))
    }

    public var assetsRoot: URL {
        root.appendingPathComponent("Assets", isDirectory: true)
    }

    public func inspect(_ source: URL, fileExtension declaredExtension: String? = nil) throws -> PatternFileMetadata {
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile != false else { throw PatternFileError.invalidContent }
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
                  CGImageSourceGetCount(image) > 0 else {
                throw PatternFileError.invalidContent
            }
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
        id: UUID
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
            let candidates = assetsRoot.appendingPathComponent(".Candidates", isDirectory: true)
            try manager.createDirectory(at: candidates, withIntermediateDirectories: true)
            let candidate = candidates.appendingPathComponent(UUID().uuidString)
            do {
                try data.write(to: candidate, options: .atomic)
                try manager.moveItem(at: candidate, to: destination)
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

    public func assetURL(_ asset: PatternAsset) -> URL {
        assetsRoot.appendingPathComponent(asset.storedFilename)
    }

    public func exportURL(_ asset: PatternAsset) -> URL {
        assetURL(asset)
    }

    public func deleteAsset(_ asset: PatternAsset) throws {
        let url = assetURL(asset)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
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
