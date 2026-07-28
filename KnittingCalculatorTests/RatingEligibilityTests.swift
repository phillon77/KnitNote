import XCTest
@testable import KnittingCalculator

@MainActor
final class RatingEligibilityTests: XCTestCase {
    func testRequiresFiveCalculationsAndOncePerVersion() {
        XCTAssertFalse(RatingEligibility.shouldRequest(
            validCount: 4,
            attemptVersion: nil,
            currentVersion: "1.0.0"
        ))
        XCTAssertTrue(RatingEligibility.shouldRequest(
            validCount: 5,
            attemptVersion: nil,
            currentVersion: "1.0.0"
        ))
        XCTAssertFalse(RatingEligibility.shouldRequest(
            validCount: 5,
            attemptVersion: "1.0.0",
            currentVersion: "1.0.0"
        ))
        XCTAssertTrue(RatingEligibility.shouldRequest(
            validCount: 5,
            attemptVersion: "1.0.0",
            currentVersion: "1.1.0"
        ))
    }

    func testCoordinatorRecordsTheAttemptBeforeRequestingAndPersistsIt() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = CalculatorPreferencesStore(
            defaults: defaults,
            locale: Locale(identifier: "zh_TW")
        )
        for _ in 0..<5 {
            store.recordValidCalculation()
        }
        let coordinator = RatingRequestCoordinator(preferences: store)
        var requestCount = 0

        coordinator.considerRequest(currentVersion: "1.0.0") {
            XCTAssertEqual(store.ratingAttemptVersion, "1.0.0")
            requestCount += 1
        }
        coordinator.considerRequest(currentVersion: "1.0.0") {
            requestCount += 1
        }
        coordinator.considerRequest(currentVersion: "1.1.0") {
            XCTAssertEqual(store.ratingAttemptVersion, "1.1.0")
            requestCount += 1
        }

        XCTAssertEqual(requestCount, 2)
        let reloadedStore = CalculatorPreferencesStore(
            defaults: defaults,
            locale: Locale(identifier: "zh_TW")
        )
        XCTAssertEqual(reloadedStore.ratingAttemptVersion, "1.1.0")
    }

    func testCalculatorScreensOnlyConsiderARequestAfterProducingAValidResult() throws {
        for path in [
            "KnittingCalculator/Gauge/GaugeCalculatorScreen.swift",
            "KnittingCalculator/Adjustment/OneRowAdjustmentView.swift",
            "KnittingCalculator/Adjustment/RowIntervalAdjustmentView.swift",
        ] {
            let source = try source(at: path)
            XCTAssertTrue(source.contains("@EnvironmentObject private var ratingCoordinator"))
            XCTAssertTrue(source.contains("@State private var hadValidResult = false"))
            XCTAssertTrue(source.contains("guard let newValue else { return }"))
            XCTAssertTrue(source.contains("hadValidResult = true"))
            XCTAssertTrue(source.contains(".onDisappear"))
            XCTAssertTrue(source.contains("guard hadValidResult else { return }"))
            XCTAssertTrue(source.contains("ratingCoordinator.considerRequest()"))

            let onChange = try XCTUnwrap(source.range(of: ".onChange(of: shareSnapshot)"))
            XCTAssertFalse(source[..<onChange.lowerBound].contains("hadValidResult = true"))
        }
    }

    func testEachCalculatorRootOwnsItsReviewSceneInsteadOfSharingOneOnTheCoordinator() throws {
        let ratingSource = try source(at: "KnittingCalculator/Model/RatingEligibility.swift")
        let appSource = try source(at: "KnittingCalculator/App/KnittingCalculatorApp.swift")
        let rootSource = try source(at: "KnittingCalculator/App/CalculatorRootView.swift")
        let coordinatorStart = try XCTUnwrap(
            ratingSource.range(of: "final class RatingRequestCoordinator")
        )
        let coordinatorSource = ratingSource[coordinatorStart.lowerBound...]

        XCTAssertTrue(appSource.contains("RatingRequestCoordinator(preferences: preferences)"))
        XCTAssertTrue(appSource.contains(".environmentObject(ratingCoordinator)"))
        XCTAssertFalse(coordinatorSource.contains("private weak var windowScene"))
        XCTAssertFalse(coordinatorSource.contains("func update(windowScene:"))
        XCTAssertFalse(coordinatorSource.contains("func considerRequest()"))
        XCTAssertTrue(rootSource.contains("@StateObject private var ratingRequestContext = RatingRequestContext()"))
        XCTAssertTrue(rootSource.contains(".environmentObject(ratingRequestContext)"))
        XCTAssertTrue(rootSource.contains("RatingRequestSceneObserver"))
        XCTAssertTrue(rootSource.contains("ratingRequestContext.update(windowScene: scene)"))

        for path in [
            "KnittingCalculator/Gauge/GaugeCalculatorScreen.swift",
            "KnittingCalculator/Adjustment/OneRowAdjustmentView.swift",
            "KnittingCalculator/Adjustment/RowIntervalAdjustmentView.swift",
        ] {
            let source = try source(at: path)
            XCTAssertTrue(source.contains("@EnvironmentObject private var ratingRequestContext"))
            XCTAssertTrue(source.contains("ratingRequestContext.considerRequest(using: ratingCoordinator)"))
        }
    }

    private func source(at path: String) throws -> String {
        try String(
            contentsOf: URL(filePath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: path),
            encoding: .utf8
        )
    }
}
