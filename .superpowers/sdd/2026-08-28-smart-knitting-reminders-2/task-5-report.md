# Task 5 report — ordered reminder queue and one-time haptic

## Scope

- Added the pure `KnittingReminderPresentationCoordinator`, which derives one deterministic current occurrence and total queue count from persisted active reminder occurrences.
- Added bounded one-time haptic presentation tracking, intersected with pending occurrence IDs so rerenders and navigation do not repeat feedback while new occurrences still receive one light impact.
- Added the shared adaptive `KnittingReminderQueueCard` for project detail and writable pattern-reader surfaces. It uses phase-specific complete/defer/skip actions, destructive-confirmed stop, exact reminder occurrence IDs and mutation revisions, verbatim user text, accessibility values, 44x44 controls, and `ViewThatFits` layout.
- Removed the legacy `CounterReminderCard` and its local action helpers, then regenerated the Xcode project membership.

## RED evidence

Command:

```sh
swift test --disable-sandbox --filter KnittingReminderPresentationTests
```

Before implementation, the new coordinator/card files were absent and the legacy card references remained. The source-contract suite built and failed with the expected missing-file and legacy-reference assertions.

## GREEN evidence

```sh
swift test --disable-sandbox --filter 'KnittingReminderPresentationTests|KnittingReminderTests|KnittingReminderStoreTests|KnittingReminderMigrationTests|KnittingReminderViewContractTests|CounterReminderViewContractTests|ProjectCounterViewContractTests|PatternReaderCounterContractTests'
```

Result: exit 0; 100 tests across 8 suites passed.

```sh
xcodegen generate
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
xcodebuild -project KnitNote.xcodeproj -target KnitNote -sdk macosx -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
git diff --check
```

Result: all commands exited 0. The builds were unsigned; the macOS build emitted only Xcode's existing multiple-architecture warning and the iOS build emitted existing App Intents metadata warnings.

The full package command was also run:

```sh
swift test --disable-sandbox
```

It reached all 1,637 tests but exited with 11 failures in pre-existing legacy reminder assertions that still expect `ProjectCounter.reminder` after the Task 2 v14 migration (7 `PatternLibraryStoreTests` assertions and 4 `WatchCommandApplicationTests` assertions). No Task 5 source or core model file is involved in those failures.

## Files

- Added `KnitNote/Projects/KnittingReminderPresentationCoordinator.swift`
- Added `KnitNote/Projects/KnittingReminderQueueCard.swift`
- Added `Tests/KnitNoteCoreTests/KnittingReminderPresentationTests.swift`
- Updated `KnitNote/Projects/ProjectDetailView.swift` and `KnitNote/Patterns/PatternReaderView.swift`
- Updated affected source-contract tests
- Deleted `KnitNote/Patterns/CounterReminderCard.swift`
- Regenerated `KnitNote.xcodeproj/project.pbxproj`

## Self-review

- Confirmed the queue is derived from persisted active reminders, uses stable target/date/identifier ordering, and presents exactly one current card.
- Confirmed card actions call only `applyKnittingReminderAction(projectID:reminderID:occurrenceID:observedRevision:action:)`; no local project mutation or invented revision is used.
- Confirmed project detail and pattern reader each contain one shared card call, with completed/read-only projects suppressing mutating reminder controls.
- Confirmed the legacy card file and production references are gone, and `git diff --check` is clean.

## Concerns

- The full package suite still contains 11 Task 1/2-era tests that assert the removed legacy `CounterReminder` projection; updating those tests is outside Task 5 scope.
- Physical iPhone, iPad, and Mac acceptance remains a later release gate; this task verified unsigned generic iOS Simulator and macOS builds.
