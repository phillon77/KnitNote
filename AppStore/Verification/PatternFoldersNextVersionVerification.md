# Pattern Folders Next-Version Verification

Status: **AUTOMATED PREPARATION PASS / PHYSICAL ACCEPTANCE PENDING**

## Exact automated candidate

- Source commit: `ef6c0c2cf1e69c4f38eaecfe2005888e31d72726`
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
| Focused folder/library/import/backup/localization selection | PASS | `382` tests in `22` suites at this candidate. |
| Complete Swift suite | PASS | `1523` tests in `128` suites passed in `302.308` seconds; true pipefail exit `0`. Log SHA-256: `06de93db46cd435e410bf0b961af135ca3ac4dc634c98aaf750fd971ae0e6d9f`. |
| iOS Simulator unsigned build | PASS | `** BUILD SUCCEEDED **`; `KnitNote`, `KnitNoteShare`, and `KnitNoteWatch` built in the graph. Log SHA-256: `8c329d141a8942b5a0ef1a08e13cc8325efccdd70413f38dcb250d8d2674f737`. |
| macOS unsigned build | PASS | `** BUILD SUCCEEDED **`. Log SHA-256: `72358fa6959541fca46c698805775f9de74c59e9b3ba155057ab5ffa7113063a`. |
| watchOS Simulator unsigned build | PASS | `** BUILD SUCCEEDED **`. Log SHA-256: `a7b195f6e4ee14a6627cc627fb656a5438a8054dee9f3451a133c9021dc924e0`. |
| Share Extension unsigned build | PASS | Existing `KnitNoteShare` scheme used because Xcode rejects `-target` together with `-derivedDataPath`; Share-only build ended `** BUILD SUCCEEDED **`. Log SHA-256: `7b059611f0517b99854a4eb24b29a5f4a4eb2749501aa7c2e5c5c47a7fdbacc9`. |
| Schema-12 migration preservation probe | PASS | `schemaTwelveMigrationPreservesEveryPatternOwnedByteAndUsage`: `1` test passed in `0.031` seconds. Log SHA-256: `acb36aeed24abf149798861a811ee1d6c997ecf652abba8ca5c76bd50e1654ba`. |
| Static diff validation | PASS | `git diff --check` passed. |

The first sandboxed iOS build attempt was non-authoritative and failed before
completion because sandboxing disconnected CoreSimulatorService during Watch
asset compilation. The exact command was rerun outside the sandbox and passed;
the failed diagnostic log remains at
`/tmp/KnitNotePatternFolders-iOS-sandbox-failed.log`.

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

## Read-only device availability

No install or launch was attempted.

- MacBook Pro (`My Mac`, macOS `26.6.1`): available.
- iPad Air 5 (`Lzzipadair5`, iPadOS `26.5.2`): unavailable; device discovery requested unlock/cable or same-network Developer Mode access.
- iPhone 17 Pro Max (`iPhone`, iOS `26.6`): unavailable; device discovery requested unlock/cable or same-network Developer Mode access.
- Apple Watch Ultra 2 (`Phil的Apple Watch`, watchOS `26.6`): unavailable; device discovery requested unlock/Bluetooth discoverability.

## Physical acceptance checklist — all PENDING

- [ ] **PENDING — iPhone:** folder-first navigation; create, rename, and delete; long-press move; scoped search; file and YouTube import destination; failure paths preserve the current selection and data.
- [ ] **PENDING — iPad:** sidebar/detail in portrait, landscape, and narrow Split View; folder CRUD/move/import/search; no hidden controls or clipped content.
- [ ] **PENDING — Mac:** sidebar, context menus, keyboard focus, window resizing, folder CRUD/move/import/search, and failure recovery.
- [ ] **PENDING — Accessibility:** VoiceOver names, counts, selected state, actions and hints; Dynamic Type; minimum touch targets; orientation/window-resizing behavior.
- [ ] **PENDING — Live localization:** switch zh-Hant, en, and ja while the app remains open; folder system names and all folder actions update immediately; user-created names remain verbatim.
- [ ] **PENDING — Existing-data preservation:** before/after comparison of existing PDF, image, and YouTube patterns; project links; reader positions; page notes; highlights; markup bytes; folder membership; and backup export/restore.

Physical acceptance must use a binary built from the exact source commit above,
without uninstalling the existing app or erasing its data. Stop fail-closed on
any missing pattern, broken backup, wrong language, inaccessible control, or
partial folder transaction.
