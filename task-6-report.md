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

## Review Fix Round 2 — Context Switch and Markup Failure Safety

- Added `PatternReaderContextIdentity` (pattern, usage, project, asset, and completion state) and SwiftUI `.task(id: readerContextIdentity)` reload. When identity changes, the view immediately stops rendering the old canvas, resets transient UI state, starts a new generation, and hydrates only the exact matching usage state.
- `PatternReaderSession` now carries identity and generation. Hydration results must match the current generation, so a cancelled or delayed old task cannot apply its state to a new usage. The reader canvas is keyed by `.id(readerSession.generation)`, forcing a new representable coordinator and preventing an old delayed PDF restore from being reused.
- Added `PatternReaderStateLoader` to select only the exact usage from a store snapshot; this moves the store-to-context state choice into compile-tested Core logic instead of testing a state object against itself.
- Added `PatternReaderMarkupSession` with explicit `loading`, `loaded`, and `failed` phases plus a dirty flag. Lifecycle/page/done saves require a current-generation, successfully loaded, dirty document. Missing markup is a successful empty load and can save after an edit; decode/read/safety failures remain non-persistable, so the reader cannot overwrite unreadable bytes with an empty document.
- Strengthened the VoiceOver source contract to verify that both custom actions occur inside the enabled branch and before the inactive `button` branch.

## Review Fix Round 3 — Generation Chaining and Inactive Usages

- Added generation-returning usage-scoped store mutations. Reader state, page-note, markup, and counter changes now return the confirmed transaction generation; `PatternReaderView` advances `expectedDataGeneration` only after a successful call, so a reader's own counter/manage interaction cannot stale its following state, note, or lifecycle save. Failed mutations leave the expected generation unchanged, preserving external optimistic-concurrency rejection.
- Added `mutatePatternReaderCounter(usageID:...)`. It validates the expected generation, active usage, and incomplete project before selecting and mutating the project counter in one archive write. This replaces reader-side project-level counter calls and rejects an unlinked usage even while its reader remains presented.
- Added `usageIsActive` to the reader context and stable identity. The reader reload task observes unlink/relink through identity, gates loading on active usage, and moves an inactive usage to a read-only session. Relinking restores the same usage ID, reading state, page note, markup, and sort order before writes are enabled again.
- Strengthened Core fixtures: the state loader now reads a real `JSONProjectStore` usage snapshot; sequence tests cover increment, rename/update, reset, state, note, markup, lifecycle markup, fresh reopen, and an externally stale generation. Markup tests also cover unsafe-path failure and a valid unedited document.

## Review Fix Round 4 — Markup Transaction and External Revision Conflict

- Usage markup saves now form an optimistic transaction: validate active usage and expected generation, snapshot the exact existing bytes, write markup, then persist the archive to advance the durable `dataGeneration`. If archive persistence fails, the snapshot restores the original bytes or absence and the generation remains unchanged. A second reader using the old generation is rejected before it can alter the first writer's markup.
- Added `PatternReaderRevisionCoordinator`, a compile-tested reducer for external store revisions. Self-confirmed mutations update its expected generation without a destructive reload. A clean external revision reloads; an external revision with dirty markup enters conflict, retains the document, and blocks page changes. Unlink or completion always triggers an immediate read-only reload.
- `PatternReaderView` observes `store.dataGeneration`, routes decisions through the reducer, and makes page change, OK, backgrounding, disappearance, and markup completion conditional on a successful dirty-markup save. A failed/stale save restores the current page instead of loading another page or discarding dirty strokes.
- Expanded loader and markup coverage with a same-pattern second-project distractor, two-writer markup race, archive-write failure rollback/fresh reopen, and dirty-markup external-revision resolution.

## Review Fix Round 5 — Production Context Entrypoints and Recoverable Failures

- Replaced every production reader construction with `PatternReaderContext`: a project screen passes its exact active `PatternProjectUsage.id`, the library opens an archive pattern in standalone read-only mode, and Store Screenshot fixtures select an active usage and its owning project. No production callsite now uses the legacy project-owned initializer, so legacy markup writes are not reachable from the shipped entrypoints.
- Context reloads retain the screenshot presentation request, including the reader's notes and markup modes, instead of clearing the requested sheet during hydration.
- A rejected PDF page change now restores all three representations of the old page: `PatternReadingState`, the callback de-duplication index, and `PDFPageNavigator`. Image readers are state-bound, so the same state restoration returns their displayed state without a separate navigator.
- Dirty-markup external revisions now present a localized conflict dialog with a destructive **Discard and Reload** action. It deliberately clears local transient markup, resets the revision coordinator to the current generation, and rehydrates the authoritative reader state; cancel leaves the existing conflict guarded against destructive writes.
- Page-note and counter editor completion closures return `Bool`. They dismiss only after their corresponding usage-scoped mutation confirms, keeping the editor open when a stale generation, unlink, completion lock, or I/O error is reported.
- Added reducer and UI source contracts for conflict reset, context-only production callsites, failure-page restoration, localized conflict action, and successful-mutation-only editor dismissal.

## Review Fix Round 6 — Atomic Page Rollback and Non-Dismissible Conflict Recovery

- Root cause: `PDFReaderView` calls `PatternReadingState.transitionToPDFPage` before the reader's page-change observer runs. That transition loads the destination page's highlight coordinates and note, so restoring only `pageIndex` after a failed markup save left an old page paired with new-page display data.
- Added `PatternReaderPageTransition`, a pure Core snapshot of the full pre-transition `PatternReadingState`. The canvas binding records it before accepting a platform callback. When page-save or conflict gating fails, the reader restores the snapshot in one state assignment, then resets the callback de-duplication index and asks `PDFPageNavigator` to return to the old page. No destination-page state can be persisted under the old page afterward.
- Replaced the separately dismissible conflict boolean with the revision coordinator's conflict phase as the alert binding. The alert exposes only the localized **Discard and Reload** action (no cancel action or destructive-role implicit cancel); presentation dismissal is refused while the reducer says resolution is required. Discard is the only transition that clears the conflict and reloads the authoritative generation.
- Added executable Core tests rather than source-string-only coverage: a rich multi-page state is transitioned then rolled back and compared exactly (page, zoom, offsets, highlight mode/positions, note, and every page-state entry); the conflict reducer proves that a conflict cannot dismiss, and only discard prepares the reload.

## Files

- `Sources/KnitNoteCore/Patterns/PatternReaderContext.swift`
- `Sources/KnitNoteCore/Patterns/PatternDocument.swift`
- `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- `KnitNote/Patterns/PatternReaderView.swift`
- `KnitNote/Patterns/PatternReaderControls.swift`
- `Tests/KnitNoteCoreTests/PatternReaderContextTests.swift`
- `Tests/KnitNoteCoreTests/PatternReaderCounterContractTests.swift`
- `Tests/KnitNoteCoreTests/PatternReaderSessionTests.swift`
- `Tests/KnitNoteCoreTests/PatternReaderAccessibilityPolicyTests.swift`
- `Tests/KnitNoteCoreTests/PatternReaderReloadSafetyTests.swift`
- `Tests/KnitNoteCoreTests/PatternReaderMarkupSessionTests.swift`
- `Tests/KnitNoteCoreTests/PatternLibraryStoreTests.swift`
- `Tests/KnitNoteCoreTests/PatternReaderRevisionCoordinatorTests.swift`
- `Tests/KnitNoteCoreTests/PatternReaderPageTransitionTests.swift`
- `KnitNote/Patterns/ProjectPatternsView.swift`
- `KnitNote/Patterns/PatternLibraryView.swift`
- `KnitNote/App/StoreScreenshotRootView.swift`
- `KnitNote/Patterns/EditPatternPageNoteView.swift`
- `KnitNote/Projects/EditCounterNameView.swift`
- `KnitNote/Localization/Localizable.xcstrings`
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
- RED round 2: `swift test --filter 'PatternReaderReloadSafetyTests|PatternReaderMarkupSessionTests|PatternReaderCounterContractTests'` failed because identity/generation loading and markup-session APIs did not exist; UI contracts also failed until the `.task(id:)` and coordinator identity were added.
- GREEN round 2 focused: `swift test --filter 'PatternReaderReloadSafetyTests|PatternReaderMarkupSessionTests|PatternReaderSessionTests|PatternReaderCounterContractTests|PatternReaderAccessibilityPolicyTests'` passed (24 tests in 5 suites).
- SwiftUI syntax: `xcrun swiftc -parse KnitNote/Patterns/PatternReaderView.swift KnitNote/Patterns/PatternReaderControls.swift` passed.
- Full round 2 regression: `swift test` passed (659 tests in 49 suites).
- RED round 3: real store sequence tests initially failed because reader mutations did not return generations and no usage-scoped counter mutation existed.
- GREEN round 3 focused: `swift test --filter 'readerUsageMutation|inactiveUsageRejectsReaderCounter|PatternReaderContextTests|PatternReaderReloadSafetyTests|PatternReaderMarkupSessionTests|PatternReaderCounterContractTests|PatternReaderAccessibilityPolicyTests'` passed (30 tests in 5 suites).
- Full round 3 regression: `swift test` passed (666 tests in 49 suites).
- RED round 4: transaction/revision tests initially failed because markup saves did not advance a durable generation and no external-revision coordinator existed.
- GREEN round 4 focused: `swift test --filter 'markupSavePublishes|failedArchiveCommit|externalRevisionWithDirtyMarkup|PatternReaderRevisionCoordinatorTests|PatternReaderCounterContractTests|PatternReaderReloadSafetyTests|PatternReaderMarkupSessionTests'` passed (29 tests in 4 suites).
- Full round 4 regression: `swift test` passed (674 tests in 50 suites).
- RED round 5: the existing file-coordinator source contract failed after the caller migration because it still expected project-owned deletion; it was updated to require the usage unlink path. New source contracts then lock the context-only callers, recovery UI, and editor completion behavior.
- GREEN round 5 focused: `swift test --filter 'PatternReaderCounterContractTests|PatternReaderRevisionCoordinatorTests|PatternReaderReloadSafetyTests'` passed (28 tests in 3 suites).
- SwiftUI syntax round 5: `xcrun swiftc -parse KnitNote/Patterns/PatternReaderView.swift KnitNote/Patterns/ProjectPatternsView.swift KnitNote/Patterns/PatternLibraryView.swift KnitNote/App/StoreScreenshotRootView.swift KnitNote/Patterns/EditPatternPageNoteView.swift KnitNote/Projects/EditCounterNameView.swift` passed.
- Full round 5 regression: `swift test` passed (680 tests in 50 suites).
- Localization catalog JSON validation: `jq empty KnitNote/Localization/Localizable.xcstrings` passed.
- RED round 6: `swift test --filter 'PatternReaderPageTransitionTests|PatternReaderRevisionCoordinatorTests'` failed because no page-transition snapshot type or conflict-resolution presentation API existed.
- GREEN round 6 focused: `swift test --filter 'PatternReaderPageTransitionTests|PatternReaderRevisionCoordinatorTests|PatternReaderCounterContractTests'` passed (27 tests in 3 suites).
- Swift syntax round 6: `xcrun swiftc -parse KnitNote/Patterns/PatternReaderView.swift Sources/KnitNoteCore/Patterns/PatternDocument.swift Sources/KnitNoteCore/Patterns/PatternReaderContext.swift` passed.
- Full round 6 regression: `swift test` passed (682 tests in 51 suites).
- `git diff --check` passed.
- `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/KnitNotePatternReaderTask6 CODE_SIGNING_ALLOWED=NO build` could not reach the reader compilation because the existing Xcode project omits Task 1–3 archive-level Core sources (`PatternAsset`, `StoredPattern`, `PatternProjectUsage`, inbox types) from the Watch target. Task 6 was explicitly scoped not to modify the Watch target or xcodeproj.

## Scope

No Task 7/8 library UI redesign, Watch, or xcodeproj changes were made. The library list's archive-level data source and the three minimal conflict strings are required for the context entrypoint and conflict-resolution fixes.

## Review Fix Round 7 — Compile-Safe Library UI and Current Screenshot Reader Data

- Corrected the archive-level library and project lists to derive their PDF/image symbol from the matched `PatternAsset.kind`; `StoredPattern` deliberately owns only its asset ID and display metadata.
- Fixed the project-detail counter editor completion callback to report a real `Bool`: it now keeps the editor presented on a thrown store mutation, presents the localized save failure, and only dismisses after a successful update.
- Hardened failed page transitions against rapid platform callbacks. A second transition preserves the original rollback snapshot; the page observer saves the snapshot page rather than SwiftUI's callback argument, and restoration derives the PDF navigation page from that same Core snapshot. The executable transition tests cover both full-state rollback and a rapid `2 -> 3 -> 4` update.
- Updated screenshot fixture version 10 content to use an archive-level `PatternAsset`, `StoredPattern`, and active `PatternProjectUsage`, with the asset at `Patterns/Assets` and usage markup at `Patterns/UsageMarkup`. The integration test installs the fixture through `JSONProjectStore.live`, resolves the pattern asset, and reads non-empty usage markup.
- Disabled reader counters now announce a read-only hint instead of the tap-and-hold mutation hint, and no longer use the nonexistent SwiftUI `.isDisabled` accessibility trait. The conflict translation uses the approved Taiwanese `織圖` terminology.
- A direct iOS SDK SwiftUI type-check found two latent production compile errors that the normal Xcode build had not reached because its Watch dependency stops at the Watch AppIcon asset: the shadowed `expectedDataGeneration` assignment in `saveMarkup`, and the invalid `.isDisabled` accessibility trait. Both are fixed; the direct type-check now completes with only existing Sendable warnings in backup/photo service code.

### Round 7 Verification

- RED: `swift test --filter 'PatternReaderPageTransitionTests|PatternReaderAccessibilityPolicyTests|StoreScreenshotFixturesTests|LocalizationContractTests'` initially failed for the new rollback-page API, read-only hint policy, localization values, and archive-level screenshot data.
- GREEN focused: `swift test --filter 'PatternReaderPageTransitionTests|PatternReaderAccessibilityPolicyTests|StoreScreenshotFixturesTests|LocalizationContractTests|PatternReaderCounterContractTests'` passed (55 tests in 5 suites).
- iOS SwiftUI type-check: `xcrun swiftc -typecheck -swift-version 5 -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -target arm64-apple-ios18.0-simulator -module-name KnitNote $(rg --files KnitNote Sources/KnitNoteCore -g '*.swift')` passed with zero errors (existing Sendable warnings only).
- Full regression: `swift test` passed (685 tests in 51 suites).
- `jq empty KnitNote/Localization/Localizable.xcstrings`, Swift parse of every touched Swift source/test file, and `git diff --check` passed.
