# KnitNote 1.4.1 localization verification record

## Release decision

**STOP — the source candidate is `1.4.1 (8)`, but release acceptance is incomplete.**

Automated tests, static release checks, four unsigned Release builds, and direct inspection of six standalone/embedded products agree on the exact twelve-language candidate identity. This evidence does not establish signed-archive, physical-device, native-language, visual, accessibility, data-neutrality, commercial, or App Store Connect acceptance.

No archive, signing, upload, submission, merge, push, price change, IAP change, or App Store Connect modification was performed.

## Candidate and environment identity

| Field | Recorded value |
| --- | --- |
| Verification date | 2026-08-07, Asia/Taipei |
| Task 5 starting commit | `ebe2d0cec5c968c4f8457dc70a8b58dba90c70b6` |
| Exact source candidate | The commit containing this record, with subject `test: verify KnitNote 1.4.1 localization`; resolve with `git log -1 --format=%H -- AppStore/Verification/Localization141Verification.md` |
| Candidate branch | `docs/knitnote-1.4.1-greek-plan` |
| Marketing version | `1.4.1` in every shipping target and inspected product |
| Build number | `8`, preserved in every shipping target and inspected product |
| Xcode | 26.6 (`17F113`) |
| Swift | Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`) |
| `main` at verification time | `3ff06866923ee1d0952b211079e0e4fdd073867f` |
| `origin/main` at verification time | `3ff06866923ee1d0952b211079e0e4fdd073867f` |

The containing commit is not embedded as its own literal SHA because changing this file would change that SHA. The handoff must pair this record with the containing commit reported by Git.

## Exact localization identity

The required locale set is:

```text
en, zh-Hant, zh-Hans, de, fr, ja, nb, sv, fi, da, ko, el
```

`project.yml`, the generated Xcode project, all three source Info.plists, all four String Catalogs, the release audit, the screenshot manifest/capture tooling, and every inspected built product use this exact set. `Base.lproj` is ignored only as an optional Interface Builder base-resource directory; any other missing or extra localization is rejected.

## TDD and automated verification

| Check | Result | Evidence |
| --- | --- | --- |
| Focused Task 5 RED | EXPECTED FAIL | 57 tests, 71 issues against the old `1.4.0`/six-locale audit and screenshot contracts |
| Focused Task 5 GREEN | PASS | 57 tests in 5 suites, zero issues |
| Full Swift suite | PASS | 1,317 tests in 122 suites, zero issues |
| Metadata validator | PASS | `METADATA CHECK: PASS` for all twelve repository locale packages |
| Commercial configuration, offline | PASS | `COMMERCIAL RELEASE CHECK: PASS (offline)` |
| Static release audit | PASS | `STATIC RELEASE AUDIT: PASS` |
| Screenshot manifest-only validation | PASS | 168 definitions: 14 per locale |
| Release storyboard contract | PASS | 72 entries: 6 per locale |
| Real signed archive audit | **NOT RUN** | No signed archives were created or supplied |

`STATIC RELEASE AUDIT: PASS` is intentionally not signed-candidate clearance. Only `release_audit.sh --archives DIR` against same-commit signed iOS and macOS archives may emit `RELEASE AUDIT: PASS`.

## Unsigned Release build and package evidence

All builds used `CODE_SIGNING_ALLOWED=NO` and separate DerivedData paths. They are compile/package evidence only.

| Target | Destination | DerivedData | Result | Identifier | Version/build |
| --- | --- | --- | --- | --- | --- |
| KnitNote iOS | `generic/platform=iOS` | `/tmp/KnitNote141Task5-iOS` | PASS | `com.phillon.KnitNote` | `1.4.1 (8)` |
| KnitNote macOS | `platform=macOS` | `/tmp/KnitNote141Task5-macOS` | PASS | `com.phillon.KnitNote` | `1.4.1 (8)` |
| KnitNoteWatch | `generic/platform=watchOS` | `/tmp/KnitNote141Task5-Watch` | PASS | `com.phillon.KnitNote.watch` | `1.4.1 (8)` |
| KnitNoteShare | `generic/platform=iOS` | `/tmp/KnitNote141Task5-Share` | PASS | `com.phillon.KnitNote.share` | `1.4.1 (8)` |

Direct inspection covered standalone iOS, macOS, Watch, and Share products plus the Watch and Share products embedded in the iOS app. All six had the expected identifier, `1.4.1 (8)`, exact twelve-item `CFBundleLocalizations`, and exactly these packaged localization directories:

```text
da.lproj, de.lproj, el.lproj, en.lproj, fi.lproj, fr.lproj,
ja.lproj, ko.lproj, nb.lproj, sv.lproj, zh-Hans.lproj, zh-Hant.lproj
```

Both Watch products also retain `WKCompanionAppBundleIdentifier = com.phillon.KnitNote` through the tested packaging contract.

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
