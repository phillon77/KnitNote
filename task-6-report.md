# Task 6 Report — Reader Context and Read-Only Mode

## RED

- Added `PatternReaderContextTests`. The initial focused run failed because `PatternReaderContext` did not exist.
- Added reader-contract coverage for usage-ID routing, read-only control disabling, accessibility-disabled counters, and legacy missing-file recovery. The first reader contract run failed because the reader still used `projectID` and `patternID` for archive-level writes and had no context gate.

## GREEN

- Added `PatternReaderContext.readOnly(patternID:)` and `.project(patternID:usageID:projectID:projectIsCompleted:)` in KnitNoteCore. `canWrite` requires a project usage and an incomplete project.
- Added `JSONProjectStore.patternAssetURL(patternID:)` so reader content is resolved from the archive-level pattern and its owned asset.
- Added the archive-level `PatternReaderView(context:)` entry point. A project context loads only the matching `PatternProjectUsage.readingState`; standalone reading starts from fresh in-memory state and has no counters or persistence target.
- Routed archive-level state, page-note, markup load, and markup save calls through `usageID`. The old project-owned initializer and its store calls remain only as a migration compatibility path.
- Completed projects refresh their context from the current project state and are read-only. Highlight controls and markup mode are disabled, counter actions are guarded and marked disabled for VoiceOver, state/notes/markup never save, and page navigation/zoom remain locally available.
- Read-only page notes reopen in a selectable display-only sheet, preserving saved reader data without exposing editing controls.
- Preserved legacy missing-file cleanup so older project-owned reader callers can still remove a stale record.

## Files

- `Sources/KnitNoteCore/Patterns/PatternReaderContext.swift`
- `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- `KnitNote/Patterns/PatternReaderView.swift`
- `KnitNote/Patterns/PatternReaderControls.swift`
- `Tests/KnitNoteCoreTests/PatternReaderContextTests.swift`
- `Tests/KnitNoteCoreTests/PatternReaderCounterContractTests.swift`
- `task-6-report.md`

## Verification

- RED: `swift test --filter PatternReaderContextTests` failed for missing `PatternReaderContext`.
- GREEN: `swift test --filter PatternReaderContextTests` passed (3 tests).
- RED: `swift test --filter PatternReaderCounterContractTests` failed for missing context-based usage routing and read-only controls.
- GREEN: `swift test --filter PatternReader` passed (18 reader context, layout, and contract tests).
- Final focused: `swift test --filter PatternReaderCounterContractTests` passed (11 tests); `swift test --filter PatternReaderContextTests` passed (3 tests).
- Full regression: `swift test` passed (646 tests in 45 suites).
- `git diff --check` passed.
- `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/KnitNotePatternReaderTask6 CODE_SIGNING_ALLOWED=NO build` could not reach the reader compilation because the existing Xcode project omits Task 1–3 archive-level Core sources (`PatternAsset`, `StoredPattern`, `PatternProjectUsage`, inbox types) from the Watch target. Task 6 was explicitly scoped not to modify the Watch target or xcodeproj.

## Scope

No Task 7/8 library UI, localization expansion, Watch, or xcodeproj changes were made.
