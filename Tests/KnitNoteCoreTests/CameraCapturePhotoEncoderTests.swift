import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import KnitNoteCore

@Suite struct CameraCapturePhotoEncoderTests {
    @Test func encodedPhotoIsBoundedWithoutUpscaling() async throws {
        let large = CameraCapturePhoto(
            image: try cameraFixtureImage(width: 2_400, height: 1_200),
            orientation: .up
        )
        let largeData = try await CameraCapturePhotoEncoder.encode(
            large,
            maximumPixelSize: 1_600
        )
        #expect(try cameraPixelSize(largeData) == CGSize(width: 1_600, height: 800))

        let small = CameraCapturePhoto(
            image: try cameraFixtureImage(width: 640, height: 480),
            orientation: .up
        )
        let smallData = try await CameraCapturePhotoEncoder.encode(
            small,
            maximumPixelSize: 1_600
        )
        #expect(try cameraPixelSize(smallData) == CGSize(width: 640, height: 480))
    }

    @Test func invalidMaximumPixelSizeIsRejected() async throws {
        let photo = CameraCapturePhoto(
            image: try cameraFixtureImage(width: 10, height: 10),
            orientation: .up
        )

        await #expect(throws: CameraCapturePhotoEncoderError.invalidMaximumPixelSize) {
            try await CameraCapturePhotoEncoder.encode(photo, maximumPixelSize: 0)
        }
    }
}

private func cameraFixtureImage(width: Int, height: Int) throws -> CGImage {
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}

private func cameraPixelSize(_ data: Data) throws -> CGSize {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try #require(
        CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    )
    return CGSize(
        width: try #require(properties[kCGImagePropertyPixelWidth] as? Int),
        height: try #require(properties[kCGImagePropertyPixelHeight] as? Int)
    )
}
