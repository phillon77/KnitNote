# Photos save crash follow-up — 2026-09-12

## Physical finding

The user confirmed that existing projects/journals and both share preview
formats work on iPhone 17 Pro Max (iOS 26.6.2). Saving to Photos terminated
KnitNote twice. Installed source: `dbdf09554ddc20861a9b1c96c0b790e57899d849`,
development build 1.6.1 (13). This is a failed physical acceptance gate.

Both 07:56 crash reports show `EXC_BREAKPOINT / SIGTRAP` on
`com.apple.PHPhotoLibrary.changes`, through `_dispatch_assert_queue_fail`,
Swift executor isolation checking, and the closure in
`IOSJournalPhotoSaver.saveJPEG(at:)`. The built app contains the correct
Photos-add purpose string; this was not a missing privacy declaration.

## Cause and bounded fix

The change block inherited MainActor isolation from the photo saver. Photos
executes change handlers on an arbitrary serial queue (documented in the
installed SDK's `PHPhotoLibrary.h`). Explicit `@Sendable` on the change block
prevents that inappropriate inherited isolation and restricts captured state
to the sendable file URL. The UI/coordinator remain MainActor-isolated.
Add-only authorization, asynchronous completion, typed errors, and temporary
file lifetime/cleanup are unchanged.

## Regression evidence

The new native test `testBothFormatsSaveToPhotosWithoutTerminatingApp` uses
the existing disposable simulator fixture, accepts the real Photos prompt,
and requires Saved to Photos, a running foreground app, and an enabled Save
button for each format. No physical user data is used by this test.

Evidence directory: `/private/tmp/knitnote-photos-crash-fix.JVFFjB`.

- Initial `red.xcresult`: test-harness failure recognizing the system's
  Traditional Chinese permission prompt; not counted as crash reproduction.
- `red-crash.xcresult`: failure against unchanged production code, with a
  matching simulator crash stack at 08:03:49.
- `green-iphone.xcresult`: 1 test passed, 0 failed, exercising both formats.
  Actual simulator Photos assets IMG_0007.JPG and IMG_0008.JPG, created at
  08:04:58 and 08:05:24, read back as 1080×1350 and 1080×1920 respectively.

- `green-ipad.xcresult`: 1 test passed, 0 failed, exercising both formats.
- `coordinator-renderer.xcresult`: focused `JournalSharePreviewModelTests` and
  `JournalShareCardRendererTests` completed with exit 0, covering save states,
  failures, source immutability, temporary cleanup, and image rendering.
- Narrow independent code review: no Critical, Important, or Minor findings;
  physical Save retest remains required.

These commands used `xcodebuild test -quiet`, `KnitNote.xcodeproj`,
`CODE_SIGNING_ALLOWED=NO`, and derived data at
`/private/tmp/knitnote-journal-share-derived`. Native regression used scheme
`KnitNoteJournalShareUITests`, test selector
`KnitNoteJournalShareUITests/JournalShareFlowUITests/testBothFormatsSaveToPhotosWithoutTerminatingApp`,
and iOS 26.5 simulators iPhone 17 Pro and iPad Pro 13-inch (M5). Coordinator
and renderer suites used scheme `KnitNote`, destination `platform=macOS`.

Signed installation and user retest status are recorded below as they
complete. The previous full Core/App results describe their original source
revision; they are not rerun or relabeled for this fix.

## Physical retest

- Fixed source: `b3b31f96feecbf363f1a2f32f820c6cef1b3f6fa`, development
  1.6.1 (13). Signed device build completed with exit 0; deep/strict signature
  verification passed and built Info.plist source revision matched.
- [x] Fixed build installed on the user's iPhone at 08:10 Taiwan time without
  uninstalling the existing app. Installation receipt:
  `/private/tmp/knitnote-photos-crash-fix.JVFFjB/install-fixed.json`.
- Automatic launch was denied because the iPhone was locked; the user must
  unlock and open KnitNote. This is not a post-fix application crash.
- [x] After installing the fix, the user reported that saving to Photos was
  normal. The reply did not enumerate each format separately.
- [x] The user subsequently reported normal image/text receipt in a social
  draft. The tested destination was not named, so this does not individually
  certify Instagram, TikTok, Facebook, or X.
- [ ] Photos denial/recovery and remaining destination-specific checks.

## iPad installation

After the user confirmed the iPad data was backed up, the same signed
`b3b31f96feecbf363f1a2f32f820c6cef1b3f6fa` app was installed on iPad Air 5
without uninstalling it first. The existing version was 1.5.1 (11); this is an
upgrade to 1.6.1 (13). Installation succeeded at 19:16 Taiwan time, with receipt
`/private/tmp/knitnote-photos-crash-fix.JVFFjB/install-ipad-fixed.json`.

- [x] User confirms existing iPad projects/journals are intact after upgrade.
- [x] User reports both preview ratios and Photos saving are normal.
- [x] User reports sharing through Messages is normal. No social app is
  installed on that iPad; this does not certify social-app receipt.
- [x] After denying Photos permission, the user confirms the permission
  prompt is shown rather than a crash. Restoring permission was requested;
  a subsequent successful save after restoring it was not separately reported.

The user subsequently authorized a local merge back to the original development
branch. No archive, upload, push, submission, or release is authorized.
