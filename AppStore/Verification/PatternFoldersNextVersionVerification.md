# Pattern Folders Next-Version Verification

Status: **AUTOMATED PREPARATION PASS / IPHONE CORE ACCEPTANCE PASS / REMAINING PHYSICAL ACCEPTANCE PENDING**

## Exact automated candidate

- Source commit: `f926a595948165b1fc64e8c9a5c453dc27857b1d`
- Branch: `feature/knitnote-1.5`
- Marketing version: `1.5.0`
- Build number: `10`
- Generated project SHA-256: `c3b2be0d83aef5a900f01c53cc02f6b7a0f631deab97eeb5dce6fff7645b560f`
- Preparation date: `2026-08-14` (Asia/Taipei)

This record prepares physical acceptance only. It is not an archive, export,
upload, App Store selection, submission, release, or publication claim.

## Automated gates

| Gate | Result | Exact evidence |
| --- | --- | --- |
| XcodeGen stability | PASS | Project hash was identical before, between, and after two consecutive generations; no `pbxproj` diff. |
| Focused folder/library/import/backup/localization selection | PASS | Final Fix Round 1 reviewed selection: `387` tests in `22` suites at this candidate. |
| Complete Swift suite | PASS | `1529` tests in `128` suites passed in `304.224` seconds; true pipefail exit `0`. Log SHA-256: `6f99f635fd2eb35726357a70c33425f99ac6b82e849112db0b97f34c6653dc44`. |
| iOS Simulator unsigned build | PASS | `** BUILD SUCCEEDED **`; `KnitNote`, `KnitNoteShare`, and `KnitNoteWatch` built in the graph. Log SHA-256: `6a8fc562b0d9bdb45c251d63c74b01f6cd8bb60f79cfb70792a3893ba069e0b9`. |
| macOS unsigned build | PASS | `** BUILD SUCCEEDED **`. Log SHA-256: `e5847fa1dfb4aad4ea035fe400bc047586f766dfb5962f94e90a05d8bebc57d9`. |
| watchOS Simulator unsigned build | PASS | `** BUILD SUCCEEDED **`. Log SHA-256: `1104423b7422a941ab2d39f978f789762a477b52b7824f4b384e9f457fa1f8b3`. |
| Share Extension unsigned build | PASS | Existing `KnitNoteShare` scheme used because Xcode rejects `-target` together with `-derivedDataPath`; Share-only build ended `** BUILD SUCCEEDED **`. Log SHA-256: `5c3ba9cf3d3526905191beeed3fe093c7303d7b106f41701cc79ebe79e0729a6`. |
| Schema-12 migration preservation probe | PASS | `schemaTwelveMigrationPreservesEveryPatternOwnedByteAndUsage`: `1` test passed in `0.031` seconds. Log SHA-256: `4b2e53ca28cc6571cd0f62735c5e2ba4844ca3440056dc37f29a23669dac5525`. |
| Static diff validation | PASS | `git diff --check` passed. |

The prior automated record at acceptance commit `d00bb36c93368b517987f033f91ebaec08a7fc1c`
was bound to source `ef6c0c2cf1e69c4f38eaecfe2005888e31d72726` and is superseded by
this final production-fix candidate. All commands above were invoked with HEAD
bound to the source commit recorded here.

## Built identity

| Product | Bundle identifier | Version | Build |
| --- | --- | --- | --- |
| iOS app | `com.phillon.KnitNote` | `1.5.0` | `10` |
| macOS app | `com.phillon.KnitNote` | `1.5.0` | `10` |
| Watch app | `com.phillon.KnitNote.watch` | `1.5.0` | `10` |
| Share Extension | `com.phillon.KnitNote.share` | `1.5.0` | `10` |

The iOS graph compiled the canonical `ProjectArchiveSchema.swift` and folder
model/presentation sources into the main app. The Share graph compiled the
schema-13 inbox payload source `PatternInboxItem.swift`, including captured
folder destination data, into `KnitNoteShare` for both simulator architectures.

## iPhone physical acceptance — PASS for tested core scope

- Acceptance date: `2026-08-14` (Asia/Taipei)
- Device: iPhone 17 Pro Max (`iPhone`, iOS `26.6`)
- Installed by data-preserving overlay: `com.phillon.KnitNote` `1.5.0` (`10`)
- Built source: `f926a595948165b1fc64e8c9a5c453dc27857b1d`
- Pre-install identity: `1.5.0` (`9`)
- Post-install identity: `1.5.0` (`10`)
- `xcrun devicectl device install app` and subsequent app launch both exited `0`.
- The user reported **PASS** after checking that existing projects and patterns remained,
  folder-first navigation worked, All and Uncategorized worked, folder create/rename/delete
  worked, long-press move worked, deleting a populated folder returned its patterns to
  Uncategorized, and live language switching did not translate user-created folder or
  pattern names.

This pass is limited to the behaviors explicitly exercised above. It does not claim the
extended import/failure matrix, VoiceOver/Dynamic Type, iPad, Mac, Watch, archive, export,
upload, submission, release, or publication acceptance. At the time of this session, the
later planned `1.5.1` (`11`) identity had not yet been built or installed and was not
covered by this session.

## Read-only device availability before this acceptance session

At automated-preparation time, no install or launch had been attempted. The iPhone state
was superseded by the physical acceptance session recorded above.

- MacBook Pro (`My Mac`, macOS `26.6.1`): available.
- iPad Air 5 (`Lzzipadair5`, iPadOS `26.5.2`): unavailable; device discovery requested unlock/cable or same-network Developer Mode access.
- iPhone 17 Pro Max (`iPhone`, iOS `26.6`): unavailable; device discovery requested unlock/cable or same-network Developer Mode access.
- Apple Watch Ultra 2 (`Phil的Apple Watch`, watchOS `26.6`): unavailable; device discovery requested unlock/Bluetooth discoverability.

## Remaining physical acceptance checklist

- [x] **PASS — iPhone core:** data-preserving overlay; folder-first navigation; All and Uncategorized; create, rename, delete, and long-press move; populated-folder deletion recovery; live language switching with user-created names preserved.
- [ ] **PENDING — iPhone extended:** scoped search; file and YouTube import destination; failure paths preserve the current selection and data; VoiceOver and Dynamic Type.
- [ ] **PENDING — iPad:** sidebar/detail in portrait, landscape, and narrow Split View; folder CRUD/move/import/search; no hidden controls or clipped content.
- [ ] **PENDING — Mac:** sidebar, context menus, keyboard focus, window resizing, folder CRUD/move/import/search, and failure recovery.
- [ ] **PENDING — Accessibility:** VoiceOver names, counts, selected state, actions and hints; Dynamic Type; minimum touch targets; orientation/window-resizing behavior.
- [ ] **PENDING — Live localization:** switch zh-Hant, en, and ja while the app remains open; folder system names and all folder actions update immediately; user-created names remain verbatim.
- [ ] **PENDING — Existing-data preservation:** before/after comparison of existing PDF, image, and YouTube patterns; project links; reader positions; page notes; highlights; markup bytes; folder membership; and backup export/restore.

Physical acceptance must use a binary built from the exact source commit above,
without uninstalling the existing app or erasing its data. Stop fail-closed on
any missing pattern, broken backup, wrong language, inaccessible control, or
partial folder transaction.
