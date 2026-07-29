import SwiftUI

@main
struct KnittingCalculatorApp: App {
    @StateObject private var preferences: CalculatorPreferencesStore
    @StateObject private var ratingCoordinator: RatingRequestCoordinator
#if DEBUG
    private let screenshotResolution: CalculatorStoreScreenshotResolution
#endif

    init() {
#if DEBUG
        let screenshotResolution = CalculatorStoreScreenshotMode.resolve()
        self.screenshotResolution = screenshotResolution
        let preferences: CalculatorPreferencesStore
        switch screenshotResolution {
        case .ready(let mode):
            preferences = mode.makePreferences()
        case .notRequested, .invalid:
            preferences = CalculatorPreferencesStore(
                defaults: .standard,
                locale: .current
            )
        }
#else
        let preferences = CalculatorPreferencesStore(
            defaults: .standard,
            locale: .current
        )
#endif
        _preferences = StateObject(wrappedValue: preferences)
        _ratingCoordinator = StateObject(
            wrappedValue: RatingRequestCoordinator(preferences: preferences)
        )
    }

    var body: some Scene {
        WindowGroup {
            Group {
#if DEBUG
                switch screenshotResolution {
                case .ready(let mode):
                    CalculatorStoreScreenshotRootView(mode: mode)
                case .notRequested:
                    CalculatorRootView()
                case .invalid:
                    ContentUnavailableView(
                        "Invalid screenshot configuration",
                        systemImage: "xmark.octagon"
                    )
                }
#else
                CalculatorRootView()
#endif
            }
                .environmentObject(preferences)
                .environmentObject(ratingCoordinator)
        }
    }
}
