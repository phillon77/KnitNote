# Project Content Color Indicators Design

## Goal

Make existing content easier to recognize on the project detail screen without adding badges, counts, or visual clutter.

## Visual Behavior

- The Pattern and Notes action-card labels keep the current primary foreground color when their corresponding content is empty.
- A Pattern label uses `WatercolorTheme.actionBerry` when the project contains at least one pattern.
- A Notes label uses `WatercolorTheme.actionBerry` when any of the project's six counters contains at least one row note.
- The Knitting Journal section title uses `WatercolorTheme.actionBerry` when the project contains at least one journal entry.
- Removing the last corresponding item immediately restores the primary foreground color.
- The journal entry cards, photographs, dates, empty-state copy, and add button retain their existing styling.
- The Knitting Calculators card remains unchanged and is the visual color reference.

## Architecture

`ProjectDetailView` derives the Pattern and Notes content states from the current `StoredProject` value on each render and passes the state into its existing action-card helper. The helper applies either the berry or primary foreground style to the label only.

`ProjectJournalSection` derives its title color from `project.journalEntries.isEmpty`. No persisted fields, migration, localization key, or store mutation is added.

## State Definitions

- Pattern content: `project.patterns.isEmpty == false`.
- Notes content: at least one counter has a non-empty `rowNotes` collection. The selected counter does not limit this check.
- Journal content: `project.journalEntries.isEmpty == false`, including completed projects whose journal is read-only.

## Accessibility

Color is supplemental only. Existing localized labels, button traits, navigation behavior, and journal accessibility remain unchanged. No status is communicated solely as required information through color.

## Testing

- Add focused view-contract coverage for the three state expressions and berry/primary styling.
- Verify the focused tests fail before production changes and pass afterward.
- Run the complete Swift test suite.
- Build the iOS Simulator and macOS targets.
- Run `git diff --check` and inspect the final scoped diff.

## Non-goals

- No badges, counts, dots, animations, card-background changes, or new settings.
- No changes to Pattern, Notes, or Journal storage behavior.
- No changes outside the project detail screen.
