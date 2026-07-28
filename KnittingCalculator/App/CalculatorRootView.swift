import SwiftUI

struct CalculatorRootView: View {
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
    }
}
