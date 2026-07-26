import Foundation
import Testing
@testable import KnitNoteCore

@MainActor
@Test func sameBytesWithDifferentNamesReuseOneAsset() async throws {
    let harness = try PatternImportHarness()
    let bytes = try Data(contentsOf: harness.makePDF(named: "Original.pdf"))
    let first = try harness.writeFile(named: "Ida.pdf", bytes: bytes)
    let second = try harness.writeFile(named: "Copy.pdf", bytes: bytes)

    _ = try await harness.importURL(first)
    let outcome = try await harness.importURL(second)

    #expect(harness.store.patternAssets.count == 1)
    #expect(outcome == .existing(patternID: harness.store.patterns[0].id))
}

@MainActor
@Test func ambiguousLegacyDuplicateRemainsPendingUntilSelection() async throws {
    let harness = try await PatternImportHarness.withTwoNamesForOneAsset()
    let item = try harness.enqueueMatchingFile()

    let outcome = try await harness.store.processPatternInboxItem(id: item.id)

    guard case let .needsSelection(_, candidatePatternIDs) = outcome else {
        Issue.record("Expected an ambiguous duplicate")
        return
    }
    #expect(candidatePatternIDs.count == 2)
    #expect(harness.inbox.item(id: item.id) != nil)
    #expect(harness.store.patternUsages.isEmpty)
}

@MainActor
@Test func selectedAmbiguousDuplicateIsIdempotentAcrossRetry() async throws {
    let harness = try await PatternImportHarness.withTwoNamesForOneAsset()
    let item = try harness.enqueueMatchingFile()
    let expected = harness.store.patterns[1].id

    let selected = try await harness.store.processPatternInboxItem(
        id: item.id,
        selectingPatternID: expected
    )

    #expect(selected == .existing(patternID: expected))
    #expect(harness.inbox.item(id: item.id) == nil)
    #expect(harness.store.patternAssets.count == 1)
}
