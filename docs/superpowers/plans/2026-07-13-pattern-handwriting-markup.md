# Pattern Handwriting Markup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-page freehand markup with pen, eraser, undo, color, width, and Apple Pencil-compatible input without modifying imported pattern files.

**Architecture:** Store strokes as normalized page coordinates in per-page JSON files under each pattern's application-support directory. A transparent SwiftUI canvas appears only in markup mode, preventing drawing gestures from competing with PDF paging or highlight movement; the existing bottom counter remains outside the canvas.

**Tech Stack:** Swift 6, SwiftUI Canvas and DragGesture, Foundation Codable, Swift Testing, existing PatternFileService storage root.

## Global Constraints

- Preserve the original PDF or image without annotations.
- Store each page independently outside the main projects JSON archive.
- Support finger and Apple Pencil input on iPhone/iPad and pointer input on macOS.
- Use normalized coordinates so strokes survive window and device size changes.
- Keep reading, highlighting, and drawing modes mutually exclusive for hit testing.
- Localize all new interface labels in English and Traditional Chinese.

---

### Task 1: Normalized stroke model

**Files:**
- Create: `Sources/KnitNoteCore/Patterns/PatternMarkup.swift`
- Create: `Tests/KnitNoteCoreTests/PatternMarkupTests.swift`

**Interfaces:**
- Produces: `PatternMarkupPoint`, `PatternMarkupStroke`, `PatternMarkupDocument`, `MarkupColor`, and mutation methods `append`, `undo`, `erase(near:tolerance:)`, and `clear`.

- [ ] Write failing tests for point clamping, stroke append, undo, nearest-stroke erasing, and Codable round trip.
- [ ] Run the focused tests and verify failure because markup types are missing.
- [ ] Implement only the normalized value types and mutations required by those tests.
- [ ] Run all core tests and confirm zero failures.
- [ ] Commit with message `Add normalized pattern markup model`.

### Task 2: Per-page markup file service

**Files:**
- Create: `Sources/KnitNoteCore/Patterns/PatternMarkupFileService.swift`
- Create: `Tests/KnitNoteCoreTests/PatternMarkupFileServiceTests.swift`
- Modify: `Sources/KnitNoteCore/Patterns/PatternFileService.swift`

**Interfaces:**
- Produces: `load(projectID:patternID:pageIndex:)`, `save(_:projectID:patternID:pageIndex:)`, `deletePage`, and `deletePatternMarkup`.

- [ ] Write failing tests using a temporary root for independent page round trips, empty-document deletion, corrupt-page isolation, and whole-pattern cleanup.
- [ ] Implement atomic JSON writes under `<root>/<projectID>/Markup/<patternID>/<pageIndex>.json`.
- [ ] Extend pattern deletion to remove that pattern's markup directory without affecting other patterns.
- [ ] Run all core tests and commit with message `Persist markup for each pattern page`.

### Task 3: Cross-platform drawing canvas

**Files:**
- Create: `KnitNote/Patterns/PatternMarkupOverlay.swift`
- Create: `KnitNote/Patterns/PatternMarkupToolbar.swift`
- Modify: `KnitNote.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: a Canvas renderer bound to `PatternMarkupDocument`, plus pen/eraser input modes and toolbar callbacks.

- [ ] Render every normalized stroke into the current canvas size.
- [ ] In pen mode, convert DragGesture locations to normalized points and append one stroke per gesture.
- [ ] In eraser mode, remove strokes near the normalized pointer location.
- [ ] Add color choices, three widths, undo, clear-page confirmation, and Done.
- [ ] Add both source files to the app target and compile iOS/macOS.

### Task 4: Reader integration and mode isolation

**Files:**
- Modify: `KnitNote/Patterns/PatternReaderView.swift`
- Modify: `KnitNote/Patterns/HighlightOverlay.swift`
- Modify: `KnitNote/Localization/Localizable.xcstrings`

**Interfaces:**
- Consumes: markup model and file service from Tasks 1–2.
- Produces: a markup-mode toolbar button and per-page load/save lifecycle.

- [ ] Add reader state for markup mode, current document, selected color, width, and tool.
- [ ] Load the current page when the reader opens; save the departing page before loading a new one.
- [ ] Save on Done, reader dismissal, and scene background transition.
- [ ] While drawing, disable PDF/image and highlight hit testing; while reading, remove the drawing overlay hit target.
- [ ] Keep PatternReaderControls in the safe-area inset outside the drawing canvas.
- [ ] Surface load/save errors without discarding in-memory strokes.
- [ ] Add English and Traditional Chinese labels for markup, pen, eraser, undo, clear, colors, widths, and Done.

### Task 5: Verification checkpoint

**Files:**
- Modify only files required by reproducible verification failures.

- [ ] Run `git diff --check`, string-catalog JSON validation, all Swift tests, and clean iOS/macOS builds.
- [ ] On iPhone/iPad verify finger and Apple Pencil drawing, erasing, undo, page independence, close/reopen persistence, counter access, and no accidental page swipe while drawing.
- [ ] On Mac verify pointer drawing and window-resize alignment.
- [ ] Commit the verified result with message `Add per-page pattern handwriting`.
