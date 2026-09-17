#if DEBUG
import OSLog
import SwiftUI

struct CalculatorStoreScreenshotRootView: View {
    let mode: CalculatorStoreScreenshotMode
    @StateObject private var ratingRequestContext = RatingRequestContext()
    @StateObject private var advertising = CalculatorAdConsent(configuration: .disabled)

    var presentation: CalculatorStoreScreenshotPresentation {
        mode.scene.presentation
    }

    var body: some View {
        Group {
            switch presentation.destination {
            case .home:
                NavigationStack {
                    CalculatorHomeView(initialScrollTarget: presentation.scrollTarget.rawValue)
                }
            case .gauge:
                NavigationStack {
                    GaugeCalculatorScreen()
                }
            case .adjustment:
                NavigationStack {
                    AdjustmentCalculatorScreen(
                        initialMode: presentation.adjustmentMode,
                        expandsRowDetails: presentation.expandsAdjustmentRowDetails,
                        initialScrollTarget: presentation.scrollTarget.rawValue,
                        initialScrollAnchor: presentation.scrollAnchor
                    )
                }
            case .settings:
                NavigationStack {
                    CalculatorSettingsView(initialScrollTarget: presentation.scrollTarget.rawValue)
                }
            }
        }
        .environment(\.locale, mode.language.locale)
        .environmentObject(ratingRequestContext)
        .environmentObject(advertising)
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
