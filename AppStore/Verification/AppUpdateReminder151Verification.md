# App Update Reminder 1.5.1 (11) Verification

## Candidate binding and scope

- Reviewed source parent: `2b8ae35397adee698c19cf5a1abf5ca24f7e4316`
- Branch: `release/knitnote-1.5.1-build11`
- Version/build: `1.5.1 (11)`
- Verification time: `2026-08-15 01:23:40 CST (+0800, Asia/Taipei)`
- Checked-in generated project SHA-256: `e05958d47dec14f861cddfd5b5705ee09e7139a913c08cc524d9192540213300`
- Worktree was clean and `git diff --check` had no output before this record was created.

This record binds the feature verification to the reviewed parent above. The
containing verification-only commit is intentionally reported by Git rather
than embedded in its own contents.

## Static and automated gates

- [x] `bash AppStore/Verification/release_audit.sh --static-only` exited `0`
  and printed `METADATA CHECK: PASS`, `COMMERCIAL RELEASE CHECK: PASS
  (offline)`, and `STATIC RELEASE AUDIT: PASS`.
- [x] One retained, complete `swift test --disable-sandbox` process exited
  `0`: **1,581 tests in 134 suites passed** after `309.754s`.
- [x] Full-suite log:
  `/tmp/KnitNoteAppUpdateReminder151-full-swift-test.log`, 3,949 lines,
  346,371 bytes, SHA-256
  `f7e2a0d0e71147d259c2bf278ca22f1d01444021374715dd79a378588c1acafd`.
- [ ] **PENDING — focused retained log hash.** Task 5 reports the reviewed
  focused result as 156 tests in 11 suites, but Task 6 did not duplicate that
  run and no retained Task 5 focused log was available to hash.

The first sandboxed full-suite attempt did not compile the package manifest or
run any tests because SwiftPM was denied write access to
`~/.cache/clang/ModuleCache`. It exited `1`. The one valid retained process was
then run outside that execution sandbox; no successful full-suite run was
duplicated or inferred.

## Reused Debug products and identity

Task 5 produced the following serial unsigned Debug builds with exit `0` and
`** BUILD SUCCEEDED **`:

- iOS Simulator:
  `/tmp/KnitNoteUpdateReminder-iOS/Build/Products/Debug-iphonesimulator/KnitNote.app`
- macOS:
  `/tmp/KnitNoteUpdateReminder-macOS/Build/Products/Debug/KnitNote.app`

The last product-source build was at `e724d40f385ee31b154bba4cfec86a6c685ea197`.
The only paths changed from that commit through the reviewed parent were
`AppStore/Verification/release_audit.sh` and
`Tests/KnitNoteCoreTests/ReleaseConfigurationContractTests.swift`; no product
source, project membership, or generated project bytes changed. These products
are therefore source-equivalent compile/package evidence for the reviewed
parent, but their processed `KnitNoteSourceRevision` is `UNSET`; they are not
archive or signed exact-revision evidence.

Inspected packaged identities were:

| Product | Identifier | Version/build |
| --- | --- | --- |
| iOS Simulator main | `com.phillon.KnitNote` | `1.5.1 (11)` |
| embedded Watch | `com.phillon.KnitNote.watch` | `1.5.1 (11)` |
| embedded Share | `com.phillon.KnitNote.share` | `1.5.1 (11)` |
| macOS main | `com.phillon.KnitNote` | `1.5.1 (11)` |

Main executable SHA-256 values:

- iOS Simulator: `e4bb4a682f6a06e16714504b4b03b4bfa0c2766f40e180c31584c17143226448`
- macOS: `7ec53fbb8750dbdd20b36cf74b69ef3d16a9933ffdab3b38b6bafa7d442bd1d8`

## Deterministic simulator fixture

The unsigned Debug product was installed without erase/uninstall on:

- iPhone 17 Pro Max simulator, iOS 26.5, UDID
  `15AE99B6-14AF-4BCE-BBD9-0007899F5590`
- iPad Pro 13-inch (M5) simulator, iPadOS 26.5, UDID
  `1DBA6547-F560-4268-8CF6-46306DA8EA07`

All launches used only the supported strict DEBUG arguments
`-appUpdateFixture YES -appUpdateFixtureVersion <version>`.

- [x] iPhone `9.9.9` visibly showed the zh-Hant title and message, current
  `1.5.1`, latest `9.9.9`, `稍後`, and `前往 App Store`.
- [x] iPad `9.9.9` visibly showed the same exact localized content.
- [x] Simulator-only defaults were set to the canonical dismissal
  (`updateReminder.dismissedVersion = 9.9.9` and a current
  `updateReminder.dismissedAt`); relaunching `9.9.9` on both devices visibly
  showed no update alert.
- [x] With that `9.9.9` dismissal still present, launching `10.0.0` on both
  devices visibly restored the alert with latest version exactly `10.0.0`.
- [x] iPhone launches with supported `languageSelection` defaults visibly
  showed correct zh-Hant, English, and Japanese title/message/actions while
  keeping version strings exact.
- [ ] **PENDING — change language while the same alert remains visible.** No
  supported runnable UI fixture exposes this interaction. Full-suite contract
  coverage verifies locale-aware rendering, but is not a manual live-switch
  observation.
- [ ] **PENDING — App Store navigation.** Button presence was observed; the
  button was not activated, so navigation is not claimed.

The `Later` action wiring, canonical persistence, seven-day policy, higher
version bypass, store completion behavior, cancellation, locale injection, and
active-scene gate are covered by the passing full suite. Direct simulator
defaults were used for policy smoke because no UI tap driver was available;
this record does not claim a literal tap on `Later`.

## Presentation priority

- [ ] **PENDING — inbox failure clears before update appears.**
- [ ] **PENDING — backup reminder/settings clears before update appears.**
- [ ] **PENDING — unlock sheet clears before update appears.**
- [ ] **PENDING — pending pattern selection clears before update appears.**

No deterministic runnable fixture for these higher-priority presentations is
defined by the task. No unapproved flags were invented. The passing
`AppUpdateReminderViewContractTests` mutation contract independently requires
the inbox failure, backup reminder, backup settings, unlock sheet, and pending
selection blockers plus the active-scene guard; that automated evidence is not
represented as manual/UI PASS.

## Mac Debug fixture

The macOS Debug executable was launched with the same fixture arguments using
isolated `HOME` and `CFFIXED_USER_HOME` values under
`/tmp/KnitNoteAppUpdateMacFixtureHome`, avoiding the user's normal KnitNote data.
The process remained alive, but the system screenshot was entirely black and
Computer Use could not obtain reliable app state. The isolated process was
then terminated (retained exec session `43725`, exit `130`).

- [ ] **PENDING — visible Mac alert/copy/layout.** No reliable visual evidence.
- [ ] **PENDING — Mac keyboard focus and button activation.** Not observed.
- [ ] **PENDING — Mac App Store navigation.** Not activated.
- [ ] **PENDING — Mac existing-data preservation.** Personal data was isolated
  rather than opened, so unchanged personal data is not inferred.

## Physical discovery and smoke

Read-only discovery on 2026-08-15 found:

- iPhone 17 Pro Max, iOS 26.6 (`23G71`), available over USB;
- iPad Air (5th generation), iPadOS 26.5.2 (`23F84`), unavailable with Xcode's
  unlock/attachment recovery suggestion;
- Apple Watch Ultra 2, watchOS 26.6 (`23U67`), available/paired (not in the
  update-reminder UI scope).

- [ ] **PENDING — signed exact-parent physical build.** The inspected products
  are unsigned simulator/macOS products and embed `UNSET`, not an exact signed
  device product.
- [ ] **PENDING — iPhone overlay install and fixture smoke.** Discovery only;
  no install, launch, erase, or uninstall occurred.
- [ ] **PENDING — iPad overlay install and fixture smoke.** Device unavailable;
  no install, launch, erase, or uninstall occurred.
- [ ] **PENDING — physical data preservation for projects, patterns, yarn,
  folders, notes, and settings.** No physical overlay was performed.

## Non-actions and acceptance boundary

No archive, export, upload, App Store Connect build selection, submission,
publication, release, merge, or push occurred. No physical device was erased or
uninstalled. This record accepts only the checked automated and simulator
observations above; every unavailable or unobserved action remains explicitly
PENDING.
