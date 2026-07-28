import SwiftUI

struct CalculatorRootView: View {
    @EnvironmentObject private var ratingCoordinator: RatingRequestCoordinator

    var body: some View {
        NavigationStack {
            CalculatorHomeView()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            CalculatorSettingsView()
                        } label: {
                            Label("app.settings.title", systemImage: "gearshape")
                        }
                        .accessibilityLabel(Text("app.settings.title"))
                    }
                }
        }
        .background {
            RatingRequestSceneObserver { scene in
                ratingCoordinator.update(windowScene: scene)
            }
            .frame(width: 0, height: 0)
        }
    }
}
