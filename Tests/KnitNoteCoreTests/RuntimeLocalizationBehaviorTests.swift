import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct RuntimeLocalizationBehaviorTests {
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
}

private func localizedFixtureBundle() throws -> Bundle {
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

    let stringsByLanguage = [
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
