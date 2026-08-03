import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum YarnLabelPhotoFileError: Error, Equatable, Sendable {
    case invalidImage
    case invalidOrdinal
    case invalidFilename
    case imageTooLarge
    case encodingFailed
}

public struct PreparedYarnLabelPhoto: Equatable, Sendable {
    public let filename: String
    public let temporaryURL: URL

    public init(filename: String, temporaryURL: URL) {
        self.filename = filename
        self.temporaryURL = temporaryURL
    }
}

public struct YarnLabelPhotoFileService: Sendable {
    public let directory: URL

    private static let maximumInputBytes = 30 * 1_024 * 1_024
    private static let maximumDecodedPixels = 80_000_000
    private static let maximumEncodedBytes = 8 * 1_024 * 1_024

    public init(directory: URL) {
        self.directory = directory
    }

    public func prepare(data: Data, yarnID: UUID, ordinal: Int) throws -> PreparedYarnLabelPhoto {
        guard ordinal == 1 || ordinal == 2 else {
            throw YarnLabelPhotoFileError.invalidOrdinal
        }
        guard data.count <= Self.maximumInputBytes else {
            throw YarnLabelPhotoFileError.imageTooLarge
        }
        try Task.checkCancellation()
        let normalized = try normalizedJPEG(data)
        guard normalized.count <= Self.maximumEncodedBytes else {
            throw YarnLabelPhotoFileError.imageTooLarge
        }
        try Task.checkCancellation()

        let filename = "\(yarnID.uuidString)-label-\(ordinal)-\(UUID().uuidString).jpg"
        guard StoredYarn.isManagedLabelPhotoFilename(filename, yarnID: yarnID) else {
            throw YarnLabelPhotoFileError.invalidFilename
        }
        let transactionDirectory = directory
            .appendingPathComponent(".transactions", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: transactionDirectory,
            withIntermediateDirectories: true
        )
        let temporaryURL = transactionDirectory.appendingPathComponent(filename, isDirectory: false)
        do {
            try normalized.write(to: temporaryURL, options: [.atomic])
            try Task.checkCancellation()
            return PreparedYarnLabelPhoto(filename: filename, temporaryURL: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: transactionDirectory)
            throw error
        }
    }

    public func publish(_ prepared: PreparedYarnLabelPhoto) throws {
        guard let finalURL = url(filename: prepared.filename),
              isOwnedTransactionURL(prepared.temporaryURL),
              prepared.temporaryURL.lastPathComponent == prepared.filename else {
            throw YarnLabelPhotoFileError.invalidFilename
        }
        let values = try prepared.temporaryURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw YarnLabelPhotoFileError.invalidFilename
        }
        guard !FileManager.default.fileExists(atPath: finalURL.path) else {
            throw YarnLabelPhotoFileError.invalidFilename
        }
        try FileManager.default.moveItem(at: prepared.temporaryURL, to: finalURL)
        try? removeEmptyTransactionParents(of: prepared.temporaryURL)
    }

    public func rollback(_ prepared: PreparedYarnLabelPhoto) throws {
        guard isOwnedTransactionURL(prepared.temporaryURL) else {
            throw YarnLabelPhotoFileError.invalidFilename
        }
        if FileManager.default.fileExists(atPath: prepared.temporaryURL.path) {
            try FileManager.default.removeItem(at: prepared.temporaryURL)
        }
        try? removeEmptyTransactionParents(of: prepared.temporaryURL)
    }

    public func url(filename: String) -> URL? {
        guard Self.isManagedFilename(filename) else { return nil }
        return directory.appendingPathComponent(filename, isDirectory: false)
    }

    public func delete(filename: String) throws {
        guard let fileURL = url(filename: filename) else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    public func totalStorageBytes() throws -> Int64 {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        return try files.reduce(into: Int64(0)) { total, file in
            guard Self.isManagedFilename(file.lastPathComponent) else { return }
            let values = try file.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize else {
                return
            }
            total += Int64(size)
        }
    }

    private func normalizedJPEG(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0,
              width <= Self.maximumDecodedPixels / height else {
            throw YarnLabelPhotoFileError.invalidImage
        }
        let pixelCount = width * height
        guard pixelCount <= Self.maximumDecodedPixels else {
            throw YarnLabelPhotoFileError.imageTooLarge
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), 1_600),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw YarnLabelPhotoFileError.invalidImage
        }
        for quality in [0.78, 0.68, 0.58, 0.48] {
            let encoded = try encodeJPEG(image, quality: quality)
            if encoded.count <= 400_000 || quality == 0.48 {
                return encoded
            }
        }
        throw YarnLabelPhotoFileError.encodingFailed
    }

    private func encodeJPEG(_ image: CGImage, quality: Double) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw YarnLabelPhotoFileError.encodingFailed
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw YarnLabelPhotoFileError.encodingFailed
        }
        return try Self.removingJPEGMetadata(from: output as Data)
    }

    private static func removingJPEGMetadata(from data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            throw YarnLabelPhotoFileError.encodingFailed
        }

        var output = Data(bytes.prefix(2))
        var index = 2
        while index < bytes.count {
            let markerStart = index
            guard bytes[index] == 0xFF else {
                throw YarnLabelPhotoFileError.encodingFailed
            }
            while index < bytes.count, bytes[index] == 0xFF { index += 1 }
            guard index < bytes.count else {
                throw YarnLabelPhotoFileError.encodingFailed
            }
            let marker = bytes[index]
            index += 1

            if marker == 0xDA {
                output.append(contentsOf: bytes[markerStart...])
                return output
            }
            if marker == 0xD9 {
                output.append(contentsOf: bytes[markerStart..<index])
                return output
            }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) {
                output.append(contentsOf: bytes[markerStart..<index])
                continue
            }

            guard index + 1 < bytes.count else {
                throw YarnLabelPhotoFileError.encodingFailed
            }
            let segmentLength = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            guard segmentLength >= 2, index + segmentLength <= bytes.count else {
                throw YarnLabelPhotoFileError.encodingFailed
            }
            let segmentEnd = index + segmentLength
            let isMetadata = (0xE0...0xEF).contains(marker) || marker == 0xFE
            if !isMetadata {
                output.append(contentsOf: bytes[markerStart..<segmentEnd])
            }
            index = segmentEnd
        }
        throw YarnLabelPhotoFileError.encodingFailed
    }

    private func isOwnedTransactionURL(_ url: URL) -> Bool {
        let transactionRoot = directory.appendingPathComponent(".transactions", isDirectory: true)
            .standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        return candidate.hasPrefix(transactionRoot + "/")
    }

    private func removeEmptyTransactionParents(of url: URL) throws {
        let transaction = url.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: transaction.path).isEmpty) == true {
            try FileManager.default.removeItem(at: transaction)
        }
        let root = transaction.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty) == true {
            try FileManager.default.removeItem(at: root)
        }
    }

    private static func isManagedFilename(_ filename: String) -> Bool {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent,
              filename.count > 36,
              let separator = filename.index(filename.startIndex, offsetBy: 36, limitedBy: filename.endIndex),
              filename[separator] == "-",
              let yarnID = UUID(uuidString: String(filename[..<separator])) else {
            return false
        }
        return StoredYarn.isManagedLabelPhotoFilename(filename, yarnID: yarnID)
    }
}
