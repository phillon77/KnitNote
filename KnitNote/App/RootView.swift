import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: JSONProjectStore
    @EnvironmentObject private var patternInboxProcessor: PatternInboxProcessor
    @Binding var storedLanguage: String

    @ViewBuilder
    var body: some View {
        content
            .overlay(alignment: .top) {
                if let notice = patternInboxProcessor.notice {
                    PatternInboxNoticeView(notice: notice)
                        .padding()
                }
            }
            .sheet(
                item: Binding(
                    get: { patternInboxProcessor.pendingSelection },
                    set: { _ in }
                )
            ) { selection in
                PendingPatternSelectionView(selection: selection)
            }
            .alert(
                "patterns.inbox.error.title",
                isPresented: Binding(
                    get: { patternInboxProcessor.failure != nil },
                    set: { _ in }
                )
            ) {
                Button("patterns.inbox.retry") {
                    patternInboxProcessor.retry()
                }
                if patternInboxProcessor.failure?.itemID != nil {
                    Button("patterns.inbox.discard", role: .destructive) {
                        patternInboxProcessor.discard()
                    }
                }
            } message: {
                Text("patterns.inbox.error.message")
            }
            .task {
                patternInboxProcessor.processPending()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    patternInboxProcessor.processPending()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
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

private struct PatternInboxNoticeView: View {
    let notice: PatternInboxNotice

    var body: some View {
        Label("patterns.inbox.imported", systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(WatercolorTheme.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 4, y: 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("patterns.inbox.imported"))
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
