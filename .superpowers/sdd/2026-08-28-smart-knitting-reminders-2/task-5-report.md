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

Result: exit 0; 110 tests across 8 suites passed. The behavioral coverage includes deterministic ordering across owning counters, deferred secondary-counter visibility, one-time haptic pruning, navigation sharing with restoration-capable visible-surface leases, authoritative complete/defer/skip refreshes, stale-action refresh, and deleted-project isolation after cache pruning.

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

It reached all 1,637 tests but exited with 11 failures in pre-existing legacy reminder assertions that still expect `ProjectCounter.reminder` after the Task 2 v14 migration (7 `PatternLibraryStoreTests` assertions and 4 `WatchCommandApplicationTests` assertions). No Task 5 source or core model file is involved in those failures. The exact failing test names were:

- `failedReminderPersistencePublishesNothing`
- `staleReminderIDIsRejectedWithoutMutation`
- `stopWinsOverStaleReminderCompletion`
- `duplicateReminderAcknowledgementCannotCompleteTwice`
- `snapshotMapsOnlyTheReminderStateWatchNeeds`
- `rejectedReaderReminderActionsPublishNothingOrSelection`
- `staleReaderReminderActionPublishesNothing`
- `completedProjectRejectsReaderReminderActionsWithoutPublishing`
- `readerMutationPublishesGenerationAndReminderTogether` (two reported issues)
- `readerCompleteAndStopPublishSelectionAndReopenState`

## Files

- Added `Sources/KnitNoteCore/Projects/KnittingReminderPresentationCoordinator.swift` and app-scoped `KnittingReminderPresentationStore`
- Added `KnitNote/Projects/KnittingReminderQueueCard.swift`
- Added `Tests/KnitNoteCoreTests/KnittingReminderPresentationTests.swift`
- Updated `KnitNote/Projects/ProjectDetailView.swift` and `KnitNote/Patterns/PatternReaderView.swift`
- Updated `KnitNote/App/RootView.swift` to prune presentation state against the authoritative project ID set
- Updated affected source-contract tests
- Deleted `KnitNote/Patterns/CounterReminderCard.swift`
- Regenerated `KnitNote.xcodeproj/project.pbxproj`

## Self-review

- Confirmed the queue is derived from persisted active reminders, uses stable target/date/identifier ordering, and presents exactly one current card.
- Confirmed each reminder is evaluated against its owning counter's persisted value, including deferred secondary-counter occurrences.
- Confirmed the app-scoped project-keyed store shares the haptic ledger across project detail and pattern reader navigation while isolating separate projects; the ledger is pruned to pending occurrences.
- Confirmed restoration-capable detail/reader lease stacks make the most recently visible surface the sole haptic claimant; hidden mounted cards cannot consume a claim, reader release restores the still-active detail lease, duplicate acquisition is idempotent, and deactivation is exact-token checked against navigation races.
- Confirmed `RootView` reconciles the store with the authoritative project ID set so deleted projects release their coordinator and active surface lease rather than accumulating indefinitely.
- Confirmed failed/stale card actions refresh from the store's authoritative project snapshot before leaving the card stale.
- Confirmed card actions call only `applyKnittingReminderAction(projectID:reminderID:occurrenceID:observedRevision:action:)`; no local project mutation or invented revision is used.
- Confirmed project detail and pattern reader each contain one shared card call, with completed/read-only projects suppressing mutating reminder controls.
- Confirmed the legacy card file and production references are gone, and `git diff --check` is clean.

## Concerns

- The full package suite still contains 11 Task 1/2-era tests that assert the removed legacy `CounterReminder` projection; updating those tests is outside Task 5 scope.
- Physical iPhone, iPad, and Mac acceptance remains a later release gate; this task verified unsigned generic iOS Simulator and macOS builds.

## Task 9 catalog ledger

Task 5 owns these card copy keys and leaves their complete 13-language expansion to Task 9: `knittingReminder.card.complete`, `knittingReminder.card.complete.hint`, `knittingReminder.card.defer`, `knittingReminder.card.defer.hint`, `knittingReminder.card.skip`, `knittingReminder.card.skip.hint`, `knittingReminder.card.stop`, `knittingReminder.card.stop.hint`, `knittingReminder.card.stop.confirm`, `knittingReminder.card.more`, `knittingReminder.card.queue`, `knittingReminder.card.target`, `knittingReminder.card.phase.initial`, and `knittingReminder.card.phase.deferred`. The card resolves these keys through the runtime locale boundary with English fallback copy so missing catalog entries never render raw keys. Task 9 catalog completion is release-blocking.

## Fix round 4 — covering-presentation visibility

### Root cause and fix

The generation-safe lease stack correctly protected nested visible surfaces, but both owning views treated a mounted parent as visible while sheets, navigation destinations, popovers, alerts, or read-only/markup modes covered or removed its queue card. A hidden parent could therefore keep the current lease and consume a future occurrence's haptic claim.

- Added `KnittingReminderPresentationStore.synchronizeSurface(...)`, which idempotently keeps an eligible lease, releases the exact token when hidden, and issues a fresh generation only after visibility returns. Existing stack restoration, stale-token release protection, project pruning, and project isolation remain unchanged.
- Added one derived `isQueueCardActuallyVisible` predicate per surface. Project detail covers edit, counter, note, all-notes, patterns/reader, journal add/detail, reminder-list navigation, calculator navigation, and save-error presentation. Pattern reader additionally requires an active hydrated writable canvas and covers calculator, page note, counter manager, reminder list, load/save/conflict presentations, markup-clear confirmation, markup mode, read-only/completed state, missing content, and inactive scene state.
- Converted the two project-detail navigation links to binding-backed navigation destinations so reminder-list and calculator coverage participate in the same visibility lifecycle.
- The shared queue card now refreshes or claims only when the parent reports actual visibility and its exact lease is still the current top lease.

### RED evidence

```sh
swift test --disable-sandbox --filter KnittingReminderPresentationTests
```

Result before production changes: exit 1 with the expected missing `synchronizeSurface` and `isCurrent` lifecycle APIs. The new behavioral tests could not compile until the visibility transition existed in production.

### GREEN evidence

```sh
swift test --disable-sandbox --filter KnittingReminderPresentationTests
```

Result: exit 0; 19 tests passed. New behavioral coverage proves that visible detail and reader surfaces claim once, a representative cover releases the exact lease so the hidden card cannot claim a future occurrence, overlapping reader covers remain hidden until both clear, and dismissal reacquires a newer generation that claims the future occurrence exactly once.

```sh
swift test --disable-sandbox --filter 'KnittingReminderPresentationTests|KnittingReminderTests|KnittingReminderStoreTests|KnittingReminderMigrationTests|KnittingReminderViewContractTests|CounterReminderViewContractTests|ProjectCounterViewContractTests|PatternReaderCounterContractTests|ProjectDetailLayoutContractTests'
```

Result: exit 0; 120 tests across 9 suites passed. Source contracts enumerate every direct covering state in each derived visibility predicate and require visibility-aware synchronization at both call sites.

```sh
xcodegen generate
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -configuration Debug -derivedDataPath /tmp/KnitNoteTask5Fix4-iOS CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
xcodebuild -project KnitNote.xcodeproj -target KnitNote -sdk macosx -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
git diff --check
```

Result: all commands exited 0. Project generation produced no project-file diff. Both builds were unsigned. iOS emitted the existing App Intents metadata-skip warning; macOS emitted that warning plus the existing multiple-architecture warning.

### Fix-round files

- `Sources/KnitNoteCore/Projects/KnittingReminderPresentationCoordinator.swift`
- `KnitNote/Projects/KnittingReminderQueueCard.swift`
- `KnitNote/Projects/ProjectDetailView.swift`
- `KnitNote/Patterns/PatternReaderView.swift`
- `Tests/KnitNoteCoreTests/KnittingReminderPresentationTests.swift`
- `Tests/KnitNoteCoreTests/ProjectCounterViewContractTests.swift`
- `Tests/KnitNoteCoreTests/PatternReaderCounterContractTests.swift`
- `.superpowers/sdd/2026-08-28-smart-knitting-reminders-2/task-5-report.md`

### Remaining concerns

- Task 9 localization remains deferred and release-blocking as recorded above.
- Automated tests and unsigned builds do not replace later physical iPhone, iPad, and Mac haptic/visibility acceptance.
