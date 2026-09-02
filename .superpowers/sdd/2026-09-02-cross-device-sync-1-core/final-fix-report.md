# Cross-Device Sync Phase 1 final-fix report

Date: 2026-09-02
Branch: `docs/cross-device-sync-design`
Starting HEAD: `0ea40c70fe85e181caecc2c192a5bcbef08621a2`
Review source: `final-review-findings.md`
Result: all Critical, Important, and Minor findings are fixed in one final-fix wave.

## Scope and boundaries

This wave fixes the Phase 1 core and local-store publication boundary only. It deliberately does not add CloudKit, account lifecycle, an app-level sync toggle, remote transport, conflict-resolution UI, or full backup/restore publication. The default live composition remains sync-disabled; a caller can now inject a sink. A pending or corrupt publication marker still blocks backup restore before any live-tree mutation.

All new core code remains free of CloudKit imports. The generated Xcode project now includes every CloudSync source in both the iOS app and Watch targets, and final generic iOS and watchOS builds pass.

## Architecture decisions

### 1. Immutable mutation binding and journal ownership

- `SyncMutation.save` now owns a validated `SyncRecordVersion`, optional exact `SyncAttachmentSource`, and mutation UUID. It no longer stores only an entity ID or relies on a current-state `SyncRecordProvider` lookup.
- `SyncRecordVersion.versionID` is a UUID derived from the canonical sorted-key encoding of the complete validated record snapshot.
- Attachment bytes are copied into a journal-owned hidden sibling directory before the journal envelope is committed. Copying streams through SHA-256, verifies size and inode stability, fsyncs the file, atomically renames, and fsyncs the directory.
- Staged bytes remain until acknowledgement of the exact `(recordID, mutationID)` identity. Replacements do not delete predecessor bytes.
- Merge accepts pending mutations directly and returns the exact save/save/delete intents in `mutationsToUpload`; it does not reconstruct saves from current state.

### 2. Attachment slot versus content version

- `SyncAttachmentSlot(owner, role, slotID)` identifies the stable semantic location.
- `SyncAttachmentVersion.versionID` derives from slot plus content digest; `conflictGroupID` derives from slot only.
- Replacement lineage uses `replacesVersionID`; self-lineage is rejected.
- Project/yarn/journal/pattern-source/markup projection uses stable slots. The two yarn label positions have distinct `label:0` and `label:1` slots, and markup uses stable page slots.
- Replacing bytes creates a save for the new immutable version and retains the old version. Removal deletes only the current content-version ID.

### 3. Atomic counter and reminder domain

- Counter and knitting-reminder state is encoded as `SyncAtomicDomainValue`, one indivisible versioned value rather than generic per-field LWW data.
- Validators bind domain ID, entity revision, mutation revision, mutation stamp, counter relationship, and record kind.
- Merge chooses the highest domain mutation revision before considering clock/device ordering. Concurrent absolute counter values are never added; the winning stamp selects one complete counter and a deterministic `counterValues` diagnostic is retained.
- Reminder same-revision divergence gives terminal occurrence handling precedence over deferral, then uses the mutation stamp.
- `SyncCounterReminderMergeContext` accepts real `PreparedWatchCommand` and `ProcessedWatchCommandLedger` values. A successfully ledgered prepared command cannot merge back to its pre-application revision; revision exhaustion fails closed.

### 4. Durable publication receipt

- The sidecar is written before archive/artifact commit.
- If a writer writes or renames the expected archive and then throws, matching bytes are treated as locally committed but not durably receipted: state is applied, the marker remains, no sink publication occurs, and later mutations are blocked with `.pendingRepair`.
- Restart or explicit repair revalidates the exact marker and committed evidence before publishing.

### 5. Versioned deletion cascade

- Deletion cascade is a `SyncFieldVersion<[SyncEntityID]>` paired with the winning `deletedAt` stamp.
- A newer restore can explicitly clear an older cascade; merge no longer unions old deletion intent forever.
- Per-kind allowed targets, duplicate targets, live non-empty cascades, stamp mismatch, Yarn exclusion, and transitive ownership are validated.
- Batch validation rejects missing/unrelated cascade targets and duplicate record IDs without trapping. Wire records are validated before collection canonicalization so malformed duplicates cannot be silently erased.

### 6. Live factory injection

- Both public `JSONProjectStore.live` entry points accept a sink with a disabled default.
- The sink is forwarded through normal startup, deferred recovery, rollback, and every error-store branch.
- No account-aware or CloudKit composition was started; that remains in later plans.

### 7. Journal file hardening

- Journal reads use `lstat`, regular-file checks, a 64 MiB bound, `open(O_NOFOLLOW)`, descriptor `fstat` identity comparison, and bounded streaming reads.
- FIFO and symlink paths are rejected before reading or blocking.
- Persisted staged attachments are reopened without following symlinks and their complete SHA-256 and byte count are revalidated, including same-size tampering.

### 8. Linear publication and projection work

- The sink protocol has atomic batch publication; the journal persists one envelope for a batch and one envelope for a partial acknowledgement.
- A failed default-loop sink retains the whole idempotent transaction. Repair retries by mutation identity instead of rewriting every suffix, removing the former quadratic sidecar pattern.
- `JSONProjectStore` caches structured record projections and reuses unchanged entity snapshots. Stable counter/reminder timestamps prevent unrelated counter records from being republished.
- Archive publication diffs record dictionaries, sends one batch, and only then removes the marker.
- Yarn link-only changes reuse the unchanged Yarn projection, preserving the existing “unlink publishes only the link deletion” contract.

### 9. Ambiguous journal durability

- Duplicate mutation UUIDs are accepted only when immutable intent matches exactly. A different record/version/intent throws `duplicateMutationID` without replacing the journal.
- Even an all-duplicate retry re-encodes, atomically writes, and re-fsyncs the existing envelope, repairing a post-rename/parent-fsync ambiguity without appending a duplicate.
- If an atomic write throws after producing live bytes, in-memory state is reconciled from the live regular file before the error is returned.

## RED/GREEN evidence by finding

| Finding | RED evidence | GREEN evidence |
| --- | --- | --- |
| 1 immutable saves/staged bytes | New real-journal tests initially could not compile against ID-only saves and had no retained attachment source. | Journal save→replace→delete→restart and store+real-journal restart tests retain both exact snapshots/byte versions; exact acknowledgement removes only the acknowledged staged file. |
| 2 stable slot/content version | New merge/markup fixtures initially had no slot/version/lineage types and the old semantic-page ID was overwritten. | Distinct label slots do not conflict; divergent versions of one slot do; replacement lineage and all photo/markup save-delete flows pass. |
| 3 counter/reminder atomicity | Atomic-domain fixtures initially failed to compile against generic scalar-only payloads. A later spec audit also produced `SyncConflict has no member counterValues`. | Stale-revision, concurrent absolute value, terminal-occurrence precedence, prepared command, processed ledger, exact pending intent, and 130 existing counter/reminder/Watch tests pass. |
| 4 write-then-throw | The new test observed publication after a write-then-throw path under the old fingerprint-only behavior. | `writeThenThrowKeepsReceiptMarkerAndDoesNotPublish` proves committed local state, retained marker, zero publication, restart repair, and exact later batch. |
| 5 deletion restore/ownership | Restore/cascade fixtures initially had only an unversioned union. Duplicate cascade input was also silently canonicalized instead of rejected. | Newer restore clears the cascade; unrelated and duplicate targets are rejected; Yarn is never a legal cascade target. |
| 6 factory injection | Enabled live-factory coverage could not supply a sink through the public factory. | Enabled live composition publishes one atomic batch; default screenshot-style composition creates no marker. All recovery/error factory branches forward the injected sink. |
| 7 bounded safe journal reads | FIFO/symlink/oversize tests exercised the old `fileExists` plus unbounded `Data(contentsOf:)` path. Same-size staged-byte corruption was initially accepted on restart. | FIFO, symlink, oversized envelope, and same-size staged digest corruption are rejected without following or blocking. |
| 8 non-quadratic path | Batch/performance tests initially lacked batch journal APIs and projection reuse; partial publication used suffix rewriting. | 2,000 enqueues plus 1,000 acknowledgements use exactly two journal writes; two deletions in a 1,500-Yarn archive use exactly two sink batches and remain below the 3-second bounds. |
| 9 idempotent repair | A write-then-throw retry could append a duplicate UUID under the old model. | Two ambiguous attempts perform two writes but reopen as one exact mutation; a different intent with the same UUID is rejected and original bytes remain. |

## Additional self-review defects closed

- Duplicate IDs in batch validation previously crashed in `Dictionary(uniqueKeysWithValues:)`; RED exited with signal 5. They now return `duplicateRecord`.
- Same-size staged attachment corruption initially produced no error; restart now rehashes it.
- Attachment lineage could point to its own content version; now rejected.
- Merge normalization initially erased a duplicate cascade before validation; validation now precedes canonical ordering.
- The generated Xcode project initially omitted all CloudSync sources, producing `cannot find type 'SyncEntityID' in scope` and related app/Watch build errors. `xcodegen generate` added all six sources to both targets, with a permanent membership contract test.
- A tightened pre-existing unlink assertion exposed an unnecessary Yarn save (`[delete link, save yarn]`); projection comparison now ignores link-only Yarn changes and the original one-delete contract passes.

## Verification commands and exact results

1. Pre-fix focused baseline:

   `swift test --filter 'SyncMutationJournalTests|SyncMergeEngineTests|SyncRecordValidationTests|SyncIdentityTests|JSONProjectStoreSyncPublicationTests'`

   Result: 57 tests passed before the final-fix changes.

2. Final focused sync/store matrix:

   `swift test --filter 'SyncMutationJournalTests|SyncMutationJournalFinalFixTests|SyncMergeEngineTests|SyncFinalFixMergePolicyTests|SyncRecordValidationTests|SyncIdentityTests|JSONProjectStoreSyncPublicationTests|Task8XcodeProjectMembershipTests'`

   Result: 84 tests in 8 suites passed in 0.526 seconds.

3. Existing real counter/reminder/Watch domain matrix:

   `swift test --filter 'ProjectCounterTests|KnittingReminderTests|WatchCommandApplicationTests|KnittingReminderStoreTests|WatchSyncPersistenceTests'`

   Result: 130 tests in 5 suites passed in 0.508 seconds.

4. Bounded performance cases from the final focused run:

   - `batchEnqueueAndPartialAcknowledgementEachPersistOnce`: 2,000 enqueue + 1,000 acknowledge, exactly 2 writes, 0.304 seconds, bound 3 seconds.
   - `largeDeletionUsesCachedProjectionAndOneBoundedBatch`: 1,500-Yarn archive, two deletions, exactly 2 batches, 0.119 seconds, each bound 3 seconds.
   - `realJournalRetainsSaveReplaceDeleteVersionsAcrossStoreAndJournalRestarts`: passed in 0.028 seconds.

5. Single final unfiltered package run:

   `swift test`

   Result: 1,819 tests in 147 suites passed in 325.533 seconds.

6. Final generic iOS build:

   `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/KnitNoteSyncCorePhase1-iOS CODE_SIGNING_ALLOWED=NO build`

   Result: `** BUILD SUCCEEDED **`. This also built and embedded the Watch and Share targets.

7. Final generic Watch build:

   `xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteWatch -configuration Debug -destination 'generic/platform=watchOS' -derivedDataPath /tmp/KnitNoteSyncCorePhase1-watchOS CODE_SIGNING_ALLOWED=NO build`

   Result: `** BUILD SUCCEEDED **` for arm64 and arm64_32.

8. Formatting/patch validation:

   `git diff --check`

   Result: clean.

The first iOS build attempt also exposed the stale generated-project membership. One diagnostic retry encountered a transient unavailable simulator disk-image service; `xcrun simctl list runtimes` confirmed iOS 18.1, iOS 26.5, and watchOS 26.5 after service recovery. The final exact iOS and Watch commands above both succeeded.

## Files changed

Production and project wiring:

- `KnitNote.xcodeproj/project.pbxproj`
- `Sources/KnitNoteCore/CloudSync/SyncRecord.swift`
- `Sources/KnitNoteCore/CloudSync/SyncRecordValidation.swift`
- `Sources/KnitNoteCore/CloudSync/SyncMergeEngine.swift`
- `Sources/KnitNoteCore/CloudSync/SyncMutationJournal.swift`
- `Sources/KnitNoteCore/CloudSync/SyncMutationPublishing.swift`
- `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`

Tests:

- `Tests/KnitNoteCoreTests/SyncMutationJournalFinalFixTests.swift` (new)
- `Tests/KnitNoteCoreTests/SyncFinalFixMergePolicyTests.swift` (new)
- `Tests/KnitNoteCoreTests/SyncMutationJournalTests.swift`
- `Tests/KnitNoteCoreTests/SyncMergeEngineTests.swift`
- `Tests/KnitNoteCoreTests/SyncRecordValidationTests.swift`
- `Tests/KnitNoteCoreTests/JSONProjectStoreSyncPublicationTests.swift`
- `Tests/KnitNoteCoreTests/Task8XcodeProjectMembershipTests.swift`

## Remaining concerns and deliberate deferrals

- CloudKit transport, account identity/lifecycle, app-level enablement, and account-scoped storage remain Plans 2–4. The core and Watch targets contain no CloudKit dependency.
- Full backup/restore mutation publication remains Plan 4 Task 4. This wave only guarantees that pending/corrupt publication evidence blocks restore before live-tree mutation.
- Conflict-resolution UI, immutable-version cleanup eligibility, and remote active-version installation remain later-plan work. Phase 1 retains divergent versions and emits deterministic conflict diagnostics so those layers do not need to recover lost bytes.
- The 3-second performance assertions are regression ceilings on this machine, not product latency promises; the measured focused times were 0.304 and 0.119 seconds.
