import SwiftUI

struct SettingsView: View {
    @Binding var storedLanguage: String

    var body: some View {
        NavigationStack {
            Form {
                Picker("settings.language", selection: $storedLanguage) {
                    Text("language.system").tag(LanguageSelection.system.rawValue)
                    Text("language.traditionalChinese").tag(LanguageSelection.traditionalChinese.rawValue)
                    Text("language.english").tag(LanguageSelection.english.rawValue)
                }
            }
            .navigationTitle("nav.settings")
        }
    }
}
