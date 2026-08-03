import Foundation

public enum YarnLabelScanError: Error, Equatable, Sendable {
    case noImages
    case tooManyImages
}

public struct YarnLabelScanSession: Sendable {
    private let recognizer: any YarnLabelRecognitionService
    private let parser: YarnLabelFieldParser

    public init(
        recognizer: any YarnLabelRecognitionService,
        parser: YarnLabelFieldParser = .init()
    ) {
        self.recognizer = recognizer
        self.parser = parser
    }

    public func scan(_ images: [Data]) async throws -> YarnLabelParseResult {
        guard !images.isEmpty else { throw YarnLabelScanError.noImages }
        guard images.count <= 2 else { throw YarnLabelScanError.tooManyImages }
        try Task.checkCancellation()

        let observations = try await withThrowingTaskGroup(
            of: [YarnLabelObservation].self,
            returning: [YarnLabelObservation].self
        ) { group in
            for (sourceImageIndex, imageData) in images.enumerated() {
                group.addTask {
                    try Task.checkCancellation()
                    let recognized = try await recognizer.recognize(
                        imageData: imageData,
                        sourceImageIndex: sourceImageIndex
                    )
                    try Task.checkCancellation()
                    return recognized.map {
                        YarnLabelObservation(
                            text: $0.text,
                            confidence: $0.confidence,
                            boundingBox: $0.boundingBox,
                            sourceImageIndex: sourceImageIndex
                        )
                    }
                }
            }

            var combined: [YarnLabelObservation] = []
            for try await recognized in group {
                combined.append(contentsOf: recognized)
            }
            return combined
        }
        try Task.checkCancellation()
        return parser.parse(observations)
    }
}
