import SwiftUI

@main
struct KnittingCalculatorApp: App {
    @StateObject private var preferences: CalculatorPreferencesStore
    @StateObject private var ratingCoordinator: RatingRequestCoordinator

    init() {
        let preferences = CalculatorPreferencesStore(
            defaults: .standard,
            locale: .current
        )
        _preferences = StateObject(wrappedValue: preferences)
        _ratingCoordinator = StateObject(
            wrappedValue: RatingRequestCoordinator(preferences: preferences)
        )
    }

    var body: some Scene {
        WindowGroup {
            CalculatorRootView()
                .environmentObject(preferences)
                .environmentObject(ratingCoordinator)
        }
    }
}
