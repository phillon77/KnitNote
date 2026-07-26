# Pattern Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build KnitNote 1.2's standalone pattern library so one owned PDF or image can be found easily, linked to multiple projects, and retain independent per-project reading data.

**Architecture:** Replace project-owned `PatternDocument` records with archive-level `PatternAsset`, `StoredPattern`, and `PatternProjectUsage` records. Route every import, including the iOS Share Extension, through a durable App Group inbox and one transaction coordinator; keep reader state and markup keyed by usage while thumbnails and original bytes are keyed by asset. Upgrade archive schema 9 to 10 and backup manifest 1 to 2 with a rollback-safe migration.

**Tech Stack:** Swift 6, SwiftUI, Foundation, CryptoKit, CoreGraphics/ImageIO, UniformTypeIdentifiers, UIKit Share Extension, Swift Testing, XcodeGen, iOS 18, iPadOS 18, macOS 15, watchOS 11.

## Global Constraints

- Target release is 1.2; the already verified automatic project cover remains a 1.1 feature.
- Support Traditional Chinese and English for every new user-facing string.
- Accept only real PDF, PNG, JPEG, or HEIC files; maximum pattern size is exactly 100,000,000 bytes.
- Keep original imported bytes unchanged and export those exact bytes.
- Store each unique file once by SHA-256 content; do not infer equality from filename alone.
- Allow zero, one, or many active project links per pattern.
- Keep page, zoom, offset, highlight, page-note, and markup state independent per project link.
- Completed projects may link and read patterns but may not mutate reader state or markup.
- Preserve inactive usage state after unlinking and restore it when the same project is relinked.
- Do not add folders, categories, tags, web downloading, cloud sync, accounts, analytics, or annotated-PDF export.
- Keep backup single-file limit at 200,000,000 bytes and total package limit at 4,000,000,000 bytes.
- Preserve the user's existing uncommitted `KnitNoteWatch.xcscheme`, localization catalog, `.superpowers/`, `KnitNote 5.xcodeproj/`, and `KnitNote 6.xcodeproj/` changes.
- Run implementation in an isolated worktree created with `superpowers:using-git-worktrees`; merge only after final review.

---

### Task 1: Archive-Level Pattern Models

**Files:**
- Create: `Sources/KnitNoteCore/Patterns/PatternAsset.swift`
- Create: `Sources/KnitNoteCore/Patterns/StoredPattern.swift`
- Create: `Sources/KnitNoteCore/Patterns/PatternProjectUsage.swift`
- Modify: `Sources/KnitNoteCore/Patterns/PatternDocument.swift`
- Modify: `Sources/KnitNoteCore/Projects/StoredProject.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Create: `Tests/KnitNoteCoreTests/PatternLibraryModelTests.swift`
- Create: `Tests/KnitNoteCoreTests/PatternLibraryTestSupport.swift`

**Interfaces:**
- Produces: `PatternAsset`, `StoredPattern`, `PatternProjectUsage`, `PatternLibrarySnapshot`.
- Produces: `ProjectArchive.patternAssets`, `ProjectArchive.patterns`, and `ProjectArchive.patternUsages`.
- Preserves: `PatternDocument` decoding only as the schema 1–9 migration source.
- Produces test helpers: `makeTestPatternPDF(at:)`, `readRepositoryFile(_:)`, and `patternLibraryRepositoryURL(_:)`.

- [ ] **Step 1: Write failing model and archive tests**

```swift
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
```

- [ ] **Step 2: Run the focused tests and confirm failure**

Run: `swift test --filter PatternLibraryModelTests`

Expected: FAIL because the archive-level pattern types do not exist.

- [ ] **Step 3: Add the three focused models and validation boundary**

```swift
public struct PatternAsset: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let sha256: String
    public let kind: PatternKind
    public let storedFilename: String
    public let byteCount: Int64
    public let pageCount: Int?
}

public struct StoredPattern: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let assetID: UUID
    public var displayName: String
    public var note: String?
    public let createdAt: Date
    public var lastOpenedAt: Date?
}

public struct PatternProjectUsage: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let patternID: UUID
    public let projectID: UUID
    public var isActive: Bool
    public let linkedAt: Date
    public var unlinkedAt: Date?
    public var sortOrder: Int
    public var readingState: PatternReadingState

    public mutating func updateReadingState(
        _ state: PatternReadingState,
        now: Date = .now
    )
}
```

Add `PatternLibrarySnapshot.validated()` checks for unique IDs, valid asset/pattern/project references, and a single usage per `(patternID, projectID)` pair. Move the old `StoredProject.patterns` coding key behind an internal `legacyPatternDocuments` property so new runtime code cannot mutate project-owned pattern records.

Add shared test helpers with these exact signatures:

```swift
func makeTestPatternPDF(at url: URL, pageCount: Int = 1) throws
func readRepositoryFile(_ relativePath: String) throws -> String
func patternLibraryRepositoryURL(_ relativePath: String) -> URL
```

- [ ] **Step 4: Run model tests**

Run: `swift test --filter PatternLibraryModelTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/KnitNoteCore/Patterns Sources/KnitNoteCore/Projects/StoredProject.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/PatternLibraryModelTests.swift Tests/KnitNoteCoreTests/PatternLibraryTestSupport.swift
git commit -m "feat: add archive-level pattern models"
```

---

### Task 2: Schema 9 to 10 Migration

**Files:**
- Create: `Sources/KnitNoteCore/Patterns/PatternLibraryMigrator.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Sources/KnitNoteCore/Patterns/PatternMarkupFileService.swift`
- Create: `Tests/KnitNoteCoreTests/PatternLibraryMigrationTests.swift`

**Interfaces:**
- Consumes: legacy `StoredProject.legacyPatternDocuments`.
- Produces: `PatternLibraryMigrator.migrate(archive:liveRoot:) throws -> MigratedPatternLibrary`.
- Produces: schema 10 archive with cleared legacy arrays and usage IDs equal to legacy `PatternDocument.id`.
- Test fixture: `LegacyPatternFixture` creates real schema 9 archives, PDF bytes, and markup directories under a unique temporary root.

- [ ] **Step 1: Write migration fixtures that cover merge, split, order, and rollback**

```swift
@Test func migrationSharesBytesButPreservesDifferentNames() throws {
    let fixture = try LegacyPatternFixture.twoProjects(
        firstName: "Ida Tee",
        secondName: "Ida Tee English",
        identicalBytes: true
    )
    let result = try PatternLibraryMigrator().migrate(
        archive: fixture.archive,
        liveRoot: fixture.liveRoot
    )

    #expect(result.assets.count == 1)
    #expect(result.patterns.map(\.displayName).sorted() == ["Ida Tee", "Ida Tee English"])
    #expect(
        result.usages.map(\.id.uuidString).sorted()
            == fixture.legacyPatternIDs.map(\.uuidString).sorted()
    )
    #expect(result.usages.map(\.sortOrder).sorted() == [0, 0])
}

@Test func failedMigrationLeavesLegacyArchiveAndFilesUntouched() throws {
    let fixture = try LegacyPatternFixture.onePattern()
    let originalArchive = try Data(contentsOf: fixture.archiveURL)
    enum PatternMigrationTestError: Error { case injected }
    let migrator = PatternLibraryMigrator(stepHook: { step in
        if step == .beforeInstall { throw PatternMigrationTestError.injected }
    })
    #expect(throws: PatternMigrationTestError.injected) {
        try migrator.migrateOnDisk(archiveURL: fixture.archiveURL)
    }
    #expect(try Data(contentsOf: fixture.archiveURL) == originalArchive)
    #expect(FileManager.default.fileExists(atPath: fixture.legacyPatternURL.path))
}
```

- [ ] **Step 2: Run migration tests and confirm failure**

Run: `swift test --filter PatternLibraryMigrationTests`

Expected: FAIL because no migrator exists.

- [ ] **Step 3: Implement staged migration**

Implement these exact phases in `PatternLibraryMigrator`:

```swift
public enum PatternMigrationStep: Sendable {
    case afterLegacyValidation
    case afterStaging
    case beforeInstall
    case afterInstall
}

public struct MigratedPatternLibrary: Sendable {
    public let archive: ProjectArchive
    public let stagedRoot: URL
}
```

For every legacy document: validate bytes, compute SHA-256, normalize its display name with trimming plus locale-independent case folding, group by `(sha256, normalizedName)` for `StoredPattern`, group by `sha256` for `PatternAsset`, preserve the legacy document ID as usage ID, and copy markup from `Patterns/<projectID>/Markup/<legacyID>` to `Patterns/UsageMarkup/<usageID>`. Install the staged archive and files with the backup service's move/rollback pattern; clean legacy copies only after reload validation succeeds.

- [ ] **Step 4: Integrate migration into store load**

Set `ProjectArchive.currentVersion = 10`. In `reloadFromDiskDuringDataOperation()`, run migration only for versions 1–9, reload the installed schema 10 archive, publish `patterns` and `patternUsages`, then increment `dataGeneration`.

- [ ] **Step 5: Run migration and existing store tests**

Run: `swift test --filter PatternLibraryMigrationTests`

Run: `swift test --filter JSONProjectStoreTests`

Expected: PASS; existing versions 1–9 still load.

- [ ] **Step 6: Commit**

```bash
git add Sources/KnitNoteCore/Patterns/PatternLibraryMigrator.swift Sources/KnitNoteCore/Patterns/PatternMarkupFileService.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/PatternLibraryMigrationTests.swift
git commit -m "feat: migrate project patterns to library"
```

---

### Task 3: Owned Asset Storage and Durable Import Inbox

**Files:**
- Replace: `Sources/KnitNoteCore/Patterns/PatternFileService.swift`
- Create: `Sources/KnitNoteCore/Patterns/PatternStorageLocations.swift`
- Create: `Sources/KnitNoteCore/Patterns/PatternInboxItem.swift`
- Create: `Sources/KnitNoteCore/Patterns/PatternInboxFileService.swift`
- Create: `Sources/KnitNoteCore/Patterns/PatternImportCoordinator.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Replace tests: `Tests/KnitNoteCoreTests/PatternFileServiceTests.swift`
- Create: `Tests/KnitNoteCoreTests/PatternInboxFileServiceTests.swift`
- Create: `Tests/KnitNoteCoreTests/PatternImportCoordinatorTests.swift`

**Interfaces:**
- Produces: `PatternInboxFileService.enqueue(source:origin:targetProjectID:now:)`.
- Produces: `JSONProjectStore.processPatternInboxItem(id:selectingPatternID:) async throws -> PatternImportOutcome`.
- Produces: deterministic SHA-256 duplicate outcomes and retained ambiguous inbox entries.
- Produces: `PatternStorageLocations.live()` using an App Group inbox on iOS and private Application Support assets on every host platform.
- Test fixture: `PatternImportHarness` exposes `makePDF(named:)`, `writeFile(named:bytes:)`, `importURL(_:)`, and `enqueueMatchingFile()` against injected temporary roots.

- [ ] **Step 1: Write failing validation, byte-preservation, duplicate, and interruption tests**

```swift
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

@Test func ambiguousLegacyDuplicateRemainsPendingUntilSelection() async throws {
    let harness = try PatternImportHarness.withTwoNamesForOneAsset()
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
```

- [ ] **Step 2: Run import tests and confirm failure**

Run: `swift test --filter PatternImport`

Expected: FAIL because the durable inbox and coordinator do not exist.

- [ ] **Step 3: Implement inbox records and atomic file ownership**

```swift
public enum PatternImportOrigin: String, Codable, Sendable {
    case library, project, shareExtension
}

public struct PatternInboxItem: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let originalFilename: String
    public let receivedAt: Date
    public let origin: PatternImportOrigin
    public let targetProjectID: UUID?
    public let stagedFilename: String
}

public enum PatternImportOutcome: Equatable, Sendable {
    case created(patternID: UUID)
    case existing(patternID: UUID)
    case needsSelection(itemID: UUID, candidatePatternIDs: [UUID])
}
```

`enqueue` must copy to `<AppGroup>/PatternInbox/.Candidates/<UUID>`, validate non-empty and ≤100,000,000 bytes, inspect actual PDF/image content, then atomically install the file and JSON sidecar. `PatternFileService` stores final originals at `Patterns/Assets/<assetID>.<ext>` and exposes `assetURL(_:)` and `exportURL(_:)`.

`PatternStorageLocations.live()` uses `FileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.com.phillon.KnitNote")` for the iOS inbox, the injected App Group container inside the extension, and the existing private `KnitNote` Application Support root for final assets. A missing App Group container throws `PatternInboxError.appGroupUnavailable`; it never falls back to an unrelated directory.

- [ ] **Step 4: Implement one transaction coordinator**

The coordinator hashes staged bytes off-main, resolves exact duplicates, selects the only normalized-name match when possible, and returns `.needsSelection` when multiple migrated records remain. It must not delete the inbox item before archive persistence succeeds; new asset installation is rolled back if archive persistence fails.

Wrap each coordinator run with the store's `activePatternTransactions` counter so backup and restore return `KnitNoteBackupError.operationInProgress` until import publication or rollback finishes.

Capture `dataGeneration` before detached validation and hashing, then validate it again immediately before archive publication. If it changed, re-resolve duplicate and project-link decisions against the current arrays instead of publishing a stale snapshot.

- [ ] **Step 5: Run import tests**

Run: `swift test --filter PatternFileServiceTests`

Run: `swift test --filter PatternInboxFileServiceTests`

Run: `swift test --filter PatternImportCoordinatorTests`

Expected: PASS, including empty, oversized, disguised extension, cancellation, retry, and byte-for-byte export cases.

- [ ] **Step 6: Commit**

```bash
git add Sources/KnitNoteCore/Patterns Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/PatternFileServiceTests.swift Tests/KnitNoteCoreTests/PatternInboxFileServiceTests.swift Tests/KnitNoteCoreTests/PatternImportCoordinatorTests.swift
git commit -m "feat: add durable pattern import pipeline"
```

---

### Task 4: Link, Unlink, Delete, and Reader Mutations

**Files:**
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Sources/KnitNoteCore/Patterns/PatternMarkupFileService.swift`
- Create: `Tests/KnitNoteCoreTests/PatternLibraryStoreTests.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternMarkupFileServiceTests.swift`

**Interfaces:**
- Produces: `linkPattern(patternID:to:)`, `unlinkPattern(patternID:from:)`, `deletePatternPermanently(id:)`.
- Produces: `renamePattern(id:to:)`, `setPatternNote(id:note:)`, and `markPatternOpened(id:at:)`.
- Produces: `updatePatternState(usageID:state:expectedDataGeneration:)`, `savePatternPageNote(usageID:pageIndex:text:)`.
- Produces: markup access keyed only by `usageID`.
- Test fixture: `PatternLibraryStoreHarness` creates archive-level assets, patterns, projects, usages, thumbnails, and markup in injected temporary roots for Tasks 4, 5, and 11.

- [ ] **Step 1: Write failing lifecycle tests**

```swift
@MainActor @Test func unlinkAndRelinkRestoreTheSameUsage() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let original = try harness.store.linkPattern(
        patternID: harness.patternID,
        to: harness.projectID
    )
    try harness.store.unlinkPattern(patternID: harness.patternID, from: harness.projectID)
    let restored = try harness.store.linkPattern(
        patternID: harness.patternID,
        to: harness.projectID
    )
    #expect(restored.id == original.id)
    #expect(restored.isActive)
}

@MainActor @Test func completedProjectRejectsReaderWrites() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject(completed: true)
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    #expect(throws: PatternLibraryMutationError.projectCompleted) {
        try harness.store.updatePatternState(
            usageID: usage.id,
            state: PatternReadingState(pageIndex: 3)
        )
    }
}
```

- [ ] **Step 2: Run store tests and confirm failure**

Run: `swift test --filter PatternLibraryStoreTests`

Expected: FAIL because lifecycle APIs do not exist.

- [ ] **Step 3: Implement transactional lifecycle APIs**

Use staged archive arrays for every mutation. `unlinkPattern` flips `isActive` and records `unlinkedAt`; relinking reactivates the same usage and preserves its `sortOrder`. A brand-new usage receives the next stable sort order for that project. Project deletion removes all active and inactive usages plus `Patterns/UsageMarkup/<usageID>`. Permanent pattern deletion throws `.activeLinksExist([UUID])` until all active usages are gone, deletes inactive usages, then removes the asset only if no other `StoredPattern` references it.

- [ ] **Step 4: Move markup ownership to usage IDs**

Replace the old signatures with:

```swift
public func load(usageID: UUID, pageIndex: Int) throws -> PatternMarkupDocument
public func save(_ document: PatternMarkupDocument, usageID: UUID, pageIndex: Int) throws
public func deleteUsageMarkup(usageID: UUID) throws
```

- [ ] **Step 5: Run lifecycle and markup tests**

Run: `swift test --filter PatternLibraryStoreTests`

Run: `swift test --filter PatternMarkupFileServiceTests`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/KnitNoteCore/Projects/JSONProjectStore.swift Sources/KnitNoteCore/Patterns/PatternMarkupFileService.swift Tests/KnitNoteCoreTests/PatternLibraryStoreTests.swift Tests/KnitNoteCoreTests/PatternMarkupFileServiceTests.swift
git commit -m "feat: manage pattern project usages"
```

---

### Task 5: Asset-Keyed Thumbnails and Project Covers

**Files:**
- Modify: `Sources/KnitNoteCore/Patterns/PatternThumbnailFileService.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `KnitNote/Projects/ProjectCoverView.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternThumbnailFileServiceTests.swift`
- Modify: `Tests/KnitNoteCoreTests/ProjectCoverViewContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`

**Interfaces:**
- Consumes: `PatternAsset`.
- Produces: one cached thumbnail per `assetID`.
- Preserves: cover priority `custom photo → first active usage by sortOrder → default icon`.

- [ ] **Step 1: Write failing shared-thumbnail and cover-order tests**

```swift
@Test func twoPatternsForOneAssetUseOneThumbnailPath() {
    let cacheRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let assetID = UUID()
    let service = PatternThumbnailFileService(directory: cacheRoot)
    #expect(service.cachedURL(assetID: assetID) == service.cachedURL(assetID: assetID))
    #expect(service.cachedURL(assetID: assetID).lastPathComponent == "\(assetID.uuidString).jpg")
}

@MainActor @Test func coverUsesFirstActiveUsageAndSkipsInactiveUsage() async throws {
    let harness = try PatternLibraryStoreHarness.coverFixture()
    try harness.store.unlinkPattern(patternID: harness.firstPatternID, from: harness.projectID)
    let url = await harness.store.projectCoverURL(for: harness.project)
    #expect(url == harness.thumbnailURL(for: harness.secondAssetID))
}
```

- [ ] **Step 2: Run focused tests and confirm failure**

Run: `swift test --filter PatternThumbnailFileServiceTests`

Run: `swift test --filter ProjectCoverViewContractTests`

Expected: FAIL on project-keyed thumbnail assumptions.

- [ ] **Step 3: Refactor thumbnail and cover lookup**

Change thumbnail signatures to `thumbnailURL(asset:sourceURL:)`, `cachedURL(assetID:)`, and `delete(assetID:)`. Change `ProjectCoverRevision` to contain `photoFilename`, `firstActiveUsageID`, `assetID`, and `projectCoverGeneration`.

- [ ] **Step 4: Run focused tests**

Run: `swift test --filter PatternThumbnailFileServiceTests`

Run: `swift test --filter ProjectCoverViewContractTests`

Run: `swift test --filter JSONProjectStoreTests`

Expected: PASS, including rotated PDF geometry and restore cache rebuilding.

- [ ] **Step 5: Commit**

```bash
git add Sources/KnitNoteCore/Patterns/PatternThumbnailFileService.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift KnitNote/Projects/ProjectCoverView.swift Tests/KnitNoteCoreTests/PatternThumbnailFileServiceTests.swift Tests/KnitNoteCoreTests/ProjectCoverViewContractTests.swift Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift
git commit -m "feat: share pattern thumbnails and covers"
```

---

### Task 6: Reader Context and Read-Only Mode

**Files:**
- Modify: `KnitNote/Patterns/PatternReaderView.swift`
- Modify: `KnitNote/Patterns/PatternReaderControls.swift`
- Modify: `KnitNote/Patterns/PDFReaderView.swift`
- Modify: `KnitNote/Patterns/ImageReaderView.swift`
- Create: `Tests/KnitNoteCoreTests/PatternReaderContextTests.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternReaderCounterContractTests.swift`

**Interfaces:**
- Produces: `PatternReaderContext.readOnly(patternID:)` and `.project(patternID:usageID:projectID:)`.
- Consumes: asset URL and optional usage state.
- Guarantees: no persistence, markup editing, notes, or counters in read-only mode.

- [ ] **Step 1: Write failing reader-context tests**

```swift
@Test func readOnlyContextHasNoWritableUsage() {
    let context = PatternReaderContext.readOnly(patternID: UUID())
    #expect(context.usageID == nil)
    #expect(context.projectID == nil)
    #expect(!context.canWrite)
}

@Test func completedProjectContextCannotWrite() {
    let context = PatternReaderContext.project(
        patternID: UUID(),
        usageID: UUID(),
        projectID: UUID(),
        projectIsCompleted: true
    )
    #expect(!context.canWrite)
}
```

- [ ] **Step 2: Run reader tests and confirm failure**

Run: `swift test --filter PatternReaderContextTests`

Expected: FAIL because `PatternReaderContext` does not exist.

- [ ] **Step 3: Refactor the reader**

Initialize project contexts from `PatternProjectUsage.readingState`; initialize read-only contexts from a fresh `PatternReadingState`. Guard `save`, note editing, highlight changes, markup mode, and counter controls behind `context.canWrite`. Keep page navigation and zoom available in read-only mode without persisting them.

- [ ] **Step 4: Run reader tests and source contracts**

Run: `swift test --filter PatternReader`

Expected: PASS; existing iPhone/iPad page restoration and layout policies remain green.

- [ ] **Step 5: Commit**

```bash
git add KnitNote/Patterns Tests/KnitNoteCoreTests/PatternReaderContextTests.swift Tests/KnitNoteCoreTests/PatternReaderCounterContractTests.swift
git commit -m "feat: support pattern reader contexts"
```

---

### Task 7: Standalone Library List and Detail

**Files:**
- Replace: `KnitNote/Patterns/PatternLibraryView.swift`
- Create: `KnitNote/Patterns/PatternLibraryRow.swift`
- Create: `KnitNote/Patterns/PatternDetailView.swift`
- Create: `KnitNote/Patterns/PatternLibrarySort.swift`
- Create: `KnitNote/Patterns/ChoosePatternReadingContextView.swift`
- Create: `Tests/KnitNoteCoreTests/PatternLibraryQueryTests.swift`
- Create: `Tests/KnitNoteCoreTests/PatternLibraryViewContractTests.swift`

**Interfaces:**
- Consumes: archive-level patterns, assets, active usages, and projects.
- Produces: query by name/note/active project name and sort by recent/name.
- Produces: detail actions for rename, note, link, export, and guarded permanent delete.
- Produces: `PatternLibraryRowModel` and `PatternLibraryIndex.init(rows:locale:)`.

- [ ] **Step 1: Write failing query and view-contract tests**

```swift
@Test func queryMatchesPatternNoteAndActiveProjectName() throws {
    let index = PatternLibraryIndex(
        rows: [
            .init(
                patternID: UUID(),
                name: "Ida Tee",
                note: "Bought from designer",
                activeProjectNames: ["Blue summer top"],
                createdAt: Date(timeIntervalSince1970: 10)
            )
        ],
        locale: Locale(identifier: "en")
    )
    #expect(index.search("designer").count == 1)
    #expect(index.search("summer").count == 1)
    #expect(index.search("missing").isEmpty)
}

@Test func libraryViewHasNoProjectSectionsOrSwipeDelete() throws {
    let source = try readRepositoryFile("KnitNote/Patterns/PatternLibraryView.swift")
    #expect(!source.contains("Section(group.projectName)"))
    #expect(!source.contains(".swipeActions"))
    #expect(source.contains(".searchable"))
}
```

- [ ] **Step 2: Run library tests and confirm failure**

Run: `swift test --filter PatternLibrary`

Expected: FAIL on the current project-grouped list.

- [ ] **Step 3: Build the simple global list**

Use one `List`, no sections for folders or projects. Each row shows asset thumbnail, full name, file type/page count, and either localized “尚未使用” or the active link count. Add `.searchable` and a menu with `.recentlyAdded` and `.name`; use `localizedStandardCompare` for name sorting. The toolbar `+` opens the existing file importer, enqueues the security-scoped URL with origin `.library`, then processes it through the same durable coordinator as project and Share Extension imports.

- [ ] **Step 4: Build detail and open routing**

The detail page displays thumbnail, full name, kind, PDF page count, byte size, creation date, optional note, and every active linked project. Rename and note edits call the global store APIs; “連結其他作品” can add both active and completed projects; export passes the owned original URL to the system share sheet.

No active usage opens `.readOnly`. One active usage opens directly. Multiple active usages present `ChoosePatternReadingContextView` with each project plus “只閱讀”. The permanent delete button is disabled while active links exist and lists their project names in its explanation.

- [ ] **Step 5: Run query and UI contract tests**

Run: `swift test --filter PatternLibraryQueryTests`

Run: `swift test --filter PatternLibraryViewContractTests`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add KnitNote/Patterns/PatternLibraryView.swift KnitNote/Patterns/PatternLibraryRow.swift KnitNote/Patterns/PatternDetailView.swift KnitNote/Patterns/PatternLibrarySort.swift KnitNote/Patterns/ChoosePatternReadingContextView.swift Tests/KnitNoteCoreTests/PatternLibraryQueryTests.swift Tests/KnitNoteCoreTests/PatternLibraryViewContractTests.swift
git commit -m "feat: build standalone pattern library"
```

---

### Task 8: Project-Side Linking and Import

**Files:**
- Replace: `KnitNote/Patterns/ProjectPatternsView.swift`
- Replace: `KnitNote/Patterns/ChoosePatternProjectView.swift`
- Create: `KnitNote/Patterns/ChooseLibraryPatternView.swift`
- Create: `KnitNote/Patterns/PatternImportResultView.swift`
- Modify: `KnitNote/Projects/ProjectDetailView.swift`
- Create: `Tests/KnitNoteCoreTests/ProjectPatternsViewContractTests.swift`

**Interfaces:**
- Consumes: `linkPattern`, `unlinkPattern`, and durable import outcomes.
- Produces: project `+` menu with exactly “從織圖匣連結” and “匯入新織圖”.
- Guarantees: swipe means unlink, never permanent deletion.

- [ ] **Step 1: Write failing project UI contract tests**

```swift
@Test func projectPatternAddMenuOffersLinkAndImport() throws {
    let source = try readRepositoryFile("KnitNote/Patterns/ProjectPatternsView.swift")
    #expect(source.contains("patterns.linkExisting"))
    #expect(source.contains("patterns.importNew"))
    #expect(source.contains("store.unlinkPattern"))
    #expect(!source.contains("store.deletePattern(projectID:"))
}
```

- [ ] **Step 2: Run the contract test and confirm failure**

Run: `swift test --filter ProjectPatternsViewContractTests`

Expected: FAIL because the current screen imports directly and deletes project-owned files.

- [ ] **Step 3: Implement link/import choices**

`ChooseLibraryPatternView` excludes already active links but includes inactive usages as “重新連結”. Import first enqueues with `targetProjectID`, processes the item, and handles `.created`, `.existing`, or `.needsSelection` without creating duplicate records.

- [ ] **Step 4: Implement unlink confirmation and completed-project behavior**

Swipe calls `unlinkPattern` after a confirmation explaining that reading data remains saved. Completed projects can link/unlink, but the reader context returned by the screen is read-only.

- [ ] **Step 5: Run UI contracts and store lifecycle tests**

Run: `swift test --filter ProjectPatternsViewContractTests`

Run: `swift test --filter PatternLibraryStoreTests`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add KnitNote/Patterns KnitNote/Projects/ProjectDetailView.swift Tests/KnitNoteCoreTests/ProjectPatternsViewContractTests.swift
git commit -m "feat: link library patterns to projects"
```

---

### Task 9: iOS Share Extension

**Files:**
- Create: `KnitNote/KnitNote-iOS.entitlements`
- Create: `KnitNoteShare/KnitNoteShare.entitlements`
- Create: `KnitNoteShare/Info.plist`
- Create: `KnitNoteShare/ShareViewController.swift`
- Create: `KnitNoteShare/ShareImportView.swift`
- Create: `KnitNoteShare/Localizable.xcstrings`
- Create: `KnitNoteShare/PrivacyInfo.xcprivacy`
- Modify: `project.yml`
- Regenerate: `KnitNote.xcodeproj/project.pbxproj`
- Create: `Tests/KnitNoteCoreTests/ShareExtensionContractTests.swift`

**Interfaces:**
- Consumes: `PatternInboxFileService` with App Group root.
- Produces: extension bundle `com.phillon.KnitNote.share`.
- Uses: App Group `group.com.phillon.KnitNote`.

- [ ] **Step 1: Write failing target and activation-rule contracts**

```swift
@Test func shareExtensionAcceptsOnlySupportedFiles() throws {
    let project = try readRepositoryFile("project.yml")
    let plist = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: patternLibraryRepositoryURL("KnitNoteShare/Info.plist")),
        format: nil
    ) as? [String: Any]
    #expect(project.contains("PRODUCT_BUNDLE_IDENTIFIER: com.phillon.KnitNote.share"))
    #expect(project.contains("group.com.phillon.KnitNote"))
    #expect(plist != nil)
}
```

- [ ] **Step 2: Run the contract and confirm failure**

Run: `swift test --filter ShareExtensionContractTests`

Expected: FAIL because the extension target is absent.

- [ ] **Step 3: Add App Group entitlements and extension target**

Add `com.apple.security.application-groups = ["group.com.phillon.KnitNote"]` to both iOS app and extension. Configure `NSExtensionPointIdentifier = com.apple.share-services` and an activation rule for one PDF or image attachment. Keep the macOS target on its existing entitlement file.

Add this XcodeGen target shape, with the app embedding the extension:

```yaml
KnitNoteShare:
  type: app-extension
  platform: iOS
  info:
    path: KnitNoteShare/Info.plist
  sources:
    - path: KnitNoteShare
    - path: Sources/KnitNoteCore
  settings:
    base:
      PRODUCT_BUNDLE_IDENTIFIER: com.phillon.KnitNote.share
      CODE_SIGN_ENTITLEMENTS: KnitNoteShare/KnitNoteShare.entitlements
```

Add `target: KnitNoteShare`, `embed: true`, and `platformFilter: iOS` to the `KnitNote` dependencies. Set the iPhone app's `CODE_SIGN_ENTITLEMENTS` for iPhone device and simulator SDKs to `KnitNote/KnitNote-iOS.entitlements` without changing `KnitNote/KnitNote-macOS.entitlements`.

- [ ] **Step 4: Implement the extension UI and enqueue flow**

Load the first `NSItemProvider` file representation, acquire security scope, enqueue it with `.shareExtension`, show localized success, unsupported, too-large, or access errors, and always finish using `extensionContext.completeRequest` or `cancelRequest`. Do not open the host App.

- [ ] **Step 5: Regenerate and verify the project**

Run: `xcodegen generate`

Run: `plutil -lint KnitNoteShare/Info.plist KnitNote/KnitNote-iOS.entitlements KnitNoteShare/KnitNoteShare.entitlements KnitNoteShare/PrivacyInfo.xcprivacy`

Run: `swift test --filter ShareExtensionContractTests`

Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add KnitNote/KnitNote-iOS.entitlements KnitNoteShare project.yml KnitNote.xcodeproj Tests/KnitNoteCoreTests/ShareExtensionContractTests.swift
git commit -m "feat: add pattern share extension"
```

---

### Task 10: Main-App Inbox Processing

**Files:**
- Create: `KnitNote/Patterns/PatternInboxProcessor.swift`
- Create: `KnitNote/Patterns/PendingPatternSelectionView.swift`
- Modify: `KnitNote/App/KnitNoteApp.swift`
- Modify: `KnitNote/App/RootView.swift`
- Create: `Tests/KnitNoteCoreTests/PatternInboxProcessorTests.swift`
- Create: `Tests/KnitNoteCoreTests/PatternInboxPresentationContractTests.swift`

**Interfaces:**
- Consumes: all inbox items in received-time order.
- Produces: foreground processing, nonblocking result banner, and blocking selection only for ambiguous migrated duplicates.
- Guarantees: serial, idempotent processing and no duplicate publication across foreground events.
- Produces: `PatternInboxProcessing` protocol and injected `PatternInboxDriver` actor used by the processor tests.

- [ ] **Step 1: Write failing serial-processing and retry tests**

```swift
@MainActor @Test func foregroundProcessingDoesNotStartTwoRuns() async throws {
    let driver = PatternInboxDriver(
        processingDelay: .milliseconds(50),
        pendingItemIDs: [UUID()]
    )
    let processor = PatternInboxProcessor(driver: driver)
    async let first: Void = processor.processPending()
    async let second: Void = processor.processPending()
    _ = await (first, second)
    #expect(driver.maximumConcurrentRuns == 1)
    #expect(driver.processedItemIDs.count == 1)
}
```

- [ ] **Step 2: Run processor tests and confirm failure**

Run: `swift test --filter PatternInboxProcessorTests`

Expected: FAIL because no foreground processor exists.

- [ ] **Step 3: Implement foreground processing**

Create one `@MainActor ObservableObject` processor in `KnitNoteApp`, inject it into `RootView`, invoke it on initial appearance and every `.active` scene phase, and retain `.needsSelection` items until `PendingPatternSelectionView` calls processing again with the selected pattern ID.

- [ ] **Step 4: Add nonblocking results**

Publish a short-lived `PatternInboxNotice` for created, duplicate, rejected, and retryable failures. Present it as an accessible overlay without changing the selected tab.

- [ ] **Step 5: Run processor and presentation tests**

Run: `swift test --filter PatternInbox`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add KnitNote/Patterns/PatternInboxProcessor.swift KnitNote/Patterns/PendingPatternSelectionView.swift KnitNote/App/KnitNoteApp.swift KnitNote/App/RootView.swift Tests/KnitNoteCoreTests/PatternInboxProcessorTests.swift Tests/KnitNoteCoreTests/PatternInboxPresentationContractTests.swift
git commit -m "feat: process shared patterns on foreground"
```

---

### Task 11: Backup Manifest 2 and Pattern Round Trips

**Files:**
- Modify: `Sources/KnitNoteCore/Backup/KnitNoteBackupManifest.swift`
- Modify: `Sources/KnitNoteCore/Backup/KnitNoteBackupService.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Tests/KnitNoteCoreTests/KnitNoteBackupManifestTests.swift`
- Modify: `Tests/KnitNoteCoreTests/KnitNoteBackupServiceTests.swift`
- Modify: `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`

**Interfaces:**
- Produces: manifest format 2 with `patternCount`; `KnitNoteBackupPreview.patternCount` is `Int?`, `nil` for format 1 and exact for format 2.
- Preserves: format 1 preview and restore.
- Includes: assets and usage markup; excludes inbox and thumbnail cache.
- Test fixture: `BackupPatternHarness` extends `PatternLibraryStoreHarness` with package export, destructive live-data mutation, restore, reload, and markup reads.

- [ ] **Step 1: Write failing manifest compatibility and mutation-backed round-trip tests**

```swift
@Test func formatTwoPreviewIncludesPatternCount() throws {
    let date = Date(timeIntervalSince1970: 1_750_000_000)
    let manifest = KnitNoteBackupManifest(
        formatVersion: 2,
        createdAt: date,
        appVersion: "1.2.0",
        projectCount: 2,
        yarnCount: 3,
        patternCount: 4
    )
    #expect(try manifest.preview().patternCount == 4)
}

@MainActor @Test func backupRoundTripRestoresInactiveUsageAndMarkup() async throws {
    let harness = try BackupPatternHarness()
    try harness.createPatternUsageThenUnlink()
    let package = try await harness.store.exportBackup(appVersion: "1.2.0")
    try harness.destroyLivePatternData()
    try await harness.restore(package)
    #expect(harness.reloadedStore.patternUsages.first?.isActive == false)
    #expect(try harness.reloadedMarkup().strokes.count == 1)
}
```

- [ ] **Step 2: Run backup tests and confirm failure**

Run: `swift test --filter KnitNoteBackup`

Expected: FAIL because manifest 2 and asset-level references are absent.

- [ ] **Step 3: Add format 2 while preserving format 1**

Decode missing `patternCount` as `nil`. `preview()` accepts formats 1 and 2, returns `nil` for format 1, returns the exact nonnegative value for format 2, and rejects versions greater than 2 or negative counts.

- [ ] **Step 4: Validate the schema 10 tree**

`referencedRelativePaths` must include `Patterns/Assets/<storedFilename>` and all existing `Patterns/UsageMarkup/<usageID>/<page>.json`. Reject missing assets, orphan archive references, unsafe paths, duplicate identifiers, and invalid markup. Do not include `.KnitNote-PatternThumbnailCache` or App Group inbox paths.

- [ ] **Step 5: Run all backup and store tests**

Run: `swift test --filter KnitNoteBackup`

Run: `swift test --filter JSONProjectStoreTests`

Expected: PASS, including old format 1 restore followed by schema 10 migration.

- [ ] **Step 6: Commit**

```bash
git add Sources/KnitNoteCore/Backup Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/KnitNoteBackupManifestTests.swift Tests/KnitNoteCoreTests/KnitNoteBackupServiceTests.swift Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift
git commit -m "feat: back up pattern library data"
```

---

### Task 12: Backup Reminder and Last Successful Date

**Files:**
- Create: `Sources/KnitNoteCore/Backup/BackupHistory.swift`
- Modify: `KnitNote/Settings/BackupSettingsSection.swift`
- Modify: `KnitNote/Patterns/PatternLibraryView.swift`
- Create: `Tests/KnitNoteCoreTests/BackupHistoryTests.swift`
- Modify: `Tests/KnitNoteCoreTests/BackupSettingsViewContractTests.swift`

**Interfaces:**
- Produces: `BackupHistory.lastSuccessfulExportAt` and `hasShownPatternReminder`.
- Updates the date only after `.fileExporter` reports success.
- Shows the local-only reminder once, after the first successful pattern collection.

- [ ] **Step 1: Write failing persistence and cancellation tests**

```swift
@Test func cancelledExportDoesNotChangeLastSuccessfulDate() {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    var history = BackupHistory(defaults: defaults)
    history.recordExportResult(.cancelled, at: Date(timeIntervalSince1970: 100))
    #expect(history.lastSuccessfulExportAt == nil)
    history.recordExportResult(.success, at: Date(timeIntervalSince1970: 200))
    #expect(history.lastSuccessfulExportAt == Date(timeIntervalSince1970: 200))
}
```

- [ ] **Step 2: Run history tests and confirm failure**

Run: `swift test --filter BackupHistoryTests`

Expected: FAIL because `BackupHistory` does not exist.

- [ ] **Step 3: Implement history and UI**

Persist dates as seconds since 1970 under `backup.lastSuccessfulExportAt`. In `finishExport`, record success only for `.success`; do not record when package creation succeeds but exporter is cancelled or fails. Display a localized “上次成功備份” row in Settings. After the first `.created` import only, show one alert explaining local storage and linking to Settings; set `patterns.backupReminderShown` when dismissed.

- [ ] **Step 4: Run history and settings tests**

Run: `swift test --filter BackupHistoryTests`

Run: `swift test --filter BackupSettingsViewContractTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/KnitNoteCore/Backup/BackupHistory.swift KnitNote/Settings/BackupSettingsSection.swift KnitNote/Patterns/PatternLibraryView.swift Tests/KnitNoteCoreTests/BackupHistoryTests.swift Tests/KnitNoteCoreTests/BackupSettingsViewContractTests.swift
git commit -m "feat: show pattern backup history"
```

---

### Task 13: Localization, Accessibility, and Responsive Layout

**Files:**
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `KnitNoteShare/Localizable.xcstrings`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternLibraryViewContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/ProjectDetailLayoutContractTests.swift`

**Interfaces:**
- Consumes: all new localization keys introduced in Tasks 7–12.
- Produces: Traditional Chinese and English values for every key.
- Guarantees: row status is not color-only and VoiceOver reads name, type, page count, and active link count.

- [ ] **Step 1: Extend localization contract tests**

Require both `en` and `zh-Hant` values for keys in these namespaces:

```swift
let requiredPrefixes = [
    "patterns.library.",
    "patterns.detail.",
    "patterns.import.",
    "patterns.link.",
    "patterns.unlink.",
    "patterns.share.",
    "patterns.backup.",
    "backup.lastSuccessful.",
]
```

Also assert that no new visible key uses an empty value and that pattern row labels expose a composed accessibility label rather than color alone.

- [ ] **Step 2: Run localization contracts and confirm failure**

Run: `swift test --filter LocalizationContractTests`

Expected: FAIL with the newly required keys.

- [ ] **Step 3: Add exact Traditional Chinese and English copy**

Add concise single-line labels for import, link, unlink, read-only, duplicate selection, permanent deletion protection, inbox results, local backup reminder, last backup date, and empty state. Preserve all pre-existing user edits in the catalog; resolve the worktree merge by adding keys rather than replacing the file.

- [ ] **Step 4: Verify small and large layouts**

Add contracts ensuring library rows use flexible text with one-line status, iPhone actions remain reachable, iPad detail content does not exceed readable width, and macOS toolbars keep text labels. Confirm Dynamic Type does not hide import, link, or delete actions.

- [ ] **Step 5: Run localization and layout tests**

Run: `swift test --filter LocalizationContractTests`

Run: `swift test --filter PatternLibraryViewContractTests`

Run: `swift test --filter ProjectDetailLayoutContractTests`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add KnitNote/Localization/Localizable.xcstrings KnitNoteShare/Localizable.xcstrings Tests/KnitNoteCoreTests/LocalizationContractTests.swift Tests/KnitNoteCoreTests/PatternLibraryViewContractTests.swift Tests/KnitNoteCoreTests/ProjectDetailLayoutContractTests.swift
git commit -m "feat: localize pattern library"
```

---

### Task 14: Full Verification and Release Documentation

**Files:**
- Modify: `AppStore/AppStoreSubmission.md`
- Create: `AppStore/Verification/PatternLibraryVerification.md`
- Modify: `AppStore/Verification/release_audit.sh`
- Modify: `project.yml`
- Regenerate: `KnitNote.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: all preceding tasks.
- Produces: reproducible automated and manual verification evidence for iPhone, iPad, macOS, Share Extension, migration, and backup.

- [ ] **Step 1: Run a clean Swift test suite**

Run: `rm -rf /tmp/KnitNotePatternLibraryDerivedData`

Run: `swift test`

Expected: all tests PASS with no skipped pattern-library tests.

- [ ] **Step 2: Run clean iOS and macOS builds**

Run:

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/KnitNotePatternLibraryDerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Run:

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/KnitNotePatternLibraryDerivedData-macOS \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: both end with `** BUILD SUCCEEDED **`; iOS build embeds `KnitNoteShare.appex`.

- [ ] **Step 3: Run static release checks**

Set the app and Share Extension marketing version to `1.2.0`, keep their build numbers equal, then run `xcodegen generate`.

Run: `bash AppStore/Verification/release_audit.sh`

Run: `git diff --check`

Expected: PASS with schema 10, manifest 2, App Group entitlements, privacy manifest, and localization checks.

- [ ] **Step 4: Perform device-matrix manual verification**

Record results in `AppStore/Verification/PatternLibraryVerification.md` for:

1. iPhone portrait: import from Files and Share Extension, search, duplicate handling, link/unlink/relink, read-only open.
2. iPad portrait and landscape: readable PDF size, page controls clear of content, highlight and markup per linked project.
3. macOS: import, search, sort, detail, export original.
4. Completed project: link/unlink allowed, all reader writes blocked.
5. Legacy schema 9 fixture: names, ordering, page state, page notes, markup, and cover survive.
6. Backup format 2 round trip and format 1 restore: inactive usage and markup survive; inbox and thumbnails do not.
7. VoiceOver: row name, type, page count, link count, buttons, errors, and selection sheet are understandable.

- [ ] **Step 5: Request two-stage code review**

Use `superpowers:requesting-code-review` for:

1. Spec compliance review against `docs/superpowers/specs/2026-07-26-pattern-library-design.md`.
2. Code quality, migration safety, transaction boundaries, and accessibility review.

Resolve every blocker and rerun Steps 1–3 after the final code change.

- [ ] **Step 6: Commit verification records**

```bash
git add AppStore/AppStoreSubmission.md AppStore/Verification/PatternLibraryVerification.md AppStore/Verification/release_audit.sh project.yml KnitNote.xcodeproj
git commit -m "docs: verify pattern library release"
```

- [ ] **Step 7: Finish the development branch**

Use `superpowers:verification-before-completion`, then `superpowers:finishing-a-development-branch`. Present the verified integration options without deleting or overwriting the user's dirty main-worktree files.
