import Foundation
import Testing

@Suite struct StoreScreenshotModeContractTests {
    @Test func screenshotModeIsDebugOnlyAndUsesAnIsolatedTemporaryStore() throws {
        let source = try sourceText("KnitNote/App/StoreScreenshotMode.swift")

        #expect(source.contains("#if DEBUG"))
        #expect(source.contains("-storeScreenshotMode"))
        #expect(source.contains("StoreScreenshotFixtures.make"))
        #expect(source.contains("FileManager.default.temporaryDirectory"))
        #expect(!source.contains("applicationSupportDirectory"))
    }

    @Test func productionAppDoesNotStartWatchSyncForSyntheticScreenshotData() throws {
        let source = try sourceText("KnitNote/App/KnitNoteApp.swift")

        #expect(source.contains("StoreScreenshotMode.current()"))
        #expect(source.contains("if screenshotMode == nil"))
        #expect(source.contains("StoreScreenshotRootView"))
        #expect(source.contains("return LanguageSettings(selection: selection).resolvedLocale()"))
    }

    @Test func screenshotRootCoversEveryApprovedScene() throws {
        let source = try sourceText("KnitNote/App/StoreScreenshotRootView.swift")

        for scene in [
            ".projects",
            ".counters",
            ".patternHighlight",
            ".patternMarkup",
            ".patternNotes",
            ".journal",
            ".yarn",
            ".calculators",
        ] {
            #expect(source.contains("case \(scene)"))
        }
    }
}

private func sourceText(_ relativePath: String) throws -> String {
    try String(
        contentsOf: storeScreenshotRepositoryRoot.appending(path: relativePath),
        encoding: .utf8
    )
}

private let storeScreenshotRepositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
