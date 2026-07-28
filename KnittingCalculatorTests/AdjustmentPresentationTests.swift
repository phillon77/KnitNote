import XCTest
@testable import KnittingCalculator

final class AdjustmentPresentationTests: XCTestCase {
    func testStepTokensUseNeutralTermsForEveryCalculatorStep() {
        XCTAssertEqual(AdjustmentStepText.token(for: .increaseOne), .increaseOne)
        XCTAssertEqual(AdjustmentStepText.token(for: .decreaseOne), .decreaseOne)
        XCTAssertEqual(AdjustmentStepText.token(for: .knit(7)), .work(7))
        XCTAssertEqual(AdjustmentStepText.token(for: .edge(1)), .edge(1))
    }

    func testAcrossRowsSummaryDoesNotRepeatTheLocalizedIntervalPrefix() throws {
        let result = try RowIntervalAdjustmentCalculator.calculate(
            .init(
                totalRows: 6,
                totalStitches: 2,
                operation: .increase,
                style: .singleSide
            )
        )

        XCTAssertEqual(
            RowIntervalAdjustmentPresentationText.summary(
                for: result,
                locale: Locale(identifier: "en")
            ),
            "Increase on one side every 3 rows for 2 adjustments."
        )
        XCTAssertEqual(
            RowIntervalAdjustmentPresentationText.summary(
                for: result,
                locale: Locale(identifier: "zh-Hant")
            ),
            "單側每 3 排加針，共 2 次調整。"
        )
    }
}
