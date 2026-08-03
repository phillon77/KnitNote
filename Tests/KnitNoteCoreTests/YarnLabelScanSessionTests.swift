import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct YarnLabelScanSessionTests {
    @Test func oneImageProducesParsedCandidates() async throws {
        let recognizer = FakeYarnLabelRecognizer(linesByImage: [
            ["Colour 12", "50 g / 120 m"],
        ])
        let session = YarnLabelScanSession(recognizer: recognizer)

        let result = try await session.scan([Data([1])])

        #expect(result.best(.colorCode)?.text == "12")
        #expect(result.best(.ballWeightGrams)?.decimalValue == 50)
        #expect(result.best(.lengthMeters)?.decimalValue == 120)
        #expect(await recognizer.requestedIndices() == [0])
    }

    @Test func twoImagesPreserveSourceIndicesAndConflictConfirmation() async throws {
        let recognizer = FakeYarnLabelRecognizer(linesByImage: [
            ["Color 12"],
            ["Color 13"],
        ])
        let session = YarnLabelScanSession(recognizer: recognizer)

        let result = try await session.scan([Data([1]), Data([2])])

        #expect(Set(result.candidates(for: .colorCode).map(\.sourceImageIndex)) == [0, 1])
        #expect(result.fieldsRequiringConfirmation.contains(.colorCode))
        #expect(Set(await recognizer.requestedIndices()) == [0, 1])
    }

    @Test func emptyAndThirdImageAreRejectedBeforeRecognition() async {
        let recognizer = FakeYarnLabelRecognizer(linesByImage: [])
        let session = YarnLabelScanSession(recognizer: recognizer)

        await #expect(throws: YarnLabelScanError.noImages) {
            try await session.scan([])
        }
        await #expect(throws: YarnLabelScanError.tooManyImages) {
            try await session.scan([Data([1]), Data([2]), Data([3])])
        }
        #expect(await recognizer.requestedIndices().isEmpty)
    }

    @Test func cancellationStopsTheScanWithoutPublishingAResult() async throws {
        let recognizer = FakeYarnLabelRecognizer(
            linesByImage: [["Colour 12"]],
            delayNanoseconds: 2_000_000_000
        )
        let session = YarnLabelScanSession(recognizer: recognizer)
        let task = Task { try await session.scan([Data([1])]) }

        while await recognizer.requestedIndices().isEmpty {
            await Task.yield()
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}

private actor FakeYarnLabelRecognizer: YarnLabelRecognitionService {
    private let linesByImage: [[String]]
    private let delayNanoseconds: UInt64
    private var indices: [Int] = []

    init(linesByImage: [[String]], delayNanoseconds: UInt64 = 0) {
        self.linesByImage = linesByImage
        self.delayNanoseconds = delayNanoseconds
    }

    func recognize(
        imageData: Data,
        sourceImageIndex: Int
    ) async throws -> [YarnLabelObservation] {
        indices.append(sourceImageIndex)
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        guard linesByImage.indices.contains(sourceImageIndex) else { return [] }
        return linesByImage[sourceImageIndex].map {
            YarnLabelObservation(
                text: $0,
                confidence: 0.95,
                sourceImageIndex: sourceImageIndex
            )
        }
    }

    func requestedIndices() -> [Int] { indices }
}
