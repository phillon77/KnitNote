# Smart Knitting Reminders 2.0 — Task 10 Final Verification

Date: 2026-09-01 (Asia/Taipei)

## Candidate identity and scope

- Branch: `docs/knitnote-smart-reminders-2`
- Verified source SHA (before this evidence-only update commit): `bdf475df24df9a56117cee4803ade6a034abcee3`
- Development identity confirmed from `project.yml`: `1.5.1 (11)` for the shipping targets; Task 10 did not change it.
- Automated status: **PASS.** All automated gates below were freshly run on the verified source SHA, with explicit retained pipeline status `0`.
- Scope boundary: evidence and acceptance preparation only. No archive, export, upload, submission, publication, signing, pricing, marketing-version, or build-number change was made; this is not physical-device acceptance.

## Final-fix findings closed

The `bdf475d` final-fix source closes the reviewed findings and the focused suites below exercise them:

- Reminder occurrence scheduling is capped at **1,000**; cap, direct-jump, and overflow tests preserve atomic state on rejection.
- A migrated secondary reminder is operational after reload and triggers only from its owning counter; the UI exposes localized edit-only access rather than new secondary creation.
- Editing an in-progress reminder presents the proposed summary and requires explicit confirmation before replacing progress; a concurrent revision rejects without overwrite.
- Watch queue lifecycle and offline state are covered: a visible queue claims haptics once, per-reminder pending actions remain distinct, persisted operations replay safely, and hidden surfaces cannot consume a visible queue's haptic lease.
- Skip is strict: initial and still-awaiting occurrences reject without mutation, while eligible deferred occurrences retain exact identity and revision handling.
- Schema 4 rejects a project missing its required reminder collection instead of normalizing malformed data.
- The prior stale-ID refinement, Task 3 public backup-restore overflow rejection, and Task 7 crash-boundary recovery remain green. Root Task 6 and Task 8 reports were restored by the final-fix source; Task 10 did not modify root reports.

## Generated-project and repository checks

| Command | Result |
| --- | --- |
| `git diff --check` before verification | exit 0; silent |
| `xcodegen generate` | exit 0 |
| `git diff --exit-code -- KnitNote.xcodeproj/project.pbxproj` | exit 0; generated PBX file remained byte-stable |

## Status-preserving pipeline wrapper

Every test, build, and audit below used this exact wrapper, substituting its command and log path:

```text
set -o pipefail
<command> 2>&1 | tee <log-path>
TASK10_STATUS=$?
printf '\nCOMMAND_EXIT_STATUS=%s\n' "$TASK10_STATUS" >> <log-path>
exit "$TASK10_STATUS"
```

Each retained log contains exactly one `COMMAND_EXIT_STATUS=0` line. Byte counts and SHA-256 values include it; success is established by that exit record, not by a display marker alone.

## Full Swift package regression

```text
swift test --disable-sandbox 2>&1 | tee /tmp/KnitNoteSmartReminders2-20260901-182744-full-swift-test.log
```

Result: `Test run with 1737 tests in 140 suites passed after 317.338 seconds.` The final log exit record is `COMMAND_EXIT_STATUS=0` and no Swift Testing issue marker is present.

- Log: `/tmp/KnitNoteSmartReminders2-20260901-182744-full-swift-test.log`
- Bytes: `381338`
- SHA-256: `a7d83dd83c11b7479cb34575404b968ed3455c0268d39d92b33f3776c95bcca0`

## Expanded focused contracts

UI, reader, secondary migration, edit confirmation, Watch-view, and localization command:

```text
swift test --disable-sandbox --filter 'PatternLibraryStoreTests|KnittingReminderViewContractTests|WatchCounterViewContractTests|LocalizationContractTests|KnittingReminderPresentationTests|ProjectCounterViewContractTests' 2>&1 | tee /tmp/KnitNoteSmartReminders2-20260901-182744-reminder-contracts.log
```

Result: `202 tests in 7 suites passed after 1.100 seconds`; `COMMAND_EXIT_STATUS=0`.

- Log: `/tmp/KnitNoteSmartReminders2-20260901-182744-reminder-contracts.log`
- Bytes: `37673`
- SHA-256: `801800bbbb28c8646d63f7b55867f0c02bd5c1076fc6d4a7c462474f409c881c`

Core, occurrence-cap, migration, schema-4, durable Watch, strict-skip, lifecycle, and offline command:

```text
swift test --disable-sandbox --filter 'KnittingReminderMigrationTests|KnittingReminderStoreTests|KnittingReminderTests|WatchCommandApplicationTests|WatchSyncPersistenceTests|WatchOptimisticStateTests|WatchSyncModelsTests' 2>&1 | tee /tmp/KnitNoteSmartReminders2-20260901-182744-reminder-migration-contracts.log
```

Result: `195 tests in 7 suites passed after 0.573 seconds`; `COMMAND_EXIT_STATUS=0`.

- Log: `/tmp/KnitNoteSmartReminders2-20260901-182744-reminder-migration-contracts.log`
- Bytes: `39818`
- SHA-256: `2a28f436502c212ae2cd2d8bc2a76c1b2477f73861013809c3ed6f358534927f`

## Fresh unsigned builds

Each build used a unique clean timestamped derived-data path, `CODE_SIGNING_ALLOWED=NO`, the status-preserving wrapper, and exactly one retained exit line.

| Target | Destination | Result | Retained log |
| --- | --- | --- | --- |
| iOS `KnitNote` | `generic/platform=iOS Simulator` | `BUILD SUCCEEDED`; `COMMAND_EXIT_STATUS=0` | `/tmp/KnitNoteSmartReminders2-20260901-182744-iOS-build.log` — 888905 bytes, SHA-256 `3d8330fee750f34ec64e75b322accf6ef9d35a911317c462d86d4226164847fb` |
| macOS `KnitNote` | `platform=macOS` | `BUILD SUCCEEDED`; `COMMAND_EXIT_STATUS=0` | `/tmp/KnitNoteSmartReminders2-20260901-182744-macOS-build.log` — 260081 bytes, SHA-256 `50228ede174d3fae6413549b1ec93a45efd45f169b3a17ae67259778cc0bea9d` |
| watchOS `KnitNoteWatch` | `generic/platform=watchOS Simulator` | `BUILD SUCCEEDED`; `COMMAND_EXIT_STATUS=0` | `/tmp/KnitNoteSmartReminders2-20260901-182744-Watch-build.log` — 282400 bytes, SHA-256 `df2ad27a58d9b0483af43a334c3549db58f84a90d5910bffd1c2c66de9886797` |

### Nonfatal build warnings observed

- AppIntents metadata processors reported `Metadata extraction skipped. No AppIntents.framework dependency found.` in fresh iOS, macOS, and watchOS logs. The iOS log also reports no AppShortcuts found. All wrapped builds still exited 0.
- macOS reported `Using the first of multiple matching destinations` for the same My Mac destination's arm64 and x86_64 variants. The selected build still exited 0.

## Static release and privacy audit

```text
bash AppStore/Verification/release_audit.sh --static-only 2>&1 | tee /tmp/KnitNoteSmartReminders2-20260901-182744-static-audit.log
```

Result: `METADATA CHECK: PASS`, `COMMERCIAL RELEASE CHECK: PASS (offline)`, and `STATIC RELEASE AUDIT: PASS`; `COMMAND_EXIT_STATUS=0`.

- Log: `/tmp/KnitNoteSmartReminders2-20260901-182744-static-audit.log`
- Bytes: `112`
- SHA-256: `c017bec76a50eca19e4553b5f0910fe888a951999e3719768a62cd3b42c78f09`

Static-only mode created no archive or export and performed no upload, submission, or publication.

## Pending manual acceptance gates

- [ ] iPhone: multi-rule creation, same-row queue, defer/skip, decrement, relaunch
- [ ] iPad: adaptive layouts and pattern-reader shortcut
- [ ] Mac: Tab/Shift-Tab, Return, Escape, focus, persistence
- [ ] Apple Watch: online/offline queue, reconnect, haptic, stale refresh
- [ ] Overwrite install: six legacy reminders and unrelated project data retained

Passing automated checks does not replace physical acceptance on any platform. All five gates remain unclaimed.
