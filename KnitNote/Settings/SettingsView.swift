import SwiftUI

struct SettingsView: View {
    @Binding var storedLanguage: String
    @Environment(\.locale) private var locale
    let versionInfo: AppVersionInfo?

    init(
        storedLanguage: Binding<String>,
        versionInfo: AppVersionInfo? = AppVersionInfo.current()
    ) {
        _storedLanguage = storedLanguage
        self.versionInfo = versionInfo
    }

    var body: some View {
        NavigationStack {
#if os(macOS)
            GeometryReader { proxy in
                settingsForm
                    .frame(width: min(max(proxy.size.width - 48, 0), 720))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(WatercolorBackground())
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

            Section("settings.storage") {
                YarnLabelStorageRow()
            }

            BackupSettingsSection()

            Section("settings.about") {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("settings.version")
                    Spacer(minLength: 12)
                    Text(versionDisplay)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .scrollContentBackground(.hidden)
        .background(WatercolorBackground())
        .navigationTitle("nav.settings")
    }

    private var versionDisplay: String {
        AppVersionDisplayFormatter.string(
            for: versionInfo,
            bundle: .main,
            locale: locale
        )
    }
}
