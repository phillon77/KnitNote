import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum JournalShareRenderError: Error, Equatable {
    case invalidPhoto
    case renderFailed
    case invalidOutputDimensions
    case encodingFailed
}

@MainActor
protocol JournalShareCardRendering {
    func renderJPEG(
        description: JournalShareCardDescription,
        photoData: Data
    ) async throws -> Data
}

@MainActor
struct SwiftUIJournalShareCardRenderer: JournalShareCardRendering {
    /// High enough for the tallest fixed output while bounding decoded input memory.
    private static let maximumDecodedPhotoDimension = 1_920
    /// Balances card detail with export size for system sharing.
    static let jpegQuality = 0.90

    func renderJPEG(
        description: JournalShareCardDescription,
        photoData: Data
    ) async throws -> Data {
        let photo = try decodePhoto(photoData)
        let renderer = ImageRenderer(content: JournalShareCardView(
            description: description,
            photo: Image(decorative: photo, scale: 1)
        ))
        renderer.proposedSize = ProposedViewSize(
            width: CGFloat(description.format.pixelWidth),
            height: CGFloat(description.format.pixelHeight)
        )
        renderer.scale = 1

        guard let rendered = renderer.cgImage else {
            throw JournalShareRenderError.renderFailed
        }
        guard rendered.width == description.format.pixelWidth,
              rendered.height == description.format.pixelHeight else {
            throw JournalShareRenderError.invalidOutputDimensions
        }
        let output = try convertToSRGB(rendered)
        return try encodeJPEG(output)
    }

    private func decodePhoto(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw JournalShareRenderError.invalidPhoto
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maximumDecodedPhotoDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw JournalShareRenderError.invalidPhoto
        }
        return image
    }

    private func convertToSRGB(_ image: CGImage) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            throw JournalShareRenderError.encodingFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let output = context.makeImage() else {
            throw JournalShareRenderError.encodingFailed
        }
        return output
    }

    private func encodeJPEG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw JournalShareRenderError.encodingFailed
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: Self.jpegQuality,
            kCGImagePropertyColorModel: kCGImagePropertyColorModelRGB,
            kCGImagePropertyProfileName: "sRGB IEC61966-2.1"
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw JournalShareRenderError.encodingFailed
        }
        return data as Data
    }
}
