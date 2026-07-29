#if DEBUG
import OSLog
import SwiftUI

struct CalculatorStoreScreenshotRootView: View {
    let mode: CalculatorStoreScreenshotMode
    @StateObject private var ratingRequestContext = RatingRequestContext()

    var body: some View {
        Group {
            switch mode.scene {
            case .home, .promotion:
                NavigationStack {
                    CalculatorHomeView()
                }
            case .gauge:
                NavigationStack {
                    GaugeCalculatorScreen()
                }
            case .adjustment:
                NavigationStack {
                    AdjustmentCalculatorScreen()
                }
            case .privacy, .privacyPromotion:
                NavigationStack {
                    CalculatorSettingsView()
                }
            }
        }
        .environment(\.locale, mode.language.locale)
        .environmentObject(ratingRequestContext)
        .overlay(alignment: .bottomTrailing) {
            Text("Ready")
                .opacity(0.001)
                .accessibilityIdentifier("storeScreenshot.ready")
        }
        .background {
            RatingRequestSceneObserver { scene in
                ratingRequestContext.update(windowScene: scene)
            }
            .frame(width: 0, height: 0)
        }
        .task {
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            Logger(
                subsystem: "com.phillon.KnittingCalculator",
                category: "StoreScreenshots"
            ).notice(
                "storeScreenshot.ready.\(mode.readinessToken, privacy: .public)"
            )
        }
    }
}
#endif
