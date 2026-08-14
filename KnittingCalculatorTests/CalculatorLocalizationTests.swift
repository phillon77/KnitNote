import XCTest
@testable import KnittingCalculator

final class CalculatorLocalizationTests: XCTestCase {
    let supportedLocales = [
        "en", "zh-Hant", "zh-Hans", "de", "fr", "ja", "ko",
        "nl", "nb", "sv", "fi", "da", "el",
    ]

    func testRepresentativeKeysResolveForEverySupportedLocale() {
        let keys = [
            "app.title", "app.home.title", "calculator.gauge.title",
            "calculator.adjustment.current",
            "calculator.adjustment.validation.positiveInteger",
            "calculator.adjustment.accessibility.summary.edge.format",
            "calculator.settings.privacy", "calculator.promotion.action",
        ]
        for identifier in supportedLocales {
            for key in keys {
                let value = CalculatorLocalization.string(key, locale: Locale(identifier: identifier))
                XCTAssertNotEqual(value, key, "Missing \(identifier) localization for \(key)")
                if identifier != "en" {
                    let englishValue = CalculatorLocalization.string(
                        key,
                        locale: Locale(identifier: "en")
                    )
                    XCTAssertNotEqual(
                        value,
                        englishValue,
                        "Unexpected English fallback for \(identifier) localization of \(key)"
                    )
                }
            }
        }
    }

    func testChineseRegionRouting() {
        XCTAssertEqual(
            CalculatorLocalization.string("app.title", locale: Locale(identifier: "zh_CN")),
            CalculatorLocalization.string("app.title", locale: Locale(identifier: "zh-Hans"))
        )
        for identifier in ["zh_TW", "zh_HK", "zh_MO"] {
            XCTAssertEqual(
                CalculatorLocalization.string("app.title", locale: Locale(identifier: identifier)),
                CalculatorLocalization.string("app.title", locale: Locale(identifier: "zh-Hant"))
            )
        }
    }
}
