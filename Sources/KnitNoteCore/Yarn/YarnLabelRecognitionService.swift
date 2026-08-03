import Foundation

public protocol YarnLabelRecognitionService: Sendable {
    func recognize(
        imageData: Data,
        sourceImageIndex: Int
    ) async throws -> [YarnLabelObservation]
}
