import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ProjectPhotoFileError: Error, Equatable, Sendable {
    case invalidImage
    case encodingFailed
}

public struct ProjectPhotoFileService: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func save(data: Data, projectID: UUID) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ProjectPhotoFileError.invalidImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ProjectPhotoFileError.invalidImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ProjectPhotoFileError.encodingFailed
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw ProjectPhotoFileError.encodingFailed
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "\(projectID.uuidString)-\(UUID().uuidString).jpg"
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
}
