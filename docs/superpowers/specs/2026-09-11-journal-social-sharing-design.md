# KnitNote Journal Social Sharing Design

**Date:** 2026-09-11  
**Status:** Approved in conversation  
**Target:** iPhone and iPad (iOS/iPadOS 18+)

## Goal

Let a person turn one existing KnitNote journal entry into an attractive,
standard JPG card and then share it through the system share sheet, save it to
Photos, or copy an editable caption. The feature must remain local-first: it
must not add social-account login, automatic publishing, analytics, or a
server-side dependency.

## Confirmed Product Direction

- Use the warm, handmade scrapbook visual direction (option B).
- Provide a 4:5 post card at exactly 1080 x 1350 pixels.
- Provide a 9:16 story card at exactly 1080 x 1920 pixels.
- Support any destination app that accepts the generated JPG through the Apple
  system share sheet; do not promise direct publishing to a named network.
- Provide independent actions for system sharing, saving to Photos, and copying
  the post text.
- Ship on iPhone and iPad first. Keep renderer boundaries portable, but do not
  expose the feature on Mac in this version.

## Scope

### Included

- A share action in the journal-entry detail toolbar.
- A share-preview screen for one journal entry.
- Live choice between post and story proportions.
- Independent visibility controls for project name, entry date, journal
  caption, and the KnitNote mark.
- A small optional `#KnitNote` suffix for copied text.
- Fixed-size JPG rendering and temporary-file lifecycle management.
- Saving the rendered JPG to Photos with permission and error handling.
- Localized KnitNote-owned UI and labels in the existing String Catalog.
- VoiceOver, Dynamic Type, and accessible state/result announcements.

### Not Included

- Social-network login, credentials, SDKs, APIs, or automatic publishing.
- TikTok Share Kit or per-network branded buttons.
- macOS sharing UI.
- Multi-entry collages, carousels, video, animation, templates, color pickers,
  or user-supplied fonts.
- Location, yarn details, row-counter values, or other project metadata.
- Translation, rewriting, summarization, or generative caption creation.
- Changes to the journal data model or persisted project archive.

## Entry Points and Interaction

`ProjectJournalEntryDetailView` gets a Share toolbar action whenever its project
and entry still exist. Sharing is read-only and remains available for completed
projects even though edit and delete stay locked.

The action opens a sheet containing:

1. A live card preview.
2. A proportion selector: **Post 4:5** or **Story 9:16**.
3. Switches for project name, date, journal text, and KnitNote mark. All four
   default to on for each newly opened preview and are not persisted.
4. An editable post-text field initialized from the complete journal caption.
5. An **Add #KnitNote** switch, on by default. It affects only copied/shared
   post text, not the rendered card.
6. A primary **Share** action plus secondary **Save to Photos** and
   **Copy Text** actions.

The sheet shows progress while loading or rendering and prevents duplicate
actions for the same render. Leaving the sheet cancels obsolete work and removes
owned temporary files.

## Visual Design

The output uses a consistent light, warm scrapbook background in both light and
dark system appearance. The original journal photo remains the visual focus.
The photo has a restrained instant-photo treatment with a slight rotation;
project/date/caption content sits below it in a warm paper note treatment. The
KnitNote mark is small, subordinate, and optional.

The 4:5 layout reserves approximately 60 percent of its height for the photo and
shows at most four lines of journal text. The 9:16 layout reserves approximately
65 percent for the photo and shows at most six lines. The renderer uses safe
insets so common social-network crops do not remove essential content.

Long project names and captions truncate with an ellipsis on the card. The
editable/copyable post text always preserves the complete normalized source
text unless the person edits it in the preview. User-created project names and
journal captions are rendered verbatim and are never localized or translated.
Only KnitNote-owned labels use the selected app language.

When every metadata switch is off, the renderer produces a photo-only card.
The KnitNote mark is never mandatory.

## Architecture

### Share Presentation Model

A view-local presentation model receives an immutable snapshot containing the
project name, entry creation date, complete caption, and full-resolution photo
URL. It owns the selected proportion, visibility settings, editable post text,
hashtag setting, render state, and user-facing errors. It does not hold or
mutate `JSONProjectStore`.

### Card Description

A small value model describes the render without SwiftUI or persistence
dependencies:

- output proportion and exact pixel size;
- localized KnitNote-owned labels;
- optional project name, formatted date, and caption;
- whether the KnitNote mark is visible.

This description is independently testable and becomes the sole input to the
renderer after the photo has loaded.

### Renderer

A dedicated renderer builds a fixed-size SwiftUI card and renders it with
`ImageRenderer`. Rendering runs through an isolated interface so tests can use a
stub and a future Mac implementation can reuse the description and card layout.
The result is encoded as a standards-compatible, color-managed JPG. Rendering
never writes to the journal photo directory or project archive.

The renderer receives immutable input. A generation token prevents an older
asynchronous render from replacing a preview produced for newer settings.

### Temporary Export

A temporary-export service writes generated JPG data atomically beneath a
KnitNote-owned temporary subdirectory using unpredictable, entry-scoped names.
It returns only validated file URLs inside that directory. Files are removed
after the share flow completes, when the preview closes, and during a bounded
startup cleanup of stale owned exports. Cleanup must never follow symlinks or
delete outside the owned root.

### System Boundaries

- SwiftUI `ShareLink` or a narrowly wrapped system activity controller receives
  the temporary JPG and post text. Destination availability and accepted fields
  remain controlled by installed apps.
- A Photos-saving abstraction performs the authorization request and asset
  creation. Denial does not disable sharing or copying.
- A clipboard abstraction writes the final edited post text.

No social SDK is linked and no network request is made by KnitNote.

## Data Flow

1. Resolve the current project and journal entry from the store.
2. Capture immutable text/date values and resolve the existing full-photo URL.
3. Load and validate the full-resolution image.
4. Build a card description from the current preview settings.
5. Render an exact-size JPG and display its preview.
6. On Share, create a temporary export and present the system share UI with the
   edited text where supported.
7. On Save, request Photos access only when needed and create one photo asset.
8. On Copy, place the complete edited text plus optional hashtag on the
   clipboard.
9. Clean up owned temporary output after completion, cancellation, or dismissal.

No step writes back to `StoredProject`, `ProjectJournalEntry`, or their photos.

## Text Rules

- Initial editable text is the complete journal caption, or an empty string
  when the entry has no caption.
- When enabled, `#KnitNote` is appended after one blank line unless it is
  already present as a standalone, case-insensitive hashtag.
- Turning the hashtag off removes only the suffix inserted by the preview; it
  must not delete text the person typed.
- Card line limits affect only visual rendering, not editable or copied text.
- Empty text is a valid copy/share state; image-only sharing remains available.

## Failures and Recovery

- If the project or entry disappears before the sheet opens, dismiss cleanly.
- If the original photo is missing, unreadable, unsafe, or fails to decode,
  show a localized error and Retry. Do not export a placeholder card.
- If rendering or JPG encoding fails, keep the preview open, explain the
  failure, and offer Retry. Do not open an empty share sheet.
- Rapid setting changes cancel or supersede prior rendering so stale output
  cannot become current.
- A denied/restricted Photos authorization shows a localized explanation and a
  Settings route where the platform permits it. Share and Copy remain usable.
- Cancellation from the system share interface is a normal outcome, not an
  error alert.
- Temporary cleanup is best-effort after successful sharing but safety checks
  are mandatory before deletion.

## Accessibility and Localization

- Every selector, switch, progress state, preview, and action has a meaningful
  localized accessibility label and value.
- Success and failure results are announced without relying on color alone.
- Controls meet the existing minimum target sizing and reflow under Dynamic
  Type without changing the exported card's fixed dimensions.
- The card preview has one concise accessibility description rather than
  exposing decorative layers individually.
- All app-owned strings go into the existing String Catalog for every currently
  supported language. User-authored content stays untouched.

## Privacy and Entitlements

Sharing is explicitly initiated by the person and always ends in a system or
user-confirmed action. KnitNote stores no social identity or credentials and
does not upload content itself. Photos permission is requested only after the
person chooses Save to Photos. The implementation must update usage-description
or privacy declarations only if the final platform API requires it; this is a
release gate, not an assumption.

This read-only feature does not change journal-edit entitlements. Completed
projects may share existing entries while remaining otherwise read-only.

## Verification

### Unit Tests

- Card descriptions produce 1080 x 1350 and 1080 x 1920 outputs.
- Every metadata visibility combination maps to the correct optional content.
- Complete text, empty text, long text, multi-script text, emoji, and hashtag
  insertion/removal behave deterministically.
- Generation tokens reject stale render completion.
- Temporary output uses safe owned paths, atomic writes, and bounded cleanup.
- Photo-save authorization and success/failure outcomes map to the correct UI
  state.
- Sharing leaves encoded project and journal state byte-for-byte unchanged.

### Rendering Tests

- Both proportions render at exact pixel dimensions.
- The warm scrapbook layout remains within bounds for short, long, absent, and
  multilingual project/caption content.
- Photo-only output and each optional-field combination render without blank or
  overlapping regions.
- Representative output is checked for color-profile and JPG decodability.

### UI and Contract Tests

- The journal detail exposes Share for active and completed projects.
- Edit/Delete remain unavailable for completed projects.
- The preview switches proportions and metadata without stale results.
- Share, Save, and Copy are reachable and announce outcomes.
- iPad presentation uses a valid sheet/popover anchor and does not crash.

### Physical Acceptance

On the exact release candidate, verify on one iPhone and one iPad:

- both card sizes and all three output actions;
- Photos denial and later authorization;
- long Traditional Chinese plus one non-Latin supported localization;
- sharing cancellation and temporary cleanup;
- receiving a JPG in at least Instagram and TikTok when installed.

Third-party destination UI and caption handling are observations, not KnitNote
release guarantees. Mac, Watch, and automatic social publishing are outside this
feature's acceptance scope.

## Release Gates

- Relevant unit, rendering, contract, and UI tests pass.
- Unsigned iOS build passes for the exact candidate.
- String Catalog completeness and privacy/usage-description audits pass.
- iPhone and iPad physical acceptance is recorded against the same full commit,
  version, and build that would be submitted.
- Existing unrelated cross-device-sync and release gates remain independent and
  must not be inferred complete from this feature's results.
