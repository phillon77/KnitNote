# Live Pattern Page Note Binding Design

## Goal

Make a saved pattern page note appear immediately when its editor is reopened, while preserving the note after leaving and reopening the pattern reader.

## Root Cause Boundary

The reported failure occurs after tapping Save and immediately reopening the note editor. This places the failure between the editor's private text state and the reader's current-page state, before a full pattern reload. The current editor owns a separate `@State` string and returns it through a closure, creating two copies of the same page note with separate SwiftUI lifetimes.

## State Ownership

`PatternReaderView` remains the sole owner of the active page note through `PatternReadingState.pageNote`. `EditPatternPageNoteView` receives a binding to that value instead of creating a private text copy.

When the editor opens, the reader records the original note so Cancel can restore it. While the editor is open, the text editor updates the active page note binding directly.

## Save and Cancel

- Save calls a reader-owned action that stores the active note in `pageStates`, persists the complete pattern reading state, and dismisses the editor only after the save attempt is made.
- Cancel restores the note captured when the editor opened and dismisses without persisting the draft.
- A save failure continues to use the existing save-error alert.
- Reopening the editor reads the active page note binding and therefore displays the saved text immediately.

## Page and File Persistence

The existing `PatternPageState.note` field and project JSON archive remain the storage format. No separate note files or archive migration are introduced. Page transitions continue to save and load notes together with page-specific highlight positions.

## Scope

This change affects only pattern page note editing and its regression tests. It does not change PDF navigation, handwriting markup, highlights, project row notes, localization text, or pattern import.

## Verification

Automated tests will verify that setting a page note updates the active page and survives a project-store reload. Platform builds will verify iOS/iPadOS and macOS compilation. Manual verification will cover Save followed by immediate reopen, Cancel, page switching, and leaving and reopening the pattern reader.
