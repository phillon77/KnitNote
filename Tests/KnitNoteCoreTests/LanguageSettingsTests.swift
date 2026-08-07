import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct LanguageSettingsTests {
    @Test(arguments: [
        ("zh-Hant-HK", AppLanguage.traditionalChinese),
        ("zh-Hans-CN", AppLanguage.simplifiedChinese),
        ("zh-Hans-HK", AppLanguage.simplifiedChinese),
        ("zh-CN", AppLanguage.simplifiedChinese),
        ("zh-SG", AppLanguage.simplifiedChinese),
        ("de-DE", AppLanguage.german),
        ("fr-CA", AppLanguage.french),
        ("ja-JP", AppLanguage.japanese),
    ])
    func followsEverySupportedSystemLanguage(identifier: String, expected: AppLanguage) {
        #expect(LanguageSettings(selection: .system)
            .resolvedLanguage(systemLanguages: [identifier]) == expected)
    }

    @Test(arguments: [
        ("nb-NO", AppLanguage.norwegianBokmal),
        ("no-NO", AppLanguage.norwegianBokmal),
        ("sv-SE", AppLanguage.swedish),
        ("fi-FI", AppLanguage.finnish),
        ("da-DK", AppLanguage.danish),
        ("ko-KR", AppLanguage.korean),
        ("el-GR", AppLanguage.greek),
    ])
    func followsVersion141SystemLanguages(identifier: String, expected: AppLanguage) {
        #expect(LanguageSettings(selection: .system)
            .resolvedLanguage(systemLanguages: [identifier]) == expected)
    }

    @Test func unsupportedSystemLanguageFallsBackToEnglish() {
        #expect(LanguageSettings(selection: .system)
            .resolvedLanguage(systemLanguages: ["it-IT"]) == .english)
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

    @Test func everyExplicitSelectionOverridesTheSystemLanguage() throws {
        for selection in LanguageSelection.allCases where selection != .system {
            let language = try #require(selection.explicitLanguage)
            #expect(LanguageSettings(selection: selection)
                .resolvedLanguage(systemLanguages: ["ko-KR"]) == language)
        }
    }

    @Test func selectedGermanKeepsTheDeviceRegion() {
        let locale = LanguageSettings(selection: .german).resolvedLocale(
            systemLanguages: ["en-US"],
            regionLocale: Locale(identifier: "fr_CA")
        )
        #expect(locale.language.languageCode?.identifier == "de")
        #expect(locale.region?.identifier == "CA")
    }

    @Test func version141IdentifiersExtendVersion140WithoutChangingHistory() {
        #expect(SupportedLocalization.v140Identifiers == [
            "en", "zh-Hant", "zh-Hans", "de", "fr", "ja",
        ])
        #expect(SupportedLocalization.v141Identifiers == [
            "en", "zh-Hant", "zh-Hans", "de", "fr", "ja",
            "nb", "sv", "fi", "da", "ko", "el",
        ])
    }
}
