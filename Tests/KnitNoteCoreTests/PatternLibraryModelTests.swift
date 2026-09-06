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
        defer { harness.blocker.finishObservation(reachedBlock: false) }
        return await harness.store.patternPDFPageThumbnailURL(
            assetID: harness.asset.id,
            pageIndex: 1
        )
    }
    do {
        try #require(await harness.blocker.waitForObservedBlock())
        try harness.store.reloadFromDisk()
        #expect(harness.store.dataGeneration > generationBeforeRequest)
        harness.blocker.resume()
        #expect(await request.value == harness.sourceURL)
    } catch {
        harness.blocker.resume()
        _ = await request.value
        throw error
    }
}

@MainActor @Test func storeSuppressesPageThumbnailWhenAssetRevisionChangesDuringRendering() async throws {
    let harness = try PageThumbnailStalenessHarness()
    defer { harness.cleanup() }

    let request = Task { @MainActor in
        defer { harness.blocker.finishObservation(reachedBlock: false) }
        return await harness.store.patternPDFPageThumbnailURL(
            assetID: harness.asset.id,
            pageIndex: 1
        )
    }
    do {
        try #require(await harness.blocker.waitForObservedBlock())
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
    } catch {
        harness.blocker.resume()
        _ = await request.value
        throw error
    }
}

@MainActor @Test func storeSuppressesPageThumbnailWhenAssetIsDeletedDuringRendering() async throws {
    let harness = try PageThumbnailStalenessHarness()
    defer { harness.cleanup() }

    let request = Task { @MainActor in
        defer { harness.blocker.finishObservation(reachedBlock: false) }
        return await harness.store.patternPDFPageThumbnailURL(
            assetID: harness.asset.id,
            pageIndex: 1
        )
    }
    do {
        try #require(await harness.blocker.waitForObservedBlock())
        try harness.writeArchive(assets: [])
        try harness.store.reloadFromDisk()
        harness.blocker.resume()
        #expect(await request.value == nil)
    } catch {
        harness.blocker.resume()
        _ = await request.value
        throw error
    }
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
        defer { blocker.finishObservation(reachedBlock: false) }
        return await store.patternPDFPageThumbnailURL(assetID: asset.id, pageIndex: 1)
    }
    do {
        try #require(await blocker.waitForObservedBlock())
        request.cancel()
        blocker.resume()
        #expect(await request.value == nil)
        #expect(!FileManager.default.fileExists(atPath: staleCacheURL.path))
    } catch {
        request.cancel()
        blocker.resume()
        _ = await request.value
        throw error
    }
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

@Test func schemaThirteenRoundTripsFoldersAndPatternMembership() throws {
    let folder = PatternFolder(displayName: "Sweaters")
    let asset = PatternAsset(
        id: UUID(),
        sha256: String(repeating: "a", count: 64),
        kind: .pdf,
        storedFilename: "fixture.pdf",
        byteCount: 4,
        pageCount: 1
    )
    let pattern = StoredPattern(
        assetID: asset.id,
        displayName: "Cardigan",
        folderID: folder.id
    )
    let archive = ProjectArchive(
        version: 13,
        projects: [],
        patternFolders: [folder],
        patternAssets: [asset],
        patterns: [pattern]
    )

    let decoded = try JSONDecoder().decode(
        ProjectArchive.self,
        from: JSONEncoder().encode(archive)
    )

    #expect(decoded.patternFolders == [folder])
    #expect(decoded.patterns.first?.folderID == folder.id)
}

@Test func schemaTwelveWithoutFolderKeysDefaultsToUncategorized() throws {
    let data = Data(#"{"version":12,"projects":[],"patterns":[]}"#.utf8)

    let archive = try JSONDecoder().decode(ProjectArchive.self, from: data)

    #expect(archive.patternFolders.isEmpty)
}

@Test func snapshotNormalizesAnOrphanFolderReferenceWithoutDroppingThePattern() throws {
    let asset = PatternAsset(
        id: UUID(),
        sha256: String(repeating: "b", count: 64),
        kind: .pdf,
        storedFilename: "fixture.pdf",
        byteCount: 4,
        pageCount: 1
    )
    let pattern = StoredPattern(assetID: asset.id, displayName: "Kept", folderID: UUID())

    let normalized = try PatternLibrarySnapshot(
        folders: [],
        assets: [asset],
        patterns: [pattern],
        usages: [],
        validProjectIDs: []
    ).normalizedAndValidated()

    #expect(normalized.patterns.map(\.displayName) == ["Kept"])
    #expect(normalized.patterns.first?.folderID == nil)
}

@Test func snapshotRejectsDuplicateFolderIdentifiers() {
    let id = UUID()
    let first = PatternFolder(id: id, displayName: "Sweaters")
    let second = PatternFolder(id: id, displayName: "Scarves")

    #expect(throws: PatternLibraryValidationError.duplicateFolderID) {
        try PatternLibrarySnapshot(
            folders: [first, second],
            assets: [],
            patterns: [],
            usages: [],
            validProjectIDs: []
        ).normalizedAndValidated()
    }
}

@Test func snapshotRejectsDuplicateCanonicalAndShippingReservedFolderNames() throws {
    let context = try shippingPatternFolderNameContext()
    let first = PatternFolder(displayName: "Café")
    let duplicate = PatternFolder(displayName: "ＣＡＦＥ")
    let reservedNames = ["All", "全部", "すべて", "미분류"]

    #expect(throws: PatternFolderValidationError.duplicateName) {
        try PatternLibrarySnapshot(
            folders: [first, duplicate],
            assets: [],
            patterns: [],
            usages: [],
            validProjectIDs: []
        ).normalizedAndValidated(nameContext: context)
    }

    for reservedName in reservedNames {
        #expect(throws: PatternFolderValidationError.reservedName) {
            try PatternLibrarySnapshot(
                folders: [PatternFolder(displayName: reservedName)],
                assets: [],
                patterns: [],
                usages: [],
                validProjectIDs: []
            ).normalizedAndValidated(nameContext: context)
        }
    }
}

@MainActor @Test func currentArchiveNameRejectionPublishesNothing() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PatternFolderArchiveBoundary-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appendingPathComponent("projects-v1.json")
    let context = try shippingPatternFolderNameContext()
    let folder = PatternFolder(displayName: "Sweaters")
    let patternFiles = PatternFileService(
        root: root.appendingPathComponent("Patterns", isDirectory: true)
    )
    let assetID = UUID()
    let assetURL = patternFiles.assetsRoot.appendingPathComponent("\(assetID.uuidString).pdf")
    try FileManager.default.createDirectory(
        at: patternFiles.assetsRoot,
        withIntermediateDirectories: true
    )
    try makeTestPatternPDF(at: assetURL)
    let metadata = try patternFiles.inspect(assetURL)
    let asset = PatternAsset(
        id: assetID,
        sha256: metadata.sha256,
        kind: metadata.kind,
        storedFilename: assetURL.lastPathComponent,
        byteCount: metadata.byteCount,
        pageCount: metadata.pageCount
    )
    let pattern = StoredPattern(
        assetID: asset.id,
        displayName: "Kept",
        folderID: folder.id
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try JSONEncoder().encode(ProjectArchive(
        version: ProjectArchive.currentVersion,
        projects: [],
        patternFolders: [folder],
        patternAssets: [asset],
        patterns: [pattern]
    )).write(to: archiveURL, options: .atomic)
    let store = JSONProjectStore(
        url: archiveURL,
        patternFileService: patternFiles,
        patternFolderNameContext: context
    )
    let publishedFolders = store.patternFolders
    let publishedPatterns = store.patterns
    let generation = store.dataGeneration
    let selection = PatternLibraryScope.folder(folder.id)

    let malformed = ProjectArchive(
        version: ProjectArchive.currentVersion,
        projects: [],
        patternFolders: [
            PatternFolder(displayName: "Café"),
            PatternFolder(displayName: "ＣＡＦＥ"),
        ],
        patternAssets: [asset],
        patterns: [pattern]
    )
    let malformedBytes = try JSONEncoder().encode(malformed)
    try malformedBytes.write(to: archiveURL, options: .atomic)

    #expect(throws: ProjectStoreError.unreadableArchive) {
        try store.reloadFromDisk()
    }
    #expect(store.patternFolders == publishedFolders)
    #expect(store.patterns == publishedPatterns)
    #expect(store.dataGeneration == generation)
    #expect(selection == .folder(folder.id))
    #expect(try Data(contentsOf: archiveURL) == malformedBytes)
}

@Test func snapshotNormalizesMalformedHistoricalFolderWhitespace() throws {
    let folder = PatternFolder(displayName: "  Sweaters\n")

    let normalized = try PatternLibrarySnapshot(
        folders: [folder],
        assets: [],
        patterns: [],
        usages: [],
        validProjectIDs: []
    ).normalizedAndValidated(nameContext: try shippingPatternFolderNameContext())

    #expect(normalized.folders.map(\.displayName) == ["Sweaters"])
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
    private let observedBlock: AsyncStream<Bool>
    private let observation: AsyncStream<Bool>.Continuation
    private let continuation = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hasBlocked = false
    private var observationFinished = false

    init() {
        let stream = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observedBlock = stream.stream
        observation = stream.continuation
    }

    func blockOnce() {
        lock.lock()
        guard !hasBlocked else {
            lock.unlock()
            return
        }
        hasBlocked = true
        lock.unlock()
        finishObservation(reachedBlock: true)
        continuation.wait()
    }

    func waitForObservedBlock() async -> Bool {
        for await result in observedBlock { return result }
        return false
    }

    func finishObservation(reachedBlock: Bool) {
        lock.lock()
        guard !observationFinished else {
            lock.unlock()
            return
        }
        observationFinished = true
        lock.unlock()
        observation.yield(reachedBlock)
        observation.finish()
    }

    func resume() {
        continuation.signal()
    }
}

@Test func pageRenderBlockObservationBuffersTheFirstTerminalEvent() async {
    let blocker = PageThumbnailRenderBlocker()
    blocker.finishObservation(reachedBlock: true)
    blocker.finishObservation(reachedBlock: false)
    #expect(await blocker.waitForObservedBlock())
    blocker.resume()
}

@Test func pageRenderCompletionBeforeStartIsObservedAsFailure() async {
    let blocker = PageThumbnailRenderBlocker()
    blocker.finishObservation(reachedBlock: false)
    blocker.finishObservation(reachedBlock: true)
    #expect(await blocker.waitForObservedBlock() == false)
    blocker.resume()
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
