import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum YarnPhotoFileError: Error, Equatable, Sendable {
    case invalidImage
    case encodingFailed
}

public enum YarnPhotoChange: Sendable {
    case unchanged
    case replace(Data)
    case remove
}

public struct YarnPhotoFileService: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func save(data: Data, yarnID: UUID) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw YarnPhotoFileError.invalidImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw YarnPhotoFileError.invalidImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw YarnPhotoFileError.encodingFailed
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw YarnPhotoFileError.encodingFailed
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "\(yarnID.uuidString)-\(UUID().uuidString).jpg"
        try (output as Data).write(to: url(filename: filename), options: .atomic)
        return filename
    }

    public func url(filename: String) -> URL {
        directory.appendingPathComponent(filename, isDirectory: false)
    }

    public func delete(filename: String) throws {
        let fileURL = url(filename: filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    func reconcile(referencedFilenames: Set<String>) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for candidate in candidates {
            let filename = candidate.lastPathComponent
            guard !referencedFilenames.contains(filename),
                  Self.isManagedFilename(filename),
                  try candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            try FileManager.default.removeItem(at: candidate)
        }
    }

    private static func isManagedFilename(_ filename: String) -> Bool {
        guard filename.hasSuffix(".jpg") else { return false }
        let stem = String(filename.dropLast(4))
        guard stem.count == 73 else { return false }
        let separator = stem.index(stem.startIndex, offsetBy: 36)
        guard stem[separator] == "-" else { return false }
        let firstID = String(stem[..<separator])
        let secondStart = stem.index(after: separator)
        let secondID = String(stem[secondStart...])
        return UUID(uuidString: firstID) != nil && UUID(uuidString: secondID) != nil
    }
}
