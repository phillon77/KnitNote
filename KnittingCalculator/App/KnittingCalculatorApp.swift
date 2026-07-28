import SwiftUI

@main
struct KnittingCalculatorApp: App {
    @StateObject private var preferences = CalculatorPreferencesStore(
        defaults: .standard,
        locale: .current
    )

    var body: some Scene {
        WindowGroup {
            CalculatorRootView()
                .environmentObject(preferences)
        }
    }
}
