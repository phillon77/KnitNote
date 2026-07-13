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
        .tint(WatercolorTheme.actionBerry)
        .watercolorTabBar()
    }
}

private extension View {
    @ViewBuilder
    func watercolorTabBar() -> some View {
        #if os(iOS)
        self
            .toolbarBackground(WatercolorTheme.softWhite.opacity(0.96), for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
        #else
        self
        #endif
    }
}

private struct PlaceholderView: View {
    let title: LocalizedStringKey
    let symbol: String

    var body: some View {
        NavigationStack {
            ZStack {
                WatercolorBackground()
                LemonEmptyState(title: title, message: "common.comingSoon")
                    .padding()
            }
            .navigationTitle(title)
        }
    }
}
