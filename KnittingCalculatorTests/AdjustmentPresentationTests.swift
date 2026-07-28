import XCTest
@testable import KnittingCalculator

final class AdjustmentPresentationTests: XCTestCase {
    func testStepTokensUseNeutralTermsForEveryCalculatorStep() {
        XCTAssertEqual(AdjustmentStepText.token(for: .increaseOne), .increaseOne)
        XCTAssertEqual(AdjustmentStepText.token(for: .decreaseOne), .decreaseOne)
        XCTAssertEqual(AdjustmentStepText.token(for: .knit(7)), .work(7))
        XCTAssertEqual(AdjustmentStepText.token(for: .edge(1)), .edge(1))
    }
}
