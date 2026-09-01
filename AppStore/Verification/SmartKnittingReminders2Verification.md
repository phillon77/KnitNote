# Smart Knitting Reminders 2.0 — Task 10 Verification

Date: 2026-09-01 (Asia/Taipei)

## Candidate identity and scope

- Branch: `docs/knitnote-smart-reminders-2`
- Verified source SHA (before this evidence-only Task 10 commit): `fff68786429a2f18d9cacca4a52f7cd1b2d99bc4`
- Development identity: `1.5.1 (11)`; Task 10 did not change the marketing version or build number.
- Automated status: **PASS.** All Task 10 automated gates below were rerun on the verified source SHA.
- Scope boundary: this is reproducible automated evidence and acceptance preparation only. It did not archive, export, upload, submit, publish, change signing, change pricing, or claim physical-device acceptance.

## Reviewed regression-fix inputs

The previously blocked reader-reminder regression was corrected before this rerun by these source commits:

- `c79baf541d1ebe6d1e8cc65718fc39aceb4844c3` — `test: update reader reminder regressions for schema 14`
- `67cb9a0dd735f26fafc05eb100a3ea881399c551` — `test: strengthen reader reminder atomicity assertions`
- `fff68786429a2f18d9cacca4a52f7cd1b2d99bc4` — `test: pin reader reminder revision transitions`

## Generated-project and repository checks

| Command | Result |
| --- | --- |
| `git diff --check` before verification | passed (silent) |
| `xcodegen generate` | passed |
| `git diff --exit-code -- KnitNote.xcodeproj/project.pbxproj` | passed (generated PBX project remained byte-stable) |

## Full Swift package regression

Command:

```text
swift test --disable-sandbox 2>&1 | tee /tmp/KnitNoteSmartReminders2-20260901-164053-full-swift-test.log
```

Result: `Test run with 1720 tests in 140 suites passed after 318.056 seconds.` The retained log contains no Swift Testing issue marker.

- Log: `/tmp/KnitNoteSmartReminders2-20260901-164053-full-swift-test.log`
- Bytes: `378228`
- SHA-256: `e794329b0c8366f1199fa9ac2d799ed2fdc8a6052c516951bf959a916e9f8464`

## Focused reminder contracts and archive-migration fixtures

UI, reader, Watch-view, and localization contract command:

```text
swift test --disable-sandbox --filter 'PatternLibraryStoreTests|KnittingReminderViewContractTests|WatchCounterViewContractTests|LocalizationContractTests' 2>&1 | tee /tmp/KnitNoteSmartReminders2-20260901-164053-reminder-contracts.log
```

Result: `Test run with 159 tests in 5 suites passed after 1.078 seconds.`

- Log: `/tmp/KnitNoteSmartReminders2-20260901-164053-reminder-contracts.log`
- Bytes: `29783`
- SHA-256: `dbbe138e0a520b0bcb121588d02ecbfec833bbda1ca52b575c2b3329d032c589`

Core, archive-migration, and durable Watch command command:

```text
swift test --disable-sandbox --filter 'KnittingReminderMigrationTests|KnittingReminderStoreTests|KnittingReminderTests|WatchCommandApplicationTests|WatchSyncPersistenceTests' 2>&1 | tee /tmp/KnitNoteSmartReminders2-20260901-164053-reminder-migration-contracts.log
```

Result: `Test run with 103 tests in 5 suites passed after 0.513 seconds.` This includes `version13MigratesEveryCounterReminderWithoutRebinding`, migration progress/revision preservation, backup staging/rejection, atomic persistence failures, and durable Watch reminder actions.

- Log: `/tmp/KnitNoteSmartReminders2-20260901-164053-reminder-migration-contracts.log`
- Bytes: `23169`
- SHA-256: `333304211299a5ecc01345b539267f1675fc88515d70b2b855d3a0193110a470`

## Fresh unsigned builds

Each command used its own clean timestamped derived-data path and `CODE_SIGNING_ALLOWED=NO`.

| Target | Command destination | Result | Retained log |
| --- | --- | --- | --- |
| iOS `KnitNote` | `generic/platform=iOS Simulator` | `BUILD SUCCEEDED` | `/tmp/KnitNoteSmartReminders2-20260901-164053-iOS-build.log` — 888885 bytes, SHA-256 `4992fae9bb8ba63f120faffacb78ff18340eecec89807d933ec8a8fb924be6df` |
| macOS `KnitNote` | `platform=macOS` | `BUILD SUCCEEDED` | `/tmp/KnitNoteSmartReminders2-20260901-164053-macOS-build.log` — 260059 bytes, SHA-256 `2901ae6db23f6a08b7cc3e7b0c59b8d45c24b600ba19e690a2bcc022a7e15902` |
| watchOS `KnitNoteWatch` | `generic/platform=watchOS Simulator` | `BUILD SUCCEEDED` | `/tmp/KnitNoteSmartReminders2-20260901-164053-Watch-build.log` — 282381 bytes, SHA-256 `de342cb1a6ef4302e2ed1dca0ef3c69739ea245f95d83ef66a922c35eec03ae5` |

## Static release and privacy audit

Command:

```text
bash AppStore/Verification/release_audit.sh --static-only 2>&1 | tee /tmp/KnitNoteSmartReminders2-20260901-164053-static-audit.log
```

Result: `METADATA CHECK: PASS`, `COMMERCIAL RELEASE CHECK: PASS (offline)`, and `STATIC RELEASE AUDIT: PASS`.

- Log: `/tmp/KnitNoteSmartReminders2-20260901-164053-static-audit.log`
- Bytes: `89`
- SHA-256: `2e24042ee44a08c18bd28150a56be8700a81b2761fc3189eddf25564481a5761`

Static-only mode created no archive or export and performed no upload, submission, or publication.

## Pending manual acceptance gates

- [ ] iPhone: multi-rule creation, same-row queue, defer/skip, decrement, relaunch
- [ ] iPad: adaptive layouts and pattern-reader shortcut
- [ ] Mac: Tab/Shift-Tab, Return, Escape, focus, persistence
- [ ] Apple Watch: online/offline queue, reconnect, haptic, stale refresh
- [ ] Overwrite install: six legacy reminders and unrelated project data retained

Passing automated checks does not replace physical acceptance on any platform. These gates remain unclaimed.
