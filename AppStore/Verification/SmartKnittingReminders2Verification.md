# Smart Knitting Reminders 2.0 — Task 10 Verification

Date: 2026-09-01 (Asia/Taipei)

## Candidate identity and scope

- Branch: `docs/knitnote-smart-reminders-2`
- Verified source SHA (before this evidence-only update commit): `21fdc3f38b992c7a04ceb3d162a6df6b4a5dba4d`
- Development identity confirmed from `project.yml`: `1.5.1 (11)` for the shipping targets; Task 10 did not change it.
- Automated status: **PASS.** Every automated gate below ran afresh on the verified source SHA and records an explicit pipeline exit status of `0`.
- Scope boundary: evidence and acceptance preparation only. This work did not archive, export, upload, submit, publish, alter signing, alter pricing, or claim physical-device acceptance.

## Reviewed regression refinements

- `21fdc3f38b992c7a04ceb3d162a6df6b4a5dba4d` resolves the genuine stale-reminder-identity refinement: the test deletes a real persisted reminder, creates a distinct replacement, then proves the stale manager request rejects atomically without changing either current reminder, counter state, selection, generation, archive bytes, or reopened state.
- Task 3 has no deferred Minor remaining. The earlier public `prepareBackupRestore` overflow fixture already proves that a format-1 version-13 archive with an overflowing derived repeating target returns `invalidArchive` before installation and leaves live archive bytes and published projects unchanged.
- Task 7 crash-boundary coverage remains exercised by the full and focused suites: a reminder at target 1 deferred after a direct jump to 5 persists display target 6, survives a crash after archive save, and recovers the original acknowledgement after restart; the maximum-observed-value case fails closed without a prepared success proof.

## Generated-project and repository checks

| Command | Result |
| --- | --- |
| `git diff --check` before verification | exit 0; silent |
| `xcodegen generate` | exit 0 |
| `git diff --exit-code -- KnitNote.xcodeproj/project.pbxproj` | exit 0; generated PBX file byte-stable |

## Pipeline wrapper

Every test, build, and audit command below used this exact status-preserving wrapper (with the shown command and log path substituted):

```text
set -o pipefail
<command> 2>&1 | tee <log-path>
TASK10_STATUS=$?
printf '\nCOMMAND_EXIT_STATUS=%s\n' "$TASK10_STATUS" >> <log-path>
exit "$TASK10_STATUS"
```

The retained byte counts and SHA-256 values include the final `COMMAND_EXIT_STATUS=0` line. Pipeline success is established from that recorded status, not from a marker alone.

## Full Swift package regression

```text
swift test --disable-sandbox 2>&1 | tee /tmp/KnitNoteSmartReminders2-20260901-171445-full-swift-test.log
```

Result: `Test run with 1720 tests in 140 suites passed after 314.174 seconds.` The log reports `COMMAND_EXIT_STATUS=0` and contains no Swift Testing issue marker.

- Log: `/tmp/KnitNoteSmartReminders2-20260901-171445-full-swift-test.log`
- Bytes: `378250`
- SHA-256: `acde05cdb82450dc17fa8363cc34de7f44d101ecf3da48ae8c104ec4215a9983`

## Focused reminder, migration, Watch, and localization contracts

```text
swift test --disable-sandbox --filter 'PatternLibraryStoreTests|KnittingReminderViewContractTests|WatchCounterViewContractTests|LocalizationContractTests' 2>&1 | tee /tmp/KnitNoteSmartReminders2-20260901-171445-reminder-contracts.log
```

Result: `159 tests in 5 suites passed after 1.087 seconds`; `COMMAND_EXIT_STATUS=0`.

- Log: `/tmp/KnitNoteSmartReminders2-20260901-171445-reminder-contracts.log`
- Bytes: `29806`
- SHA-256: `d4dad9922084da5a4025df910706ef8506c82825952df55811aed4c972552f56`

```text
swift test --disable-sandbox --filter 'KnittingReminderMigrationTests|KnittingReminderStoreTests|KnittingReminderTests|WatchCommandApplicationTests|WatchSyncPersistenceTests' 2>&1 | tee /tmp/KnitNoteSmartReminders2-20260901-171445-reminder-migration-contracts.log
```

Result: `103 tests in 5 suites passed after 0.486 seconds`; `COMMAND_EXIT_STATUS=0`. This includes version-13 every-counter migration without rebinding, backup migration staging/rejection, atomic persistence failures, durable Watch actions, and stale reminder rejection.

- Log: `/tmp/KnitNoteSmartReminders2-20260901-171445-reminder-migration-contracts.log`
- Bytes: `23192`
- SHA-256: `a337d42aa3232143f2dbbc1faa50892f37fb7dfae10d35ad76d68f1a0fe567af`

## Fresh unsigned builds

Each build used a separate clean timestamped derived-data path, `CODE_SIGNING_ALLOWED=NO`, the pipeline wrapper above, and a recorded exit of `0`.

| Target | Destination | Result | Retained log |
| --- | --- | --- | --- |
| iOS `KnitNote` | `generic/platform=iOS Simulator` | `BUILD SUCCEEDED`; `COMMAND_EXIT_STATUS=0` | `/tmp/KnitNoteSmartReminders2-20260901-171445-iOS-build.log` — 888904 bytes, SHA-256 `81762fe818bc69ae7618ffb41a145dba36078ce096bd50d4534bfe7546047386` |
| macOS `KnitNote` | `platform=macOS` | `BUILD SUCCEEDED`; `COMMAND_EXIT_STATUS=0` | `/tmp/KnitNoteSmartReminders2-20260901-171445-macOS-build.log` — 260084 bytes, SHA-256 `0b76616de4450035c668b27cbff3177e70063dfce96a101cc90d3338a6ee274c` |
| watchOS `KnitNoteWatch` | `generic/platform=watchOS Simulator` | `BUILD SUCCEEDED`; `COMMAND_EXIT_STATUS=0` | `/tmp/KnitNoteSmartReminders2-20260901-171445-Watch-build.log` — 282397 bytes, SHA-256 `0e98de6d483e75ac12ba0a822bc2f8c4c488344dfc76e79f818901eab1fbd398` |

### Nonfatal build warnings observed

- AppIntents metadata processors reported `Metadata extraction skipped. No AppIntents.framework dependency found.` in the fresh iOS, macOS, and watchOS logs. The iOS log also reports no AppShortcuts found. These are existing toolchain metadata warnings; all three wrapped build commands exited 0.
- The macOS command reported `Using the first of multiple matching destinations` for the arm64 and x86_64 variants of the same My Mac destination. The selected build still exited 0.

## Static release and privacy audit

```text
bash AppStore/Verification/release_audit.sh --static-only 2>&1 | tee /tmp/KnitNoteSmartReminders2-20260901-171445-static-audit.log
```

Result: `METADATA CHECK: PASS`, `COMMERCIAL RELEASE CHECK: PASS (offline)`, and `STATIC RELEASE AUDIT: PASS`; `COMMAND_EXIT_STATUS=0`.

- Log: `/tmp/KnitNoteSmartReminders2-20260901-171445-static-audit.log`
- Bytes: `112`
- SHA-256: `c017bec76a50eca19e4553b5f0910fe888a951999e3719768a62cd3b42c78f09`

Static-only mode created no archive or export and performed no upload, submission, or publication.

## Pending manual acceptance gates

- [ ] iPhone: multi-rule creation, same-row queue, defer/skip, decrement, relaunch
- [ ] iPad: adaptive layouts and pattern-reader shortcut
- [ ] Mac: Tab/Shift-Tab, Return, Escape, focus, persistence
- [ ] Apple Watch: online/offline queue, reconnect, haptic, stale refresh
- [ ] Overwrite install: six legacy reminders and unrelated project data retained

Passing automated checks does not replace physical acceptance on any platform. These gates remain unclaimed.
