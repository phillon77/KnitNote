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

private struct InvalidSnapshotCase: Sendable {
    let snapshot: PatternLibrarySnapshot
    let expectedError: PatternLibraryValidationError
}

@Test(arguments: invalidSnapshotCases())
private func snapshotRejectsEachDuplicateIdentifierAndMissingPattern(
    invalidCase: InvalidSnapshotCase
) {
    #expect(throws: invalidCase.expectedError) {
        try invalidCase.snapshot.validated()
    }
}

@Test func snapshotAcceptsACompleteReferenceGraph() throws {
    let projectID = UUID()
    let asset = PatternAsset(
        sha256: "valid",
        kind: .image,
        storedFilename: "valid.png",
        byteCount: 4,
        pageCount: nil
    )
    let pattern = StoredPattern(assetID: asset.id, displayName: "Valid pattern")
    let usage = PatternProjectUsage(patternID: pattern.id, projectID: projectID, sortOrder: 0)
    let snapshot = PatternLibrarySnapshot(
        assets: [asset],
        patterns: [pattern],
        usages: [usage],
        validProjectIDs: [projectID]
    )

    let validated = try snapshot.validated()

    #expect(validated.assets == [asset])
    #expect(validated.patterns == [pattern])
    #expect(validated.usages == [usage])
    #expect(validated.validProjectIDs == [projectID])
}

@Test func archiveRoundTripsArchiveLevelPatternCollections() throws {
    let project = try StoredProject(name: "Archive project")
    let asset = PatternAsset(
        sha256: "archive",
        kind: .pdf,
        storedFilename: "archive.pdf",
        byteCount: 99,
        pageCount: 3
    )
    let pattern = StoredPattern(assetID: asset.id, displayName: "Archive pattern")
    let usage = PatternProjectUsage(patternID: pattern.id, projectID: project.id, sortOrder: 1)
    let archive = ProjectArchive(
        version: 9,
        projects: [project],
        patternAssets: [asset],
        patterns: [pattern],
        patternUsages: [usage]
    )

    let decoded = try JSONDecoder().decode(ProjectArchive.self, from: JSONEncoder().encode(archive))

    #expect(decoded.version == 9)
    #expect(decoded.projects == [project])
    #expect(decoded.patternAssets == [asset])
    #expect(decoded.patterns == [pattern])
    #expect(decoded.patternUsages == [usage])
}

@Test(arguments: Array(1...9))
func legacyArchiveWithoutPatternLibraryCollectionsDecodes(version: Int) throws {
    let data = Data("{\"version\":\(version),\"projects\":[]}".utf8)

    let archive = try JSONDecoder().decode(ProjectArchive.self, from: data)

    #expect(ProjectArchive.isSupported(version: archive.version))
    #expect(archive.patternAssets.isEmpty)
    #expect(archive.patterns.isEmpty)
    #expect(archive.patternUsages.isEmpty)
}

private func invalidSnapshotCases() -> [InvalidSnapshotCase] {
    let sharedAsset = PatternAsset(
        sha256: "shared",
        kind: .pdf,
        storedFilename: "shared.pdf",
        byteCount: 1,
        pageCount: 1
    )
    let sharedPattern = StoredPattern(assetID: sharedAsset.id, displayName: "Shared")
    let firstProjectID = UUID()
    let secondProjectID = UUID()

    let duplicateAsset = PatternAsset(
        id: sharedAsset.id,
        sha256: "duplicate",
        kind: .image,
        storedFilename: "duplicate.png",
        byteCount: 2,
        pageCount: nil
    )
    let duplicatePattern = StoredPattern(
        id: sharedPattern.id,
        assetID: sharedAsset.id,
        displayName: "Duplicate pattern"
    )
    let duplicateUsageID = UUID()
    let firstUsage = PatternProjectUsage(
        id: duplicateUsageID,
        patternID: sharedPattern.id,
        projectID: firstProjectID,
        sortOrder: 0
    )
    let secondUsage = PatternProjectUsage(
        id: duplicateUsageID,
        patternID: sharedPattern.id,
        projectID: secondProjectID,
        sortOrder: 1
    )
    let unknownPatternUsage = PatternProjectUsage(
        patternID: UUID(),
        projectID: firstProjectID,
        sortOrder: 0
    )

    return [
        .init(
            snapshot: .init(
                assets: [sharedAsset, duplicateAsset],
                patterns: [],
                usages: [],
                validProjectIDs: []
            ),
            expectedError: .duplicateAssetID
        ),
        .init(
            snapshot: .init(
                assets: [sharedAsset],
                patterns: [sharedPattern, duplicatePattern],
                usages: [],
                validProjectIDs: []
            ),
            expectedError: .duplicatePatternID
        ),
        .init(
            snapshot: .init(
                assets: [sharedAsset],
                patterns: [sharedPattern],
                usages: [firstUsage, secondUsage],
                validProjectIDs: [firstProjectID, secondProjectID]
            ),
            expectedError: .duplicateUsageID
        ),
        .init(
            snapshot: .init(
                assets: [],
                patterns: [],
                usages: [],
                validProjectIDs: [firstProjectID, firstProjectID]
            ),
            expectedError: .duplicateProjectID
        ),
        .init(
            snapshot: .init(
                assets: [sharedAsset],
                patterns: [sharedPattern],
                usages: [unknownPatternUsage],
                validProjectIDs: [firstProjectID]
            ),
            expectedError: .missingPattern
        )
    ]
}
