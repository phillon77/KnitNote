# Backup test handshake verification

## Scope

Base `f65b9b682f79f2b05c12a0e3a7ad8c25b26acc3b`, branch `docs/cross-device-sync-design`, version 1.7.0 (13). Implements the user's approved test-only follow-up to `2026-09-06-backup-concurrent-timeout-diagnosis.md`.

Only `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift` changes executable code. No production source, project configuration, data format, account lifecycle, cloud activation, signing, installation, push or submission changes.

## Behavior

- The export integration test now covers normal start and a deliberate 11-second pre-start delay.
- Its observer uses a buffered asynchronous one-shot result, with first-result selection under the existing lock. It does not occupy a Swift executor worker while waiting for the block event.
- The existing ten-second interval is scheduled on the global dispatch queue immediately before the actual export call, not before the MainActor task is scheduled. Export completion or error before reaching the metadata blocker emits failure. Signals received before the waiter are retained; completion cannot overwrite success.
- Failed admission to the assertion phase now uses `#require`, releases the semaphore, cancels and awaits export, and then propagates the failure before deleting the fixture. Successful paths retain the original real-store mutation rejection and post-export mutation checks.
- Other callers of the blocker keep their original synchronous wait. No suite was globally serialized.
- The ten-second callback is scheduling-dependent; it is not a hard process kill. Before-start stalls and a detached production operation that never returns still require the outer bounded runner. No claim of general async drain is made.

## RED/GREEN evidence

Commands below used the inspected `/tmp/task4-run-bounded.py` runner, separate non-overwritten logs, and real temporary-store fixtures.

1. Initial delayed-start RED attempt `/tmp/backup-handshake-red.log` exposed that the old nonfatal expectation continued into later backup work after timing out. Controller stopped the specifically identified helper and Swift process; exit241 / runner status-15. This is an interrupted diagnostic, not a pass or clean RED proof.
2. After adding fail-fast cleanup but retaining the old wait, `swift test --filter exportSerializesProjectYarnAndJournalMutations` exited1: delayed-start=true failed the original wait after10.053s (total30.410s). Log `/tmp/backup-handshake-red-bounded.log`, SHA256 `6aa1e2c7d02fbee8ed22c179574eac853da37b1cf8cf881eb3aeb7c20977d4a8`.
3. New asynchronous observer, same command: exit0,1test/1suite with both parameter cases passed after11.520s (total31.269s). Log `/tmp/backup-handshake-green.log`, SHA256 `1a4477495a0d546eea0272ef4e66883e8975da62694daf765dff026d66e4a95a`.
4. `swift test --filter 'StoreBackupHandshakeTests|exportSerializesProjectYarnAndJournalMutations'`: exit0,5tests/2suites passed after11.638s (total31.151s). Includes buffered first-result precedence, completion without block, started-operation timeout, and waiter cancellation. Log `/tmp/backup-handshake-edge-green.log`, SHA256 `4a2cb30e7720158420301f0408d4efbe7f5e7e65e8684fa7fe3d00dd7db6b0c9`.
5. Mutation test: temporarily removed only `try beginDataOperation()` from production `exportBackup`; same integration command exited1 with14issues across both parameter cases, test11.544s/total22.644s. Missing operation state and missing mutation rejection were detected. Log `/tmp/backup-handshake-gate-mutation-red.log`, SHA256 `3792243a3b49ded4bae96d3c2f4c2daeb2e46ee7e404e41227166015595fe1ef`. Restored the line exactly and verified `git diff --exit-code -- Sources KnitNote.xcodeproj` exit0 before final regression.

## Independent review

Read-only reviewer `backup_handshake_review` found no Critical/Important issue in the test-only change. Minor coverage limitation: helper tests simulate early completion and cancellation directly rather than exercising an actual export error before metadata or integration cancellation cleanup. This is recorded, not claimed covered. The reviewer also explicitly retained the external process deadline requirement for a never-returning detached operation. No review task ran tests or changed files.

## Final concurrent verification

`swift test --filter 'JSONProjectStore|SyncConflict|SyncRemoteBatch|SyncPublication|SyncDeletion|Backup|Watch'` completed **exit0,819tests/48suites passed**, test172.707s/total184.304s, under the900-second runner bound. The export test's two parameter cases passed (137.317s including concurrent scheduling). No `warning:` or failed-test marker appeared in this log.

Log `/tmp/backup-handshake-concurrent-final.log`, SHA256 `4614b1a5e7c94843298f30b8b1d310d8041c80e582f949a5a0a370abf4969fc7`.

After this run, `git diff --check` and `git diff --exit-code -- Sources KnitNote.xcodeproj` both exited0. Only the reviewed test file and these two diagnostic/verification documents differ from the base. The observed concurrent blocker regression is resolved in this tested command; earlier failed runs remain historical evidence and are not reclassified as passes. This is one successful broad concurrent run, not a claim of universal scheduling stability. No new full-Core or platform-build result is claimed by this report, and the prior full2478-test serial result belongs to its prior test tree.

Account-session integration, async drain, live cloud/device validation and release approval remain separate work. No push or submission occurred.
