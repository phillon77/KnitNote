# Yarn Library V1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a bilingual photo-based yarn inventory that records balls and grams, links each yarn to multiple projects, and preserves all existing project data.

**Architecture:** Add a focused `StoredYarn` domain model and persist `[StoredYarn]` beside `[StoredProject]` in `ProjectArchive` version 8. Extend `JSONProjectStore` with transactional yarn and photo operations, then replace the yarn placeholder tab with small SwiftUI list, detail, and editor views that reuse the existing project photo and watercolor patterns.

**Tech Stack:** Swift 6, SwiftUI, Combine, PhotosUI, ImageIO, Foundation JSON Codable, Swift Testing, Xcode 26 project.

## Global Constraints

- Support iOS 18, macOS 15, and the existing project targets without adding third-party dependencies.
- Only the yarn name is required; every other editor field is optional.
- Store balls and grams as independent optional non-negative decimal values.
- One yarn may link to multiple projects; different colors are separate yarn records.
- V1 supports Traditional Chinese and English.
- V1 does not add search, filters, low-stock alerts, automatic consumption, or material-gap estimation.
- Preserve the current watercolor theme, 44×44 point controls, device safe areas, and all existing project, pattern, counter, and note data.

---

### Task 1: Yarn Domain Model and Validation

**Files:**
- Create: `Sources/KnitNoteCore/Yarn/StoredYarn.swift`
- Create: `Tests/KnitNoteCoreTests/StoredYarnTests.swift`

**Interfaces:**
- Produces: `StoredYarn`, `YarnValidationError`, `rename(to:)`, `updateInventory(balls:grams:)`, `updateDetails(brand:series:color:colorCode:dyeLot:storageLocation:notes:)`, `setPhotoFilename(_:)`, and `setLinkedProjectIDs(_:)`.
- Consumes: Foundation `UUID`, `Date`, `Decimal`, `Codable`, and `Sendable`.

- [ ] **Step 1: Write failing model tests**

```swift
import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct StoredYarnTests {
    @Test func nameIsTheOnlyRequiredField() throws {
        let yarn = try StoredYarn(name: "  Merino  ")
        #expect(yarn.name == "Merino")
        #expect(yarn.remainingBalls == nil)
        #expect(yarn.remainingGrams == nil)
        #expect(yarn.linkedProjectIDs.isEmpty)
    }

    @Test func inventoryAcceptsIndependentDecimalsAndRejectsNegatives() throws {
        var yarn = try StoredYarn(name: "Merino")
        try yarn.updateInventory(balls: Decimal(string: "2.5"), grams: 86)
        #expect(yarn.remainingBalls == Decimal(string: "2.5"))
        #expect(yarn.remainingGrams == 86)
        #expect(throws: YarnValidationError.negativeInventory) {
            try yarn.updateInventory(balls: -1, grams: nil)
        }
    }

    @Test func yarnRoundTripPreservesDetailsAndLinks() throws {
        let projectIDs = [UUID(), UUID()]
        var yarn = try StoredYarn(name: "Cotton")
        try yarn.updateDetails(brand: "Brand", series: "Summer", color: "Blue", colorCode: "B12", dyeLot: "L7", storageLocation: "Box A", notes: "Soft")
        yarn.setLinkedProjectIDs(Set(projectIDs))
        let decoded = try JSONDecoder().decode(StoredYarn.self, from: JSONEncoder().encode(yarn))
        #expect(decoded == yarn)
    }
}
```

- [ ] **Step 2: Run the model tests and confirm the missing-type failure**

Run: `HOME=/tmp/knitnote-home swift test --disable-sandbox --filter StoredYarnTests`

Expected: FAIL because `StoredYarn` and `YarnValidationError` do not exist.

- [ ] **Step 3: Implement the focused yarn model**

```swift
public enum YarnValidationError: Error, Equatable, Sendable {
    case emptyName
    case negativeInventory
}

public struct StoredYarn: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public private(set) var name: String
    public private(set) var photoFilename: String?
    public private(set) var brand: String?
    public private(set) var series: String?
    public private(set) var color: String?
    public private(set) var colorCode: String?
    public private(set) var dyeLot: String?
    public private(set) var remainingBalls: Decimal?
    public private(set) var remainingGrams: Decimal?
    public private(set) var storageLocation: String?
    public private(set) var notes: String?
    public private(set) var linkedProjectIDs: Set<UUID>
    public let createdAt: Date
    public private(set) var updatedAt: Date
}
```

Normalize all optional strings by trimming whitespace and converting empty strings to `nil`. Reject either inventory value when it is less than zero. Update `updatedAt` only when a value actually changes.

- [ ] **Step 4: Run model tests**

Run: `HOME=/tmp/knitnote-home swift test --disable-sandbox --filter StoredYarnTests`

Expected: PASS with 3 tests.

- [ ] **Step 5: Commit the domain model**

```bash
git add Sources/KnitNoteCore/Yarn/StoredYarn.swift Tests/KnitNoteCoreTests/StoredYarnTests.swift
git commit -m "feat: add yarn inventory model"
```

### Task 2: Archive V8 and Transactional Yarn Store

**Files:**
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`

**Interfaces:**
- Consumes: `StoredYarn` from Task 1 and existing `StoredProject`.
- Produces: published `yarns`, `addYarn(_:)`, `updateYarn(_:)`, `deleteYarn(id:)`, `yarn(id:)`, and `setYarnProjects(yarnID:projectIDs:)`.

- [ ] **Step 1: Add failing archive and store tests**

```swift
@Test @MainActor func legacyArchiveLoadsWithEmptyYarnLibrary() throws {
    let projectData = try JSONEncoder().encode(try StoredProject(name: "Scarf"))
    let projectJSON = try #require(String(data: projectData, encoding: .utf8))
    let fixture = Data("{\"version\":7,\"projects\":[\(projectJSON)]}".utf8)
    try fixture.write(to: storeURL, options: .atomic)
    let store = JSONProjectStore(url: storeURL)
    #expect(store.projects.count == 1)
    #expect(store.yarns.isEmpty)
}

@Test @MainActor func yarnCRUDAndLinksPersistAcrossStoreInstances() throws {
    let store = JSONProjectStore(url: storeURL)
    try store.add(name: "Scarf")
    let projectID = try #require(store.projects.first?.id)
    let yarn = try StoredYarn(name: "Merino")
    try store.addYarn(yarn)
    try store.setYarnProjects(yarnID: yarn.id, projectIDs: [projectID])
    let reloaded = JSONProjectStore(url: storeURL)
    #expect(reloaded.yarn(id: yarn.id)?.linkedProjectIDs == [projectID])
}
```

- [ ] **Step 2: Run the two tests and confirm they fail**

Run: `HOME=/tmp/knitnote-home swift test --disable-sandbox --filter JSONProjectStoreTests`

Expected: FAIL because the archive and store have no yarn collection.

- [ ] **Step 3: Upgrade the archive without breaking legacy decoding**

```swift
public struct ProjectArchive: Codable, Sendable {
    public let version: Int
    public var projects: [StoredProject]
    public var yarns: [StoredYarn]

    public init(version: Int, projects: [StoredProject], yarns: [StoredYarn] = []) {
        self.version = version
        self.projects = projects
        self.yarns = yarns
    }

    private enum CodingKeys: String, CodingKey { case version, projects, yarns }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        projects = try values.decode([StoredProject].self, forKey: .projects)
        yarns = try values.decodeIfPresent([StoredYarn].self, forKey: .yarns) ?? []
    }
}
```

Persist archive version `8`; sort projects and yarns independently by `updatedAt`. Stage both collections before atomic writes so failed writes do not publish partial state.

- [ ] **Step 4: Implement yarn CRUD and link cleanup**

Add `@Published public private(set) var yarns: [StoredYarn] = []`. Reject links to project IDs that are not present. Extend `delete(id:)` so it removes the deleted project ID from every yarn in the same atomic archive write before deleting the project photo.

- [ ] **Step 5: Run archive and store tests**

Run: `HOME=/tmp/knitnote-home swift test --disable-sandbox --filter JSONProjectStoreTests`

Expected: PASS, including all existing version and project persistence tests.

- [ ] **Step 6: Commit archive and CRUD changes**

```bash
git add Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift
git commit -m "feat: persist yarn library and project links"
```

### Task 3: Yarn Photo Persistence

**Files:**
- Create: `Sources/KnitNoteCore/Yarn/YarnPhotoFileService.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Create: `Tests/KnitNoteCoreTests/YarnPhotoFileServiceTests.swift`
- Modify: `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`

**Interfaces:**
- Produces: `YarnPhotoFileService.save(data:yarnID:)`, `url(filename:)`, `delete(filename:)`, `YarnPhotoChange`, `addYarn(_:photoData:)`, `updateYarn(_:photoChange:)`, and `photoURL(for:)`.
- Consumes: `StoredYarn.setPhotoFilename(_:)` and the transactional store from Task 2.

- [ ] **Step 1: Write failing valid, invalid, replace, and rollback tests**

```swift
@Test func invalidYarnPhotoIsRejected() throws {
    let service = YarnPhotoFileService(directory: photosURL)
    #expect(throws: YarnPhotoFileError.invalidImage) {
        try service.save(data: Data("not-image".utf8), yarnID: UUID())
    }
}

@Test @MainActor func failedYarnPhotoReplacementPreservesCommittedPhoto() throws {
    let store = JSONProjectStore(url: storeURL, yarnPhotoService: .init(directory: photosURL))
    let yarn = try StoredYarn(name: "Merino")
    try store.addYarn(yarn, photoData: validPNGData)
    let original = store.yarn(id: yarn.id)?.photoFilename
    #expect(throws: YarnPhotoFileError.invalidImage) {
        try store.updateYarn(yarn, photoChange: .replace(Data("bad".utf8)))
    }
    #expect(store.yarn(id: yarn.id)?.photoFilename == original)
}
```

- [ ] **Step 2: Run photo tests and verify failure**

Run: `HOME=/tmp/knitnote-home swift test --disable-sandbox --filter YarnPhotoFileServiceTests`

Expected: FAIL because the yarn photo service does not exist.

- [ ] **Step 3: Implement normalized JPEG storage**

Mirror the proven `ProjectPhotoFileService` ImageIO pipeline, but save into `YarnPhotos` with filenames in the form `yarnID-randomUUID.jpg`. Validate before creating files, cap thumbnails at 1600 pixels, encode JPEG at quality `0.86`, and use atomic writes.

- [ ] **Step 4: Make add, replace, remove, and delete transactional**

Save a new photo before archive persistence, delete it on persistence failure, and delete the old photo only after the new archive is committed. Deleting yarn removes its photo after the archive write succeeds.

- [ ] **Step 5: Run photo and store tests**

Run: `HOME=/tmp/knitnote-home swift test --disable-sandbox --filter 'YarnPhotoFileServiceTests|JSONProjectStoreTests'`

Expected: PASS with no orphaned files in rollback cases.

- [ ] **Step 6: Commit photo support**

```bash
git add Sources/KnitNoteCore/Yarn/YarnPhotoFileService.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/YarnPhotoFileServiceTests.swift Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift
git commit -m "feat: persist yarn photos safely"
```

### Task 4: Reusable Yarn Editor and Photo Picker

**Files:**
- Create: `KnitNote/Yarn/YarnPhotoView.swift`
- Create: `KnitNote/Yarn/YarnPhotoPicker.swift`
- Create: `KnitNote/Yarn/YarnEditorFields.swift`
- Create: `KnitNote/Yarn/CreateYarnView.swift`
- Create: `KnitNote/Yarn/EditYarnView.swift`
- Create: `KnitNote/Yarn/ChooseYarnProjectsView.swift`
- Create: `Tests/KnitNoteCoreTests/YarnViewContractTests.swift`
- Modify: `KnitNote.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: store yarn CRUD and photo APIs from Tasks 2–3, existing `CameraCaptureView`, project list, watercolor components, and localization keys from Task 6.
- Produces: create/edit sheets and project multi-selection UI.

- [ ] **Step 1: Add failing view-contract tests**

Read the Swift source files as UTF-8 and assert that the editor uses `YarnPhotoPicker`, `Decimal` parsing, a completion toolbar action, and a project picker; assert there is no second in-form save button.

```swift
@Test func yarnEditorKeepsOnlyNameRequiredAndUsesCompletionAction() throws {
    let source = try sourceText("KnitNote/Yarn/YarnEditorFields.swift")
    #expect(source.contains("yarn.name"))
    #expect(source.contains("remainingBalls"))
    #expect(source.contains("remainingGrams"))
    #expect(source.contains("ChooseYarnProjectsView"))
}
```

Add this helper inside `YarnViewContractTests` so every later source contract uses one repository-root implementation:

```swift
private var repositoryRoot: URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func sourceText(_ relativePath: String) throws -> String {
    try String(contentsOf: repositoryRoot.appending(path: relativePath), encoding: .utf8)
}
```

- [ ] **Step 2: Run contract tests and confirm missing-file failure**

Run: `HOME=/tmp/knitnote-home swift test --disable-sandbox --filter YarnViewContractTests`

Expected: FAIL because the yarn views do not exist.

- [ ] **Step 3: Build the reusable editor state and fields**

Use one `YarnEditorFields` component for create and edit. Parse localized text fields into optional `Decimal` values; empty text maps to `nil`. Disable the confirmation action only when the trimmed name is empty, a photo is loading, or a numeric value is negative/invalid. Preserve every field when saving fails.

- [ ] **Step 4: Build photo and project selection**

Adapt `ProjectPhotoPicker` behavior for yarn photos: PhotosPicker on all supported platforms, camera on iOS when available, replace/remove, stale-load revision cancellation, and localized load-failure alert. `ChooseYarnProjectsView` displays every project with a checkmark and allows multiple selections, including completed projects.

- [ ] **Step 5: Wire create and edit save actions**

`CreateYarnView` calls `store.addYarn(_:photoData:)`; `EditYarnView` calculates `.unchanged`, `.replace`, or `.remove` and calls `store.updateYarn(_:photoChange:)`. The navigation bar `common.done` action both saves and dismisses.

- [ ] **Step 6: Run contract and core tests**

Run: `HOME=/tmp/knitnote-home swift test --disable-sandbox --filter 'YarnViewContractTests|StoredYarnTests|JSONProjectStoreTests'`

Expected: PASS.

- [ ] **Step 7: Commit editor views**

```bash
git add KnitNote/Yarn KnitNote.xcodeproj/project.pbxproj Tests/KnitNoteCoreTests/YarnViewContractTests.swift
git commit -m "feat: add simple yarn editor"
```

### Task 5: Photo Grid Library and Yarn Detail

**Files:**
- Create: `KnitNote/Yarn/YarnCard.swift`
- Create: `KnitNote/Yarn/YarnLibraryView.swift`
- Create: `KnitNote/Yarn/YarnDetailView.swift`
- Create: `KnitNote/Yarn/YarnInventoryText.swift`
- Modify: `KnitNote/App/RootView.swift`
- Modify: `Tests/KnitNoteCoreTests/YarnViewContractTests.swift`
- Modify: `KnitNote.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `JSONProjectStore.yarns`, `photoURL(for:)`, create/edit views, linked project IDs, `LemonEmptyState`, and Watercolor theme components.
- Produces: working yarn tab, adaptive photo grid, long-press actions, detail navigation, and linked-project navigation.

- [ ] **Step 1: Add failing layout and navigation contracts**

```swift
@Test func yarnTabUsesAdaptivePhotoGridAndNoPlaceholder() throws {
    let root = try sourceText("KnitNote/App/RootView.swift")
    let library = try sourceText("KnitNote/Yarn/YarnLibraryView.swift")
    #expect(root.contains("YarnLibraryView()"))
    #expect(!root.contains("PlaceholderView(title: \"nav.yarn\""))
    #expect(library.contains("LazyVGrid"))
    #expect(library.contains("contextMenu"))
}
```

- [ ] **Step 2: Run contract tests and verify failure**

Run: `HOME=/tmp/knitnote-home swift test --disable-sandbox --filter YarnViewContractTests`

Expected: FAIL because the yarn library and detail views are absent.

- [ ] **Step 3: Implement the adaptive B-layout grid**

Use `GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 16)` so iPhone normally shows two columns and iPad gains columns naturally. Each card shows the photo or default yarn symbol, full name without manual truncation, color, and inventory chosen by this exact priority: balls, grams, no inventory label.

- [ ] **Step 4: Add empty, create, edit, and delete flows**

Show `LemonEmptyState` when the collection is empty. The top-right plus opens create. Tapping a card opens detail. Long press exposes edit and delete; delete presents a destructive confirmation alert before calling the store.

- [ ] **Step 5: Implement detail and linked-project navigation**

Show only populated fields. Display each linked project by resolving its ID through the store; tapping uses `NavigationLink` to `ProjectDetailView(projectID:)`. Keep links to completed projects and show their existing completed state in the destination.

- [ ] **Step 6: Replace the placeholder yarn tab**

Change `RootView` to instantiate `YarnLibraryView()` while keeping `Label("nav.yarn", systemImage: "shippingbox")` and the existing tab theme.

- [ ] **Step 7: Run view contracts**

Run: `HOME=/tmp/knitnote-home swift test --disable-sandbox --filter YarnViewContractTests`

Expected: PASS.

- [ ] **Step 8: Commit library and detail UI**

```bash
git add KnitNote/Yarn KnitNote/App/RootView.swift KnitNote.xcodeproj/project.pbxproj Tests/KnitNoteCoreTests/YarnViewContractTests.swift
git commit -m "feat: add yarn photo grid and detail"
```

### Task 6: Traditional Chinese, English, and Accessibility Contracts

**Files:**
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/YarnViewContractTests.swift`

**Interfaces:**
- Consumes: every `yarn.*` key referenced by Tasks 4–5.
- Produces: complete English and Traditional Chinese localizations plus card and control accessibility labels.

- [ ] **Step 1: Add failing localization key expectations**

Require localized English and Traditional Chinese values for these keys:

```text
yarn.library.title, yarn.create, yarn.edit, yarn.name, yarn.photo,
yarn.brand, yarn.series, yarn.color, yarn.colorCode, yarn.dyeLot,
yarn.remainingBalls, yarn.remainingGrams, yarn.storageLocation,
yarn.notes, yarn.linkedProjects, yarn.delete, yarn.delete.confirm,
yarn.empty.title, yarn.empty.message, yarn.inventory.balls,
yarn.inventory.grams, yarn.error.invalidNumber, yarn.error.negativeInventory,
yarn.photo.choose, yarn.photo.replace, yarn.photo.take,
yarn.photo.remove, yarn.photo.loadFailed, yarn.accessibility.photo,
yarn.accessibility.card
```

- [ ] **Step 2: Run localization contracts and verify failure**

Run: `HOME=/tmp/knitnote-home swift test --disable-sandbox --filter LocalizationContractTests`

Expected: FAIL listing missing yarn keys.

- [ ] **Step 3: Add both localizations and accessibility labels**

Use complete terms rather than shortened card labels. Format quantities with localized interpolation and `Decimal.FormatStyle`. Make each card a single accessibility element whose label contains name, optional color, and recorded inventory. Give every icon-only control an explicit localized label and maintain at least a 44×44 point content shape.

- [ ] **Step 4: Validate the string catalog and tests**

Run: `jq empty KnitNote/Localization/Localizable.xcstrings`

Run: `HOME=/tmp/knitnote-home swift test --disable-sandbox --filter 'LocalizationContractTests|YarnViewContractTests'`

Expected: JSON validation succeeds and all selected tests pass.

- [ ] **Step 5: Commit localization and accessibility**

```bash
git add KnitNote/Localization/Localizable.xcstrings KnitNote/Yarn Tests/KnitNoteCoreTests/LocalizationContractTests.swift Tests/KnitNoteCoreTests/YarnViewContractTests.swift
git commit -m "feat: localize yarn library"
```

### Task 7: Full Regression, Device Build, and Visual Acceptance

**Files:**
- Modify only files required to fix failures found by this task.

**Interfaces:**
- Consumes: all outputs from Tasks 1–6.
- Produces: verified yarn library without regressions.

- [ ] **Step 1: Run the complete Swift package test suite**

Run: `HOME=/tmp/knitnote-home swift test --disable-sandbox`

Expected: all tests pass with zero failures.

- [ ] **Step 2: Check formatting damage and localization JSON**

Run: `git diff --check`

Run: `jq empty KnitNote/Localization/Localizable.xcstrings`

Expected: both commands exit 0 with no output.

- [ ] **Step 3: Build the complete iOS app**

Run: `xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteYarnLibrary CODE_SIGNING_ALLOWED=NO build`

Expected: exit 0; environment profile or simulator warnings are acceptable, Swift compiler errors are not.

- [ ] **Step 4: Review iPhone and iPad behavior**

Launch installed builds on available iPhone and iPad simulators. Verify two-column iPhone cards, adaptive iPad columns, long names, large text, keyboard avoidance, camera availability behavior, photo selection, CRUD persistence, multiple project links, completed-project links, delete confirmation, empty state, and safe areas. Record screenshots of the library and editor on both device classes.

- [ ] **Step 5: Re-run tests after any acceptance fixes**

Run: `HOME=/tmp/knitnote-home swift test --disable-sandbox && git diff --check`

Expected: all tests pass and the diff check is clean.

- [ ] **Step 6: Commit final acceptance fixes**

```bash
git add KnitNote Sources Tests KnitNote.xcodeproj/project.pbxproj
git commit -m "test: verify yarn library experience"
```

## Completion Criteria

The yarn tab presents the approved photo grid; users can create a yarn with only a name, optionally attach a camera or library photo, record independent balls and grams, edit all agreed metadata, link multiple projects, navigate to those projects, and safely delete records. Archive version 8 loads every legacy archive without data loss, English and Traditional Chinese are complete, all tests pass, and the app builds and visually fits both iPhone and iPad.
