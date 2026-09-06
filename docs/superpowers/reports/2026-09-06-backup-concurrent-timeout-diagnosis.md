# Concurrent backup timeout: event-timing diagnosis

## Scope and candidate

2026-09-06, branch `docs/cross-device-sync-design`, HEAD `f65b9b682f79f2b05c12a0e3a7ad8c25b26acc3b` (source candidate `3be009a`), version 1.7.0 (13).

Diagnosis only: production source and the 10-second semaphore condition were unchanged. Temporary test-only probes were applied for both runs and removed afterward. No release, live store, cloud, account switching, signing, installation or push action.

## Instrumentation

Only `exportSerializesProjectYarnAndJournalMutations` enabled the probe on its `StoreOperationBlocker`. Each event wrote `BACKUP-PROBE <DispatchTime.now().uptimeNanoseconds> <event>` through `FileHandle.standardError.write`. Events were placed before/after fixture construction, at the first statement of the MainActor export task and its defer, before/after the semaphore wait, immediately before the metadata semaphore signal, after its continuation wait, at resume, and immediately after the original wait assertion. No ordering, priority, timeout or assertion was changed. Other blocker instances retained disabled tracing.

## Commands and outcomes

Both commands ran serially using the previously inspected `/tmp/task4-run-bounded.py` wrapper; the commands themselves used Swift Testing's default parallel setting. Neither reached its outer time limit.

1. `swift test --filter 'JSONProjectStore|SyncConflict|SyncRemoteBatch|SyncPublication|SyncDeletion|Backup|Watch'`: exit 1, **815 tests / 47 suites, one issue**, test170.970s / total193.245s, 900-second outer bound. The only issue was the original blocker-wait assertion (temporarily line1969 due to probes). Log `/tmp/backup-admission-probe-current.log`, SHA256 `e0c19379b6dbc523edec27cf047127d187754b7cec9e1c484a1b3545ce865842`.
2. `swift test --filter exportSerializesProjectYarnAndJournalMutations`: exit 0, **1 test / 1 suite**, test0.039s / total1.253s, 300-second outer bound. Log `/tmp/backup-admission-probe-isolated.log`, SHA256 `a228e5ed0bdf75471fc678a1a24217d73e2c925f0bdb8e5da6530f517d470431`.

## Evidence

All times below are nanoseconds on the monotonic clock, not log-arrival times; output was buffered, so wall-clock tail updates are not scheduling evidence.

| Event | Concurrent run | Isolated run |
| --- | ---: | ---: |
| Wait started | 234250197139291 | 234471290341541 |
| Wait timed out | 234260201709125 | none |
| MainActor export task started | 234351792278583 | 234471290381708 |
| Metadata blocker signaled | 234351792624708 | 234471290853791 |
| Wait succeeded | none | 234471290868791 |

In the concurrent run, the wait expired after **10.004570 seconds**, while the export task did not start until **101.595139 seconds** after the wait began. Once started, it reached the metadata blocker in **0.346125 milliseconds**. In isolation, the task started **0.040167 milliseconds** after waiting began and the wait succeeded after **0.527250 milliseconds**. The concurrent run's remaining operation-in-progress and post-export mutation assertions produced no issues.

## Conclusion and limits

The observed failure is a pre-start deadline race in the test: the detached waiter starts its ten-second deadline without evidence that the queued MainActor export task has begun. For this run, it is not evidence that executing backup I/O took ten seconds to reach the blocker. The same fixture and production code pass in isolation.

This does not identify which unrelated workload delayed MainActor execution, prove that the behavior predates the admission changes, or establish that all backup/data-integrity behavior is safe. No historical-source baseline reproduction was performed. The concurrent gate remains unresolved; this is not a repaired or passing acceptance run.

## Recommended next bounded change

Design a test-only start/block handshake that awaits the actual reached-block event rather than measuring unrelated pre-start queue delay. Preserve the mutation-rejection assertions, an outer bounded failure path, cleanup/unblocking, and proof that removing the production operation gate still fails. Validate deliberate delayed task start as well as missing signal/export failure before the full concurrent affected command. Do not merely lengthen the ten-second timeout, globally serialize all tests, weaken assertions, or change production backup behavior based on this evidence alone.
