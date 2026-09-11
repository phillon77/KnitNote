import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KnitNote

@MainActor
@Suite struct JournalShareCardRendererTests {
    @Test(arguments: [JournalShareFormat.post, .story])
    func rendersExactDecodableSRGBJPEG(_ format: JournalShareFormat) async throws {
        let data = try await render(format: format)
        let properties = try imageProperties(data)

        #expect(properties[kCGImagePropertyPixelWidth] as? Int == format.pixelWidth)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == format.pixelHeight)
        #expect(properties[kCGImagePropertyColorModel] as? String == kCGImagePropertyColorModelRGB as String)
        #expect(properties[kCGImagePropertyProfileName] as? String == "sRGB IEC61966-2.1")
        try writeRepresentativeFixtureIfRequested(data, format: format)
    }

    @Test func respectsEXIFOrientationWhenDecodingPhoto() async throws {
        let data = try await SwiftUIJournalShareCardRenderer().renderJPEG(
            description: fixtureDescription(format: .post),
            photoData: try fixtureJPEG(orientation: .right)
        )
        let image = try decodedImage(data)
        let topLeft = try rgb(image, x: 220, y: 220)
        let topRight = try rgb(image, x: 860, y: 220)

        // The source has a red top half and blue bottom half. EXIF right rotation
        // makes those halves appear on the right and left respectively.
        #expect(topLeft.blue > topLeft.red + 40)
        #expect(topRight.red > topRight.blue + 40)
    }

    @Test func invalidPhotoFailsWithoutProducingPlaceholder() async {
        await #expect(throws: JournalShareRenderError.invalidPhoto) {
            try await SwiftUIJournalShareCardRenderer().renderJPEG(
                description: fixtureDescription(format: .post),
                photoData: Data("bad".utf8)
            )
        }
    }

    @Test func rendersEveryMetadataVisibilityCombination() async throws {
        for mask in 0..<16 {
            let description = JournalShareCardDescription(
                format: mask.isMultiple(of: 2) ? .post : .story,
                projectName: mask & 1 == 0 ? nil : "冬日毛衣",
                formattedDate: mask & 2 == 0 ? nil : "2026年9月11日",
                caption: mask & 4 == 0 ? nil : "終於完成了 🧶",
                showsBrand: mask & 8 != 0
            )
            let data = try await SwiftUIJournalShareCardRenderer().renderJPEG(
                description: description,
                photoData: try fixtureJPEG()
            )
            let properties = try imageProperties(data)
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == description.format.pixelWidth)
            #expect(properties[kCGImagePropertyPixelHeight] as? Int == description.format.pixelHeight)
        }
    }

    @Test(arguments: [
        "",
        String(repeating: "長篇繁體中文編織日誌，每一針都是秋天的紀錄。", count: 18),
        "🧶 🐑 ✨ 🧣 🧵",
        "مشروع حياكة · Ημερολόγιο πλεξίματος · 뜨개질 일지"
    ])
    func rendersBoundaryCaptions(_ caption: String) async throws {
        for format in JournalShareFormat.allCases {
            let description = JournalShareCardDescription(
                format: format,
                projectName: caption,
                formattedDate: "2026/09/11",
                caption: caption,
                showsBrand: true
            )
            let data = try await SwiftUIJournalShareCardRenderer().renderJPEG(
                description: description,
                photoData: try fixtureJPEG()
            )
            #expect(try decodedImage(data).width == format.pixelWidth)
            #expect(try decodedImage(data).height == format.pixelHeight)
        }
    }

    @Test(arguments: [JournalShareFormat.post, .story])
    func warmPaperSafeAreaSurroundsPhotoOnlyCard(_ format: JournalShareFormat) async throws {
        let description = JournalShareCardDescription(
            format: format,
            projectName: nil,
            formattedDate: nil,
            caption: nil,
            showsBrand: false
        )
        let data = try await SwiftUIJournalShareCardRenderer().renderJPEG(
            description: description,
            photoData: try fixtureJPEG()
        )
        let image = try decodedImage(data)
        for (x, y) in [(12, 12), (image.width - 13, 12), (12, image.height - 13), (image.width - 13, image.height - 13)] {
            let pixel = try rgb(image, x: x, y: y)
            #expect(pixel.red > 210)
            #expect(pixel.green > 195)
            #expect(pixel.blue > 170)
            #expect(abs(Int(pixel.red) - Int(pixel.green)) < 45)
        }
    }

    private func render(format: JournalShareFormat) async throws -> Data {
        try await SwiftUIJournalShareCardRenderer().renderJPEG(
            description: fixtureDescription(format: format),
            photoData: try fixtureJPEG()
        )
    }

    private func fixtureDescription(format: JournalShareFormat) -> JournalShareCardDescription {
        JournalShareCardDescription(
            format: format,
            projectName: "秋日森林開襟衫",
            formattedDate: "2026年9月11日",
            caption: "一針一線，把秋天編進日常裡。 🧶",
            showsBrand: true
        )
    }

    private func fixtureJPEG(orientation: CGImagePropertyOrientation = .up) throws -> Data {
        let width = 640
        let height = 480
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.12, green: 0.35, blue: 0.78, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(CGColor(srgbRed: 0.88, green: 0.18, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))

        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(
            destination,
            try #require(context.makeImage()),
            [
                kCGImageDestinationLossyCompressionQuality: 0.92,
                kCGImagePropertyOrientation: orientation.rawValue
            ] as CFDictionary
        )
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func imageProperties(_ data: Data) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func decodedImage(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func writeRepresentativeFixtureIfRequested(_ data: Data, format: JournalShareFormat) throws {
        guard let directory = ProcessInfo.processInfo.environment["KNITNOTE_RENDER_FIXTURES_DIR"] else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent("journal-share-\(format.rawValue).jpg"), options: .atomic)
    }

    private func rgb(_ image: CGImage, x: Int, y: Int) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return (bytes[0], bytes[1], bytes[2])
    }
}
