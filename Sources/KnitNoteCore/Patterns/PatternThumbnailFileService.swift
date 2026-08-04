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
    public static let maximumExternalThumbnailBytes = 10 * 1_024 * 1_024
    public static let maximumExternalThumbnailDimension = 4_096

    public let directory: URL
    public let maxPixelSize: Int
    private let lock = PatternThumbnailFileLock()
    private let afterPageRender: @Sendable () -> Void

    public init(directory: URL, maxPixelSize: Int = 800) {
        self.init(
            directory: directory,
            maxPixelSize: maxPixelSize,
            afterPageRender: {}
        )
    }

    init(
        directory: URL,
        maxPixelSize: Int = 800,
        afterPageRender: @escaping @Sendable () -> Void
    ) {
        self.directory = directory
        self.maxPixelSize = max(1, maxPixelSize)
        self.afterPageRender = afterPageRender
    }

    public func thumbnailURL(
        asset: PatternAsset,
        sourceURL: URL
    ) throws -> URL {
        guard asset.kind != .youtube else {
            throw PatternThumbnailFileError.unreadableSource
        }
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
        case .youtube:
            throw PatternThumbnailFileError.unreadableSource
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
        try Task.checkCancellation()
        let destination = cachedPageURL(asset: asset, pageIndex: pageIndex)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        let image = try renderPDFPage(sourceURL, pageIndex: pageIndex)
        afterPageRender()
        try Task.checkCancellation()
        let data = try encodeJPEG(image)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Task.checkCancellation()
        try data.write(to: destination, options: .atomic)
        return destination
    }

    public func cachedURL(assetID: UUID) -> URL {
        directory
            .appendingPathComponent("\(assetID.uuidString).jpg")
    }

    /// Stores metadata artwork fetched from a remote pattern provider after
    /// first proving it is a bounded image. The cache contains only generated
    /// JPEGs, never the provider's original bytes.
    public func storeExternalThumbnail(data: Data, assetID: UUID) throws -> URL {
        let stagedURL = try stageExternalThumbnail(data: data, assetID: assetID)
        do {
            return try publishExternalThumbnail(stagedURL: stagedURL, assetID: assetID)
        } catch {
            try? discardExternalThumbnailStage(stagedURL)
            throw error
        }
    }

    /// Sanitizes remote artwork before it is kept in UI state. Consumers must
    /// display this generated JPEG rather than provider-owned source bytes.
    public func sanitizedExternalThumbnailData(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= Self.maximumExternalThumbnailBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0,
              width <= Self.maximumExternalThumbnailDimension,
              height <= Self.maximumExternalThumbnailDimension,
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
        return try encodeJPEG(image)
    }

    func stageExternalThumbnail(data: Data, assetID: UUID) throws -> URL {
        let jpeg = try sanitizedExternalThumbnailData(data)

        lock.value.lock()
        defer { lock.value.unlock() }
        let stagingDirectory = externalThumbnailStagingDirectory
        // Validate both paths before any directory-creation side effect. In
        // particular, do not let a symlinked cache root create a staging
        // directory outside the cache root.
        guard !isSymbolicLink(directory),
              !isSymbolicLink(stagingDirectory) else {
            throw PatternThumbnailFileError.unreadableSource
        }
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        guard !isSymbolicLink(directory),
              !isSymbolicLink(stagingDirectory) else {
            throw PatternThumbnailFileError.unreadableSource
        }
        let destination = stagingDirectory.appendingPathComponent(
            "\(assetID.uuidString)-\(UUID().uuidString).jpg"
        )
        try jpeg.write(to: destination, options: .atomic)
        return destination
    }

    func publishExternalThumbnail(stagedURL: URL, assetID: UUID) throws -> URL {
        lock.value.lock()
        defer { lock.value.unlock() }
        let stagingDirectory = externalThumbnailStagingDirectory
        let destination = cachedURL(assetID: assetID)
        guard stagedURL.deletingLastPathComponent().standardizedFileURL == stagingDirectory.standardizedFileURL,
              !isSymbolicLink(stagingDirectory),
              !isSymbolicLink(stagedURL) else {
            throw PatternThumbnailFileError.unreadableSource
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard !isSymbolicLink(destination.deletingLastPathComponent()),
              !isSymbolicLink(destination) else {
            throw PatternThumbnailFileError.unreadableSource
        }
        let jpeg = try Data(contentsOf: stagedURL)
        try jpeg.write(to: destination, options: .atomic)
        try? FileManager.default.removeItem(at: stagedURL)
        return destination
    }

    func discardExternalThumbnailStage(_ stagedURL: URL) throws {
        lock.value.lock()
        defer { lock.value.unlock() }
        guard stagedURL.deletingLastPathComponent().standardizedFileURL
            == externalThumbnailStagingDirectory.standardizedFileURL else {
            throw PatternThumbnailFileError.unreadableSource
        }
        guard FileManager.default.fileExists(atPath: stagedURL.path) else { return }
        try FileManager.default.removeItem(at: stagedURL)
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

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private var externalThumbnailStagingDirectory: URL {
        directory.appendingPathComponent(".ExternalThumbnailStaging", isDirectory: true)
    }
}

private final class PatternThumbnailFileLock: @unchecked Sendable {
    let value = NSLock()
}
