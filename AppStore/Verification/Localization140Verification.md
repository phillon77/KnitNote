# KnitNote localization verification record

## Release decision

**STOP — this is not an immutable KnitNote 1.4.0 release candidate.**

The repository-owned automated checks pass. Four unsigned Release builds from the original verification commit passed, and the review-fix change set also passes a fresh unsigned iOS Release integration build containing the Watch and Share products. Every inspected product declares and packages the six release locales. Release acceptance is still blocked because:

- every target is still marketing version `1.3.1`, build `7`, not `1.4.0`;
- the source candidate supplied for this verification, `fdb978dd80475a27a5c09510a57f8c53e2876314`, built without `CFBundleLocalizations`; the fix is in a later verification commit;
- no signed archives were created or audited;
- no physical-device, visual, accessibility, data-neutrality, or tester acceptance was performed;
- new six-language screenshots were not captured or visually approved;
- live App Store Connect build selection, price, IAP, and metadata were not verified.

No archive, upload, submission, merge, push, price change, or IAP change was performed as part of this verification.

## Candidate and environment identity

| Field | Recorded value |
| --- | --- |
| Verification date | 2026-08-06, Asia/Taipei |
| Supplied source candidate | `fdb978dd80475a27a5c09510a57f8c53e2876314` |
| Supplied source tree | `2c9fb3eec3722509dbb7d2b9df4c98b72b482fb1` |
| Supplied source `git archive` SHA-256 | `7f4f593c8aaeaa0dbfd47ca29d54e32a222203f2380c072246eed9bd172a4496` |
| Original Task 8 verification commit | `2354714c3416433801e14173c0d59f19f51bd9bb` (`test: verify KnitNote 1.4 localization`) |
| Review-fix commit | The commit containing this record, with subject `fix: harden localization release verification`; resolve its immutable SHA with `git log -1 --format=%H -- AppStore/Verification/Localization140Verification.md` |
| Marketing version in every build | `1.3.1` — **release blocker** |
| Build number in every build | `7` |
| Xcode | 26.6 (`17F113`) |
| Swift | Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`) |
| `main` at verification time | `3ff06866923ee1d0952b211079e0e4fdd073867f` |
| `origin/main` at verification time | `3ff06866923ee1d0952b211079e0e4fdd073867f` |

The review-fix commit is intentionally not embedded as a literal SHA in its own contents because doing so would change that SHA. The final handoff must pair this record with the containing commit returned by Git.

## Automated verification

| Check | Result | Evidence |
| --- | --- | --- |
| Baseline Swift suite at supplied source commit | PASS | 1,269 tests in 117 suites |
| Final full Swift suite | PASS | 1,282 tests in 118 suites, zero failures |
| App Store metadata checker | PASS | `METADATA CHECK: PASS` |
| Commercial configuration, offline | PASS | `COMMERCIAL RELEASE CHECK: PASS (offline)` |
| Static release audit | PASS | `RELEASE AUDIT: PASS` |
| Release-audit localization behavior tests | PASS | 8 tests, including rejection of an extra `nb` catalog localization and `nb.lproj`, plus acceptance of exact six localized directories with optional `Base.lproj` |
| Screenshot fixture/tooling tests | PASS | 14 tests, including byte-identical all-six main fixtures, identical all-six Watch fixtures, and sanitized capture-entrypoint environment |
| Screenshot manifest-only validation | PASS | 84 definitions |
| Signed archive audit | **NOT RUN** | No archive or signing was authorized; fixture tests do not substitute for a real signed archive |

The first full-audit attempt inside the restricted sandbox failed before tests because SwiftPM could not write `~/.cache/clang/ModuleCache`. The same command was rerun with normal SwiftPM cache access and passed. This was an execution-environment failure, not a product test failure.

The review-fix full Swift and static-audit commands were:

```sh
swift test --disable-sandbox --scratch-path /tmp/KnitNoteTask8FixRound1Full-2354714
AppStore/Verification/release_audit.sh --static-only
```

They completed with:

```text
Test run with 1282 tests in 118 suites passed
METADATA CHECK: PASS
COMMERCIAL RELEASE CHECK: PASS (offline)
RELEASE AUDIT: PASS
```

## Localization source contract

The exact expected locale identifiers are:

```text
en, zh-Hant, zh-Hans, de, fr, ja
```

| Source | Source language | Locale set | Entries |
| --- | --- | --- | ---: |
| `KnitNote/Localization/Localizable.xcstrings` | `en` | all six | 509 |
| `KnitNote/Localization/InfoPlist.xcstrings` | `en` | all six across the catalog | 4 |
| `KnitNoteWatch/Localizable.xcstrings` | `en` | all six | 15 |
| `KnitNoteShare/Localizable.xcstrings` | `en` | all six | 18 |
| Xcode project `knownRegions` | development region `en` | all six plus `Base` | n/a |
| Main source `Info.plist` | n/a | exact six-item `CFBundleLocalizations` | n/a |
| Watch source `Info.plist` | n/a | exact six-item `CFBundleLocalizations` | n/a |
| Share source `Info.plist` | n/a | exact six-item `CFBundleLocalizations` | n/a |

`InfoPlist.xcstrings` uses the String Catalog source-language/key fallback for the English `KnitNote Backup` source string; the other five locale values remain explicit and complete. For every entry in all four catalogs, the audit treats an omitted English source localization as that canonical fallback and requires the resulting localization-key domain to equal the six release locales exactly. Missing and extra locales are rejected.

Packaged resource directories follow the same exact-domain rule: the localized `.lproj` set must equal the six release locales. `Base.lproj` is explicitly optional and ignored only because it contains Interface Builder base resources rather than a release locale; every other extra `.lproj` directory is rejected.

## Release build evidence

All commands used `Release` and `CODE_SIGNING_ALLOWED=NO`. These products are unsigned build evidence only; they are not archives and are not installable release acceptance candidates.

The supplied source commit `fdb978dd80475a27a5c09510a57f8c53e2876314` first produced four successful builds, but all four products lacked `CFBundleLocalizations`. That supplied commit therefore failed the localization packaging contract and was rejected as a release candidate.

After the minimal source-plist fix, the four targets were rebuilt from the same verification change set. The same four commands were run again from clean original verification commit `2354714c3416433801e14173c0d59f19f51bd9bb` after it was created.

| Target | Destination | DerivedData | Build | Identifier | Version/build |
| --- | --- | --- | --- | --- | --- |
| KnitNote iOS | `generic/platform=iOS` | `/tmp/KnitNoteTask8Fixed-20260806-1503-iOS` | PASS | `com.phillon.KnitNote` | `1.3.1 (7)` |
| KnitNote macOS | `platform=macOS` | `/tmp/KnitNoteTask8Fixed-20260806-1503-macOS` | PASS | `com.phillon.KnitNote` | `1.3.1 (7)` |
| KnitNoteWatch | `generic/platform=watchOS` | `/tmp/KnitNoteTask8Fixed-20260806-1503-Watch` | PASS | `com.phillon.KnitNote.watch` | `1.3.1 (7)` |
| KnitNoteShare | `generic/platform=iOS` | `/tmp/KnitNoteTask8Fixed-20260806-1503-Share` | PASS | `com.phillon.KnitNote.share` | `1.3.1 (7)` |

The review-fix change set then received a fresh integration build:

| Target | Destination | DerivedData | Build | Version/build |
| --- | --- | --- | --- | --- |
| KnitNote iOS with embedded Watch and Share | `generic/platform=iOS` | `/tmp/KnitNoteTask8FixRound1-iOS` | PASS | `1.3.1 (7)` |

Direct inspection of that fresh integration product again found exact six-item `CFBundleLocalizations` arrays and exact six localized `.lproj` directories in the main app, embedded Watch app, and embedded Share extension.

Direct inspection of each standalone product and the iOS product's embedded Watch and Share bundles found the same result:

- `CFBundleLocalizations`: exactly `en`, `zh-Hant`, `zh-Hans`, `de`, `fr`, `ja`;
- packaged localization directories: exactly `en.lproj`, `zh-Hant.lproj`, `zh-Hans.lproj`, `de.lproj`, `fr.lproj`, `ja.lproj`;
- no platform's result is being used as evidence for another platform.

## Screenshot automation and visual status

The release storyboard and tooling now cover all six locales while preserving the existing command-line interfaces.

| Item | Automated result | Human acceptance |
| --- | --- | --- |
| Release storyboard | 36 entries: 6 per locale | **PENDING** |
| Screenshot manifest | 84 frames: 14 per locale | manifest-only PASS |
| Capture script locale/region routing | `en_US`, `zh_TW`, `zh_CN`, `de_DE`, `fr_FR`, `ja_JP` | **NOT CAPTURED** |
| Composer contact sheets | six locale outputs supported | **NOT VISUALLY REVIEWED** |
| Generated screenshots for `zh-Hans`, `de`, `fr`, `ja` | tooling ready | **NOT GENERATED / NOT APPROVED** |
| Existing `en` / `zh-Hant` generated assets | historical files only | **NOT candidate evidence** |

All six locale fixtures now reuse one neutral English sample user-authored payload. The main fixture's serialized archive bytes and complete generated-file dictionary are identical across all six UI locales; the Watch fixture's project identity and complete cache are also identical. This prevents screenshots from implying that changing app language translates project names, counters, notes, journals, yarn details, imported content, or identifiers. Capture-entrypoint tests strip simulator UDIDs and app-path overrides before invoking the real script, so an armed parent shell still stops at the first non-destructive device gate. These automated guarantees do not replace physical language-switching verification.

## Physical six-language acceptance matrix

Every cell is independently pending. A pass on one device, orientation, process, or locale must not be copied to another cell.

| Surface | `en` | `zh-Hant` | `zh-Hans` | `de` | `fr` | `ja` |
| --- | --- | --- | --- | --- | --- | --- |
| iPhone portrait | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |
| iPhone landscape | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |
| iPad portrait | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |
| iPad landscape | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |
| Mac resizable windows | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |
| Apple Watch | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |
| Share Extension | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |

No acceptance device was used, so device model, OS version, installed build identity, and exact-candidate installation evidence are all **NOT RECORDED**.

For every matrix cell, all of these flows remain **PENDING / NOT VERIFIED**:

- launch and language switching;
- create/edit project;
- pattern library, reader, markup, calculator, PDF page/zoom/highlight state;
- counters and row notes;
- journal entries and photos;
- yarn editing and OCR candidate confirmation before save;
- backup/export and restore entry points;
- purchase, trial, and unlock messaging;
- Settings and About;
- localized validation and error dialogs.

## Accessibility and appearance acceptance

| Surface | VoiceOver focus/order | Dynamic Type/layout | Dark mode | Error dialogs |
| --- | --- | --- | --- | --- |
| iPhone portrait | PENDING | PENDING | PENDING | PENDING |
| iPhone landscape | PENDING | PENDING | PENDING | PENDING |
| iPad portrait | PENDING | PENDING | PENDING | PENDING |
| iPad landscape | PENDING | PENDING | PENDING | PENDING |
| Mac resizable windows | PENDING | PENDING | PENDING | PENDING |
| Apple Watch | PENDING | PENDING | PENDING | PENDING |
| Share Extension | PENDING | PENDING | PENDING | PENDING |

These checks must be repeated in all six locales. No accessibility or appearance cell is passed by source inspection or automated tests.

## Data-neutral language-switch verification

The required known-data experiment was **NOT PERFORMED**. Each item remains pending through a full `zh-Hant → en → zh-Hans → de → fr → ja → zh-Hant` cycle:

| Data | Required comparison | Status |
| --- | --- | --- |
| Project and identifiers | IDs, timestamps, values, completion state | PENDING |
| Six counters | IDs, names, values, row state | PENDING |
| User notes | exact user-entered text | PENDING |
| Journal | text, dates, links, photo references | PENDING |
| Yarn and OCR | confirmed fields, photos, project links; no save before confirmation | PENDING |
| Imported pattern/PDF | bytes, collection links, reading context | PENDING |
| Reader state | page, zoom, offset, highlights, markup | PENDING |
| Backup | byte-for-byte or semantic package comparison as appropriate | PENDING |

## Tester sign-off

| Role | Name | Exact candidate | Date | Decision |
| --- | --- | --- | --- | --- |
| iPhone/iPad tester | NOT ASSIGNED | NOT INSTALLED | NOT RECORDED | PENDING |
| Mac tester | NOT ASSIGNED | NOT INSTALLED | NOT RECORDED | PENDING |
| Watch tester | NOT ASSIGNED | NOT INSTALLED | NOT RECORDED | PENDING |
| Share Extension tester | NOT ASSIGNED | NOT INSTALLED | NOT RECORDED | PENDING |
| Accessibility reviewer | NOT ASSIGNED | NOT INSTALLED | NOT RECORDED | PENDING |
| Release owner | NOT SIGNED | NOT A 1.4.0 CANDIDATE | 2026-08-06 | STOP |

## Release-boundary gate

Before any archive, upload, or App Store Connect submission, the release owner must create and identify a true `1.4.0` candidate, then re-run this entire record against that exact immutable commit and installed binary. The following must all agree before release can proceed:

- `main` and `origin/main`;
- release commit and archive provenance;
- version and build number across iOS, macOS, Watch, and Share;
- signed bundle identifiers, entitlements, privacy manifests, six `.lproj` directories, and `CFBundleLocalizations`;
- live price, IAP, and selected App Store Connect build;
- six-language metadata and visually approved screenshots;
- exact-candidate physical acceptance and named tester sign-off.

Any divergence keeps the decision at **STOP**.
