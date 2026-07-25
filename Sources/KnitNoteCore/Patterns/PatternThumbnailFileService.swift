import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PatternThumbnailFileError: Error, Equatable, Sendable {
    case unreadableSource
    case renderingFailed
    case encodingFailed
}

public struct PatternThumbnailFileService: Sendable {
    public let directory: URL
    public let maxPixelSize: Int
    private let lock = PatternThumbnailFileLock()

    public init(directory: URL, maxPixelSize: Int = 800) {
        self.directory = directory
        self.maxPixelSize = max(1, maxPixelSize)
    }

    public func thumbnailURL(
        projectID: UUID,
        pattern: PatternDocument,
        sourceURL: URL
    ) throws -> URL {
        lock.value.lock()
        defer { lock.value.unlock() }
        let destination = cachedURL(projectID: projectID, patternID: pattern.id)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        let image: CGImage
        switch pattern.kind {
        case .pdf:
            image = try renderPDFPageOne(sourceURL)
        case .image:
            image = try renderImage(sourceURL)
        }
        let data = try encodeJPEG(image)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        return destination
    }

    public func cachedURL(projectID: UUID, patternID: UUID) -> URL {
        directory
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("\(patternID.uuidString).jpg")
    }

    public func delete(projectID: UUID, patternID: UUID) throws {
        lock.value.lock()
        defer { lock.value.unlock() }
        let url = cachedURL(projectID: projectID, patternID: patternID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func deleteProject(projectID: UUID) throws {
        lock.value.lock()
        defer { lock.value.unlock() }
        let url = directory.appendingPathComponent(projectID.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func deleteAll() throws {
        lock.value.lock()
        defer { lock.value.unlock() }
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private func renderImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                ] as CFDictionary
              ) else {
            throw PatternThumbnailFileError.unreadableSource
        }
        return image
    }

    private func renderPDFPageOne(_ url: URL) throws -> CGImage {
        guard let document = CGPDFDocument(url as CFURL),
              let page = document.page(at: 1) else {
            throw PatternThumbnailFileError.unreadableSource
        }
        let mediaBox = page.getBoxRect(.mediaBox)
        guard mediaBox.width > 0, mediaBox.height > 0 else {
            throw PatternThumbnailFileError.renderingFailed
        }
        let scale = min(CGFloat(maxPixelSize) / max(mediaBox.width, mediaBox.height), 1)
        let size = CGSize(
            width: max(1, (mediaBox.width * scale).rounded()),
            height: max(1, (mediaBox.height * scale).rounded())
        )
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: Int(size.width) * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PatternThumbnailFileError.renderingFailed
        }
        let target = CGRect(origin: .zero, size: size)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(target)
        context.concatenate(page.getDrawingTransform(
            .mediaBox,
            rect: target,
            rotate: 0,
            preserveAspectRatio: true
        ))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else {
            throw PatternThumbnailFileError.renderingFailed
        }
        return image
    }

    private func encodeJPEG(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw PatternThumbnailFileError.encodingFailed
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw PatternThumbnailFileError.encodingFailed
        }
        return output as Data
    }
}

private final class PatternThumbnailFileLock: @unchecked Sendable {
    let value = NSLock()
}
