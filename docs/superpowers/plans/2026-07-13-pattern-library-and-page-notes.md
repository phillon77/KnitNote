# Pattern Library and Per-Page Notes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect the project and global pattern entry points, and persist independent highlight positions and one text note for every pattern page.

**Architecture:** Keep each pattern owned by its existing `StoredProject`; the global library derives grouped rows from all projects and never duplicates files. Extend `PatternDocument` with page-indexed value data while keeping highlight enabled/mode global, then let `PatternReaderView` save the departing page and load the arriving page.

**Tech Stack:** Swift 6, SwiftUI, PDFKit, Foundation Codable, Swift Testing, JSON file persistence.

## Global Constraints

- Preserve the current discrete single-page PDF reader and screen-fixed highlight overlay.
- Support iOS, iPadOS, and macOS without adding third-party dependencies.
- Provide Traditional Chinese and English for every new user-facing string.
- Decode existing archive version 4 without data loss or requiring pattern re-import.
- A pattern remains owned by exactly one project and has exactly one stored source file.
- Handwriting markup is excluded from this plan and receives a separate plan after this phase is verified.

---

### Task 1: Per-page pattern data model and archive migration

**Files:**
- Modify: `Sources/KnitNoteCore/Patterns/PatternDocument.swift`
- Modify: `Sources/KnitNoteCore/Projects/StoredProject.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternDocumentTests.swift`

**Interfaces:**
- Produces: `PatternPageState`, `PatternReadingState.pageStates`, `PatternReadingState.loadPage(_:)`, and `PatternReadingState.saveCurrentPage()`.
- Produces: archive version 5 that still decodes version 4.

- [ ] **Step 1: Write failing page-state tests**

Add tests proving positions clamp, blank notes become `nil`, separate page indexes remain independent, and a legacy `PatternDocument` without `pageStates` migrates its global positions into its saved `pageIndex`.

```swift
@Test func pageStatesKeepIndependentHighlightsAndTrimNotes() {
    var state = PatternReadingState(pageIndex: 0, highlightPosition: 0.2, verticalHighlightPosition: 0.8)
    state.pageNote = "  first repeat  "
    state.saveCurrentPage()
    state.pageIndex = 1
    state.loadPage(1)
    #expect(state.highlightPosition == 0.5)
    #expect(state.verticalHighlightPosition == 0.5)
    state.highlightPosition = 0.7
    state.pageNote = "   "
    state.saveCurrentPage()
    #expect(state.pageStates[0]?.note == "first repeat")
    #expect(state.pageStates[1]?.note == nil)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `CLANG_MODULE_CACHE_PATH="$PWD/work/swift-cache" swift test --disable-sandbox --scratch-path work/.build --filter PatternDocumentTests`

Expected: compilation fails because `pageNote`, `pageStates`, `saveCurrentPage`, and `loadPage` do not exist.

- [ ] **Step 3: Add the minimal page-state model**

Implement a Codable value keyed by integer page index and expose state transitions in one place.

```swift
public struct PatternPageState: Codable, Hashable, Sendable {
    public var horizontalPosition: Double
    public var verticalPosition: Double
    public var note: String?

    public init(horizontalPosition: Double = 0.5, verticalPosition: Double = 0.5, note: String? = nil) {
        self.horizontalPosition = min(1, max(0, horizontalPosition))
        self.verticalPosition = min(1, max(0, verticalPosition))
        let clean = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.note = clean.isEmpty ? nil : clean
    }
}
```

Add `[Int: PatternPageState]` to both the persisted document and reading state. `saveCurrentPage()` writes current positions/note under `pageIndex`; `loadPage(_:)` sets `pageIndex` and loads that page or the centered default. During legacy decoding, initialize the dictionary with the old positions at the decoded `pageIndex`.

- [ ] **Step 4: Persist page states and raise the archive version**

Update `StoredProject.updatePatternState` to copy `state.pageStates`. Change the encoder to `ProjectArchive(version: 5, projects: projects)` while leaving its decoder tolerant of existing versions.

- [ ] **Step 5: Run all core tests and verify GREEN**

Run: `CLANG_MODULE_CACHE_PATH="$PWD/work/swift-cache" swift test --disable-sandbox --scratch-path work/.build`

Expected: all tests pass, including archive reload and version 4 migration coverage.

- [ ] **Step 6: Commit**

Commit message: `Persist pattern state for each page`

---

### Task 2: Page switching coordinator

**Files:**
- Modify: `Sources/KnitNoteCore/Patterns/PatternDocument.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternDocumentTests.swift`
- Modify: `KnitNote/Patterns/PatternReaderView.swift`

**Interfaces:**
- Consumes: `saveCurrentPage()` and `loadPage(_:)` from Task 1.
- Produces: `PatternReadingState.movePDFPage(by:pageCount:)` that saves the old page before loading the new page.

- [ ] **Step 1: Extend the existing movement test**

Set page 0 positions/note, move forward, set page 1 values, move backward, and assert page 0 values return. Add boundary assertions proving a rejected movement does not erase the current page.

- [ ] **Step 2: Run the focused test and verify RED**

Run: `CLANG_MODULE_CACHE_PATH="$PWD/work/swift-cache" swift test --disable-sandbox --scratch-path work/.build --filter discretePDFPageMovementClampsAndClearsOffsets`

Expected: restored positions remain at the newly edited page values.

- [ ] **Step 3: Make page movement atomic**

Replace direct page-index assignment with this sequence:

```swift
public mutating func movePDFPage(by delta: Int, pageCount: Int) {
    guard pageCount > 0 else { return }
    let target = min(pageCount - 1, max(0, pageIndex + delta))
    guard target != pageIndex else { return }
    saveCurrentPage()
    offsetX = 0
    offsetY = 0
    loadPage(target)
}
```

In `PatternReaderView`, observe a `pageIndex` change reported by a swipe. Keep a private `displayedPageIndex`, save it before loading the reported index, and guard against the programmatic button path loading the same page twice.

- [ ] **Step 4: Run all core tests**

Run: `CLANG_MODULE_CACHE_PATH="$PWD/work/swift-cache" swift test --disable-sandbox --scratch-path work/.build`

Expected: all tests pass.

- [ ] **Step 5: Commit**

Commit message: `Restore highlights when switching pattern pages`

---

### Task 3: Per-page text note editor

**Files:**
- Create: `KnitNote/Patterns/EditPatternPageNoteView.swift`
- Modify: `KnitNote/Patterns/PatternReaderView.swift`
- Modify: `KnitNote/Localization/Localizable.xcstrings`

**Interfaces:**
- Consumes: `PatternReadingState.pageNote` and `saveCurrentPage()`.
- Produces: a modal editor bound to the current page note.

- [ ] **Step 1: Add localized copy**

Add English and Traditional Chinese values for `patterns.pageNote`, `patterns.pageNote.placeholder`, `patterns.pageNote.page`, and `patterns.pageNote.hasNote`.

- [ ] **Step 2: Create the focused editor**

Create a `NavigationStack` sheet containing a multi-line `TextEditor`, a page-number title, Cancel, and Save. Save returns trimmed text through a closure; an empty result deletes the note.

```swift
struct EditPatternPageNoteView: View {
    let pageNumber: Int
    let initialText: String
    let onSave: (String) -> Void
    @State private var text: String
}
```

- [ ] **Step 3: Connect the reader toolbar**

Add a note toolbar button to `PatternReaderView`. Show `doc.text.fill` when the current page has a note and `doc.text` otherwise. On save, set `state.pageNote`, call `state.saveCurrentPage()`, and persist through the existing store save path.

- [ ] **Step 4: Build iOS and macOS**

Run:

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath work/DerivedData-iOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath work/DerivedData-macOS CODE_SIGNING_ALLOWED=NO build
```

Expected: both builds end with `BUILD SUCCEEDED`; the string catalog parses with `jq empty KnitNote/Localization/Localizable.xcstrings`.

- [ ] **Step 5: Commit**

Commit message: `Add notes to individual pattern pages`

---

### Task 4: Global pattern library

**Files:**
- Create: `KnitNote/Patterns/PatternLibraryView.swift`
- Create: `KnitNote/Patterns/ChoosePatternProjectView.swift`
- Modify: `KnitNote/App/RootView.swift`
- Modify: `KnitNote/Patterns/ProjectPatternsView.swift`
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `Tests/KnitNoteCoreTests/PatternDocumentTests.swift`

**Interfaces:**
- Consumes: `JSONProjectStore.projects`, existing `ProjectPatternsView` importer, and `PatternReaderView(projectID:pattern:)`.
- Produces: a bottom-tab library grouped by project and a reusable import destination flow.

- [ ] **Step 1: Add a grouping test and helper**

Define a small Sendable projection in the core module:

```swift
public struct PatternProjectGroup: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let projectName: String
    public let patterns: [PatternDocument]
}

public func patternGroups(from projects: [StoredProject]) -> [PatternProjectGroup]
```

Test that empty projects are omitted, project order is preserved, and every pattern appears exactly once under its owner.

- [ ] **Step 2: Run the grouping test and verify RED**

Run: `CLANG_MODULE_CACHE_PATH="$PWD/work/swift-cache" swift test --disable-sandbox --scratch-path work/.build --filter patternGroups`

Expected: compilation fails because the projection and helper are undefined.

- [ ] **Step 3: Implement the minimal grouping helper**

Map projects with non-empty `patterns` to `PatternProjectGroup` without copying or moving files.

- [ ] **Step 4: Replace the bottom placeholder**

Create `PatternLibraryView` with a `NavigationStack` and one `Section(projectName)` per group. Each row opens `PatternReaderView` with the owning project ID. Its add button opens `ChoosePatternProjectView`; choosing a project launches the same importer behavior used by `ProjectPatternsView`.

- [ ] **Step 5: Extract duplicate import behavior**

Move the file-import result handling into a small reusable view/helper that always receives an explicit `projectID`. Keep security-scoped access, copied-file cleanup on store failure, and existing error presentation unchanged.

- [ ] **Step 6: Localize empty states and project selection**

Add English and Traditional Chinese values for the global library title, empty message, choose-project title, and no-project warning. Replace the `PlaceholderView` pattern tab in `RootView` with `PatternLibraryView()`.

- [ ] **Step 7: Run tests and both platform builds**

Run the full Swift test command and both `xcodebuild` commands from Task 3.

Expected: tests pass and both builds succeed.

- [ ] **Step 8: Commit**

Commit message: `Connect global and project pattern libraries`

---

### Task 5: Regression verification and release checkpoint

**Files:**
- Modify only files required by failures found during verification.

**Interfaces:**
- Consumes: all features from Tasks 1–4.
- Produces: a verified checkpoint before handwriting work begins.

- [ ] **Step 1: Run clean automated verification**

Run `git diff --check`, JSON catalog validation, all Swift tests, and fresh iOS/macOS builds. Expected: no diff errors, valid JSON, all tests pass, and both builds succeed.

- [ ] **Step 2: Perform device acceptance checks**

On iPhone and iPad verify: project entry and bottom entry open the same file; button and swipe page changes restore distinct highlights; notes persist after closing/reopening; a legacy pattern opens without re-import; importing from the bottom tab requires a project; deleting from one entry removes the row from both.

- [ ] **Step 3: Record only reproducible fixes**

For each discovered regression, add a failing automated test where the behavior is model-level, apply the smallest fix, and rerun the complete verification commands.

- [ ] **Step 4: Commit the verified checkpoint**

Commit message: `Verify pattern library and page notes`

- [ ] **Step 5: Start the handwriting design checkpoint**

Use the approved handwriting section of `docs/superpowers/specs/2026-07-13-pattern-page-notes-and-markup-design.md` to create a separate implementation plan only after this checkpoint passes on device.
