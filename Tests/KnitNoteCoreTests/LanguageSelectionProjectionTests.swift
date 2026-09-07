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

    @Test func mainAppLazilyProjectsAtLaunchAndOnEveryStoredSelectionChange() throws {
        let source = try repositorySource("KnitNote/App/KnitNoteApp.swift")
        let initializer = try languageProjectionFunction(
            signature: "    init()",
            in: source
        )
        let localFactory = try languageProjectionClosure(
            after: "makeLocal:",
            in: initializer
        )
        let changeHandler = try #require(
            sourceSection(
                source,
                from: ".onChange(of: storedLanguage)",
                to: ".knitNoteMacMinimumWindowContentSize()"
            )
        )

        #expect(localFactory.contains("languageProjection = LanguageSelectionProjection.live()"))
        #expect(localFactory.contains(
            "let initialLanguage = UserDefaults.standard.string(forKey: \"languageSelection\")"
        ))
        #expect(localFactory.contains("languageProjection?.write(initialLanguage)"))
        #expect(localFactory.contains("languageSelectionProjection: languageProjection"))
        #expect(
            initializer.components(separatedBy: "LanguageSelectionProjection.live()").count == 2
        )
        #expect(
            localFactory.components(separatedBy: "LanguageSelectionProjection.live()").count == 2
        )
        #expect(changeHandler.contains("languageSelectionProjection?.write("))
        #expect(changeHandler.contains("LanguageSelection(rawValue: newValue) ?? .system"))
    }

    @Test func screenshotLaunchReturnsBeforeTheOnlyLocalProjectionFactoryCall() throws {
        let source = try repositorySource("KnitNote/App/AppSessionComposition.swift")
        let makeLaunch = try languageProjectionFunction(
            signature: "    static func makeLaunch(",
            in: source
        )
        let screenshotStart = try #require(makeLaunch.range(
            of: "if let screenshotBaseDirectory"
        ))
        let screenshotReturn = try #require(makeLaunch.range(
            of: "return AppSessionLaunchResources("
        ))
        let localFactoryCall = try #require(makeLaunch.range(
            of: "let local = try makeLocal()"
        ))
        let screenshotRoute = makeLaunch[
            screenshotStart.lowerBound..<localFactoryCall.lowerBound
        ]

        #expect(screenshotStart.lowerBound < screenshotReturn.lowerBound)
        #expect(screenshotReturn.lowerBound < localFactoryCall.lowerBound)
        #expect(makeLaunch.components(separatedBy: "try makeLocal()").count == 2)
        #expect(screenshotRoute.contains("languageSelectionProjection: nil"))
        #expect(screenshotRoute.contains("makeWatch: { _ in nil }"))
        #expect(!screenshotRoute.contains("LanguageSelectionProjection.live()"))
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

private func languageProjectionFunction(signature: String, in source: String) throws -> String {
    let signatures = source.components(separatedBy: signature)
    guard signatures.count == 2,
          let start = source.range(of: signature)?.lowerBound,
          let openingBrace = source[start...].firstIndex(of: "{") else {
        throw LanguageSelectionProjectionTestError.missingUniqueOwner
    }
    return try languageProjectionBracedBlock(from: start, openingBrace: openingBrace, in: source)
}

private func languageProjectionClosure(after marker: String, in source: String) throws -> String {
    let markers = source.components(separatedBy: marker)
    guard markers.count == 2,
          let markerRange = source.range(of: marker),
          let openingBrace = source[markerRange.upperBound...].firstIndex(of: "{") else {
        throw LanguageSelectionProjectionTestError.missingUniqueOwner
    }
    return try languageProjectionBracedBlock(
        from: markerRange.lowerBound,
        openingBrace: openingBrace,
        in: source
    )
}

private func languageProjectionBracedBlock(
    from start: String.Index,
    openingBrace: String.Index,
    in source: String
) throws -> String {
    var depth = 0
    var cursor = openingBrace
    while cursor < source.endIndex {
        switch source[cursor] {
        case "{":
            depth += 1
        case "}":
            depth -= 1
            if depth == 0 {
                return String(source[start...cursor])
            }
        default:
            break
        }
        cursor = source.index(after: cursor)
    }
    throw LanguageSelectionProjectionTestError.missingUniqueOwner
}

private enum LanguageSelectionProjectionTestError: Error {
    case commandFailed(String)
    case missingUniqueOwner
}

private let languageProjectionRepositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
