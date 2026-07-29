import Foundation
import KnittingCalculatorCore
import Testing
@testable import KnittingCalculator

struct CalculatorStoreScreenshotModeTests {
    @Test func screenshotArgumentsResolveOnlyWhenComplete() {
        #expect(
            CalculatorStoreScreenshotMode.resolve(arguments: ["app"])
                == .notRequested
        )
        #expect(
            CalculatorStoreScreenshotMode.resolve(arguments: [
                "app",
                "-storeScreenshotMode", "YES",
                "-storeScreenshotScene", "gauge",
                "-storeScreenshotLanguage", "zh-Hant",
                "-storeScreenshotToken", "token-1",
            ]) == .ready(.init(
                scene: .gauge,
                language: .zhHant,
                readinessToken: "token-1"
            ))
        )
    }

    @Test func requestedScreenshotModeRejectsMissingOrUnknownValues() {
        #expect(
            CalculatorStoreScreenshotMode.resolve(arguments: [
                "app",
                "-storeScreenshotMode", "YES",
            ]) == .invalid
        )
        #expect(
            CalculatorStoreScreenshotMode.resolve(arguments: [
                "app",
                "-storeScreenshotMode", "YES",
                "-storeScreenshotScene", "unknown",
                "-storeScreenshotLanguage", "en",
                "-storeScreenshotToken", "token-2",
            ]) == .invalid
        )
        #expect(
            CalculatorStoreScreenshotMode.resolve(arguments: [
                "app",
                "-storeScreenshotMode", "YES",
                "-storeScreenshotScene", "home",
                "-storeScreenshotLanguage", "fr",
                "-storeScreenshotToken", "token-3",
            ]) == .invalid
        )
        #expect(
            CalculatorStoreScreenshotMode.resolve(arguments: [
                "app",
                "-storeScreenshotMode", "YES",
                "-storeScreenshotScene", "home",
                "-storeScreenshotLanguage", "en",
                "-storeScreenshotToken", "",
            ]) == .invalid
        )
    }

    @Test @MainActor
    func screenshotPreferencesUseDeterministicGaugeAndAdjustmentDrafts() {
        let mode = CalculatorStoreScreenshotMode(
            scene: .adjustment,
            language: .en,
            readinessToken: "preferences-\(UUID().uuidString)"
        )

        let preferences = mode.makePreferences()

        #expect(preferences.gauge == GaugeDraft(
            unit: .centimeters,
            sampleWidth: "10",
            sampleStitches: "20",
            targetWidth: "25",
            sampleHeight: "10",
            sampleRows: "30",
            targetHeight: "20"
        ))
        #expect(preferences.oneRow == OneRowAdjustmentDraft(
            currentStitches: "80",
            targetStitches: "92",
            reservesEdgeStitches: true
        ))
        #expect(preferences.rowInterval == RowIntervalAdjustmentDraft(
            totalRows: "20",
            totalStitches: "6",
            operation: .increase,
            style: .singleSide
        ))
    }
}
