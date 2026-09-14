# Journal sharing local merge verification — 2026-09-12

The user authorized a local merge only. No push, archive, upload, App Store
submission, or release was performed as part of this integration.

## Exact integration

- Original development branch: `docs/cross-device-sync-design`.
- Previous target HEAD: `dd499905c053b884882838f53eec69c6b0925f2d`.
- Feature: `feature/journal-social-share`.
- Fast-forwarded and tested HEAD: `aeecdf01c7e71248d3bbb6670f1da7976ec1a041`.
- Integration command: `git merge --ff-only feature/journal-social-share`.
- Existing untracked development/design files were preserved unchanged.
- `git diff --check` from the previous target to the tested HEAD passed.

## Fresh post-merge results

All commands ran in the target development worktree. Evidence root:
`/private/tmp/knitnote-share-local-merge.FxMnnX` (temporary local artifacts).

| Check | Result | Evidence |
| --- | --- | --- |
| `swift test --no-parallel` | Exit 0; 2,950 tests in 215 suites passed, 2,854.679 seconds | `core.log` |
| Full `KnitNoteAppTests`, macOS arm64 | Exit 0; 510 distinct passed, 2 skipped, 0 failed; 683 parameterized passes | `app.xcresult` |
| iPhone 17 Pro / iOS 26.5 simulator Photos regression | Exit 0; 1 passed, 0 skipped/failed; both 4:5 and 9:16 actual saves | `iphone.xcresult` |
| iPad Pro 13-inch (M5) / iOS 26.5 simulator Photos regression | Exit 0; 1 passed, 0 skipped/failed; both 4:5 and 9:16 actual saves | `ipad.xcresult` |

Xcode commands used `KnitNote.xcodeproj`, `CODE_SIGNING_ALLOWED=NO`, and
`-derivedDataPath /private/tmp/knitnote-share-local-merge.FxMnnX/DerivedData`.
App tests used scheme `KnitNote` and `-only-testing:KnitNoteAppTests`.
Simulator tests used scheme `KnitNoteJournalShareUITests` and selector
`KnitNoteJournalShareUITests/JournalShareFlowUITests/testBothFormatsSaveToPhotosWithoutTerminatingApp`.

The two App skips were the existing built-child-exit bootstrap integration
case (result only says skipped) and the opt-in CloudKit Development-container
integration case. They are not counted as passing coverage.

## Physical acceptance and remaining scope

See [Photos crash verification](JournalPhotoSaveCrashVerification.md) for the
fixed source revision, signed installations, and user reports. The iPad
confirmed both image formats, Photos saving, Messages sharing, and a visible
denied-permission prompt without a crash. In subsequent user-reported physical
retests, Instagram was installed on the iPad and sharing to it succeeded;
saving to Photos also succeeded again after permission was restored. These
reports close the iPad Instagram-sharing and permission-recovery checks,
without changing the historical automated results above. Facebook, X, and
TikTok remain individually untested; the report does not certify every
Instagram posting mode. The iPhone social-draft destination was not named,
and its permission-denial/recovery path remains separately unconfirmed.

These results validate local integration, not every social destination or a
release candidate. A subsequent documentation-only commit records this report;
the tested source tree is the exact HEAD stated above.
