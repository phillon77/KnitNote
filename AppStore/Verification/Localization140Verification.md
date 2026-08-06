# KnitNote localization verification record

## Release decision

**STOP — the exact source candidate is KnitNote `1.4.0 (8)`, but release acceptance remains incomplete.**

The project specification, generated Xcode Release settings, source plists, and all six inspected standalone/embedded products agree on `1.4.0 (8)` and the exact six release locales. This removes the earlier version/build blocker. Release acceptance is still blocked because:

- no signed archives were created or audited;
- no physical-device, visual, accessibility, data-neutrality, or tester acceptance was performed;
- new six-language screenshots were not captured or visually approved;
- live App Store Connect build selection, price, IAP, and metadata were not verified.

No archive, upload, submission, merge, push, price change, or IAP change was performed as part of this verification.

## Candidate and environment identity

| Field | Recorded value |
| --- | --- |
| Verification date | 2026-08-06, Asia/Taipei |
| Historical supplied source | `fdb978dd80475a27a5c09510a57f8c53e2876314` — rejected; not the current candidate |
| Supplied source tree | `2c9fb3eec3722509dbb7d2b9df4c98b72b482fb1` |
| Supplied source `git archive` SHA-256 | `7f4f593c8aaeaa0dbfd47ca29d54e32a222203f2380c072246eed9bd172a4496` |
| Original Task 8 verification commit | `2354714c3416433801e14173c0d59f19f51bd9bb` (`test: verify KnitNote 1.4 localization`) |
| Review-fix commit | `1e77d9a712cb277e7240d15ed4b797e4195d979c` (`fix: harden localization release verification`) |
| Exact `1.4.0 (8)` source candidate | The commit containing this record, with subject `chore: prepare KnitNote 1.4.0 build 8`; resolve its immutable SHA with `git log -1 --format=%H -- AppStore/Verification/Localization140Verification.md` |
| Candidate branch | `docs/knitnote-1.4-localization` |
| Marketing version in every candidate build | `1.4.0` |
| Build number in every candidate build | `8` |
| Xcode | 26.6 (`17F113`) |
| Swift | Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`) |
| `main` at verification time | `3ff06866923ee1d0952b211079e0e4fdd073867f` |
| `origin/main` at verification time | `3ff06866923ee1d0952b211079e0e4fdd073867f` |

The exact candidate commit is intentionally not embedded as a literal SHA in its own contents because doing so would change that SHA. The final handoff must pair this record with the containing commit returned by Git.

## Automated verification

| Check | Result | Evidence |
| --- | --- | --- |
| Baseline Swift suite at supplied source commit | PASS | 1,269 tests in 117 suites |
| Final full Swift suite | PASS | 1,287 tests in 119 suites, zero failures |
| App Store metadata checker | PASS | `METADATA CHECK: PASS` |
| Commercial configuration, offline | PASS | `COMMERCIAL RELEASE CHECK: PASS (offline)` |
| Static release audit | PASS | `RELEASE AUDIT: PASS` |
| Release candidate identity behavior tests | PASS | 3 tests covering parsed `project.yml`, four resolved Xcode Release setting combinations, generated source plists, and exact six locale declarations |
| Release-audit localization/identity behavior tests | PASS | 10 tests, including independent rejection of version `1.3.1`, build `7`, an extra `nb` catalog localization, and `nb.lproj`, plus acceptance of `1.4.0 (8)` with optional `Base.lproj` |
| Screenshot fixture/tooling tests | PASS | 14 tests, including byte-identical all-six main fixtures, identical all-six Watch fixtures, and sanitized capture-entrypoint environment |
| Screenshot manifest-only validation | PASS | 84 definitions |
| Signed archive audit | **NOT RUN** | No archive or signing was authorized; fixture tests do not substitute for a real signed archive |

During the original Task 8 verification, a restricted-sandbox attempt failed before tests because SwiftPM could not write `~/.cache/clang/ModuleCache`; its normal-cache rerun passed. The current candidate-identity run used the explicit scratch path below and did not encounter that environment failure.

The candidate-identity full Swift and static-audit commands were:

```sh
swift test --disable-sandbox --scratch-path /tmp/KnitNoteTask8RC140Full-1e77
AppStore/Verification/release_audit.sh --static-only
```

They completed with:

```text
Test run with 1287 tests in 119 suites passed
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

`project.yml` is now the canonical generator input for the three dynamic version/build plist keys and the three exact six-item `CFBundleLocalizations` arrays. A repeated `xcodegen generate` left the generated project and all three source plist SHA-256 values unchanged. Generation also reconciled the already-committed `SupportedLocalization.swift` source into the app and Watch targets covered by `Sources/KnitNoteCore`; no scheme or other product membership changed.

## Release build evidence

All commands used `Release` and `CODE_SIGNING_ALLOWED=NO` from the clean exact commit containing this record. These products are unsigned build evidence only; they are not signed archives and do not establish physical acceptance.

| Target | Destination | DerivedData | Build | Identifier | Version/build |
| --- | --- | --- | --- | --- | --- |
| KnitNote iOS | `generic/platform=iOS` | `/tmp/KnitNote140Build8-RC-exact-iOS` | PASS | `com.phillon.KnitNote` | `1.4.0 (8)` |
| KnitNote macOS | `platform=macOS` | `/tmp/KnitNote140Build8-RC-exact-macOS` | PASS | `com.phillon.KnitNote` | `1.4.0 (8)` |
| KnitNoteWatch | `generic/platform=watchOS` | `/tmp/KnitNote140Build8-RC-exact-Watch` | PASS | `com.phillon.KnitNote.watch` | `1.4.0 (8)` |
| KnitNoteShare | `generic/platform=iOS` | `/tmp/KnitNote140Build8-RC-exact-Share` | PASS | `com.phillon.KnitNote.share` | `1.4.0 (8)` |

Direct inspection covered six independently identified products: standalone iOS, macOS, Watch, and Share plus the Watch and Share products embedded in the iOS app. Every product had:

- the expected production bundle identifier; both Watch products also had companion identifier `com.phillon.KnitNote`;
- `CFBundleShortVersionString = 1.4.0` and `CFBundleVersion = 8`;
- `CFBundleLocalizations`: exactly `en`, `zh-Hant`, `zh-Hans`, `de`, `fr`, `ja`;
- packaged localization directories: exactly `en.lproj`, `zh-Hant.lproj`, `zh-Hans.lproj`, `de.lproj`, `fr.lproj`, `ja.lproj`.

Historical note: the originally supplied `fdb978dd80475a27a5c09510a57f8c53e2876314` source and later `1.3.1 (7)` verification builds are not this candidate. They remain relevant only as earlier rejected/fix-round evidence; none is being promoted to candidate status.

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
| Release owner | NOT SIGNED | SOURCE CANDIDATE `1.4.0 (8)`; NOT INSTALLED | 2026-08-06 | STOP |

## Release-boundary gate

Before any archive, upload, or App Store Connect submission, the release owner must use the exact immutable `1.4.0 (8)` commit identified by this record, produce signed archives from it, and complete the pending installed-binary acceptance. The following must all agree before release can proceed:

- `main` and `origin/main`;
- release commit and archive provenance;
- version and build number across iOS, macOS, Watch, and Share;
- signed bundle identifiers, entitlements, privacy manifests, six `.lproj` directories, and `CFBundleLocalizations`;
- live price, IAP, and selected App Store Connect build;
- six-language metadata and visually approved screenshots;
- exact-candidate physical acceptance and named tester sign-off.

Any divergence keeps the decision at **STOP**.
