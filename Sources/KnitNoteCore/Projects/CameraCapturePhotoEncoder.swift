import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum CameraCapturePhotoEncoderError: Error, Equatable, Sendable {
    case invalidMaximumPixelSize
    case resizingFailed
    case encodingFailed
}

public struct CameraCapturePhoto: Sendable {
    public let image: CGImage
    public let orientation: CGImagePropertyOrientation

    public init(image: CGImage, orientation: CGImagePropertyOrientation) {
        self.image = image
        self.orientation = orientation
    }
}

public enum CameraCapturePhotoEncoder {
    public static func encode(
        _ photo: CameraCapturePhoto,
        maximumPixelSize: Int = 1_600,
        compressionQuality: Double = 0.9
    ) async throws -> Data {
        let encodingTask = Task.detached(priority: .userInitiated) {
            try encodeSynchronously(
                photo,
                maximumPixelSize: maximumPixelSize,
                compressionQuality: compressionQuality
            )
        }
        return try await withTaskCancellationHandler {
            try await encodingTask.value
        } onCancel: {
            encodingTask.cancel()
        }
    }

    private static func encodeSynchronously(
        _ photo: CameraCapturePhoto,
        maximumPixelSize: Int,
        compressionQuality: Double
    ) throws -> Data {
        guard maximumPixelSize > 0 else {
            throw CameraCapturePhotoEncoderError.invalidMaximumPixelSize
        }
        try Task.checkCancellation()
        let boundedImage = try boundedImage(photo.image, maximumPixelSize: maximumPixelSize)
        try Task.checkCancellation()

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw CameraCapturePhotoEncoderError.encodingFailed
        }
        CGImageDestinationAddImage(
            destination,
            boundedImage,
            [
                kCGImageDestinationLossyCompressionQuality: compressionQuality,
                kCGImagePropertyOrientation: photo.orientation.rawValue,
            ] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw CameraCapturePhotoEncoderError.encodingFailed
        }
        try Task.checkCancellation()
        return output as Data
    }

    private static func boundedImage(
        _ image: CGImage,
        maximumPixelSize: Int
    ) throws -> CGImage {
        let longestEdge = max(image.width, image.height)
        guard longestEdge > maximumPixelSize else { return image }

        let scale = CGFloat(maximumPixelSize) / CGFloat(longestEdge)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CameraCapturePhotoEncoderError.resizingFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let boundedImage = context.makeImage() else {
            throw CameraCapturePhotoEncoderError.resizingFailed
        }
        return boundedImage
    }
}
