import CoreGraphics
import Foundation
import ImageIO
import Vision

enum VisionYarnLabelRecognitionError: Error, Equatable, Sendable {
    case invalidImage
    case recognitionFailed
}

struct VisionYarnLabelRecognitionService: YarnLabelRecognitionService {
    func recognize(
        imageData: Data,
        sourceImageIndex: Int
    ) async throws -> [YarnLabelObservation] {
        let recognitionTask = Task.detached(priority: .userInitiated) {
            try Self.recognizeSynchronously(
                imageData: imageData,
                sourceImageIndex: sourceImageIndex
            )
        }
        return try await withTaskCancellationHandler {
            try await recognitionTask.value
        } onCancel: {
            recognitionTask.cancel()
        }
    }

    private static func recognizeSynchronously(
        imageData: Data,
        sourceImageIndex: Int
    ) throws -> [YarnLabelObservation] {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw VisionYarnLabelRecognitionError.invalidImage
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientationRaw = properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let preferred = ["zh-Hant", "en-US"].filter { supported.contains($0) }
        if !preferred.isEmpty {
            request.recognitionLanguages = preferred
        } else if !supported.isEmpty {
            request.recognitionLanguages = supported
        }

        let handler = VNImageRequestHandler(
            cgImage: image,
            orientation: orientation,
            options: [:]
        )
        do {
            try handler.perform([request])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw VisionYarnLabelRecognitionError.recognitionFailed
        }
        try Task.checkCancellation()

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return YarnLabelObservation(
                text: candidate.string,
                confidence: candidate.confidence,
                boundingBox: observation.boundingBox,
                sourceImageIndex: sourceImageIndex
            )
        }
    }
}
