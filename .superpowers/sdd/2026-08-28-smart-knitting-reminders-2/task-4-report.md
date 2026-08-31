# Task 4 report — reminder list and editor UI

## Scope

- Added one project-level `KnittingReminderListView(projectID:)` with active and ended sections, deterministic next-target/creation/ID ordering, a main-counter-only add route, and exact revision-backed stop, reset, and delete actions.
- Added `KnittingReminderEditorView(projectID:reminderID:)` for new and migrated reminders. It presents semantic kinds, verbatim optional text, one-time/repeating schedules, interval, finite/unlimited limits, and only constructs a draft after integer validation succeeds.
- Added `KnittingReminderSummary` for locale-aware semantic/system copy while rendering user-entered text with `Text(verbatim:)`.
- Added the same reminder-list entry point and active count beside project counters and in the pattern reader toolbar.
- Replaced the legacy `CounterReminderEditor` creation flow. Counter management now keeps only a migrated secondary-counter edit link; counter saves preserve reminder state with `.unchanged`.
- Kept queue-card, haptic, Watch, and catalog-expansion work out of scope for later tasks.

## RED evidence

Command:

```sh
swift test --disable-sandbox --filter 'KnittingReminderViewContractTests|ProjectDetailLayoutContractTests|PatternReaderCounterContractTests|CounterReminderViewContractTests'
```

Before production implementation, the new list/editor/summary source files were absent and the old counter-manager reminder creation expectations still existed. The run compiled the contracts and failed with the expected missing-file and legacy-affordance assertions (15 issues across the selected suites).

## GREEN evidence

```sh
swift test --disable-sandbox --filter 'KnittingReminderTests|KnittingReminderStoreTests|ProjectCounterViewContractTests|CounterReminderViewContractTests|KnittingReminderViewContractTests|ProjectDetailLayoutContractTests|PatternReaderCounterContractTests'
```

Result: exit 0; 92 tests across 7 suites passed.

```sh
xcodegen generate
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -quiet build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet build
git diff --check
```

Result: all commands exited 0. The macOS build emitted Xcode's existing multiple-matching-destination warning only.

## Files

- Added `KnitNote/Projects/KnittingReminderListView.swift`
- Added `KnitNote/Projects/KnittingReminderEditorView.swift`
- Added `KnitNote/Projects/KnittingReminderSummary.swift`
- Deleted `KnitNote/Projects/CounterReminderEditor.swift` after all production references moved.
- Updated project-detail, pattern-reader, counter-manager, generated-project, and affected source-contract files.

## Self-review

- Confirmed new creation calls the Task 2 store API, whose binding is `StoredProject.mainCounterID`; editor updates, stop/reset, and delete always carry the reminder ID plus observed revision.
- Confirmed migrated secondary rules are visible with their counter display name and remain reachable from counter management without any secondary add control.
- Confirmed finished projects make the list rows read-only and disable editor saving.
- Confirmed no Task 5 queue/haptic implementation was added and `git diff --check` is clean.

## Concerns

- Task 9 still owns the reviewed 13-language catalog expansion. Until then, `KnittingReminderSummary` is locale-aware and has English fallbacks when the new catalog keys are not yet present; user-entered text remains unchanged.
- This task provides automated source/store coverage and unsigned builds only. Physical iPhone, iPad, and Mac acceptance remains a later release gate.
