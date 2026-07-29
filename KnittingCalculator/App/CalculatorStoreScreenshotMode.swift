#if DEBUG
import Foundation
import KnittingCalculatorCore

enum CalculatorStoreScreenshotScene: String, CaseIterable {
    case home, gauge, adjustment, privacy, promotion, privacyPromotion

    var presentation: CalculatorStoreScreenshotPresentation {
        switch self {
        case .home:
            .init(destination: .home)
        case .gauge:
            .init(destination: .gauge)
        case .adjustment:
            .init(
                destination: .adjustment,
                adjustmentMode: .acrossRows,
                expandsAdjustmentRowDetails: true
            )
        case .privacy:
            .init(destination: .settings)
        case .promotion:
            .init(
                destination: .home,
                showsKnitNotePromotion: true
            )
        case .privacyPromotion:
            .init(
                destination: .settings,
                showsKnitNotePromotion: true
            )
        }
    }
}

enum CalculatorStoreScreenshotDestination: Equatable {
    case home
    case gauge
    case adjustment
    case settings
}

struct CalculatorStoreScreenshotPresentation: Equatable {
    let destination: CalculatorStoreScreenshotDestination
    let showsKnitNotePromotion: Bool
    let adjustmentMode: AdjustmentMode
    let expandsAdjustmentRowDetails: Bool

    init(
        destination: CalculatorStoreScreenshotDestination,
        showsKnitNotePromotion: Bool = false,
        adjustmentMode: AdjustmentMode = .oneRow,
        expandsAdjustmentRowDetails: Bool = false
    ) {
        self.destination = destination
        self.showsKnitNotePromotion = showsKnitNotePromotion
        self.adjustmentMode = adjustmentMode
        self.expandsAdjustmentRowDetails = expandsAdjustmentRowDetails
    }
}

enum CalculatorStoreScreenshotLanguage: String {
    case zhHant = "zh-Hant"
    case en

    var locale: Locale {
        Locale(identifier: rawValue)
    }
}

struct CalculatorStoreScreenshotMode: Equatable {
    let scene: CalculatorStoreScreenshotScene
    let language: CalculatorStoreScreenshotLanguage
    let readinessToken: String

    static func resolve(
        arguments: [String]
    ) -> CalculatorStoreScreenshotResolution {
        guard arguments.containsAdjacent(
            key: "-storeScreenshotMode",
            value: "YES"
        ) else {
            return .notRequested
        }
        guard let sceneValue = arguments.value(after: "-storeScreenshotScene"),
              let scene = CalculatorStoreScreenshotScene(rawValue: sceneValue),
              let languageValue = arguments.value(after: "-storeScreenshotLanguage"),
              let language = CalculatorStoreScreenshotLanguage(rawValue: languageValue),
              let readinessToken = arguments.value(after: "-storeScreenshotToken"),
              !readinessToken.isEmpty else {
            return .invalid
        }
        return .ready(.init(
            scene: scene,
            language: language,
            readinessToken: readinessToken
        ))
    }

    static func resolve(
        processInfo: ProcessInfo = .processInfo
    ) -> CalculatorStoreScreenshotResolution {
        resolve(arguments: processInfo.arguments)
    }

    @MainActor
    func makePreferences() -> CalculatorPreferencesStore {
        let suite = "com.phillon.KnittingCalculator.StoreScreenshots.\(readinessToken)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = CalculatorPreferencesStore(
            defaults: defaults,
            locale: language.locale
        )
        store.gauge = GaugeDraft(
            unit: .centimeters,
            sampleWidth: "10",
            sampleStitches: "20",
            targetWidth: "25",
            sampleHeight: "10",
            sampleRows: "30",
            targetHeight: "20"
        )
        store.oneRow = OneRowAdjustmentDraft(
            currentStitches: "80",
            targetStitches: "92",
            reservesEdgeStitches: true
        )
        store.rowInterval = RowIntervalAdjustmentDraft(
            totalRows: "20",
            totalStitches: "6",
            operation: .increase,
            style: .singleSide
        )
        return store
    }
}

enum CalculatorStoreScreenshotResolution: Equatable {
    case notRequested
    case ready(CalculatorStoreScreenshotMode)
    case invalid
}

private extension Array where Element == String {
    func value(after key: String) -> String? {
        guard let index = firstIndex(of: key) else { return nil }
        let valueIndex = index + 1
        guard indices.contains(valueIndex) else { return nil }
        return self[valueIndex]
    }

    func containsAdjacent(key: String, value: String) -> Bool {
        indices.contains { index in
            self[index] == key
                && indices.contains(index + 1)
                && self[index + 1] == value
        }
    }
}
#endif
