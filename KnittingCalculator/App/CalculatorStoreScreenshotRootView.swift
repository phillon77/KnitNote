#if DEBUG
import OSLog
import SwiftUI

struct CalculatorStoreScreenshotRootView: View {
    let mode: CalculatorStoreScreenshotMode
    @StateObject private var ratingRequestContext = RatingRequestContext()

    var body: some View {
        let presentation = mode.scene.presentation

        Group {
            switch presentation.destination {
            case .home:
                NavigationStack {
                    CalculatorHomeView(
                        showsKnitNotePromotion: presentation.showsKnitNotePromotion
                    )
                }
            case .gauge:
                NavigationStack {
                    GaugeCalculatorScreen()
                }
            case .adjustment:
                NavigationStack {
                    AdjustmentCalculatorScreen(
                        initialMode: presentation.adjustmentMode,
                        expandsRowDetails: presentation.expandsAdjustmentRowDetails
                    )
                }
            case .settings:
                NavigationStack {
                    CalculatorSettingsView(
                        showsKnitNotePromotion: presentation.showsKnitNotePromotion
                    )
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
