# Task 2 report: bind attachment history to canonical snapshots

## Status

Complete. Attachment version identity is now bound to a deterministic canonical
snapshot in journal history, weak v1 history is retained as opaque authority,
and every production attachment tombstone path covered by this task clones the
issued immutable record and changes only the deletion overlay.

## Implementation

- Added `SyncAttachmentImmutableSnapshot`. It copies the attachment record's
  schema version, ID, `createdAt`, `entityRevision`, fields, deletion cascade,
  atomic domain, attachment metadata, and relationships. Relationships are
  normalized by role, target kind, and target UUID before deterministic JSON
  encoding and SHA-256. The complete `deletedAt` value and stamp are omitted.
- Reused `SyncRecordVersion`'s deterministic encoder so record-version and
  canonical-snapshot hashing share the same sorted-key encoding policy without
  changing `SyncRecordVersion` identity semantics.
- Strengthened `SyncAttachmentLineage` to aggregate canonical snapshot digests
  by attachment version ID. Reusing one ID with any immutable record difference
  now throws `corruptAttachmentVersion`; live and tombstone overlays still share
  one identity.
- Added proof-shard payload v2. New attachment duplicate proofs retain both the
  full record-version digest (mutation identity) and canonical immutable digest
  (attachment version identity), plus slot/parent/deletion metadata.
- Added collective validation before lineage construction. It compares the
  complete `SyncAttachmentVersion` first (preserving enqueue's typed
  `.invalidAttachment` for metadata/cross-slot corruption), compares canonical
  digests per version ID, then retains existing same-slot, acyclic lineage and
  tombstone-monotonicity checks.
- Decodes payload-v1 attachment saves, tombstones, and bare deletes as explicit
  opaque authorities. Their record ID remains reserved, so later version-ID
  reuse or predecessor references fail closed. Exact same-mutation retry remains
  bound by the legacy record-version/content/byte-count hashes.
- Extended publication evidence with a backward-compatible optional
  `attachmentRecords` field. Modern issuance persists the exact causally stamped
  record and validates every later overlay against its canonical digest. The
  existing Watch proof fields and behavior are unchanged.
- Updated archive attachment projection, project/yarn/journal attachment
  deletion, usage-markup deletion, and legacy-markup deletion to clone the
  exact issued record. Causal receipt stamping updates only `deletedAt` for an
  attachment tombstone; it does not restamp fields or increment immutable
  `entityRevision`.
- Updated legacy bare-delete conversion in `SyncMergeEngine` to clone the exact
  available attachment record and advance only its deletion stamp/value.

## Production breaks named by the RED tests

1. Acknowledged journal history compared only nested attachment metadata, so a
   reused version ID with divergent `createdAt`, `entityRevision`, or another
   valid immutable payload field was accepted and appended.
2. Payload-v1 attachment history lacked a canonical digest but was treated as
   usable lineage, allowing later reuse of its ID or reference as predecessor.
   The same weakness applied to a v1 bare attachment delete that still reserved
   a historical version ID.
3. Legacy migration could write a new checkpoint/shard layout before discovering
   that two pending records reused one attachment version with divergent
   immutable snapshots.
4. Archive projection, artifact-only markup adapters, and legacy bare-delete
   conversion reconstructed tombstone records, changing immutable creation,
   revision, field, or relationship data.
5. The publication sidecar persisted only `SyncAttachmentVersion`; after a
   restart it could not reproduce the exact causally stamped issued record.

## TDD evidence

All commands used the isolated scratch directory required by the task. No full
suite was run.

Baseline before Task 2 tests:

```sh
swift test --scratch-path /tmp/KnitNoteResidualTask2 --filter 'SyncAttachmentVersionTests|SyncMutationJournalTests|SyncMutationJournalSegmentTests|SyncMutationJournalFinalFixTests'
```

Result: exit 0; 63 tests in 4 suites passed.

Primary journal RED, after adding the createdAt/entityRevision/immutable-field
and opaque-v1 cases:

```sh
swift test --scratch-path /tmp/KnitNoteResidualTask2 --filter 'SyncAttachmentVersionTests|SyncMutationJournalTests|SyncMutationJournalSegmentTests|SyncMutationJournalFinalFixTests'
```

Result: exit 1; 67 tests in 4 suites ran. The four new journal cases failed for
the intended behavioral reason: `.corrupt` was not thrown and journal artifacts
changed. A preceding fixture attempt failed earlier on an invalid missing
checkpoint; the fixture was corrected before this recorded RED.

Legacy validation-before-write RED:

```sh
swift test --scratch-path /tmp/KnitNoteResidualTask2 --filter 'legacyDivergentAttachmentSnapshotsLeaveOriginalLayoutUntouched'
```

Result: exit 1; 1 test in 1 suite failed because migration did not throw and
moved the legacy file instead of preserving its original layout.

Expanded projector/store/merge RED requested after the initial brief:

```sh
swift test --scratch-path /tmp/KnitNoteResidualTask2 --filter 'deletingOneAttachmentDoesNotHashSurvivorsAndDeletesOnlyIssuedVersion|legacyPendingAttachmentDeleteBecomesDurableTombstone|projectPhotoPublishesStableAttachmentSaveAndDelete'
```

Result: exit 1; 3 tests in 3 suites failed only their canonical digest equality,
proving all three tombstone paths changed immutable data.

The first broad journal GREEN attempt correctly exposed one existing expectation:

```sh
swift test --scratch-path /tmp/KnitNoteResidualTask2 --filter 'SyncAttachmentVersionTests|SyncMutationJournalTests|SyncMutationJournalSegmentTests|SyncMutationJournalFinalFixTests|SyncFinalFixMergePolicyTests'
```

Result: exit 1; 84 tests in 5 suites ran; only
`enqueueRejectsDivergentDuplicateAttachmentVersionAndCrossSlotLineage` failed
because metadata divergence returned `.corrupt` rather than the public enqueue
contract's `.invalidAttachment`. Comparing complete attachment metadata before
canonical digests fixed the classification without weakening digest checks.

Expanded focused GREEN:

```sh
swift test --scratch-path /tmp/KnitNoteResidualTask2 --filter 'SyncPublicationEvidenceDurabilityTests|deletingOneAttachmentDoesNotHashSurvivorsAndDeletesOnlyIssuedVersion|legacyPendingAttachmentDeleteBecomesDurableTombstone|projectPhotoPublishesStableAttachmentSaveAndDelete'
```

Result: exit 0; 12 tests in 4 suites passed.

The first Task 1 adjacent/store regression run exposed the two remaining
artifact-only adapters:

```sh
swift test --scratch-path /tmp/KnitNoteResidualTask2 --filter 'WatchCommandApplicationTests|WatchSyncPersistenceTests|JSONProjectStoreSyncPublicationTests|SyncCounterReminderMergeTests|SyncPublicationEvidenceDurabilityTests|PhoneWatchSyncSourceContractTests|SyncAttachmentManifestTests'
```

Result: exit 1; 213 tests in 7 suites ran; only
`usageMarkupPublishesStableAttachmentSaveAndDelete` and
`legacyMarkupPublishesStableAttachmentSaveAndDelete` failed because no
tombstone reached the sink. Root-cause tracing showed both helpers still rebuilt
records from version-only input; evidence validation rejected them. Passing and
cloning the exact sidecar record made the two-test focused command pass 2/2.

Additional v1 bare-delete RED/GREEN:

```sh
swift test --scratch-path /tmp/KnitNoteResidualTask2 --filter 'opaqueV1BareAttachmentDeleteRejectsVersionReuseWithoutWriting'
```

RED result: exit 1; 1 test in 1 suite failed with no corruption error and changed
artifacts. GREEN result with the same command: exit 0; 1 test passed.

Final required journal/scale GREEN, rerun after the last proof change:

```sh
swift test --scratch-path /tmp/KnitNoteResidualTask2 --filter 'SyncAttachmentVersionTests|SyncMutationJournalTests|SyncMutationJournalSegmentTests|SyncMutationJournalFinalFixTests|SyncFinalFixMergePolicyTests'
```

Result: exit 0; 85 tests in 5 suites passed in 149.757 seconds, including the
2,000 sequential attachment acknowledgement and proof-root/compaction cases.

Final Task 1 Watch plus projection/store adjacency GREEN, rerun after all
production changes:

```sh
swift test --scratch-path /tmp/KnitNoteResidualTask2 --filter 'WatchCommandApplicationTests|WatchSyncPersistenceTests|JSONProjectStoreSyncPublicationTests|SyncCounterReminderMergeTests|SyncPublicationEvidenceDurabilityTests|PhoneWatchSyncSourceContractTests|SyncAttachmentManifestTests'
```

Result: exit 0; 213 tests in 7 suites passed in 3.208 seconds. This verifies the
Task 1 orphan-proof behavior and every existing Watch Codable path remained
intact while the shared projection/store evidence was extended.

## Migration and failure behavior

- A valid v1 proof shard remains in place and loads successfully. Attachment
  authorities are interpreted as opaque in memory; they are never upgraded by
  borrowing the current mutation's data. Reuse/predecessor rejection leaves the
  checkpoint, proof shard, segment, and migration marker byte-for-byte unchanged.
- A legacy full-envelope migration computes canonical digests from its own
  pending record bytes and collectively validates them before any checkpoint or
  shard write. Divergence leaves the original file and directory inventory
  unchanged.
- A pre-change publication sidecar with no `attachmentRecords` key still decodes
  and retains versions, deleted IDs, and Watch proofs. It is not silently
  backfilled. Without the exact record it cannot authorize a tombstone/bare
  delete, and rejection does not rewrite its bytes.
- Modern sidecars persist the exact issued record and preserve it across restart;
  live/tombstone digest comparison prevents divergent overlays from being saved.

## Files changed

- `Sources/KnitNoteCore/CloudSync/SyncRecord.swift`
- `Sources/KnitNoteCore/CloudSync/SyncRecordValidation.swift`
- `Sources/KnitNoteCore/CloudSync/SyncMutationJournal.swift`
- `Sources/KnitNoteCore/CloudSync/SyncPublicationProjection.swift`
- `Sources/KnitNoteCore/CloudSync/SyncMergeEngine.swift`
- `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- `Tests/KnitNoteCoreTests/SyncAttachmentVersionTests.swift`
- `Tests/KnitNoteCoreTests/SyncMutationJournalSegmentTests.swift`
- `Tests/KnitNoteCoreTests/SyncAttachmentManifestTests.swift`
- `Tests/KnitNoteCoreTests/SyncFinalFixMergePolicyTests.swift`
- `Tests/KnitNoteCoreTests/JSONProjectStoreSyncPublicationTests.swift`
- `Tests/KnitNoteCoreTests/SyncPublicationEvidenceDurabilityTests.swift`

## Self-review and concerns

- Reviewed the complete production and test diff against Task 1 HEAD `d98a87e`.
  `git diff --check` passed before report creation; it is rerun before commit.
- New proof shards are payload version 2 while the outer checksum wrapper remains
  version 1, matching the existing wrapper contract. Payload versions other than
  1 or 2 fail closed.
- Legacy version-only publication evidence intentionally remains readable but
  cannot authorize deletion until an exact immutable record is available. No
  current-data backfill or guessed tombstone is performed.
- The 2,000-attachment case remains incremental and compact but took about 90
  seconds inside the final 150-second journal gate on this machine.
- No full-suite, CloudKit transport, release version/build, push, archive, or App
  Store action was performed; Task 4 owns the full-suite/release gate.

## Fix round 1: complete v1 authority matrix

The review finding was a test-evidence gap, not a production defect. The former
coverage exercised a v1 live save for reuse/predecessor and a v1 bare delete for
reuse only. It is now one six-case matrix crossing all three valid v1 attachment
authority forms (`liveSave`, `savedTombstone`, `bareDelete`) with both forbidden
attempts (`reuse`, `predecessor`). Each case requires typed `.corrupt`, compares
the checkpoint, proof shard, segment, and migrated-marker data byte for byte, and
compares the complete directory inventory before and after rejection.

The first focused attempt did not reach a behavioral RED: Swift rejected the
parameterized test because its method visibility exceeded its private argument
type. It exited 1 with no tests run; declaring the test `fileprivate` corrected
the fixture declaration before behavior was evaluated.

To verify that the added rows catch the named production break, a temporary,
uncommitted mutation limited opaque reservations to v1 authorities carrying a
content digest. This models the regression where saved tombstones and bare
deletes stop reserving their historical version ID:

```sh
swift test --scratch-path /tmp/KnitNoteResidualTask2 --filter 'opaqueV1AttachmentAuthorityRejectsEveryReuseAndPredecessorWithoutWriting'
```

Mutation-control RED: exit 1; 1 parameterized test in 1 suite failed with 12
issues. Precisely the four newly required rows failed: saved-tombstone reuse,
saved-tombstone predecessor, bare-delete reuse, and bare-delete predecessor.
Each showed the missing typed error plus changed artifact bytes and directory
layout. The live-save rows remained passing. This was deliberate test
sensitivity evidence, not a defect in the committed production implementation.

The temporary mutation was fully reverted. GREEN with the identical command:
exit 0; 1 parameterized test with 6 cases in 1 suite passed in 0.026 seconds.
No production file remains changed in this fix round.

Final Task 2 journal gate after restoring production:

```sh
swift test --scratch-path /tmp/KnitNoteResidualTask2 --filter 'SyncAttachmentVersionTests|SyncMutationJournalTests|SyncMutationJournalSegmentTests|SyncMutationJournalFinalFixTests|SyncFinalFixMergePolicyTests'
```

Result: exit 0; 84 tests in 5 suites passed in 144.168 seconds. The Swift Testing
summary counts the six argument rows as one parameterized test; its detailed
output separately confirms all 6 cases. No Task 1 production or Watch path was
touched, so the earlier 213-test adjacency result remains applicable.
