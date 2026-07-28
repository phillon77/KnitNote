import XCTest
@testable import KnittingCalculator

final class GaugeDraftBehaviorTests: XCTestCase {
    func testConvertingUnitChangesLengthsButNotCounts() {
        var draft = GaugeDraft(
            unit: .centimeters,
            sampleWidth: "10",
            sampleStitches: "20",
            targetWidth: "40",
            sampleHeight: "5",
            sampleRows: "12",
            targetHeight: "30"
        )
        GaugeDraftConverter.convert(
            &draft,
            to: .inches,
            codec: LocalizedNumberCodec(locale: Locale(identifier: "en_US"))
        )
        XCTAssertEqual(draft.sampleStitches, "20")
        XCTAssertEqual(draft.sampleRows, "12")
        XCTAssertEqual(draft.unit, .inches)
        XCTAssertEqual(Double(draft.sampleWidth)!, 3.937, accuracy: 0.001)
    }
}
