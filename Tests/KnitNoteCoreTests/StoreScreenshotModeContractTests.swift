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

        #expect(source.contains("StoreScreenshotMode.resolve()"))
        #expect(source.contains("preconditionFailure"))
        #expect(source.contains("refusing to open the live store"))
        #expect(source.contains("if screenshotMode == nil"))
        #expect(source.contains("StoreScreenshotRootView"))
        #expect(source.contains("return LanguageSettings(selection: selection).resolvedLocale()"))
    }

    @Test func watchAppHasAnIsolatedDebugOnlyScreenshotRoute() throws {
        let appSource = try sourceText("KnitNoteWatch/KnitNoteWatchApp.swift")
        let modeSource = try sourceText("KnitNoteWatch/WatchStoreScreenshotMode.swift")

        #expect(modeSource.contains("#if DEBUG"))
        #expect(modeSource.contains("-storeScreenshotMode"))
        #expect(modeSource.contains("watchProjects"))
        #expect(modeSource.contains("watchCounters"))
        #expect(appSource.contains("WatchStoreScreenshotMode.resolve()"))
        #expect(appSource.contains("if let screenshotMode"))
        #expect(appSource.contains("watchSyncCoordinator.start()"))
        #expect(appSource.contains("refusing to open the live cache"))
        #expect(modeSource.contains("WatchStoreScreenshotHost"))
        #expect(modeSource.contains("WatchCounterView("))
        #expect(!modeSource.contains("private var projectList"))
    }

    @Test func screenshotRootCoversEveryApprovedScene() throws {
        let source = try sourceText("KnitNote/App/StoreScreenshotRootView.swift")

        for scene in [
            ".projects",
            ".counters",
            ".patternHighlight",
            ".patternCrossHighlight",
            ".patternMarkup",
            ".patternNotes",
            ".journal",
            ".yarn",
            ".calculators",
        ] {
            #expect(source.contains("case \(scene)"))
        }
    }

    @Test func patternScenesOpenTheirPromisedPresentation() throws {
        let root = try sourceText("KnitNote/App/StoreScreenshotRootView.swift")
        let reader = try sourceText("KnitNote/Patterns/PatternReaderView.swift")

        #expect(root.contains("patternScene(presentation: .crossHighlight)"))
        #expect(root.contains("patternScene(presentation: .markup)"))
        #expect(root.contains("patternScene(presentation: .notes)"))
        #expect(reader.contains("_markupMode = State(initialValue: storePresentation == .markup)"))
        #expect(reader.contains("_showingPageNote = State(initialValue: storePresentation == .notes)"))
    }

    @Test func captureScriptRefusesPersonalDevicesAndStaleScenes() throws {
        let script = try sourceText("AppStore/Screenshots/capture.sh")

        #expect(script.contains("name.startswith(\"KnitNote Store\")"))
        #expect(script.contains("xcrun simctl erase"))
        #expect(script.contains("-storeScreenshotToken"))
        #expect(script.contains("eventMessage CONTAINS '$token'"))
        #expect(script.contains("verify_dimensions"))
        #expect(script.contains("AppleLanguages"))
        #expect(!script.contains("--wifiBars 3 --cellularBars 4 >/dev/null"))
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
