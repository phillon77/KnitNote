# Six Project Counters Design

## Goal

Replace each project's single row counter with six independent counters for complex knitting patterns. Every counter has an editable name, its own value, and its own per-row notes. The Projects and Pattern Reader screens edit the same stored counters and remain synchronized.

The feature must retain the current quick-counting experience, preserve existing project data, remain usable while following a large pattern on iPad, and support localization.

## Counter Model

Every project owns exactly six counters in a stable order. Each counter stores:

- a stable identifier;
- an editable localized display name;
- a non-negative integer value;
- notes keyed by that counter's row value.

New projects receive six counters named with localized defaults equivalent to `計數器 1` through `計數器 6` in Traditional Chinese and `Counter 1` through `Counter 6` in English. Default names are generated from localization keys rather than persisted source-language literals.

If a user clears a custom name, the counter returns to its localized default name. Renaming a counter does not change its identifier, value, order, or notes.

Each project also stores the selected counter identifier. Both Projects and Pattern Reader use this value as the current primary counter.

## Existing Data Migration

The project archive version advances once. When an older project is decoded:

- its existing `currentRow` becomes Counter 1's value;
- its existing row notes become Counter 1's notes;
- Counters 2 through 6 begin at zero with no notes;
- Counter 1 becomes the selected counter;
- all unrelated project, pattern, photo, markup, and reading-state data remains unchanged.

Migration is deterministic and idempotent. Loading and saving an already migrated project must not create additional counters or move notes again.

Compatibility accessors may temporarily expose the selected counter value to unchanged code, but the six-counter collection is the authoritative source after migration.

## Project Detail Experience

The central counting area represents the selected counter:

- its name appears above the large number;
- tapping the name or edit affordance opens counter renaming;
- the large `+1` action increments only the selected counter;
- Undo decrements only the selected counter and is disabled at zero;
- Notes opens the note belonging to the selected counter's current value.

A counter selector appears below the primary controls. It always exposes all six counters in stable order. Each item shows its name and value, can be tapped to become the selected counter, and offers a compact quick-add action. The selected item uses the existing watercolor accent treatment.

iPhone uses a two-column layout. iPad uses three or six columns depending on available width. Controls retain practical touch targets and Dynamic Type support. The selector may scroll when accessibility text sizes require additional space.

Project list cards show only the selected counter's name and value so the Projects home screen remains uncluttered.

## Pattern Reader Experience

The Pattern Reader receives a collapsible counter panel inside its existing safe-area controls.

When collapsed, the panel shows only the selected counter's name, value, decrement, increment, expand, and note actions. When expanded, it exposes all six counters with selection, decrement, increment, rename, and note access.

The panel edits the same project model as Project Detail. A value, name, note, or selection changed in one screen is visible when the other screen appears, without a separate synchronization layer.

The panel must not reset when the user changes PDF pages, moves highlight lines, enters or leaves markup, rotates the device, or switches between compact and full-screen iPad presentation. On iPad it stays within the safe area and reserves enough layout space that the bottom of the pattern remains reachable. On iPhone the expanded panel uses a compact two-column layout and may scroll independently of the PDF.

## Notes

Each counter owns an independent note namespace keyed by its current integer value. For example, Counter 1 row 12 and Counter 2 row 12 are different notes.

Opening Notes always carries both the counter identifier and row value. Saving an empty note deletes only that exact counter-row note. Renaming, selecting, incrementing, or decrementing another counter cannot overwrite it.

The existing note editor presentation and save semantics remain unchanged apart from this composite identity.

## State and Data Flow

`StoredProject` is the single source of truth. Mutating APIs identify a counter explicitly for increment, decrement, rename, selection, and note updates. Views do not calculate array indexes from names and do not duplicate counter values in local state.

The project store persists each mutation through its existing save path. UI-only state, such as whether the Pattern Reader panel is expanded, remains local to the view and is not part of the project archive.

Counter operations reject unknown identifiers safely. Values clamp at zero, names trim surrounding whitespace, and failed persistence leaves the last committed project data available to the UI.

## Localization and Accessibility

- Add localized format strings for all six default counter names using the counter number as an argument.
- Localize panel labels, rename controls, accessibility values, and action descriptions in Traditional Chinese and English.
- VoiceOver announces the counter name, current value, selected state, and whether an action increments or decrements it.
- Counter identity never depends on a translated name, so changing the app language does not detach notes or values.
- Reduce Motion and the existing watercolor visual system remain unchanged.

## Testing and Acceptance

Automated tests cover:

- six counters on every new project;
- localized default-name formatting and blank-name reset;
- independent increment and decrement with zero clamping;
- stable counter selection;
- independent notes for equal row values on different counters;
- rename operations preserving value and notes;
- legacy row and note migration into Counter 1;
- migration idempotence and archive round trips;
- project-store persistence of all six counters;
- Project Detail and Pattern Reader source-contract integration;
- no reset during PDF page, highlight, or markup state changes;
- localized Traditional Chinese and English strings.

Manual acceptance covers iPhone and iPad in portrait and landscape, large Dynamic Type, Pattern Reader collapsed and expanded states, rapid quick-add operations, renaming, per-counter notes, navigation between Project Detail and Pattern Reader, app relaunch, and existing-project migration.

## Out of Scope

- More or fewer than six counters per project.
- Reordering, deleting, duplicating, or color-coding counters.
- Automatic linked counters, repeat formulas, targets, or reset rules.
- Showing all six counters on project-list cards or Apple Watch in this version.
- Cloud conflict resolution beyond the existing project-store behavior.
