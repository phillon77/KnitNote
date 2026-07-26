import Foundation
import Testing
@testable import KnitNoteCore

@MainActor @Test func unlinkAndRelinkRestoreTheSameUsage() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()

    let original = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let duplicate = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    try harness.store.updatePatternState(
        usageID: original.id,
        state: PatternReadingState(pageIndex: 3, highlightPosition: 0.7)
    )
    try harness.store.unlinkPattern(patternID: harness.patternID, from: harness.projectID)

    let restored = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)

    #expect(restored.id == original.id)
    #expect(duplicate.id == original.id)
    #expect(harness.store.patternUsages.count == 1)
    #expect(restored.isActive)
    #expect(restored.readingState.pageIndex == 3)
    #expect(restored.readingState.highlightPosition == 0.7)
}

@MainActor @Test func relinkedUsageSurvivesFreshStoreReloadWithItsStateNotesAndMarkup() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let markup = PatternMarkupDocument(strokes: [.init(
        points: [.init(x: 0.2, y: 0.3)], color: .blue, width: 0.009
    )])
    try harness.store.updatePatternState(usageID: usage.id, state: PatternReadingState(pageIndex: 4))
    try harness.store.savePatternPageNote(usageID: usage.id, pageIndex: 4, text: "reload note")
    try harness.store.savePatternMarkup(
        markup,
        usageID: usage.id,
        pageIndex: 4,
        expectedDataGeneration: harness.store.dataGeneration
    )
    try harness.store.unlinkPattern(patternID: harness.patternID, from: harness.projectID)
    let relinked = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)

    let reopened = try harness.reopenedStore()

    #expect(reopened.patternUsages == [relinked])
    #expect(try reopened.loadPatternMarkup(usageID: usage.id, pageIndex: 4) == markup)
}

@MainActor @Test func inactiveUsageRejectsEveryReaderWrite() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    try harness.store.unlinkPattern(patternID: harness.patternID, from: harness.projectID)

    #expect(throws: PatternLibraryMutationError.usageInactive) {
        try harness.store.updatePatternState(usageID: usage.id, state: PatternReadingState(pageIndex: 1))
    }
    #expect(throws: PatternLibraryMutationError.usageInactive) {
        try harness.store.savePatternPageNote(usageID: usage.id, pageIndex: 1, text: "blocked")
    }
    #expect(throws: PatternLibraryMutationError.usageInactive) {
        try harness.store.savePatternMarkup(
            PatternMarkupDocument(),
            usageID: usage.id,
            pageIndex: 1,
            expectedDataGeneration: harness.store.dataGeneration
        )
    }
}

@MainActor @Test func readerUsageMutationSequenceAdvancesGenerationWithoutSelfStaling() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let counterID = try #require(harness.store.project(id: harness.projectID)?.counters.first?.id)
    var expected = harness.store.dataGeneration

    expected = try harness.store.mutatePatternReaderCounter(
        usageID: usage.id,
        counterID: counterID,
        mutation: .increment,
        expectedDataGeneration: expected
    )
    expected = try harness.store.mutatePatternReaderCounter(
        usageID: usage.id,
        counterID: counterID,
        mutation: .update(name: "Reader counter", value: 4),
        expectedDataGeneration: expected
    )
    expected = try harness.store.mutatePatternReaderCounter(
        usageID: usage.id,
        counterID: counterID,
        mutation: .reset,
        expectedDataGeneration: expected
    )
    expected = try harness.store.updatePatternState(
        usageID: usage.id,
        state: PatternReadingState(pageIndex: 5, zoomScale: 2.2, offsetX: 0.25, offsetY: 0.75),
        expectedDataGeneration: expected
    )
    expected = try harness.store.savePatternPageNote(
        usageID: usage.id,
        pageIndex: 5,
        text: "reader sequence",
        expectedDataGeneration: expected
    )
    let markup = harness.drawing(x: 0.42)
    expected = try harness.store.savePatternMarkup(
        markup,
        usageID: usage.id,
        pageIndex: 5,
        expectedDataGeneration: expected
    )
    _ = try harness.store.savePatternMarkup(
        markup,
        usageID: usage.id,
        pageIndex: 5,
        expectedDataGeneration: expected
    )

    let reopened = try harness.reopenedStore()
    #expect(reopened.project(id: harness.projectID)?.counters.first?.value == 0)
    #expect(reopened.project(id: harness.projectID)?.counters.first?.customName == "Reader counter")
    #expect(reopened.patternUsages.first(where: { $0.id == usage.id })?.readingState.pageIndex == 5)
    #expect(reopened.patternUsages.first(where: { $0.id == usage.id })?.readingState.pageStates[5]?.note == "reader sequence")
    #expect(try reopened.loadPatternMarkup(usageID: usage.id, pageIndex: 5) == markup)
}

@MainActor @Test func readerUsageMutationKeepsExternalOptimisticConcurrencyRejection() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let staleGeneration = harness.store.dataGeneration
    let counterID = try #require(harness.store.project(id: harness.projectID)?.counters.first?.id)
    _ = try harness.store.mutatePatternReaderCounter(
        usageID: usage.id,
        counterID: counterID,
        mutation: .increment,
        expectedDataGeneration: staleGeneration
    )
    let confirmedGeneration = harness.store.dataGeneration

    #expect(throws: ProjectStoreError.staleDataGeneration) {
        try harness.store.updatePatternState(
            usageID: usage.id,
            state: PatternReadingState(pageIndex: 2),
            expectedDataGeneration: staleGeneration
        )
    }
    #expect(harness.store.dataGeneration == confirmedGeneration)
}

@MainActor @Test func inactiveUsageRejectsReaderCounterMutationAndRelinkRestoresReaderWrites() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let counterID = try #require(harness.store.project(id: harness.projectID)?.counters.first?.id)
    let state = PatternReadingState(pageIndex: 3)
    let markup = harness.drawing(x: 0.61)
    var expected = try harness.store.updatePatternState(
        usageID: usage.id,
        state: state,
        expectedDataGeneration: harness.store.dataGeneration
    )
    expected = try harness.store.savePatternMarkup(markup, usageID: usage.id, pageIndex: 3, expectedDataGeneration: expected)
    try harness.store.unlinkPattern(patternID: harness.patternID, from: harness.projectID)

    #expect(throws: PatternLibraryMutationError.usageInactive) {
        try harness.store.mutatePatternReaderCounter(
            usageID: usage.id,
            counterID: counterID,
            mutation: .increment,
            expectedDataGeneration: harness.store.dataGeneration
        )
    }
    #expect(harness.store.patternUsages.first(where: { $0.id == usage.id })?.readingState == state)
    #expect(try harness.store.loadPatternMarkup(usageID: usage.id, pageIndex: 3) == markup)

    let relinked = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    expected = try harness.store.mutatePatternReaderCounter(
        usageID: relinked.id,
        counterID: counterID,
        mutation: .increment,
        expectedDataGeneration: harness.store.dataGeneration
    )
    #expect(expected == harness.store.dataGeneration)
    #expect(relinked.id == usage.id)
    #expect(harness.store.patternUsages.first(where: { $0.id == usage.id })?.readingState == state)
    #expect(try harness.store.loadPatternMarkup(usageID: usage.id, pageIndex: 3) == markup)
}

@MainActor @Test func usageBoundReaderServiceRejectsUnknownUsageInsteadOfProvidingStandaloneWrites() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()

    #expect(throws: PatternLibraryMutationError.usageNotFound) {
        try harness.store.savePatternMarkup(
            PatternMarkupDocument(),
            usageID: UUID(),
            pageIndex: 0,
            expectedDataGeneration: harness.store.dataGeneration
        )
    }
}

@MainActor @Test func linkedProjectsKeepReadingNotesAndMarkupIndependent() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndTwoProjects()
    let first = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let second = try harness.store.linkPattern(patternID: harness.patternID, to: harness.secondProjectID!)
    let firstMarkup = PatternMarkupDocument(strokes: [.init(
        points: [.init(x: 0.1, y: 0.2)], color: .red, width: 0.006
    )])

    try harness.store.updatePatternState(usageID: first.id, state: PatternReadingState(pageIndex: 2))
    try harness.store.savePatternPageNote(usageID: first.id, pageIndex: 2, text: "first project")
    try harness.store.savePatternMarkup(
        firstMarkup,
        usageID: first.id,
        pageIndex: 2,
        expectedDataGeneration: harness.store.dataGeneration
    )

    #expect(harness.store.patternUsages.first(where: { $0.id == first.id })?.readingState.pageIndex == 2)
    #expect(harness.store.patternUsages.first(where: { $0.id == second.id })?.readingState.pageIndex == 0)
    #expect(harness.store.patternUsages.first(where: { $0.id == first.id })?.readingState.pageStates[2]?.note == "first project")
    #expect(harness.store.patternUsages.first(where: { $0.id == second.id })?.readingState.pageStates[2]?.note == nil)
    #expect(try harness.store.loadPatternMarkup(usageID: first.id, pageIndex: 2) == firstMarkup)
    #expect(try harness.store.loadPatternMarkup(usageID: second.id, pageIndex: 2).strokes.isEmpty)
}

@MainActor @Test func emptyDeletionTransactionDoesNotLeaveADeletionJournal() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()

    let transaction = try PatternLibraryDeletionTransaction.begin(
        root: harness.patternsRoot,
        markupService: PatternMarkupFileService(root: harness.patternsRoot),
        usageIDs: [],
        asset: nil,
        fileService: PatternFileService(root: harness.patternsRoot)
    )
    try transaction.stage()

    let reopened = try harness.reopenedStore()
    #expect(reopened.loadError == nil)
    #expect(harness.deletionTransactionEntries().isEmpty)
}

@MainActor @Test func projectDeletionRejectsASymlinkedUsageMarkupRoot() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    try harness.store.savePatternMarkup(
        harness.drawing(x: 0.3),
        usageID: usage.id,
        pageIndex: 0,
        expectedDataGeneration: harness.store.dataGeneration
    )
    let usageMarkupRoot = harness.patternsRoot.appendingPathComponent("UsageMarkup", isDirectory: true)
    let outside = harness.root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.removeItem(at: usageMarkupRoot)
    try FileManager.default.createSymbolicLink(at: usageMarkupRoot, withDestinationURL: outside)

    #expect(throws: PatternMarkupFileError.unsafePath) {
        try harness.store.delete(id: harness.projectID)
    }
    #expect(harness.store.projects.map(\.id) == [harness.projectID])
}

@MainActor @Test func unlinkingAnUnknownPairDoesNotDeletePatternOrAsset() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()

    try harness.store.unlinkPattern(patternID: harness.patternID, from: UUID())

    #expect(harness.store.patterns.map(\.id) == [harness.patternID])
    #expect(harness.store.patternAssets.map(\.id) == [harness.assetID])
    #expect(FileManager.default.fileExists(atPath: harness.assetURL.path))
}

@MainActor @Test func completedProjectRejectsReaderWrites() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject(completed: true)
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)

    #expect(throws: PatternLibraryMutationError.projectCompleted) {
        try harness.store.updatePatternState(usageID: usage.id, state: PatternReadingState(pageIndex: 3))
    }
    #expect(throws: PatternLibraryMutationError.projectCompleted) {
        try harness.store.savePatternPageNote(usageID: usage.id, pageIndex: 3, text: "blocked")
    }
    #expect(throws: PatternLibraryMutationError.projectCompleted) {
        try harness.store.savePatternMarkup(
            PatternMarkupDocument(),
            usageID: usage.id,
            pageIndex: 3,
            expectedDataGeneration: harness.store.dataGeneration
        )
    }
}

@MainActor @Test func deletingProjectDeletesAllItsUsageMarkupWithoutDeletingPatternOrAsset() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndTwoProjects()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let survivingUsage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.secondProjectID!)
    try harness.store.savePatternMarkup(
        PatternMarkupDocument(strokes: [.init(points: [.init(x: 0.4, y: 0.5)], color: .black, width: 0.01)]),
        usageID: usage.id,
        pageIndex: 0,
        expectedDataGeneration: harness.store.dataGeneration
    )
    let markupURL = harness.markupURL(usageID: usage.id, pageIndex: 0)
    let survivingMarkup = PatternMarkupDocument(strokes: [.init(
        points: [.init(x: 0.7, y: 0.6)], color: .red, width: 0.01
    )])
    try harness.store.updatePatternState(
        usageID: survivingUsage.id,
        state: PatternReadingState(pageIndex: 5)
    )
    try harness.store.savePatternMarkup(
        survivingMarkup,
        usageID: survivingUsage.id,
        pageIndex: 5,
        expectedDataGeneration: harness.store.dataGeneration
    )
    let updatedSurvivingUsage = try #require(
        harness.store.patternUsages.first(where: { $0.id == survivingUsage.id })
    )

    try harness.store.unlinkPattern(patternID: harness.patternID, from: harness.projectID)
    try harness.store.delete(id: harness.projectID)

    #expect(harness.store.patternUsages == [updatedSurvivingUsage])
    #expect(harness.store.patterns.map(\.id) == [harness.patternID])
    #expect(harness.store.patternAssets.map(\.id) == [harness.assetID])
    #expect(!FileManager.default.fileExists(atPath: markupURL.path))
    #expect(FileManager.default.fileExists(atPath: harness.assetURL.path))
    #expect(try harness.store.loadPatternMarkup(usageID: survivingUsage.id, pageIndex: 5) == survivingMarkup)

    let reopened = try harness.reopenedStore()
    #expect(reopened.patternUsages == [updatedSurvivingUsage])
    #expect(try reopened.loadPatternMarkup(usageID: survivingUsage.id, pageIndex: 5) == survivingMarkup)
}

@MainActor @Test func failedProjectDeleteRestoresUsagesMarkupAndArchiveAfterFreshReload() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject(failingArchiveWrites: true)
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let markup = PatternMarkupDocument(strokes: [.init(
        points: [.init(x: 0.2, y: 0.2)], color: .green, width: 0.01
    )])
    try harness.store.savePatternMarkup(
        markup,
        usageID: usage.id,
        pageIndex: 0,
        expectedDataGeneration: harness.store.dataGeneration
    )
    harness.archiveWriteGate?.shouldFail = true

    #expect(throws: ProjectStoreError.persistenceFailed) {
        try harness.store.delete(id: harness.projectID)
    }

    let reopened = try harness.reopenedStore()
    #expect(reopened.loadError == nil)
    #expect(reopened.projects.map(\.id) == [harness.projectID])
    #expect(reopened.patternUsages.map(\.id) == [usage.id])
    #expect(try reopened.loadPatternMarkup(usageID: usage.id, pageIndex: 0) == markup)
}

@MainActor @Test func permanentDeleteBlocksActiveLinksThenRemovesInactiveUsageMarkupAndLastAsset() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    try harness.store.savePatternMarkup(
        PatternMarkupDocument(strokes: [.init(points: [.init(x: 0.2, y: 0.8)], color: .blue, width: 0.01)]),
        usageID: usage.id,
        pageIndex: 1,
        expectedDataGeneration: harness.store.dataGeneration
    )
    let markupURL = harness.markupURL(usageID: usage.id, pageIndex: 1)

    #expect(throws: PatternLibraryMutationError.activeLinksExist([harness.projectID])) {
        try harness.store.deletePatternPermanently(id: harness.patternID)
    }
    try harness.store.unlinkPattern(patternID: harness.patternID, from: harness.projectID)
    try harness.store.deletePatternPermanently(id: harness.patternID)

    #expect(harness.store.patterns.isEmpty)
    #expect(harness.store.patternUsages.isEmpty)
    #expect(harness.store.patternAssets.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: markupURL.path))
    #expect(!FileManager.default.fileExists(atPath: harness.assetURL.path))

    let reopened = try harness.reopenedStore()
    #expect(reopened.loadError == nil)
    #expect(reopened.patterns.isEmpty)
    #expect(reopened.patternUsages.isEmpty)
    #expect(reopened.patternAssets.isEmpty)
}

@MainActor @Test func permanentDeleteKeepsAnAssetReferencedByAnotherPattern() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject(sharedAsset: true)
    _ = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    try harness.store.unlinkPattern(patternID: harness.patternID, from: harness.projectID)

    try harness.store.deletePatternPermanently(id: harness.patternID)

    #expect(harness.store.patterns.map(\.id) == [harness.sharedPatternID!])
    #expect(harness.store.patternAssets.map(\.id) == [harness.assetID])
    #expect(FileManager.default.fileExists(atPath: harness.assetURL.path))
}

@MainActor @Test func failedPermanentDeleteRestoresArchiveAndOwnedFiles() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject(failingArchiveWrites: true)
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    try harness.store.savePatternMarkup(
        PatternMarkupDocument(strokes: [.init(points: [.init(x: 0.4, y: 0.4)], color: .green, width: 0.01)]),
        usageID: usage.id,
        pageIndex: 0,
        expectedDataGeneration: harness.store.dataGeneration
    )
    let markupURL = harness.markupURL(usageID: usage.id, pageIndex: 0)
    try harness.store.unlinkPattern(patternID: harness.patternID, from: harness.projectID)
    harness.archiveWriteGate?.shouldFail = true

    #expect(throws: ProjectStoreError.persistenceFailed) {
        try harness.store.deletePatternPermanently(id: harness.patternID)
    }

    #expect(harness.store.patterns.map(\.id) == [harness.patternID])
    #expect(harness.store.patternUsages.map(\.id) == [usage.id])
    #expect(harness.store.patternAssets.map(\.id) == [harness.assetID])
    #expect(FileManager.default.fileExists(atPath: harness.assetURL.path))
    #expect(FileManager.default.fileExists(atPath: markupURL.path))
}

@MainActor @Test func freshStartupRollsBackStagedProjectDeletionBeforeArchivePublication() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndTwoProjects()
    let first = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let second = try harness.store.linkPattern(patternID: harness.patternID, to: harness.secondProjectID!)
    let firstMarkup = harness.drawing(x: 0.1)
    let secondMarkup = harness.drawing(x: 0.9)
    try harness.store.savePatternMarkup(firstMarkup, usageID: first.id, pageIndex: 0, expectedDataGeneration: harness.store.dataGeneration)
    try harness.store.savePatternMarkup(secondMarkup, usageID: second.id, pageIndex: 0, expectedDataGeneration: harness.store.dataGeneration)
    let transaction = try PatternLibraryDeletionTransaction.begin(
        root: harness.patternsRoot,
        markupService: PatternMarkupFileService(root: harness.patternsRoot),
        usageIDs: [first.id],
        asset: nil,
        fileService: PatternFileService(root: harness.patternsRoot)
    )
    try transaction.stage()

    let reopened = try harness.reopenedStore()
    #expect(reopened.loadError == nil)
    let restoredUsageIDs = reopened.patternUsages.map(\.id).sorted { $0.uuidString < $1.uuidString }
    let expectedUsageIDs = [first.id, second.id].sorted { $0.uuidString < $1.uuidString }

    #expect(restoredUsageIDs == expectedUsageIDs)
    #expect(try reopened.loadPatternMarkup(usageID: first.id, pageIndex: 0) == firstMarkup)
    #expect(try reopened.loadPatternMarkup(usageID: second.id, pageIndex: 0) == secondMarkup)
    #expect(harness.deletionTransactionEntries().isEmpty)
}

@MainActor @Test func freshStartupFinalizesPublishedProjectDeletionWithoutTouchingAnotherUsage() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndTwoProjects()
    let first = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let second = try harness.store.linkPattern(patternID: harness.patternID, to: harness.secondProjectID!)
    let firstMarkup = harness.drawing(x: 0.1)
    let secondMarkup = harness.drawing(x: 0.9)
    try harness.store.savePatternMarkup(firstMarkup, usageID: first.id, pageIndex: 0, expectedDataGeneration: harness.store.dataGeneration)
    try harness.store.savePatternMarkup(secondMarkup, usageID: second.id, pageIndex: 0, expectedDataGeneration: harness.store.dataGeneration)
    let transaction = try PatternLibraryDeletionTransaction.begin(
        root: harness.patternsRoot,
        markupService: PatternMarkupFileService(root: harness.patternsRoot),
        usageIDs: [first.id],
        asset: nil,
        fileService: PatternFileService(root: harness.patternsRoot)
    )
    try transaction.stage()
    try harness.removeProjectFromArchive(projectID: harness.projectID)
    try transaction.publish()

    let reopened = try harness.reopenedStore()
    #expect(reopened.loadError == nil)

    #expect(reopened.projects.map(\.id) == [harness.secondProjectID!])
    #expect(reopened.patternUsages.map(\.id) == [second.id])
    #expect(try reopened.loadPatternMarkup(usageID: second.id, pageIndex: 0) == secondMarkup)
    #expect(harness.deletionTransactionEntries().isEmpty)
}

@MainActor @Test func freshStartupRollsBackStagedPatternDeletionBeforeArchivePublication() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let markup = harness.drawing(x: 0.3)
    try harness.store.savePatternMarkup(markup, usageID: usage.id, pageIndex: 0, expectedDataGeneration: harness.store.dataGeneration)
    let transaction = try PatternLibraryDeletionTransaction.begin(
        root: harness.patternsRoot,
        markupService: PatternMarkupFileService(root: harness.patternsRoot),
        usageIDs: [usage.id],
        asset: harness.asset,
        fileService: PatternFileService(root: harness.patternsRoot)
    )
    try transaction.stage()

    let reopened = try harness.reopenedStore()
    #expect(reopened.loadError == nil)

    #expect(reopened.patterns.map(\.id) == [harness.patternID])
    #expect(reopened.patternAssets.map(\.id) == [harness.assetID])
    #expect(try reopened.loadPatternMarkup(usageID: usage.id, pageIndex: 0) == markup)
    #expect(FileManager.default.fileExists(atPath: harness.assetURL.path))
    #expect(harness.deletionTransactionEntries().isEmpty)
}

@MainActor @Test func freshStartupFinalizesPublishedPatternDeletionAndClearsTransactionArtifacts() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    try harness.store.savePatternMarkup(harness.drawing(x: 0.3), usageID: usage.id, pageIndex: 0, expectedDataGeneration: harness.store.dataGeneration)
    let transaction = try PatternLibraryDeletionTransaction.begin(
        root: harness.patternsRoot,
        markupService: PatternMarkupFileService(root: harness.patternsRoot),
        usageIDs: [usage.id],
        asset: harness.asset,
        fileService: PatternFileService(root: harness.patternsRoot)
    )
    try transaction.stage()
    try harness.removePatternFromArchive(patternID: harness.patternID)
    try transaction.publish()

    let reopened = try harness.reopenedStore()

    #expect(reopened.patterns.isEmpty)
    #expect(reopened.patternUsages.isEmpty)
    #expect(reopened.patternAssets.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: harness.assetURL.path))
    #expect(harness.deletionTransactionEntries().isEmpty)
}

@MainActor @Test func malformedDeletionJournalBlocksLoadAndFurtherMutations() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    try harness.writeMalformedDeletionJournal()

    let reopened = try harness.reopenedStore()

    #expect(reopened.loadError == .unreadableArchive)
    #expect(throws: ProjectStoreError.archiveUnavailable) {
        try reopened.linkPattern(patternID: harness.patternID, to: harness.projectID)
    }
}

@MainActor @Test func tamperedDeletionJournalIntegrityBlocksLoadAndFurtherMutations() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let transaction = try PatternLibraryDeletionTransaction.begin(
        root: harness.patternsRoot,
        markupService: PatternMarkupFileService(root: harness.patternsRoot),
        usageIDs: [usage.id],
        asset: nil,
        fileService: PatternFileService(root: harness.patternsRoot)
    )
    try transaction.stage()
    try harness.tamperDeletionJournalIntegrity()

    let reopened = try harness.reopenedStore()

    #expect(reopened.loadError == .unreadableArchive)
    #expect(throws: ProjectStoreError.archiveUnavailable) {
        try reopened.linkPattern(patternID: harness.patternID, to: harness.projectID)
    }
}

@MainActor
final class PatternLibraryStoreHarness {
    let root: URL
    let patternID: UUID
    let assetID: UUID
    let projectID: UUID
    let secondProjectID: UUID?
    let sharedPatternID: UUID?
    let asset: PatternAsset
    let patternsRoot: URL
    let archiveURL: URL
    let assetURL: URL
    let store: JSONProjectStore
    let archiveWriteGate: ArchiveWriteGate?

    private init(
        completed: Bool,
        secondProject: Bool,
        sharedAsset: Bool,
        failingArchiveWrites: Bool
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatternLibraryStoreHarness-\(UUID().uuidString)", isDirectory: true)
        patternsRoot = root.appendingPathComponent("Patterns", isDirectory: true)
        archiveURL = root.appendingPathComponent("projects-v1.json")
        assetID = UUID()
        patternID = UUID()
        projectID = UUID()
        secondProjectID = secondProject ? UUID() : nil
        let sharedID = sharedAsset ? UUID() : nil
        sharedPatternID = sharedID
        assetURL = patternsRoot.appendingPathComponent("Assets", isDirectory: true)
            .appendingPathComponent("\(assetID.uuidString).pdf")
        try FileManager.default.createDirectory(at: assetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeTestPatternPDF(at: assetURL)
        let metadata = try PatternFileService(root: patternsRoot).inspect(assetURL)
        asset = PatternAsset(
            id: assetID,
            sha256: metadata.sha256,
            kind: metadata.kind,
            storedFilename: assetURL.lastPathComponent,
            byteCount: metadata.byteCount,
            pageCount: metadata.pageCount
        )
        let firstProject = try StoredProject(
            id: projectID,
            name: "First",
            completedAt: completed ? Date(timeIntervalSince1970: 1) : nil
        )
        var projects = [firstProject]
        if let secondProjectID {
            projects.append(try StoredProject(id: secondProjectID, name: "Second"))
        }
        var archivePatterns = [StoredPattern(id: patternID, assetID: assetID, displayName: "Fixture")]
        if let sharedID {
            archivePatterns.append(StoredPattern(id: sharedID, assetID: assetID, displayName: "Shared"))
        }
        let archive = ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: projects,
            patternAssets: [asset],
            patterns: archivePatterns
        )
        try JSONEncoder().encode(archive).write(to: archiveURL, options: .atomic)
        let gate = failingArchiveWrites ? ArchiveWriteGate() : nil
        archiveWriteGate = gate
        store = JSONProjectStore(
            url: archiveURL,
            patternFileService: PatternFileService(root: patternsRoot),
            patternInboxFileService: PatternInboxFileService(
                root: root.appendingPathComponent("PatternInbox", isDirectory: true)
            ),
            backupService: KnitNoteBackupService(
                liveRoot: root,
                workRoot: root.appendingPathComponent(".BackupWork", isDirectory: true)
            ),
            archiveWrite: { data, destination in
                if gate?.shouldFail == true { throw ProjectStoreError.persistenceFailed }
                try data.write(to: destination, options: .atomic)
            }
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    static func onePatternAndProject(
        completed: Bool = false,
        sharedAsset: Bool = false,
        failingArchiveWrites: Bool = false
    ) throws -> PatternLibraryStoreHarness {
        try .init(
            completed: completed,
            secondProject: false,
            sharedAsset: sharedAsset,
            failingArchiveWrites: failingArchiveWrites
        )
    }

    static func onePatternAndTwoProjects() throws -> PatternLibraryStoreHarness {
        try .init(
            completed: false,
            secondProject: true,
            sharedAsset: false,
            failingArchiveWrites: false
        )
    }

    func markupURL(usageID: UUID, pageIndex: Int) -> URL {
        root.appendingPathComponent("Patterns/UsageMarkup/\(usageID.uuidString)/\(pageIndex).json")
    }

    func drawing(x: Double) -> PatternMarkupDocument {
        PatternMarkupDocument(strokes: [.init(
            points: [.init(x: x, y: 0.5)], color: .black, width: 0.01
        )])
    }

    func reopenedStore() throws -> JSONProjectStore {
        JSONProjectStore(
            url: archiveURL,
            patternFileService: PatternFileService(root: patternsRoot),
            patternInboxFileService: PatternInboxFileService(
                root: root.appendingPathComponent("PatternInbox", isDirectory: true)
            ),
            backupService: KnitNoteBackupService(
                liveRoot: root,
                workRoot: root.appendingPathComponent(".BackupWork", isDirectory: true)
            )
        )
    }

    func removeProjectFromArchive(projectID: UUID) throws {
        var archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: archiveURL))
        archive.projects.removeAll { $0.id == projectID }
        archive.patternUsages.removeAll { $0.projectID == projectID }
        try JSONEncoder().encode(archive).write(to: archiveURL, options: .atomic)
    }

    func removePatternFromArchive(patternID: UUID) throws {
        var archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: archiveURL))
        guard let pattern = archive.patterns.first(where: { $0.id == patternID }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        archive.patterns.removeAll { $0.id == patternID }
        archive.patternUsages.removeAll { $0.patternID == patternID }
        if !archive.patterns.contains(where: { $0.assetID == pattern.assetID }) {
            archive.patternAssets.removeAll { $0.id == pattern.assetID }
        }
        try JSONEncoder().encode(archive).write(to: archiveURL, options: .atomic)
    }

    func deletionTransactionEntries() -> [URL] {
        let root = patternsRoot.appendingPathComponent(".DeletionTransactions", isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    }

    func writeMalformedDeletionJournal() throws {
        let root = patternsRoot.appendingPathComponent(".DeletionTransactions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not a journal".utf8).write(
            to: root.appendingPathComponent("\(UUID().uuidString).json"),
            options: .atomic
        )
    }

    func tamperDeletionJournalIntegrity() throws {
        guard let journalURL = deletionTransactionEntries().first(where: { $0.pathExtension == "json" }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any]
        object?["integrity"] = "tampered"
        try JSONSerialization.data(withJSONObject: object ?? [:]).write(to: journalURL, options: .atomic)
    }
}

final class ArchiveWriteGate: @unchecked Sendable {
    var shouldFail = false
}
