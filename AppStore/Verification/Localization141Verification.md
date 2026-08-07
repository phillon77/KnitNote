# KnitNote 1.4.1 localization verification record

## Release decision

**STOP — the source candidate is `1.4.1 (8)`, but release acceptance is incomplete.**

Automated tests and static release checks cover the repository state containing this record. Four unsigned Release builds were created after the final-fixes commit and six standalone/embedded products were inspected against that exact containing commit. This is exact-source compile and package evidence only; it does not establish signed-archive, physical-device, native-language, visual, accessibility, data-neutrality, commercial, or App Store Connect acceptance.

No archive, signing, upload, submission, merge, push, price change, IAP change, or App Store Connect modification was performed.

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

No acceptance device was used. Device model, OS version, installed candidate identity, tester, and date are therefore **NOT RECORDED** for every surface below.

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
| iPhone/iPad tester | NOT ASSIGNED | NOT RECORDED | NOT INSTALLED | PENDING |
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
