import Foundation
import Testing
@testable import KnitNoteCore

@Test func usageRestoresItsIndependentReadingState() throws {
    let patternID = UUID()
    let projectID = UUID()
    var usage = PatternProjectUsage(patternID: patternID, projectID: projectID, sortOrder: 2)
    var state = PatternReadingState(pageIndex: 4, highlightEnabled: true, highlightPosition: 0.31)
    state.setPageNote("front neck")
    usage.updateReadingState(state, now: Date(timeIntervalSince1970: 20))

    let decoded = try JSONDecoder().decode(
        PatternProjectUsage.self,
        from: JSONEncoder().encode(usage)
    )
    #expect(decoded.patternID == patternID)
    #expect(decoded.projectID == projectID)
    #expect(decoded.readingState.pageIndex == 4)
    #expect(decoded.readingState.pageNote == "front neck")
}

@Test func archiveVersionTenRejectsDuplicateUsagePairs() throws {
    let project = try StoredProject(name: "Cardigan")
    let pattern = StoredPattern(assetID: UUID(), displayName: "Ida Tee")
    let first = PatternProjectUsage(patternID: pattern.id, projectID: project.id, sortOrder: 0)
    let second = PatternProjectUsage(patternID: pattern.id, projectID: project.id, sortOrder: 1)
    #expect(throws: PatternLibraryValidationError.duplicateUsage) {
        try PatternLibrarySnapshot(
            assets: [],
            patterns: [pattern],
            usages: [first, second],
            validProjectIDs: [project.id]
        ).validated()
    }
}

@Test func snapshotRejectsPatternWithoutAnAsset() throws {
    let pattern = StoredPattern(assetID: UUID(), displayName: "Missing source")

    #expect(throws: PatternLibraryValidationError.missingAsset) {
        try PatternLibrarySnapshot(
            assets: [],
            patterns: [pattern],
            usages: [],
            validProjectIDs: []
        ).validated()
    }
}

@Test func snapshotRejectsUsageForUnknownProject() throws {
    let asset = PatternAsset(
        sha256: "abc",
        kind: .pdf,
        storedFilename: "abc.pdf",
        byteCount: 1,
        pageCount: 1
    )
    let pattern = StoredPattern(assetID: asset.id, displayName: "Ida Tee")
    let usage = PatternProjectUsage(patternID: pattern.id, projectID: UUID(), sortOrder: 0)

    #expect(throws: PatternLibraryValidationError.missingProject) {
        try PatternLibrarySnapshot(
            assets: [asset],
            patterns: [pattern],
            usages: [usage],
            validProjectIDs: []
        ).validated()
    }
}
