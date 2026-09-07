import Foundation
import SwiftUI

private struct MacMinimumWindowContentSizeModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
#if os(macOS)
        content.frame(
            minWidth: CGFloat(KnitNoteMacWindowSizingPolicy.minimumWidth),
            minHeight: CGFloat(KnitNoteMacWindowSizingPolicy.minimumHeight)
        )
#else
        content
#endif
    }
}

private extension View {
    func knitNoteMacMinimumWindowContentSize() -> some View {
        modifier(MacMinimumWindowContentSizeModifier())
    }
}

private extension Scene {
    @SceneBuilder
    func knitNoteMacWindowSizing() -> some Scene {
#if os(macOS)
        self
            .defaultSize(
                width: CGFloat(KnitNoteMacWindowSizingPolicy.defaultWidth),
                height: CGFloat(KnitNoteMacWindowSizingPolicy.defaultHeight)
            )
            .windowResizability(.contentMinSize)
#else
        self
#endif
    }
}

@main
struct KnitNoteApp: App {
    @StateObject private var entitlementCoordinator: EntitlementCoordinator
    @StateObject private var sessionOwner: AppSessionOwner
    @StateObject private var appUpdateReminderCoordinator: AppUpdateReminderCoordinator
    private let screenshotMode: StoreScreenshotMode?
#if os(iOS)
    private let languageSelectionProjection: LanguageSelectionProjection?
#endif
    @AppStorage("languageSelection") private var storedLanguage = LanguageSelection.system.rawValue

    init() {
        let screenshotMode: StoreScreenshotMode?
        switch StoreScreenshotMode.resolve() {
        case .notRequested:
            screenshotMode = nil
        case let .ready(mode):
            screenshotMode = mode
        case .invalid:
            preconditionFailure("Invalid App Store screenshot request; refusing to open the live store")
        }
        self.screenshotMode = screenshotMode
        let appUpdateFixture: AppUpdateFixture?
        switch AppUpdateFixture.resolve(
            arguments: ProcessInfo.processInfo.arguments
        ) {
        case .notRequested:
            appUpdateFixture = nil
        case let .ready(fixture):
            appUpdateFixture = fixture
        case .invalid:
            preconditionFailure("App update fixture is invalid or overlaps screenshot mode")
        }
        let appUpdateReminderCoordinator: AppUpdateReminderCoordinator
        if screenshotMode == nil {
            appUpdateReminderCoordinator = AppUpdateReminderLiveFactory.make(fixture: appUpdateFixture)
        } else {
            appUpdateReminderCoordinator = AppUpdateReminderCoordinator(
                enabled: false,
                installedVersion: { nil },
                platform: .iPhone,
                countryCode: { nil },
                fetch: { _, _ in nil },
                history: UpdateReminderHistory()
            )
        }
        _appUpdateReminderCoordinator = StateObject(
            wrappedValue: appUpdateReminderCoordinator
        )
        let launch: AppSessionLaunchResources
        let owner = AppSessionOwner()
        do {
            launch = try AppSessionComposition.makeLaunch(
                screenshotBaseDirectory: screenshotMode?.baseDirectory,
                backupHistory: BackupHistory(),
                makeScreenshotStore: { directory, entitlement in
                    JSONProjectStore.live(
                        baseDirectory: directory,
                        authorizeMutation: { entitlement.authorize($0) },
                        commitSuccessfulMutation: { entitlement.commitSuccessfulMutation($0) }
                    )
                },
                makeLocal: {
                    // Everything opening live services or app-group projections
                    // stays inside the lazily selected local shipping route.
                    let languageProjection: LanguageSelectionProjection?
#if os(iOS)
                    languageProjection = LanguageSelectionProjection.live()
                    let initialLanguage = UserDefaults.standard.string(forKey: "languageSelection")
                        .flatMap(LanguageSelection.init(rawValue:)) ?? .system
                    languageProjection?.write(initialLanguage)
                    let entitlementProjection = try? EntitlementProjectionWriter.live()
#else
                    languageProjection = nil
#endif
                    let entitlement = EntitlementCoordinator.configured(
                        screenshotMode: false,
                        onSnapshotChange: { snapshot, generatedAt in
#if os(iOS)
                            try? entitlementProjection?.write(snapshot: snapshot, generatedAt: generatedAt)
#endif
                        }
                    )
                    let store = JSONProjectStore.live(
                        authorizeMutation: { entitlement.authorize($0) },
                        commitSuccessfulMutation: { entitlement.commitSuccessfulMutation($0) }
                    )
                    return AppSessionLocalDependencies(
                        store: store,
                        entitlementCoordinator: entitlement,
                        languageSelectionProjection: languageProjection,
                        makeWatch: { fixedStore in
#if os(iOS)
                            let adapter = PhoneWatchSession()
                            let supportRoot = FileManager.default
                                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                                .appendingPathComponent("KnitNote", isDirectory: true)
                            return AppSessionWatchResources(
                                coordinator: PhoneWatchSyncCoordinator(
                                    projectStore: fixedStore,
                                    entitlementCoordinator: entitlement,
                                    transport: adapter,
                                    applicationSupportRoot: supportRoot,
                                    languageCode: {
                                        let selection = UserDefaults.standard.string(forKey: "languageSelection")
                                            .flatMap(LanguageSelection.init(rawValue:)) ?? .system
                                        return LanguageSettings(selection: selection).resolvedLanguage().rawValue
                                    }
                                ),
                                adapter: adapter
                            )
#else
                            return nil
#endif
                        }
                    )
                }
            )
            // This is the existing non-sync local store, not an account-ready
            // installation or a verified legacy adoption result.
            try owner.publishPreparedSession(launch.session, for: owner.generation)
        } catch {
            preconditionFailure("Unable to assemble the local App session")
        }
        _sessionOwner = StateObject(wrappedValue: owner)
        _entitlementCoordinator = StateObject(wrappedValue: launch.entitlementCoordinator)
#if os(iOS)
        languageSelectionProjection = launch.languageSelectionProjection
        // Preserve the local-only Watch route, starting after full publication.
        if screenshotMode == nil {
            owner.visibleSession?.presentation?.watch?.coordinator.start()
        }
#endif
    }

    private var selection: LanguageSelection {
        LanguageSelection(rawValue: storedLanguage) ?? .system
    }

    private var appLocale: Locale {
        if let screenshotMode {
            return screenshotMode.locale
        }
        return LanguageSettings(selection: selection).resolvedLocale()
    }

    var body: some Scene {
        WindowGroup {
            AppSessionRootView(owner: sessionOwner) {
                if let screenshotMode {
                    StoreScreenshotRootView(
                        scene: screenshotMode.scene,
                        readinessToken: screenshotMode.readinessToken
                    )
                } else {
                    RootView(storedLanguage: $storedLanguage)
                }
            } unavailable: {
                ProgressView(LocaleAwareText.string("common.loading", locale: appLocale))
            }
                .environment(\.locale, appLocale)
                .environmentObject(entitlementCoordinator)
                .environmentObject(appUpdateReminderCoordinator)
                .preferredColorScheme(.light)
#if os(iOS)
                .onChange(of: storedLanguage) { _, newValue in
                    languageSelectionProjection?.write(
                        LanguageSelection(rawValue: newValue) ?? .system
                    )
                    sessionOwner.visibleSession?.presentation?.watch?.coordinator.publishLatestSnapshotIfChanged()
                }
#endif
                .knitNoteMacMinimumWindowContentSize()
                .task {
                    await entitlementCoordinator.prepare()
                }
        }
        .knitNoteMacWindowSizing()
    }
}
