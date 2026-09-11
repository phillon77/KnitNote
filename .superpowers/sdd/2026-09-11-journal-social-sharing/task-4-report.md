# Task 4 Report: Preview Coordinator and Injectable iOS Actions

## RED/GREEN evidence

RED command:

```text
xcodebuild test -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /private/tmp/knitnote-journal-share-derived CODE_SIGNING_ALLOWED=NO -only-testing:KnitNoteAppTests/JournalSharePreviewModelTests
```

Result: failed during test-target compilation because
`JournalSharePreviewModel`, `JournalShareSource`, `JournalPhotoSaving`,
`JournalTextCopying`, and the typed state/error values did not exist. This was
the expected missing-feature RED.

Final focused GREEN command:

```text
xcodegen generate
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /private/tmp/knitnote-journal-share-derived CODE_SIGNING_ALLOWED=NO -only-testing:KnitNoteAppTests/JournalSharePreviewModelTests
```

Result: exit 0. The result bundle reports 18 passed, 0 failed, 0 skipped.

Platform-adapter compile command:

```text
xcodebuild build -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/knitnote-journal-share-derived CODE_SIGNING_ALLOWED=NO
```

Result: exit 0, including the iOS-only Photos and UIKit adapters.

Per the controller ruling, the full app and Core suites are deferred to final
integration and were not run for Task 4.

## Implemented behavior

- `JournalSharePreviewModel` snapshots `JournalShareSource`; it retains no
  mutable project or store reference.
- Editable text is the card caption and the complete copy/share text source.
  `#KnitNote` is composed only for copy/share and is never rendered on the card.
- Photo bytes are read off-main from a non-empty regular file. Direct photo and
  photo-directory symlinks are rejected, while the legitimate `/var` system
  alias remains supported. Decode rejection maps to the retryable photo error.
- A generation token plus an immutable description comparison rejects stale
  success and failure, including settings changed before the next refresh begins.
- Sharing and Photos saving use real owned temporary exports. Share exports live
  until `finishSharing`; Photos exports live through the awaited system consumer.
  Dismissal cannot unlink a file still being consumed or publish stale outcomes.
- Photos denial and asset-write failure have distinct typed outcomes. Permission
  is requested only by the iOS saver after Save to Photos is selected.
- Startup stale-export cleanup is best effort, bounded to 50 files older than one
  day, and runs without delaying model initialization.
- Tests encode the real entry before/after actions and compare real source photo
  bytes, rather than comparing two unchanged local values.

## UI-facing interfaces

- Construct with `JournalShareSource(projectName:entry:photoURL:)`, injected
  `Locale`, renderer, export service, photo saver, and text copier.
- Bind controls to `format`, `visibility`, `editableText`, and `includesHashtag`.
- Call `refreshPreview()` when the sheet opens or any card-affecting setting
  changes. Render `previewJPEG` only for `.ready`; `.failed(.photoUnavailable)`
  and `.failed(.renderingFailed)` support Retry.
- Enable Share using `canShare`; call `prepareShare()` and retain the returned
  `JournalSharePayload` through the system completion callback, then call
  `finishSharing(_:)` for both completion and cancellation.
- Call `saveToPhotos()` and observe `photoSaveState` (`idle`, `saving`, `saved`,
  `failed`, or `cancelled`) plus `photoSaveError` for existing UI mapping.
- Enable Copy using `canCopy` and call `copyText()`.
- Call `dismiss()` from sheet teardown. A later system completion callback must
  still call `finishSharing(_:)` so its retained export is safely removed.

## Self-review and concerns

- The focused tests use explicit continuation/call-count handshakes rather than
  sleeps. They cover stale render success/failure, stale Save rejection,
  duplicate actions, exact composed copy text, locale injection, source-byte
  immutability, save success/denial/write failure/cancellation, real export
  cleanup, and symlink safety.
- The loader rejects a symlink used as the immediate photo directory. It does
  not attempt a descriptor-relative audit of every ancestor; normal app-owned
  storage plus direct file/directory checks bound this Task 4 read path.
- System-share cancellation is intentionally not an error; Task 5 must always
  route its completion callback to `finishSharing(_:)`.
