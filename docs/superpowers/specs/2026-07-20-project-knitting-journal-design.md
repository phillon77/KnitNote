# Project Knitting Journal Design

Date: 2026-07-20
Status: User-approved design

## Goal

Add a lightweight, photo-first knitting journal to each project so users can casually record visible progress and feel a sense of accomplishment. The feature must remain simpler than an activity log: it records only entries the user deliberately creates, never counter taps or other automatic events.

## Scope

Version 1 includes:

- one journal per project;
- entries containing one required photo, an optional short caption, and an automatically recorded creation date;
- camera and photo-library import;
- horizontal, newest-first cards on the project detail screen;
- full-photo viewing;
- caption editing and entry deletion while the project is active;
- read-only viewing after the project is completed;
- Traditional Chinese and English localization and VoiceOver support.

Version 1 does not include badges, streaks, statistics, automatic milestones, social sharing, manual date editing, multiple photos per entry, or a separate global journal tab.

## Placement and Visual Design

The journal appears in the currently unused lower portion of `ProjectDetailView`, after the existing Notes and Patterns actions and before the bottom tab bar. It uses the existing watercolor palette, rounded white surfaces, and magenta action color.

The section header reads “編織日記” / “Knitting Journal”. While the project is active, a single plus button appears at the trailing edge. Entries form one horizontal scrolling row, newest first. Each compact card shows:

- a rounded photo thumbnail;
- the optional caption, limited visually to two lines without changing the stored text;
- a locale-formatted date.

The row must fit the existing vertical scroll view and must not create nested vertical scrolling. It uses lazy horizontal loading so a long journal remains responsive. Card widths may adapt modestly between iPhone and iPad, while retaining one-row presentation.

When no entries exist and the project is active, the section shows a small calm prompt: “記錄這件作品的第一個進度吧” / “Record the first progress on this project.” When a completed project has no entries, the section remains present in read-only form with a neutral empty message and no add affordance.

## User Flows

### Add

1. The user taps the plus button.
2. A compact source chooser offers Camera and Photo Library. Camera is offered only where the platform and hardware support it.
3. After choosing or taking a photo, the editor shows the image and one optional caption field.
4. Tapping Done normalizes and saves the image, creates the entry with the current date, persists the project archive, and dismisses the editor.

The photo is the only required content. Canceling at any stage creates nothing.

### View and edit

Tapping a card opens a focused detail view with the full stored image, caption, and date. For an active project, this view exposes Edit and Delete. Edit changes only the caption in version 1; users create another entry if they want a different photo. Delete requires confirmation and removes both the entry metadata and its managed image files.

### Completed projects

Completing a project makes the journal read-only immediately:

- existing entries and full photos remain viewable;
- the plus button is hidden;
- caption editing and deletion are unavailable;
- all store mutation APIs also reject journal changes, so the lock is not merely visual.

Resuming the project restores add, edit, and delete. Completing or resuming never changes existing journal data.

## Data Model

Add a `ProjectJournalEntry` value type in `KnitNoteCore` with:

- `id: UUID`;
- `photoFilename: String`;
- `thumbnailFilename: String`;
- `caption: String?`, normalized by trimming surrounding whitespace and converting blank text to `nil`;
- `createdAt: Date`.

`StoredProject` gains a private-set `[ProjectJournalEntry]` collection. Public read access returns the entries in a deterministic newest-first order; persistence must not depend on UI sorting. Legacy archives without the field decode it as an empty array. Entry identifiers must be unique within a project, malformed blank filenames are rejected, and invalid or duplicate decoded entries must not be allowed to reference arbitrary files.

The JSON archive version is incremented once. Migration remains backward-compatible: all existing project, counter, note, pattern, completion, photo, yarn, and tool data must decode unchanged.

## Image Storage and Size

Journal images live in a dedicated managed directory, separate from project cover and yarn photos. The app never copies an original camera-sized image directly into managed storage.

Before commit:

- normalize orientation;
- resize the full image to a maximum long edge of 1600 pixels without upscaling;
- encode as JPEG at approximately 0.8 quality;
- create a separate small thumbnail sized for the journal card;
- use generated unique filenames and validate that the source is a decodable image.

Typical full images should remain roughly 300 KB to 1 MB, so 100 entries are expected to use approximately 30–100 MB plus small thumbnails. Version 1 imposes no entry-count limit.

The list loads thumbnails only. The full file is loaded only in the detail view. Image decoding and resizing must not block the main UI thread. The editor shows an inline saving progress indicator while that background work runs, disables Done to prevent duplicate submissions, and remains dismissible only after the transaction finishes or fails.

Restyling the existing Notes and Patterns buttons to match the calculator tool card is an explicitly deferred follow-up and is not part of this journal implementation.

## Store Transactions and Cleanup

Journal mutation belongs to `JSONProjectStore`, not directly to SwiftUI views. Add, edit, and delete operations identify both the project and entry by stable IDs and validate that the project still exists and is active at commit time.

Adding uses an atomic best-effort transaction:

1. prepare full and thumbnail files under unique candidate names;
2. update and persist the archive with the new entry;
3. if persistence fails, remove both candidates and keep the in-memory project unchanged.

Editing a caption persists the archive before publishing the updated project. Deleting persists removal of the metadata first, then removes the now-unreferenced managed files. If file cleanup fails, the metadata remains deleted and later reconciliation removes the orphan; no live entry is damaged.

Deleting a project removes all journal full images and thumbnails after the project archive update succeeds. Successful trusted archive loads reconcile the journal directory against all referenced filenames. An unreadable archive must never trigger reconciliation or deletion.

## Failure Handling

- Invalid or unsupported images show a localized error and leave the editor draft available for retry.
- Camera denial or photo-picker cancellation does not create an entry.
- Storage or archive failure keeps the previous committed project unchanged and presents a localized retryable error.
- A project completed or deleted while an editor is open causes the final save to fail safely with a localized message.
- A missing journal image shows a neutral placeholder in the card/detail view without crashing; trusted reconciliation and later deletion may clean its metadata only through explicit store rules.

## Localization and Accessibility

All titles, empty states, source choices, buttons, confirmations, lock messages, and errors use String Catalog keys with complete `en` and `zh-Hant` values. Dates use the active app language while preserving the device region.

Each journal card is one VoiceOver element whose localized label includes the caption when present and the formatted date. The plus button states that it adds a journal entry. The image picker, editor, detail actions, destructive confirmation, empty state, and completed read-only state remain understandable without color. Touch targets are at least 44 by 44 points and Dynamic Type must not overlap or truncate actionable labels.

## Testing and Acceptance

Core tests cover:

- entry normalization, deterministic ordering, Codable round trips, and legacy migration;
- archive version migration without loss of existing data;
- add, caption edit, delete, and persistence across store instances;
- active/completed/resumed mutation rules;
- invalid, missing, duplicate, and unreferenced filenames;
- add rollback and delete/reconciliation failure behavior;
- project deletion cleanup without touching another project's files;
- image validation, unique filenames, 1600-pixel maximum, thumbnail generation, and no upscaling.

View and localization contracts cover:

- placement after Notes and Patterns and before the tab bar;
- a lazy horizontal newest-first row;
- active empty state and completed read-only empty state;
- camera availability guards and photo-library support;
- hidden add/edit/delete controls for completed projects;
- full Traditional Chinese and English copy, VoiceOver labels, Dynamic Type-safe layout, and 44-point actions.

Final acceptance requires successful full Swift tests, String Catalog validation, project generation, macOS build, iOS build when CoreSimulator is available, and interactive checks on both iPhone and iPad for adding, horizontal scrolling, full-photo viewing, editing, deleting, completion locking, resuming, and persistence after relaunch.
