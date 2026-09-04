# Task 2 — CKSyncEngine protocol adapter and state persistence

## Status

`DONE_WITH_CONCERNS`: the Task 2 focused macOS app suite passes 9/9 and the generic iOS build passes. The required full Swift package suite was run twice; each run completed all 2,044 tests but reported the same pre-existing `PatternShareInboxEnqueuerTests` timing failure. That test passes 1/1 in isolation. Task 2 does not modify the Core package or that share-inbox implementation.

## Implementation

- Added the app-target-only `CloudSyncTransport` protocol, `CloudSyncEvent`, `CloudSyncFailure`, and `CKSyncEngineTransport` actor.
- The live initializer obtains `CKContainer.privateCloudDatabase`, passes the configured custom zone and optional decoded `CKSyncEngine.State.Serialization` into `CKSyncEngine.Configuration`, and uses the actor as delegate. No CloudKit import or target membership was added to `Sources/KnitNoteCore` or the Watch target.
- Added a deterministic `CKSyncEngineDriving` seam used by app tests; no test constructs a live container or contacts CloudKit.
- `FileCloudSyncEngineStateStore` encodes and decodes the actual Codable `CKSyncEngine.State.Serialization`. Save uses the existing durable-file primitive: same-directory temporary file, complete write, file `fsync`, atomic POSIX rename, then parent-directory `fsync`. Load and save reject symbolic links and non-regular destinations; malformed serialization throws rather than becoming `nil`.
- Account changes cancel and discard only the engine accelerator state and its in-memory mutation bindings. The Plan 1 `FileSyncMutationJournal` is neither injected nor cleared, and the regression test verifies its mutation survives.
- Scheduling validates each mutation, validates save records through `CloudRecordCodec`, deduplicates only identical mutation IDs, and maintains a FIFO per `SyncEntityID`. Exactly one intent per record is represented in CKSyncEngine; acknowledgment emits the matching mutation ID and promotes the next queued intent. Restart rescheduling binds the journal mutation to an equivalent serialized engine pending change without duplicating it, while conflicting stale engine intent is deterministically replaced by journal authority.
- `nextRecordZoneChangeBatch` filters pending changes with `context.options.scope`, filters to the configured zone, and caps each request at 250 before using `CKSyncEngine.RecordZoneChangeBatch(pendingChanges:recordProvider:)`.
- Fetch callbacks preserve CloudKit callback order. Transient CloudKit errors are surfaced as retryable failures with retry-after metadata and no competing retry loop; server-record-changed, quota, invalid arguments, authentication, token, and zone failures remain explicit for Task 3 policy.
- Stale callbacks from a discarded live engine are rejected by engine identity after account change.

## Files

- `KnitNote/CloudSync/CloudSyncEngineStateStore.swift`
- `KnitNote/CloudSync/CloudSyncEngineTransport.swift`
- `Tests/KnitNoteAppTests/CloudSyncEngineTransportTests.swift`
- `KnitNote.xcodeproj/project.pbxproj`
- `.superpowers/sdd/2026-09-02-cross-device-sync-2-cloudkit-assets/task-2-report.md`

## TDD evidence

### Initial RED

Command:

```sh
xcodebuild test -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteTask2-RED -only-testing:KnitNoteAppTests/CloudSyncEngineTransportTests CODE_SIGNING_ALLOWED=NO
```

Result: exit 65 before production code existed. The compiler failed the new tests with the expected missing symbols, including `Cannot find type 'CKSyncEngineDriving' in scope` and `Cannot find 'FileCloudSyncEngineStateStore' in scope`.

### Durability regression RED

After self-review identified that POSIX rename could otherwise replace a symbolic-link destination, a regression was added and run as the whole focused suite:

```sh
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteTask2-SymlinkRED2 -only-testing:KnitNoteAppTests/CloudSyncEngineTransportTests CODE_SIGNING_ALLOWED=NO
```

Result: exit 65 with exactly `stateSaveRejectsSymlinkInsteadOfReplacingIt` failing. The store was then changed to fail closed before the durable write.

### Final GREEN

Command:

```sh
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteTask2-FocusedFinal -only-testing:KnitNoteAppTests/CloudSyncEngineTransportTests CODE_SIGNING_ALLOWED=NO
```

Result: exit 0. `xcresulttool` summary for `/tmp/KnitNoteTask2-FocusedFinal/Logs/Test/Test-KnitNote-2026.09.04_08-19-18-+0800.xcresult`:

```json
{"passedTests":9,"failedTests":0,"totalTestCount":9,"result":"Passed"}
```

The nine tests cover real state-file durability boundaries and round-trip decoding, malformed and unsafe state files, fetched callback order, account/journal separation, same-record FIFO identity, restart idempotence, scope/250 batching, and CloudKit failure mapping.

## Required validation

### Swift package suite

First command:

```sh
swift test --scratch-path /tmp/KnitNoteTask2-SwiftFinal
```

Result: exit 1 after completing 2,044 tests in 155 suites in 351.407 seconds, with one issue. The failure was the pre-existing `PatternShareInboxEnqueuerTests.cancellationDuringCandidateCopyPublishesNothingAndCleansEveryArtifact`: `copyStarted.wait(timeout: .now() + 2)` returned `.timedOut` instead of `.success`.

Isolation command:

```sh
swift test --scratch-path /tmp/KnitNoteTask2-SwiftFinal --filter PatternShareInboxEnqueuerTests.cancellationDuringCandidateCopyPublishesNothingAndCleansEveryArtifact
```

Result: exit 0; 1 test in 1 suite passed in 0.010 seconds.

Fresh full rerun:

```sh
swift test --scratch-path /tmp/KnitNoteTask2-SwiftRerun
```

Result: exit 1 after completing 2,044 tests in 155 suites in 340.897 seconds with one issue. It reproduced the same full-suite timing concern; the package output otherwise completed its suites. Task 2 adds only app-target sources/tests, so none of these new files are compiled into `KnitNoteCorePackageTests`.

### Generic iOS build

The sandboxed attempt could not access local CoreSimulator/watchsimulator runtime assets. The same isolated build was rerun with approved host access:

```sh
xcodebuild build -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/KnitNoteTask2-iOSFinalOutsideSandbox CODE_SIGNING_ALLOWED=NO
```

Result: exit 0 with no diagnostics.

### Static checks

- `git diff --check` — pass, no output.
- `plutil -lint KnitNote.xcodeproj/project.pbxproj` — `KnitNote.xcodeproj/project.pbxproj: OK`.
- `rg -n '^import CloudKit' Sources/KnitNoteCore` — exit 1 with no matches, as required.
- Project membership inspection places the two production files only in the `KnitNote` Sources phase and their test only in `KnitNoteAppTests`; there is no Watch membership.
- Branch/base recheck: `docs/cross-device-sync-design` at task base `5d8396b1a10630066ab4168ce818420efdef0665` before this task commit.

## Self-review

- **State authority:** CKSyncEngine serialization is treated only as an accelerator. A missing file yields `nil`; corrupt or unsafe files throw. The adapter never creates, edits, acknowledges, or clears the Plan 1 journal.
- **Mutation identity:** the FIFO is keyed by record identity but retains every distinct `mutationID` and intent. An engine success can acknowledge only the current queue head with matching save/delete intent, and later work is not handed to CKSyncEngine until then.
- **Crash restart:** a restored pending change and the journal-rescheduled head are matched by record ID and intent; equal state is reused without another add. The journal remains the source of payload and identity.
- **Batch correctness:** ordering is deterministic, caller scope is applied before the 250 cap, foreign zones are rejected, and save providers derive records only from the current queue heads.
- **Error policy:** no manual sleeps, backoff, or automatic retry loop was added. CKSyncEngine retains transport scheduling while Task 3 receives typed policy events.
- **Scope:** no entitlement, schema deployment, development-container write, lifecycle wiring, UI wiring, or Watch code was added.

## Concerns

- The full Swift package suite has the unrelated load-sensitive share-inbox timing failure described above. It is independently green and was already present in the Task 1 report at the task base. Focused Task 2 tests and both target compilation paths are green.
- Live CloudKit network behavior, container writes, schema creation, and account transitions were intentionally not exercised because they are outside this task and would violate deterministic-test and no-development-write constraints.

---

## Fix round 1/5 — 2026-09-04

### Amended status

`DONE_WITH_CONCERNS`: all four Critical and five Important review findings are addressed. The amended focused macOS suite passes 29/29 and the required generic iOS build passes. Per the fix-round instruction, the full package suite was not rerun because every amended production/test file remains app-target-only; the original Task 2 package evidence and its isolated pre-existing timing concern remain recorded above.

### Review findings addressed

- Fetched record callbacks now carry an explicit batch UUID. State serializations that arrive after a fetched callback remain deferred behind every unacknowledged batch that preceded them; acknowledgements may arrive out of order, but only the newest serialization whose required batches are all acknowledged is atomically persisted. Ending the event stream synchronously invalidates the generation and detaches the engine before cancellation, without persisting held state.
- Restored CKSyncEngine record changes are not send-authoritative. Batching remains disabled until journal replay is explicitly finished and the custom zone is ready, and every save/delete is filtered against the exact current journal queue head. Finishing replay issues one zone-scoped CKSyncEngine send so an earlier gated automatic request is deterministically retriggered.
- Every save batch record carries `syncMutationID` and a fresh `syncAttemptID`; returned saves and failed saves must match both the active attempt and queue head before changing durable state or acknowledging the mutation. Delete success is bound to the active delete attempt and holds successor batching until CKSyncEngine's `didSendChanges` cycle boundary, preventing duplicate delete callbacks from consuming a successor. Save→save and save→delete→save duplicate callback regressions are covered.
- Account reset now bumps the generation and detaches the engine, queue, attempts, deferred inbound checkpoints, replay gate, and zone readiness before the cancellation await. Every engine suspension point rechecks generation, delegate entry is engine-identity gated, and a failed serialized-state clear permanently blocks restart for that transport instance.
- CKRecord system fields are durably stored per account and configured zone. Outbound saves rebuild from the stored system-field record before replacing application fields; fetched, saved, and server-conflict records advance the stored base, while fetched or sent deletions remove it before delivery/acknowledgement.
- The driver now models pending database changes. Start queues `.saveZone` for only the configured custom zone, database callbacks publish zone-ready/zone-deleted lifecycle events, record sending is zone-gated, and automatic/manual fetch and send options are limited to that zone.
- Permanent mutation failures publish the exact queue-head mutation ID and require explicit retirement or replacement. Retirement removes stale CKSyncEngine pending state; retryable failures leave the journal head intact for CKSyncEngine-managed retry. `accountTemporarilyUnavailable` maps to retryable in direct and callback paths.
- Both serialized engine state and CKRecord system fields use the shared descriptor-relative atomic file primitive: a held `O_DIRECTORY | O_NOFOLLOW` parent descriptor, `openat`/`fstatat`, same-directory temporary creation, file `fsync`, `renameat`, and parent-directory `fsync`. Destination symlinks, rename-boundary swaps, and parent-path swaps are covered with real filesystem tests.

### Strict TDD evidence

All commands below ran from the linked Task 2 worktree and used isolated DerivedData under `/tmp`.

#### Inbound acknowledgement and termination

```sh
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteTask2Fix1-InboundRED -only-testing:KnitNoteAppTests/CloudSyncEngineTransportTests CODE_SIGNING_ALLOWED=NO
```

Result: exit 65 (expected RED). The compiler reported the missing identified `.fetched(batchID:records:deleted:)` case and missing `acknowledgeFetchedBatch` API.

The same focused command with `-derivedDataPath /tmp/KnitNoteTask2Fix1-InboundGREEN` exited 0 after implementing deferred serialization and stream-termination invalidation.

#### Journal binding, zone lifecycle, and scoped batching

```sh
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteTask2Fix1-ReplayZoneRED -only-testing:KnitNoteAppTests/CloudSyncEngineTransportTests CODE_SIGNING_ALLOWED=NO
```

Result: exit 65 (expected RED) with missing replay-finish/zone-lifecycle APIs and fetch-scope support. The first GREEN run correctly exposed that the old 250-record test supplied unbound changes; after binding those changes to journal mutations, `/tmp/KnitNoteTask2Fix1-ReplayZoneGREEN2` exited 0.

#### Attempt identity, failed-head resolution, and retry mapping

```sh
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteTask2Fix1-AttemptFailureRED -only-testing:KnitNoteAppTests/CloudSyncEngineTransportTests CODE_SIGNING_ALLOWED=NO
```

Result: exit 65 (expected RED) because attempt identity and failed-head resolution did not exist. Compile/test iterations at `AttemptFailureGREEN` through `AttemptFailureGREEN3` exposed the new zone-ready event ordering and the need for one-shot attempts. `/tmp/KnitNoteTask2Fix1-AttemptFailureGREEN4` exited 0 after the tests and implementation reflected the real lifecycle.

#### Descriptor-relative stores and durable system fields

```sh
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteTask2Fix1-StoresRED -only-testing:KnitNoteAppTests/CloudSyncEngineTransportTests CODE_SIGNING_ALLOWED=NO
```

Result: exit 65 (expected RED) with the system-field store/initializer absent. The first GREEN compile identified the required `@Sendable` synchronized durability recorder; `/tmp/KnitNoteTask2Fix1-StoresGREEN2` then exited 0. Added saved/conflict/delete round-trip and system-field symlink characterization tests passed in `/tmp/KnitNoteTask2Fix1-SystemTransitionsRED` (the behaviors were already implemented by that RED/GREEN slice).

#### Synchronous account invalidation and suspended operations

```sh
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteTask2Fix1-GenerationRED -only-testing:KnitNoteAppTests/CloudSyncEngineTransportTests CODE_SIGNING_ALLOWED=NO
```

Result: exit 65 (expected RED) with missing `staleOperation` and `accountResetIncomplete` transitions. `/tmp/KnitNoteTask2Fix1-GenerationGREEN` exited 0 after generation checks, pre-await detachment, and restart blocking were implemented.

The controllably suspending batch-materialization regression first failed at compile time in `/tmp/KnitNoteTask2Fix1-BatchRaceRED` because the `recordMaterializer` seam did not exist. After adding the seam, the first GREEN compile caught a Swift 6 concurrent mutable capture; converting it to an immutable snapshot produced exit 0 at `/tmp/KnitNoteTask2Fix1-BatchRaceGREEN3`.

#### Additional self-review RED/GREEN slices

```sh
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteTask2Fix1-ReplayKickRED3 -only-testing:KnitNoteAppTests/CloudSyncEngineTransportTests CODE_SIGNING_ALLOWED=NO
```

Result: exit 65 with exactly `finishingJournalReplayTriggersOneConfiguredZoneSend()` failing. A zone-scoped send kick was added; the consolidated `/tmp/KnitNoteTask2Fix1-ReplayKickGREEN` suite exited 0.

`/tmp/KnitNoteTask2Fix1-FetchedDeleteRED` exited 65 with exactly `fetchedDeletionRemovesDurableSystemFieldsBeforeDelivery()` failing. Removing stored fields on fetched deletion made the next consolidated suite green.

`/tmp/KnitNoteTask2Fix1-FailedRetireRED` exited 65 with exactly `retiringFailedHeadRemovesItsEnginePendingChange()` failing. Removing the obsolete engine pending change during explicit retirement made the next consolidated suite green.

### Final focused macOS verification

```sh
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteTask2Fix1-FocusedFinal2 -only-testing:KnitNoteAppTests/CloudSyncEngineTransportTests CODE_SIGNING_ALLOWED=NO
```

Result: exit 0. `xcresulttool` summary for `/tmp/KnitNoteTask2Fix1-FocusedFinal2/Logs/Test/Test-KnitNote-2026.09.04_09-19-20-+0800.xcresult`:

```json
{"passedTests":29,"failedTests":0,"totalTestCount":29,"result":"Passed"}
```

### Generic iOS verification

The sandboxed command below exited 65 because Xcode could not read any installed `watchsimulator` runtime while compiling the embedded Watch target:

```sh
xcodebuild build -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/KnitNoteTask2Fix1-iOSFinal CODE_SIGNING_ALLOWED=NO
```

The identical build was rerun with approved host access and a fresh isolated path:

```sh
xcodebuild build -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/KnitNoteTask2Fix1-iOSFinal2OutsideSandbox CODE_SIGNING_ALLOWED=NO
```

Result: exit 0 with no diagnostics.

### Static checks

- `git diff --check` — exit 0, no output.
- `plutil -lint KnitNote.xcodeproj/project.pbxproj` — exit 0, `KnitNote.xcodeproj/project.pbxproj: OK`.
- `rg -n '^import CloudKit' Sources/KnitNoteCore` — exit 1 with no matches, as required.
- Project membership contains one Sources-phase entry for each app-only CloudSync file and no Watch Sources-phase entry.
- Branch/base before the fix commit: `docs/cross-device-sync-design` at `c79de1f03fa635e3d48c02be703ac5b2c6a7c8f9`.

### Fix-round files

- `KnitNote/CloudSync/CloudSyncEngineTransport.swift`
- `KnitNote/CloudSync/CloudSyncEngineStateStore.swift`
- `KnitNote/CloudSync/CloudRecordSystemFieldsStore.swift` (new)
- `Tests/KnitNoteAppTests/CloudSyncEngineTransportTests.swift`
- `KnitNote.xcodeproj/project.pbxproj`
- `.superpowers/sdd/2026-09-02-cross-device-sync-2-cloudkit-assets/task-2-report.md`

### Fix-round self-review

- Rechecked all nine review findings against the amended implementation and deterministic tests. Journal ownership remains outside this type; only the serialized CKSyncEngine accelerator state is cleared on account change.
- State serialization cannot advance past an unacknowledged fetched batch. Every outgoing record/delete is an exact current queue head, and save acknowledgements consume a one-shot mutation/attempt identity.
- The account generation is checked after every driver/materializer await. Live delegate callbacks are rejected unless their `CKSyncEngine` object identity is still attached.
- Durable system-field writes/removals occur before matching delivery/acknowledgement, and callback identity is validated before a returned save may overwrite the stored base.
- No entitlement, container write, schema deployment, lifecycle/UI wiring, Core-package CloudKit import, or Watch membership was added.

### Fix-round concerns

- Live CloudKit networking remains intentionally unexercised. The deterministic driver and real CloudKit value types cover adapter behavior without writing to a development container.
- CKSyncEngine delete-success callbacks expose a record ID rather than caller fields. The adapter therefore binds deletion to the one active delete attempt and delays any successor batch until the documented `didSendChanges` cycle boundary; the save→delete→save duplicate-callback regression proves the successor is not consumed.
- The full Swift package suite was intentionally not rerun in this fix round under the explicit app-target-only ruling. Its original 2,044-test evidence and unrelated isolated share-inbox timing concern remain above.

---

## Fix round 2/5 — 2026-09-04

### Amended status

`DONE`: every round-two Critical and Important finding is covered by a failing regression observed before its production change and by the final 37/37 focused suite. The generic iOS build and static target-boundary checks also pass.

### Review findings addressed

- **Critical / original inbound acknowledgement #1:** fetched callbacks now decode and validate the entire callback before mutating adapter durability. System-field saves and removals are committed together through one atomic envelope replacement. A decode, validation, save, or removal failure emits no acknowledgeable fetched batch, latches inbound durability failure, and prevents later engine serialization from being persisted.
- **Important / original durable system fields #5:** the real system-field store now supports transactional mixed save/remove batches and account-scoped `removeAll`. Existing real-store tests cover saved/conflict bases and successful fetched/sent deletion; the new failure tests prove that neither save nor deletion failure can advance the engine checkpoint.
- **Important / original zone lifecycle #6:** zone deletion closes the record gate, advances the zone epoch, invalidates active attempts, durably removes all bases for the active account, queues `.saveZone`, and kicks a configured-zone send. A saved/fetched zone opens the gate only once and kicks one scoped send; a failed reset cannot reopen it.
- **Important / original failed-head transition #7:** replacement of a failed queue head rebinds the exact mutation and deterministically kicks one configured-zone send. Retirement still removes obsolete engine pending work; retryable CK errors remain under CKSyncEngine retry policy.
- Stream termination now flips a lock-backed nonisolated terminal latch synchronously in `AsyncStream.onTermination`, before asynchronous engine cleanup can suspend. All public use and restart paths fail with `.terminated`, and delegate/batch callbacks ignore the detached transport.
- Record-zone batch materialization captures both account generation and zone epoch. After each materializer suspension, after CKSyncEngine batch construction, and before installing attempts, it revalidates zone readiness plus the exact queue-head mutation/intent and absence of a newer attempt. Zone deletion and a competing batch therefore invalidate stale work.
- Live transport construction now requires an injected nonempty opaque account identity whenever the durable system-field store is present. Startup fails closed before engine activation for a missing or whitespace-only key; no Apple ID email is queried or stored.
- Gate reopening is centralized around one configured-zone send kick: failed-head replacement, first zone-ready transition, and delete-cycle completion are each observable in the deterministic driver and duplicate callbacks do not produce duplicate kicks.

### Strict TDD evidence

All commands ran from the Task 2 worktree with isolated `/tmp` DerivedData and `CODE_SIGNING_ALLOWED=NO`.

#### Transactional fetched durability

```sh
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteTask2Fix2-InboundDurabilityRED -only-testing:KnitNoteAppTests/CloudSyncEngineTransportTests CODE_SIGNING_ALLOWED=NO
```

Result: exit 65 (expected RED). Exactly the new real-store save-failure and deletion-failure regressions failed because the adapter emitted a fetched batch and allowed a later state update despite the system-field store failure.

The first GREEN command at `/tmp/KnitNoteTask2Fix2-InboundDurabilityGREEN` encountered a local Xcode test-runner communication failure before results. The identical command rerun with approved host access and fresh `/tmp/KnitNoteTask2Fix2-InboundDurabilityGREEN2` exited 0.

#### Terminal latch

```sh
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteTask2Fix2-TerminationRED -only-testing:KnitNoteAppTests/CloudSyncEngineTransportTests CODE_SIGNING_ALLOWED=NO
```

Result: exit 65 (expected RED); the test could not compile because the explicit `.terminated` transition did not exist. `/tmp/KnitNoteTask2Fix2-TerminationGREEN` exited 0 after adding the synchronous latch and guarded entry points.

#### Required account identity

```sh
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteTask2Fix2-AccountIdentityRED -only-testing:KnitNoteAppTests/CloudSyncEngineTransportTests CODE_SIGNING_ALLOWED=NO
```

Result: exit 65 (expected RED); the missing `.missingAccountIdentity` contract exposed that an engine could activate without a durable account namespace. `/tmp/KnitNoteTask2Fix2-AccountIdentityGREEN` exited 0 after startup validation and required live-initializer identity.

#### Zone and queue gate liveness

```sh
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteTask2Fix2-GateKickRED -only-testing:KnitNoteAppTests/CloudSyncEngineTransportTests CODE_SIGNING_ALLOWED=NO
```

Result: exit 65 (expected RED). Driver-observable assertions failed for the missing zone-ready, zone-deletion/bootstrap, delete-cycle, and failed-head replacement send kicks. `/tmp/KnitNoteTask2Fix2-GateKickGREEN` exited 0 after adding one-shot scoped kicks and durable zone reset behavior.

#### Suspended batch invalidation

```sh
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteTask2Fix2-BatchEpochRED -only-testing:KnitNoteAppTests/CloudSyncEngineTransportTests CODE_SIGNING_ALLOWED=NO
```

Result: exit 65 (expected RED). Both new controllably suspended tests failed: a zone-deleted batch survived materialization, and an older batch could overwrite the newer attempt. `/tmp/KnitNoteTask2Fix2-BatchEpochGREEN` exited 0 after epoch/head/attempt revalidation.

### Final focused macOS verification

```sh
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteTask2Fix2-FocusedFinal -only-testing:KnitNoteAppTests/CloudSyncEngineTransportTests CODE_SIGNING_ALLOWED=NO
```

Result: exit 0. `xcresulttool` summary for `/tmp/KnitNoteTask2Fix2-FocusedFinal/Logs/Test/Test-KnitNote-2026.09.04_09-46-17-+0800.xcresult` reported `passedTests: 37`, `failedTests: 0`, `totalTestCount: 37`, `result: Passed`.

### Generic iOS verification

```sh
xcodebuild build -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/KnitNoteTask2Fix2-iOSFinal CODE_SIGNING_ALLOWED=NO
```

Result: exit 0 with no diagnostics.

### Static checks

- `git diff --check` — exit 0, no output.
- `plutil -lint KnitNote.xcodeproj/project.pbxproj` — exit 0, `KnitNote.xcodeproj/project.pbxproj: OK`.
- `rg '^import CloudKit' Sources/KnitNoteCore` — exit 1 with no matches, as required.
- Branch/base recheck: `docs/cross-device-sync-design` at `bf95e68d3b20cd83c9e732f2ef50a057610c1788` before this fix commit.
- The full package suite was not rerun under the explicit app-target-only fix-round ruling; prior package evidence remains above.

### Fix-round files

- `KnitNote/CloudSync/CloudSyncEngineTransport.swift`
- `KnitNote/CloudSync/CloudRecordSystemFieldsStore.swift`
- `Tests/KnitNoteAppTests/CloudSyncEngineTransportTests.swift`
- `.superpowers/sdd/2026-09-02-cross-device-sync-2-cloudkit-assets/task-2-report.md`

### Fix-round self-review

- Rechecked each round-two finding against production paths and a regression that failed first. Inbound callbacks cannot expose an acknowledgement before their system-field transaction succeeds, and a failed callback permanently blocks serialization for that engine lifetime.
- The terminal latch is visible without actor scheduling, so cancellation races cannot recreate the engine. Generation and zone epoch checks reject suspended or detached operations before attempt installation.
- Zone deletion clears only the active account's configured-zone bases. It never owns or clears the Plan 1 mutation journal; queued mutations remain gated until the replacement zone is ready.
- Each reopened gate causes at most one immediate zone-scoped send in the tested transition. Retryable errors are surfaced without a competing retry loop.
- No entitlements, CloudKit schema/container writes, lifecycle/UI wiring, Core-package import, or Watch membership were added.

### Fix-round concerns

- Live CloudKit networking remains intentionally unexercised; the suite uses real CloudKit value types, real descriptor-relative stores, and a deterministic driver without contacting a container.
- Stream termination is intentionally final for a transport instance. A caller that needs synchronization again must construct a new transport and stream.
- The full Swift package suite was intentionally not rerun because amended files remain app-target-only; the earlier recorded package evidence and unrelated timing concern are unchanged.
