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
        asset: PatternAsset,
        sourceURL: URL
    ) throws -> URL {
        lock.value.lock()
        defer { lock.value.unlock() }
        let destination = cachedURL(assetID: asset.id)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        let image: CGImage
        switch asset.kind {
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

    public func thumbnailURL(
        asset: PatternAsset,
        sourceURL: URL,
        pageIndex: Int
    ) throws -> URL {
        guard asset.kind == .pdf, pageIndex >= 0 else {
            throw PatternThumbnailFileError.unreadableSource
        }
        lock.value.lock()
        defer { lock.value.unlock() }
        let destination = cachedPageURL(asset: asset, pageIndex: pageIndex)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        let image = try renderPDFPage(sourceURL, pageIndex: pageIndex)
        let data = try encodeJPEG(image)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        return destination
    }

    public func cachedURL(assetID: UUID) -> URL {
        directory
            .appendingPathComponent("\(assetID.uuidString).jpg")
    }

    public func cachedPageURL(asset: PatternAsset, pageIndex: Int) -> URL {
        let safeSHA = asset.sha256.allSatisfy(\.isHexDigit) && !asset.sha256.isEmpty
            ? asset.sha256
            : "unknown"
        return directory.appendingPathComponent(
            "\(asset.id.uuidString)-\(safeSHA)-page-\(max(0, pageIndex)).jpg"
        )
    }

    public func delete(assetID: UUID) throws {
        lock.value.lock()
        defer { lock.value.unlock() }
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let coverURL = cachedURL(assetID: assetID)
        if FileManager.default.fileExists(atPath: coverURL.path) {
            try FileManager.default.removeItem(at: coverURL)
        }
        let pagePrefix = "\(assetID.uuidString)-"
        for url in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) where url.lastPathComponent.hasPrefix(pagePrefix)
            && url.lastPathComponent.contains("-page-")
            && url.pathExtension == "jpg" {
            try FileManager.default.removeItem(at: url)
        }
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
        try renderPDFPage(url, pageIndex: 0)
    }

    private func renderPDFPage(_ url: URL, pageIndex: Int) throws -> CGImage {
        guard let document = CGPDFDocument(url as CFURL),
              let page = document.page(at: pageIndex + 1) else {
            throw PatternThumbnailFileError.unreadableSource
        }
        let mediaBox = page.getBoxRect(.mediaBox)
        guard mediaBox.width > 0, mediaBox.height > 0 else {
            throw PatternThumbnailFileError.renderingFailed
        }
        let swapsDimensions = page.rotationAngle % 180 != 0
        let displayedSize = swapsDimensions
            ? CGSize(width: mediaBox.height, height: mediaBox.width)
            : mediaBox.size
        let scale = min(
            CGFloat(maxPixelSize) / max(displayedSize.width, displayedSize.height),
            1
        )
        let size = CGSize(
            width: max(1, (displayedSize.width * scale).rounded()),
            height: max(1, (displayedSize.height * scale).rounded())
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
