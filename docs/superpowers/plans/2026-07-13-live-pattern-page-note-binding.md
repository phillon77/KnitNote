# Live Pattern Page Note Binding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make saved per-page pattern notes visible immediately when reopened and persistent after a full project-store reload.

**Architecture:** `PatternReadingState` keeps its explicit note-setting operation for immediate UI state. A dedicated project-store operation writes a note by project ID, pattern ID, and page index without depending on a live reader view. The note sheet reloads the confirmed page state from the store when it closes.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, Swift Package Manager, Xcode 26.

## Global Constraints

- Preserve PDF navigation, highlights, handwriting markup, and row counting.
- Keep `PatternPageState.note` and project JSON as the storage format.
- Support iOS/iPadOS 18 or newer and macOS 15 or newer.
- Add no dependencies and do not include the pre-existing localization working-tree change.

---

### Task 1: Immediate and Reloaded Page Note State

**Files:**
- Modify: `Sources/KnitNoteCore/Patterns/PatternDocument.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternDocumentTests.swift`

**Interfaces:**
- Produces: `PatternReadingState.setPageNote(_:)`.
- Consumes: The active zero-based `pageIndex` and entered note text.

- [ ] **Step 1: Write a failing state test**

```swift
@Test func settingPageNoteImmediatelyUpdatesActivePageState() {
    var state = PatternReadingState(pageIndex: 2)
    state.setPageNote("  sleeve repeat  ")
    #expect(state.pageNote == "sleeve repeat")
    #expect(state.pageStates[2]?.note == "sleeve repeat")
}
```

- [ ] **Step 2: Run the focused test and verify RED**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/work/swift-cache" swift test --disable-sandbox --scratch-path work/.build --filter settingPageNoteImmediatelyUpdatesActivePageState
```

Expected: compilation fails because `setPageNote(_:)` is missing.

- [ ] **Step 3: Implement the minimal setter**

```swift
public mutating func setPageNote(_ text: String) {
    pageNote = text
    saveCurrentPage()
}
```

- [ ] **Step 4: Add and run a store reload regression test**

Create a project and pattern, call `setPageNote("chart note")`, persist through `updatePatternState`, reload `JSONProjectStore`, and expect `readingState.pageNote == "chart note"` and `pageStates[pageIndex]?.note == "chart note"`. Run the complete Swift test suite and expect zero failures.

- [ ] **Step 5: Commit**

Stage only the core and test files and commit `Persist active pattern page notes immediately`.

### Task 2: Live-Bound Note Editor

**Files:**
- Modify: `KnitNote/Patterns/EditPatternPageNoteView.swift`
- Modify: `KnitNote/Patterns/PatternReaderView.swift`

**Interfaces:**
- Consumes: `PatternReadingState.setPageNote(_:)` from Task 1.
- Produces: An editor with `@Binding var text`, `onSave: () -> Void`, and `onCancel: () -> Void`.

- [ ] **Step 1: Replace the editor's private text state with a binding**

```swift
struct EditPatternPageNoteView: View {
    @Environment(\.dismiss) private var dismiss
    let pageNumber: Int
    @Binding var text: String
    let onSave: () -> Void
    let onCancel: () -> Void
}
```

Save calls `onSave()` then dismisses. Cancel calls `onCancel()` then dismisses. Remove the custom initializer and private `@State` text.

- [ ] **Step 2: Make the reader own draft restoration and persistence**

Add `@State private var originalPageNote = ""`. Before presenting the sheet, assign `originalPageNote = state.pageNote`. Pass `text: $state.pageNote`. Save calls `state.setPageNote(state.pageNote)` followed by `save()`. Cancel assigns `state.pageNote = originalPageNote` without persisting.

- [ ] **Step 3: Run full verification**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/work/swift-cache" swift test --disable-sandbox --scratch-path work/.build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath work/DerivedData-iOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath work/DerivedData-macOS CODE_SIGNING_ALLOWED=NO build
```

Expected: 33 tests pass and both builds end with `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

Stage only the two app files and commit `Bind pattern page notes to reader state`.

### Task 3: Direct Store Persistence for iPhone

**Files:**
- Modify: `Sources/KnitNoteCore/Patterns/PatternDocument.swift`
- Modify: `Sources/KnitNoteCore/Projects/StoredProject.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternDocumentTests.swift`
- Modify: `KnitNote/Patterns/PatternReaderView.swift`

**Interfaces:**
- Produces: `PatternDocument.setPageNote(_:pageIndex:)`, `StoredProject.savePatternPageNote(patternID:pageIndex:text:)`, and `JSONProjectStore.savePatternPageNote(projectID:patternID:pageIndex:text:)`.
- Consumes: Stable project, pattern, and zero-based page identifiers captured before presenting the note sheet.

- [ ] **Step 1: Write a failing direct-store test**

Create a project with a PDF pattern, call `store.savePatternPageNote(projectID:patternID:pageIndex:text:)` for page 2, reload `JSONProjectStore`, and expect only `pageStates[2]?.note` to equal the trimmed note.

- [ ] **Step 2: Run the focused test and verify RED**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/work/swift-cache" swift test --disable-sandbox --scratch-path work/.build --filter dedicatedPageNoteSaveSurvivesWithoutReaderState
```

Expected: compilation fails because the store operation is missing.

- [ ] **Step 3: Implement the direct persistence chain**

`PatternDocument.setPageNote(_:pageIndex:)` must preserve that page's horizontal and vertical highlight positions while replacing only its note. `StoredProject` locates the pattern and calls it. `JSONProjectStore` performs the mutation and atomic archive write.

- [ ] **Step 4: Route sheet Save and dismissal through the store**

Capture the page index when opening the editor. Save calls the dedicated store API with that captured index. Add a sheet `onDismiss` callback that reloads `state` from the stored pattern's `readingState`, then restores the confirmed PDF page index and current page note without navigating the PDF.

- [ ] **Step 5: Run all tests and platform builds**

Run the existing full Swift test command plus iOS and macOS build commands. Expected: 34 tests pass and both builds succeed.

- [ ] **Step 6: Commit**

Stage only the five listed files and commit `Save pattern page notes directly to the store`.

### Task 4: Final Inspection

**Files:** Verify only.

- [ ] **Step 1:** Run `git diff --check`, `git status --short`, and `git log -4 --oneline`; only the preserved localization change may remain.
- [ ] **Step 2:** Ask the user to test immediate reopen and full reader reopen on both iPhone and iPad.
