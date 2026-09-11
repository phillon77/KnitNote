# KnitNote Journal Social Sharing Verification

Date: 2026-09-11
Candidate: `1.6.1` / Build `13`
Final verification SHA: `885799e0f862b7c8cfd95b97537efbfb4e04dcdd`

Scope: local automated and iOS Simulator verification only. This report does
not authorize or claim a signed archive, physical-device acceptance, upload,
App Store Connect edit, submission, or release.

The final SHA includes the localization-contract correction and the reviewed
selected-state accessibility trait for the reflowed format buttons. Earlier
Xcode/native results under `/private/tmp/knitnote-journal-share-task7` predate
that production change and are superseded by the final-source results below.

## Automated verification

### Repository integrity

- `git diff --check` completed with no output before candidate verification.
- `git status --short` was clean after the test-preparation commit and before
  the candidate SHA was recorded.

### Full Core suite

Command:

```text
swift test --no-parallel
```

The first full run began at 2026-09-11T14:29:57Z and completed after 2589.676
seconds with 2950 tests in 215 suites and four issues. The only failing source
tests were
`mainAppCatalogIsCompleteForVersion150Languages`,
`infoPlistCatalogIsCompleteForVersion150Languages`, and
`journalSourceCatalogAndContractKeysStayInLockstep` (two expectations). The
new journal-sharing keys and Photos purpose key had not been added to the
frozen localization oracles/source inventory. Durable RED log:
`/private/tmp/knitnote-journal-share-task7/logs/swift-test-no-parallel.log`.

The narrow test-contract correction is commit `4845c0a`. Each exact regression
then passed independently:

```text
swift test --filter mainAppCatalogIsCompleteForVersion150Languages
swift test --filter infoPlistCatalogIsCompleteForVersion150Languages
swift test --filter journalSourceCatalogAndContractKeysStayInLockstep
```

Intermediate corrected full serial run: **INTERRUPTED — NOT A PASS**. It began at
2026-09-11T15:16:09Z and was intentionally stopped with SIGINT/exit 130 during
`staticAuditRejectsLexicallyDuplicateRelevantBuildSettings` after final review
requested a production accessibility correction. Durable partial log:
`/private/tmp/knitnote-journal-share-task7/logs/swift-test-no-parallel-corrected.log`.
A fresh full run began on exact final SHA `885799e0` at
2026-09-11T15:27:46Z. Durable final log:
`/private/tmp/knitnote-journal-share-task7/logs/swift-test-no-parallel-final-885799e.log`.
It completed at 2026-09-11T16:10:31Z with exit 0: **2950 tests in 215 suites
passed after 2544.407 seconds, zero issues**.

The Core suite retains exact composed-text coverage in `JournalShareModelTests`,
including user text and optional `#KnitNote` content.

### macOS-hosted app test bundle

Command completed on final SHA `885799e0` from 2026-09-11T15:36:21Z through
2026-09-11T15:42:21Z with result Passed: 510 distinct tests passed, two
skipped, zero failed (683 parameterized passed device records).

```text
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /private/tmp/knitnote-journal-share-derived -resultBundlePath /private/tmp/knitnote-journal-share-task7/results/macos-app-tests-final-885799e.xcresult CODE_SIGNING_ALLOWED=NO -only-testing:KnitNoteAppTests
```

Skipped tests:

- `AppBootstrapTransitionIntegrationTests/builtChildExitRecoversBeforeOrdinaryJournalAndDoesNotBootstrapTwice(cut:)` — xcresult reports only `Test skipped`; no more specific reason was recorded.
- `CloudKitDevelopmentIntegrationTests/createsFetchesUpdatesAndDeletesUniqueDevelopmentZone()` — `NOT RUN unless explicitly opted into an available Development container`.

### Generic builds

Both commands exited 0 against the unchanged production tree:

```text
xcodebuild build -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/knitnote-journal-share-derived CODE_SIGNING_ALLOWED=NO
xcodebuild build -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/knitnote-journal-share-derived CODE_SIGNING_ALLOWED=NO
```

Durable final-source results are
`/private/tmp/knitnote-journal-share-final-fix/results/frozen-885799e-generic-ios-simulator-build.xcresult`
and
`/private/tmp/knitnote-journal-share-final-fix/results/frozen-885799e-generic-ios-device-build.xcresult`;
matching logs are under
`/private/tmp/knitnote-journal-share-final-fix/logs/`.
These unsigned builds are compilation evidence, not signed-device or
distribution evidence.

### Card output contracts

Automated model and renderer tests verify decodable sRGB JPEG output at the
exact dimensions below for both formats:

| Format | Dimensions |
| --- | --- |
| Post 4:5 | 1080 x 1350 JPG |
| Story 9:16 | 1080 x 1920 JPG |

Renderer tests also cover metadata visibility combinations, long captions, and
photo-only safe areas. Model tests cover export ownership/cleanup, Save state,
cancellation, and exact composed text with hashtag inclusion and omission.

## Native iOS Simulator matrix

Both device names, identifiers, and runtime were read from
`xcrun simctl list devices available`; no destination was invented. Normal
shards ran at the devices' existing `large` content size. Accessibility shards
used the supported command below after capturing the prior value, and both
devices were restored to `large` afterward:

```text
xcrun simctl ui <device-id> content_size accessibility-extra-extra-extra-large
```

| Destination | UTC interval | Shard | Result | Durable result |
| --- | --- | --- | --- | --- |
| iPhone 17 Pro, iOS 26.5, `CCC0104E-86BA-4FB7-BDD9-CD2608F90F58` | 15:27:52–15:29:29 | English normal | PASS, 3/3 | `/private/tmp/knitnote-journal-share-final-fix/results/frozen-885799e-iphone-normal-3cases.xcresult` |
| iPhone 17 Pro, iOS 26.5, `CCC0104E-86BA-4FB7-BDD9-CD2608F90F58` | 15:29:51–15:30:21 | zh-Hant accessibility XXXL | PASS, 1/1 | `/private/tmp/knitnote-journal-share-final-fix/results/frozen-885799e-iphone-accessibility-1case.xcresult` |
| iPad Pro 13-inch (M5), iOS 26.5, `1DBA6547-F560-4268-8CF6-46306DA8EA07` | 15:30:54–15:32:39 | English normal | PASS, 3/3 | `/private/tmp/knitnote-journal-share-final-fix/results/frozen-885799e-ipad-normal-3cases.xcresult` |
| iPad Pro 13-inch (M5), iOS 26.5, `1DBA6547-F560-4268-8CF6-46306DA8EA07` | 15:32:57–15:33:26 | zh-Hant accessibility XXXL | PASS, 1/1 | `/private/tmp/knitnote-journal-share-final-fix/results/frozen-885799e-ipad-accessibility-1case.xcresult` |

The normal shard exercises completed-project journal sharing/read-only state,
both ratios, all four metadata switches, edited text, hashtag, Copy feedback,
Save reachability, and real activity-sheet cancellation. The activity
`ActivityListView` disappeared after interactive dismissal and Share became
enabled again. The accessibility shard proves zh-Hant localization and
vertical reflow of the ratio controls. Fixture project/caption text remains
English by design across app locales.

Retained candidate screenshots:

- iPhone normal:
  `/private/tmp/knitnote-journal-share-task7/attachments/final-885799e-iphone-normal/070F99DC-9653-4015-B49C-763E236D4F0A.png`
- iPhone zh-Hant accessibility XXXL:
  `/private/tmp/knitnote-journal-share-task7/attachments/final-885799e-iphone-accessibility/BEAD8B1D-A6B4-4CB9-BE7C-60C232CD60AF.png`
- iPad normal:
  `/private/tmp/knitnote-journal-share-task7/attachments/final-885799e-ipad-normal/1A2E84C8-B287-4D63-A9C0-DEC1D9F95C0F.png`
- iPad zh-Hant accessibility XXXL:
  `/private/tmp/knitnote-journal-share-task7/attachments/final-885799e-ipad-accessibility/6D66A7B6-889C-4726-B43A-C571F220035A.png`

Visual inspection found the normal iPhone card metadata fit. Both final
accessibility screenshots are scrolled to the actual vertical ratio controls:
Post shows a selected checkmark, Story shows an unselected circle, labels are
legible or wrap as needed, and the metadata toggles are visible. On iPad the
sheet/title did not clip horizontally, but the normal initial viewport shows
only the photo/top of the tall card; it does not prove the entire card is
visible without scrolling. Lower controls are verified as reachable scroll
content, not as simultaneously visible in the initial screenshot. Simulator
coverage does not claim a source-mutation check. Coordinator tests cover
immutable source-entry input, while the native completed-project case verifies
that Edit and Delete are absent and Share remains available.

At accessibility sizes, the selected Post/Story format is also exposed through
the native selected accessibility trait. The final focused regression passed
1/1, and both final device-family accessibility shards assert the initial and
changed selected state.

## Review outcome and deferred non-blockers

Whole-branch review found no Critical issues and one Important accessibility
issue: accessibility-size format buttons did not expose their current selected
state. Commit `885799e0` addressed it with a conditional native `.isSelected`
trait and UI assertions that move selection Post -> Story -> Post. Scoped
re-review found the issue addressed, the spec whitespace gate addressed, and no
new Critical or Important breakage.

The following observations were explicitly triaged as non-blocking follow-up,
not silently counted as completed:

- superseded preview loads may continue detached file I/O; stale publication
  is already rejected, so cancellation/caching is deferred performance work;
- the tall iPad preview may require scrolling before controls; controls remain
  reachable, and viewport-relative preview sizing is optional polish;
- a nonpositive cleanup-cap test is deferred because production always passes
  50 and the guard is direct;
- live clipboard UI inspection is deferred; Core model tests retain exact
  full-text and hashtag composition coverage, while native UI verifies Copy
  reachability and feedback.

## Physical-device acceptance — not performed

All items below remain release gates for the exact later release candidate:

- [ ] iPhone: Photos add authorization granted; saved Post and Story dimensions/content verified in Photos.
- [ ] iPhone: Photos access denied; localized recovery and Settings route verified.
- [ ] iPad: Photos add authorization granted; saved Post and Story dimensions/content verified in Photos.
- [ ] iPad: Photos access denied; localized recovery and Settings route verified.
- [ ] Instagram receives the owned JPG and composed text as expected.
- [ ] TikTok receives the owned JPG and composed text as expected.
- [ ] Long Traditional Chinese caption and post text remain legible and complete.
- [ ] One other non-Latin locale is inspected on device.
- [ ] System activity cancellation returns to a ready preview on physical iPhone and iPad.
- [ ] Temporary export cleanup is confirmed after share completion, cancellation, and preview dismissal.

Physical acceptance must be performed later against one exact immutable release
candidate. Nothing in this report marks those checks complete.
