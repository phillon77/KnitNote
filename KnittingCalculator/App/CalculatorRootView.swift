import SwiftUI

struct CalculatorRootView: View {
    var body: some View {
        NavigationStack {
            CalculatorHomeView()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            // Settings routing is intentionally added with Task 7.
                        } label: {
                            Label("app.settings.title", systemImage: "gearshape")
                        }
                        .disabled(true)
                    }
                }
        }
    }
}
