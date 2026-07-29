import XCTest
@testable import KnittingCalculator
import KnittingCalculatorCore

final class AdjustmentPresentationTests: XCTestCase {
    func testStepTokensUseNeutralTermsForEveryCalculatorStep() {
        XCTAssertEqual(AdjustmentStepText.token(for: .increaseOne), .increaseOne)
        XCTAssertEqual(AdjustmentStepText.token(for: .decreaseOne), .decreaseOne)
        XCTAssertEqual(AdjustmentStepText.token(for: .knit(7)), .work(7))
        XCTAssertEqual(AdjustmentStepText.token(for: .edge(1)), .edge(1))
    }

    func testTraditionalChineseAcrossRowsSummariesJoinIntervalAndOperationWithoutASpace() throws {
        let cases: [(
            operation: RowIntervalAdjustmentOperation,
            style: RowIntervalAdjustmentStyle,
            totalRows: Int,
            totalStitches: Int,
            expected: String
        )] = [
            (.increase, .singleSide, 6, 2, "單側每 3 排加針，共 2 次調整。"),
            (.increase, .singleSide, 7, 2, "單側每 3–4 排加針，共 2 次調整。"),
            (.increase, .bothSides, 6, 4, "雙側每 3 排加針，共 2 次調整。"),
            (.increase, .bothSides, 7, 4, "雙側每 3–4 排加針，共 2 次調整。"),
            (.decrease, .singleSide, 6, 2, "單側每 3 排減針，共 2 次調整。"),
            (.decrease, .singleSide, 7, 2, "單側每 3–4 排減針，共 2 次調整。"),
            (.decrease, .bothSides, 6, 4, "雙側每 3 排減針，共 2 次調整。"),
            (.decrease, .bothSides, 7, 4, "雙側每 3–4 排減針，共 2 次調整。"),
        ]

        for testCase in cases {
            let result = try RowIntervalAdjustmentCalculator.calculate(
                .init(
                    totalRows: testCase.totalRows,
                    totalStitches: testCase.totalStitches,
                    operation: testCase.operation,
                    style: testCase.style
                )
            )

            XCTAssertEqual(
                RowIntervalAdjustmentPresentationText.summary(
                    for: result,
                    locale: Locale(identifier: "zh-Hant")
                ),
                testCase.expected,
                "\(testCase.operation.rawValue), \(testCase.style.rawValue), \(testCase.totalRows) rows"
            )
        }
    }

    func testEnglishAcrossRowsSummaryDoesNotRepeatTheLocalizedIntervalPrefix() throws {
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
    }
}
