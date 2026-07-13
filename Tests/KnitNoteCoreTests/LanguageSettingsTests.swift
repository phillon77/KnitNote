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
}
