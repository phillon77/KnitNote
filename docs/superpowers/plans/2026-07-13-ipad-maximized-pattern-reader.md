# iPad Maximized Pattern Reader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Increase the iPad pattern canvas while keeping controls in separate safe regions and leaving iPhone and Mac unchanged.

**Architecture:** A pure layout policy selects maximized-safe or standard layout from an iPad flag. The reader removes the reserved markup strip only for iPad, moves markup actions into the fixed navigation bar, and asks the existing bottom controls to render a compact single row.

**Tech Stack:** Swift 6, SwiftUI, UIKit device idiom, Swift Testing, Xcode 26.

## Global Constraints

- Apply the maximized-safe layout only to iPad, including iPad Split View.
- Never place the pattern underneath a toolbar or bottom panel.
- Toggling markup must not resize or recreate the iPad PDF canvas.
- Preserve iPhone and Mac layout and all pattern state behavior.
- Add no dependencies and exclude the pre-existing localization working-tree change.

---

### Task 1: Testable Device Layout Policy

**Files:**
- Modify: `Sources/KnitNoteCore/Patterns/PatternDocument.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternDocumentTests.swift`

**Interfaces:**
- Produces: `PatternReaderLayout.standard`, `.maximizedSafe`, and `patternReaderLayout(isPad:)`.

- [ ] **Step 1: Write a failing selection test**

```swift
@Test func onlyIPadUsesMaximizedSafePatternLayout() {
    #expect(patternReaderLayout(isPad: true) == .maximizedSafe)
    #expect(patternReaderLayout(isPad: false) == .standard)
}
```

- [ ] **Step 2: Run the focused test and verify RED**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/work/swift-cache" swift test --disable-sandbox --scratch-path work/.build --filter onlyIPadUsesMaximizedSafePatternLayout
```

Expected: compilation fails because the policy is missing.

- [ ] **Step 3: Implement the policy**

```swift
public enum PatternReaderLayout: Sendable { case standard, maximizedSafe }
public func patternReaderLayout(isPad: Bool) -> PatternReaderLayout {
    isPad ? .maximizedSafe : .standard
}
```

- [ ] **Step 4: Run the focused test and verify GREEN**

Expected: one selected test passes.

### Task 2: Compact Safe iPad Controls

**Files:**
- Modify: `KnitNote/Patterns/PatternReaderControls.swift`
- Modify: `KnitNote/Patterns/PatternReaderView.swift`

**Interfaces:**
- Consumes: `patternReaderLayout(isPad:)` from Task 1.
- Produces: `PatternReaderControls(..., compact: Bool)` with a one-row compact layout.

- [ ] **Step 1: Add the compact controls variant**

Keep the existing two-row body as `standardControls`. Add `compactControls` containing previous page, page counter, next page, current row, undo row, and complete row in one `HStack`. Use the same disabled conditions, labels, material background, horizontal padding, and safe bottom padding. Select with `if compact { compactControls } else { standardControls }`.

- [ ] **Step 2: Select iPad by device idiom**

In `PatternReaderView`, return `.maximizedSafe` only when `UIDevice.current.userInterfaceIdiom == .pad` under `#if os(iOS)`. Return `.standard` on macOS. Pass `compact: readerLayout == .maximizedSafe` to the controls.

- [ ] **Step 3: Remove only the iPad reserved markup strip**

Render the existing 60-point `PatternMarkupToolbar` only for `.standard`. The condition is device-stable, so markup toggling cannot change iPad canvas height.

- [ ] **Step 4: Put iPad markup actions in the navigation bar**

When the layout is `.maximizedSafe` and markup is active, replace normal primary actions with pen, eraser, color menu, width menu, undo, clear, and Done. Keep the navigation bar height unchanged. When markup is inactive, show the current highlight, mode, markup, and note actions.

### Task 3: Verification and Commit

**Files:** All files from Tasks 1 and 2.

- [ ] **Step 1: Run full verification**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/work/swift-cache" swift test --disable-sandbox --scratch-path work/.build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath work/DerivedData-iOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath work/DerivedData-macOS CODE_SIGNING_ALLOWED=NO build
```

Expected: 35 tests pass and both platform builds succeed.

- [ ] **Step 2: Inspect and commit**

Run `git diff --check` and verify only the preserved localization change remains outside the implementation. Commit the four implementation files and tests as `Maximize the safe iPad pattern canvas`.

- [ ] **Step 3: Hand off iPad checks**

Ask the user to verify portrait and landscape pattern size, compact controls, page navigation, markup tools, highlights, notes, and row counting.
