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
            macSettingsContent
#else
            settingsForm
#endif
        }
        .tint(WatercolorTheme.actionBerry)
    }

    #if os(macOS)
    private var macSettingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CGFloat(MacSettingsLayout.sectionSpacing)) {
                MacSettingsSection(title: "settings.general") {
                    MacSettingsRow {
                        HStack(spacing: 16) {
                            Text("settings.language")
                            Spacer(minLength: 16)
                            languagePicker
                                .labelsHidden()
                                .frame(width: 210)
                        }
                    }
                }

                MacSettingsSection(title: "calculator.tools.title") {
                    calculatorLink(
                        title: "calculator.gauge.title",
                        systemImage: "ruler",
                        destination: GaugeCalculatorView()
                    )
                    Divider()
                    calculatorLink(
                        title: "calculator.adjustment.title",
                        systemImage: "arrow.up.arrow.down",
                        destination: EvenStitchAdjustmentCalculatorView()
                    )
                }

                MacSettingsSection(title: "settings.data") {
                    MacSettingsRow {
                        YarnLabelStorageRow()
                    }
                    Divider()
                    BackupSettingsSection()
                }

                MacSettingsSection(title: "settings.about") {
                    calculatorLink(
                        title: "about.story.title",
                        systemImage: "book.closed",
                        destination: KnitNoteStoryView()
                    )
                    Divider()
                    MacSettingsRow {
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text("settings.version")
                            Spacer(minLength: 12)
                            Text(versionDisplay)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: CGFloat(MacSettingsLayout.contentMaximumWidth))
            .padding(CGFloat(MacSettingsLayout.outerPadding))
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(WatercolorBackground())
        .navigationTitle("nav.settings")
    }

    private var languagePicker: some View {
        Picker("settings.language", selection: $storedLanguage) {
            ForEach(LanguageSelection.allCases, id: \.rawValue) { selection in
                Text(LocalizedStringKey(selection.localizationKey))
                    .tag(selection.rawValue)
            }
        }
    }

    private func calculatorLink<Destination: View>(
        title: LocalizedStringKey,
        systemImage: String,
        destination: Destination
    ) -> some View {
        NavigationLink {
            destination
        } label: {
            MacSettingsRow {
                HStack(spacing: 12) {
                    Label(title, systemImage: systemImage)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
    }
    #endif

    private var settingsForm: some View {
        Form {
            Picker("settings.language", selection: $storedLanguage) {
                ForEach(LanguageSelection.allCases, id: \.rawValue) { selection in
                    Text(LocalizedStringKey(selection.localizationKey))
                        .tag(selection.rawValue)
                }
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
                NavigationLink {
                    KnitNoteStoryView()
                } label: {
                    Label("about.story.title", systemImage: "book.closed")
                }
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

private struct KnitNoteStoryView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("about.story.title")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("about.story.p1")
                Text("about.story.p2")
                Text("about.story.p3")
                Text("about.story.p4")
                Text("about.story.p5")
                Text("about.story.p6")

                Divider()

                Text("about.usage.title")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("about.usage.body")
            }
            .font(.body)
            .lineSpacing(4)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
            .frame(maxWidth: 680, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(WatercolorBackground())
        .navigationTitle("about.story.title")
    }
}
