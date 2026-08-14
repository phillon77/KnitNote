import Foundation
import Testing

@Suite struct AppUpdateFixtureContractTests {
    @Test func fixtureIsDebugOnlyStrictAndDeterministic() throws {
        let source = try updateFixtureSource("KnitNote/App/AppUpdateFixture.swift")

        #expect(source.contains("#if DEBUG"))
        #expect(source.contains("#else\n        return .invalid"))
        #expect(source.contains("argumentValue(after: \"-appUpdateFixture\", in: arguments) == \"YES\""))
        #expect(source.contains("after: \"-appUpdateFixtureVersion\""))
        #expect(source.contains("AppVersion(rawVersion)"))
        #expect(source.contains("https://apps.apple.com/tw/app/id6793023054"))
        #expect(source.contains("!arguments.contains(\"-storeScreenshotMode\")"))
        #expect(source.contains("arguments.occurrences(of: \"-appUpdateFixture\") == 1"))
        #expect(source.contains("arguments.occurrences(of: \"-appUpdateFixtureVersion\") == 1"))
        #expect(!source.contains("environment["))
        #expect(!source.contains("environmentVariable"))
    }

    @Test func productionAppResolvesFixtureAfterScreenshotModeAndOnlyInjectsItIntoNormalRoot() throws {
        let source = try updateFixtureSource("KnitNote/App/KnitNoteApp.swift")
        let screenshotResolution = try #require(source.range(of: "StoreScreenshotMode.resolve()"))
        let fixtureResolution = try #require(source.range(of: "AppUpdateFixture.resolve("))

        #expect(screenshotResolution.lowerBound < fixtureResolution.lowerBound)
        #expect(source.contains("preconditionFailure(\"App update fixture is invalid or overlaps screenshot mode\")"))
        #expect(source.contains("if screenshotMode == nil"))
        #expect(source.contains("AppUpdateReminderLiveFactory.make(fixture: appUpdateFixture)"))
        #expect(source.contains("RootView(storedLanguage: $storedLanguage)\n                        .environmentObject(appUpdateReminderCoordinator)"))
        #expect(!source.contains("ProcessInfo.processInfo.environment"))
    }

    @Test func liveFactoryUsesStorefrontImmediatelyBeforeLookupAndFixtureNeverCallsIt() throws {
        let source = try updateFixtureSource("KnitNote/App/AppUpdateReminderLiveFactory.swift")

        #expect(source.contains("import StoreKit"))
        #expect(source.contains("let storefrontCode = await Storefront.current?.countryCode"))
        #expect(source.contains("Locale(identifier: \"en_\\($0)\").region?.identifier"))
        #expect(source.contains("AppStoreUpdateLookup.normalizedCountryCode(alpha2)"))
        #expect(source.contains("AppStoreUpdateLookup.normalizedCountryCode(Locale.current.region?.identifier)"))
        #expect(source.contains("?? \"tw\""))
        #expect(source.contains("if let fixture"))
        #expect(source.contains("return fixture.availableUpdate"))
        #expect(source.contains("return await lookup.fetch(countryCode: countryCode, platform: platform)"))
    }
}

private func updateFixtureSource(_ relativePath: String) throws -> String {
    try String(contentsOf: updateFixtureRepositoryRoot.appending(path: relativePath), encoding: .utf8)
}

private let updateFixtureRepositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
