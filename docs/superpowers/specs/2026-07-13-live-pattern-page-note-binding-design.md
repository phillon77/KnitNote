# Live Pattern Page Note Binding Design

## Goal

Make a saved pattern page note appear immediately when its editor is reopened, while preserving the note after leaving and reopening the pattern reader.

## Root Cause Boundary

The first failure occurred after tapping Save and immediately reopening the note editor. Live binding fixed that behavior on iPad, but iPhone still loses the note even after leaving and reopening the pattern. The remaining failure is caused by relying on the reader view's transient state during the iPhone sheet lifecycle. Saving must not depend on the reader view remaining alive.

## State Ownership

`PatternReaderView` owns the active editing value through `PatternReadingState.pageNote`. `EditPatternPageNoteView` receives a binding to that value instead of creating a private text copy.

The project store is the persistence owner. It exposes a dedicated operation that receives project ID, pattern ID, zero-based page index, and note text. That operation updates only the requested page's `PatternPageState.note` and writes the project archive without reading transient reader state.

When the editor opens, the reader records the original note so Cancel can restore it. While the editor is open, the text editor updates the active binding. When the sheet closes, the reader reloads the confirmed current page note from the project store.

## Save and Cancel

- Save directly calls the project store's page-note operation with the captured project, pattern, and page identifiers. It does not persist a detached copy of the complete reader state.
- Cancel restores the note captured when the editor opened and dismisses without persisting the draft.
- A save failure continues to use the existing save-error alert.
- Sheet dismissal reloads the active page from the project store, so reopening displays the saved text on both iPhone and iPad.

## Page and File Persistence

The existing `PatternPageState.note` field and project JSON archive remain the storage format. No separate note files or archive migration are introduced. Page transitions continue to save and load notes together with page-specific highlight positions.

## Scope

This change affects only pattern page note editing and its regression tests. It does not change PDF navigation, handwriting markup, highlights, project row notes, localization text, or pattern import.

## Verification

Automated tests will verify that the dedicated store operation updates only the requested page and survives a project-store reload. Platform builds will verify iOS/iPadOS and macOS compilation. Manual verification will cover Save followed by immediate reopen on iPhone and iPad, Cancel, page switching, and leaving and reopening the pattern reader.
