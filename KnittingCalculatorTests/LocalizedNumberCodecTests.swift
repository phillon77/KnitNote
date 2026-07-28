import XCTest
@testable import KnittingCalculator

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
}
