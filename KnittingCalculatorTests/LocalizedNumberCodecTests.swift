import XCTest
@testable import KnittingCalculator

@MainActor
final class LocalizedNumberCodecTests: XCTestCase {
    func testParsesEitherDecimalSeparatorAndRejectsInvalidValues() {
        let codec = LocalizedNumberCodec(locale: Locale(identifier: "zh_TW"))
        XCTAssertEqual(codec.parseDecimal("10,5"), 10.5)
        XCTAssertEqual(codec.parseDecimal("10.5"), 10.5)
        XCTAssertNil(codec.parseDecimal("0"))
        XCTAssertNil(codec.parseDecimal("-2"))
        XCTAssertNil(codec.parseDecimal("12x"))
        XCTAssertEqual(codec.parsePositiveInteger("12"), 12)
        XCTAssertNil(codec.parsePositiveInteger("12.5"))
    }

    func testFormatsWithTheLocaleDecimalSeparatorAndAtMostFourFractionDigits() {
        let codec = LocalizedNumberCodec(locale: Locale(identifier: "de_DE"))

        XCTAssertEqual(codec.format(10.5), "10,5")
        XCTAssertEqual(codec.format(1.23456), "1,2346")
    }

    func testSupportedLocalesAcceptBothSeparatorsAndUseTheirDisplaySeparator() {
        let decimalCommaLocales = ["de", "fr", "nl", "nb", "sv", "fi", "da", "el"]
        let decimalPointLocales = ["en", "zh-Hant", "zh-Hans", "ja", "ko"]

        for identifier in decimalCommaLocales {
            let codec = LocalizedNumberCodec(locale: Locale(identifier: identifier))
            XCTAssertEqual(codec.parseDecimal("10,5"), 10.5, identifier)
            XCTAssertEqual(codec.parseDecimal("10.5"), 10.5, identifier)
            XCTAssertEqual(codec.format(10.5), "10,5", identifier)
        }
        for identifier in decimalPointLocales {
            let codec = LocalizedNumberCodec(locale: Locale(identifier: identifier))
            XCTAssertEqual(codec.parseDecimal("10,5"), 10.5, identifier)
            XCTAssertEqual(codec.parseDecimal("10.5"), 10.5, identifier)
            XCTAssertEqual(codec.format(10.5), "10.5", identifier)
        }
    }

    func testChangingLocaleDoesNotRewriteSavedNumbersOrUnit() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var store = CalculatorPreferencesStore(
            defaults: defaults,
            locale: Locale(identifier: "de_DE")
        )
        store.gauge.sampleWidth = "10,5"
        store.gauge.sampleStitches = "21"
        store.gauge.unit = .inches

        store = CalculatorPreferencesStore(
            defaults: defaults,
            locale: Locale(identifier: "ja_JP")
        )

        XCTAssertEqual(store.gauge.sampleWidth, "10,5")
        XCTAssertEqual(store.gauge.sampleStitches, "21")
        XCTAssertEqual(store.gauge.unit, .inches)
    }
}
