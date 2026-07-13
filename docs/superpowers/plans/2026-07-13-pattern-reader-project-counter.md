# Pattern Reader Project Counter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the owning project's shared row counter, complete-row action, and undo action to the pattern reader's bottom control bar.

**Architecture:** `PatternReaderView` continues to receive the owning `projectID` and reads `currentRow` from `JSONProjectStore`. Counter actions call the existing store methods, while a focused SwiftUI control component renders the PDF and image variants without creating another counter.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, existing JSONProjectStore.

## Global Constraints

- Use `StoredProject.currentRow` as the only row count.
- Preserve the discrete single-page PDF reader, per-page highlights, and notes.
- Support iOS, iPadOS, and macOS.
- Localize all new labels in English and Traditional Chinese.
- Do not add dependencies or change the archive format.

---

### Task 1: Shared counter control model

**Files:**
- Create: `KnitNote/Patterns/PatternReaderControls.swift`
- Modify: `KnitNote.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `PatternReaderControls(currentRow:pageIndex:pageCount:onPreviousPage:onNextPage:onUndoRow:onCompleteRow:)`.

- [ ] Write a focused SwiftUI component with an optional page-navigation row and an always-visible counter row.
- [ ] Disable previous/next at page boundaries and undo at row zero.
- [ ] Use a regular-material rounded container placed in the bottom safe area.
- [ ] Add the new source file to the KnitNote target.

### Task 2: Store-backed reader integration

**Files:**
- Modify: `KnitNote/Patterns/PatternReaderView.swift`
- Modify: `KnitNote/Localization/Localizable.xcstrings`

**Interfaces:**
- Consumes: existing `JSONProjectStore.completeRow(id:)` and `undoRow(id:)`.

- [ ] Replace the current PDF page capsule with `PatternReaderControls`.
- [ ] Pass the current owning project's `currentRow`, including when opened from the global pattern library.
- [ ] Call the existing store actions and surface persistence errors through the reader's save error alert.
- [ ] Add English and Traditional Chinese labels for current row, complete row, and undo.

### Task 3: Verification and checkpoint

**Files:**
- Modify only files required by a reproducible verification failure.

- [ ] Run `git diff --check` and validate the string catalog with `jq empty`.
- [ ] Run all Swift tests and confirm zero failures.
- [ ] Build generic iOS and macOS targets with signing disabled.
- [ ] Commit the verified result with message `Add project counter to pattern reader`.
