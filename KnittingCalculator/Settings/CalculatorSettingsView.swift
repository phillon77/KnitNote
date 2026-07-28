import SwiftUI

struct CalculatorSettingsView: View {
    @EnvironmentObject private var preferences: CalculatorPreferencesStore
    @Environment(\.locale) private var locale
    @State private var showsResetConfirmation = false

    var body: some View {
        Form {
            Section("calculator.settings.unit.section") {
                Picker("calculator.gauge.unit", selection: unitBinding) {
                    Text("calculator.gauge.unit.centimeters").tag(GaugeLengthUnit.centimeters)
                    Text("calculator.gauge.unit.inches").tag(GaugeLengthUnit.inches)
                }
                .accessibilityLabel(Text("calculator.gauge.unit"))
                .accessibilityValue(
                    Text(
                        preferences.gauge.unit == .centimeters
                            ? "calculator.gauge.unit.centimeters"
                            : "calculator.gauge.unit.inches"
                    )
                )
            }

            Section("calculator.settings.data.section") {
                Button("calculator.settings.reset") {
                    showsResetConfirmation = true
                }
                .foregroundStyle(.red)
                .frame(minHeight: 44)
                .accessibilityHint(Text("calculator.settings.reset.hint"))
            }

            Section("calculator.settings.knitnote.section") {
                KnitNotePromotionCard()
            }

            Section("calculator.settings.support.section") {
                Link("calculator.settings.feedback", destination: URL(string: "mailto:lzz.1999@icloud.com")!)
                    .frame(minHeight: 44)
                Link(
                    "calculator.settings.privacy",
                    destination: URL(string: "https://phillon77.github.io/KnitNote/knitting-calculator-privacy.html")!
                )
                .frame(minHeight: 44)
            }

            Section("calculator.settings.about.section") {
                LabeledContent("calculator.settings.version", value: versionText)
            }
        }
        .navigationTitle("app.settings.title")
        .confirmationDialog(
            "calculator.settings.reset.confirmation.title",
            isPresented: $showsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("calculator.settings.reset", role: .destructive) {
                preferences.resetDrafts()
            }
            Button("calculator.settings.reset.cancel", role: .cancel) {}
        } message: {
            Text("calculator.settings.reset.confirmation.message")
        }
    }

    private var unitBinding: Binding<GaugeLengthUnit> {
        Binding(
            get: { preferences.gauge.unit },
            set: { newUnit in
                var draft = preferences.gauge
                GaugeDraftConverter.convert(
                    &draft,
                    to: newUnit,
                    codec: LocalizedNumberCodec(locale: locale)
                )
                preferences.gauge = draft
            }
        )
    }

    private var versionText: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return CalculatorLocalization.formatted(
            "calculator.settings.version.format",
            version,
            build,
            locale: locale
        )
    }
}
