# Cross-device Sync Residual Authorities Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the three remaining Phase 1 correctness gaps so missing-target Watch rejections, immutable attachment history, and revision receipts remain verifiable across devices and restarts.

**Architecture:** Add a narrow orphan Watch-proof record only for results that cannot belong to an extant counter aggregate; bind journal attachment history to a canonical immutable-snapshot digest while treating metadata-poor v1 history as opaque; split revision heads from immutable per-mutation receipt files committed through a bounded recovery marker. Existing counter aggregates, segmented journal framing, durable-file primitives, and publication ordering remain the integration boundaries.

**Tech Stack:** Swift 6, Foundation, CryptoKit, Swift Testing, Xcode iOS/watchOS schemes.

**Spec:** `docs/superpowers/specs/2026-09-03-cross-device-sync-residual-authorities-design.md`

## Global Constraints

- Support iOS 18.0, macOS 15.0, and watchOS 11.0; `CloudSync` must not import CloudKit.
- The same mutation ID permanently reuses the exact entity, logical revision, and device ID.
- The same attachment version ID permanently names the same canonical immutable snapshot; deletion remains an overlay.
- Evidence-poor legacy attachment history fails closed without modifying original bytes or guessing lineage.
- A processed Watch command cannot execute again after restart, ledger pruning, or transfer to a fresh device.
- Archive, sidecar, marker, and recovery ordering remain durable and idempotent.
- Preserve user text and attachment bytes, 「使用毛線」 unlink behavior, and multi-reminder semantics.
- Do not change version/build numbers, add CloudKit transport, push, archive, or submit for review in this plan.
- Every production behavior change follows RED → verified expected failure → minimal GREEN → focused regression run.

---

### Task 1: Publish missing-target Watch rejection authority

**Files:**
- Modify: `Sources/KnitNoteCore/CloudSync/SyncIdentity.swift`
- Modify: `Sources/KnitNoteCore/CloudSync/SyncRecord.swift`
- Modify: `Sources/KnitNoteCore/CloudSync/SyncRecordValidation.swift`
- Modify: `Sources/KnitNoteCore/CloudSync/SyncPublicationProjection.swift`
- Modify: `Sources/KnitNoteCore/CloudSync/SyncMergeEngine.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Sources/KnitNoteCore/WatchSync/PreparedWatchCommand.swift`
- Test: `Tests/KnitNoteCoreTests/SyncCounterReminderMergeTests.swift`
- Test: `Tests/KnitNoteCoreTests/JSONProjectStoreSyncPublicationTests.swift`
- Test: `Tests/KnitNoteCoreTests/SyncPublicationEvidenceDurabilityTests.swift`

**Interfaces:**
- Consumes: `SyncProcessedWatchCommandProof.validated()`, `SyncAttachmentPublicationEvidence.watchCommandProofs`, `SyncPublicationProjector`, publication transaction marker and durable evidence file.
- Produces: `SyncEntityKind.watchCommandProof`, `SyncOrphanWatchCommandProof`, deterministic record identity keyed by command ID, projector output for missing-target proofs, and merge validation that preserves those proofs independently of archive membership.

- [ ] **Step 1: Add RED tests for missing project and missing counter after pruning**

Add tests that create a rejected command, remove the local `ProcessedWatchCommandLedger`, restart the store, project records, and verify a fresh destination with no project/counter can validate the exact immutable proof. The core assertions must be equivalent to:

```swift
let proofRecord = try #require(projected.mutations.compactMap(\.savedRecordVersion)
    .map(\.record)
    .first { $0.id == SyncEntityID(kind: .watchCommandProof, uuid: command.id) })
#expect(proofRecord.payload.atomicDomain == .orphanWatchCommandProof(expectedProof))

let restarted = try makeStore(root: root, deletingProcessedLedger: true)
let replay = try restarted.applyWatchCommand(command)
#expect(replay.rejection == expectedRejection)
#expect(restarted.counterApplicationCount == 0)
```

Cover `.projectMissing`, `.counterMissing`, project/counter reappearance, and fresh-device merge.

- [ ] **Step 2: Run the Watch tests and verify RED**

Run:

```bash
swift test --filter 'JSONProjectStoreSyncPublicationTests|SyncCounterReminderMergeTests'
```

Expected: the missing-target cases fail because the projector emits no authority when it cannot iterate an extant counter.

- [ ] **Step 3: Define the immutable orphan proof schema**

Add one entity kind and atomic-domain case with a schema-independent wrapper:

```swift
public struct SyncOrphanWatchCommandProof: Codable, Equatable, Sendable {
    public let proof: SyncProcessedWatchCommandProof

    public init(proof: SyncProcessedWatchCommandProof) throws {
        guard proof.rejection == .projectMissing || proof.rejection == .counterMissing,
              proof.commandIdentity != nil,
              proof.preparedCommand == nil,
              proof.effectProof == nil else {
            throw SyncRecordVersionError.corrupt
        }
        self.proof = try proof.validated()
    }
}
```

Encode/decode `.orphanWatchCommandProof(SyncOrphanWatchCommandProof)` explicitly. Do not permit this case to carry accepted effects or rejection reasons that belong to an extant counter aggregate.

- [ ] **Step 4: Project and merge orphan proof records**

Partition `processedWatchProofs` by whether their target counter exists in the current archive. Existing targets remain in `SyncCounterReminderState`; `.projectMissing` and `.counterMissing` proofs without a target emit one record whose ID is the command ID and whose mutation stamp comes from the durable processing proof. Validate exact duplicate equality; two payloads for the same command ID are corruption.

Use a helper with an explicit result:

```swift
func orphanWatchProofRecords(
    proofs: [SyncProcessedWatchCommandProof],
    archive: ProjectArchive,
    deviceID: String
) throws -> [SyncEntityID: SyncRecord]
```

The merge engine must retain a valid orphan record even if neither side has its project. If the counter later exists and the same proof is also embedded, require exact proof equality and keep the orphan record as the immutable missing-target authority.

- [ ] **Step 5: Make missing-target persistence atomic and durable**

In `applyWatchCommand`, construct the rejection proof before returning the acknowledgement. Save it through the existing locked evidence transaction, enqueue its projected mutation under the existing publication marker, and remove the marker only after durable evidence and journal publication succeed. A retry must find the same proof by command ID and return the same acknowledgement without applying an effect.

Add failure-injection tests at evidence write, journal enqueue, and marker removal. Each restart must publish the same proof exactly once.

- [ ] **Step 6: Verify GREEN and regressions**

Run:

```bash
swift test --filter 'WatchCommandApplicationTests|WatchSyncPersistenceTests|JSONProjectStoreSyncPublicationTests|SyncCounterReminderMergeTests|SyncPublicationEvidenceDurabilityTests|PhoneWatchSyncSourceContractTests'
```

Expected: all selected suites pass; missing-target commands remain rejected after pruning and on a fresh destination.

- [ ] **Step 7: Commit Task 1**

```bash
git add Sources/KnitNoteCore/CloudSync/SyncIdentity.swift Sources/KnitNoteCore/CloudSync/SyncRecord.swift Sources/KnitNoteCore/CloudSync/SyncRecordValidation.swift Sources/KnitNoteCore/CloudSync/SyncPublicationProjection.swift Sources/KnitNoteCore/CloudSync/SyncMergeEngine.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift Sources/KnitNoteCore/WatchSync/PreparedWatchCommand.swift Tests/KnitNoteCoreTests/SyncCounterReminderMergeTests.swift Tests/KnitNoteCoreTests/JSONProjectStoreSyncPublicationTests.swift Tests/KnitNoteCoreTests/SyncPublicationEvidenceDurabilityTests.swift
git commit -m "fix: retain orphan Watch rejection proofs"
```

### Task 2: Bind journal attachment history to canonical snapshots

**Files:**
- Modify: `Sources/KnitNoteCore/CloudSync/SyncRecord.swift`
- Modify: `Sources/KnitNoteCore/CloudSync/SyncRecordValidation.swift`
- Modify: `Sources/KnitNoteCore/CloudSync/SyncMutationJournal.swift`
- Test: `Tests/KnitNoteCoreTests/SyncAttachmentVersionTests.swift`
- Test: `Tests/KnitNoteCoreTests/SyncMutationJournalTests.swift`
- Test: `Tests/KnitNoteCoreTests/SyncMutationJournalSegmentTests.swift`
- Test: `Tests/KnitNoteCoreTests/SyncMutationJournalFinalFixTests.swift`

**Interfaces:**
- Consumes: deterministic `SyncRecordVersion` encoding, `SyncMutationDuplicateProof`, proof shards/checkpoint root, `SyncAttachmentLineage`, and legacy migration validation-before-write.
- Produces: `SyncAttachmentImmutableSnapshot`, `immutableSnapshotSHA256`, new proof-shard schema with backward decode, and opaque-v1 conflict enforcement.

- [ ] **Step 1: Add RED tests for full-snapshot divergence**

Create two saved attachment versions with identical `SyncAttachmentVersion` but change one immutable field at a time: `createdAt`, `entityRevision`, owner relationship, and an immutable payload field. Enqueue/acknowledge the first, then enqueue the second with a new mutation ID and require `.corrupt` without changing journal bytes.

Also prove deletion is an overlay:

```swift
let liveDigest = try SyncAttachmentImmutableSnapshot(record: live).sha256
let deletedDigest = try SyncAttachmentImmutableSnapshot(record: tombstone).sha256
#expect(liveDigest == deletedDigest)
```

- [ ] **Step 2: Add RED tests for opaque v1 acknowledged history**

Construct a valid legacy v1 proof shard lacking lineage metadata, load it successfully as opaque history, then attempt both:

```swift
try journal.enqueue(reusingOpaqueVersionID)
try journal.enqueue(replacingOpaqueVersionID)
```

Expected: both throw typed corruption; original checkpoint, shard, segment, and legacy bytes remain byte-for-byte unchanged.

- [ ] **Step 3: Run journal tests and verify RED**

Run:

```bash
swift test --filter 'SyncAttachmentVersionTests|SyncMutationJournalTests|SyncMutationJournalSegmentTests|SyncMutationJournalFinalFixTests'
```

Expected: divergent immutable record fields and v1 predecessor reuse are currently accepted, so the new assertions fail for the intended reason.

- [ ] **Step 4: Add canonical snapshot encoding**

Define a value that copies every immutable attachment-record field and deliberately omits `deletedAt`:

```swift
struct SyncAttachmentImmutableSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let id: SyncEntityID
    let createdAt: Date
    let entityRevision: UInt64
    let fields: [String: SyncFieldVersion<SyncScalar>]
    let deletionCascade: SyncFieldVersion<[SyncEntityID]>?
    let atomicDomain: SyncFieldVersion<SyncAtomicDomainValue>?
    let attachment: SyncAttachmentVersion
    let relationships: [SyncRelationship]

    init(record: SyncRecord) throws {
        guard let attachment = record.payload.attachment,
              record.id == .init(kind: .attachment, uuid: attachment.versionID) else {
            throw SyncRecordVersionError.corrupt
        }
        self.schemaVersion = record.schemaVersion
        self.id = record.id
        self.createdAt = record.createdAt
        self.entityRevision = record.entityRevision
        self.fields = record.payload.fields
        self.deletionCascade = record.payload.deletionCascade
        self.atomicDomain = record.payload.atomicDomain
        self.attachment = attachment
        self.relationships = record.relationships.sorted {
            ($0.role, $0.target.kind.rawValue, $0.target.uuid.uuidString)
                < ($1.role, $1.target.kind.rawValue, $1.target.uuid.uuidString)
        }
    }
}
```

Compute SHA-256 from the existing deterministic encoder after normalizing relationship ordering. Do not hash a re-encoded synthetic attachment record and do not include tombstone value/stamp.

- [ ] **Step 5: Version duplicate proofs and enforce opaque history**

Extend `SyncMutationDuplicateProof` with optional `attachmentImmutableSnapshotSHA256` and an explicit legacy-evidence state. New proofs require a 32-byte digest. Decode v1 shards as opaque attachment authorities containing at least their record/version IDs when available; validation must reject any later version-ID reuse or predecessor reference to an opaque authority.

Collective validation must compare canonical digest per version ID before constructing `SyncAttachmentLineage`. Continue validating cross-slot parents, cycles, tombstone monotonicity, and mutation-level `recordVersionSHA256` independently.

- [ ] **Step 6: Preserve validation-before-write migration**

Compute digests from legacy pending record bytes before any checkpoint/shard creation. If an old shard is too weak to prove identity, retain it as opaque rather than upgrading it with current data. Verify every rejection leaves the old layout untouched.

- [ ] **Step 7: Verify GREEN, corruption, and scale regressions**

Run:

```bash
swift test --filter 'SyncAttachmentVersionTests|SyncMutationJournalTests|SyncMutationJournalSegmentTests|SyncMutationJournalFinalFixTests|SyncFinalFixMergePolicyTests'
```

Expected: all selected suites pass, including existing 2,000-attachment and proof-root tests.

- [ ] **Step 8: Commit Task 2**

```bash
git add Sources/KnitNoteCore/CloudSync/SyncRecord.swift Sources/KnitNoteCore/CloudSync/SyncRecordValidation.swift Sources/KnitNoteCore/CloudSync/SyncMutationJournal.swift Tests/KnitNoteCoreTests/SyncAttachmentVersionTests.swift Tests/KnitNoteCoreTests/SyncMutationJournalTests.swift Tests/KnitNoteCoreTests/SyncMutationJournalSegmentTests.swift Tests/KnitNoteCoreTests/SyncMutationJournalFinalFixTests.swift
git commit -m "fix: bind journal attachment snapshots"
```

### Task 3: Persist immutable revision receipts with bounded recovery

**Files:**
- Modify: `Sources/KnitNoteCore/CloudSync/SyncRevisionLedger.swift`
- Modify: `Sources/KnitNoteCore/CloudSync/SyncDurableFile.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Test: `Tests/KnitNoteCoreTests/SyncRevisionLedgerTests.swift`
- Test: `Tests/KnitNoteCoreTests/JSONProjectStoreSyncPublicationTests.swift`

**Interfaces:**
- Consumes: `SyncRevisionRequest`, `SyncRevisionReceipt`, `SyncRevisionAllocating`, `SyncDurableFile`, shared file lock, publication recovery marker.
- Produces: immutable receipt-file layout, compact entity-head envelope, bounded batch marker, legacy v1 ledger migration, and I/O counters for historical retry complexity.

- [ ] **Step 1: Add the exact historical-retry RED test**

Add the missing sequence verbatim in behavior:

```swift
let a = try ledger.allocate(for: entity, mutationID: aID, observedRemoteRevision: 0)
_ = try ledger.allocate([
    .init(entityID: entity, mutationID: bID, observedRemoteRevision: a.logicalRevision),
    .init(entityID: entity, mutationID: cID, observedRemoteRevision: a.logicalRevision + 1),
])
let restarted = SyncRevisionLedger(url: url, deviceID: "installation-A")
let retriedA = try restarted.allocate(
    for: entity,
    mutationID: aID,
    observedRemoteRevision: 9_999
)
#expect(retriedA == a)
```

Expected RED: current compaction removes A before restart, so retry allocates a new revision.

- [ ] **Step 2: Add RED crash and bounded-I/O tests**

Inject failures after marker sync, after each receipt-file rename, after head-ledger sync, and before marker removal. Restart must return every original receipt and allocate the next revision above all durable receipts.

Add counters with explicit assertions:

```swift
#expect(counters.headLedgerDurableWriteCount == 1)
#expect(counters.receiptLookupCount <= requests.count + 1)
#expect(historicalRetryCounters.receiptLookupCount <= 2)
#expect(historicalRetryCounters.receiptDirectoryEnumerationCount == 0)
```

Populate at least 5,000 receipts before the historical retry.

- [ ] **Step 3: Run ledger tests and verify RED**

Run:

```bash
swift test --filter 'SyncRevisionLedgerTests|JSONProjectStoreSyncPublicationTests'
```

Expected: historical A retry and crash-boundary tests fail against the compacting single-file implementation.

- [ ] **Step 4: Introduce the version-2 storage layout**

Keep `url` as the compact heads file and derive sibling paths without changing callers:

```swift
private var receiptsRootURL: URL {
    url.deletingPathExtension().appendingPathExtension("receipts", isDirectory: true)
}

private func receiptURL(for mutationID: UUID) -> URL {
    let hex = mutationID.uuidString.lowercased()
    return receiptsRootURL
        .appendingPathComponent(String(hex.prefix(2)), isDirectory: true)
        .appendingPathComponent("\(hex).json")
}
```

Define a compact v2 heads envelope with no receipt array and a transaction marker containing the exact proposed new receipts and target heads. All encodings must be deterministic and size-bounded by the current allocation batch.

- [ ] **Step 5: Implement locked batch allocation and recovery**

Under the existing process-local and cross-process locks:

1. Recover a durable marker if present.
2. Read only requested receipt files.
3. Validate existing receipts byte-for-byte and reuse them.
4. Allocate new revisions from compact heads and observed floors.
5. Durable-write the marker.
6. Durable-create immutable receipt files; existing equal files are idempotent, differing files are corruption.
7. Durable-write heads once.
8. Remove and directory-sync the marker.

Do not enumerate all receipts on the hot path. A head-write failure after receipt creation must be repaired from the marker on restart.

- [ ] **Step 6: Migrate the legacy v1 envelope safely**

When the old envelope contains `receipts`, validate device ID, positive revisions, unique mutation IDs, entity agreement, and issued-head maxima. Write a migration marker, materialize immutable receipt files, write v2 heads, then retire the old encoding only after every parent directory is synchronized. Re-entry must accept identical existing receipts and reject divergence without deleting the v1 bytes.

- [ ] **Step 7: Integrate publication recovery**

Ensure `JSONProjectStore` publication recovery can reconstruct the same batch receipts after process restart without depending on compacted in-envelope history. Existing publication markers may retain duplicate receipt data for transaction recovery, but the immutable receipt files are the long-term idempotence authority.

- [ ] **Step 8: Verify GREEN and concurrency regressions**

Run:

```bash
swift test --filter 'SyncRevisionLedgerTests|JSONProjectStoreSyncPublicationTests|SyncInstallationIdentityTests|SyncPublicationTransactionTests'
```

Expected: all selected suites pass, including multi-instance/process allocation, overflow, corruption, migration, crash recovery, 5,000-receipt bounded retry, and one head-ledger write per batch.

- [ ] **Step 9: Commit Task 3**

```bash
git add Sources/KnitNoteCore/CloudSync/SyncRevisionLedger.swift Sources/KnitNoteCore/CloudSync/SyncDurableFile.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/SyncRevisionLedgerTests.swift Tests/KnitNoteCoreTests/JSONProjectStoreSyncPublicationTests.swift
git commit -m "fix: preserve immutable revision receipts"
```

### Task 4: Integrated Phase 1 verification and release-gate report

**Files:**
- Modify only if an integration test exposes a product defect: files already listed in Tasks 1–3
- Test: relevant files already listed in Tasks 1–3
- Create: `.superpowers/sdd/2026-09-03-cross-device-sync-residual-authorities/task-4-report.md` (ignored execution evidence, not a product artifact)

**Interfaces:**
- Consumes: completed and reviewed Tasks 1–3.
- Produces: one exact-candidate verification report; no version/build edit, push, archive, or submission.

- [ ] **Step 1: Run the combined focused suite**

```bash
swift test --filter 'WatchCommandApplicationTests|WatchSyncPersistenceTests|JSONProjectStoreSyncPublicationTests|SyncCounterReminderMergeTests|SyncPublicationEvidenceDurabilityTests|SyncAttachmentVersionTests|SyncMutationJournalTests|SyncMutationJournalSegmentTests|SyncMutationJournalFinalFixTests|SyncRevisionLedgerTests|SyncInstallationIdentityTests|SyncPublicationTransactionTests'
```

Expected: exit 0 with exact test/suite counts recorded.

- [ ] **Step 2: Run the complete Swift package suite**

```bash
swift test -q
```

Expected: exit 0; record exact totals and any non-failing diagnostics.

- [ ] **Step 3: Build generic iOS and Watch targets**

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/KnitNoteSyncResidual-iOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteWatch -configuration Debug -destination 'generic/platform=watchOS' -derivedDataPath /tmp/KnitNoteSyncResidual-Watch CODE_SIGNING_ALLOWED=NO build
```

Expected: both exit 0 with `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Verify source hygiene and candidate identity**

```bash
git diff --check
git status --short
git rev-parse HEAD
```

Expected: no whitespace errors; only the plan-specific ignored evidence workspace may be untracked/ignored; record the exact HEAD.

- [ ] **Step 5: Write the verification report**

Record every command, exit status, test total, build result, candidate SHA, and non-claim. Explicitly state that CloudKit transport, physical-device acceptance, version/build mutation, archive, push, and App Store Connect review submission remain outside this plan.

- [ ] **Step 6: Commit any integration-only test correction**

If Step 1–4 required no source/test fix, do not create an empty commit. If a regression required a TDD fix, stage only the affected source/test files and commit:

```bash
git commit -m "test: verify residual sync authorities"
```

After Task 4, request a broad whole-branch review from base `37a1ae0db039df117e6c5e2fef3c382524b1eb39` through the final implementation HEAD. If findings remain, permit exactly one final fix dispatch and one scoped re-review. Only a clean review may transition to `superpowers:verification-before-completion` and then the release-candidate workflow.
