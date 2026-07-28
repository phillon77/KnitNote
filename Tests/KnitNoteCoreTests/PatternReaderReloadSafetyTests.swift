import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct PatternReaderReloadSafetyTests {
    @MainActor @Test func loaderSelectsOnlyTheExactUsageStateFromTheStoreSnapshot() throws {
        let harness = try PatternLibraryStoreHarness.onePatternAndTwoProjects()
        let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
        let distractor = try harness.store.linkPattern(patternID: harness.patternID, to: harness.secondProjectID!)
        let wanted = PatternReadingState(pageIndex: 6, zoomScale: 2.4, offsetX: 0.3, offsetY: 0.7)
        let context = PatternReaderContext.project(
            patternID: harness.patternID,
            usageID: usage.id,
            projectID: harness.projectID,
            projectIsCompleted: false
        )
        _ = try harness.store.updatePatternState(
            usageID: usage.id,
            state: wanted,
            expectedDataGeneration: harness.store.dataGeneration
        )
        _ = try harness.store.updatePatternState(
            usageID: distractor.id,
            state: PatternReadingState(pageIndex: 1, zoomScale: 1.2),
            expectedDataGeneration: harness.store.dataGeneration
        )

        #expect(PatternReaderStateLoader.readingState(
            for: context,
            usages: harness.store.patternUsages
        ) == wanted)
    }

    @Test func loaderProjectsTargetPageExplicitFieldsWithoutMutatingStoredUsage() {
        let patternID = UUID()
        let projectID = UUID()
        let usageID = UUID()
        let stored = PatternReadingState(
            pageIndex: 2,
            zoomScale: 2.2,
            offsetX: 0.3,
            offsetY: 0.7,
            highlightEnabled: true,
            highlightPosition: 0.21,
            highlightMode: .cross,
            verticalHighlightPosition: 0.79,
            pageNote: "Stored top-level page",
            pageStates: [
                2: PatternPageState(
                    horizontalPosition: 0.42,
                    verticalPosition: 0.64,
                    note: "Displayed target page"
                ),
            ]
        )
        let usage = PatternProjectUsage(
            id: usageID,
            patternID: patternID,
            projectID: projectID,
            sortOrder: 0,
            readingState: stored
        )
        let context = PatternReaderContext.project(
            patternID: patternID,
            usageID: usageID,
            projectID: projectID,
            projectIsCompleted: false
        )

        let loaded = PatternReaderStateLoader.readingState(
            for: context,
            usages: [usage]
        )

        #expect(loaded.highlightPosition == 0.42)
        #expect(loaded.verticalHighlightPosition == 0.64)
        #expect(loaded.pageNote == "Displayed target page")
        #expect(usage.readingState == stored)
    }

    @Test func staleHydrationGenerationCannotApplyAfterContextReset() {
        let first = writableContext()
        let second = PatternReaderContext.project(
            patternID: UUID(), usageID: UUID(), projectID: UUID(), projectIsCompleted: false
        )
        var session = PatternReaderSession(context: first)
        let firstGeneration = session.beginLoading(context: first, identity: .init(context: first, assetID: UUID()))
        let secondGeneration = session.beginLoading(context: second, identity: .init(context: second, assetID: UUID()))

        let staleAccepted = session.hydrate(PatternReadingState(pageIndex: 8), for: firstGeneration)
        #expect(!staleAccepted)
        #expect(session.phase == .loading)
        let currentAccepted = session.hydrate(PatternReadingState(pageIndex: 2), for: secondGeneration)
        #expect(currentAccepted)
        #expect(session.readingState?.pageIndex == 2)
        #expect(session.context == second)
    }

    @Test func identityChangesForAssetUsageAndCompletionChanges() {
        let context = writableContext()
        let assetID = UUID()
        let baseline = PatternReaderContextIdentity(context: context, assetID: assetID)
        let completed = PatternReaderContextIdentity(
            context: .project(
                patternID: context.patternID,
                usageID: context.usageID!,
                projectID: context.projectID!,
                projectIsCompleted: true
            ),
            assetID: assetID
        )
        let replacementAsset = PatternReaderContextIdentity(context: context, assetID: UUID())
        let inactive = PatternReaderContextIdentity(
            context: .project(
                patternID: context.patternID,
                usageID: context.usageID!,
                projectID: context.projectID!,
                usageIsActive: false,
                projectIsCompleted: false
            ),
            assetID: assetID
        )

        #expect(baseline != completed)
        #expect(baseline != replacementAsset)
        #expect(baseline != inactive)
    }

    private func writableContext() -> PatternReaderContext {
        .project(patternID: UUID(), usageID: UUID(), projectID: UUID(), projectIsCompleted: false)
    }
}
