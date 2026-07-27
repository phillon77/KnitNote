import SwiftUI

@MainActor
final class PatternBackupReminderPresenter: ObservableObject {
    @Published private(set) var isPresented: Bool
    @Published private(set) var isShowingBackupSettings: Bool
    private var coordinator: PatternBackupReminderCoordinator

    init(history: BackupHistory = .init()) {
        let coordinator = PatternBackupReminderCoordinator(history: history)
        self.coordinator = coordinator
        isPresented = coordinator.isPresented
        isShowingBackupSettings = coordinator.isShowingBackupSettings
    }

    func accept(_ outcome: PatternImportOutcome) {
        coordinator.accept(outcome)
        publish()
    }

    func accept(_ outcomes: [PatternImportOutcome]) {
        coordinator.accept(outcomes)
        publish()
    }

    func dismiss(openBackupSettings: Bool) {
        coordinator.dismiss(openBackupSettings: openBackupSettings)
        publish()
    }

    func closeBackupSettings() {
        coordinator.closeBackupSettings()
        publish()
    }

    private func publish() {
        isPresented = coordinator.isPresented
        isShowingBackupSettings = coordinator.isShowingBackupSettings
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: JSONProjectStore
    @EnvironmentObject private var entitlementCoordinator: EntitlementCoordinator
    @EnvironmentObject private var patternInboxProcessor: PatternInboxProcessor
    @EnvironmentObject private var backupReminderPresenter: PatternBackupReminderPresenter
    @Binding var storedLanguage: String
    @State private var isUnlockSheetRequested = false

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
            .sheet(isPresented: unlockSheetBinding) {
                UnlockSheet()
            }
            .sheet(
                isPresented: Binding(
                    get: { backupReminderPresenter.isShowingBackupSettings },
                    set: { isPresented in
                        if !isPresented {
                            backupReminderPresenter.closeBackupSettings()
                        }
                    }
                )
            ) {
                NavigationStack {
                    Form {
                        BackupSettingsSection()
                    }
                    .navigationTitle("nav.settings")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("common.done") {
                                backupReminderPresenter.closeBackupSettings()
                            }
                        }
                    }
                }
            }
            .alert(
                "patterns.backup.reminder.title",
                isPresented: Binding(
                    get: { backupReminderPresenter.isPresented },
                    set: { isPresented in
                        if !isPresented {
                            backupReminderPresenter.dismiss(openBackupSettings: false)
                        }
                    }
                )
            ) {
                Button("patterns.backup.reminder.settings") {
                    backupReminderPresenter.dismiss(openBackupSettings: true)
                }
                Button("patterns.backup.reminder.dismiss", role: .cancel) {
                    backupReminderPresenter.dismiss(openBackupSettings: false)
                }
            } message: {
                Text("patterns.backup.reminder.message")
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
            .onChange(of: entitlementCoordinator.unlockRequest) { _, request in
                if request != nil {
                    isUnlockSheetRequested = true
                }
            }
            .onChange(of: entitlementCoordinator.snapshot) { _, snapshot in
                if UnlockPresentation.shouldDismissUnlock(
                    snapshot: snapshot,
                    now: .now
                ) {
                    isUnlockSheetRequested = false
                }
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
            ProjectsView(onShowUnlock: {
                isUnlockSheetRequested = true
            })
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

    private var unlockSheetBinding: Binding<Bool> {
        Binding(
            get: {
                isUnlockSheetRequested
                    || entitlementCoordinator.unlockRequest != nil
            },
            set: { isPresented in
                guard !isPresented else { return }
                isUnlockSheetRequested = false
                entitlementCoordinator.dismissUnlock()
            }
        )
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
