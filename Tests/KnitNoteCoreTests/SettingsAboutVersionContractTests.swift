import Foundation
import Testing

@Suite struct SettingsAboutVersionContractTests {
    @Test func settingsEndsWithAStaticInjectedVersionRow() throws {
        let source = try appSource("KnitNote/Settings/SettingsView.swift")
        #expect(source.contains("let versionInfo: AppVersionInfo?"))
        #expect(source.contains("versionInfo: AppVersionInfo? = AppVersionInfo.current()"))
        #expect(source.contains("Section(\"settings.about\")"))
        #expect(source.contains("Text(\"settings.version\")"))
        #expect(source.contains("BackupSettingsSection()"))
        #expect(source.range(of: "BackupSettingsSection()")!.lowerBound < source.range(of: "Section(\"settings.about\")")!.lowerBound)
        #expect(!source.contains("NavigationLink(value: versionInfo"))
        #expect(!source.contains("Button(\"settings.version\""))
    }

    @Test func settingsDoesNotHardcodeThePlannedReleaseNumbers() throws {
        let source = try appSource("KnitNote/Settings/SettingsView.swift")
        #expect(!source.contains("1.3.1"))
        #expect(!source.contains("Build 7"))
        #expect(!source.contains("MARKETING_VERSION"))
    }

    @Test func settingsUsesTheRuntimeTestedFormatterWithTheAppSelectedLocale() throws {
        let source = try appSource("KnitNote/Settings/SettingsView.swift")

        #expect(source.contains("@Environment(\\.locale) private var locale"))
        #expect(source.contains("AppVersionDisplayFormatter.string("))
        #expect(source.contains("bundle: .main,"))
        #expect(source.contains("locale: locale"))
        #expect(!source.contains("String(localized: \"settings.version.format\""))
        #expect(!source.contains("Locale.current"))
    }

    @Test func installedVersionParserStaysOutOfTheWatchTarget() throws {
        let specification = try appSource("project.yml")
        let watchTarget = try #require(
            specification.range(of: "  KnitNoteWatch:")
                .flatMap { start in
                    specification.range(
                        of: "  KnitNoteShare:",
                        range: start.upperBound..<specification.endIndex
                    ).map { specification[start.lowerBound..<$0.lowerBound] }
                }
        )

        #expect(watchTarget.contains("- App/AppVersionInfo.swift"))
    }
}

private func appSource(_ relativePath: String) throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: repositoryRoot.appendingPathComponent(relativePath),
        encoding: .utf8
    )
}
