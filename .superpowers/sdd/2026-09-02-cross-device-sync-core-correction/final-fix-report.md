# Cross-device sync final corrective fix report

Date: 2026-09-03

Branch: `docs/cross-device-sync-design`

Starting HEAD: `e9eb4c6bf2eaf0b3a81d7d099e5a90cf2dd7d607`

Implementation commit: `b5153be9fcbc99c51639168be9d59a71273c8999` (`fix: close cross-device sync correctness gaps`)

Scope boundary: core synchronization correctness only. CloudKit transport remains explicitly out of scope.

## Outcome

The final-review findings were addressed as one cohesive correctness wave. The implementation now treats attachment versions as an immutable lineage, carries verifiable Watch command outcomes inside the synchronized counter aggregate, validates attachment history collectively at every journal construction/migration boundary, makes publication evidence durable before transaction-marker removal, batches causal revision allocation, bounds journal hot-path metadata reads, and gives yarn-label photos stable persisted slot identities.

The exact final source tree passed the complete Swift package suite and generic iOS and watchOS builds. One earlier full-suite run reported one issue whose diagnostic was lost in truncated concurrent output; all 225 directly affected tests passed independently afterward, and a complete quiet rerun passed all 1,971 tests. This non-reproduction is recorded under Verification rather than hidden.

## Finding resolutions

### 1. Attachment lineage and deletion authority

- Added collective `SyncAttachmentLineage` validation keyed by immutable version ID.
- Rejects divergent snapshots for one version ID, cross-slot parents, and replacement cycles.
- Computes unsuperseded per-slot heads. Sequential ancestors remain immutable history and no longer appear as conflicts.
- Concurrent unsuperseded heads remain visible as conflicts, while `resolvedAttachmentVersionIDs` selects the causal winner by deletion stamp and deterministic UUID tie-break.
- Replaced attachment bare deletes with tombstone saves carrying the exact immutable attachment snapshot.
- Persisted every issued version plus a durable deleted-version set. A deleted head can never be reused; restoring content issues a child version, so deleting the latest head cannot expose an ancestor.
- Legacy bare deletes are upgraded only when the exact issued record/version is available; guessing is rejected.

Coverage includes sequential A -> B lineage, forked heads, cycles, causal resolution, exact legacy-delete upgrade, tombstoned stale-manifest reuse, and delete-without-resurrection.

### 2. Transferable Watch exactly-once proof

- Added immutable `SyncProcessedWatchCommandProof` values to `SyncCounterReminderState`.
- Accepted commands carry the prepared command and exact effect proof. Rejections carry a bounded, schema-independent `ProcessedWatchCommandIdentity` plus rejection reason, avoiding future/legacy command-schema decode failures.
- Validation rejects accepted proofs with a mismatched effect and rejection proofs without command identity.
- Equal-stamp and causal aggregate merges monotonically union IDs and proofs, reject divergent proof reuse, and validate every processed ID before accepting it.
- Projection unions durable sidecar proof, cached aggregate proof, and locally available ledger proof; it never republishes a processed ID that lacks transferable proof.
- Durable rejection paths now publish their proof immediately. A duplicate delivery repairs an interrupted pending publication before returning its acknowledgement.
- The sidecar retains proof after the local processed ledger is deleted or pruned, so a fresh device with an empty ledger can validate and merge the aggregate.

Coverage includes fresh-device/empty-ledger merge, post-ledger-deletion republish, accepted-effect mismatch, durable rejection publication, unknown-schema rejection restart, refusal of identity-free rejection proof, and interrupted-publication repair.

### 3. Journal cross-record attachment invariants

- Extended immutable duplicate-proof shards with attachment version and tombstone metadata.
- Runs collective attachment-lineage validation before any legacy migration writes, after checkpoint/segment replay, and before enqueue frames are constructed.
- Acknowledgement pruning retains enough immutable version metadata to validate later descendants, duplicate version IDs, cross-slot parents, cycles, and live reuse after tombstone.
- Invalid legacy bytes are validated before checkpoint/shard creation; corruption leaves the original legacy bytes and layout untouched.

Coverage includes divergent duplicate version IDs, cross-slot lineage, cyclic lineage, acknowledged ancestry followed by replacement, and corrupt legacy migration with untouched bytes/layout.

### 4. Sidecar evidence durability and crash ordering

- Routed evidence writes through `SyncDurableFile`: exclusive advisory lock, complete temporary-file write, file `fsync`, atomic rename, and parent-directory `fsync`.
- Added explicit failure injection before file sync, rename, and directory sync.
- Evidence updates use one locked read/validate/write transaction, preventing separately loaded stores from overwriting one another's acknowledged history.
- Publication order is sink enqueue, durable evidence update, durable manifest update, then transaction-marker removal. Any evidence failure retains the marker for idempotent repair.
- Added a sidecar-only restart test proving lineage and deletion authority survive without relying on an in-memory cache.

### 5. Revision allocation scaling and safe compaction

- Added `SyncRevisionRequest` and a batch allocator that performs one cross-process lock acquisition and at most one durable ledger write for a publication transaction.
- Kept the original single-request protocol requirement and supplied a source-compatible default batch adapter; `SyncRevisionLedger` overrides it with the atomic batch implementation.
- Compaction retains the current requested mutation receipts plus the latest receipt/head for every entity. Pending publication recovery carries its exact per-mutation receipts in the durable transaction marker.
- Existing mutation IDs reuse their receipt; divergent reuse, invalid floors, overflow, and cross-instance concurrency fail safely.

Coverage includes one-write batch allocation, retry reuse, next-batch compaction, restart recovery, legacy allocator compatibility, revision exhaustion, and two ledger instances sharing one file.

### 6. Journal hot-path scaling

- Checkpoint schema v4 stores an append-only hash-chain root over immutable proof-shard bytes.
- Cold load reads and verifies every referenced immutable shard against the checkpoint root.
- Warm freshness checks fingerprint only mutable legacy/checkpoint/segment artifacts; they no longer stat every immutable shard on every operation.
- Added `metadataReadCount` instrumentation and a large-shard test proving steady-state metadata reads are independent of proof-shard count.
- Older segmented checkpoints are upgraded only after their shards, replay frames, attachment lineage, and pending sources validate.

Coverage includes 2,000 sequential operations, 2,000 attachment acknowledgements, bounded metadata reads, proof-root corruption, interrupted shard publication, partial shards, and v2/v3 upgrade/recovery.

### 7. Stable yarn-label attachment slots

- Added persisted `StoredYarn.labelPhotoSlotIDs`, paired by index with filenames and validated for completeness/uniqueness.
- Legacy archives deterministically derive each slot from the UUID already embedded in the managed label filename.
- Filename identity is preserved first; same ordinal preserves the semantic slot across photo replacement; new labels receive fresh UUID slots.
- Attachment publication now uses `label:<stable UUID>` instead of the compacting array index.

Coverage includes repeatable legacy decode, removing the first of two labels while retaining the second slot, and an end-to-end publication test proving the second attachment version is unchanged while only the first slot is tombstoned.

### Minor A. Projection authority

- `SyncCanonicalPublicationSnapshot` in `SyncPublicationProjection.swift` is the sole compiled archive structural projector.
- The former duplicate structural projector and full-content/full-hash attachment projection paths are explicitly compile-excluded and documented as compatibility references.
- The only active compatibility boundary is the artifact-only markup helper, because those commits do not pass through an archive projection; archive-backed attachments all use the incremental manifest projector.
- A source-contract test guards this authority split.

### Minor B. Publication receipt invariant

- Replaced the tautological unique-entity predicate with the actual transaction contract: complete mutation coverage, unique mutation IDs, exactly one mutation/receipt per entity, one nonempty device identity, positive revisions, and exact mutation/receipt matching.
- Added a regression test that rejects two mutations for the same entity in one publication transaction.

## Changed files

Production:

- `Sources/KnitNoteCore/CloudSync/SyncInstallationIdentity.swift`
- `Sources/KnitNoteCore/CloudSync/SyncMergeEngine.swift`
- `Sources/KnitNoteCore/CloudSync/SyncMutationJournal.swift`
- `Sources/KnitNoteCore/CloudSync/SyncMutationPublishing.swift`
- `Sources/KnitNoteCore/CloudSync/SyncPublicationProjection.swift`
- `Sources/KnitNoteCore/CloudSync/SyncRecord.swift`
- `Sources/KnitNoteCore/CloudSync/SyncRecordValidation.swift`
- `Sources/KnitNoteCore/CloudSync/SyncRevisionLedger.swift`
- `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- `Sources/KnitNoteCore/WatchSync/PreparedWatchCommand.swift`
- `Sources/KnitNoteCore/WatchSync/ProcessedWatchCommandLedger.swift`
- `Sources/KnitNoteCore/Yarn/StoredYarn.swift`

Tests:

- `Tests/KnitNoteCoreTests/JSONProjectStoreSyncPublicationTests.swift`
- `Tests/KnitNoteCoreTests/PhoneWatchSyncSourceContractTests.swift`
- `Tests/KnitNoteCoreTests/StoredYarnLabelFieldsTests.swift`
- `Tests/KnitNoteCoreTests/SyncAttachmentManifestTests.swift`
- `Tests/KnitNoteCoreTests/SyncAttachmentVersionTests.swift`
- `Tests/KnitNoteCoreTests/SyncCounterReminderMergeTests.swift`
- `Tests/KnitNoteCoreTests/SyncFinalFixMergePolicyTests.swift`
- `Tests/KnitNoteCoreTests/SyncMutationJournalSegmentTests.swift`
- `Tests/KnitNoteCoreTests/SyncPublicationEvidenceDurabilityTests.swift` (new)
- `Tests/KnitNoteCoreTests/SyncRevisionLedgerTests.swift`

## TDD evidence

Representative RED observations before production changes:

- `swift test --filter SyncCounterReminderMergeTests.equalStampAggregatesMonotonicallyUnionTransferredProcessedCommand` failed because equal-stamp aggregates treated additive processed proof as corrupt.
- `swift test --filter SyncRevisionLedgerTests.legacySingleRequestAllocatorGetsCompatibleBatchAdapter` failed to compile when the first batch-only protocol shape broke legacy allocators.
- `swift test --filter SyncAttachmentManifestTests.tombstonedHeadIsNeverReusedEvenWhenAStaleManifestStillMatches` failed because the stale manifest suppressed the required child issuance.
- `swift test --filter SyncCounterReminderMergeTests.recordValidationRejectsEmbeddedAcceptedProofWithWrongEffect` failed because the invalid accepted effect was not rejected.
- `swift test --filter SyncPublicationEvidenceDurabilityTests.legacyBareAttachmentDeleteRequiresExactIssuedEvidence` failed because an unissued bare delete was accepted.
- `swift test --filter JSONProjectStoreSyncPublicationTests.durableWatchRejectionPublishesTransferableProofAndSurvivesLedgerDeletion` failed to compile because ledger and aggregate proof had no command identity.
- `swift test --filter JSONProjectStoreSyncPublicationTests.duplicateRejectedWatchCommandRepairsInterruptedProofPublication` first exposed that direct storage of an unsupported-schema command could not be decoded, then failed with `pendingRepair` until duplicate acknowledgement explicitly repaired publication.
- `swift test --filter SyncCounterReminderMergeTests.rejectionProofWithoutCommandIdentityIsRejected` failed because a rejection with no command identity was accepted.

Focused GREEN evidence on the final implementation:

- `swift test --filter 'JSONProjectStoreSyncPublicationTests.(durableWatchRejectionPublishesTransferableProofAndSurvivesLedgerDeletion|duplicateRejectedWatchCommandRepairsInterruptedProofPublication)|PhoneWatchSyncSourceContractTests.phoneStoreDecodesLegacyReminderCommandsWithoutExecutingThem'`
  - exit 0; 3 tests in 2 suites passed.
- `swift test --filter 'WatchSyncPersistenceTests|WatchCommandApplicationTests|JSONProjectStoreSyncPublicationTests|SyncCounterReminderMergeTests|PhoneWatchSyncSourceContractTests'`
  - exit 0; 175 tests in 5 suites passed.
- `swift test --filter 'SyncAttachment|SyncFinalFixMergePolicy|SyncCounterReminderMerge|JSONProjectStoreSyncPublication|SyncRevisionLedger|SyncMutationJournal|StoredYarnLabel|JSONProjectStoreYarnLabel|SyncPublicationEvidence|PhoneWatchSyncSourceContract'`
  - exit 0; 225 tests in 13 suites passed in 71.417 seconds.

## Final verification

1. `swift test`
   - First final attempt: exit 1; 1,971 tests in 155 suites, one issue. The concurrent output was truncated before the failing diagnostic. The failure did not reproduce in the complete directly affected set or the next complete run.
2. `swift test -q --xunit-output /tmp/knitnote-sync-final-full.xml`
   - exit 0; 1,971 tests in 155 suites passed in 345.019 seconds.
3. `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/KnitNoteCrossDeviceSyncFinalFix-iOS CODE_SIGNING_ALLOWED=NO build`
   - exit 0; `** BUILD SUCCEEDED **`.
4. `xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteWatch -configuration Debug -destination 'generic/platform=watchOS' -derivedDataPath /tmp/KnitNoteCrossDeviceSyncFinalFix-Watch CODE_SIGNING_ALLOWED=NO build`
   - exit 0; `** BUILD SUCCEEDED **`.
5. `git diff --check` and `git diff --cached --check`
   - both exit 0 with no output before the implementation commit.

Non-failing build diagnostics were limited to existing toolchain notices, including AppIntents metadata extraction being skipped when no AppIntents framework dependency exists.

## Remaining risks and explicit non-claims

- CloudKit transport, server schema/deployment, account behavior, and real multi-device transport were not changed or tested; they remain outside this correction's scope.
- Generic builds are compile/link evidence, not physical acceptance. No iPhone, iPad, Mac, or Watch hardware acceptance was performed for this branch.
- Monotonic immutable attachment and Watch proof history is fail-closed at the existing 64 MiB encoded sidecar cap. A future compaction design would need a durable aggregate/checkpoint proof before safely discarding history.
- Journal steady-state filesystem metadata work is bounded, but collective lineage validation CPU/memory remains proportional to retained attachment proof history. The 2,000-attachment stress test passed; substantially larger histories should be profiled before increasing current caps.
- The first complete-suite one-issue result was non-reproducible and its individual diagnostic was lost to truncated concurrent output. The directly affected 225-test run and subsequent complete 1,971-test run both passed; this should still be watched in later CI runs.

No release, submission, deployment, physical-device acceptance, or CloudKit transport completion is claimed by this report.
