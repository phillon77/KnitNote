import SwiftUI

@main
struct KnitNoteApp: App {
    @StateObject private var projectStore = JSONProjectStore.live()
    @AppStorage("languageSelection") private var storedLanguage = LanguageSelection.system.rawValue

    private var selection: LanguageSelection {
        LanguageSelection(rawValue: storedLanguage) ?? .system
    }

    private var language: AppLanguage {
        LanguageSettings(selection: selection).resolvedLanguage()
    }

    var body: some Scene {
        WindowGroup {
            RootView(storedLanguage: $storedLanguage)
                .environment(\.locale, Locale(identifier: language.rawValue))
                .environmentObject(projectStore)
        }
    }
}
