# Pattern Highlight Modes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add persistent horizontal, vertical, and cross highlight modes to every pattern reader.

**Architecture:** Extend the existing versioned pattern reading state with a string-backed highlight mode and a second normalized position. Keep rendering isolated in `HighlightOverlay`, while `PatternReaderView` owns mode selection and persistence through the existing store.

**Tech Stack:** Swift 6, SwiftUI, Foundation Codable, Swift Testing, XcodeGen-generated iOS/macOS project.

## Global Constraints

- Support iOS 18, macOS 15, and the shared core used by watchOS 11.
- Default migrated and newly created patterns to Horizontal mode.
- Support Traditional Chinese and English for every new user-facing string.
- Preserve existing PDF page restoration behavior and JSON archives.
- Do not add dependencies or configurable colors, widths, or opacity.

---

### Task 1: Persistent Highlight Mode Model

**Files:**
- Modify: `Sources/KnitNoteCore/Patterns/PatternDocument.swift`
- Modify: `Sources/KnitNoteCore/Projects/StoredProject.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Test: `Tests/KnitNoteCoreTests/PatternDocumentTests.swift`

**Interfaces:**
- Produces: `HighlightMode: String, Codable, CaseIterable, Sendable`
- Produces: `PatternReadingState.highlightMode: HighlightMode`
- Produces: `PatternReadingState.verticalHighlightPosition: Double`

- [ ] **Step 1: Write failing model tests**

Add tests proving new states default to `.horizontal`, both positions clamp to `0...1`, and `.cross` plus both positions survive a store reload.

- [ ] **Step 2: Run the focused tests and confirm failure**

Run: `CLANG_MODULE_CACHE_PATH="$PWD/work/swift-cache" swift test --disable-sandbox --scratch-path work/.build --filter PatternDocumentTests`

Expected: compilation fails because the new type and properties do not exist.

- [ ] **Step 3: Implement the minimal model and persistence changes**

Add the enum and fields, update `readingState`, and copy both new values in `StoredProject.updatePatternState`. Give stored fields decoding defaults so version-3 archives load as Horizontal with vertical position `0.5`. Increment archive output to version 4 while accepting supported older versions.

- [ ] **Step 4: Run all core tests**

Run: `CLANG_MODULE_CACHE_PATH="$PWD/work/swift-cache" swift test --disable-sandbox --scratch-path work/.build`

Expected: all tests pass and archive tests assert version 4.

### Task 2: Three-Mode Highlight Rendering

**Files:**
- Modify: `KnitNote/Patterns/HighlightOverlay.swift`
- Modify: `KnitNote/Patterns/PatternReaderView.swift`

**Interfaces:**
- Consumes: `HighlightMode`, horizontal `Binding<Double>`, vertical `Binding<Double>`
- Produces: `HighlightOverlay(mode:horizontalPosition:verticalPosition:)`

- [ ] **Step 1: Replace the single-band overlay API**

Render a 44-point-high band for `.horizontal`, a 44-point-wide band for `.vertical`, and both for `.cross`. Clamp drag updates and accessibility increments to `0...1`.

- [ ] **Step 2: Add mode selection to the reader toolbar**

Keep the enable toggle and add a menu with Horizontal, Vertical, and Cross actions. Pass all three state values into the overlay and preserve them through the existing save operation.

- [ ] **Step 3: Build iOS and macOS immediately**

Run generic iOS and macOS `xcodebuild` commands with code signing disabled.

Expected: both builds succeed with no Swift compilation errors.

### Task 3: Localization and Final Verification

**Files:**
- Modify: `KnitNote/Localization/Localizable.xcstrings`

**Interfaces:**
- Produces localized keys: `patterns.highlightMode`, `patterns.highlight.horizontal`, `patterns.highlight.vertical`, `patterns.highlight.cross`, `patterns.highlight.horizontalControl`, and `patterns.highlight.verticalControl`.

- [ ] **Step 1: Add English and Traditional Chinese translations**

Use Horizontal/Vertical/Cross and 橫向/縱向/十字; provide explicit accessible control labels in both languages.

- [ ] **Step 2: Verify the catalog contains both localizations for every new key**

Run a catalog scan that reports missing English or Traditional Chinese values.

- [ ] **Step 3: Run fresh complete verification**

Run all Swift tests, generic iOS build, and macOS build.

Expected: all tests pass and both builds end with `BUILD SUCCEEDED`.
