import SwiftUI

struct RootView: View {
    @Binding var storedLanguage: String

    var body: some View {
        TabView {
            ProjectsView()
                .tabItem { Label("nav.projects", systemImage: "square.grid.2x2") }
            PatternLibraryView()
                .tabItem { Label("nav.patterns", systemImage: "doc.text.image") }
            PlaceholderView(title: "nav.yarn", symbol: "shippingbox")
                .tabItem { Label("nav.yarn", systemImage: "shippingbox") }
            SettingsView(storedLanguage: $storedLanguage)
                .tabItem { Label("nav.settings", systemImage: "gearshape") }
        }
    }
}

private struct PlaceholderView: View {
    let title: LocalizedStringKey
    let symbol: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text("common.comingSoon"))
    }
}
