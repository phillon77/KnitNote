import Dispatch
import Foundation
import Testing
@testable import KnitNoteCore

@MainActor @Test func storeReturnsVersionedURLForRequestedPDFPageThumbnail() async throws {
    let harness = try PatternImportHarness()
    let sourceURL = harness.sourceRoot.appendingPathComponent("ThreePages.pdf")
    try makeTestPatternPDF(at: sourceURL, pageCount: 3)
    _ = try await harness.importURL(sourceURL)
    let asset = try #require(harness.store.patternAssets.first)

    let thumbnailURL = try #require(
        await harness.store.patternPDFPageThumbnailURL(assetID: asset.id, pageIndex: 1)
    )
    let expectedURL = try harness.thumbnailService.thumbnailURL(
        asset: asset,
        sourceURL: try harness.assetURLFor(source: sourceURL),
        pageIndex: 1
    )

    #expect(FileManager.default.fileExists(atPath: thumbnailURL.path))
    #expect(thumbnailURL == expectedURL)
}

@MainActor @Test func storeDoesNotPublishInvalidOrCancelledPageThumbnailRequests() async throws {
    let harness = try PatternImportHarness()
    let pdfURL = harness.sourceRoot.appendingPathComponent("ThreePages.pdf")
    try makeTestPatternPDF(at: pdfURL, pageCount: 3)
    _ = try await harness.importURL(pdfURL)
    let pdfAsset = try #require(harness.store.patternAssets.first)
    let imageURL = try harness.writeFile(
        named: "SinglePixel.png",
        bytes: try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL6aAAAAABJRU5ErkJggg=="))
    )
    _ = try await harness.importURL(imageURL)
    let imageAsset = try #require(harness.store.patternAssets.first { $0.kind == .image })

    #expect(await harness.store.patternPDFPageThumbnailURL(assetID: imageAsset.id, pageIndex: 0) == nil)
    #expect(await harness.store.patternPDFPageThumbnailURL(assetID: pdfAsset.id, pageIndex: -1) == nil)
    #expect(await harness.store.patternPDFPageThumbnailURL(assetID: pdfAsset.id, pageIndex: 3) == nil)

    let cancelledRequest = Task { @MainActor in
        await harness.store.patternPDFPageThumbnailURL(assetID: pdfAsset.id, pageIndex: 0)
    }
    cancelledRequest.cancel()
    #expect(await cancelledRequest.value == nil)
}

@MainActor @Test func storePublishesPageThumbnailWhenOnlyGlobalGenerationChanges() async throws {
    let harness = try PageThumbnailStalenessHarness()
    defer { harness.cleanup() }
    let generationBeforeRequest = harness.store.dataGeneration

    let request = Task { @MainActor in
        await harness.store.patternPDFPageThumbnailURL(assetID: harness.asset.id, pageIndex: 1)
    }
    #expect(await Task.detached { harness.blocker.waitUntilBlocked() }.value)

    try harness.store.reloadFromDisk()
    #expect(harness.store.dataGeneration > generationBeforeRequest)
    harness.blocker.resume()

    #expect(await request.value == harness.sourceURL)
}

@MainActor @Test func storeSuppressesPageThumbnailWhenAssetRevisionChangesDuringRendering() async throws {
    let harness = try PageThumbnailStalenessHarness()
    defer { harness.cleanup() }

    let request = Task { @MainActor in
        await harness.store.patternPDFPageThumbnailURL(assetID: harness.asset.id, pageIndex: 1)
    }
    #expect(await Task.detached { harness.blocker.waitUntilBlocked() }.value)

    try FileManager.default.removeItem(at: harness.sourceURL)
    try makeTestPatternPDF(at: harness.sourceURL, pageCount: 4)
    let revisedMetadata = try harness.fileService.inspect(harness.sourceURL)
    let revisedAsset = PatternAsset(
        id: harness.asset.id,
        sha256: revisedMetadata.sha256,
        kind: revisedMetadata.kind,
        storedFilename: harness.asset.storedFilename,
        byteCount: revisedMetadata.byteCount,
        pageCount: revisedMetadata.pageCount
    )
    try harness.writeArchive(assets: [revisedAsset])
    try harness.store.reloadFromDisk()
    harness.blocker.resume()

    #expect(await request.value == nil)
}

@MainActor @Test func storeSuppressesPageThumbnailWhenAssetIsDeletedDuringRendering() async throws {
    let harness = try PageThumbnailStalenessHarness()
    defer { harness.cleanup() }

    let request = Task { @MainActor in
        await harness.store.patternPDFPageThumbnailURL(assetID: harness.asset.id, pageIndex: 1)
    }
    #expect(await Task.detached { harness.blocker.waitUntilBlocked() }.value)

    try harness.writeArchive(assets: [])
    try harness.store.reloadFromDisk()
    harness.blocker.resume()

    #expect(await request.value == nil)
}

@MainActor @Test func cancellingStoreRequestCancelsStartedDetachedPageThumbnailRender() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PageThumbnailCancellation-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appendingPathComponent("projects-v1.json")
    let fileService = PatternFileService(root: root.appendingPathComponent("Patterns", isDirectory: true))
    let assetID = UUID()
    let sourceURL = fileService.assetsRoot.appendingPathComponent("\(assetID.uuidString).pdf")
    try FileManager.default.createDirectory(at: fileService.assetsRoot, withIntermediateDirectories: true)
    try makeTestPatternPDF(at: sourceURL, pageCount: 3)
    let metadata = try fileService.inspect(sourceURL)
    let asset = PatternAsset(
        id: assetID,
        sha256: metadata.sha256,
        kind: metadata.kind,
        storedFilename: sourceURL.lastPathComponent,
        byteCount: metadata.byteCount,
        pageCount: metadata.pageCount
    )
    try JSONEncoder().encode(ProjectArchive(
        version: ProjectArchive.currentVersion,
        projects: [],
        patternAssets: [asset]
    )).write(to: archiveURL, options: .atomic)
    let blocker = PageThumbnailRenderBlocker()
    let staleCacheURL = root.appendingPathComponent("stale-page.jpg")
    let store = JSONProjectStore(
        url: archiveURL,
        patternFileService: fileService,
        patternPDFPageThumbnailURLGenerator: { _, _, _ in
            blocker.blockOnce()
            guard !Task.isCancelled else { return nil }
            try? Data("stale".utf8).write(to: staleCacheURL, options: .atomic)
            return staleCacheURL
        },
        backupService: KnitNoteBackupService(
            liveRoot: root,
            workRoot: root.appendingPathComponent("BackupWork", isDirectory: true)
        )
    )
    defer { blocker.resume() }

    let request = Task { @MainActor in
        await store.patternPDFPageThumbnailURL(assetID: asset.id, pageIndex: 1)
    }
    #expect(await Task.detached { blocker.waitUntilBlocked() }.value)

    request.cancel()
    blocker.resume()

    #expect(await request.value == nil)
    #expect(!FileManager.default.fileExists(atPath: staleCacheURL.path))
}

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

private final class PageThumbnailRenderBlocker: @unchecked Sendable {
    private let blocked = DispatchSemaphore(value: 0)
    private let continuation = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hasBlocked = false

    func blockOnce() {
        lock.lock()
        guard !hasBlocked else {
            lock.unlock()
            return
        }
        hasBlocked = true
        lock.unlock()
        blocked.signal()
        continuation.wait()
    }

    func waitUntilBlocked() -> Bool {
        blocked.wait(timeout: .now() + 10) == .success
    }

    func resume() {
        continuation.signal()
    }
}

@MainActor
private final class PageThumbnailStalenessHarness {
    let root: URL
    let archiveURL: URL
    let fileService: PatternFileService
    let sourceURL: URL
    let asset: PatternAsset
    let blocker: PageThumbnailRenderBlocker
    let store: JSONProjectStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageThumbnailStaleness-\(UUID().uuidString)", isDirectory: true)
        archiveURL = root.appendingPathComponent("projects-v1.json")
        fileService = PatternFileService(
            root: root.appendingPathComponent("Patterns", isDirectory: true)
        )
        let assetID = UUID()
        sourceURL = fileService.assetsRoot.appendingPathComponent("\(assetID.uuidString).pdf")
        try FileManager.default.createDirectory(
            at: fileService.assetsRoot,
            withIntermediateDirectories: true
        )
        try makeTestPatternPDF(at: sourceURL, pageCount: 3)
        let metadata = try fileService.inspect(sourceURL)
        asset = PatternAsset(
            id: assetID,
            sha256: metadata.sha256,
            kind: metadata.kind,
            storedFilename: sourceURL.lastPathComponent,
            byteCount: metadata.byteCount,
            pageCount: metadata.pageCount
        )
        blocker = PageThumbnailRenderBlocker()
        try JSONEncoder().encode(ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: [],
            patternAssets: [asset]
        )).write(to: archiveURL, options: .atomic)
        store = JSONProjectStore(
            url: archiveURL,
            patternFileService: fileService,
            patternPDFPageThumbnailURLGenerator: { [blocker] _, sourceURL, _ in
                blocker.blockOnce()
                return sourceURL
            },
            backupService: KnitNoteBackupService(
                liveRoot: root,
                workRoot: root.appendingPathComponent("BackupWork", isDirectory: true)
            )
        )
    }

    func writeArchive(assets: [PatternAsset]) throws {
        try JSONEncoder().encode(ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: [],
            patternAssets: assets
        )).write(to: archiveURL, options: .atomic)
    }

    func cleanup() {
        blocker.resume()
        try? FileManager.default.removeItem(at: root)
    }
}
