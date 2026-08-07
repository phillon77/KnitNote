import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct LanguagePickerContractTests {
    @Test func settingsUsesOneCompleteLanguagePickerSource() throws {
        let source = try String(contentsOf: settingsViewURL, encoding: .utf8)
        let pickerSources = source.components(separatedBy: "Picker(\"settings.language\"").dropFirst()

        #expect(pickerSources.count == 2)
        for pickerSource in pickerSources {
            #expect(pickerSource.contains("ForEach(LanguageSelection.allCases, id: \\.rawValue)"))
            #expect(pickerSource.contains("Text(LocalizedStringKey(selection.localizationKey))"))
            #expect(pickerSource.contains(".tag(selection.rawValue)"))
        }
    }

    @Test func everySelectionHasAStableLocalizationKey() {
        let expectedKeys: [LanguageSelection: String] = [
            .system: "language.system",
            .traditionalChinese: "language.traditionalChinese",
            .simplifiedChinese: "language.simplifiedChinese",
            .english: "language.english",
            .german: "language.german",
            .french: "language.french",
            .japanese: "language.japanese",
            .norwegianBokmal: "language.norwegianBokmal",
            .swedish: "language.swedish",
            .finnish: "language.finnish",
            .danish: "language.danish",
            .korean: "language.korean",
            .greek: "language.greek",
        ]

        #expect(expectedKeys.count == LanguageSelection.allCases.count)
        for selection in LanguageSelection.allCases {
            #expect(selection.localizationKey == expectedKeys[selection])
        }
    }

    private var settingsViewURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "KnitNote/Settings/SettingsView.swift")
    }
}
