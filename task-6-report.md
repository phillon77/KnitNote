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

## Review Fix — Hydration and VoiceOver

- Replaced the reader's default-state-first launch with `PatternReaderSession`: it stays in `.loading` while the exact usage state and markup are resolved, then moves to `.hydrated` before the PDF/image canvas can be constructed. This prevents a representable coordinator from observing or persisting placeholder reader state.
- The canvas binding ignores callbacks until the session is hydrated and the canvas is active. On a newly hydrated canvas, the current page is marked handled before page-change persistence begins, so the hydration assignment cannot save default markup over the stored page.
- The session resets to `.loading` before a new context is hydrated; focused Core coverage proves context switching, pre-hydration callback suppression, and round-tripping every persisted reading-state field (page, zoom, normalized offsets, highlight settings, and per-page state).
- Added `PatternReaderCounterAccessibilityPolicy`. Enabled counters register their increment/manage VoiceOver actions; disabled or completed-project counters register neither action, rather than registering an action which only no-ops inside its handler.

## Files

- `Sources/KnitNoteCore/Patterns/PatternReaderContext.swift`
- `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- `KnitNote/Patterns/PatternReaderView.swift`
- `KnitNote/Patterns/PatternReaderControls.swift`
- `Tests/KnitNoteCoreTests/PatternReaderContextTests.swift`
- `Tests/KnitNoteCoreTests/PatternReaderCounterContractTests.swift`
- `Tests/KnitNoteCoreTests/PatternReaderSessionTests.swift`
- `Tests/KnitNoteCoreTests/PatternReaderAccessibilityPolicyTests.swift`
- `task-6-report.md`

## Verification

- RED: `swift test --filter PatternReaderContextTests` failed for missing `PatternReaderContext`.
- GREEN: `swift test --filter PatternReaderContextTests` passed (3 tests).
- RED: `swift test --filter PatternReaderCounterContractTests` failed for missing context-based usage routing and read-only controls.
- GREEN: `swift test --filter PatternReader` passed (18 reader context, layout, and contract tests).
- Final focused: `swift test --filter PatternReaderCounterContractTests` passed (11 tests); `swift test --filter PatternReaderContextTests` passed (3 tests).
- RED review coverage: new session/policy tests initially failed because `PatternReaderSession` and `PatternReaderCounterAccessibilityPolicy` did not exist; UI contracts then failed until the hydrated canvas gate and conditional VoiceOver actions were added.
- GREEN review coverage: `swift test --filter 'PatternReaderSessionTests|PatternReaderAccessibilityPolicyTests|PatternReaderCounterContractTests'` passed (19 tests in 3 suites).
- Full regression: `swift test` passed (654 tests in 47 suites).
- `git diff --check` passed.
- `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/KnitNotePatternReaderTask6 CODE_SIGNING_ALLOWED=NO build` could not reach the reader compilation because the existing Xcode project omits Task 1–3 archive-level Core sources (`PatternAsset`, `StoredPattern`, `PatternProjectUsage`, inbox types) from the Watch target. Task 6 was explicitly scoped not to modify the Watch target or xcodeproj.

## Scope

No Task 7/8 library UI, localization expansion, Watch, or xcodeproj changes were made.
