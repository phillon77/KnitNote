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
