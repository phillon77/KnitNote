import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import KnitNoteCore

@Suite struct PatternThumbnailFileServiceTests {
    @Test func rendersPDFPageOneAndImagePatternsAsBoundedJPEG() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sources = root.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let pdfURL = sources.appendingPathComponent("chart.pdf")
        let imageURL = sources.appendingPathComponent("chart.png")
        try makePDF(at: pdfURL, size: CGSize(width: 1_200, height: 600))
        try makePNG(at: imageURL, width: 600, height: 1_200)
        let service = PatternThumbnailFileService(
            directory: root.appendingPathComponent("cache"),
            maxPixelSize: 800
        )
        let pdf = asset(kind: .pdf, filename: "chart.pdf")
        let image = asset(kind: .image, filename: "chart.png")

        let pdfThumbnail = try service.thumbnailURL(
            asset: pdf,
            sourceURL: pdfURL
        )
        let imageThumbnail = try service.thumbnailURL(
            asset: image,
            sourceURL: imageURL
        )

        #expect(try pixelSize(pdfThumbnail) == CGSize(width: 800, height: 400))
        #expect(try pixelSize(imageThumbnail) == CGSize(width: 400, height: 800))
        #expect(pdfThumbnail.pathExtension == "jpg")
        #expect(imageThumbnail.pathExtension == "jpg")
    }

    @Test func rendersRotatedPDFUsingDisplayedPageGeometry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceURL = root.appendingPathComponent("rotated.pdf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeRotatedPDF(
            at: sourceURL,
            size: CGSize(width: 1_200, height: 600),
            rotation: 90
        )
        let document = try #require(CGPDFDocument(sourceURL as CFURL))
        #expect(document.page(at: 1)?.rotationAngle == 90)
        let service = PatternThumbnailFileService(
            directory: root.appendingPathComponent("cache"),
            maxPixelSize: 800
        )
        let pattern = asset(kind: .pdf, filename: "rotated.pdf")

        let thumbnailURL = try service.thumbnailURL(
            asset: pattern,
            sourceURL: sourceURL
        )

        #expect(try pixelSize(thumbnailURL) == CGSize(width: 400, height: 800))
    }

    @Test func reusesSharedCacheAndDeletesOneAsset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makePNG(at: source, width: 40, height: 20)
        let service = PatternThumbnailFileService(directory: root.appendingPathComponent("cache"))
        let sharedAsset = asset(kind: .image, filename: "source.png")
        let firstURL = try service.thumbnailURL(asset: sharedAsset, sourceURL: source)
        let originalDate = try #require(
            try firstURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )
        let reusedURL = try service.thumbnailURL(asset: sharedAsset, sourceURL: source)

        #expect(reusedURL == firstURL)
        #expect(try reusedURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == originalDate)
        try service.delete(assetID: sharedAsset.id)
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        let otherAssetURL = try service.thumbnailURL(
            asset: asset(kind: .image, filename: "other.png"),
            sourceURL: source
        )
        try service.deleteAll()
        #expect(!FileManager.default.fileExists(atPath: otherAssetURL.path))
    }

    @Test func twoPatternsForOneAssetUseOneThumbnailPath() {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let assetID = UUID()
        let service = PatternThumbnailFileService(directory: cacheRoot)

        #expect(service.cachedURL(assetID: assetID) == service.cachedURL(assetID: assetID))
        #expect(service.cachedURL(assetID: assetID).lastPathComponent == "\(assetID.uuidString).jpg")
    }

    @Test func concurrentRequestsShareOneValidCachedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makePNG(at: source, width: 640, height: 320)
        let service = PatternThumbnailFileService(directory: root.appendingPathComponent("cache"))
        let pattern = asset(kind: .image, filename: "chart.png")

        let urls = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try service.thumbnailURL(
                        asset: pattern,
                        sourceURL: source
                    )
                }
            }
            var results: [URL] = []
            for try await url in group {
                results.append(url)
            }
            return results
        }

        #expect(Set(urls).count == 1)
        #expect(try pixelSize(try #require(urls.first)) == CGSize(width: 640, height: 320))
    }

    private func makePDF(at url: URL, size: CGSize) throws {
        var box = CGRect(origin: .zero, size: size)
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.6, alpha: 1))
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
    }

    private func makeRotatedPDF(
        at url: URL,
        size: CGSize,
        rotation: Int
    ) throws {
        let unrotatedURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: unrotatedURL) }
        try makePDF(at: unrotatedURL, size: size)
        let document = try #require(PDFDocument(url: unrotatedURL))
        let page = try #require(document.page(at: 0))
        page.rotation = rotation
        #expect(document.write(to: url))
    }

    private func makePNG(at url: URL, width: Int, height: Int) throws {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func pixelSize(_ url: URL) throws -> CGSize {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return CGSize(
            width: try #require(properties[kCGImagePropertyPixelWidth] as? Int),
            height: try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        )
    }

    private func asset(kind: PatternKind, filename: String) -> PatternAsset {
        PatternAsset(
            id: UUID(),
            sha256: "test-hash-\(UUID().uuidString)",
            kind: kind,
            storedFilename: filename,
            byteCount: 0,
            pageCount: kind == .pdf ? 1 : nil
        )
    }
}
