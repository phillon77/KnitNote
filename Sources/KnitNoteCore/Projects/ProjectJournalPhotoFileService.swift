import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ProjectJournalPhotoFileError: Error, Equatable, Sendable {
    case invalidImage
    case invalidFilename
    case encodingFailed
}

public enum ProjectJournalPhotoFilename {
    public static func isManaged(_ filename: String) -> Bool {
        components(filename, variant: .full) != nil || components(filename, variant: .thumbnail) != nil
    }

    public static func isFullImage(_ filename: String) -> Bool {
        components(filename, variant: .full) != nil
    }

    public static func isThumbnail(_ filename: String) -> Bool {
        components(filename, variant: .thumbnail) != nil
    }

    public static func isMatchingPair(full: String, thumbnail: String, entryID: UUID) -> Bool {
        guard let fullParts = components(full, variant: .full),
              let thumbnailParts = components(thumbnail, variant: .thumbnail) else {
            return false
        }
        return fullParts.projectID == thumbnailParts.projectID
            && fullParts.entryID == thumbnailParts.entryID
            && fullParts.token == thumbnailParts.token
            && fullParts.entryID == entryID
    }

    public static func isOwnedPair(
        full: String,
        thumbnail: String,
        projectID: UUID,
        entryID: UUID
    ) -> Bool {
        guard let fullParts = components(full, variant: .full),
              let thumbnailParts = components(thumbnail, variant: .thumbnail) else {
            return false
        }
        return fullParts.projectID == projectID
            && thumbnailParts.projectID == projectID
            && fullParts.entryID == entryID
            && thumbnailParts.entryID == entryID
            && fullParts.token == thumbnailParts.token
    }

    private enum Variant {
        case full
        case thumbnail

        var suffix: String {
            switch self {
            case .full: "-full.jpg"
            case .thumbnail: "-thumb.jpg"
            }
        }
    }

    private struct Components {
        let projectID: UUID
        let entryID: UUID
        let token: UUID
    }

    private static func components(_ filename: String, variant: Variant) -> Components? {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent else { return nil }
        guard filename.hasSuffix(variant.suffix) else { return nil }

        let stem = String(filename.dropLast(variant.suffix.count))
        guard stem.count == 110 else { return nil }
        let firstSeparator = stem.index(stem.startIndex, offsetBy: 36)
        let secondSeparator = stem.index(stem.startIndex, offsetBy: 73)
        guard stem[firstSeparator] == "-", stem[secondSeparator] == "-" else { return nil }

        let projectIDString = String(stem[..<firstSeparator])
        let entryStart = stem.index(after: firstSeparator)
        let entryIDString = String(stem[entryStart..<secondSeparator])
        let tokenStart = stem.index(after: secondSeparator)
        let tokenString = String(stem[tokenStart...])
        guard let projectID = UUID(uuidString: projectIDString),
              let entryID = UUID(uuidString: entryIDString),
              let token = UUID(uuidString: tokenString) else {
            return nil
        }
        return Components(projectID: projectID, entryID: entryID, token: token)
    }
}

public struct ProjectJournalPhotoFiles: Equatable, Sendable {
    public let photoFilename: String
    public let thumbnailFilename: String

    public init(photoFilename: String, thumbnailFilename: String) {
        self.photoFilename = photoFilename
        self.thumbnailFilename = thumbnailFilename
    }
}

public struct ProjectJournalPhotoFileService: Sendable {
    public let directory: URL

    private let writeData: @Sendable (Data, URL) throws -> Void

    public init(directory: URL) {
        self.init(directory: directory, writeData: Self.writeAtomically)
    }

    init(directory: URL, writeData: @escaping @Sendable (Data, URL) throws -> Void) {
        self.directory = directory
        self.writeData = writeData
    }

    public func save(data: Data, projectID: UUID, entryID: UUID) throws -> ProjectJournalPhotoFiles {
        let token = UUID().uuidString
        let files = ProjectJournalPhotoFiles(
            photoFilename: "\(projectID.uuidString)-\(entryID.uuidString)-\(token)-full.jpg",
            thumbnailFilename: "\(projectID.uuidString)-\(entryID.uuidString)-\(token)-thumb.jpg"
        )
        guard let fullURL = url(filename: files.photoFilename),
              let thumbnailURL = url(filename: files.thumbnailFilename) else {
            throw ProjectJournalPhotoFileError.invalidFilename
        }

        do {
            try Task.checkCancellation()
            let decoded = try decodedImage(data: data)
            try Task.checkCancellation()
            let fullData = try normalizedJPEG(decoded: decoded, maximumPixelSize: 1_600)
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeData(fullData, fullURL)
            try Task.checkCancellation()
            let thumbnailData = try normalizedJPEG(decoded: decoded, maximumPixelSize: 360)
            try Task.checkCancellation()
            try writeData(thumbnailData, thumbnailURL)
            try Task.checkCancellation()
            return files
        } catch {
            try? delete(files: files)
            throw error
        }
    }

    /// Returns a managed URL only for a generated journal filename; unsafe or
    /// unrecognized input returns `nil` without resolving a path.
    public func url(filename: String) -> URL? {
        guard ProjectJournalPhotoFilename.isManaged(filename) else { return nil }
        return directory.appendingPathComponent(filename, isDirectory: false)
    }

    public func delete(files: ProjectJournalPhotoFiles) throws {
        try delete(filename: files.photoFilename)
        try delete(filename: files.thumbnailFilename)
    }

    func delete(filenames: Set<String>) throws {
        for filename in filenames {
            try delete(filename: filename)
        }
    }

    public func reconcile(referencedFilenames: Set<String>) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }

        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for candidate in candidates {
            let filename = candidate.lastPathComponent
            guard !referencedFilenames.contains(filename),
                  ProjectJournalPhotoFilename.isManaged(filename),
                  try candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            try FileManager.default.removeItem(at: candidate)
        }
    }

    private func decodedImage(data: Data) throws -> DecodedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ProjectJournalPhotoFileError.invalidImage
        }
        return DecodedImage(source: source, width: width, height: height)
    }

    private func normalizedJPEG(decoded: DecodedImage, maximumPixelSize: Int) throws -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(
                max(decoded.width, decoded.height),
                maximumPixelSize
            )
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            decoded.source,
            0,
            options as CFDictionary
        ) else {
            throw ProjectJournalPhotoFileError.invalidImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ProjectJournalPhotoFileError.encodingFailed
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw ProjectJournalPhotoFileError.encodingFailed
        }
        return output as Data
    }

    private func delete(filename: String) throws {
        guard let fileURL = url(filename: filename) else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    private struct DecodedImage {
        let source: CGImageSource
        let width: Int
        let height: Int
    }
}
