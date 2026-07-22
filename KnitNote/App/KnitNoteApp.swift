import SwiftUI

@main
struct KnitNoteApp: App {
    @StateObject private var projectStore: JSONProjectStore
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
        let projectStore = screenshotMode.map {
            JSONProjectStore.live(baseDirectory: $0.baseDirectory)
        } ?? JSONProjectStore.live()
        _projectStore = StateObject(wrappedValue: projectStore)
#if os(iOS)
        let phoneWatchSyncCoordinator = PhoneWatchSyncCoordinator(projectStore: projectStore)
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
                .preferredColorScheme(.light)
        }
    }
}
