import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: JSONProjectStore
    @Binding var storedLanguage: String

    @ViewBuilder
    var body: some View {
        if store.loadError == nil {
            homeTabs
        } else {
            ZStack {
                WatercolorBackground()
                ContentUnavailableView {
                    Label(
                        "yarn.error.loadFailed.title",
                        systemImage: "externaldrive.badge.exclamationmark"
                    )
                } description: {
                    Text("yarn.error.loadFailed.message")
                } actions: {
                    Button("common.retry") {
                        store.retryLoad()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var homeTabs: some View {
        TabView {
            ProjectsView()
                .tabItem { Label("nav.projects", systemImage: "square.grid.2x2") }
            PatternLibraryView()
                .tabItem { Label("nav.patterns", systemImage: "doc.text.image") }
            YarnLibraryView()
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
