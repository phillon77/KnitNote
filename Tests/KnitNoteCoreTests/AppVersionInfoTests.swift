import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct AppVersionInfoTests {
    @Test func parsesAndTrimsBothRequiredStrings() {
        let info = AppVersionInfo(infoDictionary: [
            "CFBundleShortVersionString": " 1.3.1 ",
            "CFBundleVersion": " 007 ",
        ])
        #expect(info == AppVersionInfo(version: "1.3.1", build: "007"))
    }

    @Test func rejectsIncompleteMalformedOrBlankMetadata() {
        let dictionaries: [[String: Any]] = [
            [:],
            ["CFBundleShortVersionString": "1.3.1"],
            ["CFBundleVersion": "7"],
            ["CFBundleShortVersionString": "", "CFBundleVersion": "7"],
            ["CFBundleShortVersionString": "1.3.1", "CFBundleVersion": "   "],
            ["CFBundleShortVersionString": 131, "CFBundleVersion": "7"],
            ["CFBundleShortVersionString": "1.3.1", "CFBundleVersion": 7],
        ]

        for dictionary in dictionaries {
            #expect(AppVersionInfo(infoDictionary: dictionary) == nil)
        }
    }

    @Test func preservesNonNumericComponents() {
        let info = AppVersionInfo(infoDictionary: [
            "CFBundleShortVersionString": "1.3.1-beta",
            "CFBundleVersion": "7A",
        ])
        #expect(info?.version == "1.3.1-beta")
        #expect(info?.build == "7A")
    }

    @Test func displayFormatterFollowsTheSuppliedRuntimeLocaleUsingRealBundleLocalizations() throws {
        let fixture = try LocalizedVersionFixtureBundle()
        defer { fixture.remove() }
        let info = try #require(AppVersionInfo(infoDictionary: [
            "CFBundleShortVersionString": " 1.3.1 ",
            "CFBundleVersion": " 7 ",
        ]))

        #expect(
            AppVersionDisplayFormatter.string(
                for: info,
                bundle: fixture.bundle,
                locale: Locale(identifier: "zh-Hant-TW")
            ) == "1.3.1（Build 7）"
        )
        #expect(
            AppVersionDisplayFormatter.string(
                for: info,
                bundle: fixture.bundle,
                locale: Locale(identifier: "en-US")
            ) == "1.3.1 (Build 7)"
        )
    }

    @Test func displayFormatterPreservesMissingMetadataFallback() throws {
        let fixture = try LocalizedVersionFixtureBundle()
        defer { fixture.remove() }

        #expect(
            AppVersionDisplayFormatter.string(
                for: nil,
                bundle: fixture.bundle,
                locale: Locale(identifier: "en-US")
            ) == "—"
        )
        #expect(
            AppVersionDisplayFormatter.string(
                for: AppVersionInfo(version: "   ", build: "7"),
                bundle: fixture.bundle,
                locale: Locale(identifier: "en-US")
            ) == "—"
        )
    }
}

private struct LocalizedVersionFixtureBundle {
    let url: URL
    let bundle: Bundle

    init() throws {
        let manager = FileManager.default
        url = manager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathExtension("bundle")
        try manager.createDirectory(at: url, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleIdentifier": "com.phillon.KnitNote.VersionFixture.\(UUID().uuidString)",
            "CFBundleDevelopmentRegion": "en",
            "CFBundleLocalizations": ["en", "zh-Hant"],
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: url.appendingPathComponent("Info.plist"))

        try Self.writeLocalization(
            language: "en",
            value: "%1$@ (Build %2$@)",
            under: url
        )
        try Self.writeLocalization(
            language: "zh-Hant",
            value: "%1$@（Build %2$@）",
            under: url
        )

        bundle = try #require(Bundle(url: url))
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    private static func writeLocalization(
        language: String,
        value: String,
        under root: URL
    ) throws {
        let directory = root.appendingPathComponent("\(language).lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        try "\"settings.version.format\" = \"\(escaped)\";\n".write(
            to: directory.appendingPathComponent("Localizable.strings"),
            atomically: true,
            encoding: .utf8
        )
    }
}
