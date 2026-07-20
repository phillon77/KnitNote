import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct LanguageSettingsTests {
    @Test func followsSupportedSystemLanguage() {
        let settings = LanguageSettings(selection: .system)
        #expect(settings.resolvedLanguage(systemLanguages: ["zh-Hant-TW"]) == .traditionalChinese)
    }

    @Test func unsupportedSystemLanguageFallsBackToEnglish() {
        let settings = LanguageSettings(selection: .system)
        #expect(settings.resolvedLanguage(systemLanguages: ["fr-FR"]) == .english)
    }

    @Test func explicitChoiceOverridesSystem() {
        let settings = LanguageSettings(selection: .traditionalChinese)
        #expect(settings.resolvedLanguage(systemLanguages: ["en-US"]) == .traditionalChinese)
    }

    @Test func explicitAppLanguagePreservesTheDeviceRegionForNumbers() {
        let settings = LanguageSettings(selection: .english)

        let locale = settings.resolvedLocale(
            systemLanguages: ["zh-Hant-TW"],
            regionLocale: Locale(identifier: "de_DE")
        )
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal

        #expect(locale.language.languageCode?.identifier == "en")
        #expect(locale.region?.identifier == "DE")
        #expect(formatter.string(from: 1.5) == "1,5")
    }

    @Test func traditionalChineseSelectionAlsoPreservesTheDeviceRegion() {
        let settings = LanguageSettings(selection: .traditionalChinese)

        let locale = settings.resolvedLocale(
            systemLanguages: ["en-GB"],
            regionLocale: Locale(identifier: "en_US")
        )

        #expect(locale.language.languageCode?.identifier == "zh")
        #expect(locale.region?.identifier == "US")
    }
}
