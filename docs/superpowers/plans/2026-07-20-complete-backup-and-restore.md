# Complete Backup and Restore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a localized Settings workflow that exports every managed KnitNote record and media file into one `.knitnote-backup` package and safely restores it by fully replacing current data with rollback protection.

**Architecture:** KnitNoteCore owns a versioned manifest, deterministic package builder/validator, and staged atomic installer. The main-actor `JSONProjectStore` serializes backup operations with normal mutations and reloads the installed archive before committing a restore. SwiftUI owns only document picking/exporting, preview confirmation, progress, and localized feedback.

**Tech Stack:** Swift 6, Foundation file packages and `FileWrapper`, SwiftUI `FileDocument`/`fileExporter`/`fileImporter`, UniformTypeIdentifiers, Swift Testing, XcodeGen.

## Global Constraints

- Version 1 restore completely replaces the current data set; it never merges records.
- The package extension is `.knitnote-backup` and the format version is exactly `1`.
- Export only `projects-v1.json`, referenced files in `ProjectPhotos`, `YarnPhotos`, `ProjectJournalPhotos`, and referenced pattern files/markup under `Patterns`.
- Never export device permissions, caches, unknown files, or the device-local language selection.
- Validate before replacement and retain rollback data until the installed archive successfully reloads.
- Reject symbolic links, unsafe path components, unknown package entries, missing references, duplicate record identifiers, invalid yarn links, malformed markup, files above 200 MB, and packages above 4 GB.
- Support iOS 18, macOS 15, Traditional Chinese, and English without adding third-party dependencies.
- Preserve unrelated untracked paths `.superpowers/`, `KnitNote 5.xcodeproj/`, and `KnitNote 6.xcodeproj/`.

---

## File structure

- Create `Sources/KnitNoteCore/Backup/KnitNoteBackupManifest.swift`: versioned manifest, preview, limits, and typed errors.
- Create `Sources/KnitNoteCore/Backup/KnitNoteBackupService.swift`: package creation, structural/reference validation, staging, installation, rollback, and cleanup.
- Modify `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`: serialized data-operation state, explicit reload, export/inspect/restore orchestration.
- Create `KnitNote/Settings/KnitNoteBackupDocument.swift`: custom UTType and package `FileDocument` adapter.
- Create `KnitNote/Settings/BackupSettingsSection.swift`: export/import UI, preview confirmation, progress, and alerts.
- Modify `KnitNote/Settings/SettingsView.swift`: place the backup section below calculator tools.
- Modify `KnitNote/Localization/Localizable.xcstrings`: Traditional Chinese and English backup copy.
- Create `Tests/KnitNoteCoreTests/KnitNoteBackupManifestTests.swift`: manifest compatibility tests.
- Create `Tests/KnitNoteCoreTests/KnitNoteBackupServiceTests.swift`: package, validation, install, and rollback tests.
- Modify `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`: reload and mutation-lock tests.
- Create `Tests/KnitNoteCoreTests/BackupSettingsViewContractTests.swift`: UI and localization contract checks.
- Regenerate `KnitNote.xcodeproj/project.pbxproj` from `project.yml` only if the current project does not automatically include the new source paths.

---

### Task 1: Versioned backup manifest and compatibility policy

**Files:**
- Create: `Sources/KnitNoteCore/Backup/KnitNoteBackupManifest.swift`
- Create: `Tests/KnitNoteCoreTests/KnitNoteBackupManifestTests.swift`

**Interfaces:**
- Produces: `KnitNoteBackupManifest`, `KnitNoteBackupPreview`, `KnitNoteBackupLimits`, and `KnitNoteBackupError` used by every later task.
- Consumes: `ProjectArchive` only for counts in higher-level services; this task remains filesystem-independent.

- [ ] **Step 1: Write failing manifest tests**

```swift
import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct KnitNoteBackupManifestTests {
    @Test func versionOneRoundTripsAndBuildsPreview() throws {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let manifest = KnitNoteBackupManifest(
            formatVersion: 1,
            createdAt: date,
            appVersion: "1.0.0",
            projectCount: 2,
            yarnCount: 3
        )
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(KnitNoteBackupManifest.self, from: data)
        #expect(decoded == manifest)
        #expect(try decoded.preview() == .init(createdAt: date, projectCount: 2, yarnCount: 3))
    }

    @Test func newerFormatIsRejected() {
        let manifest = KnitNoteBackupManifest(
            formatVersion: 2,
            createdAt: .now,
            appVersion: "2.0",
            projectCount: 0,
            yarnCount: 0
        )
        #expect(throws: KnitNoteBackupError.unsupportedNewerVersion(2)) {
            try manifest.preview()
        }
    }
}
```

- [ ] **Step 2: Run the focused tests and confirm RED**

Run: `swift test --filter KnitNoteBackupManifestTests`

Expected: compilation fails because the backup types do not exist.

- [ ] **Step 3: Implement manifest values, limits, and typed errors**

```swift
import Foundation

public struct KnitNoteBackupManifest: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public let formatVersion: Int
    public let createdAt: Date
    public let appVersion: String
    public let projectCount: Int
    public let yarnCount: Int

    public init(formatVersion: Int = Self.currentFormatVersion, createdAt: Date, appVersion: String, projectCount: Int, yarnCount: Int) {
        self.formatVersion = formatVersion
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.projectCount = projectCount
        self.yarnCount = yarnCount
    }

    public func preview() throws -> KnitNoteBackupPreview {
        guard formatVersion <= Self.currentFormatVersion else {
            throw KnitNoteBackupError.unsupportedNewerVersion(formatVersion)
        }
        guard formatVersion == 1, projectCount >= 0, yarnCount >= 0 else {
            throw KnitNoteBackupError.invalidManifest
        }
        return KnitNoteBackupPreview(createdAt: createdAt, projectCount: projectCount, yarnCount: yarnCount)
    }
}

public struct KnitNoteBackupPreview: Equatable, Sendable {
    public let createdAt: Date
    public let projectCount: Int
    public let yarnCount: Int
    public init(createdAt: Date, projectCount: Int, yarnCount: Int) {
        self.createdAt = createdAt
        self.projectCount = projectCount
        self.yarnCount = yarnCount
    }
}

public enum KnitNoteBackupLimits {
    public static let maximumManifestBytes: Int64 = 1_000_000
    public static let maximumArchiveBytes: Int64 = 20_000_000
    public static let maximumFileBytes: Int64 = 200_000_000
    public static let maximumPackageBytes: Int64 = 4_000_000_000
}

public enum KnitNoteBackupError: Error, Equatable, Sendable {
    case invalidManifest
    case unsupportedNewerVersion(Int)
    case invalidArchive
    case countMismatch
    case duplicateIdentifier
    case invalidYarnProjectLinks
    case unsafePackageEntry
    case unknownPackageEntry
    case missingReferencedFile(String)
    case invalidMarkup
    case fileTooLarge
    case packageTooLarge
    case accessDenied
    case operationInProgress
    case installFailedOriginalPreserved
    case rollbackFailed
}
```

- [ ] **Step 4: Run focused tests and confirm GREEN**

Run: `swift test --filter KnitNoteBackupManifestTests`

Expected: all manifest tests pass.

- [ ] **Step 5: Commit the manifest unit**

```bash
git add Sources/KnitNoteCore/Backup/KnitNoteBackupManifest.swift Tests/KnitNoteCoreTests/KnitNoteBackupManifestTests.swift
git commit -m "Add versioned KnitNote backup manifest"
```

### Task 2: Deterministic package creation and validation

**Files:**
- Create: `Sources/KnitNoteCore/Backup/KnitNoteBackupService.swift`
- Create: `Tests/KnitNoteCoreTests/KnitNoteBackupServiceTests.swift`

**Interfaces:**
- Consumes: `KnitNoteBackupManifest`, `KnitNoteBackupPreview`, `KnitNoteBackupLimits`, `KnitNoteBackupError`, `ProjectArchive`, `PatternMarkupDocument`, and existing managed photo filename policies.
- Produces: `KnitNoteBackupService.init(liveRoot:workRoot:)`, `createPackage(appVersion:now:)`, `inspectPackage(at:)`, and `stagePackage(at:)`.

- [ ] **Step 1: Add test helpers and failing complete-export tests**

```swift
private func makeServiceFixture() throws -> (KnitNoteBackupService, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let live = root.appendingPathComponent("KnitNote")
    let work = root.appendingPathComponent("Work")
    try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
    return (KnitNoteBackupService(liveRoot: live, workRoot: work), live, root)
}

@Test func exportCopiesArchiveAndEveryReferencedMediaKindButNotOrphans() throws {
    let (service, live, root) = try makeServiceFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try BackupFixture.writeCompleteArchive(to: live)
    try Data("orphan".utf8).write(to: live.appendingPathComponent("ProjectPhotos/orphan.jpg"))

    let package = try service.createPackage(appVersion: "1.0", now: .init(timeIntervalSince1970: 10))

    #expect(FileManager.default.fileExists(atPath: package.appendingPathComponent("manifest.json").path))
    for relativePath in fixture.referencedRelativePaths {
        #expect(FileManager.default.fileExists(atPath: package.appendingPathComponent("Data/\(relativePath)").path))
    }
    #expect(!FileManager.default.fileExists(atPath: package.appendingPathComponent("Data/ProjectPhotos/orphan.jpg").path))
    #expect(try service.inspectPackage(at: package).projectCount == 1)
}
```

`BackupFixture.writeCompleteArchive(to:)` must create one project photo, one yarn photo, a matching journal full/thumbnail pair, one pattern PDF fixture, and valid markup JSON using real model filenames. It returns those relative paths for assertions.

- [ ] **Step 2: Run the export test and confirm RED**

Run: `swift test --filter KnitNoteBackupServiceTests.exportCopiesArchiveAndEveryReferencedMediaKindButNotOrphans`

Expected: compilation fails because `KnitNoteBackupService` is absent.

- [ ] **Step 3: Implement package layout and referenced-file collection**

Implement these exact public entry points:

```swift
public struct StagedKnitNoteBackup: Sendable {
    public let root: URL
    public let preview: KnitNoteBackupPreview
}

public struct KnitNoteBackupService: Sendable {
    public let liveRoot: URL
    public let workRoot: URL

    public init(liveRoot: URL, workRoot: URL) {
        self.liveRoot = liveRoot
        self.workRoot = workRoot
    }

    public func createPackage(appVersion: String, now: Date = .now) throws -> URL
    public func inspectPackage(at packageRoot: URL) throws -> KnitNoteBackupPreview
    public func stagePackage(at packageRoot: URL) throws -> StagedKnitNoteBackup
}
```

`createPackage` must decode `liveRoot/projects-v1.json`, reject invalid links and duplicate IDs, create a unique work directory ending in `.knitnote-backup`, copy the archive, copy each exact referenced file, include every markup file under known project/pattern UUID directories, encode `manifest.json` atomically, then call `inspectPackage` before returning.

- [ ] **Step 4: Run the export test and confirm GREEN**

Run: `swift test --filter KnitNoteBackupServiceTests.exportCopiesArchiveAndEveryReferencedMediaKindButNotOrphans`

Expected: the focused export test passes.

- [ ] **Step 5: Add failing hostile/import validation cases**

```swift
@Test(arguments: ["../escape.jpg", "/tmp/escape.jpg", "nested/name.jpg"])
func unsafeReferencedFilenamesAreRejected(_ filename: String) throws {
    let package = try BackupFixture.package(projectPhotoFilename: filename)
    #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
        _ = try package.service.inspectPackage(at: package.url)
    }
}

@Test func missingReferenceIsRejected() throws {
    let package = try BackupFixture.completePackage()
    try FileManager.default.removeItem(at: package.firstReferencedFile)
    #expect(throws: KnitNoteBackupError.missingReferencedFile(package.firstRelativePath)) {
        _ = try package.service.inspectPackage(at: package.url)
    }
}

@Test func symlinkUnknownEntryAndMalformedMarkupAreRejected() throws {
    let symlink = try BackupFixture.packageContainingSymlink()
    #expect(throws: KnitNoteBackupError.unsafePackageEntry) { _ = try symlink.service.inspectPackage(at: symlink.url) }
    let unknown = try BackupFixture.packageContainingUnknownEntry()
    #expect(throws: KnitNoteBackupError.unknownPackageEntry) { _ = try unknown.service.inspectPackage(at: unknown.url) }
    let markup = try BackupFixture.packageContainingMalformedMarkup()
    #expect(throws: KnitNoteBackupError.invalidMarkup) { _ = try markup.service.inspectPackage(at: markup.url) }
}
```

Also add explicit tests for newer format, manifest/archive count mismatch, duplicate project IDs, duplicate yarn IDs, dangling yarn project links, 200 MB per-file enforcement via injected resource-size metadata/helper, 4 GB aggregate enforcement, and staging into a fresh work directory.

- [ ] **Step 6: Implement strict structural and reference validation**

Use URL resource keys `[.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]`, refuse hidden/symbolic items, require exactly `manifest.json` and `Data` at package root, and permit only the five known paths below `Data`. Validate file components with `lastPathComponent == value`, no `/`, no `\\`, and no `..`. Require journal pairs to satisfy `ProjectJournalPhotoFilename.isOwnedPair` and parse every accepted markup file as `PatternMarkupDocument`.

Copy an accepted import into `workRoot/<UUID>/Data` in `stagePackage`; validate the staged copy again so installation never depends on the external security-scoped URL remaining available.

- [ ] **Step 7: Run all service tests and confirm GREEN**

Run: `swift test --filter KnitNoteBackupServiceTests`

Expected: every package creation and validation test passes.

- [ ] **Step 8: Commit package creation and validation**

```bash
git add Sources/KnitNoteCore/Backup/KnitNoteBackupService.swift Tests/KnitNoteCoreTests/KnitNoteBackupServiceTests.swift
git commit -m "Build and validate complete backup packages"
```

### Task 3: Atomic installation, rollback, and store serialization

**Files:**
- Modify: `Sources/KnitNoteCore/Backup/KnitNoteBackupService.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Tests/KnitNoteCoreTests/KnitNoteBackupServiceTests.swift`
- Modify: `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`

**Interfaces:**
- Consumes: `StagedKnitNoteBackup` and package service methods from Task 2.
- Produces: `KnitNoteBackupInstallation`, `install(_:)`, `commit(_:)`, `rollback(_:)`, `JSONProjectStore.isDataOperationInProgress`, `exportBackup(appVersion:)`, `prepareBackupRestore(from:)`, `cancelBackupRestore(_:)`, `cleanupBackupArtifact(at:)`, `restoreBackup(_:)`, and `reloadFromDisk()`.

- [ ] **Step 1: Write failing install/rollback service tests**

```swift
@Test func installKeepsRollbackUntilExplicitCommit() throws {
    let fixture = try BackupInstallFixture.make()
    defer { fixture.cleanup() }
    let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)
    let installation = try fixture.service.install(staged)
    #expect(try fixture.liveArchiveName() == "replacement")
    #expect(FileManager.default.fileExists(atPath: installation.rollbackRoot.path))
    try fixture.service.commit(installation)
    #expect(!FileManager.default.fileExists(atPath: installation.rollbackRoot.path))
}

@Test func rollbackRestoresOriginalArchive() throws {
    let fixture = try BackupInstallFixture.make()
    defer { fixture.cleanup() }
    let installation = try fixture.service.install(try fixture.service.stagePackage(at: fixture.replacementPackage))
    try fixture.service.rollback(installation)
    #expect(try fixture.liveArchiveName() == "original")
}
```

Add injected step-failure tests for failure before live rename, after rollback rename, after staged rename, during commit cleanup, and during rollback. Assert the exact typed result: original preserved versus rollback failed.

- [ ] **Step 2: Run focused install tests and confirm RED**

Run: `swift test --filter KnitNoteBackupServiceTests.install`

Expected: compilation fails because installation APIs do not exist.

- [ ] **Step 3: Implement same-volume atomic installation**

```swift
public struct KnitNoteBackupInstallation: Sendable {
    public let liveRoot: URL
    public let rollbackRoot: URL
}

enum KnitNoteBackupReplacementStep: Sendable {
    case beforeLiveMove
    case afterLiveMove
    case afterStagedMove
    case beforeRollback
    case beforeCommitCleanup
}

public extension KnitNoteBackupService {
    func install(_ staged: StagedKnitNoteBackup) throws -> KnitNoteBackupInstallation
    func commit(_ installation: KnitNoteBackupInstallation) throws
    func rollback(_ installation: KnitNoteBackupInstallation) throws
    func recoverInterruptedReplacement() throws
}
```

Add an internal test initializer `init(liveRoot:workRoot:replacementStepHook:)` whose hook defaults to `{ _ in }` from the public initializer and is called at each `KnitNoteBackupReplacementStep`. Create `workRoot` beside `liveRoot` for production so `moveItem` stays on one volume. `install` moves live to a unique rollback directory, moves staged `Data` to live, and restores rollback immediately if the second move fails. `commit` removes rollback only. `rollback` removes incomplete live and moves rollback back. `recoverInterruptedReplacement` favors an existing valid live root; when live is absent and exactly one valid rollback exists, restore it.

- [ ] **Step 4: Run service install tests and confirm GREEN**

Run: `swift test --filter KnitNoteBackupServiceTests`

Expected: all creation, validation, installation, and rollback tests pass.

- [ ] **Step 5: Write failing store reload and operation-lock tests**

```swift
@MainActor @Test func reloadReplacesPublishedProjectsAndYarns() throws {
    let fixture = try StoreBackupFixture.make()
    defer { fixture.cleanup() }
    let store = JSONProjectStore(url: fixture.archiveURL)
    try fixture.writeReplacementArchive()
    try store.reloadFromDisk()
    #expect(store.projects.map(\.name) == ["Restored project"])
    #expect(store.yarns.map(\.name) == ["Restored yarn"])
}

@MainActor @Test func mutationIsRejectedWhileDataOperationRuns() async throws {
    let fixture = try StoreBackupFixture.make(blockBackupUntilReleased: true)
    defer { fixture.cleanup() }
    let store = fixture.store
    async let export = store.exportBackup(appVersion: "1.0")
    await fixture.waitUntilBackupStarted()
    #expect(throws: KnitNoteBackupError.operationInProgress) { try store.add(name: "Blocked") }
    fixture.releaseBackup()
    _ = try await export
}
```

- [ ] **Step 6: Implement store coordination and reload semantics**

Add:

```swift
@Published public private(set) var isDataOperationInProgress = false

public func reloadFromDisk() throws
public func exportBackup(appVersion: String) async throws -> URL
public func prepareBackupRestore(from packageURL: URL) async throws -> StagedKnitNoteBackup
public func cancelBackupRestore(_ backup: StagedKnitNoteBackup)
public func cleanupBackupArtifact(at url: URL)
public func restoreBackup(_ backup: StagedKnitNoteBackup) async throws
```

Refactor private `load()` into a decoding helper that returns validated arrays before publishing. `reloadFromDisk()` must throw without changing published arrays when decoding fails. Make `ensureArchiveAvailable()` also reject `isDataOperationInProgress`. Export and restore set the flag with `defer`, reject starting while `activeJournalPhotoTransactions > 0`, run service filesystem work away from the main actor, and restore performs install → reload → commit on the already validated private staging copy. If reload fails, call rollback and reload the original archive before throwing `.installFailedOriginalPreserved`; if rollback or original reload fails, throw `.rollbackFailed`.

`prepareBackupRestore` keeps security-scoped access entirely inside its call, invokes `stagePackage`, and returns the app-owned staged copy. It does not set the destructive-operation flag because it never touches live data. `cancelBackupRestore` removes that staged root. `restoreBackup` accepts only a service-produced staged value and validates it once more immediately before installation.

- [ ] **Step 7: Run store and service tests and confirm GREEN**

Run: `swift test --filter JSONProjectStoreTests && swift test --filter KnitNoteBackupServiceTests`

Expected: all focused tests pass with mutation exclusion and rollback behavior verified.

- [ ] **Step 8: Commit atomic restore and store coordination**

```bash
git add Sources/KnitNoteCore/Backup/KnitNoteBackupService.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/KnitNoteBackupServiceTests.swift Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift
git commit -m "Restore backups atomically with rollback"
```

### Task 4: Localized Settings export/import workflow

**Files:**
- Create: `KnitNote/Settings/KnitNoteBackupDocument.swift`
- Create: `KnitNote/Settings/BackupSettingsSection.swift`
- Modify: `KnitNote/Settings/SettingsView.swift`
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Create: `Tests/KnitNoteCoreTests/BackupSettingsViewContractTests.swift`

**Interfaces:**
- Consumes: the five `JSONProjectStore` backup APIs and `StagedKnitNoteBackup.preview` from Task 3.
- Produces: a Settings section with package export, security-scoped import, destructive preview confirmation, progress disabling, and localized result alerts.

- [ ] **Step 1: Write failing UI/localization contract tests**

```swift
import Foundation
import Testing

@Suite struct BackupSettingsViewContractTests {
    @Test func settingsContainsBackupSectionAndBothSystemPickers() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let settings = try String(contentsOf: root.appendingPathComponent("KnitNote/Settings/SettingsView.swift"))
        let backup = try String(contentsOf: root.appendingPathComponent("KnitNote/Settings/BackupSettingsSection.swift"))
        #expect(settings.contains("BackupSettingsSection()"))
        #expect(backup.contains("fileExporter"))
        #expect(backup.contains("fileImporter"))
        #expect(backup.contains("confirmationDialog"))
        #expect(backup.contains("isDataOperationInProgress"))
        #expect(backup.contains("startAccessingSecurityScopedResource"))
    }

    @Test func everyBackupKeyHasEnglishAndTraditionalChinese() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let catalogData = try Data(contentsOf: root.appendingPathComponent("KnitNote/Localization/Localizable.xcstrings"))
        let catalog = try #require(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        for key in BackupLocalizationContract.requiredKeys {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            #expect(localizations["en"] != nil)
            #expect(localizations["zh-Hant"] != nil)
        }
    }
}
```

The required key list must include section title, export, restore, preview date/projects/yarns, replacement warning, confirm, cancel, preparing, restoring, export success, restore success, all six user-facing error categories, and accessibility labels.

- [ ] **Step 2: Run UI tests and confirm RED**

Run: `swift test --filter BackupSettingsViewContractTests`

Expected: tests fail because the new Settings files and keys are missing.

- [ ] **Step 3: Implement the custom package document**

```swift
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let knitNoteBackup = UTType(filenameExtension: "knitnote-backup", conformingTo: .package)!
}

struct KnitNoteBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.knitNoteBackup] }
    let packageWrapper: FileWrapper

    init(packageURL: URL) throws {
        packageWrapper = try FileWrapper(url: packageURL)
    }

    init(configuration: ReadConfiguration) throws {
        guard configuration.file.isDirectory else { throw CocoaError(.fileReadCorruptFile) }
        packageWrapper = configuration.file
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        packageWrapper
    }
}
```

- [ ] **Step 4: Implement the backup Settings section**

`BackupSettingsSection` uses `@EnvironmentObject private var store: JSONProjectStore` and localized state. Export calls `store.exportBackup`, wraps the returned URL, and presents `.fileExporter` with `KnitNote-YYYY-MM-DD` as the default filename. Import uses `.fileImporter(allowedContentTypes: [.knitNoteBackup])`, calls `startAccessingSecurityScopedResource()`, holds access until `prepareBackupRestore` has copied and validated the package, then calls `stopAccessingSecurityScopedResource()` and shows the staged copy's preview plus replacement warning. Confirmation calls `restoreBackup(_:)` with that app-owned staged value and shows localized success.

Use `StagedKnitNoteBackup` directly as the pending restore value. If preparation fails, the service deletes any partial staged copy. When confirmation is cancelled, call `store.cancelBackupRestore(_:)`. On view disappearance, cancel any unused staged restore and delete temporary export artifacts through `store.cleanupBackupArtifact(at:)`.

Map errors to a small `BackupUserMessage` enum so filesystem paths are never included in alert text. Disable both rows when `store.isDataOperationInProgress` or local inspection is active, and show `ProgressView` beside the active row.

- [ ] **Step 5: Add Traditional Chinese and English strings**

Use copy equivalent to:

```text
backup.section = Data Backup / 資料備份
backup.export = Export Complete Backup / 匯出完整備份
backup.restore = Restore from Backup / 從備份還原
backup.replace.warning = Restoring will replace all current KnitNote data. / 還原後將取代目前所有 KnitNote 資料。
backup.restore.confirm = Replace and Restore / 取代並還原
backup.restore.success = Backup restored. / 備份已還原。
backup.restore.originalPreserved = Restore failed. Your original data was preserved. / 還原失敗，原有資料已保留。
```

Add the remaining required keys from Step 1 with equally direct wording and plural-safe project/yarn count format strings.

- [ ] **Step 6: Insert the section and run UI tests**

Add `BackupSettingsSection()` after the calculator section in `SettingsView`.

Run: `swift test --filter BackupSettingsViewContractTests`

Expected: all Settings and localization contract tests pass.

- [ ] **Step 7: Regenerate and build the application**

Run: `xcodegen generate`

Expected: `KnitNote.xcodeproj` includes both new Settings files and both new KnitNoteCore backup files.

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteBackupBuild CODE_SIGNING_ALLOWED=NO build`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 8: Commit the Settings workflow**

```bash
git add KnitNote/Settings/KnitNoteBackupDocument.swift KnitNote/Settings/BackupSettingsSection.swift KnitNote/Settings/SettingsView.swift KnitNote/Localization/Localizable.xcstrings Tests/KnitNoteCoreTests/BackupSettingsViewContractTests.swift project.yml KnitNote.xcodeproj/project.pbxproj
git commit -m "Add localized backup and restore settings"
```

### Task 5: Interrupted-operation recovery and end-to-end verification

**Files:**
- Modify: `KnitNote/App/KnitNoteApp.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`
- Modify: `docs/superpowers/specs/2026-07-20-complete-backup-and-restore-design.md` only if verification reveals an actual documented behavior correction.

**Interfaces:**
- Consumes: `recoverInterruptedReplacement()` and all UI/store/package behavior from Tasks 1–4.
- Produces: launch-time recovery, complete regression evidence, and a user-verifiable handoff.

- [ ] **Step 1: Write failing interrupted-launch recovery tests**

```swift
@MainActor @Test func liveStoreRecoversRollbackWhenLiveRootIsMissing() throws {
    let fixture = try StoreBackupFixture.interruptedAfterLiveRename()
    defer { fixture.cleanup() }
    let store = JSONProjectStore.live(baseDirectory: fixture.applicationSupport)
    #expect(store.projects.map(\.name) == ["Original project"])
    #expect(store.loadError == nil)
}

@MainActor @Test func validLiveRootWinsOverStaleRollback() throws {
    let fixture = try StoreBackupFixture.validLiveWithStaleRollback()
    defer { fixture.cleanup() }
    let store = JSONProjectStore.live(baseDirectory: fixture.applicationSupport)
    #expect(store.projects.map(\.name) == ["Installed project"])
    #expect(!FileManager.default.fileExists(atPath: fixture.rollbackRoot.path))
}
```

- [ ] **Step 2: Run recovery tests and confirm RED**

Run: `swift test --filter JSONProjectStoreTests.liveStoreRecoversRollback`

Expected: the test fails because live initialization does not recover interrupted replacement state.

- [ ] **Step 3: Recover before initial store load**

Add `JSONProjectStore.live(baseDirectory:)` for testability. It constructs the live/work roots, calls `KnitNoteBackupService.recoverInterruptedReplacement()`, and then initializes the store from `projects-v1.json`. Production `live()` delegates to the Application Support base URL. If recovery itself fails, initialize with a visible `.unreadableArchive` state rather than deleting either candidate root.

Keep `KnitNoteApp`'s `@StateObject private var projectStore = JSONProjectStore.live()` unchanged unless initialization must move into a small factory to satisfy actor isolation.

- [ ] **Step 4: Run recovery and full test suites**

Run: `swift test --filter JSONProjectStoreTests`

Expected: every store test passes.

Run: `swift test`

Expected: all suites pass with no failures.

- [ ] **Step 5: Verify localization and repository hygiene**

Run: `rg -n 'backup\.' KnitNote/Localization/Localizable.xcstrings KnitNote/Settings`

Expected: every UI key used by the Settings files exists in the catalog.

Run: `git diff --check`

Expected: no whitespace errors.

Run: `git status --short`

Expected: only intentional backup feature files plus the pre-existing untracked `.superpowers/`, `KnitNote 5.xcodeproj/`, and `KnitNote 6.xcodeproj/` appear.

- [ ] **Step 6: Build iOS and macOS targets**

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteBackupFinalIOS CODE_SIGNING_ALLOWED=NO build`

Expected: `BUILD SUCCEEDED` or a documented environment-only CoreSimulator availability failure after Swift compilation succeeds.

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteBackupFinalMac CODE_SIGNING_ALLOWED=NO build`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Perform manual acceptance on both form factors when runtimes are available**

On iPhone and iPad simulators: create a project with renamed counters, row note, journal photo/caption, project photo, yarn photo/link, PDF pattern, non-first page reading state, horizontal/vertical highlight, page note, and markup. Export a backup, change/delete the data, restore, confirm the preview counts, and verify every item returns. Then import a deliberately damaged package and confirm current data remains unchanged.

- [ ] **Step 8: Commit recovery and verification changes**

```bash
git add KnitNote/App/KnitNoteApp.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift docs/superpowers/specs/2026-07-20-complete-backup-and-restore-design.md
git commit -m "Recover interrupted backup restores safely"
```

---

## Completion criteria

- A backup made on iPhone, iPad, or Mac appears as one `.knitnote-backup` document.
- A valid backup restores every managed record and referenced media file after explicit replacement confirmation.
- A corrupt, hostile, incomplete, oversized, or newer backup cannot alter current data.
- A failure after replacement begins either restores the original archive and files or presents the distinct rollback-failure state without claiming success.
- Backup controls cannot race active mutations or journal photo writes.
- Traditional Chinese and English UI, full tests, diff checks, and available platform builds pass.
