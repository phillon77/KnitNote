import XCTest
@testable import KnittingCalculator
import KnittingCalculatorCore

final class CalculatorShareTextTests: XCTestCase {
    func testGaugeShareContainsInputsResultAttributionAndFreeAppURL() throws {
        let result = try XCTUnwrap(
            GaugeCalculator.calculate(
                .init(sampleLength: 10, sampleCount: 20, targetLength: 40)
            )
        )

        let text = CalculatorShareText.gauge(
            .init(
                unit: .centimeters,
                sampleLength: 10,
                sampleCount: 20,
                targetLength: 40,
                result: result,
                rows: nil
            ),
            locale: Locale(identifier: "zh-Hant")
        )

        XCTAssertTrue(text.contains("10"))
        XCTAssertTrue(text.contains("80"))
        XCTAssertTrue(text.contains("由編織計算器計算"))
        XCTAssertTrue(text.contains(CalculatorProductLinks.freeApp.absoluteString))
        XCTAssertFalse(text.contains("https://apps.apple.com/app/id6793023054"))
    }

    func testOneRowShareIncludesEdgeChoiceAndCompleteSteps() throws {
        let result = try EvenStitchAdjustmentCalculator.calculate(
            .init(current: 20, target: 24, reservesEdgeStitches: true)
        )

        let text = CalculatorShareText.oneRow(
            .init(
                current: 20,
                target: 24,
                reservesEdgeStitches: true,
                result: result
            ),
            locale: Locale(identifier: "en")
        )

        XCTAssertTrue(text.contains("20"))
        XCTAssertTrue(text.contains("24"))
        XCTAssertTrue(text.contains("One edge stitch on each side"))
        XCTAssertTrue(text.contains("Increase 1 stitch"))
        XCTAssertTrue(text.contains("Calculated with Knitting Calculator"))
        XCTAssertTrue(text.contains(CalculatorProductLinks.freeApp.absoluteString))
        XCTAssertFalse(text.contains("https://apps.apple.com/app/id6793023054"))
    }

    func testAcrossRowsShareIncludesIntervalAndAdjustmentRows() throws {
        let input = RowIntervalAdjustmentInput(
            totalRows: 8,
            totalStitches: 4,
            operation: .increase,
            style: .singleSide
        )
        let result = try RowIntervalAdjustmentCalculator.calculate(input)

        let text = CalculatorShareText.rowInterval(
            .init(input: input, result: result),
            locale: Locale(identifier: "zh-Hant")
        )

        XCTAssertTrue(text.contains("8"))
        XCTAssertTrue(text.contains("4"))
        XCTAssertTrue(text.contains("每 2 排"))
        XCTAssertTrue(text.contains("2、4、6、8"))
        XCTAssertTrue(text.contains("由編織計算器計算"))
        XCTAssertTrue(text.contains(CalculatorProductLinks.freeApp.absoluteString))
        XCTAssertFalse(text.contains("https://apps.apple.com/app/id6793023054"))
    }
}
