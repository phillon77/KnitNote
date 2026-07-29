import Foundation
import Testing

@Suite struct PatternInboxAppContractTests {
    @Test func rootProcessesTheInboxAtLaunchAndWheneverTheSceneBecomesActive() throws {
        let app = try readRepositoryFile("KnitNote/App/KnitNoteApp.swift")
        let root = try readRepositoryFile("KnitNote/App/RootView.swift")

        #expect(app.contains(".environmentObject(patternInboxProcessor)"))
        #expect(root.contains("@Environment(\\.scenePhase)"))
        #expect(root.contains(".task(id: scenePhase)"))
        #expect(root.contains("patternInboxProcessor.processPending()"))
        #expect(root.contains("scenePhase == .active"))
        #expect(root.contains("await entitlementCoordinator.ensurePrepared()"))
    }

    @Test func processorUsesTheActorDriverAndKeepsSelectionAndFailureVisible() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/PatternInboxProcessor.swift")

        #expect(source.contains("PatternInboxDriver"))
        #expect(source.contains("@Published private(set) var pendingSelection"))
        #expect(source.contains("@Published private(set) var failure"))
        #expect(source.contains("func resolve"))
        #expect(source.contains("func retry"))
        #expect(source.contains("func discard"))
        #expect(source.contains("catch is CancellationError"))
    }

    @Test func ambiguousDuplicateOffersExistingCollectionsOrOneNewCollection() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/PendingPatternSelectionView.swift")

        #expect(source.contains("candidatePatternIDs"))
        #expect(source.contains("patterns.inbox.choose.title"))
        #expect(source.contains("patterns.inbox.createNew"))
        #expect(source.contains("resolution: .existing(patternID)"))
        #expect(source.contains("resolution: .createNew"))
        #expect(source.contains(".interactiveDismissDisabled()"))
        #expect(source.contains(".accessibilityLabel"))
    }

    @Test func failureHasReadableRetryAndDiscardActionsAndNoticeIsNonNavigating() throws {
        let root = try readRepositoryFile("KnitNote/App/RootView.swift")
        let processor = try readRepositoryFile("KnitNote/Patterns/PatternInboxProcessor.swift")

        #expect(root.contains("patterns.inbox.error.title"))
        #expect(root.contains("patterns.inbox.error.message"))
        #expect(root.contains("patterns.inbox.retry"))
        #expect(root.contains("patterns.inbox.discard"))
        #expect(root.contains("patterns.inbox.later"))
        #expect(root.contains("patternInboxProcessor.dismissFailure()"))
        #expect(root.contains("patternInboxProcessor.failure?.itemID"))
        #expect(root.contains("PatternInboxNoticeView"))
        #expect(root.contains(".overlay(alignment: .top)"))
        #expect(processor.contains("func dismissFailure()"))
        #expect(processor.contains("failure = nil"))
    }

    @Test func allInboxCopyIsTranslatedInEnglishAndTraditionalChinese() throws {
        let data = try Data(contentsOf: patternLibraryRepositoryURL(
            "KnitNote/Localization/Localizable.xcstrings"
        ))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        let keys = [
            "patterns.inbox.choose.title",
            "patterns.inbox.choose.message",
            "patterns.inbox.createNew",
            "patterns.inbox.imported",
            "patterns.inbox.error.title",
            "patterns.inbox.error.message",
            "patterns.inbox.retry",
            "patterns.inbox.discard",
            "patterns.inbox.later",
        ]

        for key in keys {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for language in ["en", "zh-Hant"] {
                let localization = try #require(localizations[language] as? [String: Any])
                let unit = try #require(localization["stringUnit"] as? [String: Any])
                #expect((unit["value"] as? String)?.isEmpty == false)
            }
        }
    }
}
