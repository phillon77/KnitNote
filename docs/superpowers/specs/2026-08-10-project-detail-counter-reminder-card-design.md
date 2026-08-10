# Project Detail Counter Reminder Card Design

Date: 2026-08-10

## Goal

Show a selected counter's pending reminder directly on the project detail page
so Complete and Stop are available without opening the pattern reader.

## Placement and presentation

When the selected project counter has a pending reminder, the existing
`CounterReminderCard` appears immediately below the `CounterSelectorGrid` card
and before the yarn section. No placeholder or empty card is shown when there
is no pending reminder.

The project detail page reuses the existing card unchanged. This preserves its
localized reached-row and combined-count copy, optional user message,
VoiceOver labels and hints, adaptive Complete/Stop layout, and 44-point action
heights. The pattern reader continues to show the same component; neither
screen creates a second reminder record.

## Data flow

The card is derived from `project.selectedCounter.reminder?.pending`. Its
message comes from the same selected counter reminder. Changing the selected
counter immediately changes or removes the visible card through the existing
store observation.

Complete passes the pending reminder ID and observed occurrence count to
`JSONProjectStore.completeCounterReminder`. Stop passes the selected counter ID
and pending reminder ID to `JSONProjectStore.stopCounterReminder`. Both use the
existing direct project transactions; no new persistence model or reminder
state is introduced.

## Failure and stale-state behavior

The view never hides the card by changing local presentation state. A card
disappears only when the store publishes an accepted mutation.

After Complete or Stop returns, the view checks the current selected counter:

- Complete succeeds only if the matching pending occurrence is no longer
  present.
- Stop succeeds only if the matching reminder is no longer active.

If the direct operation throws, or the expected postcondition is not true, the
existing project-detail save-error alert is shown. The card remains visible so
the user can refresh or retry. Completed-project rejection therefore cannot
look successful.

## Testing

A source contract must prove that:

- the card is placed after the counter selector and before the yarn section;
- it is driven only by the selected counter's pending reminder;
- the existing card receives the pending value and user message;
- Complete uses the exact reminder ID and observed occurrence count;
- Stop uses the exact reminder ID;
- both actions check the store postcondition and surface the existing error;
- neither action clears local card state.

Existing core reminder/store tests continue to cover atomic completion,
stopping, stale ID/count rejection, completed-project rejection, and persistence
failure. Focused view/store tests and unsigned iOS/macOS builds must pass before
physical testing.

## Physical acceptance

The exact committed 1.5.0 (Build 9) candidate is overlay-installed on the
paired iPhone without uninstalling or erasing data. The user confirms on the
project detail page that a pending combined reminder appears below the counter
grid, Complete clears it once, Stop disables it, reopening preserves the
result, and prior projects remain present.

## Boundaries

This work does not change reminder scheduling, Watch behavior, pattern-reader
behavior, localization catalogs, user-created text, metadata, version/build,
archive/export, upload, submission, merge, or push state. iPad, Watch, Mac, and
release acceptance remain separate gates.
