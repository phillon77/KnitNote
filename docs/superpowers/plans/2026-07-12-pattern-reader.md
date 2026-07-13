# Pattern Reader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let each project import, retain, organize, and read multiple image/PDF patterns with persistent page, zoom, offset, and highlight state.

**Architecture:** Codable `PatternDocument` records live inside each project and JSON archives advance to version 3. A file service validates and copies source files into project-scoped Application Support storage; SwiftUI list/import screens use Store APIs, while platform reader adapters wrap native image scrolling and PDFKit behind a shared reading-state interface.

**Tech Stack:** Swift 6, SwiftUI, Codable JSON, UniformTypeIdentifiers, PDFKit, QuickLook/ImageIO, Combine, Swift Testing, String Catalog, XcodeGen.

## Global Constraints

- Support PDF, PNG, JPEG, and HEIC up to 100 MB.
- Support multiple patterns per project.
- Copy imports into App-owned Application Support storage.
- Never translate imported filenames or content.
- Existing v1/v2 archives must load without data loss.
- Persist new archives as version 3.
- Keep camera, Photos, AI, annotations, iCloud, and Watch outside scope.

---

### Task 1: Pattern Domain Model and JSON v3

**Files:**
- Create: `Sources/KnitNoteCore/Patterns/PatternDocument.swift`
- Modify: `Sources/KnitNoteCore/Projects/StoredProject.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Create: `Tests/KnitNoteCoreTests/PatternDocumentTests.swift`
- Create: `Tests/KnitNoteCoreTests/PatternArchiveMigrationTests.swift`

- [ ] Write failing tests for default empty patterns on v1/v2 decode, v3 round trip, clamped highlight position, valid page index, rename, delete, and recently-opened sorting.
- [ ] Run all Swift package tests and confirm failures are due to missing pattern APIs.
- [ ] Implement `PatternKind`, `PatternReadingState`, and Codable `PatternDocument`.
- [ ] Add `patterns` to `StoredProject` with `decodeIfPresent(...) ?? []` migration behavior.
- [ ] Add Store APIs for add, rename, delete, mark-opened, and update-reading-state.
- [ ] Change archive writer to version 3 and rerun all tests.

### Task 2: Validated File Import Service

**Files:**
- Create: `Sources/KnitNoteCore/Patterns/PatternFileService.swift`
- Create: `Tests/KnitNoteCoreTests/PatternFileServiceTests.swift`

- [ ] Write failing tests using temporary PDF/image/oversized/unsupported fixtures.
- [ ] Implement type detection from UTType plus file content checks; reject empty PDFs, undecodable images, files over 100 MB, and unsupported extensions.
- [ ] Implement unique destination path `Patterns/<project-id>/<pattern-id>.<ext>` and atomic copy.
- [ ] Ensure same display name creates distinct stored filenames.
- [ ] Implement deletion and orphan cleanup reporting.
- [ ] Run service and regression tests.

### Task 3: Import and Pattern Management UI

**Files:**
- Create: `KnitNote/Patterns/ProjectPatternsView.swift`
- Create: `KnitNote/Patterns/ImportPatternCoordinator.swift`
- Create: `KnitNote/Patterns/RenamePatternView.swift`
- Modify: `KnitNote/Projects/ProjectDetailView.swift`
- Modify: `KnitNote/Localization/Localizable.xcstrings`

- [ ] Add bilingual keys for add, patterns, recent, all, image/PDF types, rename, delete confirmation, oversize, invalid, copy failure, missing file, and remove record.
- [ ] Add an Add Pattern button and recent-pattern card to project detail.
- [ ] Present `fileImporter` for PDF and supported image UTTypes with multiple selection disabled per import action.
- [ ] Copy and validate first, then add the JSON record; rollback copied files if record persistence fails.
- [ ] Build all-pattern list with recent ordering, rename sheet, and confirmed deletion.
- [ ] Validate catalog completeness for `en` and `zh-Hant`.

### Task 4: Native Image and PDF Readers

**Files:**
- Create: `KnitNote/Patterns/PatternReaderView.swift`
- Create: `KnitNote/Patterns/ImageReaderView.swift`
- Create: `KnitNote/Patterns/PDFReaderView.swift`
- Create: `KnitNote/Patterns/HighlightOverlay.swift`

- [ ] Route by `PatternKind`, showing localized missing/corrupt errors when loading fails.
- [ ] Wrap a native scroll/zoom view for images; restore scale/relative offset and support double-tap fit reset.
- [ ] Wrap PDFKit for continuous multi-page reading; restore valid page, scale, and offset and display page/total count.
- [ ] Overlay a draggable translucent horizontal band; clamp and persist its 0...1 position independently per document.
- [ ] Save reading state on navigation away and when the app becomes inactive.
- [ ] Add VoiceOver labels for document, page count, reset, and highlight controls.

### Task 5: Verification and Migration Safety

**Files:**
- Modify: `docs/localization-release-checklist.md` if present.

- [ ] Run all Swift package tests, including literal v1/v2 fixtures and v3 round trips.
- [ ] Regenerate the Xcode project.
- [ ] Clean-build macOS and generic iOS with signing disabled.
- [ ] Confirm iOS `UILaunchScreen` remains present.
- [ ] Verify PDF and image import, duplicate names, reopen state, highlighter, rename, confirmed deletion, missing-file removal, and relaunch persistence on iPhone, iPad, and Mac.
- [ ] Confirm every String Catalog entry has English and Traditional Chinese.

## Completion Boundary

The feature is complete when multiple image/PDF patterns can be imported and managed per project, native readers restore their state and highlight, v1/v2 data remains intact, and automated tests plus macOS/iOS builds pass.
