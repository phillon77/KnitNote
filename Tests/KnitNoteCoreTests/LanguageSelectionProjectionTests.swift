import Foundation
import Testing
@testable import KnitNoteCore

@Suite(.serialized) struct LanguageSelectionProjectionTests {
    @Test func explicitSelectionStoresOnlyItsRawValueAndOverridesShareSystemLanguage() throws {
        try withProjectionDefaults { defaults in
            let projection = LanguageSelectionProjection(defaults: defaults)

            projection.write(.japanese)

            #expect(
                defaults.object(forKey: LanguageSelectionProjection.selectionKey) as? String
                    == LanguageSelection.japanese.rawValue
            )
            let locale = projection.resolvedLocale(
                systemLanguages: ["en-US"],
                regionLocale: Locale(identifier: "en_US")
            )
            #expect(locale.language.languageCode?.identifier == "ja")
            #expect(locale.region?.identifier == "US")
        }
    }

    @Test func systemSelectionUsesTheShareProcessSystemLanguage() throws {
        try withProjectionDefaults { defaults in
            let projection = LanguageSelectionProjection(defaults: defaults)
            projection.write(.system)

            let locale = projection.resolvedLocale(
                systemLanguages: ["fr-CA"],
                regionLocale: Locale(identifier: "en_CA")
            )

            #expect(projection.readSelection() == .system)
            #expect(locale.language.languageCode?.identifier == "fr")
            #expect(locale.region?.identifier == "CA")
        }
    }

    @Test(arguments: [nil, "", "retired-language"])
    func missingOrInvalidProjectionUsesTheShareProcessSystemLanguage(
        rawValue: String?
    ) throws {
        try withProjectionDefaults { defaults in
            if let rawValue {
                defaults.set(rawValue, forKey: LanguageSelectionProjection.selectionKey)
            }
            let projection = LanguageSelectionProjection(defaults: defaults)

            let locale = projection.resolvedLocale(
                systemLanguages: ["zh-Hant-HK"],
                regionLocale: Locale(identifier: "en_HK")
            )

            #expect(projection.readSelection() == .system)
            #expect(locale.language.languageCode?.identifier == "zh")
            #expect(locale.language.script?.identifier == "Hant")
            #expect(locale.region?.identifier == "HK")
        }
    }

    @Test func projectionUsesTheProductionGroupGrantedToAppAndShare() throws {
        for path in [
            "KnitNote/KnitNote-iOS.entitlements",
            "KnitNoteShare/KnitNoteShare.entitlements",
        ] {
            let data = try Data(contentsOf: languageProjectionRepositoryRoot.appending(path: path))
            let plist = try #require(
                PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any]
            )
            let groups = try #require(
                plist["com.apple.security.application-groups"] as? [String]
            )
            #expect(groups == [LanguageSelectionProjection.appGroupIdentifier])
        }
    }

    @Test func shareTargetCompilesTheSharedLanguageProjectionAndResolver() throws {
        let project = try parsedProjectSpecification()
        let targets = try #require(project["targets"] as? [String: Any])
        let share = try #require(targets["KnitNoteShare"] as? [String: Any])
        let sources = try #require(share["sources"] as? [[String: Any]])
        let paths = Set(sources.compactMap { $0["path"] as? String })

        #expect(paths.isSuperset(of: [
            "Sources/KnitNoteCore/Localization/AppLanguage.swift",
            "Sources/KnitNoteCore/Localization/LanguageSettings.swift",
            "Sources/KnitNoteCore/Localization/LanguageSelectionProjection.swift",
        ]))
    }

    @Test func mainAppProjectsAtLaunchAndOnEveryStoredSelectionChange() throws {
        let source = try repositorySource("KnitNote/App/KnitNoteApp.swift")
        let initializer = try #require(
            sourceSection(source, from: "    init() {", to: "    private var selection:")
        )
        let changeHandler = try #require(
            sourceSection(
                source,
                from: ".onChange(of: storedLanguage)",
                to: ".knitNoteMacMinimumWindowContentSize()"
            )
        )

        #expect(initializer.contains("LanguageSelectionProjection.live()"))
        #expect(initializer.contains("languageSelectionProjection?.write("))
        #expect(changeHandler.contains("languageSelectionProjection?.write("))
        #expect(changeHandler.contains("LanguageSelection(rawValue: newValue) ?? .system"))
    }

    @Test func shareLaunchInjectsTheProjectedLocaleIntoItsSwiftUIView() throws {
        let source = try repositorySource("KnitNoteShare/ShareViewController.swift")
        let viewDidLoad = try #require(
            sourceSection(
                source,
                from: "    override func viewDidLoad() {",
                to: "    override func viewDidAppear"
            )
        )

        #expect(viewDidLoad.contains("LanguageSelectionProjection.live()"))
        #expect(viewDidLoad.contains(".resolvedLocale()"))
        #expect(viewDidLoad.contains(".environment(\\.locale, locale)"))
    }
}

private func withProjectionDefaults(
    _ body: (UserDefaults) throws -> Void
) throws {
    let suiteName = "LanguageSelectionProjectionTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try body(defaults)
}

private func parsedProjectSpecification() throws -> [String: Any] {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/env")
    process.arguments = ["xcodegen", "dump", "--type", "parsed-json"]
    process.currentDirectoryURL = languageProjectionRepositoryRoot
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors

    try process.run()
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw LanguageSelectionProjectionTestError.commandFailed(
            String(data: errorData + outputData, encoding: .utf8) ?? ""
        )
    }
    return try #require(
        JSONSerialization.jsonObject(with: outputData) as? [String: Any]
    )
}

private func repositorySource(_ path: String) throws -> String {
    try String(
        contentsOf: languageProjectionRepositoryRoot.appending(path: path),
        encoding: .utf8
    )
}

private func sourceSection(
    _ source: String,
    from start: String,
    to end: String
) -> Substring? {
    guard let startRange = source.range(of: start),
          let endRange = source.range(
              of: end,
              range: startRange.upperBound..<source.endIndex
          ) else {
        return nil
    }
    return source[startRange.lowerBound..<endRange.lowerBound]
}

private enum LanguageSelectionProjectionTestError: Error {
    case commandFailed(String)
}

private let languageProjectionRepositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
