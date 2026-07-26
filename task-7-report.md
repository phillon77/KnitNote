# Task 7 Report — Standalone Pattern Library

## Scope

Implemented only the standalone pattern-library list, detail, and library reader routing. No project-side picker/import redesign, Share Extension, backup reminder, or other Task 8+ work was added.

## RED

- Added `PatternLibraryQueryTests` before production code. The first focused run failed to compile because `PatternLibraryIndex`, `PatternLibraryRowModel`, and `PatternLibrarySort` did not exist.
- Added durable library-import and owned-thumbnail integration tests before their store APIs. The focused run failed because `JSONProjectStore` had no `importPatternFromLibrary` or `patternThumbnailURL`.
- Added library UI contracts before replacing the old project-chooser list. They required one searchable list, thumbnail rows, usage summaries, sorting, detail actions, guarded deletion, adaptive layout, and read-only/single/multiple reader routing.
- Added exact English and Traditional Chinese catalog expectations before the new strings. The localization test failed on missing entries and then on the old project-dependent empty-state message.

## GREEN

- Added locale-aware `PatternLibraryIndex` search across pattern name, note, and active project names. Recent sorting uses creation date descending with deterministic name/ID ties; name sorting uses localized, numeric-aware standard ordering.
- Replaced the old project-dependent screen with one ungrouped list. Rows show an asset-keyed thumbnail, full multi-line name, file type/page count, and either the active project count or “Not used yet”.
- Added direct library import from the Files picker. The security-scoped file is copied into the durable inbox with `.library` origin and no target project, then published through the existing import coordinator. Ambiguous migrated duplicates remain pending until the user explicitly selects a collection.
- Added a responsive detail screen for thumbnail, name, file type/pages, byte size, creation date, note, active links, rename, note editing, linking active or completed projects, unlinking, exact-original `ShareLink` export, and guarded permanent deletion.
- Opening from detail uses a read-only context for zero active usages, the exact project usage for one link, and an explicit project/read-only chooser for multiple links. Completed-project contexts remain read-only.
- Added an asset-keyed async thumbnail view that decodes the owned local JPEG off the main actor, with a non-color fallback and one combined VoiceOver row label containing name, type/pages, and usage count.
- Added complete English and Traditional Chinese copy for list, sort, metadata, editing, project linking, export, deletion, and reader-context selection.

## Review Fix Round 1

- Reproduced the macOS compile failure with the real macOS SDK. The inline navigation-bar title modifier now lives behind a platform-safe view modifier: iOS keeps the inline title and macOS uses the native title style.
- Duplicate imports now map through a tested presentation reducer. An “Already Saved” / “已收藏” alert identifies the result and offers a localized, VoiceOver-readable action that navigates to the existing pattern detail.
- Library enqueue now performs recovery, validation, copy, hash inspection, move, and staged-sidecar publication in a detached user-initiated task. The security-scoped access remains alive in the awaiting UI task; processing and archive publication resume on the main actor only after enqueue finishes.
- A failed staged-sidecar write now removes both the candidate and any already-moved staged file, leaving the inbox and archive unmodified.

## Review Fix Round 2

- Added a write-then-throw failpoint that persists the staged manifest at its real path before reporting failure. RED reproduced an orphan manifest, a fresh-recovery quarantine event, and quarantine residue.
- Enqueue now records only the unique manifest path owned by the current item after confirming that path does not already exist. Its failure cleanup removes that exact path only when its UUID still matches the current item, alongside the existing candidate and staged-file cleanup.
- The failpoint now leaves candidates, staged items, manifests, quarantine, in-memory library state, and the archive unchanged. Fresh recovery reports no orphan, pending item, cleanup retry, or quarantine work.

## Verification

- Focused initial behavior: 14 tests passed across query, UI contract, localization, durable import, and thumbnail integration.
- Review-fix RED evidence reproduced all three defects: macOS compilation failed on `navigationBarTitleDisplayMode`; duplicate presentation failed because its reducer did not exist; enqueue tests observed main-thread I/O and a staged-file residue after manifest-write failure.
- Focused library regression: `swift test --filter PatternLibrary --quiet` passed 78 tests.
- Reader/library compatibility: 32 focused tests passed after updating the Task 6 source contracts for the new detail/chooser routing and durable library import.
- Full regression: `swift test --quiet` passed 706 tests in 54 suites.
- Real iOS Simulator and macOS SwiftUI type-checks of every `KnitNote` and `Sources/KnitNoteCore` Swift file passed with zero errors. Existing Sendable warnings remain in backup and journal-photo services.
- `jq empty` passed for `Localizable.xcstrings`; Swift parse passed for every touched Swift file; `git diff --check` passed.

## Files

- `Sources/KnitNoteCore/Patterns/PatternLibraryIndex.swift`
- `Sources/KnitNoteCore/Patterns/PatternLibraryImportPresentation.swift`
- `Sources/KnitNoteCore/Patterns/PatternInboxFileService.swift`
- `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- `KnitNote/Patterns/PatternLibraryView.swift`
- `KnitNote/Patterns/PatternLibraryRow.swift`
- `KnitNote/Patterns/PatternLibrarySort.swift`
- `KnitNote/Patterns/PatternDetailView.swift`
- `KnitNote/Patterns/ChoosePatternReadingContextView.swift`
- `KnitNote/Localization/Localizable.xcstrings`
- `Tests/KnitNoteCoreTests/PatternLibraryQueryTests.swift`
- `Tests/KnitNoteCoreTests/PatternLibraryImportPresentationTests.swift`
- `Tests/KnitNoteCoreTests/PatternLibraryViewContractTests.swift`
- `Tests/KnitNoteCoreTests/PatternLibraryStoreTests.swift`
- `Tests/KnitNoteCoreTests/PatternLibraryTestSupport.swift`
- `Tests/KnitNoteCoreTests/PatternReaderCounterContractTests.swift`
- `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`
