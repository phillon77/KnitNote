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
        let candidate = root.appendingPathComponent(filename).standardizedFileURL
        guard candidate.deletingLastPathComponent().path == root.path else {
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
