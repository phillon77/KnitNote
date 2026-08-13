# Pattern Folders Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add safe single-level user-created folders to the Pattern Library, with one optional folder per pattern, an adaptive sidebar/drill-down interface, atomic mutations, backup support, and complete 13-language accessibility copy.

**Architecture:** Add `PatternFolder` as a first-class archive entity and `folderID: UUID?` to `StoredPattern`; `nil` is the system Uncategorized collection while All remains a virtual query. Keep folder CRUD and pattern movement inside `JSONProjectStore` atomic archive writes, carry an optional destination through inbox/YouTube import publication, and present one `NavigationSplitView` that collapses to folder-first navigation on iPhone.

**Tech Stack:** Swift 6, SwiftUI, Combine, Foundation Codable, Swift Testing, Apple String Catalogs, XcodeGen, Xcode 26.

## Global Constraints

- A pattern belongs to at most one user folder; `folderID == nil` means system Uncategorized.
- All and Uncategorized are virtual system collections, never persisted as deletable folders.
- Folders are single-level; do not add tags, nested folders, bulk movement, CloudKit, or sharing.
- Deleting a nonempty folder atomically moves every referenced pattern to Uncategorized before removing the folder.
- Existing pattern assets, names, notes, project usages, reader state, page notes, highlights, markup, thumbnails, and original files must remain unchanged.
- User-entered pattern and folder names are never translated or rewritten.
- All new App copy must exist in the existing 13 shipping locales: `en`, `zh-Hant`, `zh-Hans`, `de`, `fr`, `ja`, `nb`, `sv`, `fi`, `da`, `ko`, `el`, `nl`.
- Store validation and persistence failures publish no partial memory, archive, generation, selection, or navigation change.
- Do not change version, Build, signing, release scripts, App Store metadata, archive, upload, submission, or release state.
- Physical iPhone, iPad, Mac, VoiceOver, Dynamic Type, orientation, and data-preservation checks remain explicit acceptance gates.

---

### Task 1: Define folder domain models and scoped Pattern Library queries

**Files:**
- Create: `Sources/KnitNoteCore/Patterns/PatternFolder.swift`
- Modify: `Sources/KnitNoteCore/Patterns/PatternLibraryIndex.swift`
- Create: `Tests/KnitNoteCoreTests/PatternFolderModelTests.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternLibraryQueryTests.swift`

**Interfaces:**
- Produces: `PatternFolder(id:displayName:createdAt:)`.
- Produces: `PatternLibraryScope.all`, `.uncategorized`, and `.folder(UUID)`.
- Produces: `PatternFolderNameContext(locale:reservedNames:)` and `PatternFolderNamePolicy.validatedName(_:folders:excluding:nameContext:)`.
- Produces: `PatternLibraryIndex.rows(in:sortedBy:)` and `search(_:in:sortedBy:)`.
- Consumed later by: archive validation, `JSONProjectStore`, sidebar presentation, and import destination selection.

- [ ] **Step 1: Write failing model and name-policy tests**

Create tests covering stable identity, Codable round trip, whitespace trimming, empty rejection, case/diacritic-insensitive duplicate rejection, exclusion of the folder being renamed, and reserved names across locales:

```swift
import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct PatternFolderModelTests {
    private let context = PatternFolderNameContext(
        locale: Locale(identifier: "zh-Hant"),
        reservedNames: ["全部", "未分類", "All", "Uncategorized"]
    )

    @Test func folderRoundTripsWithoutChangingUserCopy() throws {
        let folder = PatternFolder(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            displayName: "  毛衣 / Sweaters  ",
            createdAt: Date(timeIntervalSince1970: 123)
        )
        let decoded = try JSONDecoder().decode(
            PatternFolder.self,
            from: JSONEncoder().encode(folder)
        )
        #expect(decoded == folder)
        #expect(decoded.displayName == "  毛衣 / Sweaters  ")
    }

    @Test func policyTrimsAndRejectsEmptyDuplicateAndReservedNames() throws {
        let existing = PatternFolder(displayName: "Café", createdAt: .distantPast)
        #expect(try PatternFolderNamePolicy.validatedName(
            "  Socks  ", folders: [existing], excluding: nil, nameContext: context
        ) == "Socks")
        #expect(throws: PatternFolderValidationError.emptyName) {
            try PatternFolderNamePolicy.validatedName(
                " \n ", folders: [existing], excluding: nil, nameContext: context
            )
        }
        #expect(throws: PatternFolderValidationError.duplicateName) {
            try PatternFolderNamePolicy.validatedName(
                "CAFE", folders: [existing], excluding: nil, nameContext: context
            )
        }
        #expect(throws: PatternFolderValidationError.reservedName) {
            try PatternFolderNamePolicy.validatedName(
                "All", folders: [existing], excluding: nil, nameContext: context
            )
        }
        #expect(try PatternFolderNamePolicy.validatedName(
            "Café", folders: [existing], excluding: existing.id, nameContext: context
        ) == "Café")
    }
}
```

- [ ] **Step 2: Write failing scope/query tests**

Extend `PatternLibraryRowModel` test fixtures with `folderID: UUID?`, then add:

```swift
@Test func queryScopesAllUncategorizedAndOneFolderBeforeSearching() {
    let sweaters = UUID()
    let rows = [
        row(name: "Alpha", folderID: sweaters),
        row(name: "Beta", folderID: nil),
        row(name: "Gamma", folderID: UUID()),
    ]
    let index = PatternLibraryIndex(rows: rows, locale: Locale(identifier: "en"))

    #expect(index.rows(in: .all, sortedBy: .name).map(\.name) == ["Alpha", "Beta", "Gamma"])
    #expect(index.rows(in: .uncategorized, sortedBy: .name).map(\.name) == ["Beta"])
    #expect(index.rows(in: .folder(sweaters), sortedBy: .name).map(\.name) == ["Alpha"])
    #expect(index.search("Gamma", in: .folder(sweaters), sortedBy: .name).isEmpty)
    #expect(index.search("Gamma", in: .all, sortedBy: .name).map(\.name) == ["Gamma"])
}

private func row(name: String, folderID: UUID?) -> PatternLibraryRowModel {
    PatternLibraryRowModel(
        patternID: UUID(),
        name: name,
        note: nil,
        activeProjectNames: [],
        createdAt: .distantPast,
        folderID: folderID
    )
}
```

- [ ] **Step 3: Run focused tests and witness RED**

Run:

```bash
swift test --disable-sandbox --filter 'PatternFolderModelTests|PatternLibraryQueryTests'
```

Expected: compilation fails because `PatternFolder`, `PatternLibraryScope`, the folder-name policy, and scoped query methods do not exist.

- [ ] **Step 4: Implement the domain types**

Create `PatternFolder.swift` with these public interfaces:

```swift
import Foundation

public struct PatternFolder: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String
    public let createdAt: Date

    public init(id: UUID = UUID(), displayName: String, createdAt: Date = .now) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
    }
}

public enum PatternLibraryScope: Hashable, Sendable {
    case all
    case uncategorized
    case folder(UUID)
}

public struct PatternFolderNameContext: Sendable {
    public let locale: Locale
    public let reservedNames: Set<String>

    public init(locale: Locale, reservedNames: Set<String>) {
        self.locale = locale
        self.reservedNames = reservedNames
    }
}

public enum PatternFolderValidationError: Error, Equatable, Sendable {
    case emptyName
    case duplicateName
    case reservedName
}

public enum PatternFolderNamePolicy {
    public static func validatedName(
        _ proposed: String,
        folders: [PatternFolder],
        excluding excludedID: UUID?,
        nameContext: PatternFolderNameContext
    ) throws -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PatternFolderValidationError.emptyName }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        func matches(_ value: String) -> Bool {
            value.compare(trimmed, options: options, locale: nameContext.locale) == .orderedSame
        }
        guard !nameContext.reservedNames.contains(where: matches) else {
            throw PatternFolderValidationError.reservedName
        }
        guard !folders.contains(where: { $0.id != excludedID && matches($0.displayName) }) else {
            throw PatternFolderValidationError.duplicateName
        }
        return trimmed
    }
}
```

- [ ] **Step 5: Implement scoped query behavior**

Add `folderID` to `PatternLibraryRowModel`, keep the old sorting behavior, and filter before search:

```swift
public func rows(
    in scope: PatternLibraryScope,
    sortedBy sort: PatternLibrarySort
) -> [PatternLibraryRowModel] {
    sourceRows.filter { row in
        switch scope {
        case .all: true
        case .uncategorized: row.folderID == nil
        case let .folder(folderID): row.folderID == folderID
        }
    }.sorted { lhs, rhs in
        switch sort {
        case .recentlyAdded:
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
        case .name:
            break
        }
        let order = localizedStandardCompare(lhs.name, rhs.name)
        if order != .orderedSame {
            return order == .orderedAscending
        }
        return lhs.patternID.uuidString < rhs.patternID.uuidString
    }
}

public func search(
    _ query: String,
    in scope: PatternLibraryScope,
    sortedBy sort: PatternLibrarySort = .recentlyAdded
) -> [PatternLibraryRowModel] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return rows(in: scope, sortedBy: sort).filter { row in
        guard !trimmed.isEmpty else { return true }
        return matches(row.name, query: trimmed)
            || row.note.map { matches($0, query: trimmed) } == true
            || row.activeProjectNames.contains { matches($0, query: trimmed) }
    }
}
```

Retain compatibility overloads `rows(sortedBy:)` and `search(_:sortedBy:)` delegating to `.all` until UI call sites move in Task 5.

- [ ] **Step 6: Run GREEN and commit**

Run:

```bash
swift test --disable-sandbox --filter 'PatternFolderModelTests|PatternLibraryQueryTests|PatternLibraryModelTests'
git diff --check
git add Sources/KnitNoteCore/Patterns/PatternFolder.swift Sources/KnitNoteCore/Patterns/PatternLibraryIndex.swift Tests/KnitNoteCoreTests/PatternFolderModelTests.swift Tests/KnitNoteCoreTests/PatternLibraryQueryTests.swift
git commit -m "feat: define pattern folder domain"
```

Expected: selected tests pass and the commit contains no archive/store/UI changes.

---

### Task 2: Add archive schema 13, migration, normalization, and backup validation

**Files:**
- Modify: `Sources/KnitNoteCore/Patterns/StoredPattern.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Sources/KnitNoteCore/Patterns/PatternLibraryMigrator.swift`
- Modify: `Sources/KnitNoteCore/Backup/KnitNoteBackupService.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternLibraryModelTests.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternLibraryMigrationTests.swift`
- Modify: `Tests/KnitNoteCoreTests/KnitNoteBackupServiceTests.swift`
- Modify: `Tests/KnitNoteCoreTests/ReleaseConfigurationContractTests.swift`

**Interfaces:**
- Consumes: `PatternFolder` from Task 1.
- Produces: `StoredPattern.folderID: UUID?`.
- Produces: `ProjectArchive.patternFolders: [PatternFolder]`, `currentVersion == 13`, and `patternFoldersIntroducedVersion == 13`.
- Produces: `PatternLibrarySnapshot(folders:assets:patterns:usages:validProjectIDs:)` and `normalizedAndValidated()`.
- Consumed later by: store CRUD, backup restore, import publication, and UI.

- [ ] **Step 1: Write failing archive/model tests**

Add tests that require schema 13, folder round trip, schema-12 default empty folders, and orphan normalization:

```swift
@Test func schemaThirteenRoundTripsFoldersAndPatternMembership() throws {
    let folder = PatternFolder(displayName: "Sweaters")
    let asset = PatternAsset(
        id: UUID(), sha256: String(repeating: "a", count: 64), kind: .pdf,
        storedFilename: "fixture.pdf", byteCount: 4, pageCount: 1
    )
    let pattern = StoredPattern(assetID: asset.id, displayName: "Cardigan", folderID: folder.id)
    let archive = ProjectArchive(
        version: 13,
        projects: [],
        patternFolders: [folder],
        patternAssets: [asset],
        patterns: [pattern]
    )
    let decoded = try JSONDecoder().decode(ProjectArchive.self, from: JSONEncoder().encode(archive))
    #expect(decoded.patternFolders == [folder])
    #expect(decoded.patterns.first?.folderID == folder.id)
}

@Test func snapshotNormalizesAnOrphanFolderReferenceWithoutDroppingThePattern() throws {
    let asset = PatternAsset(
        id: UUID(), sha256: String(repeating: "b", count: 64), kind: .pdf,
        storedFilename: "fixture.pdf", byteCount: 4, pageCount: 1
    )
    let pattern = StoredPattern(assetID: asset.id, displayName: "Kept", folderID: UUID())
    let normalized = try PatternLibrarySnapshot(
        folders: [], assets: [asset], patterns: [pattern], usages: [], validProjectIDs: []
    ).normalizedAndValidated()
    #expect(normalized.patterns.map(\.displayName) == ["Kept"])
    #expect(normalized.patterns.first?.folderID == nil)
}
```

Use existing fixture constructors in the test file rather than introducing a second production fixture API.

- [ ] **Step 2: Write failing migration and backup tests**

Add tests that load a real schema-12 JSON archive without folder keys, migrate it to 13, and round-trip a schema-13 backup:

```swift
@Test func schemaTwelveMigrationPreservesEveryPatternOwnedByteAndUsage() throws {
    let fixture = try SchemaTenPatternLibraryFixture.make(version: 12)
    try PatternLibraryMigrator().migrateOnDisk(archiveURL: fixture.archiveURL)
    let archive = try JSONDecoder().decode(
        ProjectArchive.self,
        from: Data(contentsOf: fixture.archiveURL)
    )
    #expect(archive.version == 13)
    #expect(archive.patternFolders.isEmpty)
    #expect(archive.patterns.allSatisfy { $0.folderID == nil })
    #expect(try Data(contentsOf: fixture.assetURL) == fixture.assetData)
    #expect(try Data(contentsOf: fixture.markupURL) == fixture.markupData)
    #expect(archive.patternAssets == [fixture.asset])
    #expect(archive.patterns.map(\.id) == [fixture.pattern.id])
    #expect(archive.patternUsages == [fixture.usage])
}
```

Change `SchemaTenPatternLibraryFixture.make()` to `make(version: Int = 10)` and pass `version` to its `ProjectArchive` initializer. In backup tests, require duplicate folder IDs to throw `duplicateIdentifier`, orphan membership to normalize without losing the pattern during store load, and export/restore to preserve a valid folder ID.

- [ ] **Step 3: Run schema tests and witness RED**

Run:

```bash
swift test --disable-sandbox --filter 'PatternLibraryModelTests|PatternLibraryMigrationTests|KnitNoteBackupServiceTests|ReleaseConfigurationContractTests'
```

Expected: failures identify missing folder fields, current schema 12, and absent backup validation.

- [ ] **Step 4: Extend `StoredPattern` and snapshot validation**

Add the optional member and backward-compatible Codable handling:

```swift
public var folderID: UUID?

public init(
    id: UUID = UUID(),
    assetID: UUID,
    displayName: String,
    note: String? = nil,
    createdAt: Date = .now,
    lastOpenedAt: Date? = nil,
    prefersOriginalColorsInDarkMode: Bool = false,
    folderID: UUID? = nil
) {
    self.id = id
    self.assetID = assetID
    self.displayName = displayName
    self.note = note
    self.createdAt = createdAt
    self.lastOpenedAt = lastOpenedAt
    self.prefersOriginalColorsInDarkMode = prefersOriginalColorsInDarkMode
    self.folderID = folderID
}
```

Add `folderID` to `CodingKeys`, use `decodeIfPresent`, and encode only when non-nil. Extend `PatternLibraryValidationError` with `duplicateFolderID`; extend `PatternLibrarySnapshot` with `folders` and implement:

```swift
public func normalizedAndValidated() throws -> PatternLibrarySnapshot {
    guard Set(folders.map(\.id)).count == folders.count else {
        throw PatternLibraryValidationError.duplicateFolderID
    }
    let folderIDs = Set(folders.map(\.id))
    let normalizedPatterns = patterns.map { pattern in
        var pattern = pattern
        if let folderID = pattern.folderID, !folderIDs.contains(folderID) {
            pattern.folderID = nil
        }
        return pattern
    }
    return try PatternLibrarySnapshot(
        folders: folders,
        assets: assets,
        patterns: normalizedPatterns,
        usages: usages,
        validProjectIDs: validProjectIDs
    ).validatedReferences()
}
```

Keep duplicate folder IDs fail-closed; only missing folder references normalize.

Rename the current asset/pattern/usage/project validation body to the private helper `validatedReferences()`. Keep the public compatibility entry point exact and normalization-aware:

```swift
public func validated() throws -> PatternLibrarySnapshot {
    try normalizedAndValidated()
}
```

This prevents existing callers from bypassing orphan-folder normalization while keeping their source signatures stable.

- [ ] **Step 5: Bump and migrate `ProjectArchive`**

Change the archive interface to:

```swift
public static let currentVersion = 13
public static let patternFoldersIntroducedVersion = 13
public var patternFolders: [PatternFolder]
```

Add `patternFolders` to the initializer with default `[]`, CodingKeys, decoder with `decodeIfPresent`, and encoder. In `PatternLibraryMigrator.makeArchive`, copy valid existing folders for schema 13 and use `[]` for older archives; set every pre-13 pattern `folderID` to `nil`; create the migrated archive with `version: 13`.

- [ ] **Step 6: Update backup validation and release contracts**

In `KnitNoteBackupService.validateArchive`, include folder IDs in duplicate checks and call `normalizedAndValidated()`. Update every exhaustive `PatternLibraryValidationError` switch to map `.duplicateFolderID` to `KnitNoteBackupError.duplicateIdentifier`. Update `ReleaseConfigurationContractTests` to require `currentVersion = 13`.

- [ ] **Step 7: Run focused GREEN and commit**

Run:

```bash
swift test --disable-sandbox --filter 'PatternLibraryModelTests|PatternLibraryMigrationTests|KnitNoteBackupServiceTests|ReleaseConfigurationContractTests'
git diff --check
git add Sources/KnitNoteCore/Patterns/StoredPattern.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift Sources/KnitNoteCore/Patterns/PatternLibraryMigrator.swift Sources/KnitNoteCore/Backup/KnitNoteBackupService.swift Tests/KnitNoteCoreTests/PatternLibraryModelTests.swift Tests/KnitNoteCoreTests/PatternLibraryMigrationTests.swift Tests/KnitNoteCoreTests/KnitNoteBackupServiceTests.swift Tests/KnitNoteCoreTests/ReleaseConfigurationContractTests.swift
git commit -m "feat: persist pattern folder membership"
```

Expected: old schemas remain readable, schema 13 round-trips, valid folder relationships survive backup, and orphan membership keeps the pattern as Uncategorized.

---

### Task 3: Implement atomic folder CRUD and pattern movement in the store

**Files:**
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternLibraryStoreTests.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternLibraryTestSupport.swift`

**Interfaces:**
- Consumes: schema-13 folder collection and name policy.
- Produces: published `patternFolders: [PatternFolder]`.
- Produces: `createPatternFolder(name:nameContext:now:)`, `renamePatternFolder(id:to:nameContext:)`, `movePattern(id:toFolderID:)`, and `deletePatternFolder(id:)`.
- Produces: `PatternFolderStoreError.folderNotFound` and `.patternNotFound` for stale identities.
- Consumed later by: folder editor, context menus, move sheet, sidebar counts.

- [ ] **Step 1: Write failing success-path transaction tests**

Add one test for each public API and assert archive plus memory plus generation:

```swift
@MainActor @Test func createRenameMoveAndDeleteFolderAreAtomic() async throws {
    let harness = try PatternImportHarness()
    let source = try harness.makePDF(named: "Cardigan.pdf")
    let outcome = try await harness.store.importPatternFromLibrary(source)
    guard case let .created(patternID) = outcome else {
        Issue.record("Expected a newly created pattern")
        return
    }
    let context = PatternFolderNameContext(
        locale: Locale(identifier: "en"),
        reservedNames: ["All", "Uncategorized"]
    )
    let initialGeneration = harness.store.dataGeneration

    let folder = try harness.store.createPatternFolder(
        name: " Sweaters ", nameContext: context, now: Date(timeIntervalSince1970: 10)
    )
    #expect(folder.displayName == "Sweaters")
    #expect(harness.store.dataGeneration == initialGeneration + 1)

    try harness.store.renamePatternFolder(id: folder.id, to: "Pullovers", nameContext: context)
    try harness.store.movePattern(id: patternID, toFolderID: folder.id)
    let movedCount = try harness.store.deletePatternFolder(id: folder.id)

    #expect(movedCount == 1)
    #expect(harness.store.patternFolders.isEmpty)
    #expect(harness.store.patterns.first(where: { $0.id == patternID })?.folderID == nil)
    let archive = try JSONDecoder().decode(
        ProjectArchive.self,
        from: Data(contentsOf: harness.archiveURL)
    )
    #expect(archive.patterns.first(where: { $0.id == patternID })?.folderID == nil)
}
```

- [ ] **Step 2: Write failing stale/no-op/failure tests**

For missing folder, missing pattern, moving to the current folder, duplicate names, and injected `archiveWrite` failure, snapshot memory arrays, generation, archive bytes, and folder selection fixture state before the call. Require them all to remain byte/value identical after rejection. In particular:

```swift
@MainActor @Test func movingToTheCurrentFolderDoesNotRewriteOrAdvanceGeneration() async throws {
    let harness = try PatternImportHarness()
    let source = try harness.makePDF(named: "No-op.pdf")
    _ = try await harness.store.importPatternFromLibrary(source)
    let patternID = try #require(harness.store.patterns.first?.id)
    let context = PatternFolderNameContext(
        locale: Locale(identifier: "en"), reservedNames: ["All", "Uncategorized"]
    )
    let folder = try harness.store.createPatternFolder(name: "Socks", nameContext: context)
    try harness.store.movePattern(id: patternID, toFolderID: folder.id)
    let beforeData = try Data(contentsOf: harness.archiveURL)
    let beforeGeneration = harness.store.dataGeneration

    try harness.store.movePattern(id: patternID, toFolderID: folder.id)

    #expect(harness.store.dataGeneration == beforeGeneration)
    #expect(try Data(contentsOf: harness.archiveURL) == beforeData)
}
```

- [ ] **Step 3: Run store tests and witness RED**

Run:

```bash
swift test --disable-sandbox --filter PatternLibraryStoreTests
```

Expected: compilation fails on absent published folders and CRUD APIs.

- [ ] **Step 4: Thread folders through store load and persist**

Add:

```swift
@Published public private(set) var patternFolders: [PatternFolder] = []
```

Extend `persist` with `patternFolders stagedPatternFolders: [PatternFolder]? = nil`; normalize and validate the complete folder/pattern snapshot before encoding; publish every array only after `archiveWrite` succeeds. Extend `decode` and `reloadFromDiskDuringDataOperation` to return/publish normalized folders and patterns.

- [ ] **Step 5: Implement the four public mutations**

Use these signatures and semantics:

```swift
@discardableResult
public func createPatternFolder(
    name: String,
    nameContext: PatternFolderNameContext,
    now: Date = .now
) throws -> PatternFolder

public func renamePatternFolder(
    id: UUID,
    to name: String,
    nameContext: PatternFolderNameContext
) throws

public func movePattern(id: UUID, toFolderID folderID: UUID?) throws

@discardableResult
public func deletePatternFolder(id: UUID) throws -> Int
```

Define the store error exactly once near the other Pattern Library mutation errors:

```swift
public enum PatternFolderStoreError: Error, Equatable, Sendable {
    case folderNotFound
    case patternNotFound
}
```

Validate from the latest in-memory arrays immediately before staging. `deletePatternFolder` maps every matching `StoredPattern.folderID` to nil in one staged array and persists that array together with the folder removal. `movePattern` returns without persistence when the destination equals the current value.

- [ ] **Step 6: Run GREEN and commit**

Run:

```bash
swift test --disable-sandbox --filter 'PatternLibraryStoreTests|PatternLibraryModelTests|JSONProjectStoreTests'
git diff --check
git add Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/PatternLibraryStoreTests.swift Tests/KnitNoteCoreTests/PatternLibraryTestSupport.swift
git commit -m "feat: manage pattern folders atomically"
```

Expected: all mutations are durable on success and side-effect-free on validation or persistence failure.

---

### Task 4: Preserve selected folder destination through file and YouTube imports

**Files:**
- Modify: `Sources/KnitNoteCore/Patterns/PatternInboxItem.swift`
- Modify: `Sources/KnitNoteCore/Patterns/PatternInboxFileService.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Sources/KnitNoteCore/Patterns/YouTubePatternAddCoordinator.swift`
- Modify: `KnitNote/Patterns/AddYouTubePatternView.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternInboxFileServiceTests.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternInboxProcessingStoreTests.swift`
- Modify: `Tests/KnitNoteCoreTests/YouTubePatternStoreTests.swift`
- Modify: `Tests/KnitNoteCoreTests/AddYouTubePatternContractTests.swift`

**Interfaces:**
- Consumes: store `patternFolders` and `StoredPattern.folderID`.
- Produces: `PatternInboxItem.targetFolderID: UUID?` with backward-compatible decode.
- Produces: `importPatternFromLibrary(_:folderID:now:)` and `addYouTubePattern(link:title:targetProjectID:targetFolderID:now:)`.
- Preserves: project imports and Share Extension imports use nil folder; duplicate resolution never moves an existing pattern.
- Consumed later by: `PatternLibraryView` current-scope import actions.

- [ ] **Step 1: Write failing file-import destination tests**

Require inbox manifests to round-trip `targetFolderID`, legacy manifests to decode it as nil, a newly created pattern to receive the valid target, an asynchronously deleted target to normalize the new pattern to nil, and an existing duplicate to retain its old folder.

```swift
@MainActor @Test func libraryImportPublishesNewPatternIntoCapturedFolderWithoutMovingDuplicates() async throws {
    let harness = try PatternImportHarness()
    let context = PatternFolderNameContext(
        locale: Locale(identifier: "en"), reservedNames: ["All", "Uncategorized"]
    )
    let first = try harness.store.createPatternFolder(name: "First", nameContext: context)
    let second = try harness.store.createPatternFolder(name: "Second", nameContext: context)
    let source = try harness.makePDF(named: "same.pdf")

    let created = try await harness.store.importPatternFromLibrary(source, folderID: first.id)
    let createdID: UUID
    if case let .created(patternID) = created {
        createdID = patternID
    } else {
        Issue.record("Expected a newly created pattern")
        return
    }
    #expect(harness.store.patterns.first(where: { $0.id == createdID })?.folderID == first.id)

    let duplicate = try await harness.store.importPatternFromLibrary(source, folderID: second.id)
    #expect(duplicate == .existing(patternID: createdID))
    #expect(harness.store.patterns.first(where: { $0.id == createdID })?.folderID == first.id)
}
```

- [ ] **Step 2: Write failing YouTube destination tests**

Require a new YouTube pattern to use `targetFolderID`, an existing YouTube pattern to keep its current folder, a project-linked import to retain both usage and folder, and missing target folder to create the new pattern in Uncategorized.

- [ ] **Step 3: Run import tests and witness RED**

Run:

```bash
swift test --disable-sandbox --filter 'PatternInboxFileServiceTests|PatternInboxProcessingStoreTests|YouTubePatternStoreTests|AddYouTubePatternContractTests'
```

Expected: failures identify absent `targetFolderID` and absent import API parameters.

- [ ] **Step 4: Extend inbox Codable and enqueue interfaces**

Add `targetFolderID: UUID?` to `PatternInboxItem`, a custom decoder using `decodeIfPresent`, and this parameter to both enqueue overloads. Keep Share Extension callers compiling by defaulting the new parameter to nil. Persist the value inside the existing manifest; do not create a second sidecar.

- [ ] **Step 5: Apply the destination only when creating a new pattern**

Change library import to:

```swift
public func importPatternFromLibrary(
    _ source: URL,
    folderID: UUID?,
    now: Date = .now
) async throws -> PatternImportOutcome
```

Capture `folderID` in the inbox item. In `publishPatternImport`, compute:

```swift
let destinationFolderID = prepared.item.targetFolderID.flatMap { candidate in
    patternFolders.contains(where: { $0.id == candidate }) ? candidate : nil
}
```

Pass it only to each newly initialized `StoredPattern`; never modify `selected` or the single existing duplicate.

- [ ] **Step 6: Extend the YouTube path**

Add `targetFolderID` to `YouTubePatternAddCoordinator`, `AddYouTubePatternView`, and `JSONProjectStore.addYouTubePattern`. Validate it against the latest folders when constructing a new `StoredPattern`; use nil when missing. Keep the existing-asset branch unchanged except for project usage linking.

- [ ] **Step 7: Run GREEN and commit**

Run:

```bash
swift test --disable-sandbox --filter 'PatternInboxFileServiceTests|PatternInboxProcessingStoreTests|PatternInboxDriverTests|YouTubePatternStoreTests|AddYouTubePatternContractTests|PatternImportCoordinatorTests'
git diff --check
git add Sources/KnitNoteCore/Patterns/PatternInboxItem.swift Sources/KnitNoteCore/Patterns/PatternInboxFileService.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift Sources/KnitNoteCore/Patterns/YouTubePatternAddCoordinator.swift KnitNote/Patterns/AddYouTubePatternView.swift Tests/KnitNoteCoreTests/PatternInboxFileServiceTests.swift Tests/KnitNoteCoreTests/PatternInboxProcessingStoreTests.swift Tests/KnitNoteCoreTests/YouTubePatternStoreTests.swift Tests/KnitNoteCoreTests/AddYouTubePatternContractTests.swift
git commit -m "feat: route new patterns into selected folders"
```

Expected: new library imports land in the captured folder, background/share imports remain Uncategorized, and duplicate imports do not silently move existing user content.

---

### Task 5: Build adaptive folder navigation and management UI

**Files:**
- Create: `KnitNote/Patterns/PatternFolderSidebarView.swift`
- Create: `KnitNote/Patterns/PatternFolderEditorView.swift`
- Create: `KnitNote/Patterns/MovePatternFolderView.swift`
- Create: `KnitNote/Patterns/PatternLibraryCollectionView.swift`
- Modify: `KnitNote/Patterns/PatternLibraryView.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternLibraryViewContractTests.swift`
- Create: `Tests/KnitNoteCoreTests/PatternFolderPresentationTests.swift`

**Interfaces:**
- Consumes: `PatternLibraryScope`, published `patternFolders`, store CRUD, scoped `PatternLibraryIndex`, and folder-aware import APIs.
- Produces: `PatternFolderSidebarView(selection:onCreate:onRename:onDelete:)`.
- Produces: `PatternLibraryCollectionView(scope:)` with search, sort, import, detail navigation, and move context menu.
- Produces: one `NavigationSplitView` that presents sidebar/detail on iPad/Mac and collapses folder-first on iPhone.

- [ ] **Step 1: Write failing presentation-policy tests**

Create a pure presentation model test for deterministic folder ordering, counts, system-row identity, and post-delete selection:

```swift
@Test func sidebarPlacesSystemRowsFirstAndSortsUserFoldersBySelectedLocale() {
    let beta = PatternFolder(displayName: "Beta", createdAt: Date(timeIntervalSince1970: 2))
    let alpha = PatternFolder(displayName: "Alpha", createdAt: Date(timeIntervalSince1970: 1))
    let rows = PatternFolderPresentation.rows(
        folders: [beta, alpha],
        patterns: [pattern(folderID: alpha.id), pattern(folderID: nil)],
        locale: Locale(identifier: "en")
    )
    #expect(rows.map(\.scope) == [.all, .uncategorized, .folder(alpha.id), .folder(beta.id)])
    #expect(rows.map(\.count) == [2, 1, 1, 0])
    #expect(PatternFolderPresentation.selectionAfterDeleting(
        .folder(alpha.id), deletedFolderID: alpha.id
    ) == .uncategorized)
}

private func pattern(folderID: UUID?) -> StoredPattern {
    StoredPattern(assetID: UUID(), displayName: UUID().uuidString, folderID: folderID)
}
```

- [ ] **Step 2: Write failing source contracts for the approved layout**

Require:

```swift
@Test func patternLibraryUsesFolderFirstAdaptiveNavigationAndLongPressMovement() throws {
    let root = try sourceText("KnitNote/Patterns/PatternLibraryView.swift")
    let sidebar = try sourceText("KnitNote/Patterns/PatternFolderSidebarView.swift")
    let collection = try sourceText("KnitNote/Patterns/PatternLibraryCollectionView.swift")

    #expect(root.contains("NavigationSplitView"))
    #expect(root.contains("PatternFolderSidebarView"))
    #expect(root.contains("PatternLibraryCollectionView"))
    #expect(sidebar.contains("patterns.folder.all"))
    #expect(sidebar.contains("patterns.folder.uncategorized"))
    #expect(sidebar.contains("contextMenu"))
    #expect(collection.contains("contextMenu"))
    #expect(collection.contains("MovePatternFolderView"))
    #expect(collection.contains("PatternLibraryIndex(rows: rows, locale: locale)"))
    #expect(collection.contains(".search(query, in: scope, sortedBy: sort)"))
}
```

- [ ] **Step 3: Run UI contracts and witness RED**

Run:

```bash
swift test --disable-sandbox --filter 'PatternLibraryViewContractTests|PatternFolderPresentationTests'
```

Expected: missing new presentation and view types cause RED.

- [ ] **Step 4: Implement the pure sidebar presentation model**

Add `PatternFolderPresentation` alongside `PatternFolderSidebarView` with:

```swift
enum PatternFolderSidebarTitle: Equatable {
    case localizedKey(String)
    case userContent(String)
}

struct PatternFolderSidebarRow: Identifiable, Equatable {
    let scope: PatternLibraryScope
    let title: PatternFolderSidebarTitle
    let count: Int
    var id: PatternLibraryScope { scope }
}

enum PatternFolderPresentation {
    static func rows(
        folders: [PatternFolder],
        patterns: [StoredPattern],
        locale: Locale
    ) -> [PatternFolderSidebarRow]

    static func selectionAfterDeleting(
        _ selection: PatternLibraryScope,
        deletedFolderID: UUID
    ) -> PatternLibraryScope
}
```

Build system rows with `.localizedKey("patterns.folder.all")` and `.localizedKey("patterns.folder.uncategorized")`; build user rows with `.userContent(folder.displayName)` so user names never pass through localization. Sort user folders using the same locale-aware, numeric, width/diacritic-insensitive ordering as pattern names, then creation date, then UUID.

- [ ] **Step 5: Implement folder editor and move picker**

`PatternFolderEditorView` owns a draft string and a localized validation error; it calls the store only from Done and dismisses only after success. `MovePatternFolderView` lists Uncategorized and every user folder, shows a checkmark on the current destination, calls `movePattern`, and dismisses only after success. Use 44-point minimum hit areas and explicit VoiceOver labels.

Build the name context from every shipping language, not only the selected language:

```swift
private func patternFolderNameContext(locale: Locale) -> PatternFolderNameContext {
    let reservedNames = Set(SupportedLocalization.v150Identifiers.flatMap { identifier in
        let candidateLocale = Locale(identifier: identifier)
        return [
            LocaleAwareText.string("patterns.folder.all", locale: candidateLocale),
            LocaleAwareText.string("patterns.folder.uncategorized", locale: candidateLocale),
        ]
    })
    return PatternFolderNameContext(locale: locale, reservedNames: reservedNames)
}
```

Add a behavior contract that asserts `All`, `全部`, `すべて`, `Uncategorized`, `未分類`, and their remaining shipping translations are in the resulting set.

Use this error mapping boundary rather than `localizedDescription`:

```swift
enum PatternFolderFailurePresentation {
    static func key(for error: Error) -> String {
        switch error {
        case PatternFolderValidationError.emptyName: "patterns.folder.error.empty"
        case PatternFolderValidationError.duplicateName: "patterns.folder.error.duplicate"
        case PatternFolderValidationError.reservedName: "patterns.folder.error.reserved"
        case PatternFolderStoreError.folderNotFound: "patterns.folder.error.missing"
        default: "patterns.folder.error.saveFailed"
        }
    }
}
```

- [ ] **Step 6: Split the current list into `PatternLibraryCollectionView`**

Move existing row creation, asset lookup, search, sort, file import, YouTube import, duplicate selection, alert, and detail navigation into the collection view. Add `let scope: PatternLibraryScope`; derive new-pattern destination as nil for `.all`/`.uncategorized` and the UUID for `.folder`. Add a row context menu that sets the selected pattern for `MovePatternFolderView`.

- [ ] **Step 7: Compose the adaptive root**

Replace the root `NavigationStack` with:

```swift
NavigationSplitView {
    PatternFolderSidebarView(
        selection: $selection,
        onCreate: { folderEditor = .create },
        onRename: { folderEditor = .rename($0) },
        onDelete: { pendingDeletion = $0 }
    )
} detail: {
    PatternLibraryCollectionView(scope: selection)
}
```

Use `.navigationSplitViewStyle(.balanced)`. SwiftUI collapses the split view to sidebar-first navigation on iPhone; do not add a fixed two-column `HStack` or horizontal scrolling fallback. After a successful delete of the selected folder, set selection to `.uncategorized`.

- [ ] **Step 8: Add deletion confirmation for empty and nonempty folders**

Compute the current count at render time and show a localized count-aware confirmation for both empty and nonempty folders; zero must not bypass confirmation. Call `deletePatternFolder` only from the destructive button. On error, retain pending deletion context and offer retry; on success, clear it and update selection.

- [ ] **Step 9: Run GREEN and commit**

Run:

```bash
swift test --disable-sandbox --filter 'PatternLibraryViewContractTests|PatternFolderPresentationTests|PatternLibraryQueryTests|PatternLibraryStoreTests|PatternLibraryImportPresentationTests'
xcodegen generate
git diff --check
git add KnitNote/Patterns/PatternFolderSidebarView.swift KnitNote/Patterns/PatternFolderEditorView.swift KnitNote/Patterns/MovePatternFolderView.swift KnitNote/Patterns/PatternLibraryCollectionView.swift KnitNote/Patterns/PatternLibraryView.swift Tests/KnitNoteCoreTests/PatternLibraryViewContractTests.swift Tests/KnitNoteCoreTests/PatternFolderPresentationTests.swift KnitNote.xcodeproj/project.pbxproj
git commit -m "feat: add adaptive pattern folder navigation"
```

Expected: focused tests pass and the generated project contains all four new source files with no deleted/stale membership.

---

### Task 6: Add complete localized folder copy and accessibility contracts

**Files:**
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternLibraryViewContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/KnittingTerminologyContractTests.swift`

**Interfaces:**
- Consumes: the folder UI keys used by Task 5.
- Produces: complete values and matching format tokens for all 13 shipping locales.
- Produces: pluralized folder/pattern count and delete-confirmation strings.

- [ ] **Step 1: Add failing required-key and accessibility contracts**

Require these exact keys in all 13 languages:

```swift
let requiredPatternFolderKeys: Set<String> = [
    "patterns.folder.all",
    "patterns.folder.uncategorized",
    "patterns.folder.new",
    "patterns.folder.name",
    "patterns.folder.rename",
    "patterns.folder.move",
    "patterns.folder.count",
    "patterns.folder.delete.title",
    "patterns.folder.delete.message",
    "patterns.folder.error.empty",
    "patterns.folder.error.duplicate",
    "patterns.folder.error.reserved",
    "patterns.folder.error.missing",
    "patterns.folder.error.saveFailed",
]
```

Require `%lld` in `patterns.folder.count` and in the delete message across matching plural paths. Require source files to include explicit accessibility labels/hints for New Folder, Rename, Delete, Move, row count, and current selection.

- [ ] **Step 2: Run localization contracts and witness RED**

Run:

```bash
swift test --disable-sandbox --filter 'StringCatalogLocalizationContractTests|PatternLibraryViewContractTests|KnittingTerminologyContractTests'
```

Expected: required folder keys are absent.

- [ ] **Step 3: Add English source values and developer comments**

Use these exact English meanings:

| Key | English value / plural intent |
| --- | --- |
| `patterns.folder.all` | `All` |
| `patterns.folder.uncategorized` | `Uncategorized` |
| `patterns.folder.new` | `New Folder` |
| `patterns.folder.name` | `Folder Name` |
| `patterns.folder.rename` | `Rename Folder` |
| `patterns.folder.move` | `Move to Folder` |
| `patterns.folder.count` | one `%lld pattern`; other `%lld patterns` |
| `patterns.folder.delete.title` | `Delete Folder?` |
| `patterns.folder.delete.message` | one `The folder will be deleted and %lld pattern will move to Uncategorized.`; other `The folder will be deleted and %lld patterns will move to Uncategorized.` |
| `patterns.folder.error.empty` | `Enter a folder name.` |
| `patterns.folder.error.duplicate` | `A folder with this name already exists.` |
| `patterns.folder.error.reserved` | `This name is reserved by KnitNote.` |
| `patterns.folder.error.missing` | `This folder is no longer available.` |
| `patterns.folder.error.saveFailed` | `The folder change could not be saved. Try again.` |

Catalog comments must state that “folder” means a user-created single-level Pattern Library collection, “pattern” means knitting/crochet pattern, and user names must remain untranslated.

- [ ] **Step 4: Fill every shipping locale and run structural validation**

For each required key, add `translated` values for `en`, `zh-Hant`, `zh-Hans`, `de`, `fr`, `ja`, `nb`, `sv`, `fi`, `da`, `ko`, `el`, and `nl`. Preserve `%lld` type and the catalog's required plural paths. Use the following reviewed draft as the implementation baseline; entries separated by `|` are singular and plural variations:

| Locale | All; Uncategorized; New Folder; Folder Name; Rename; Move; Count |
| --- | --- |
| en | All; Uncategorized; New Folder; Folder Name; Rename Folder; Move to Folder; `%lld pattern` \| `%lld patterns` |
| zh-Hant | 全部; 未分類; 新增資料匣; 資料匣名稱; 重新命名資料匣; 移到資料匣; `%lld 份織圖` |
| zh-Hans | 全部; 未分类; 新建文件夹; 文件夹名称; 重命名文件夹; 移到文件夹; `%lld 个织图` |
| de | Alle; Nicht kategorisiert; Neuer Ordner; Ordnername; Ordner umbenennen; In Ordner verschieben; `%lld Anleitung` \| `%lld Anleitungen` |
| fr | Tous; Non classés; Nouveau dossier; Nom du dossier; Renommer le dossier; Déplacer vers un dossier; `%lld patron` \| `%lld patrons` |
| ja | すべて; 未分類; 新規フォルダ; フォルダ名; フォルダ名を変更; フォルダに移動; パターン `%lld` 件 |
| nb | Alle; Ukategorisert; Ny mappe; Mappenavn; Gi nytt navn til mappen; Flytt til mappe; `%lld oppskrift` \| `%lld oppskrifter` |
| sv | Alla; Okategoriserade; Ny mapp; Mappnamn; Byt namn på mappen; Flytta till mapp; `%lld mönster` |
| fi | Kaikki; Luokittelemattomat; Uusi kansio; Kansion nimi; Nimeä kansio uudelleen; Siirrä kansioon; `%lld ohje` \| `%lld ohjetta` |
| da | Alle; Ikke kategoriseret; Ny mappe; Mappenavn; Omdøb mappen; Flyt til mappe; `%lld opskrift` \| `%lld opskrifter` |
| ko | 전체; 미분류; 새 폴더; 폴더 이름; 폴더 이름 변경; 폴더로 이동; 도안 `%lld`개 |
| el | Όλα; Χωρίς κατηγορία; Νέος φάκελος; Όνομα φακέλου; Μετονομασία φακέλου; Μετακίνηση σε φάκελο; `%lld πατρόν` |
| nl | Alles; Niet gecategoriseerd; Nieuwe map; Mapnaam; Map hernoemen; Naar map verplaatsen; `%lld patroon` \| `%lld patronen` |

| Locale | Delete title; Delete message singular \| plural |
| --- | --- |
| en | Delete Folder?; `The folder will be deleted and %lld pattern will move to Uncategorized.` \| `The folder will be deleted and %lld patterns will move to Uncategorized.` |
| zh-Hant | 刪除資料匣？; `將刪除資料匣，並把 %lld 份織圖移到「未分類」。` |
| zh-Hans | 删除文件夹？; `将删除文件夹，并把 %lld 个织图移到“未分类”。` |
| de | Ordner löschen?; `Der Ordner wird gelöscht und %lld Anleitung wird nach „Nicht kategorisiert“ verschoben.` \| `Der Ordner wird gelöscht und %lld Anleitungen werden nach „Nicht kategorisiert“ verschoben.` |
| fr | Supprimer le dossier ?; `Le dossier sera supprimé et %lld patron sera déplacé vers « Non classés ».` \| `Le dossier sera supprimé et %lld patrons seront déplacés vers « Non classés ».` |
| ja | フォルダを削除しますか？; `フォルダを削除し、パターン %lld 件を「未分類」に移動します。` |
| nb | Slette mappen?; `Mappen slettes, og %lld oppskrift flyttes til Ukategorisert.` \| `Mappen slettes, og %lld oppskrifter flyttes til Ukategorisert.` |
| sv | Ta bort mappen?; `Mappen tas bort och %lld mönster flyttas till Okategoriserade.` |
| fi | Poistetaanko kansio?; `Kansio poistetaan ja %lld ohje siirretään Luokittelemattomiin.` \| `Kansio poistetaan ja %lld ohjetta siirretään Luokittelemattomiin.` |
| da | Slet mappen?; `Mappen slettes, og %lld opskrift flyttes til Ikke kategoriseret.` \| `Mappen slettes, og %lld opskrifter flyttes til Ikke kategoriseret.` |
| ko | 폴더를 삭제할까요?; `폴더가 삭제되고 도안 %lld개가 미분류로 이동됩니다.` |
| el | Διαγραφή φακέλου; `Ο φάκελος θα διαγραφεί και %lld πατρόν θα μετακινηθεί στα Χωρίς κατηγορία.` |
| nl | Map verwijderen?; `De map wordt verwijderd en %lld patroon wordt naar Niet gecategoriseerd verplaatst.` \| `De map wordt verwijderd en %lld patronen worden naar Niet gecategoriseerd verplaatst.` |

Use these error values in key order `empty`, `duplicate`, `reserved`, `missing`, `saveFailed`:

- en: `Enter a folder name.`; `A folder with this name already exists.`; `This name is reserved by KnitNote.`; `This folder is no longer available.`; `The folder change could not be saved. Try again.`
- zh-Hant: `請輸入資料匣名稱。`; `已有同名資料匣。`; `此名稱為 KnitNote 保留名稱。`; `此資料匣已不存在。`; `無法儲存資料匣變更，請再試一次。`
- zh-Hans: `请输入文件夹名称。`; `已有同名文件夹。`; `此名称由 KnitNote 保留。`; `此文件夹已不存在。`; `无法保存文件夹更改，请重试。`
- de: `Gib einen Ordnernamen ein.`; `Ein Ordner mit diesem Namen ist bereits vorhanden.`; `Dieser Name ist für KnitNote reserviert.`; `Dieser Ordner ist nicht mehr verfügbar.`; `Die Ordneränderung konnte nicht gespeichert werden. Versuche es erneut.`
- fr: `Saisissez un nom de dossier.`; `Un dossier portant ce nom existe déjà.`; `Ce nom est réservé par KnitNote.`; `Ce dossier n’est plus disponible.`; `La modification du dossier n’a pas pu être enregistrée. Réessayez.`
- ja: `フォルダ名を入力してください。`; `同じ名前のフォルダがすでにあります。`; `この名前は KnitNote によって予約されています。`; `このフォルダは利用できなくなりました。`; `フォルダの変更を保存できませんでした。もう一度お試しください。`
- nb: `Skriv inn et mappenavn.`; `Det finnes allerede en mappe med dette navnet.`; `Dette navnet er reservert av KnitNote.`; `Denne mappen er ikke lenger tilgjengelig.`; `Mappeendringen kunne ikke lagres. Prøv igjen.`
- sv: `Ange ett mappnamn.`; `Det finns redan en mapp med det här namnet.`; `Det här namnet är reserverat av KnitNote.`; `Den här mappen är inte längre tillgänglig.`; `Mappändringen kunde inte sparas. Försök igen.`
- fi: `Anna kansiolle nimi.`; `Samanniminen kansio on jo olemassa.`; `Nimi on varattu KnitNotelle.`; `Kansio ei ole enää käytettävissä.`; `Kansion muutosta ei voitu tallentaa. Yritä uudelleen.`
- da: `Indtast et mappenavn.`; `Der findes allerede en mappe med dette navn.`; `Dette navn er reserveret af KnitNote.`; `Denne mappe er ikke længere tilgængelig.`; `Mappeændringen kunne ikke gemmes. Prøv igen.`
- ko: `폴더 이름을 입력하세요.`; `같은 이름의 폴더가 이미 있습니다.`; `이 이름은 KnitNote에서 사용하도록 예약되어 있습니다.`; `이 폴더는 더 이상 사용할 수 없습니다.`; `폴더 변경 사항을 저장할 수 없습니다. 다시 시도하세요.`
- el: `Εισαγάγετε όνομα φακέλου.`; `Υπάρχει ήδη φάκελος με αυτό το όνομα.`; `Αυτό το όνομα είναι δεσμευμένο από το KnitNote.`; `Αυτός ο φάκελος δεν είναι πλέον διαθέσιμος.`; `Δεν ήταν δυνατή η αποθήκευση της αλλαγής φακέλου. Δοκιμάστε ξανά.`
- nl: `Voer een mapnaam in.`; `Er bestaat al een map met deze naam.`; `Deze naam is gereserveerd door KnitNote.`; `Deze map is niet meer beschikbaar.`; `De mapwijziging kon niet worden bewaard. Probeer het opnieuw.`

These are implementation drafts, not a native-acceptance claim. Task 6 Step 5 must correct any unnatural phrase with a RED exact regression before the catalog commit.

Run:

```bash
jq empty KnitNote/Localization/Localizable.xcstrings
swift test --disable-sandbox --filter 'StringCatalogLocalizationContractTests|LocalizationContractTests|KnittingTerminologyContractTests|PatternLibraryViewContractTests'
```

Expected: JSON parses and every required locale/token/plural/accessibility contract passes.

- [ ] **Step 5: Perform a linguistic review and lock corrections**

Review all 14 English-to-target-language rows independently, with special attention to Japanese/Korean counters, Chinese “織圖” terminology, Scandinavian compound nouns, Greek cases, Dutch naturalness, and Delete-versus-remove semantics. For every corrected phrase, add an exact regression assertion in `LocalizationContractTests` before changing the catalog, witness the assertion fail, then update the catalog and rerun Step 4.

- [ ] **Step 6: Commit localization as one atomic catalog change**

Run:

```bash
git diff --check
git add KnitNote/Localization/Localizable.xcstrings Tests/KnitNoteCoreTests/LocalizationContractTests.swift Tests/KnitNoteCoreTests/PatternLibraryViewContractTests.swift Tests/KnitNoteCoreTests/KnittingTerminologyContractTests.swift
git commit -m "feat: localize pattern folder management"
```

Expected: the commit contains the complete 13-language key family and its structural/linguistic contracts; no locale is left `new`, blank, stale, or key-valued.

---

### Task 7: Regenerate, run full regression gates, and prepare exact physical acceptance

**Files:**
- Modify if generated output changes: `KnitNote.xcodeproj/project.pbxproj`
- Create after automated gates: `AppStore/Verification/PatternFoldersNextVersionVerification.md`

**Interfaces:**
- Consumes: all prior tasks.
- Produces: byte-stable generated project, complete automated verification evidence, and a pending physical checklist bound to an exact commit/version/build.

- [ ] **Step 1: Verify XcodeGen is stable**

Run:

```bash
xcodegen generate
shasum -a 256 KnitNote.xcodeproj/project.pbxproj
xcodegen generate
shasum -a 256 KnitNote.xcodeproj/project.pbxproj
git diff --check
```

Expected: both SHA-256 values are identical. Commit a changed pbxproj only when it is the deterministic result of `project.yml` and source membership.

- [ ] **Step 2: Run focused data, backup, import, UI, and localization suites**

Run:

```bash
swift test --disable-sandbox --filter 'PatternFolder|PatternLibrary|PatternInbox|YouTubePattern|KnitNoteBackup|LocalizationContract|RuntimeLocalization'
```

Expected: every selected suite passes with zero issues.

- [ ] **Step 3: Run the complete Swift suite once**

Run:

```bash
swift test --disable-sandbox
```

Expected: all tests in all suites pass. Preserve the exact count and elapsed time in the task report; do not start a duplicate while a retained SwiftPM process owns `.build`.

- [ ] **Step 4: Build every affected Apple target without signing**

Run:

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNotePatternFolders-iOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/KnitNotePatternFolders-macOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteWatch -configuration Debug -destination 'generic/platform=watchOS Simulator' -derivedDataPath /tmp/KnitNotePatternFolders-Watch CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -target KnitNoteShare -configuration Debug -sdk iphonesimulator -derivedDataPath /tmp/KnitNotePatternFolders-Share CODE_SIGNING_ALLOWED=NO build
```

Expected: all four commands end with `** BUILD SUCCEEDED **`. Inspect the iOS build graph to confirm main App and Share Extension compile the schema-13 core sources.

- [ ] **Step 5: Run static data-preservation probes**

Create a temporary schema-12 fixture containing a PDF asset, project usage, page state, note, and markup; launch schema-13 load/migration through the test helper; compare asset SHA-256, IDs, usage state, note, and markup bytes before/after. Require only archive schema/folder fields to differ and every old pattern to have nil folder membership.

Run the exact regression that performs this probe:

```bash
swift test --disable-sandbox --filter schemaTwelveMigrationPreservesEveryPatternOwnedByteAndUsage
```

Expected: one test passes and prints no user-data mismatch.

- [ ] **Step 6: Commit deterministic generated output and verification record**

Run:

```bash
git rev-parse HEAD
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /tmp/KnitNotePatternFolders-iOS/Build/Products/Debug-iphonesimulator/KnitNote.app/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /tmp/KnitNotePatternFolders-iOS/Build/Products/Debug-iphonesimulator/KnitNote.app/Info.plist
```

Use the exact outputs in `AppStore/Verification/PatternFoldersNextVersionVerification.md`, followed by unchecked boxes for:

1. iPhone folder-first navigation, create/rename/delete, long-press move, scoped search, and import destination.
2. iPad sidebar/detail in portrait, landscape, and narrow Split View.
3. Mac sidebar, context menus, keyboard focus, window resizing, and search.
4. VoiceOver names/counts/actions plus Dynamic Type.
5. zh-Hant, en, and ja live language changes.
6. Before/after preservation of existing PDF/image/YouTube patterns, project links, reader positions, page notes, highlights, markup, and backup restore.

Then run:

```bash
git add KnitNote.xcodeproj/project.pbxproj AppStore/Verification/PatternFoldersNextVersionVerification.md
git diff --cached --check
git commit -m "test: prepare pattern folder acceptance"
```

Expected: physical boxes remain unchecked until observed on the exact binary. If pbxproj has no deterministic diff, stage only the verification file.

- [ ] **Step 7: Perform physical acceptance without broadening release authority**

Install the exact built commit without uninstalling or erasing user data. Execute every unchecked item from Step 6 and record PASS/PENDING per target. Stop fail-closed on any missing pattern, broken backup, wrong language, inaccessible control, or partial folder transaction. Do not archive, export, upload, select an App Store build, submit, or release as part of this feature plan.
