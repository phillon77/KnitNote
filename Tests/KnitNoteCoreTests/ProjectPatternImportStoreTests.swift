import Foundation
import Testing
@testable import KnitNoteCore

@MainActor @Test func projectImportCreatesACollectionAndActiveUsageThroughTheDurableInbox() async throws {
    let harness = try PatternImportHarness()
    try harness.store.add(name: "Sweater")
    let projectID = try #require(harness.store.projects.first?.id)
    let source = try harness.makePDF(named: "New Project Pattern.pdf")

    let outcome = try await harness.store.importPatternFromProject(
        source,
        projectID: projectID
    )
    let patternID = try #require(harness.store.patterns.first?.id)

    #expect(outcome == .created(patternID: patternID))
    #expect(harness.store.patternUsages.count == 1)
    #expect(harness.store.patternUsages[0].patternID == patternID)
    #expect(harness.store.patternUsages[0].projectID == projectID)
    #expect(harness.store.patternUsages[0].isActive)
    #expect(try harness.inbox.items().isEmpty)
}

@MainActor @Test func projectImportOfExistingBytesLinksWithoutDuplicatingTheCollection() async throws {
    let harness = try PatternImportHarness()
    let source = try harness.makePDF(named: "Original.pdf")
    _ = try await harness.store.importPatternFromLibrary(source)
    try harness.store.add(name: "Scarf")
    let projectID = try #require(harness.store.projects.first?.id)

    let outcome = try await harness.store.importPatternFromProject(
        source,
        projectID: projectID
    )
    let patternID = try #require(harness.store.patterns.first?.id)

    #expect(outcome == .existing(patternID: patternID))
    #expect(harness.store.patterns.count == 1)
    #expect(harness.store.patternAssets.count == 1)
    #expect(harness.store.patternUsages.map(\.patternID) == [patternID])
    #expect(harness.store.patternUsages.map(\.projectID) == [projectID])
}

@MainActor @Test func ambiguousProjectImportWaitsForSelectionThenLinksTheChosenCollection() async throws {
    let harness = try await PatternImportHarness.withTwoNamesForOneAsset()
    try harness.store.add(name: "Cardigan")
    let projectID = try #require(harness.store.projects.first?.id)
    let source = harness.sourceRoot.appendingPathComponent("Matching.pdf")

    let pending = try await harness.store.importPatternFromProject(
        source,
        projectID: projectID
    )
    guard case let .needsSelection(itemID, candidatePatternIDs) = pending else {
        Issue.record("Expected migrated duplicates to require selection")
        return
    }
    #expect(harness.store.patternUsages.isEmpty)
    let selectedPatternID = try #require(candidatePatternIDs.first)

    let resolved = try await harness.store.processPatternInboxItem(
        id: itemID,
        selectingPatternID: selectedPatternID
    )

    #expect(resolved == .existing(patternID: selectedPatternID))
    #expect(harness.store.patternUsages.count == 1)
    #expect(harness.store.patternUsages[0].patternID == selectedPatternID)
    #expect(harness.store.patternUsages[0].projectID == projectID)
    #expect(try harness.inbox.items().isEmpty)
}
