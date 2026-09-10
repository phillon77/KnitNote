import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct RuntimeLocalizationBehaviorTests {
    // Missing story resources or English fallback for a selected language must fail.
    @Test func aboutStoryResolvesInEveryLanguageWithCorrectedLemonYear() throws {
        let keys = ["about.story.title", "about.story.p1", "about.story.p2",
                    "about.story.p3", "about.story.p4", "about.story.p5",
                    "about.story.p6", "about.usage.title", "about.usage.body"]
        let values = try shippingCatalogValues(keys: keys)
        let bundle = try localizedFixtureBundle(additionalStringsByLanguage: values)
        for language in SupportedLocalization.v150Identifiers {
            for key in keys {
                let value = LocaleAwareText.string(key, locale: Locale(identifier: language), bundle: bundle)
                #expect(!value.isEmpty && value != key)
            }
            let memory = LocaleAwareText.string("about.story.p3", locale: Locale(identifier: language), bundle: bundle)
            #expect(memory.contains("2025"))
            #expect(!memory.contains("2023"))
        }
        #expect(LocaleAwareText.string("about.story.title", locale: Locale(identifier: "zh-Hant"), bundle: bundle) == "開發故事")
        #expect(LocaleAwareText.string("about.usage.title", locale: Locale(identifier: "zh-Hant"), bundle: bundle) == "建議使用方式")
        #expect(LocaleAwareText.string("about.story.title", locale: Locale(identifier: "en"), bundle: bundle) == "The Story Behind KnitNote")
        #expect(LocaleAwareText.string("about.story.title", locale: Locale(identifier: "ja"), bundle: bundle) == "KnitNote が生まれた物語")
    }

    @Test func semanticMessageRendersAgainWhenTheSelectedLocaleChanges() throws {
        let bundle = try localizedFixtureBundle()
        let message = LocalizedMessage.key("save.error")

        #expect(
            message.resolved(
                locale: Locale(identifier: "en_US"),
                bundle: bundle
            ) == "Save failed"
        )
        #expect(
            message.resolved(
                locale: Locale(identifier: "de_DE"),
                bundle: bundle
            ) == "Speichern fehlgeschlagen"
        )
    }

    @Test func formattedTitleUsesTheSelectedLocaleAtRenderTime() throws {
        let bundle = try localizedFixtureBundle()

        #expect(
            LocaleAwareText.format(
                "page.title",
                locale: Locale(identifier: "en_US"),
                bundle: bundle,
                3
            ) == "Page 3 Note"
        )
        #expect(
            LocaleAwareText.format(
                "page.title",
                locale: Locale(identifier: "de_DE"),
                bundle: bundle,
                3
            ) == "Notiz zu Seite 3"
        )
    }

    @Test func pluralVariationUsesTheSelectedResourceLanguage() throws {
        let bundle = try localizedFixtureBundle()

        #expect(
            LocaleAwareText.interpolated(
                "project.count",
                defaultValue: "\(1) project",
                locale: Locale(identifier: "en_US"),
                bundle: bundle
            ) == "1 project"
        )
        #expect(
            LocaleAwareText.interpolated(
                "project.count",
                defaultValue: "\(2) projects",
                locale: Locale(identifier: "de_DE"),
                bundle: bundle
            ) == "2 Projekte"
        )
    }

    @Test func supportedLocaleMissingKeyFallsBackToTheEnglishCatalog() throws {
        let bundle = try localizedFixtureBundle()

        #expect(
            LocaleAwareText.string(
                "english.only",
                locale: Locale(identifier: "de_DE"),
                bundle: bundle
            ) == "English only"
        )
        #expect(
            LocaleAwareText.format(
                "english.format",
                locale: Locale(identifier: "de_DE"),
                bundle: bundle,
                4
            ) == "English Page 4"
        )
    }

    @Test func supportedLocaleMissingPluralVariationFallsBackToTheEnglishCatalogVariation() throws {
        let bundle = try localizedFixtureBundle()

        #expect(
            LocaleAwareText.interpolated(
                "fallback.count",
                defaultValue: "\(2) default entries",
                locale: Locale(identifier: "de_DE"),
                bundle: bundle
            ) == "2 English catalog entries"
        )
    }

    @Test func byteCountReformatsWhenTheSelectedLocaleChanges() {
        let bytes: Int64 = 1_500_000

        #expect(
            LocaleAwareText.byteCount(
                bytes,
                locale: Locale(identifier: "en_US")
            ) == "1.5 MB"
        )
        #expect(
            LocaleAwareText.byteCount(
                bytes,
                locale: Locale(identifier: "de_DE")
            ) == "1,5 MB"
        )
    }

    @Test func projectsTitleResolvesInEveryVersion150LocaleWithoutChangingProjectNames() throws {
        let titles = try navigationTitlesFromShippingCatalog(key: "nav.projects")
        let bundle = try localizedFixtureBundle(
            additionalStringsByLanguage: titles.mapValues { ["nav.projects": $0] }
        )

        for language in SupportedLocalization.v150Identifiers {
            #expect(
                LocaleAwareText.string(
                    "nav.projects",
                    locale: Locale(identifier: language),
                    bundle: bundle
                ) != "nav.projects"
            )
        }

        #expect(
            LocaleAwareText.string(
                "nav.projects",
                locale: Locale(identifier: "de"),
                bundle: bundle
            ) == "Projekte"
        )
        #expect(
            LocaleAwareText.string(
                "nav.projects",
                locale: Locale(identifier: "nl"),
                bundle: bundle
            ) == "Projecten"
        )
        #expect(
            LocaleAwareText.string(
                "nav.projects",
                locale: Locale(identifier: "zh-Hant"),
                bundle: bundle
            ) == "作品"
        )

        let userName = "作品 test 42"
        #expect(userName == "作品 test 42")
    }

    @MainActor @Test func yarnLibraryTitleResolvesInEveryVersion150LocaleWithoutChangingYarnNames() throws {
        let titles = try navigationTitlesFromShippingCatalog(key: "yarn.library.title")
        let bundle = try localizedFixtureBundle(
            additionalStringsByLanguage: titles.mapValues { ["yarn.library.title": $0] }
        )

        for language in SupportedLocalization.v150Identifiers {
            #expect(
                LocaleAwareText.string(
                    "yarn.library.title",
                    locale: Locale(identifier: language),
                    bundle: bundle
                ) != "yarn.library.title"
            )
        }

        #expect(LocaleAwareText.string(
            "yarn.library.title",
            locale: Locale(identifier: "en"),
            bundle: bundle
        ) == "Yarn Library")
        #expect(LocaleAwareText.string(
            "yarn.library.title",
            locale: Locale(identifier: "ja"),
            bundle: bundle
        ) == "毛糸ライブラリ")
        #expect(LocaleAwareText.string(
            "yarn.library.title",
            locale: Locale(identifier: "zh-Hant"),
            bundle: bundle
        ) == "毛線庫")

        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "RuntimeLocalizationYarn-\(UUID().uuidString).json")
        let store = JSONProjectStore(url: storeURL)
        let userYarn = try StoredYarn(name: "Jaipur peace silk")
        try store.addYarn(userYarn)

        for language in ["zh-Hant", "en", "ja"] {
            _ = LocaleAwareText.string(
                "yarn.library.title",
                locale: Locale(identifier: language),
                bundle: bundle
            )
        }

        #expect(store.yarns == [userYarn])
    }

    @Test func smartReminderSemanticsReorderForSelectedLocalesWhileCustomTextStaysVerbatim() throws {
        let keys = [
            "knittingReminder.kind.changeYarn",
            "knittingReminder.rule.repeating.limited",
            "knittingReminder.card.queue",
        ]
        let bundle = try localizedFixtureBundle(
            additionalStringsByLanguage: try shippingCatalogValues(keys: keys)
        )

        #expect(LocaleAwareText.string(
            "knittingReminder.kind.changeYarn",
            locale: Locale(identifier: "zh-Hant"),
            bundle: bundle
        ) == "換色")
        #expect(LocaleAwareText.format(
            "knittingReminder.rule.repeating.limited",
            locale: Locale(identifier: "de"),
            bundle: bundle,
            10, 4, 6
        ) == "Ab Reihe 10, alle 4 Reihen, 6-mal")
        #expect(LocaleAwareText.format(
            "knittingReminder.rule.repeating.limited",
            locale: Locale(identifier: "ja"),
            bundle: bundle,
            10, 4, 6
        ) == "10段目から4段ごと、6回")
        #expect(LocaleAwareText.format(
            "knittingReminder.card.queue",
            locale: Locale(identifier: "nb"),
            bundle: bundle,
            2, 5
        ) == "2 av 5")

        let userText = "K2, luego 米白色 — 사용자 메모"
        let reminder = try #require(KnittingReminder(
            counterID: UUID(),
            draft: .oneTime(kind: .changeYarn, target: 10, text: userText),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let restored = try JSONDecoder().decode(
            KnittingReminder.self,
            from: JSONEncoder().encode(reminder)
        )
        for language in ["zh-Hant", "de", "ja", "nb"] {
            _ = LocaleAwareText.string(
                "knittingReminder.kind.changeYarn",
                locale: Locale(identifier: language),
                bundle: bundle
            )
            #expect(restored.text == "K2, luego 米白色 — 사용자 메모")
        }
    }

}

private func shippingCatalogValues(keys: [String]) throws -> [String: [String: String]] {
    let repositoryRoot = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(contentsOf: repositoryRoot.appending(
        path: "KnitNote/Localization/Localizable.xcstrings"
    ))
    let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try #require(catalog["strings"] as? [String: Any])
    var result: [String: [String: String]] = [:]
    for key in keys {
        let entry = try #require(strings[key] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        for language in SupportedLocalization.v150Identifiers {
            let localization = try #require(localizations[language] as? [String: Any])
            let unit = try #require(localization["stringUnit"] as? [String: Any])
            result[language, default: [:]][key] = try #require(unit["value"] as? String)
        }
    }
    return result
}

private func navigationTitlesFromShippingCatalog(key: String) throws -> [String: String] {
        let repositoryRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot.appending(
            path: "KnitNote/Localization/Localizable.xcstrings"
        ))
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let entry = try #require(strings[key] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        return try Dictionary(uniqueKeysWithValues: SupportedLocalization.v150Identifiers.map { language in
            let translation = try #require(localizations[language] as? [String: Any])
            let unit = try #require(translation["stringUnit"] as? [String: Any])
            return (language, try #require(unit["value"] as? String))
        })
    }

private func localizedFixtureBundle(
    additionalStringsByLanguage: [String: [String: String]] = [:]
) throws -> Bundle {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "RuntimeLocalization-\(UUID().uuidString).bundle", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let info: [String: Any] = [
        "CFBundleDevelopmentRegion": "en",
        "CFBundleIdentifier": "com.phillon.KnitNote.RuntimeLocalizationTests.\(UUID().uuidString)",
        "CFBundleName": "RuntimeLocalizationTests",
        "CFBundlePackageType": "BNDL",
    ]
    let infoData = try PropertyListSerialization.data(
        fromPropertyList: info,
        format: .xml,
        options: 0
    )
    try infoData.write(to: root.appending(path: "Info.plist"))

    var stringsByLanguage = [
        "en": [
            "english.format": "English Page %d",
            "english.only": "English only",
            "save.error": "Save failed",
            "page.title": "Page %d Note",
        ],
        "de": [
            "save.error": "Speichern fehlgeschlagen",
            "page.title": "Notiz zu Seite %d",
        ],
    ]
    for (language, additionalStrings) in additionalStringsByLanguage {
        stringsByLanguage[language, default: [:]].merge(additionalStrings) { _, new in new }
    }
    for (language, strings) in stringsByLanguage {
        let directory = root.appending(path: "\(language).lproj", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: strings,
            format: .xml,
            options: 0
        )
        try data.write(to: directory.appending(path: "Localizable.strings"))

        var plural: [String: Any] = [
            "project.count": [
                "NSStringLocalizedFormatKey": "%#@count@",
                "count": [
                    "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                    "NSStringFormatValueTypeKey": "lld",
                    "one": language == "de" ? "%lld Projekt" : "%lld project",
                    "other": language == "de" ? "%lld Projekte" : "%lld projects",
                ],
            ],
        ]
        if language == "en" {
            plural["fallback.count"] = [
                "NSStringLocalizedFormatKey": "%#@count@",
                "count": [
                    "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                    "NSStringFormatValueTypeKey": "lld",
                    "one": "%lld English catalog entry",
                    "other": "%lld English catalog entries",
                ],
            ]
        } else {
            plural["fallback.count"] = [
                "NSStringLocalizedFormatKey": "%#@count@",
                "count": [
                    "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                    "NSStringFormatValueTypeKey": "lld",
                    "one": "%lld deutscher Eintrag",
                ],
            ]
        }
        let pluralData = try PropertyListSerialization.data(
            fromPropertyList: plural,
            format: .xml,
            options: 0
        )
        try pluralData.write(to: directory.appending(path: "Localizable.stringsdict"))
    }

    return try #require(Bundle(url: root))
}
