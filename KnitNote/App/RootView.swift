import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var store: JSONProjectStore
    @EnvironmentObject private var reminderPresentationStore: KnittingReminderPresentationStore
    @EnvironmentObject private var entitlementCoordinator: EntitlementCoordinator
    @EnvironmentObject private var patternInboxProcessor: PatternInboxProcessor
    @EnvironmentObject private var backupReminderPresenter: PatternBackupReminderPresenter
    @EnvironmentObject private var appUpdateReminderCoordinator: AppUpdateReminderCoordinator
    @Binding var storedLanguage: String
    @State private var unlockPresentation = UnlockPresentationOrchestrator()

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
                } else {
                    Button("patterns.inbox.later", role: .cancel) {
                        patternInboxProcessor.dismissFailure()
                    }
                }
            } message: {
                Text("patterns.inbox.error.message")
            }
            // APP_UPDATE_PRESENTATION_BEGIN
            .alert(
                Text(verbatim: LocaleAwareText.string("update.available.title", locale: locale)),
                isPresented: Binding(
                    get: { shouldPresentAppUpdate },
                    set: { _ in }
                ),
                presenting: appUpdateReminderCoordinator.pendingUpdate
            ) { update in
                Button(
                    role: .cancel,
                    action: { appUpdateReminderCoordinator.remindLater() },
                    label: {
                        Text(verbatim: LocaleAwareText.string("update.available.later", locale: locale))
                    }
                )
                Button {
                    openURL(update.storeURL)
                    appUpdateReminderCoordinator.didOpenStore()
                } label: {
                    Text(verbatim: LocaleAwareText.string("update.available.openStore", locale: locale))
                }
            } message: { update in
                let installedVersion = AppVersionInfo.current()?.version ?? "—"
                let currentLine = "\(LocaleAwareText.string("update.available.currentVersion", locale: locale)): \(installedVersion)"
                let latestLine = "\(LocaleAwareText.string("update.available.latestVersion", locale: locale)): \(update.displayVersion)"
                let message = LocaleAwareText.format(
                    "update.available.message",
                    locale: locale,
                    currentLine,
                    latestLine
                )
                Text(verbatim: message)
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await appUpdateReminderCoordinator.checkIfNeeded()
            }
            // APP_UPDATE_PRESENTATION_END
            .task(id: scenePhase) {
                guard scenePhase == .active,
                      await entitlementCoordinator.ensurePrepared() else {
                    return
                }
                patternInboxProcessor.processPending()
            }
            .onChange(of: entitlementCoordinator.unlockRequest) { _, request in
                unlockPresentation.receiveCoordinatorRequest(request)
            }
            .onChange(of: entitlementCoordinator.snapshot) { _, snapshot in
                if UnlockPresentation.shouldDismissUnlock(
                    snapshot: snapshot,
                    now: .now
                ) {
                    unlockPresentation.dismiss()
                }
            }
            .onAppear {
                reminderPresentationStore.pruneProjects(
                    keeping: Set(store.projects.map(\.id))
                )
            }
            .onChange(of: store.projects) { _, projects in
                reminderPresentationStore.pruneProjects(
                    keeping: Set(projects.map(\.id))
                )
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
                unlockPresentation.requestExplicitly()
            }, onCreateSheetPresentationChanged: { isPresented in
                if isPresented {
                    unlockPresentation.createProjectSheetDidPresent()
                } else {
                    unlockPresentation.createProjectSheetDidDismiss()
                }
            })
                .tabItem { Label("nav.projects", systemImage: "square.grid.2x2") }
            PatternLibraryView()
                .tabItem { Label("nav.patterns", systemImage: "doc.text.image") }
            YarnLibraryView()
                .tabItem { Label("nav.yarn", systemImage: "shippingbox") }
            SettingsView(storedLanguage: $storedLanguage, onShowUnlock: {
                unlockPresentation.requestExplicitly()
            })
                .tabItem { Label("nav.settings", systemImage: "gearshape") }
        }
        .tint(WatercolorTheme.actionBerry)
        .watercolorTabBar()
    }

    // APP_UPDATE_PRIORITY_OWNER_BEGIN
    private var shouldPresentAppUpdate: Bool {
        AppUpdatePresentationState(
            hasBlockingStoreLoadError: store.loadError != nil,
            isCreateProjectSheetPresented:
                unlockPresentation.isCreateProjectSheetPresented,
            isBackupReminderPresented: backupReminderPresenter.isPresented,
            isBackupSettingsPresented:
                backupReminderPresenter.isShowingBackupSettings,
            hasPatternInboxFailure: patternInboxProcessor.failure != nil,
            hasPendingPatternSelection:
                patternInboxProcessor.pendingSelection != nil,
            isUnlockPaywallPresented: unlockSheetBinding.wrappedValue
        ).shouldPresentUpdate(
            hasPendingUpdate: appUpdateReminderCoordinator.pendingUpdate != nil
        )
    }
    // APP_UPDATE_PRIORITY_OWNER_END

    private var unlockSheetBinding: Binding<Bool> {
        Binding(
            get: {
                unlockPresentation.isPresented(
                    coordinatorRequest: entitlementCoordinator.unlockRequest
                )
            },
            set: { isPresented in
                guard !isPresented else { return }
                unlockPresentation.dismiss()
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
