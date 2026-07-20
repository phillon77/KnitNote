import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KnitNoteCore

@Suite("Project journal preview loader")
struct ProjectJournalPreviewLoaderTests {
    @Test @MainActor func rawDataIsDecodedIntoABoundedPreviewOffTheCallerActor() async throws {
        let source = try makeJPEG(width: 2400, height: 1200)

        let preview = try #require(await ProjectJournalPreviewLoader.load(
            data: source,
            maximumPixelSize: 600
        ))

        #expect(preview.pixelWidth == 600)
        #expect(preview.pixelHeight == 300)
    }

    @Test @MainActor func fullFileIsDecodedDirectlyIntoABoundedPreview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("full.jpg")
        try makeJPEG(width: 1000, height: 2000).write(to: url)

        let preview = try #require(await ProjectJournalPreviewLoader.load(
            url: url,
            maximumPixelSize: 800
        ))

        #expect(preview.pixelWidth == 400)
        #expect(preview.pixelHeight == 800)
    }

    @Test func invalidDataAndInvalidBoundsDoNotProduceAPreview() async {
        #expect(await ProjectJournalPreviewLoader.load(data: Data("bad".utf8), maximumPixelSize: 600) == nil)
        #expect(await ProjectJournalPreviewLoader.load(data: Data(), maximumPixelSize: 0) == nil)
    }

    private func makeJPEG(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.45, green: 0.35, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        )
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
