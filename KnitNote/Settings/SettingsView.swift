import SwiftUI

struct SettingsView: View {
    @Binding var storedLanguage: String

    var body: some View {
        NavigationStack {
#if os(macOS)
            settingsForm
                .frame(maxWidth: .infinity)
                .frame(maxWidth: 720)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
#else
            settingsForm
#endif
        }
        .tint(WatercolorTheme.actionBerry)
    }

    private var settingsForm: some View {
        Form {
            Picker("settings.language", selection: $storedLanguage) {
                Text("language.system").tag(LanguageSelection.system.rawValue)
                Text("language.traditionalChinese").tag(LanguageSelection.traditionalChinese.rawValue)
                Text("language.english").tag(LanguageSelection.english.rawValue)
            }

            Section("calculator.tools.title") {
                NavigationLink {
                    GaugeCalculatorView()
                } label: {
                    Label("calculator.gauge.title", systemImage: "ruler")
                }

                NavigationLink {
                    EvenStitchAdjustmentCalculatorView()
                } label: {
                    Label("calculator.adjustment.title", systemImage: "arrow.up.arrow.down")
                }
            }

            BackupSettingsSection()
        }
        .scrollContentBackground(.hidden)
        .background(WatercolorBackground())
        .navigationTitle("nav.settings")
    }
}
