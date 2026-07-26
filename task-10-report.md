# Task 10 Report — Main-App Inbox Processing

## Scope

Implemented only foreground processing of the durable pattern inbox in the iOS/macOS main App. The App scans at launch and whenever its scene becomes active, processes items serially in received-time order, presents compact success feedback, and stops for an explicit duplicate choice or a persistent retryable failure. No Task 11 backup-manifest work was included. The Share Extension remains enqueue-only, and Watch contains none of the new processing or presentation code.

## RED

- Added store tests before the resolution and inbox-management APIs existed. The first focused run failed to compile because `PatternImportDuplicateResolution`, `.createNew`, `.existing`, `pendingPatternInboxItems()`, and `discardPatternInboxItem(id:)` did not exist.
- Added driver tests before the protocol, actor, update, or blocking-state types existed. The focused run failed to compile on the missing `PatternInboxProcessing` and `PatternInboxDriver` symbols.
- Added App contracts before the processor, chooser, lifecycle wiring, and localized copy existed. The first run reported five failing tests and fifteen issues covering missing files, launch/active scanning, retry/discard, accessible notice, and eight untranslated inbox keys.

## GREEN

- Added explicit duplicate resolution while retaining the existing `selectingPatternID` API. Automatic handling still selects unique assets or unique normalized names; explicit existing selection validates its candidate.
- Explicit create-new adds one collection referencing the already-owned matching asset. It does not install duplicate bytes. Archive persistence completes before inbox cleanup.
- Added off-main pending enumeration and idempotent discard. Both run inside the store's active pattern-transaction gate; discard never mutates the archive.
- Added the injected `PatternInboxProcessing` protocol and `PatternInboxDriver` actor. An explicit non-reentrant gate prevents overlapping foreground runs despite actor suspension. Processing is ordered and stops at the first ambiguity or failure.
- Cancellation propagates as `CancellationError`, releases the gate, and does not become a user-facing failure. Retry, explicit resolution, and discard continue through the remaining queue.
- `PatternInboxProcessor` is one MainActor observable object owned by `KnitNoteApp`. `RootView` starts it on initial task and every active scene transition without changing the selected tab.
- Ambiguous duplicates remain in a nondismissable chooser until the user selects an existing collection or creates a new one.
- Processing failures remain visible with localized retry and, for item-specific failures, discard actions. Successful imports show a short-lived accessible overlay.
- Added exact English and Traditional Chinese inbox copy and readable VoiceOver labels for the chooser, actions, and notice.

## Crash, Retry, and Boundary Evidence

- Explicit-existing restart/idempotency preserves one asset and the original two collections; a second call for the cleaned item returns `itemNotFound`.
- A create-new cleanup failure followed by a fresh store recovery preserves exactly one asset and three collections, publishes `Matching` exactly once, and empties the inbox.
- The actor concurrency test suspends the first processing call, invokes a second foreground run, and proves the overlap returns busy while the item is processed only once.
- A cancellation-then-retry test proves cancellation escapes unchanged and a subsequent run succeeds.
- Inbox scans and mutations increment the same pattern-transaction count used to reject overlapping data operations.
- Generated PBX membership proves the driver, processor, and chooser belong to the main App and are absent from Watch. The Share target builds only its enqueue source graph and contains no `JSONProjectStore`, `ProjectArchive`, driver, or process API reference.

## Verification

- Store processing: 5 tests passed.
- Actor driver: 4 tests passed.
- App/presentation/localization contracts: 5 tests passed.
- Generated-project membership: 1 test passed.
- Final full regression: `swift test --quiet` passed 771 tests in 66 suites.
- Final Debug builds with code signing disabled passed for:
  - KnitNote, generic iOS Simulator.
  - KnitNote, generic macOS.
  - KnitNoteShare, generic iOS Simulator.
  - KnitNoteWatch, generic watchOS Simulator.
- `jq empty` passed for the main App string catalog.
- `plutil -lint` passed for the generated PBX project, App and Share Info plists, and both App Group entitlements.
- Swift parse passed for every touched Swift source and test file.
- Share archive-boundary search and `git diff --check` passed.

## Files

- `KnitNote.xcodeproj/project.pbxproj`
- `KnitNote/App/KnitNoteApp.swift`
- `KnitNote/App/RootView.swift`
- `KnitNote/Localization/Localizable.xcstrings`
- `KnitNote/Patterns/PatternInboxProcessor.swift`
- `KnitNote/Patterns/PendingPatternSelectionView.swift`
- `Sources/KnitNoteCore/Patterns/PatternInboxItem.swift`
- `Sources/KnitNoteCore/Patterns/PatternInboxProcessing.swift`
- `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- `Tests/KnitNoteCoreTests/PatternInboxAppContractTests.swift`
- `Tests/KnitNoteCoreTests/PatternInboxDriverTests.swift`
- `Tests/KnitNoteCoreTests/PatternInboxProcessingStoreTests.swift`
- `Tests/KnitNoteCoreTests/Task8XcodeProjectMembershipTests.swift`
- `docs/superpowers/plans/2026-07-26-task10-main-app-inbox-processing.md`
- `project.yml`
