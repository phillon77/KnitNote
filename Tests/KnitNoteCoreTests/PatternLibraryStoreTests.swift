import Foundation
import Testing
@testable import KnitNoteCore

@MainActor @Test func unlinkAndRelinkRestoreTheSameUsage() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()

    let original = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    try harness.store.updatePatternState(
        usageID: original.id,
        state: PatternReadingState(pageIndex: 3, highlightPosition: 0.7)
    )
    try harness.store.unlinkPattern(patternID: harness.patternID, from: harness.projectID)

    let restored = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)

    #expect(restored.id == original.id)
    #expect(restored.isActive)
    #expect(restored.readingState.pageIndex == 3)
    #expect(restored.readingState.highlightPosition == 0.7)
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
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    try harness.store.savePatternMarkup(
        PatternMarkupDocument(strokes: [.init(points: [.init(x: 0.4, y: 0.5)], color: .black, width: 0.01)]),
        usageID: usage.id,
        pageIndex: 0,
        expectedDataGeneration: harness.store.dataGeneration
    )
    let markupURL = harness.markupURL(usageID: usage.id, pageIndex: 0)

    try harness.store.unlinkPattern(patternID: harness.patternID, from: harness.projectID)
    try harness.store.delete(id: harness.projectID)

    #expect(harness.store.patternUsages.isEmpty)
    #expect(harness.store.patterns.map(\.id) == [harness.patternID])
    #expect(harness.store.patternAssets.map(\.id) == [harness.assetID])
    #expect(!FileManager.default.fileExists(atPath: markupURL.path))
    #expect(FileManager.default.fileExists(atPath: harness.assetURL.path))
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

@MainActor
final class PatternLibraryStoreHarness {
    let root: URL
    let patternID: UUID
    let assetID: UUID
    let projectID: UUID
    let secondProjectID: UUID?
    let sharedPatternID: UUID?
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
        let patternsRoot = root.appendingPathComponent("Patterns", isDirectory: true)
        let archiveURL = root.appendingPathComponent("projects-v1.json")
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
        let asset = PatternAsset(
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
}

final class ArchiveWriteGate: @unchecked Sendable {
    var shouldFail = false
}
