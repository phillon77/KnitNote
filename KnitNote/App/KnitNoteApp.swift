import SwiftUI

@main
struct KnitNoteApp: App {
    @StateObject private var projectStore: JSONProjectStore
#if os(iOS)
    @StateObject private var phoneWatchSyncCoordinator: PhoneWatchSyncCoordinator
#endif
    @AppStorage("languageSelection") private var storedLanguage = LanguageSelection.system.rawValue

    init() {
        let projectStore = JSONProjectStore.live()
        _projectStore = StateObject(wrappedValue: projectStore)
#if os(iOS)
        let phoneWatchSyncCoordinator = PhoneWatchSyncCoordinator(projectStore: projectStore)
        _phoneWatchSyncCoordinator = StateObject(
            wrappedValue: phoneWatchSyncCoordinator
        )
        phoneWatchSyncCoordinator.start()
#endif
    }

    private var selection: LanguageSelection {
        LanguageSelection(rawValue: storedLanguage) ?? .system
    }

    private var appLocale: Locale {
        LanguageSettings(selection: selection).resolvedLocale()
    }

    var body: some Scene {
        WindowGroup {
            RootView(storedLanguage: $storedLanguage)
                .environment(\.locale, appLocale)
                .environmentObject(projectStore)
                .preferredColorScheme(.light)
        }
    }
}
