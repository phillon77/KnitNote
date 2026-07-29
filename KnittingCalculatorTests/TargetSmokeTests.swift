import XCTest
@testable import KnittingCalculator
import KnittingCalculatorCore

final class TargetSmokeTests: XCTestCase {
    func testSharedGaugeCoreIsLinked() {
        let result = GaugeCalculator.calculate(
            .init(sampleLength: 10, sampleCount: 20, targetLength: 40)
        )
        XCTAssertEqual(result?.recommendedCount, 80)
    }

    func testCalculatorBundleLoadsRepresentativeAdjustmentLocalization() {
        XCTAssertEqual(
            CalculatorLocalization.string(
                "calculator.adjustment.mode.acrossRows",
                locale: Locale(identifier: "en")
            ),
            "Across rows"
        )
    }

    func testTraditionalChineseLocaleVariantsResolveTheTraditionalChineseCatalog() {
        for identifier in ["zh-Hant-TW", "zh_TW"] {
            XCTAssertEqual(
                CalculatorLocalization.string(
                    "calculator.adjustment.mode.acrossRows",
                    locale: Locale(identifier: identifier)
                ),
                "跨排"
            )
        }
    }
}
