# KnitNote 1.4.1 localization verification record

## Release decision

**STOP — the source candidate is `1.4.1 (8)`, but release acceptance is incomplete.**

Automated tests and static release checks cover the repository state containing this record. Four unsigned Release builds were created after the final-fixes commit and six standalone/embedded products were inspected against that exact containing commit. This is exact-source compile and package evidence only; it does not establish signed-archive, physical-device, native-language, visual, accessibility, data-neutrality, commercial, or App Store Connect acceptance.

No archive, distribution signing, upload, submission, merge, push, price change, IAP change, or App Store Connect modification was performed. A later Task 4 iPhone Debug build used development signing solely for the recorded physical acceptance.

## 2026-08-08 final entitlement-neutral resume candidate

The final-review source fix is `9adc8fe` (`fix: keep completed-project deletion entitlement-neutral`). The exact candidate is the commit containing this evidence record, resolved at handoff with `git rev-parse HEAD`; this record does not embed its own changing commit identifier. The source change makes only `.resumeProject` join `.deleteProject` as an entitlement-neutral capability. The store still rejects direct deletion while a project is completed, and every unrelated editing capability retains its prior trial or unlock decision.

| Check | Result | Exact evidence |
| --- | --- | --- |
| Witnessed focused RED | EXPECTED FAIL | Before the source change, `swift test --filter 'trialNotStartedCanResumeCompletedProjectOnlyForDeletionWithoutStartingTrial\|expiredTrialCanResumeCompletedProjectOnlyForDeletionWithoutRequestingUnlock'` ran 2 tests and failed with 2 issues: both resume calls threw `ProjectStoreError.accessRestricted`. The trial-not-started path reached the trial-commit gate; the expired path was rejected by policy. |
| Focused GREEN and entitlement regression | PASS | `swift test --filter 'JSONProjectStoreTests\|FeatureAccessPolicyTests\|JSONProjectStoreEntitlementTests'` exited 0: 114 tests in 1 suite passed. Both snapshots prove direct completed-project deletion is rejected; resume returns `.allow` without committing trial start or requesting unlock; `.editProject` remains gated; resume then deletion persists. |
| Full Swift package suite | PASS | `swift test --quiet` exited 0: 1,348 tests in 122 suites passed after 126.683 seconds (the legacy XCTest suite separately reported 0 tests / 0 failures). |
| Focused macOS app-hosted deletion tests | PASS | The deterministic three-function selector command exited 0 with host test-runner access. `/tmp/KnitNoteCompletedDeletionFinalFixTests/Logs/Test/Test-KnitNote-2026.08.08_07-06-12-+0800.xcresult` reports 3 passed, 0 failed, 0 skipped, `result: Passed`. The initial restricted-sandbox run exited 65 because `testmanagerd.control` was blocked and is not counted as test evidence. |
| Unsigned Debug iOS Simulator build | PASS | `xcodebuild ... -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteCompletedDeletionFinalFix-iOS CODE_SIGNING_ALLOWED=NO build -quiet` exited 0. |
| Unsigned Debug macOS build | PASS | `xcodebuild ... -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteCompletedDeletionFinalFix-macOS CODE_SIGNING_ALLOWED=NO build -quiet` exited 0. |
| Metadata validator | PASS | `python3 AppStore/Verification/metadata_check.py AppStore/Metadata` emitted `METADATA CHECK: PASS`. |
| Static release audit | PASS | `bash AppStore/Verification/release_audit.sh --static-only` emitted `METADATA CHECK: PASS`, `COMMERCIAL RELEASE CHECK: PASS (offline)`, and `STATIC RELEASE AUDIT: PASS`. |

### New-candidate physical acceptance — PENDING

The prior `efb801e86e9a3c196603548be9aca8c0b957c2c0` iPhone PASS below is historical evidence only. It does not accept the new entitlement-policy candidate. After the exact containing commit is overlay-installed without uninstalling or erasing data, the user must repeat the disposable-project in-progress deletion, completed-project rejection, resume-without-unlock-or-trial-start, resumed deletion, relaunch persistence, Traditional-Chinese VoiceOver, and non-disposable-project preservation checks. Until the user supplies those results, the new candidate decision is **PENDING** and the release decision remains **STOP**.

## Historical 2026-08-08 Task 4: completed-project deletion protection evidence

This section is historical evidence for the working-tree source at `efb801e86e9a3c196603548be9aca8c0b957c2c0` on branch `docs/knitnote-1.4-localization`. It does not apply to the final entitlement-neutral resume candidate, replace the broader historical evidence below, or relax any release gate.

| Check | Result | Exact evidence |
| --- | --- | --- |
| Full Swift package suite | PASS | `swift test --quiet` exited 0: `1,345 tests in 122 suites passed after 118.912 seconds` (the legacy XCTest suite reported 0 tests / 0 failures separately). |
| Brief-specified focused Xcode command | INCONCLUSIVE | The first sandboxed attempt exited 65 because `testmanagerd.control` was blocked by a sandbox restriction. The exact same command was then rerun with the required host service access and exited 0, but its `.xcresult` reports `totalTestCount: 0`, `result: unknown`; therefore this selector is not treated as evidence that a test executed. |
| Supplementary `KnitNoteAppTests` target | PASS | `xcodebuild test … -only-testing:KnitNoteAppTests …` exited 0. Its `.xcresult` reports `totalTestCount: 56`, `passedTests: 56`, `failedTests: 0`, `result: Passed` (the per-configuration dynamic-parameter aggregate reports 59 passed executions). It includes the three deletion tests: `completedProjectRequiresResumeBeforeEditorDeletion()`, `inProgressProjectAllowsEditorDeletion()`, and `projectEditorDeletionRemovesTheProjectBeforeLeavingTheEditor()`. |
| Unsigned Debug iOS Simulator build | PASS | Brief command exited 0 with `CODE_SIGNING_ALLOWED=NO`, derived data `/tmp/KnitNoteCompletedDeletion-iOS`. |
| Unsigned Debug macOS build | PASS | Brief command exited 0 with `CODE_SIGNING_ALLOWED=NO`, derived data `/tmp/KnitNoteCompletedDeletion-macOS`. |
| Metadata validator | PASS | `METADATA CHECK: PASS`. |
| Static release audit | PASS | `METADATA CHECK: PASS`; `COMMERCIAL RELEASE CHECK: PASS (offline)`; `STATIC RELEASE AUDIT: PASS`. |
| Whitespace check | PASS | `git diff --check` exited 0 with no output before this record was edited. |

The focused selector discrepancy is a test-command concern, not a passing result: `EditProjectDeletionActionTests.swift` contains top-level Swift Testing tests, while the brief's selector is `-only-testing:KnitNoteAppTests/EditProjectDeletionActionTests`. The successful broader target run is recorded as supplementary evidence rather than silently substituting for the requested command.

#### Deterministic top-level Swift Testing selector resolution

The valid selectors come directly from the successful `.xcresult` test identifiers, which are `KnitNoteAppTests/<top-level test function>()`, not `KnitNoteAppTests/<source filename>`. This command exited 0:

```bash
xcodebuild test -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteCompletedDeletionTestsTopLevel -only-testing:'KnitNoteAppTests/completedProjectRequiresResumeBeforeEditorDeletion()' -only-testing:'KnitNoteAppTests/inProgressProjectAllowsEditorDeletion()' -only-testing:'KnitNoteAppTests/projectEditorDeletionRemovesTheProjectBeforeLeavingTheEditor()' CODE_SIGNING_ALLOWED=NO -quiet
```

`/tmp/KnitNoteCompletedDeletionTestsTopLevel/Logs/Test/Test-KnitNote-2026.08.08_06-26-55-+0800.xcresult` reports `totalTestCount: 3`, `passedTests: 3`, `failedTests: 0`, `skippedTests: 0`, and `result: Passed`. Its only test nodes are the three named deletion tests. This resolves the zero-test concern without changing source: the brief's file-style selector is invalid for top-level Swift Testing functions, while the explicit function selectors are deterministic and focused.

### Exact iPhone Debug install boundary

| Field | Recorded value |
| --- | --- |
| Build source | `efb801e86e9a3c196603548be9aca8c0b957c2c0` |
| Candidate | Debug `com.phillon.KnitNote`, `1.4.1 (8)` |
| Device | `iPhone` — iPhone 17 Pro Max (`iPhone18,2`), physical, paired and booted |
| Device identifier | `30C68657-A038-5548-A1C6-F9280C02D5FB` (UDID `00008150-00042D6A3612401C`) |
| OS | iOS 26.6 (build `23G71`) |
| Pre-install state | Existing developer app `com.phillon.KnitNote` `1.4.1 (8)` was present. |
| Build result | Device-destination Debug build exited 0 at `/tmp/KnitNoteCompletedDeletion-iPhone/Build/Products/Debug-iphoneos/KnitNote.app`; signing identity was Apple Development, Team ID `9CFPAUL5N5`. This is a development build, not a signed distribution archive. |
| Install result | `xcrun devicectl device install app` exited 0 over the existing bundle. No uninstall or data erase command was used. Installed path: `/private/var/containers/Bundle/Application/998EE0EA-3518-43F2-80A4-530B7C8BD7BE/KnitNote.app`. |
| Launch result | `xcrun devicectl device process launch … com.phillon.KnitNote` exited 0. |
| App interface locale | English (`en`) during the user physical acceptance. This is user-provided evidence; the device query itself did not return a locale. |
| VoiceOver language result | Separately, the user reported that Traditional-Chinese VoiceOver announced the disabled Delete control and its guidance. This does **not** establish `zh-Hant` app-interface acceptance. |

The install and launch prove only that the exact Debug candidate could replace the existing same-bundle development installation and start. They do not prove preservation of user data, UI state, tactile behavior, VoiceOver output, or any release condition.

### User physical iPhone acceptance — PASS (2026-08-08)

The user reported the following sequential PASS results on the already-recorded physical iPhone 17 Pro Max (iOS 26.6), using the exact `efb801e86e9a3c196603548be9aca8c0b957c2c0` Debug candidate `com.phillon.KnitNote` `1.4.1 (8)` with the app interface set to English (`en`). This is user physical acceptance evidence; it does not imply `zh-Hant` app-interface acceptance or acceptance for any other platform, locale, or release gate.

1. **PASS — In-progress project:** editor Delete was enabled; confirmation appeared; deletion succeeded; the app returned to the project list.
2. **PASS — Completed project:** editor Delete was disabled; localized resume guidance was visible; the project remained after leaving and reopening the app.
3. **PASS — Restored project:** after Resume, reopening Edit, and confirming Delete, the project was absent after app relaunch.
4. **PASS — Traditional Chinese VoiceOver:** VoiceOver announced the disabled Delete control and its guidance. This is an accessibility-language result separate from the English app-interface locale.

These tests used disposable projects only. After acceptance, the user confirmed that all existing non-disposable/formal projects remained fully present and unchanged. This is a user physical preservation observation for the stated projects, not a replacement for the broader data-neutrality acceptance below.

## Candidate and environment identity

| Field | Recorded value |
| --- | --- |
| Verification date | 2026-08-07, Asia/Taipei |
| Task 5 starting commit | `ebe2d0cec5c968c4f8457dc70a8b58dba90c70b6` |
| Recorded 1.4.0 source baseline | `ca3014146f2b9156b71b5104f7fea7e5fbd02839` (`1.4.0 (8)`) |
| Exact source candidate | Resolve the immutable candidate at handoff with `git rev-parse HEAD`; bind signed archives through the supported creator and embedded source revision. This record deliberately does not predict its containing commit subject or SHA. |
| Candidate branch | `docs/knitnote-1.4.1-greek-plan` |
| Marketing version | `1.4.1` in every shipping target; historical inspected products also reported `1.4.1` |
| Build number | `8` in every shipping target; historical inspected products also reported `8` |
| Xcode | 26.6 (`17F113`) |
| Swift | Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`) |
| `main` at verification time | `3ff06866923ee1d0952b211079e0e4fdd073867f` |
| `origin/main` at verification time | `3ff06866923ee1d0952b211079e0e4fdd073867f` |

The containing commit is not embedded as its own literal SHA because changing this file would change that SHA. The handoff must pair this record with the containing commit reported by Git.

The baseline above is the latest repository source commit configured as `1.4.0 (8)` immediately before the 1.4.1 localization plan, and `git merge-base --is-ancestor ca3014146f2b9156b71b5104f7fea7e5fbd02839 HEAD` must pass. The older `Localization140Verification.md` record was last changed at `77d0c2ea0e991cb0a5411809b379620fa906f904`; that record itself says STOP and records no signed archive. This is source-lineage evidence only: it does not establish parity with an App Store-selected or released binary, and the contemporaneous `main` value is not the release baseline.

## Exact localization identity

The required locale set is:

```text
en, zh-Hant, zh-Hans, de, fr, ja, nb, sv, fi, da, ko, el
```

`project.yml`, the generated Xcode project, all three source Info.plists, all four String Catalogs, the release audit, and the screenshot manifest/capture tooling use this exact set. Historical inspected products used the same set. `Base.lproj` is ignored only as an optional Interface Builder base-resource directory; any other missing or extra localization is rejected.

## TDD and automated verification

| Check | Result | Evidence |
| --- | --- | --- |
| Focused Task 5 RED | EXPECTED FAIL | 57 tests, 71 issues against the old `1.4.0`/six-locale audit and screenshot contracts |
| Focused Task 5 hardening GREEN | PASS | 54 release/configuration/screenshot tests in 3 suites, zero issues, including real-format UTF-16LE table parsing and strict codesign option coverage |
| Final-fixes focused Swift tests | PASS | 122 tests in 8 suites, zero issues |
| Full Swift suite | PASS | 1,341 tests: 1,027 tests in all 122 named suites plus 314 module-level tests. Coverage used mutually exclusive uppercase suite and lowercase global-test partitions. Broad concurrent invocations stalled in SwiftPM helpers, so no monolithic-pass claim is made. One transient Xcode build-settings read returned missing values; the same 3-test identity suite passed after a clean recompilation, with all four shipping products verified. |
| Python tooling tests | PASS | 22 tests: 20 metadata validator tests and 2 Korean compositor/glyph tests |
| Metadata validator | PASS | `METADATA CHECK: PASS` for all twelve repository locale packages |
| Commercial configuration, offline | PASS | `COMMERCIAL RELEASE CHECK: PASS (offline)` |
| Static release audit | PASS | `STATIC RELEASE AUDIT: PASS` |
| Screenshot manifest-only validation | PASS | 168 definitions: 14 per locale |
| Release storyboard contract | PASS | 72 entries: 6 per locale |
| Real signed archive audit | **NOT RUN** | No signed archives were created or supplied |

`STATIC RELEASE AUDIT: PASS` is intentionally not signed-candidate clearance. The supported `create_release_candidate.sh OUTPUT_DIRECTORY` workflow creates both signed archives from a detached exact clean HEAD, embeds that revision, inventories all bundle bytes, writes provenance, and runs the production archive audit before publishing the directory. Only that production audit may emit `RELEASE AUDIT: PASS`; `--test-only` fixtures emit a visibly different marker. Unsigned builds and static audit remain distinct evidence.

Archive localization validation uses Apple `plutil` to normalize compiled `.strings`/`.stringsdict` tables before exact source-catalog key-domain comparison. This covers real macOS UTF-16LE tables whose XML encoding declaration is not directly parseable by Python `plistlib`. Certificate extraction uses codesign's joined `--extract-certificates=PREFIX` form.

## Exact containing-commit unsigned Release build and package evidence

All builds used `CODE_SIGNING_ALLOWED=NO`, the containing commit as `KNITNOTE_SOURCE_REVISION`, and separate DerivedData paths. They were run after the final-fixes commit and prove only unsigned compilation and package shape for that exact source commit.

| Target | Destination | DerivedData | Result | Identifier | Version/build |
| --- | --- | --- | --- | --- | --- |
| KnitNote iOS | `generic/platform=iOS` | `/tmp/KnitNote141FinalFixes-iOS` | PASS | `com.phillon.KnitNote` | `1.4.1 (8)` |
| KnitNote macOS | `platform=macOS` | `/tmp/KnitNote141FinalFixes-macOS` | PASS | `com.phillon.KnitNote` | `1.4.1 (8)` |
| KnitNoteWatch | `generic/platform=watchOS` | `/tmp/KnitNote141FinalFixes-Watch` | PASS | `com.phillon.KnitNote.watch` | `1.4.1 (8)` |
| KnitNoteShare | `generic/platform=iOS` | `/tmp/KnitNote141FinalFixes-Share` | PASS | `com.phillon.KnitNote.share` | `1.4.1 (8)` |

Direct inspection covered standalone iOS, macOS, Watch, and Share products plus the Watch and Share products embedded in the iOS app. All six had the expected identifier, `1.4.1 (8)`, exact twelve-item `CFBundleLocalizations`, and exactly these packaged localization directories:

```text
da.lproj, de.lproj, el.lproj, en.lproj, fi.lproj, fr.lproj,
ja.lproj, ko.lproj, nb.lproj, sv.lproj, zh-Hans.lproj, zh-Hant.lproj
```

Both Watch products also retain `WKCompanionAppBundleIdentifier = com.phillon.KnitNote` through the tested packaging contract. The exact iOS and macOS main products each contain all twelve compiled `InfoPlist.strings` tables. No compiled table contains a key outside the four-key contract (`CFBundleDisplayName`, `CFBundleName`, `NSCameraUsageDescription`, and `KnitNote Backup`), and each compiled-table plus validated direct-plist fallback resolves to the exact effective four-key values. This accounts for English source values that Xcode legitimately omits from the compiled table while still checking their exact plist paths independently.

The hardened production archive audit now also requires the signed macOS product to have the exact App Sandbox, user-selected read/write, and outbound-network entitlement contract, with only the explicitly permitted signing identifiers and optional production/debug spelling. This source/build evidence is unsigned, so it does not claim that signed-entitlement gate has run.

## Final whole-branch finding disposition

All locally automatable source/tooling corrections from the final review were implemented and covered by positive and negative tests. The terminology finding is only partially resolved until independent native-speaker review is complete:

- supported-locale missing keys and missing plural variations explicitly fall back to English;
- iOS and macOS both package complete system-string tables, and the audit rejects missing, extra, stale, masked, or misplaced values;
- source and signed macOS entitlements are checked against the exact production security contract;
- screenshot capture test seams require `--test-only`, while full validation requires the expected immutable commit, version, and build;
- Korean composition requires a Hangul-capable font and rejects tofu-equivalent glyph rendering;
- catalog terminology scopes are machine-connected to the glossary, objective defects were corrected, and native-speaker certification remains pending;
- metadata validation rejects both missing and extra locale packages.

The separate prerequisite blocker remains unresolved: `ca3014146f2b9156b71b5104f7fea7e5fbd02839` proves recorded `1.4.0 (8)` source lineage only. No exact released/App Store-selected 1.4.0 binary-to-commit relationship was supplied or established.

## Physical and native acceptance

For the broad localization/platform matrix below, no acceptance device was used. The scoped Task 4 iPhone deletion and Traditional-Chinese VoiceOver acceptance above is the sole recorded exception; it does not establish the remaining surfaces, locales, or workflows.

| Surface | Existing locales: `en`, `zh-Hant`, `zh-Hans`, `de`, `fr`, `ja` | New locales: `nb`, `sv`, `fi`, `da`, `ko`, `el` |
| --- | --- | --- |
| iPhone portrait and landscape | PENDING | PENDING |
| iPad portrait and landscape | PENDING | PENDING |
| Mac resizable windows | PENDING | PENDING |
| Apple Watch | PENDING | PENDING |
| Share Extension | PENDING | PENDING |

Every row still requires language switching, projects, six counters, pattern reader/calculators, yarn/OCR confirmation-before-save, notes/journal, backup entry points, purchase/trial messaging, Settings/About, localized errors, VoiceOver, Dynamic Type, and dark mode. New-language review must additionally cover long Nordic compound words, Korean line wrapping, and Greek accents, casing, search, sorting, and long-word wrapping. Independent native-speaker approval remains mandatory for `nb`, `sv`, `fi`, `da`, `ko`, and `el`.

## Data-neutrality acceptance

The required populated-project language cycle was **NOT PERFORMED**. The following must remain unchanged through all twelve languages: user text, project and counter identifiers/values, yarn fields and photos, OCR candidates and confirmed values, pattern links, imported bytes, PDF position, highlight and markup state, journal entries, backup content, trial state, and entitlement state. Automated screenshot fixtures prove only that their synthetic user-authored archive/files are byte-identical across locale selection; they do not replace this physical experiment.

## Screenshot and App Store status

The repository now defines twelve locale capture routes and regions (`en_US`, `zh_TW`, `zh_CN`, `de_DE`, `fr_FR`, `ja_JP`, `nb_NO`, `sv_SE`, `fi_FI`, `da_DK`, `ko_KR`, `el_GR`) with 168 manifest frames and 72 storyboard entries. No candidate screenshots were captured, composed, visually reviewed, or approved.

All twelve metadata source packages pass repository validation. Live App Store Connect locale packages, selected build, price, IAP, availability, screenshots, and publication state were **NOT INSPECTED OR CHANGED**.

## Tester sign-off

| Role | Name | Device/OS | Exact candidate | Decision |
| --- | --- | --- | --- | --- |
| iPhone/iPad tester | User (Task 4 scope) | iPhone 17 Pro Max / iOS 26.6 | Debug `efb801e86e9a3c196603548be9aca8c0b957c2c0`, `1.4.1 (8)` | PASS — four deletion/Traditional-Chinese VoiceOver assertions only; all remaining iPhone/iPad matrix items PENDING |
| Mac tester | NOT ASSIGNED | NOT RECORDED | NOT INSTALLED | PENDING |
| Watch tester | NOT ASSIGNED | NOT RECORDED | NOT INSTALLED | PENDING |
| Share Extension tester | NOT ASSIGNED | NOT RECORDED | NOT INSTALLED | PENDING |
| Accessibility reviewer | NOT ASSIGNED | NOT RECORDED | NOT INSTALLED | PENDING |
| Native-language reviewers | NOT ASSIGNED | NOT RECORDED | NOT INSTALLED | PENDING |
| Release owner | NOT SIGNED | n/a | SOURCE ONLY `1.4.1 (8)` | STOP |

## Release-boundary gate

Release remains **STOP** because this candidate commit is not `main`/`origin/main`, signed archives do not exist, and physical/native/App Store checks are pending. Before upload or submission, the release owner must verify that all of these agree with one immutable commit:

- `main`, `origin/main`, release commit, and archive provenance;
- version/build, identifiers, signed entitlements, privacy manifests, `CFBundleLocalizations`, and packaged `.lproj` directories across iOS, macOS, Watch, and Share;
- exact-device acceptance and named tester/native-speaker sign-off for all twelve languages;
- live price, IAP, availability, metadata, screenshots, and selected App Store Connect build.

Any divergence keeps the decision at **STOP**. Explicit approval is required before any upload, submission, publication, or commercial-state change.
