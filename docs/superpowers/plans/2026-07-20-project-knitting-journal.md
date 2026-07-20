# Project Knitting Journal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a photo-first, manually authored knitting journal to each project, displayed as a simple horizontal row and locked read-only when the project is completed.

**Architecture:** `ProjectJournalEntry` belongs to `StoredProject`; `JSONProjectStore` owns all metadata transactions and delegates normalized full/thumbnail files to a dedicated `ProjectJournalPhotoFileService`. Focused SwiftUI views consume only store APIs, while String Catalog keys provide complete English, Traditional Chinese, date, error, and accessibility copy.

**Tech Stack:** Swift 6, SwiftUI, Foundation, Combine, ImageIO, UniformTypeIdentifiers, Swift Testing, XcodeGen, String Catalog (`.xcstrings`).

## Global Constraints

- Deployment targets remain iOS 18.0, macOS 15.0, and watchOS 11.0.
- One required photo, one optional trimmed caption, and one automatic creation date per entry.
- Full image maximum long edge is exactly 1600 pixels without upscaling; JPEG quality target is 0.8.
- A separate thumbnail is stored and the horizontal list loads thumbnails only.
- Image validation, resizing, and JPEG encoding run off the main actor; the editor shows saving progress and prevents duplicate Done actions while work is in flight.
- Entries appear newest first in one lazy horizontal row after Notes and Patterns.
- Completed projects are read-only at both UI and store layers; resume restores mutations.
- Version 1 has no badge, streak, statistic, sharing, manual date, multiple-photo, global journal, or entry-count-limit feature.
- Every new user-facing or VoiceOver string has complete `en` and `zh-Hant` catalog values.
- Preserve all unrelated dirty-worktree changes; stage and commit only files named by the current task.
- Restyling the existing Notes and Patterns buttons is a deferred follow-up and is outside this plan.

---

## File Structure

- `Sources/KnitNoteCore/Projects/ProjectJournalEntry.swift`: journal value type, validation, caption normalization, and deterministic ordering helper.
- `Sources/KnitNoteCore/Projects/StoredProject.swift`: owns journal entries and active-project mutation rules.
- `Sources/KnitNoteCore/Projects/ProjectJournalPhotoFileService.swift`: validates, downsamples, encodes, stores, removes, and reconciles full/thumbnail pairs.
- `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`: atomic journal metadata/file transactions, URLs, cleanup, archive version 9.
- `KnitNote/Projects/ProjectJournalSection.swift`: empty state, header, plus action, lazy horizontal cards.
- `KnitNote/Projects/EditProjectJournalEntryView.swift`: camera/library acquisition and add/caption editor.
- `KnitNote/Projects/ProjectJournalEntryDetailView.swift`: full photo, metadata, edit and confirmed delete.
- `KnitNote/Projects/JournalPhotoPicker.swift`: platform-guarded PhotosPicker and iOS camera wrapper.
- `KnitNote/Projects/ProjectDetailView.swift`: state and journal placement only.
- `KnitNote/Localization/Localizable.xcstrings`: journal UI, errors, confirmations, and accessibility.
- `project.yml` and generated `KnitNote.xcodeproj/project.pbxproj`: source/resource and camera-purpose integration.
- `Tests/KnitNoteCoreTests/ProjectJournalEntryTests.swift`: model and Codable tests.
- `Tests/KnitNoteCoreTests/ProjectJournalPhotoFileServiceTests.swift`: image sizing/file lifecycle tests.
- `Tests/KnitNoteCoreTests/ProjectJournalStoreTests.swift`: transaction, migration, locking, cleanup, and persistence tests.
- `Tests/KnitNoteCoreTests/ProjectJournalViewContractTests.swift`: placement, platform guards, lazy layout, completed lock, and accessibility contracts.
- `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`: exact bilingual journal catalog coverage.

---

### Task 1: Journal model and project lifecycle rules

**Files:**
- Create: `Sources/KnitNoteCore/Projects/ProjectJournalEntry.swift`
- Modify: `Sources/KnitNoteCore/Projects/StoredProject.swift`
- Create: `Tests/KnitNoteCoreTests/ProjectJournalEntryTests.swift`

**Interfaces:**
- Produces: `ProjectJournalEntry`, `ProjectJournalMutationError`, `StoredProject.journalEntries`, `addJournalEntry(_:, now:)`, `updateJournalCaption(id:caption:now:)`, and `deleteJournalEntry(id:now:)`.
- Consumes: existing `StoredProject.isCompleted`, Codable migration, and `updatedAt` behavior.

- [ ] **Step 1: Write failing model and lifecycle tests**

```swift
import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct ProjectJournalEntryTests {
    @Test func captionIsTrimmedAndBlankBecomesNil() throws {
        #expect(try ProjectJournalEntry(photoFilename: "full.jpg", thumbnailFilename: "thumb.jpg", caption: "  sleeve done  ").caption == "sleeve done")
        #expect(try ProjectJournalEntry(photoFilename: "full.jpg", thumbnailFilename: "thumb.jpg", caption: " \n ").caption == nil)
    }

    @Test func activeProjectMutatesButCompletedProjectRejectsChanges() throws {
        var project = try StoredProject(name: "Sweater")
        let entry = try ProjectJournalEntry(photoFilename: "full.jpg", thumbnailFilename: "thumb.jpg", caption: nil)
        try project.addJournalEntry(entry)
        project.markCompleted()
        #expect(throws: ProjectJournalMutationError.projectCompleted) {
            try project.updateJournalCaption(id: entry.id, caption: "Done")
        }
        #expect(throws: ProjectJournalMutationError.projectCompleted) {
            try project.deleteJournalEntry(id: entry.id)
        }
        project.resume()
        try project.updateJournalCaption(id: entry.id, caption: "Done")
        #expect(project.journalEntries.first?.caption == "Done")
    }

    @Test func legacyProjectDecodesWithEmptyJournal() throws {
        let project = try StoredProject(name: "Legacy")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        object.removeValue(forKey: "journalEntries")
        let decoded = try JSONDecoder().decode(StoredProject.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.journalEntries.isEmpty)
    }
}
```

- [ ] **Step 2: Run the focused suite and verify RED**

Run:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/knitnote-journal-clang SWIFT_MODULECACHE_PATH=/tmp/knitnote-journal-swift swift test --disable-sandbox --filter ProjectJournalEntryTests
```

Expected: compilation fails because `ProjectJournalEntry` and journal mutation APIs do not exist.

- [ ] **Step 3: Implement the journal value type**

```swift
import Foundation

public enum ProjectJournalEntryError: Error, Equatable, Sendable { case invalidFilename }
public enum ProjectJournalMutationError: Error, Equatable, Sendable { case projectCompleted, entryNotFound }

public struct ProjectJournalEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let photoFilename: String
    public let thumbnailFilename: String
    public private(set) var caption: String?
    public let createdAt: Date

    public init(id: UUID = UUID(), photoFilename: String, thumbnailFilename: String, caption: String?, createdAt: Date = .now) throws {
        let photo = photoFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        let thumbnail = thumbnailFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !photo.isEmpty, !thumbnail.isEmpty else { throw ProjectJournalEntryError.invalidFilename }
        self.id = id
        self.photoFilename = photo
        self.thumbnailFilename = thumbnail
        self.caption = Self.normalizedCaption(caption)
        self.createdAt = createdAt
    }

    public mutating func updateCaption(_ value: String?) { caption = Self.normalizedCaption(value) }
    private static func normalizedCaption(_ value: String?) -> String? {
        guard let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty else { return nil }
        return clean
    }
}
```

- [ ] **Step 4: Add `journalEntries` to `StoredProject`, Codable, and guarded mutations**

Add the property, initialize it to `[]`, add `journalEntries` to `CodingKeys`, decode with `decodeIfPresent(...) ?? []`, encode it, and use these exact methods:

```swift
public private(set) var journalEntries: [ProjectJournalEntry]

public mutating func addJournalEntry(_ entry: ProjectJournalEntry, now: Date = .now) throws {
    guard !isCompleted else { throw ProjectJournalMutationError.projectCompleted }
    guard !journalEntries.contains(where: { $0.id == entry.id }) else { return }
    journalEntries.append(entry)
    journalEntries.sort { lhs, rhs in lhs.createdAt == rhs.createdAt ? lhs.id.uuidString > rhs.id.uuidString : lhs.createdAt > rhs.createdAt }
    updatedAt = now
}

public mutating func updateJournalCaption(id: UUID, caption: String?, now: Date = .now) throws {
    guard !isCompleted else { throw ProjectJournalMutationError.projectCompleted }
    guard let index = journalEntries.firstIndex(where: { $0.id == id }) else { throw ProjectJournalMutationError.entryNotFound }
    journalEntries[index].updateCaption(caption)
    updatedAt = now
}

@discardableResult
public mutating func deleteJournalEntry(id: UUID, now: Date = .now) throws -> ProjectJournalEntry {
    guard !isCompleted else { throw ProjectJournalMutationError.projectCompleted }
    guard let index = journalEntries.firstIndex(where: { $0.id == id }) else { throw ProjectJournalMutationError.entryNotFound }
    updatedAt = now
    return journalEntries.remove(at: index)
}
```

- [ ] **Step 5: Add decode validation and ordering tests, then run focused and full suites**

Add tests for duplicate IDs, blank filenames, equal-date deterministic ordering, encode/decode preservation, and `updatedAt`. Invalid decoded entries must throw rather than introduce arbitrary file references.

Run the focused command from Step 2, then:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/knitnote-journal-clang SWIFT_MODULECACHE_PATH=/tmp/knitnote-journal-swift swift test --disable-sandbox
```

Expected: all tests pass.

- [ ] **Step 6: Commit Task 1**

```bash
git add Sources/KnitNoteCore/Projects/ProjectJournalEntry.swift Sources/KnitNoteCore/Projects/StoredProject.swift Tests/KnitNoteCoreTests/ProjectJournalEntryTests.swift
git commit -m "Add project journal model"
```

---

### Task 2: Normalized full and thumbnail image service

**Files:**
- Create: `Sources/KnitNoteCore/Projects/ProjectJournalPhotoFileService.swift`
- Create: `Tests/KnitNoteCoreTests/ProjectJournalPhotoFileServiceTests.swift`

**Interfaces:**
- Produces: `ProjectJournalPhotoFiles`, `ProjectJournalPhotoFileService.save(data:projectID:entryID:)`, `url(filename:)`, `delete(files:)`, and `reconcile(referencedFilenames:)`.
- Consumes: ImageIO and UTType JPEG; no UIKit dependency so SwiftPM/macOS tests remain valid.

- [ ] **Step 1: Write failing image and lifecycle tests**

```swift
@Test func saveCreatesUniqueFullAndThumbnailFiles() throws {
    let service = ProjectJournalPhotoFileService(directory: temporaryDirectory())
    let first = try service.save(data: fixtureJPEG(width: 2400, height: 1200), projectID: UUID(), entryID: UUID())
    let second = try service.save(data: fixtureJPEG(width: 2400, height: 1200), projectID: UUID(), entryID: UUID())
    #expect(first != second)
    #expect(FileManager.default.fileExists(atPath: service.url(filename: first.photoFilename).path))
    #expect(FileManager.default.fileExists(atPath: service.url(filename: first.thumbnailFilename).path))
}

@Test func fullImageNeverExceeds1600AndSmallImagesAreNotUpscaled() throws {
    let service = ProjectJournalPhotoFileService(directory: temporaryDirectory())
    let large = try service.save(data: fixtureJPEG(width: 2400, height: 1200), projectID: UUID(), entryID: UUID())
    #expect(pixelSize(service.url(filename: large.photoFilename)).width == 1600)
    let small = try service.save(data: fixtureJPEG(width: 640, height: 480), projectID: UUID(), entryID: UUID())
    #expect(pixelSize(service.url(filename: small.photoFilename)).width == 640)
}
```

- [ ] **Step 2: Run the focused suite and verify RED**

Run the Task 1 cache-prefixed command with `--filter ProjectJournalPhotoFileServiceTests`.

Expected: compilation fails because the service does not exist.

- [ ] **Step 3: Implement file-pair preparation and storage**

```swift
public struct ProjectJournalPhotoFiles: Equatable, Sendable {
    public let photoFilename: String
    public let thumbnailFilename: String
}

public struct ProjectJournalPhotoFileService: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func save(data: Data, projectID: UUID, entryID: UUID) throws -> ProjectJournalPhotoFiles {
        let token = UUID().uuidString
        let full = "\(projectID.uuidString)-\(entryID.uuidString)-\(token)-full.jpg"
        let thumb = "\(projectID.uuidString)-\(entryID.uuidString)-\(token)-thumb.jpg"
        let fullData = try normalizedJPEG(data: data, maximumPixelSize: 1600, quality: 0.8)
        let thumbData = try normalizedJPEG(data: data, maximumPixelSize: 360, quality: 0.8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try fullData.write(to: url(filename: full), options: .atomic)
            try thumbData.write(to: url(filename: thumb), options: .atomic)
            return .init(photoFilename: full, thumbnailFilename: thumb)
        } catch {
            try? delete(filename: full)
            try? delete(filename: thumb)
            throw error
        }
    }
}
```

Implement `normalizedJPEG` with `CGImageSourceCreateThumbnailAtIndex`, `kCGImageSourceCreateThumbnailWithTransform`, a maximum size of `min(originalLongEdge, requestedMaximum)`, and `CGImageDestinationAddImage`. Reject undecodable input with `ProjectJournalPhotoFileError.invalidImage`.

- [ ] **Step 4: Implement idempotent pair deletion and trusted reconciliation**

```swift
public func delete(files: ProjectJournalPhotoFiles) throws {
    try delete(filename: files.photoFilename)
    try delete(filename: files.thumbnailFilename)
}

public func reconcile(referencedFilenames: Set<String>) throws {
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    for file in try FileManager.default.contentsOfDirectory(atPath: directory.path)
        where !referencedFilenames.contains(file) {
        try delete(filename: file)
    }
}
```

- [ ] **Step 5: Test invalid data, orientation, cleanup, reconciliation, and rollback**

Add explicit tests for invalid bytes, orientation transform, both files removed, missing-file idempotence, only unreferenced files removed, and second-write failure removing the first candidate. Run the focused suite and full Swift tests.

- [ ] **Step 6: Commit Task 2**

```bash
git add Sources/KnitNoteCore/Projects/ProjectJournalPhotoFileService.swift Tests/KnitNoteCoreTests/ProjectJournalPhotoFileServiceTests.swift
git commit -m "Store normalized journal photos"
```

---

### Task 3: Atomic store APIs, archive migration, and cleanup

**Files:**
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Create: `Tests/KnitNoteCoreTests/ProjectJournalStoreTests.swift`
- Modify: `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`

**Interfaces:**
- Produces: async `addJournalEntry(projectID:photoData:caption:createdAt:)`, `updateJournalCaption(projectID:entryID:caption:)`, `deleteJournalEntry(projectID:entryID:)`, `journalPhotoURL(for:)`, and `journalThumbnailURL(for:)`.
- Consumes: Tasks 1–2 exact types and existing atomic `persist` behavior.

- [ ] **Step 1: Write failing store transaction tests**

```swift
@Test @MainActor func journalRoundTripsAndCompletionLocksEveryMutation() async throws {
    let fixture = try StoreFixture()
    try fixture.store.add(name: "Sweater")
    let projectID = try #require(fixture.store.projects.first?.id)
    try await fixture.store.addJournalEntry(projectID: projectID, photoData: fixtureJPEG(), caption: "  body  ", createdAt: Date(timeIntervalSince1970: 100))
    #expect(fixture.store.project(id: projectID)?.journalEntries.first?.caption == "body")
    try fixture.store.markCompleted(projectID: projectID)
    await #expect(throws: ProjectJournalMutationError.projectCompleted) {
        try await fixture.store.addJournalEntry(projectID: projectID, photoData: fixtureJPEG(), caption: nil, createdAt: .now)
    }
}
```

Add RED tests for add rollback on archive failure, delete metadata before cleanup, project deletion cleanup, relaunch persistence, another project's files remaining, unreadable archive never reconciling, and version 8 decoding to an empty journal.

- [ ] **Step 2: Run focused tests and verify RED**

Run the cache-prefixed Swift test command with `--filter ProjectJournalStoreTests`.

Expected: missing initializer/service/API failures.

- [ ] **Step 3: Inject the journal service and expose URLs**

```swift
private let journalPhotoService: ProjectJournalPhotoFileService

public init(url: URL, photoService: ProjectPhotoFileService? = nil, yarnPhotoService: YarnPhotoFileService? = nil, journalPhotoService: ProjectJournalPhotoFileService? = nil) {
    self.url = url
    self.photoService = photoService ?? .init(directory: url.deletingLastPathComponent().appendingPathComponent("ProjectPhotos", isDirectory: true))
    self.yarnPhotoService = yarnPhotoService ?? .init(directory: url.deletingLastPathComponent().appendingPathComponent("YarnPhotos", isDirectory: true))
    self.journalPhotoService = journalPhotoService ?? .init(directory: url.deletingLastPathComponent().appendingPathComponent("ProjectJournalPhotos", isDirectory: true))
    load()
}

public func journalPhotoURL(for entry: ProjectJournalEntry) -> URL? { journalPhotoService.url(filename: entry.photoFilename) }
public func journalThumbnailURL(for entry: ProjectJournalEntry) -> URL? { journalPhotoService.url(filename: entry.thumbnailFilename) }
```

- [ ] **Step 4: Implement add, update, and delete transactions**

```swift
public func addJournalEntry(projectID: UUID, photoData: Data, caption: String?, createdAt: Date = .now) async throws {
    guard let index = projects.firstIndex(where: { $0.id == projectID }) else { throw ProjectJournalMutationError.entryNotFound }
    guard !projects[index].isCompleted else { throw ProjectJournalMutationError.projectCompleted }
    try ensureArchiveAvailable()
    let entryID = UUID()
    let service = journalPhotoService
    let files = try await Task.detached(priority: .userInitiated) {
        try service.save(data: photoData, projectID: projectID, entryID: entryID)
    }.value
    do {
        let entry = try ProjectJournalEntry(id: entryID, photoFilename: files.photoFilename, thumbnailFilename: files.thumbnailFilename, caption: caption, createdAt: createdAt)
        var staged = projects
        try staged[index].addJournalEntry(entry, now: createdAt)
        try persist(projects: staged, yarns: yarns)
    } catch {
        try? journalPhotoService.delete(files: files)
        throw error
    }
}

public func deleteJournalEntry(projectID: UUID, entryID: UUID) throws {
    guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else { throw ProjectJournalMutationError.entryNotFound }
    var staged = projects
    let removed = try staged[projectIndex].deleteJournalEntry(id: entryID)
    try persist(projects: staged, yarns: yarns)
    try? journalPhotoService.delete(files: .init(photoFilename: removed.photoFilename, thumbnailFilename: removed.thumbnailFilename))
}
```

Implement caption update through a staged project and `persist`. Re-check project existence and completion in the final API call; never rely on editor state.

- [ ] **Step 5: Bump the archive to version 9 and reconcile only after trusted load/persist**

Encode `ProjectArchive(version: 9, ...)`. Add `reconcileJournalPhotos()` using the union of both filenames across all entries. Call it only after successful decode or successful persist, parallel to yarn reconciliation. Extend project deletion to capture all journal files before persist and remove them afterward.

- [ ] **Step 6: Run focused/full tests and commit Task 3**

Run `ProjectJournalStoreTests`, `JSONProjectStoreTests`, then the full suite. Expected: all pass and archives write version 9.

```bash
git add Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/ProjectJournalStoreTests.swift Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift
git commit -m "Persist project knitting journals"
```

---

### Task 4: Journal section, editor, camera/library picker, and detail view

**Files:**
- Create: `KnitNote/Projects/ProjectJournalSection.swift`
- Create: `KnitNote/Projects/EditProjectJournalEntryView.swift`
- Create: `KnitNote/Projects/ProjectJournalEntryDetailView.swift`
- Create: `KnitNote/Projects/JournalPhotoPicker.swift`
- Modify: `KnitNote/Projects/ProjectDetailView.swift`
- Modify: `project.yml`
- Regenerate: `KnitNote.xcodeproj/project.pbxproj`
- Create: `Tests/KnitNoteCoreTests/ProjectJournalViewContractTests.swift`

**Interfaces:**
- Consumes: Task 3 store APIs and existing `WatercolorBackground`, `WatercolorCard`, project completion state, and camera purpose description.
- Produces: project-detail journal UI and platform-safe photo acquisition.

- [ ] **Step 1: Write failing view contracts**

```swift
@Test func projectPlacesJournalAfterSupportButtons() throws {
    let source = try projectSource(named: "ProjectDetailView")
    let patterns = try #require(source.range(of: "supportingButton(\"patterns.open\""))
    let journal = try #require(source.range(of: "ProjectJournalSection("))
    #expect(patterns.lowerBound < journal.lowerBound)
}

@Test func journalIsLazyHorizontalAndCompletedProjectsHideMutations() throws {
    let source = try projectSource(named: "ProjectJournalSection")
    #expect(source.contains("ScrollView(.horizontal"))
    #expect(source.contains("LazyHStack"))
    #expect(source.contains("if !project.isCompleted"))
}
```

Add contracts for PhotosPicker, iOS-only camera guards, 44-point plus action, two-line captions, thumbnail URLs in cards, full URLs only in detail, delete confirmation, Dynamic Type-friendly vertical editor layout, and accessibility labels.

- [ ] **Step 2: Run contracts and verify RED**

Run the cache-prefixed Swift test command with `--filter ProjectJournalViewContractTests`.

Expected: missing view files and `ProjectJournalSection` placement.

- [ ] **Step 3: Build the focused horizontal section**

```swift
struct ProjectJournalSection: View {
    let project: StoredProject
    let thumbnailURL: (ProjectJournalEntry) -> URL
    let onAdd: () -> Void
    let onOpen: (ProjectJournalEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("journal.title").font(.headline)
                Spacer()
                if !project.isCompleted {
                    Button("journal.add", systemImage: "plus", action: onAdd)
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
            if project.journalEntries.isEmpty {
                Text(project.isCompleted ? "journal.empty.completed" : "journal.empty.active")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(project.journalEntries) { entry in
                            ProjectJournalCard(entry: entry, thumbnailURL: thumbnailURL(entry)) { onOpen(entry) }
                        }
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 4: Implement picker/editor and detail interactions**

Use `PhotosPicker` on both supported app destinations. Under `#if os(iOS)`, provide `UIImagePickerController` camera only when `UIImagePickerController.isSourceTypeAvailable(.camera)`. The editor stores selected bytes and caption draft, disables Done until bytes exist, calls Task 3 add/update APIs from a `Task`, sets `isSaving = true` before awaiting, shows a `ProgressView`, disables duplicate Done actions, and restores the draft plus a localized alert on failure. The detail uses the full URL, exposes Edit/Delete only when active, and confirms delete with a destructive role.

- [ ] **Step 5: Place the journal and wire sheets**

Add `showingJournalEditor` and `selectedJournalEntry` state to `ProjectDetailView`. Insert:

```swift
WatercolorCard {
    ProjectJournalSection(
        project: project,
        thumbnailURL: store.journalThumbnailURL(for:),
        onAdd: { showingJournalEditor = true },
        onOpen: { selectedJournalEntry = $0 }
    )
}
```

after the Notes/Patterns `HStack` and before recent notes. Present add/editor and detail sheets by stable entry ID so a deleted project/entry dismisses safely.

- [ ] **Step 6: Generate the project, run contracts/full tests, build, and commit**

```bash
xcodegen generate
CLANG_MODULE_CACHE_PATH=/tmp/knitnote-journal-clang SWIFT_MODULECACHE_PATH=/tmp/knitnote-journal-swift swift test --disable-sandbox --filter ProjectJournalViewContractTests
CLANG_MODULE_CACHE_PATH=/tmp/knitnote-journal-clang SWIFT_MODULECACHE_PATH=/tmp/knitnote-journal-swift swift test --disable-sandbox
xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=macOS' -derivedDataPath /tmp/KnitNoteJournalMac CODE_SIGNING_ALLOWED=NO build
```

Expected: all commands exit 0.

```bash
git add KnitNote/Projects/ProjectJournalSection.swift KnitNote/Projects/EditProjectJournalEntryView.swift KnitNote/Projects/ProjectJournalEntryDetailView.swift KnitNote/Projects/JournalPhotoPicker.swift KnitNote/Projects/ProjectDetailView.swift Tests/KnitNoteCoreTests/ProjectJournalViewContractTests.swift project.yml KnitNote.xcodeproj/project.pbxproj
git commit -m "Add project knitting journal interface"
```

---

### Task 5: English, Traditional Chinese, dates, and accessibility

**Files:**
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/ProjectJournalViewContractTests.swift`

**Interfaces:**
- Consumes: every `journal.*` key referenced by Task 4.
- Produces: exact bilingual copy and named full accessibility formats whose placeholder order may differ by language.

- [ ] **Step 1: Add failing exact-copy and placeholder tests**

Require complete `en` and `zh-Hant` values for:

```text
journal.title
journal.add
journal.empty.active
journal.empty.completed
journal.source.camera
journal.source.library
journal.caption
journal.done
journal.edit
journal.delete
journal.delete.confirm.title
journal.delete.confirm.message
journal.readOnly.completed
journal.error.invalidImage
journal.error.saveFailed
journal.error.projectUnavailable
journal.card.accessibility.withCaption.format
journal.card.accessibility.withoutCaption.format
```

Assert the two accessibility formats each have exactly the intended `%@` arguments and no concatenated sentence fragments.

- [ ] **Step 2: Run localization contracts and verify RED**

Run the cache-prefixed test command with `--filter LocalizationContractTests`.

Expected: missing `journal.*` catalog entries.

- [ ] **Step 3: Add natural bilingual catalog values**

Use these exact primary values:

```text
journal.title: en "Knitting Journal"; zh-Hant "編織日記"
journal.add: en "Add journal entry"; zh-Hant "新增日記"
journal.empty.active: en "Record the first progress on this project."; zh-Hant "記錄這件作品的第一個進度吧"
journal.empty.completed: en "No journal entries were recorded."; zh-Hant "這件作品沒有日記紀錄"
journal.readOnly.completed: en "This completed project's journal is read-only."; zh-Hant "作品已完成，編織日記僅供查看"
```

Translate all remaining keys as complete phrases, using `%@` only in the two named card accessibility formats. Format entry dates with SwiftUI `Text(entry.createdAt, format: .dateTime.year().month().day())` under the existing region-preserving app locale.

- [ ] **Step 4: Wire accessible card semantics and validate catalog JSON**

Make each card one element with `.accessibilityElement(children: .ignore)`, a localized label containing optional caption plus date, and button trait. Ensure add, source, edit, and delete controls retain visible or explicit labels and 44-point targets.

Run:

```bash
jq empty KnitNote/Localization/Localizable.xcstrings
CLANG_MODULE_CACHE_PATH=/tmp/knitnote-journal-clang SWIFT_MODULECACHE_PATH=/tmp/knitnote-journal-swift swift test --disable-sandbox --filter LocalizationContractTests
CLANG_MODULE_CACHE_PATH=/tmp/knitnote-journal-clang SWIFT_MODULECACHE_PATH=/tmp/knitnote-journal-swift swift test --disable-sandbox --filter ProjectJournalViewContractTests
```

Expected: JSON and both suites pass.

- [ ] **Step 5: Run the full suite/build and commit Task 5**

Run full Swift tests, `xcodegen generate`, the generic macOS build, and `git diff --check`.

```bash
git add KnitNote/Localization/Localizable.xcstrings KnitNote/Projects/ProjectJournalSection.swift KnitNote/Projects/EditProjectJournalEntryView.swift KnitNote/Projects/ProjectJournalEntryDetailView.swift Tests/KnitNoteCoreTests/LocalizationContractTests.swift Tests/KnitNoteCoreTests/ProjectJournalViewContractTests.swift KnitNote.xcodeproj/project.pbxproj
git commit -m "Localize project knitting journal"
```

---

### Task 6: Final regression and device acceptance

**Files:**
- Modify only if verification reveals a defect in files named by Tasks 1–5.
- Create: `.superpowers/sdd/project-journal-final-report.md`

**Interfaces:**
- Consumes: completed Tasks 1–5.
- Produces: reproducible verification evidence and an explicit simulator/device gate.

- [ ] **Step 1: Run all focused suites**

```bash
CLANG_MODULE_CACHE_PATH=/tmp/knitnote-journal-final-clang SWIFT_MODULECACHE_PATH=/tmp/knitnote-journal-final-swift swift test --disable-sandbox --filter ProjectJournalEntryTests
CLANG_MODULE_CACHE_PATH=/tmp/knitnote-journal-final-clang SWIFT_MODULECACHE_PATH=/tmp/knitnote-journal-final-swift swift test --disable-sandbox --filter ProjectJournalPhotoFileServiceTests
CLANG_MODULE_CACHE_PATH=/tmp/knitnote-journal-final-clang SWIFT_MODULECACHE_PATH=/tmp/knitnote-journal-final-swift swift test --disable-sandbox --filter ProjectJournalStoreTests
CLANG_MODULE_CACHE_PATH=/tmp/knitnote-journal-final-clang SWIFT_MODULECACHE_PATH=/tmp/knitnote-journal-final-swift swift test --disable-sandbox --filter ProjectJournalViewContractTests
CLANG_MODULE_CACHE_PATH=/tmp/knitnote-journal-final-clang SWIFT_MODULECACHE_PATH=/tmp/knitnote-journal-final-swift swift test --disable-sandbox --filter LocalizationContractTests
```

Expected: every suite reports zero failures.

- [ ] **Step 2: Run complete generation, tests, validation, and builds**

```bash
xcodegen generate
jq empty KnitNote/Localization/Localizable.xcstrings
CLANG_MODULE_CACHE_PATH=/tmp/knitnote-journal-final-clang SWIFT_MODULECACHE_PATH=/tmp/knitnote-journal-final-swift swift test --disable-sandbox
xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=macOS' -derivedDataPath /tmp/KnitNoteJournalFinalMac CODE_SIGNING_ALLOWED=NO build
xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteJournalFinalIOS CODE_SIGNING_ALLOWED=NO build
git diff --check
```

Expected: all available commands exit 0. If CoreSimulator reports no runtime or connection failure, record the exact output as an environment gate rather than claiming iOS acceptance.

- [ ] **Step 3: Complete iPhone and iPad interaction checks when a runtime is available**

On both device classes verify: active empty state; camera availability behavior; library add; optional blank caption; newest-first horizontal scrolling; thumbnails stay clipped; full image opens; edit and confirmed delete; completed project hides all mutations but keeps viewing; resume restores mutations; relaunch preserves entries; deleting the project removes journal files; Traditional Chinese and English; large Dynamic Type; VoiceOver labels.

- [ ] **Step 4: Write the final evidence report**

Record commands, exit codes, test counts, build destinations, simulator availability, device checklist results, unresolved gates, and `git status --short` in `.superpowers/sdd/project-journal-final-report.md`. Do not describe an unrun iPhone/iPad check as passed.

- [ ] **Step 5: Commit verification-only corrections and report**

```bash
git add .superpowers/sdd/project-journal-final-report.md
git commit -m "Verify project knitting journal"
```
