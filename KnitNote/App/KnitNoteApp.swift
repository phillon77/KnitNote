import SwiftUI

@main
struct KnitNoteApp: App {
    @StateObject private var entitlementCoordinator: EntitlementCoordinator
    @StateObject private var projectStore: JSONProjectStore
    @StateObject private var patternInboxProcessor: PatternInboxProcessor
    @StateObject private var patternBackupReminderPresenter: PatternBackupReminderPresenter
    private let screenshotMode: StoreScreenshotMode?
#if os(iOS)
    @StateObject private var phoneWatchSyncCoordinator: PhoneWatchSyncCoordinator
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
        #if os(iOS)
        let entitlementProjectionWriter = try? EntitlementProjectionWriter.live()
        #endif
        let entitlementCoordinator = EntitlementCoordinator.configured(
            screenshotMode: screenshotMode != nil,
            onSnapshotChange: { snapshot, generatedAt in
                #if os(iOS)
                try? entitlementProjectionWriter?.write(
                    snapshot: snapshot,
                    generatedAt: generatedAt
                )
                #endif
            }
        )
        _entitlementCoordinator = StateObject(wrappedValue: entitlementCoordinator)
        let projectStore = screenshotMode.map {
            JSONProjectStore.live(
                baseDirectory: $0.baseDirectory,
                authorizeMutation: { entitlementCoordinator.authorize($0) },
                commitSuccessfulMutation: {
                    entitlementCoordinator.commitSuccessfulMutation($0)
                }
            )
        } ?? JSONProjectStore.live(
            authorizeMutation: { entitlementCoordinator.authorize($0) },
            commitSuccessfulMutation: {
                entitlementCoordinator.commitSuccessfulMutation($0)
            }
        )
        _projectStore = StateObject(wrappedValue: projectStore)
        let patternBackupReminderPresenter = PatternBackupReminderPresenter()
        _patternBackupReminderPresenter = StateObject(
            wrappedValue: patternBackupReminderPresenter
        )
        _patternInboxProcessor = StateObject(
            wrappedValue: PatternInboxProcessor(
                store: projectStore,
                backupReminderPresenter: patternBackupReminderPresenter
            )
        )
#if os(iOS)
        let phoneWatchSyncCoordinator = PhoneWatchSyncCoordinator(
            projectStore: projectStore,
            entitlementCoordinator: entitlementCoordinator
        )
        _phoneWatchSyncCoordinator = StateObject(
            wrappedValue: phoneWatchSyncCoordinator
        )
        if screenshotMode == nil {
            phoneWatchSyncCoordinator.start()
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
            Group {
                if let screenshotMode {
                    StoreScreenshotRootView(
                        scene: screenshotMode.scene,
                        readinessToken: screenshotMode.readinessToken
                    )
                } else {
                    RootView(storedLanguage: $storedLanguage)
                }
            }
                .environment(\.locale, appLocale)
                .environmentObject(projectStore)
                .environmentObject(entitlementCoordinator)
                .environmentObject(patternInboxProcessor)
                .environmentObject(patternBackupReminderPresenter)
                .preferredColorScheme(.light)
                .task {
                    await entitlementCoordinator.prepare()
                }
        }
    }
}
