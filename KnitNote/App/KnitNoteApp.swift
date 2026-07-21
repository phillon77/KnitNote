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
        _phoneWatchSyncCoordinator = StateObject(
            wrappedValue: PhoneWatchSyncCoordinator(projectStore: projectStore)
        )
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
#if os(iOS)
                .onAppear {
                    phoneWatchSyncCoordinator.start()
                }
#endif
        }
    }
}
