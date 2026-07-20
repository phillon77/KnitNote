import SwiftUI

@main
struct KnitNoteApp: App {
    @StateObject private var projectStore = JSONProjectStore.live()
    @AppStorage("languageSelection") private var storedLanguage = LanguageSelection.system.rawValue

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
