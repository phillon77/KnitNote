# App Update Reminder 1.5.1 (11) Verification

## Candidate binding and scope

- Reviewed source parent: `3c83e8192b6e3300c44905533c02331c90d30432`
- Final-review starting point: `006718e9e880890315ea3e258fb5fee87786a126`
- Branch: `release/knitnote-1.5.1-build11`
- Version/build: `1.5.1 (11)`
- Verification time: `2026-08-15 02:12:16 CST (+0800, Asia/Taipei)`
- Checked-in generated project SHA-256:
  `e05958d47dec14f861cddfd5b5705ee09e7139a913c08cc524d9192540213300`
- App Store lookup sentinel SHA-256:
  `e98d217256ad5a1b15ee64d61f44b75c9f6c981b50088ca2fe7f199382ed21c4`
- App Store live factory SHA-256 remained:
  `dcae917c3d5f301e6d79ea3901b4c8a55f37277a55d76efc8d0bc656ad255bb7`
- The worktree was clean and `git diff --check` had no output before this
  evidence record was edited.

This record binds final-review verification to the source/test commit above.
The containing verification-only commit is intentionally reported by Git
rather than embedded in its own contents.

## Final-review fixes and automated gates

- [x] Presentation arbitration now has one state decision covering every
  RootView/app-level blocking owner: store load error, create-project sheet,
  backup reminder, backup settings/restore confirmation, inbox
  failure/destructive discard, inbox selection, and unlock/paywall sheet.
- [x] Owner-scoped source mutation contracts include decoys outside the owner
  block. Pure behavior tests verify each of the seven owners defers the update,
  no-owner presentation, no-pending behavior, and retention of a pending update
  while a blocker is active.
- [x] Store URLs must retain the real Apple localized shape
  `https://apps.apple.com/<country>/app/<localized-slug>/id6793023054?<query>`.
  Tests reject a wrong product identifier, wrong route/path, user info,
  explicit port `443`, and explicit nondefault port `444`.
- [x] TDD RED was observed before implementation: the five new invalid Store
  URL fixtures were accepted; presentation tests did not compile because
  `AppUpdatePresentationState` did not exist; and the real audit rejected the
  old sentinel pin with exactly two reported issues.
- [x] Targeted presentation/lookup/audit command exited `0`: **28 tests in 5
  suites passed**.
- [x] Complete `ReleaseConfigurationContractTests` command exited `0`: **36
  tests in 1 suite passed**.
- [x] Update-focused command exited `0`: **162 tests in 12 suites passed**.
- [x] `bash AppStore/Verification/release_audit.sh --static-only` exited `0`
  and printed `METADATA CHECK: PASS`, `COMMERCIAL RELEASE CHECK: PASS
  (offline)`, and `STATIC RELEASE AUDIT: PASS`.
- [x] Exactly one retained complete `swift test --disable-sandbox` process
  exited `0`: **1,587 tests in 135 suites passed after 326.105s**.
- [x] Full-suite log:
  `/tmp/KnitNoteAppUpdateReminder151-final-fix-3c83e81-full-swift-test.log`,
  3,981 lines, 350,363 bytes, SHA-256
  `dfadda0af1b92ae1e453f15c0bb678f1c543c92928d0e434e8d9f2910628ee67`.

The focused commands were observed directly but were not retained as separate
log artifacts, so no focused-log hash is claimed. The full-suite count includes
the same focused coverage and the real `ReleaseAuditLocalizationTests` suite;
no second full process was run.

No source membership, `project.yml`, or checked-in generated project bytes
changed, so `xcodegen` was intentionally not run.

## Fresh serial builds and packaged identity

Fresh builds were run after source commit `3c83e819` in separate DerivedData
directories. All reported `** BUILD SUCCEEDED **` with exit `0`:

| Build | Product | Log evidence |
| --- | --- | --- |
| iOS Simulator, compile/package (`CODE_SIGNING_ALLOWED=NO`) | `/tmp/KnitNoteUpdateReminderFinalFix-3c83e81-iOS-outside/Build/Products/Debug-iphonesimulator/KnitNote.app` | 4,972 lines, 757,219 bytes, SHA-256 `53b41f0bcf39f22355faaecbfb355ea100274a9ddb91f752ed171e693fabba04` |
| macOS, compile/package (`CODE_SIGNING_ALLOWED=NO`) | `/tmp/KnitNoteUpdateReminderFinalFix-3c83e81-macOS-outside/Build/Products/Debug/KnitNote.app` | 1,528 lines, 217,678 bytes, SHA-256 `97aa0c46f29ca08bd7e0c323f9a7ecf2babbe442c8b394d07c278af3dbe0c0ab` |
| iOS Simulator, `Sign to Run Locally` smoke product | `/tmp/KnitNoteUpdateReminderFinalFix-3c83e81-iOS-signed-smoke/Build/Products/Debug-iphonesimulator/KnitNote.app` | 5,107 lines, 788,834 bytes, SHA-256 `9474c967e5b44d16789c422ebcebe1840f0d9e004455e6686b679a8b6f655f76` |

Inspected packaged identities were:

| Product | Identifier | Version/build |
| --- | --- | --- |
| iOS Simulator main | `com.phillon.KnitNote` | `1.5.1 (11)` |
| embedded Watch | `com.phillon.KnitNote.watch` | `1.5.1 (11)` |
| embedded Share | `com.phillon.KnitNote.share` | `1.5.1 (11)` |
| macOS main | `com.phillon.KnitNote` | `1.5.1 (11)` |

The source-bearing Debug dylib SHA-256 values were:

- unsigned iOS Simulator: `a04cd1fdf288f8cbe79df9857728b45859827bb8058f67e402c7de8805dc24ec`
- `Sign to Run Locally` iOS Simulator: `4ab30d496f9908138fd1bd4954d7280ffe187c9e17e37738b53ca3a2b80bbecb`
- macOS: `d9285f1f022ea3743f411fd6f80207aca1d086cfdc00c9f180f53338a3a7e08a`

These Debug products still process `KnitNoteSourceRevision` as `UNSET`; they
are fresh compile/package and simulator smoke evidence, not signed archive or
exact-revision distribution evidence.

## Fresh deterministic simulator smoke

All launches used only the supported strict DEBUG arguments
`-appUpdateFixture YES -appUpdateFixtureVersion 10.0.1`.

- [x] A previously unused iPhone 17e simulator, iOS 26.5, UDID
  `B26E2337-863F-4647-A31F-219A5457DE55`, ran the fresh `Sign to Run Locally`
  product and visibly showed the zh-Hant title/message, current `1.5.1`, latest
  `10.0.1`, `稍後`, and `前往 App Store`.
  Screenshot: `/tmp/KnitNoteUpdateReminderFinalFix-3c83e81-signed-iPhone-10.0.1.png`,
  1170 x 2532, SHA-256
  `05d3aaa54c60c32762c193186ae2780efb41891c8ab8f29d820fdb280d5e6358`.
- [x] On the existing iPad Pro 13-inch (M5) simulator, iPadOS 26.5, UDID
  `1DBA6547-F560-4268-8CF6-46306DA8EA07`, the fresh signed product visibly
  kept an inbox failure/destructive confirmation above the load-error surface;
  the pending `10.0.1` update did not overtake either blocker.
  Screenshot: `/tmp/KnitNoteUpdateReminderFinalFix-3c83e81-signed-iPad-10.0.1.png`,
  2064 x 2752, SHA-256
  `263621be08d51a6995e7931f2d18f334a8a7dfea19d233f92f3e5bcedf124433`.
- [ ] **PENDING — iPad alert with all blockers cleared at the reviewed source.**
  The fresh iPad observation covered arbitration, not the unobstructed alert.
- [ ] **PENDING — same-version seven-day suppression and higher-version bypass
  at the reviewed source.** The prior `006718e` simulator observations are
  historical only and are not carried forward as PASS after production-source
  changes.
- [ ] **PENDING — live locale changes while the same alert remains visible.**
  Full-suite contracts cover locale-aware rendering; no current-source live
  switch was observed.
- [ ] **PENDING — App Store navigation.** Button presence was observed on the
  iPhone, but it was not activated.

The first smoke attempt used the unsigned compile/package product and displayed
the blocking load-error surface rather than an update alert. A read-only
Simulator log identified `group.com.phillon.KnitNote ... client is not
entitled`; the `Sign to Run Locally` product was therefore built and used for
valid alert smoke. No physical device data was involved or cleared.

## Presentation priority boundary

- [x] Fresh iPad smoke observed inbox failure/destructive confirmation and
  load error taking priority over a fixture-provided pending update.
- [ ] **PENDING — clear the observed iPad blockers and visually observe the
  retained update appear.** Automated coordinator behavior verifies retention,
  but the full UI transition was not performed.
- [ ] **PENDING — create-project sheet and unlock/paywall visual ordering.**
- [ ] **PENDING — backup reminder/settings and restore confirmation visual
  ordering.**
- [ ] **PENDING — pending pattern selection visual ordering.**

The automated state and owner-scoped mutation suites cover every listed owner;
the PENDING entries above deliberately remain manual/UI acceptance boundaries.

## Mac Debug fixture

- [ ] **PENDING — visible Mac alert/copy/layout.** No fresh reliable visual
  evidence was obtained after the source change.
- [ ] **PENDING — Mac keyboard focus and button activation.** Not observed.
- [ ] **PENDING — Mac App Store navigation.** Not activated.
- [ ] **PENDING — Mac existing-data preservation.** Not observed.

## Physical and live-service boundaries

- [ ] **PENDING — signed exact-parent physical iPhone/iPad build.** The
  inspected Debug products embed `UNSET`; no physical install or launch was
  performed.
- [ ] **PENDING — physical overlay/data preservation for projects, patterns,
  yarn, folders, notes, and settings.** No physical device was erased,
  uninstalled, or mutated.
- [ ] **PENDING — live App Store lookup/localized `trackViewUrl` observation.**
  URL shape and identity are automated contract evidence only.
- [ ] **PENDING — live App Store navigation.** No Store button was activated.
- [ ] **PENDING — live locale switching on iPhone, iPad, and Mac.**

## Non-actions and acceptance boundary

No archive, export, upload, App Store Connect build selection, submission,
publication, release, merge, or push occurred. This record accepts only the
checked automated/build evidence, the fresh iPhone alert observation, and the
fresh iPad blocker-ordering observation above; every unavailable or unobserved
action remains explicitly PENDING.
