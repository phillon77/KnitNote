import CoreGraphics
import Dispatch
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import KnitNoteCore

@Suite struct PatternThumbnailFileServiceTests {
    @Test func pageThumbnailRendersTheRequestedPDFPageAndUsesVersionedCacheKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pdfURL = root.appendingPathComponent("three-pages.pdf")
        try makeSolidColorPDF(
            at: pdfURL,
            colors: [
                RGB(red: 255, green: 0, blue: 0),
                RGB(red: 0, green: 255, blue: 0),
                RGB(red: 0, green: 0, blue: 255)
            ]
        )
        let service = PatternThumbnailFileService(
            directory: root.appendingPathComponent("cache"),
            maxPixelSize: 240
        )
        let assetID = UUID()
        let pdfAsset = asset(
            id: assetID,
            sha256: String(repeating: "a", count: 64),
            kind: .pdf,
            filename: "three-pages.pdf",
            pageCount: 3
        )

        let first = try service.thumbnailURL(asset: pdfAsset, sourceURL: pdfURL, pageIndex: 0)
        let second = try service.thumbnailURL(asset: pdfAsset, sourceURL: pdfURL, pageIndex: 1)
        let third = try service.thumbnailURL(asset: pdfAsset, sourceURL: pdfURL, pageIndex: 2)
        let updatedAsset = asset(
            id: assetID,
            sha256: String(repeating: "b", count: 64),
            kind: .pdf,
            filename: "three-pages.pdf",
            pageCount: 3
        )
        let updated = try service.thumbnailURL(asset: updatedAsset, sourceURL: pdfURL, pageIndex: 0)

        let firstColor = try centerRGB(first)
        let secondColor = try centerRGB(second)
        let thirdColor = try centerRGB(third)
        try FileManager.default.removeItem(at: pdfURL)
        let reused = try service.thumbnailURL(asset: pdfAsset, sourceURL: pdfURL, pageIndex: 0)

        #expect(first != second)
        #expect(second != third)
        #expect(firstColor != secondColor)
        #expect(secondColor != thirdColor)
        #expect(firstColor.red > firstColor.green && firstColor.red > firstColor.blue)
        #expect(secondColor.green > secondColor.red && secondColor.green > secondColor.blue)
        #expect(thirdColor.blue > thirdColor.red && thirdColor.blue > thirdColor.green)
        #expect(first == service.cachedPageURL(asset: pdfAsset, pageIndex: 0))
        #expect(reused == first)
        #expect(try centerRGB(reused) == firstColor)
        #expect(updated != first)
        #expect(service.cachedPageURL(asset: pdfAsset, pageIndex: 1) != first)
    }

    @Test func cancellationAfterPageRenderDoesNotWriteThePageCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pdfURL = root.appendingPathComponent("three-pages.pdf")
        try makeSolidColorPDF(
            at: pdfURL,
            colors: [
                RGB(red: 255, green: 0, blue: 0),
                RGB(red: 0, green: 255, blue: 0),
                RGB(red: 0, green: 0, blue: 255)
            ]
        )
        let blocker = PageThumbnailServiceRenderBlocker()
        let service = PatternThumbnailFileService(
            directory: root.appendingPathComponent("cache"),
            maxPixelSize: 240,
            afterPageRender: { blocker.block() }
        )
        let pdfAsset = asset(
            sha256: String(repeating: "d", count: 64),
            kind: .pdf,
            filename: "three-pages.pdf",
            pageCount: 3
        )
        let cachedURL = service.cachedPageURL(asset: pdfAsset, pageIndex: 1)
        defer { blocker.resume() }

        let request = Task.detached {
            try? service.thumbnailURL(asset: pdfAsset, sourceURL: pdfURL, pageIndex: 1)
        }
        #expect(await Task.detached { blocker.waitUntilBlocked() }.value)

        request.cancel()
        blocker.resume()

        #expect(await request.value == nil)
        #expect(!FileManager.default.fileExists(atPath: cachedURL.path))
    }

    @Test func deletingAnAssetRemovesItsCoverAndAllPageThumbnails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pdfURL = root.appendingPathComponent("three-pages.pdf")
        try makeSolidColorPDF(
            at: pdfURL,
            colors: [
                RGB(red: 255, green: 0, blue: 0),
                RGB(red: 0, green: 255, blue: 0),
                RGB(red: 0, green: 0, blue: 255)
            ]
        )
        let service = PatternThumbnailFileService(directory: root.appendingPathComponent("cache"))
        let pattern = asset(
            sha256: String(repeating: "c", count: 64),
            kind: .pdf,
            filename: "three-pages.pdf",
            pageCount: 3
        )

        let cover = try service.thumbnailURL(asset: pattern, sourceURL: pdfURL)
        let firstPage = try service.thumbnailURL(asset: pattern, sourceURL: pdfURL, pageIndex: 0)
        let lastPage = try service.thumbnailURL(asset: pattern, sourceURL: pdfURL, pageIndex: 2)
        try service.delete(assetID: pattern.id)

        #expect(!FileManager.default.fileExists(atPath: cover.path))
        #expect(!FileManager.default.fileExists(atPath: firstPage.path))
        #expect(!FileManager.default.fileExists(atPath: lastPage.path))
    }

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

    @Test func rotatedPDFThumbnailsPreserveColoredCornerOrientationAt180And270Degrees() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let baseURL = root.appendingPathComponent("base.pdf")
        let rotated180URL = root.appendingPathComponent("rotated-180.pdf")
        let rotated270URL = root.appendingPathComponent("rotated-270.pdf")
        try makeMarkedPDF(at: baseURL, size: CGSize(width: 300, height: 200))
        try makeRotatedPDF(from: baseURL, to: rotated180URL, rotation: 180)
        try makeRotatedPDF(from: baseURL, to: rotated270URL, rotation: 270)
        let service = PatternThumbnailFileService(
            directory: root.appendingPathComponent("cache"),
            maxPixelSize: 300
        )

        let base = try service.thumbnailURL(asset: asset(kind: .pdf, filename: "base.pdf"), sourceURL: baseURL)
        let rotated180 = try service.thumbnailURL(asset: asset(kind: .pdf, filename: "rotated-180.pdf"), sourceURL: rotated180URL)
        let rotated270 = try service.thumbnailURL(asset: asset(kind: .pdf, filename: "rotated-270.pdf"), sourceURL: rotated270URL)
        let sourceCorners = try cornerColors(base)
        let rotated180Corners = try cornerColors(rotated180)
        let rotated270Corners = try cornerColors(rotated270)

        #expect(try pixelSize(rotated180) == CGSize(width: 300, height: 200))
        #expect(try pixelSize(rotated270) == CGSize(width: 200, height: 300))
        #expect(colorsMatch(rotated180Corners[0], sourceCorners[3]))
        #expect(colorsMatch(rotated180Corners[1], sourceCorners[2]))
        #expect(colorsMatch(rotated180Corners[2], sourceCorners[1]))
        #expect(colorsMatch(rotated180Corners[3], sourceCorners[0]))
        #expect(colorsMatch(rotated270Corners[0], sourceCorners[2]))
        #expect(colorsMatch(rotated270Corners[1], sourceCorners[0]))
        #expect(colorsMatch(rotated270Corners[2], sourceCorners[3]))
        #expect(colorsMatch(rotated270Corners[3], sourceCorners[1]))
    }

    @Test func jpegEXIFOrientationTransformsColoredCornerContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pngURL = root.appendingPathComponent("baseline.png")
        let jpegURL = root.appendingPathComponent("oriented.jpg")
        try makeMarkedImage(at: pngURL, type: .png, orientation: nil)
        try makeMarkedImage(at: jpegURL, type: .jpeg, orientation: .right)
        let service = PatternThumbnailFileService(
            directory: root.appendingPathComponent("cache"),
            maxPixelSize: 120
        )

        let baseline = try service.thumbnailURL(asset: asset(kind: .image, filename: "baseline.png"), sourceURL: pngURL)
        let oriented = try service.thumbnailURL(asset: asset(kind: .image, filename: "oriented.jpg"), sourceURL: jpegURL)
        let sourceCorners = try cornerColors(baseline)
        let orientedCorners = try cornerColors(oriented)

        #expect(try pixelSize(baseline) == CGSize(width: 120, height: 60))
        #expect(try pixelSize(oriented) == CGSize(width: 60, height: 120))
        #expect(colorsMatch(orientedCorners[0], sourceCorners[1]))
        #expect(colorsMatch(orientedCorners[1], sourceCorners[3]))
        #expect(colorsMatch(orientedCorners[2], sourceCorners[0]))
        #expect(colorsMatch(orientedCorners[3], sourceCorners[2]))
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

    private func makeSolidColorPDF(at url: URL, colors: [RGB]) throws {
        var box = CGRect(x: 0, y: 0, width: 240, height: 180)
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for color in colors {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(
                red: CGFloat(color.red) / 255,
                green: CGFloat(color.green) / 255,
                blue: CGFloat(color.blue) / 255,
                alpha: 1
            ))
            context.fill(box)
            context.endPDFPage()
        }
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

    private func makeRotatedPDF(from sourceURL: URL, to destinationURL: URL, rotation: Int) throws {
        let document = try #require(PDFDocument(url: sourceURL))
        let page = try #require(document.page(at: 0))
        page.rotation = rotation
        #expect(document.write(to: destinationURL))
    }

    private func makeMarkedPDF(at url: URL, size: CGSize) throws {
        var box = CGRect(origin: .zero, size: size)
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        drawCornerMarkers(in: context, size: size)
        context.endPDFPage()
        context.closePDF()
    }

    private func makeMarkedImage(
        at url: URL,
        type: UTType,
        orientation: CGImagePropertyOrientation?
    ) throws {
        let size = CGSize(width: 120, height: 60)
        let context = try #require(CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: Int(size.width) * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        drawCornerMarkers(in: context, size: size)
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL,
            type.identifier as CFString,
            1,
            nil
        ))
        var properties: [CFString: Any] = [:]
        if let orientation {
            properties[kCGImagePropertyOrientation] = orientation.rawValue
        }
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func drawCornerMarkers(in context: CGContext, size: CGSize) {
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2
        context.setFillColor(CGColor(red: 0.95, green: 0.05, blue: 0.05, alpha: 1))
        context.fill(CGRect(x: 0, y: halfHeight, width: halfWidth, height: halfHeight))
        context.setFillColor(CGColor(red: 0.05, green: 0.85, blue: 0.05, alpha: 1))
        context.fill(CGRect(x: halfWidth, y: halfHeight, width: halfWidth, height: halfHeight))
        context.setFillColor(CGColor(red: 0.05, green: 0.15, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight))
        context.setFillColor(CGColor(red: 0.95, green: 0.85, blue: 0.05, alpha: 1))
        context.fill(CGRect(x: halfWidth, y: 0, width: halfWidth, height: halfHeight))
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

    private func centerRGB(_ url: URL) throws -> RGB {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try #require(CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
        let offset = ((image.height / 2) * image.width + image.width / 2) * 4
        return RGB(red: bytes[offset], green: bytes[offset + 1], blue: bytes[offset + 2])
    }

    private func cornerColors(_ url: URL) throws -> [[UInt8]] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width
        let height = image.height
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
        func color(x: Int, y: Int) -> [UInt8] {
            let offset = (y * width + x) * 4
            return [bytes[offset], bytes[offset + 1], bytes[offset + 2]]
        }
        let insetX = max(1, width / 4)
        let insetY = max(1, height / 4)
        return [
            color(x: insetX, y: height - insetY),
            color(x: width - insetX - 1, y: height - insetY),
            color(x: insetX, y: insetY),
            color(x: width - insetX - 1, y: insetY)
        ]
    }

    private func colorsMatch(_ lhs: [UInt8], _ rhs: [UInt8], tolerance: Int = 40) -> Bool {
        zip(lhs, rhs).allSatisfy { abs(Int($0) - Int($1)) <= tolerance }
    }

    private func asset(
        id: UUID = UUID(),
        sha256: String = "test-hash-\(UUID().uuidString)",
        kind: PatternKind,
        filename: String,
        pageCount: Int? = nil
    ) -> PatternAsset {
        PatternAsset(
            id: id,
            sha256: sha256,
            kind: kind,
            storedFilename: filename,
            byteCount: 0,
            pageCount: pageCount ?? (kind == .pdf ? 1 : nil)
        )
    }

    private struct RGB: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }
}

private final class PageThumbnailServiceRenderBlocker: @unchecked Sendable {
    private let blocked = DispatchSemaphore(value: 0)
    private let continuation = DispatchSemaphore(value: 0)

    func block() {
        blocked.signal()
        continuation.wait()
    }

    func waitUntilBlocked() -> Bool {
        blocked.wait(timeout: .now() + 10) == .success
    }

    func resume() {
        continuation.signal()
    }
}
