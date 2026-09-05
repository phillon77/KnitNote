# Remote Batch Durable Commit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Commit raw incoming batches against complete canonical state without lost local edits, premature ACK, or duplicate domain effects.

**Architecture:** Extend the existing publication transaction, not a second archive writer. A Core preparation/commit boundary owns complete-state merge and recovery; a MainActor adapter owns account-epoch ordering and transport acknowledgement evidence. Keep production activation closed while server-record-changed replacement and broader lifecycle gates remain unfinished.

**Tech Stack:** Swift 6, Foundation, CryptoKit, Swift Testing, existing file-backed journal/checkpoint, CloudKit interfaces used with isolated test transports.

**Spec:** `docs/superpowers/specs/2026-09-05-remote-batch-durable-commit-design.md` (user approved after commit `68535fc`). Read the complete spec before executing any task.

## Global Constraints

- Version stays **1.7.0（13）**. Execution starts from this existing linked worktree, not another checkout; inspect HEAD and user changes before edits.
- No live CloudKit, Keychain, user data, App host, UI/settings, purchase, localization, signing-setting, push, upload or submission changes.
- Preserve the existing **100,000,000-byte** limits for encoded persistent authorities and verified files. Reject oversized candidates before modifying live data.
- Raw batches are partial inputs, never complete archives. Preserve unrelated records, tombstones, attachment history, Watch evidence and exact pending FIFO payloads.
- Final account validation and durable work occur synchronously inside `CloudSyncAccountEpoch.withCurrent`; no await while holding write ownership.
- Failures retain incoming data and recovery authority; no success stubs, ignored parser/storage errors, arbitrary file cleanup, or guessed deletion authority.
- Do not implement the distinct server-record-changed FIFO replacement here. Its concrete adapter path must throw and preserve pending; no production-ready claim.
- Existing full Core PASS (2,311 tests) belongs to `6db2302`, not to new code. Run fresh verification after implementation.

## File ownership and dependency order

1. `SyncRemoteBatch.swift`: validated raw input, deterministic identity, preparation/result contracts.
2. `SyncCanonicalCheckpoint.swift` and `SyncMutationPublishing.swift`: bounded receipts and recoverable remote-source transaction metadata, exact legacy decoding.
3. `SyncMutationJournal.swift`: an internal nonescaping exclusive journal lease; `JSONProjectStore.swift`: narrow preparation/commit/recovery entry points. No unrelated store refactor.
4. `JSONProjectStoreRemoteBatchCommitter.swift`: MainActor adapter only; coordinator and transport/state-store changes pass raw input and durable ACK evidence.
5. Tests and verification report: combined faults, competing edits, reopen, and non-host integration evidence.

New Swift sources must be added to the actual relevant Xcode consumers in `KnitNote.xcodeproj/project.pbxproj`. Do not regenerate unrelated project sections.

## Shared contract decisions

Proposed new public Core declarations (defined by Tasks 1–2, implemented by Task 3):

```swift
public struct SyncRemoteBatchIdentity: Codable, Equatable, Sendable {
    public let accountIDHash: String
    public let batchID: UUID
    public let contentSHA256: Data
}
public struct SyncRemoteBatch: Sendable {
    public let identity: SyncRemoteBatchIdentity
    public let records: [SyncRecord]
    public let deletedRecordIDs: [SyncEntityID]
    public init(accountIDHash: String, batchID: UUID,
                records: [SyncRecord], deletedRecordIDs: [SyncEntityID]) throws
}
public struct SyncRemoteBatchReceipt: Codable, Equatable, Sendable {
    public let identity: SyncRemoteBatchIdentity
    public let commitID: UUID
    public let domainChanged: Bool
}
public struct SyncRemoteBatchPreparation: Sendable {
    // Internal stored fields only; no public/memberwise initializer.
    // Carries raw batch, complete predecessor evidence and exact candidate.
}
public enum SyncRemoteBatchCommitResult: Equatable, Sendable {
    case committed(SyncRemoteBatchReceipt)
    case alreadyCommitted(SyncRemoteBatchReceipt)
    case stalePredecessor
}
public enum SyncRemoteBatchError: Error, Equatable, Sendable {
    case invalidBatch, identityCollision, missingAuthority
    case unprovenDeletion, receiptCapacity, unsupportedConflictReplacement
}
```

Receipt budget: at most **4,096 unretired receipts**, also subject to the whole checkpoint/transaction byte cap. Store receipts in canonical format 2, not an unrelated ledger. Same batch ID + differing digest is rejected while its receipt is retained. Receipt content and raw input must bind account hash and sorted, validated records/deletion IDs; reject duplicate record IDs rather than resolving them by array order. Delivery generation is an epoch guard, not part of stable content identity.

Retirement is allowed only after the adapter revalidates the current epoch, transport scope and durable acknowledged state/verified batch absence. Unconfirmed receipts are never evicted. A retirement is itself a canonical-only publication transaction; a crash can retain excess receipts but cannot discard unacknowledged proof. No permanent, unbounded seen-ID set is promised: after durable retirement, equivalent redelivery is processed by merge/version idempotence against current state, with no repeated effect. Conflicting ID/content still present in incoming storage must be rejected there.

## Verification commands

Use `/usr/bin/arch -arm64 /usr/bin/swift` so the XCTest harness matches the arm64 bundle. Request narrowly scoped sandbox-external execution when build-settings/socket diagnostics require it. Do not change HOME or CODEX_HOME.

```sh
CLANG_MODULE_CACHE_PATH=/tmp/daily-canonical-clang-cache /usr/bin/arch -arm64 /usr/bin/swift test --disable-sandbox --no-parallel --cache-path /tmp/task4-swift-cache --config-path /tmp/task4-swift-config --security-path /tmp/task4-swift-security --filter 'SyncRemoteBatch|JSONProjectStoreRemoteBatch'
```

Each task runs its named filter with the same options, captures exit status and nonzero selected-test count, and records RED then GREEN. No overlap with full-suite runs. Final full run uses a verified owned-process-group timeout of **1,800 seconds**; timeout is incomplete, never PASS. Inspect `/tmp/task4-run-bounded.py` before reusing it; if unavailable, implement an equivalent task-owned bounded runner as test tooling, not an app change.

### Task 1: Raw batch identity and isolated fixture

**Files:**
- Create: `Sources/KnitNoteCore/CloudSync/SyncRemoteBatch.swift`
- Create: `Tests/KnitNoteCoreTests/SyncRemoteBatchTests.swift`
- Create: `Tests/KnitNoteCoreTests/RemoteBatchFixture.swift`
- Modify: `KnitNote.xcodeproj/project.pbxproj`

**Interfaces:** Produce the raw batch, identity, errors and opaque preparation/result declarations above. Fixture has `init() throws`, `remove()`, `account: SyncAccountIdentity`, `records: [SyncRecord]`, `projectID: UUID`, `store: JSONProjectStore`, `journal: FileSyncMutationJournal`, `checkpoints: SyncCanonicalCheckpointStore`, and `batch(records: [SyncRecord], id: UUID) throws -> SyncRemoteBatch`.

- [ ] Build the fixture from the actual bootstrap setup in `JSONProjectStoreCanonicalDurabilityTests.Fixture`: unique temporary root; two projects, six counters each; real export, bootstrap commit/handoff, journal and activated store. Do not copy private production internals or construct a forged handoff. All fixture cleanup targets its own explicit root.
- [ ] Add the identity RED test:

```swift
@Test @MainActor func inputOrderDoesNotChangeIdentity() throws {
    let f = try RemoteBatchFixture(); defer { f.remove() }
    let id = UUID()
    let a = try f.batch(records: f.records, id: id)
    let b = try f.batch(records: Array(f.records.reversed()), id: id)
    #expect(a.identity == b.identity)
    #expect(a.identity.contentSHA256.count == 32)
}
```

- [ ] Add explicit cases for invalid hash, duplicate IDs, malformed record, deletion/save ambiguity, changed content with same ID, and encoded-byte overflow. Hash canonical sorted encoding of account/batch/records/deletions, not memory descriptions or output ordering.
- [ ] Run `--filter SyncRemoteBatchTests`; verify failure relates to missing validation/identity contract, not fixture setup.
- [ ] Implement validation using `SyncRecordValidator`, deterministic sorted encoding and SHA256; validate before accepting input. Define opaque preparation fields when first consumed, with no client-manufactured predecessor authority.
- [ ] Re-run the filter; commit exact files as `feat(sync): define verified incoming batch identity`.

### Task 2: Bounded receipts and remote publication format

**Files:**
- Modify: `Sources/KnitNoteCore/CloudSync/SyncCanonicalCheckpoint.swift`
- Modify: `Sources/KnitNoteCore/CloudSync/SyncMutationPublishing.swift`
- Modify: `Sources/KnitNoteCore/CloudSync/SyncRemoteBatch.swift`
- Create: `Tests/KnitNoteCoreTests/SyncRemoteBatchTransactionTests.swift`
- Modify: `Tests/KnitNoteCoreTests/SyncCanonicalCheckpointTests.swift`

**Interfaces:** Add `remoteBatchReceipts: [SyncRemoteBatchReceipt]` to canonical checkpoint, with an empty default for newly created checkpoints. Add optional remote-source authority to publication format 6 containing raw identity, exact predecessor commitment and receipt action (insert/retire). The source metadata participates in integrity. Preserve format 1 checkpoint encoding/integrity when decoding and re-encoding old proof; formats 2–5 publication recovery remain byte/meaning compatible. Upgrade only through a proven transition.

- [ ] Write RED tests roundtripping real retained format 1 and publication format 5 fixtures, then inserting a remote receipt into a new candidate. Mutate only receipt digest, account or commit ID and require validation rejection.

```swift
// Test sequence: load a real legacy fixture, construct its proven successor,
// encode/decode, and compare exact receipt and all predecessor records.
#expect(decoded.remoteBatchReceipts == [receipt])
#expect(decoded.records == predecessor.records)
#expect(throws: SyncRemoteBatchError.identityCollision) {
    try candidate.insertingRemoteReceipt(conflictingReceipt)
}
```

Define `insertingRemoteReceipt(_:) throws -> SyncCanonicalCheckpoint` in this task: identical retained receipt is idempotent; same account/batch with differing receipt content is rejected; 4,097th unretired receipt throws `receiptCapacity` without changing the original. Tests create `receipt` with identity from Task 1 and a fixed commit UUID, not by reproducing the implementation hash.

- [ ] Test exact-cap/over-cap receipts and full 100,000,000-byte encoded envelope, including metadata-only retire transitions and unknown/invalid source format rejection.
- [ ] Run `--filter 'SyncRemoteBatchTransaction|SyncCanonicalCheckpoint|SyncCanonicalPublicationTransaction'` and observe RED.
- [ ] Implement explicit version switches and integrity paths. Extend the existing transaction constructor/validation, not a second transaction file. A remote candidate's full records are validated differently from a locally projected mutation delta; do not loosen local format-5 invariants to accommodate it.
- [ ] Update every normal local-edit/checkpoint successor constructor to carry retained receipts unchanged. Add local-edit-after-remote-commit and local deletion/restore tests proving receipts survive, rather than silently using the empty default. A format-1 instance preserves its legacy integrity; the first receipt insertion creates an explicit format-2 successor.
- [ ] Re-run the filter; commit `feat(sync): bind remote receipts to canonical publication`.

### Task 3: Complete-state preparation and exclusive durable commit

**Files:**
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Sources/KnitNoteCore/CloudSync/SyncMutationJournal.swift`
- Modify: `Sources/KnitNoteCore/CloudSync/SyncMutationPublishing.swift`
- Modify: `Sources/KnitNoteCore/CloudSync/SyncRemoteBatch.swift`
- Create: `Tests/KnitNoteCoreTests/JSONProjectStoreRemoteBatchTests.swift`
- Modify: `Tests/KnitNoteCoreTests/RemoteBatchFixture.swift`

**Interfaces:** Add MainActor store APIs:

```swift
public func prepareRemoteBatch(_ batch: SyncRemoteBatch,
    attachmentSources: [UUID: SyncAttachmentSource]) throws -> SyncRemoteBatchPreparation
public func commitRemoteBatch(_ preparation: SyncRemoteBatchPreparation)
    throws -> SyncRemoteBatchCommitResult
public func retireRemoteBatchReceipt(_ identity: SyncRemoteBatchIdentity,
    verifyTransportAcknowledgement: () throws -> Void) throws
public var onRemoteDomainCommitted: ((UUID) -> Void)? { get set }
```

The acknowledgement verifier is a nonescaping boundary capability supplied only by the adapter, never a boolean from UI. It must re-read durable scope/account/ACK evidence under epoch protection immediately before retirement. Core also checks current account/root/receipt binding. This dependency does not import CloudKit into Core.

Internal journal contract: `withExclusivePending<T>(_ body: (SyncJournalWriteLease) throws -> T) throws -> T`, with `SyncJournalWriteLease.pending() throws -> [SyncMutation]` and `enqueue(_ mutations: [SyncMutation]) throws`. Reuse the journal's existing process and file lock across the callback. Lease cannot escape or be reused after callback; check lifetime. Use lock-held enqueue internals, not recursively locking public enqueue. No public lease APIs or new lock namespace. Integrate a transaction-local publication sink using the lease so the final snapshot comparison and all journal writes share that lock.

- [ ] Extend the fixture with `renamedBatch(_ name: String, id: UUID) throws -> SyncRemoteBatch`: export a modified copy with a remote stamp strictly above the fixture baseline; include only the changed project record in the batch, not the second project/counters. Define `renameLocally(_ name: String) throws` via the existing real store update API used by canonical tests.
- [ ] Write partial-input RED:

```swift
let before = try #require(try f.checkpoints.load())
let batch = try f.renamedBatch("Remote", id: UUID())
let p = try f.store.prepareRemoteBatch(batch, attachmentSources: [:])
let result = try f.store.commitRemoteBatch(p)
guard case .committed = result else { Issue.record("Expected commit"); return }
let after = try #require(try f.checkpoints.load())
#expect(after.records.filter { $0.id != batch.records[0].id }
    == before.records.filter { $0.id != batch.records[0].id })
#expect(try f.journal.pending().isEmpty)
```

Fixture must acknowledge bootstrap pending before this pure-download case and retain the exact baseline receipt; do not assert empty if setup intentionally leaves uploads.

- [ ] Write stale-predecessor RED: prepare; call `renameLocally`; commit old preparation; expect `.stalePredecessor` and byte-for-byte unchanged post-edit archive/journal/checkpoint. Repeat with journal ACK, Watch state and attachment authority changes.
- [ ] Run `--filter JSONProjectStoreRemoteBatchTests`; confirm real behavioral RED.
- [ ] Implement preparation by snapshotting all predecessor authorities, merging raw records against full canonical state with actual Watch context, preserving local-only assets, and calling the real mapper with verified sources. Store the exact snapshot commitment and candidate in opaque preparation. Reject unproven raw deletion IDs, missing dependencies/media, wrong account, incomplete temp files and pending repair before writing.
- [ ] Implement commit inside existing ownership plus exclusive journal lease: re-read complete authorities, compare exact commitments, persist remote intent, install verified materialization, preserve exact mutations/receipts and finalize canonical/metadata using the existing transaction recovery path. Stage expensive work before final lock; final validation/copy uses pinned/bounded reads. Never bypass failed predecessor comparison by hashing display values alone.
- [ ] Receipt hit returns `.alreadyCommitted` without applying old candidate over newer state. Same identity collision throws. Only new committed domain changes call `onRemoteDomainCommitted(commitID)`, after all durable steps; metadata-only operations do not.
- [ ] Implement retirement as a proven canonical-only transaction; call verifier again at durable boundary. Do not remove receipts merely because no current UI task mentions the batch.
- [ ] Re-run tests plus `--filter 'SyncMutationJournal|JSONProjectStoreCanonical|SyncPublication'`; commit `feat(sync): commit remote batches against exclusive canonical state`.

### Task 4: Restart and fault-boundary guarantees

**Files:**
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Sources/KnitNoteCore/CloudSync/SyncMutationPublishing.swift`
- Create: `Tests/KnitNoteCoreTests/JSONProjectStoreRemoteBatchRecoveryTests.swift`
- Modify: `Tests/KnitNoteCoreTests/RemoteBatchFixture.swift`

**Interfaces:** Reuse `SyncCanonicalPublicationBoundary` for after-intent/archive/journal/checkpoint/before-intent-removal faults; add a receipt-persistence fault only if distinct from checkpoint commit. Fixture adds `reopen() throws -> JSONProjectStore` using a fresh journal and canonical activation without a bootstrap handoff. Use the existing durable-file boundary hooks for file fsync, rename and directory fsync failures.

- [ ] Write a parameterized RED over existing boundaries; drop store/journal instances after injected failure and reopen twice. Assert exact predecessor before domain commit, exact candidate after it, exact pending identities, retained receipt and absence of repeated domain effect.

```swift
for _ in 0..<2 {
    let reopened = try f.reopen()
    let prepared = try reopened.prepareRemoteBatch(batch, attachmentSources: [:])
    let result = try reopened.commitRemoteBatch(prepared)
    #expect(try f.journal.pending().map(\.identity) == expectedIdentities)
    #expect(try f.checkpoints.load()?.records == expectedRecords)
    // After a durable original commit, result must be alreadyCommitted.
    #expect(result == .alreadyCommitted(expectedReceipt))
}
```

Build `expectedRecords`, `expectedIdentities`, `expectedReceipt` from the retained transaction's exact candidate/receipt plus original pending, not from the newly reopened result. For before-archive faults, assert preserved predecessor and then one fresh successful commit rather than using the after-commit oracle.

- [ ] Add corrupt/partial intent, missing checkpoint, wrong root, symlink/media substitution, receipt overflow, retirement interruption, unconfirmed receipt retention and duplicate-after-later-local-edit cases. Verify unexpected data remains for recovery.
- [ ] Run `--filter JSONProjectStoreRemoteBatchRecoveryTests`; record each intended failure.
- [ ] Extend startup recovery's version/source dispatch to complete the exact remote candidate. Do not re-run projection or generate new mutation UUIDs during repair. Block general editing until repair completes; preserve old format recovery behavior.
- [ ] Re-run remote tests plus existing canonical durability suite; commit `test(sync): verify remote batch crash recovery`.

### Task 5: Real coordinator adapter, epoch and ACK ordering

**Files:**
- Create: `KnitNote/CloudSync/JSONProjectStoreRemoteBatchCommitter.swift`
- Modify: `KnitNote/CloudSync/KnitNoteCloudSyncCoordinator.swift`
- Modify: `KnitNote/CloudSync/CloudSyncEngineTransport.swift`
- Modify: `KnitNote/CloudSync/CloudSyncEngineStateStore.swift`
- Modify: `Tests/KnitNoteAppTests/KnitNoteCloudSyncCoordinatorTests.swift`
- Create: `Tests/KnitNoteAppTests/RemoteBatchCommitterIntegrationTests.swift`
- Modify: `KnitNote.xcodeproj/project.pbxproj`

**Interfaces:** Change only fetched-batch protocol input to raw Core batch; keep existing conflict method signature. Add post-ACK method and transport evidence query:

```swift
func commitFetchedBatch(batch: SyncRemoteBatch,
    accountEpoch: CloudSyncAccountEpoch) async throws
func didAcknowledgeFetchedBatch(batch: SyncRemoteBatchIdentity,
    accountEpoch: CloudSyncAccountEpoch) async throws
// CloudSyncTransport; real implementation consults durable incoming storage.
func verifyFetchedBatchAcknowledgement(_ batchID: UUID) async throws
```

`JSONProjectStoreRemoteBatchCommitter` is MainActor and conforms to `SyncFetchedBatchCommitting`; initializer consumes store, expected `SyncAccountIdentity`, attachment-source resolver `(SyncRemoteBatch) async throws -> [UUID: SyncAttachmentSource]`, and an ACK verifier `(SyncRemoteBatchIdentity) throws -> Void` bound to the durable incoming store. Async transport ACK verification alone is insufficient: the synchronous injected verifier revalidates on receipt retirement. Give fake implementations explicit behavior in tests; no permissive default on the protocol.

- [ ] Add real-adapter/fake-transport RED: one partial batch commits store before ACK; durable failure means zero ACK; unchanged batch retry preserves FIFO; epoch invalidation after attachment await causes zero write/ACK; failed ACK leaves receipt; successful durable ACK enables safe retirement. Account hash is computed from verified container/user binding and checked against both batch and store, not accepted from remote payload.
- [ ] Adapt existing coordinator test doubles to the raw batch API without reducing their assertions. Keep conflict-rebase tests intact. Add a test invoking real adapter `commitServerRecordChanged` and assert `unsupportedConflictReplacement`, original FIFO unchanged, needs-attention instead of synced.
- [ ] Run actual coordinator tests in an isolated no-host test harness. Reuse and inspect the previous Plan 3 no-host harness if present; otherwise create a task-owned temporary Swift package importing actual Core/CloudSync source files and adapted test imports, excluding KnitNoteApp and live initialization. Run `swift test --list-tests` first and confirm required suites exist. Never fall back to launching the regular App test host.
- [ ] Implement coordinator raw-batch forwarding (do not merge partial state before adapter), adapter bounded stale retries (maximum 3), epoch `withCurrent` around each final synchronous commit, and validated ACK retirement. Exhaustion returns a retryable failure and keeps incoming data; never spin indefinitely.
- [ ] For transport ACK proof, add read-only checks to `FileCloudIncomingBatchStore` matching account/zone and stored acknowledgement or verified absence. Protect evidence reads with existing store synchronization/identity checks; contradictory or unreadable data throws. Cleanup failure remains visible and retains receipts; it does not erase durable domain commit.
- [ ] Re-run integration, source-observation, account-transition and conflict coordinator tests without App host; commit `feat(sync): connect verified remote batch commit adapter`.

### Task 6: Combined acceptance and scoped handoff

**Files:**
- Modify: `Tests/KnitNoteCoreTests/JSONProjectStoreRemoteBatchRecoveryTests.swift`
- Modify: `Tests/KnitNoteAppTests/RemoteBatchCommitterIntegrationTests.swift`
- Create: `docs/superpowers/reports/2026-09-05-remote-batch-verification.md`

**Interfaces:** Consume Tasks 1–5 only. No production lifecycle/UI activation.

- [ ] Add combined tests: six counters/Watch proofs + another project's partial remote update; valid staged attachment + preserved historical heads; tombstone with proven retention vs unsupported raw delete; local edit between ACK failure and duplicate delivery; receipt saturation and acknowledged retirement. Each test asserts exact records, payload/FIFO identities and files, not merely no error.
- [ ] Run focused Core and actual coordinator no-host tests; reject zero-test selections. Then run full Core once under the 1,800-second bound. Record actual counts, failures, warnings, timeout and process exit; focused success cannot replace a full failure.
- [ ] Run `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/remote-batch-derived CODE_SIGNING_ALLOWED=NO build-for-testing`. Run `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/remote-batch-ios-derived CODE_SIGNING_ALLOWED=NO build` when its installed SDK is available; if unavailable, record that explicit validation gap. No test host, installation, archive/export, or signing workaround.
- [ ] Review the complete source diff against the approved spec and resolve Critical/Important issues in one scoped fix wave with targeted re-verification; any changed source invalidates the prior final candidate test claim.
- [ ] Record final SHA, source hash, full/targeted evidence, production-disabled status and remaining gates (server-record-changed CAS adapter, complete deletion-media/marker transport, real lifecycle ownership/freeze, UI/Watch wiring and all-device acceptance).
- [ ] Run `git diff --check`, commit exact report/tests as `docs(sync): record remote batch verification and remaining gates`, and keep the branch/worktree. No merge, push, schema deployment, upload or submission is part of this plan.

## Self-review map

- Spec §§1–3 scope/architecture: global constraints and file map.
- §4 identity/full-state/CAS/account ordering: Tasks 1, 3, 5.
- §5 attachment/deletion/FIFO/metadata-only: Tasks 3, 4, 6.
- §6 format/restart/bounded receipts/ACK retirement: Tasks 2–5.
- §7 notifications and unsupported conflict path: Tasks 3, 5, 6.
- §8 full acceptance matrix: Tasks 1–6; real-device tests explicitly remain outside this plan.
- §9 completion evidence: Task 6. No implementation or fresh test completion is claimed by this document.
