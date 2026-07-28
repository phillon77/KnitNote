import XCTest
@testable import KnittingCalculator

@MainActor
final class CalculatorPreferencesStoreTests: XCTestCase {
    func testDraftsRoundTripAndResetWithoutTouchingCounters() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        var store = CalculatorPreferencesStore(defaults: defaults, locale: Locale(identifier: "zh_TW"))
        store.gauge.sampleWidth = "10"
        store.oneRow.reservesEdgeStitches = false
        store.recordValidCalculation()

        store = CalculatorPreferencesStore(defaults: defaults, locale: Locale(identifier: "zh_TW"))
        XCTAssertEqual(store.gauge.sampleWidth, "10")
        XCTAssertFalse(store.oneRow.reservesEdgeStitches)
        XCTAssertEqual(store.validCalculationCount, 1)

        store.resetDrafts()
        XCTAssertEqual(store.gauge.sampleWidth, "")
        XCTAssertTrue(store.oneRow.reservesEdgeStitches)
        XCTAssertEqual(store.validCalculationCount, 1)
    }

    func testFirstUnitUsesUSRegionOnlyForInches() {
        XCTAssertEqual(CalculatorPreferencesStore.initialUnit(for: Locale(identifier: "en_US")), .inches)
        XCTAssertEqual(CalculatorPreferencesStore.initialUnit(for: Locale(identifier: "zh_TW")), .centimeters)
        XCTAssertEqual(CalculatorPreferencesStore.initialUnit(for: Locale(identifier: "en_GB")), .centimeters)
    }

    func testChosenUnitPersistsInsteadOfUsingALaterLocale() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        var store = CalculatorPreferencesStore(defaults: defaults, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(store.gauge.unit, .inches)

        store.gauge.unit = .centimeters
        store = CalculatorPreferencesStore(defaults: defaults, locale: Locale(identifier: "en_US"))

        XCTAssertEqual(store.gauge.unit, .centimeters)
    }

    func testRecordValidCalculationSaturatesAtFive() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = CalculatorPreferencesStore(defaults: defaults, locale: Locale(identifier: "zh_TW"))

        for _ in 0..<6 {
            store.recordValidCalculation()
        }

        XCTAssertEqual(store.validCalculationCount, 5)
    }
}
