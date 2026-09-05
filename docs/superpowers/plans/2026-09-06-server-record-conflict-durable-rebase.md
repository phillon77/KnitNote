# Server Record Conflict Durable Rebase Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Durably rebase a conflicted record's complete pending FIFO without losing later edits, accepting stale ACKs, or exposing partially committed state.

**Architecture:** Core computes from raw conflict input and complete canonical authority. Extend the existing journal with explicit versioned replacement/ACK transitions and the existing publication transaction with conflict recovery evidence; the App adapter owns epoch ordering and transport handoff. Keep production activation closed.

**Tech Stack:** Swift 6, Foundation, CryptoKit, Swift Testing, existing file-backed journal/checkpoint/publication, isolated CloudKit transport interfaces.

**Spec:** `docs/superpowers/specs/2026-09-06-server-record-conflict-durable-rebase-design.md`, approved by the user after `497007382d513967e7371c79a323ea8a8daee6ca`.

## Global Constraints

- Version stays **1.7.0（13）**; continue in `.worktrees/cross-device-sync-design`, branch `docs/cross-device-sync-design`. Verify actual HEAD and preserve user changes before execution.
- No App host, live CloudKit, Keychain, user data, UI/Watch activation, purchase, localization, signing-setting, merge, push, upload or submission changes.
- Preserve **100,000,000-byte** authority/verified-file limits and the journal's stricter **64 * 1_024 * 1_024-byte** limit. Reject the entire projected transaction/checkpoint before durable intent if any bound is exceeded.
- Preserve each mutation's recordID, mutationID, intent and global FIFO position; compare complete versions and source evidence, not just identities. Unrelated records, receipts, tombstones, Watch proofs, media/history and FIFO payloads remain intact.
- Keep ordinary enqueue immutable: same ID plus unauthorized different content remains an error. Only an explicit validated rebase transition changes a pending version.
- Final epoch validation, authority CAS and durable work are synchronous inside `CloudSyncAccountEpoch.withCurrent`; no await or external callback under ownership locks.
- One shared budget of **3 attempts per conflict event**, covering preparation, commit and transport coordination; no nested retry budgets or unconditional self-rescheduling.
- Failure retains authoritative data and evidence. No success stubs, swallowed validation errors, guessed deletion/ACK, arbitrary cleanup, or permanent unbounded attempt set.
- Earlier full Core **2,369/174** belongs to `c7465f8`, not this plan's code. Final verification must bind the final source/test candidate, warnings and exact commands.

## File ownership and task order

1. `SyncConflictRebase.swift`: public validated conflict/version contracts and internal durable transition structures; real fixture and Xcode Core consumers.
2. `SyncMutationJournal.swift`: exclusive full-FIFO replacement, retained transition validation, versioned ACK and backward-compatible journal persistence.
3. `SyncMutationPublishing.swift`: publication format 7 conflict source and complete deterministic recovery evidence.
4. `JSONProjectStore.swift`: narrow conflict preparation/commit/recovery entry points; no unrelated store refactor.
5. Core recovery tests: actual fault boundaries, exact oracles, completely fresh handles.
6. App coordinator/adapter/transport/system-fields integration: raw input, exact failed-attempt/version authority, versioned ACK/cleanup, bounded retry and all conformers.
7. Combined acceptance and frozen-candidate report.

The tasks are sequential. A task may be reviewed independently, but later tasks cannot treat an unfinished replacement/ACK path as production enabled. Read this spec and plan in full at execution start. Carry Global Constraints and shared contract definitions into extracted task briefs; the extraction script does not include preceding context automatically.

## Shared contract and wire decisions

Public Core contracts, defined in Task 1 (constructors validate; no public/memberwise preparation constructor):

```swift
public struct SyncMutationVersionToken: Codable, Equatable, Sendable {
    public let identity: SyncMutationIdentity
    public let contentSHA256: Data
    public let journalRevision: UInt64
    public init(mutation: SyncMutation, journalRevision: UInt64 = 0) throws
}
public struct SyncVersionedMutation: Codable, Equatable, Sendable {
    public let mutation: SyncMutation
    public let token: SyncMutationVersionToken
    public init(mutation: SyncMutation, journalRevision: UInt64) throws
}
public struct SyncConflictInput: Codable, Equatable, Sendable {
    public let accountIDHash: String
    public let failedAttemptID: UUID
    public let failedMutation: SyncMutation
    public let failedVersion: SyncMutationVersionToken
    public let serverRecord: SyncRecord
    public let expectedRecordQueue: [SyncMutation]
    public let expectedVersions: [SyncMutationVersionToken]
    public init(accountIDHash: String, failedAttemptID: UUID,
        failedMutation: SyncMutation, failedVersion: SyncMutationVersionToken,
        serverRecord: SyncRecord, expectedRecordQueue: [SyncMutation],
        expectedVersions: [SyncMutationVersionToken]) throws
}
public struct SyncConflictPreparation: Sendable {
    let liveRoot: URL
    let input: SyncConflictInput
    let predecessor: SyncCanonicalCheckpoint
    let authority: [SyncRemoteAuthorityFile]
    let pending: [SyncVersionedMutation]
    let transaction: SyncPublicationTransaction?
    let previousResolution: SyncConflictResolution?
}
public struct SyncConflictResolution: Codable, Equatable, Sendable {
    public let transactionID: UUID
    public let input: SyncConflictInput
    public let replacement: SyncMutation
    public let followingReplacements: [SyncMutation]
    public let versions: [SyncMutationVersionToken]
}
public enum SyncConflictCommitResult: Equatable, Sendable {
    case committed(SyncConflictResolution)
    case stalePredecessor
    case obsoleteFailure
}
public enum SyncConflictError: Error, Equatable, Sendable {
    case invalidInput, missingAuthority, identityCollision, capacity
}
public enum SyncVersionedAcknowledgementResult: Equatable, Sendable {
    case acknowledged, alreadyAcknowledged, staleVersion
}
```

`SyncMutationVersionToken` hashes a version-1 sorted-key JSON payload of identity, intent, complete `savedRecordVersion`, and optional attachment byte count/hash, and separately binds `journalRevision`. Revision0 is only the originally issued version; every actual rebase advances the affected mutation's revision by exactly1, checked for overflow, even if the content returns to an earlier value. This prevents A→B→A stale ACK acceptance. Local URL and `isJournalStaged` are excluded from this portable upload token; full Core/journal CAS separately compares actual `SyncMutation` values and validates file identity/content. Decode must revalidate identity and32-byte digest; pairing a token with a mutation must recompute its content hash and verify its revision against journal authority. Default revision0 is fixture/new-issued convenience, never a fallback for an existing rebased mutation.

`SyncConflictInput` requires a lowercase 64-hex account hash, a nonempty unique same-record FIFO, exact failed/server/head identities and validated records/mutations. A failed payload differing from the current queue head is not automatically trusted: only Core's retained transition for the same failed attempt, raw server content and original failed token can prove prior local rebase during transport-handoff retry. Newer unrelated attempts make the old input obsolete. Each preparation gets a new transaction UUID; one UUID with changed bytes is an identity collision, not a retry.

Validate expectedVersions count/order/content against every expectedRecordQueue item, and failedVersion against the original failedMutation. A caller cannot choose a higher revision to authorize itself; Core/journal verify all revisions against retained native history. A nil preparation transaction with a previousResolution means proven already-committed effect; with neither it means obsoleteFailure. Commit still revalidates current ownership/authority before returning either result.

Internal `SyncJournalRebaseTransition` fields: `version = 1`, `transactionID`, `input`, `predecessorPendingSHA256`, `recordPositions: [Int]`, `before: [SyncMutation]`, `after: [SyncMutation]`, `beforeVersions: [SyncMutationVersionToken]`, `afterVersions: [SyncMutationVersionToken]`, `integrity`. `before`/beforeVersions equal input.expectedRecordQueue/expectedVersions. `after` preserves identity/intent sequence and count, with each afterVersion revision exactly its beforeVersion+1 and matching content. The digest binds ordered complete global versioned pending; positions bind selected slots. Integrity binds every field except itself. The publication source retains the full global versioned predecessor snapshot. Define internal `SyncConflictRebaseCoding.pendingDigest(_ mutations: [SyncVersionedMutation]) throws -> Data` in Task1 using sorted-key encoding/SHA-256, including the full mutation/source and token.

Journal persistence:

- Keep frame envelope version 1 and old kinds 1 enqueue / 2 identity ACK / 3 cleanup unchanged. Add kind **4 rebase** carrying a complete validated transition and kind **5 versionedAcknowledgement** carrying a `SyncMutationVersionToken`. Both include existing frame sequence/checksum/trailer handling.
- New checkpoint **version 5** adds ordered `rebaseHistory: [SyncJournalRebaseTransition]`, included in strict validation; versions 1–4 decode exactly as before with no history. A v5 checkpoint remains v5 after ordinary successors. Newly rebased histories must never be serialized as v4.
- Preserve issued immutable proof shards. Rebase history is a separate authority field inside the same native journal checkpoint, not a second ledger/file writer. Derive current effective proofs by validating ordered authorized transitions against issued proofs. Recovery queries may recognize an exact predecessor proof along that chain; current ACK/enqueue/cleanup checks must use the effective current version.
- Checkpoint compaction retains the ordered validated transition history, including after ACK; no history pruning in this plan. Enforce the existing 64 MiB checkpoint limit on the projected history before intent. This is bounded conservative retention, not unlimited deduplication; reaching capacity safely blocks further rebase and is recorded as an activation/performance limitation. Do not silently drop history or introduce a new arbitrary count cap.
- An old kind-2 identity-only ACK may remove only a mutation that has never been rebased. Any rebased current version requires kind 5, including when later content happens to equal its issued content. Legacy replay before the first rebase remains valid.

Publication **format 7** adds optional `conflictSource`; formats 2–6 retain their original integrity/decoding. `remoteSource` and `conflictSource` are mutually exclusive. Conflict source contains version 1, raw input, full retained predecessor/remote-style durable candidate plan, journal transition, full before/after pending snapshots, exact media/evidence and a matching canonical transition. Conflict transactions must not use the ordinary append mutations path. Zero-domain-change rebase is still a real metadata transaction with no extra domain notification.

## Verification commands

Core commands run from the linked worktree. Replace only the named filter/log per task; use serial builds, exact exit status, nonzero selection and captured warnings:

```zsh
set -o pipefail
env CLANG_MODULE_CACHE_PATH=/tmp/conflict-rebase-clang-cache /usr/bin/arch -arm64 /usr/bin/swift test --disable-sandbox --no-parallel --cache-path /tmp/conflict-rebase-swift-cache --config-path /tmp/conflict-rebase-swift-config --security-path /tmp/conflict-rebase-swift-security --filter 'SyncConflict' 2>&1 | tee /tmp/conflict-rebase-task1.log
```

Task 6 creates `/private/tmp/conflict-rebase-harness` from the actual-source layout of `/private/tmp/remote-batch-task6-harness`; read its Package.swift before reuse. The new harness includes the required five existing suites plus the new conflict suite, and compiles the live suite without executing it. Use supported `swift test list`, not deprecated discovery. Keep Core and harness caches separate; no simultaneous Swift/Xcode runs.

### Task 1: Validated conflict/version contracts and a real fixture

**Files:**
- Create: `Sources/KnitNoteCore/CloudSync/SyncConflictRebase.swift`
- Create: `Tests/KnitNoteCoreTests/ConflictRebaseFixture.swift`
- Create: `Tests/KnitNoteCoreTests/SyncConflictInputTests.swift`
- Modify: `KnitNote.xcodeproj/project.pbxproj` (new Core source only, every existing consumer that includes SyncRemoteBatch.swift)

**Interfaces:** Produces the public contracts and internal transition shape above. Test fixture wraps the existing `RemoteBatchFixture`, preserving real bootstrap/fresh-handle APIs. Produce `@MainActor struct ConflictRebaseFixture` with `base: RemoteBatchFixture`, `init() throws`, `input(attemptID: UUID = UUID()) throws -> SyncConflictInput`, and `remove()`; initialization ACKs bootstrap then calls `renameLocally("Local 1")`, `renameLocally("Local 2")`, `renameLocally("Local 3")`. `input` reads actual same-record pending and uses `base.renamedBatch("Server", id: UUID()).records[0]`; Task1 fixture-issued entries all have revision0. Task2 changes the fixture to read journal.pendingVersioned() once that method exists, never infer revision0 after rebase. failedVersion is the captured original attempted token, expectedVersions describe the current exact queue. Never forge a handoff.

- [ ] Write token/input tests before production implementation. Use actual immutable versions from the fixture:

```swift
@Test @MainActor func differentPayloadWithSameIDHasDifferentToken() throws {
    let f = try ConflictRebaseFixture(); defer { f.remove() }
    let input = try f.input()
    let first = input.expectedRecordQueue[0]
    let changed = try SyncMutation.save(recordVersion: SyncRecordVersion(record: input.serverRecord),
        mutationID: first.mutationID)
    #expect(first.identity == changed.identity)
    #expect(try SyncMutationVersionToken(mutation: first) != SyncMutationVersionToken(mutation: changed))
}
```

- [ ] Run filter `SyncConflictInputTests`, log `/tmp/conflict-rebase-task1-red.log`. Missing-type compile failure is scaffold evidence only; after contracts compile, prove behavior RED for omitted token content or missing input validation before completing implementation.
- [ ] Implement the token payload encoding and strict `init`/`init(from:)`. Reject invalid account, server/head mismatch, empty queue, duplicate IDs, multiple recordIDs, invalid attachment binding and malformed digest. Do not claim caller-created input is a verified failed transport attempt.
- [ ] Implement transition validation and integrity encoding. Its positional rule is:

```swift
guard !before.isEmpty, before == input.expectedRecordQueue,
      before.map(\.identity) == after.map(\.identity),
      before.map(\.intent) == after.map(\.intent),
      recordPositions.count == before.count,
      recordPositions == recordPositions.sorted(),
      Set(recordPositions).count == recordPositions.count,
      recordPositions.allSatisfy({ $0 >= 0 }) else { throw SyncConflictError.invalidInput }
```

- [ ] Verify same payload token repeatability, altered record field/deletion overlay/attachment content token changes, portable-token equality after safe source relocation, ordered queue digest changes, same transactionID/content mismatch refusal, and encoded-size rejection. Fixture must have exactly three same-record saves, not merely nonempty.
- [ ] Run Task 1 filter plus `SyncRemoteBatchTests`; plutil-lint the project; record exact test count and warnings. Commit only the four named files.

### Task 2: Native journal CAS replacement and version-bound ACK

**Files:**
- Modify: `Sources/KnitNoteCore/CloudSync/SyncMutationJournal.swift`
- Modify: `Sources/KnitNoteCore/CloudSync/SyncConflictRebase.swift`
- Create: `Tests/KnitNoteCoreTests/SyncConflictJournalTests.swift`
- Modify: `Tests/KnitNoteCoreTests/SyncMutationJournalSegmentTests.swift`
- Modify: `Tests/KnitNoteCoreTests/SyncMutationJournalFinalFixTests.swift`
- Modify: `Tests/KnitNoteCoreTests/SyncPendingRecoveryPacketTests.swift` (PacketJournalSnapshot conformance)
- Modify: `Tests/KnitNoteAppTests/KnitNoteCloudSyncCoordinatorTests.swift` (FakeCoordinatorJournal conformance only)
- Modify: `Tests/KnitNoteCoreTests/ConflictRebaseFixture.swift` (read actual versioned snapshot)

**Interfaces:** Extend `SyncJournalWriteLease` with `pendingVersioned() throws -> [SyncVersionedMutation]`, `preflightRebase(_ transition: SyncJournalRebaseTransition) throws`, `rebase(_ transition: SyncJournalRebaseTransition) throws -> Bool` (false only exact predecessor mismatch), and `retainedRebases(for input: SyncConflictInput) throws -> [SyncJournalRebaseTransition]` ordered from oldest to newest. Add required protocol methods `pendingVersioned() throws -> [SyncVersionedMutation]` and `acknowledgeCurrentVersion(_ token: SyncMutationVersionToken) throws -> SyncVersionedAcknowledgementResult`; File journal is the real implementation. Snapshot+revision read is atomic under the journal lock. Other conformers explicitly implement atomic compare/remove or throw missing authority; PacketJournalSnapshot is read-only and must throw for ACK. No default read-then-identity-ACK success implementation. Task6 migrates production transport callers.

- [ ] Write a real journal test with three same-record saves interleaved with another record's saves. Capture complete `pending()` and full journal tree. Build a validated transition replacing each selected payload, retaining original indices; assert one durable frame and exact global after-array. Change expected payload but retain IDs and verify false/stale with byte-identical authority.
- [ ] Run filter `SyncConflictJournalTests`; retain behavior RED for stale same-ID versions and missing native transition persistence.
- [ ] Add kinds 4/5, checkpoint v5 and ordered retained history exactly as Shared decisions. Decode and replay v1–4 fixtures unchanged. Implement pure selection reconstruction before IO:

```swift
guard try SyncConflictRebaseCoding.pendingDigest(currentPending) == transition.predecessorPendingSHA256,
      currentPending.enumerated().filter({ $0.element.mutation.recordID == transition.input.serverRecord.id }).map(\.offset)
        == transition.recordPositions,
      transition.recordPositions.map({ currentPending[$0].mutation }) == transition.before,
      transition.recordPositions.map({ currentPending[$0].token }) == transition.beforeVersions else { return false }
var candidatePending = currentPending
for (index, position) in transition.recordPositions.enumerated() {
    candidatePending[position] = try SyncVersionedMutation(mutation: transition.after[index],
        journalRevision: transition.afterVersions[index].journalRevision)
}
```

`currentPending` and `candidatePending` are complete `[SyncVersionedMutation]` snapshots. Full mutation encoding includes local source authority, unlike the portable upload token. Check decoded indices against array counts before subscripting; validate revision increment/no overflow and exact after-token content before construction.
- [ ] Preflight transition/frame and projected compacted checkpoint sizes before staging/appending. Run attachment lineage/content validation over issued plus explicitly authorized effective proofs; retain immutable snapshot constraints. Rebase cannot manufacture a different immutable attachment under the same version ID.
- [ ] Keep ordinary enqueue collision rejection and make same-current-version duplicates no-op; older superseded payload must not enqueue or replace current data. Implement effective proof lookup without overwriting original immutable proof shards. Compaction must replay an ordered proof chain; reordered/missing/colliding transitions fail closed.
- [ ] Implement versioned ACK in the same journal lock. Compare portable token to the effective current pending version; stale token leaves journal and bytes untouched. Missing pending returns alreadyAcknowledged only with retained proof of ACK for that exact effective version, not merely a seen mutation ID. The frame persists this version binding. Existing identity ACK refuses rebased IDs.
- [ ] Test old-token ACK after rebase, content returning to an older value, repeated rebase/ACK/reopen/compaction, partial final frame, rolled-back checkpoint, missing proof shard, capacity preflight and attachment cleanup. Preserve reference-safe cleanup and exact current version even though issued proof shards describe the original version; cleanup completion offsets cannot bypass rebase history validation.
- [ ] Run `SyncConflictJournal|SyncMutationJournal` serially; review complete counts/warnings, then commit exact changed source/tests. Keep scope expansion to protocol conformers explicit in report.

### Task 3: Publication format 7 and reconstructable conflict source

**Files:**
- Modify: `Sources/KnitNoteCore/CloudSync/SyncMutationPublishing.swift`
- Modify: `Sources/KnitNoteCore/CloudSync/SyncConflictRebase.swift`
- Create: `Tests/KnitNoteCoreTests/SyncConflictPublicationTests.swift`
- Modify: `Tests/KnitNoteCoreTests/SyncCanonicalPublicationTransactionTests.swift`
- Modify: `Tests/KnitNoteCoreTests/SyncRemoteBatchTransactionTests.swift`

**Interfaces:** Add internal `SyncConflictPublicationSource: Codable, Equatable, Sendable` with `version`, `input`, `transition`, `plan: SyncRemoteBatchDurablePlan`, `beforePending: [SyncMutation]`, `afterPending: [SyncMutation]`, `beforeVersions: [SyncMutationVersionToken]`, `afterVersions: [SyncMutationVersionToken]`. Add optional `conflictSource` initializer/field to `SyncPublicationTransaction`; format7 only. Inspected SyncRemoteBatchDurablePlan has no batch receipt: reuse its predecessor, authority, pending, raw records, archive and media fields without changing format6 encoding. Keep raw records `[input.serverRecord]`, empty raw deletion IDs, matching predecessor/global pending and validated complete candidate in the outer canonical transition; never fabricate a fetched-batch receipt.

- [ ] Write fixed nonempty old format2–6 decoding/re-encoding tests and a format7 conflict roundtrip. Capture old fixtures before modifying writers. Test both source fields set, changed transition digest, candidate/queue mismatch and missing media plan are rejected.
- [ ] Run filter `SyncConflictPublicationTests`, retain RED. Add format7 integrity fields and reject conflictSource on old versions rather than ignoring it. New ordinary/remote writes may use format7 with nil conflictSource; existing readback does not silently upgrade old evidence.
- [ ] Add exact relationships to source validation:

```swift
guard source.transition.input == source.input,
      source.transition.before == source.input.expectedRecordQueue,
      source.beforePending.count == source.afterPending.count,
      source.transition.recordPositions.map({ source.beforePending[$0] }) == source.transition.before,
      source.transition.recordPositions.map({ source.afterPending[$0] }) == source.transition.after
else { throw SyncPublicationError.corruptTransaction }
```

Check bounds before indexing; compare every unselected position's full mutation and version token exactly. before/afterVersions parallel their corresponding complete pending arrays and match transition selected versions. Bind canonical/source/account/transactionID, original/candidate archive hashes, required media/evidence and projected journal replacement. Conflict uses an empty ordinary append mutations array; the sole FIFO change is the explicit transition.
- [ ] Check total encoded publication ≤100,000,000 and projected journal checkpoint/frame ≤64 MiB before writing intent. Exercise just-under/over real encoded payloads; a small valid fixture plus test-injected lower limit may supplement, not replace, actual boundary coverage.
- [ ] Run `SyncConflictPublication|SyncCanonicalPublicationTransaction|SyncRemoteBatchTransaction`, record count/exit/warnings and commit exact files. This task supplies format authority only; it does not activate store conflict handling.

### Task 4: Core complete-state conflict preparation, commit and recovery

**Files:**
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Sources/KnitNoteCore/CloudSync/SyncMutationPublishing.swift`
- Modify: `Sources/KnitNoteCore/CloudSync/SyncConflictRebase.swift`
- Create: `Tests/KnitNoteCoreTests/JSONProjectStoreConflictRebaseTests.swift`
- Modify: `Tests/KnitNoteCoreTests/ConflictRebaseFixture.swift`

**Interfaces:** Implement on MainActor JSONProjectStore:

```swift
public func prepareConflictRebase(_ input: SyncConflictInput,
    attachmentSources: [UUID: SyncAttachmentSource]) throws -> SyncConflictPreparation
public func commitConflictRebase(_ preparation: SyncConflictPreparation,
    withCommitOwnership: (_ work: () throws -> SyncConflictCommitResult) throws -> SyncConflictCommitResult
        = { try $0() }) throws -> SyncConflictCommitResult
```

Reuse `onRemoteDomainCommitted` after ownership wrapper returns. Core makes one attempt; no retry loop. The preparation retains raw input, complete predecessor and precomputed validated candidate/source/transition; only Core constructs it.

- [ ] Add the real stale-edit RED test:

```swift
@Test @MainActor func laterEditRejectsPreparedConflictWithoutMutation() throws {
    let f = try ConflictRebaseFixture(); defer { f.remove() }
    let p = try f.base.store.prepareConflictRebase(f.input(), attachmentSources: [:])
    try f.base.renameLocally("After preparation")
    let archive = try Data(contentsOf: f.base.archiveURL)
    let checkpoint = try f.base.checkpoints.load()
    let pending = try f.base.journal.pending()
    #expect(try f.base.store.commitConflictRebase(p) == .stalePredecessor)
    #expect(try Data(contentsOf: f.base.archiveURL) == archive)
    #expect(try f.base.checkpoints.load() == checkpoint)
    #expect(try f.base.journal.pending() == pending)
}
```

- [ ] Run `JSONProjectStoreConflictRebaseTests`. Then compute sequential per-mutation merge with the actual merge engine: first failed save against raw server, each following immutable version against prior result. Preserve original ID/intent/attachment snapshot; validate complete final canonical/relationships with full authority, not a partial archive. Manually expected field values/records in tests must not simply call the same merge helper as the production oracle.
- [ ] Handle previously locally committed conflict during handoff retry using retained transition proof for exact failed attempt/server/original token. Accept authorized current queue descendants only; unrelated/newer failure is obsolete. A repeated identical effect must reuse existing durable result/no-op rather than create unbounded metadata-only transitions. A genuinely later queued local edit requires a new validated candidate and transaction ID within the shared event budget.
- [ ] Prepare media on full-record/evidence change, including nil-deletion overlay stamp-only changes. Preflight complete evidence apply/validation, archive/canonical encodings, journal transition/projection and file identity before intent. Missing deletion/attachment/parent evidence blocks; do not add the deferred deletion transport.
- [ ] In the existing lock order, revalidate all predecessor authorities and exact global pending, then write format7 intent and complete media/archive/evidence/journal/canonical. Route to `lease.rebase`, never enqueue replacements. Retain intent on any later error. New journal history must not be mistaken for unrelated inventory mutation during this transaction's recovery.
- [ ] Extend activation/recovery dispatch for conflictSource before ordinary/fetched branches. Use retained original candidate and transition. Recognize native proof-backed partial completion and legal later ACK/append/rebase; missing/rolled-back journal is not ACK. Callbacks run after locks; no domain change means no generation increment.
- [ ] Add successful exact three-save/global-FIFO oracle, complete unrelated records/receipts/Watch/media preservation, same-stamp failure, missing authority, callback epoch reentry, metadata-only behavior and durable-repeat tests. Run `JSONProjectStoreConflictRebase|SyncConflict|JSONProjectStoreRemoteBatch`; commit exact files after self-review.

### Task 5: Fault boundaries and completely fresh recovery oracles

**Files:**
- Create: `Tests/KnitNoteCoreTests/JSONProjectStoreConflictRecoveryTests.swift`
- Modify: `Tests/KnitNoteCoreTests/ConflictRebaseFixture.swift`
- Modify: `Tests/KnitNoteCoreTests/RemoteBatchFixture.swift` only for narrow shared fresh-handle helpers
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift` only if a missing internal default-noop fault seam is proven

**Interfaces:** Reuse `SyncCanonicalPublicationBoundary.allCases`, existing durable media boundary hook and fixture fresh-store/handle-release facilities. Add no production format merely for tests. Fixture must capture independent complete expected checkpoint/queue/evidence/file snapshots and original transaction before the fault.

- [ ] Parameterize a real conflict over every existing canonical publication boundary, plus native journal rebase append/checkpoint and required media file/rename/directory-sync boundaries. Trigger each actual fault once and prove it fired; a test that simply commits successfully does not cover a failure boundary.
- [ ] For each boundary, retain original expected transaction/candidate, release initial store/journal/checkpoint handles with weak-deallocation assertion, then create two independent store+journal+checkpoint sets. Each recovery either reaches the same exact original candidate or preserves all authority on documented refusal; replay never regenerates IDs/stamps or repeats callback/domain effects.

```swift
@Test(arguments: SyncCanonicalPublicationBoundary.allCases)
@MainActor func conflictRecoveryRetainsExactCandidateTwice(
    boundary: SyncCanonicalPublicationBoundary) throws {
    let f = try ConflictRebaseRecoveryFixture(boundary: boundary)
    defer { f.remove() }
    try f.commitExpectingInjectedBoundary()
    try f.dropInitialHandlesAndAssertReleased()
    try f.reopenAndAssertOriginalCandidate()
    try f.reopenAndAssertOriginalCandidate()
}
```

Define `ConflictRebaseRecoveryFixture` in ConflictRebaseFixture.swift with these exact methods; each reopen method owns fresh local handles and drops them before returning, and assertions compare retained full values rather than recomputing production merge outputs. Use Swift Testing assertions for checkpoint, entire ordered mutations, every record/proof, archive/evidence/journal file trees, installed/staged bytes and inode where unchanged.
- [ ] Test missing/old journal, partial frames/temp, unrelated append, copied/replaced root, archive/media symlink, missing proof shard and account mismatch. Snapshot all involved roots and complete journal authority before refusal, including displaced originals.
- [ ] Exercise legitimate later ACK, compaction and local append with exact retained proof; these must not appear identical to missing-journal data loss. Test overlay-only attachment update with history and both normal/after-intent reopens.
- [ ] For already-correct Task4 behavior, record injected-failure evidence and one narrow test-oracle mutation RED; do not manufacture a production defect. Restore mutation byte-for-byte and rerun `JSONProjectStoreConflict|SyncConflict|SyncMutationJournalFinalFix` before commit. Record actual source changes, if any, because they invalidate earlier candidate verification.

### Task 6: Raw conflict adapter, exact transport handoff and stale-ACK rejection

**Files:**
- Modify: `KnitNote/CloudSync/JSONProjectStoreRemoteBatchCommitter.swift`
- Modify: `KnitNote/CloudSync/KnitNoteCloudSyncCoordinator.swift`
- Modify: `KnitNote/CloudSync/CloudSyncEngineTransport.swift`
- Modify: `KnitNote/CloudSync/CloudRecordSystemFieldsStore.swift` only for scoped server-base verification
- Modify: `Tests/KnitNoteAppTests/KnitNoteCloudSyncCoordinatorTests.swift`
- Modify: `Tests/KnitNoteAppTests/CloudSyncEngineTransportTests.swift`
- Modify: `Tests/KnitNoteAppTests/RemoteBatchCommitterIntegrationTests.swift`
- Create: `Tests/KnitNoteAppTests/ConflictRebaseIntegrationTests.swift`
- Modify: `Tests/KnitNoteAppTests/CloudKitDevelopmentIntegrationTests.swift` (ProbeDurableCommitter compile-only)
- Modify: `Tests/KnitNoteAppTests/CloudAccountTransitionCoordinatorTests.swift` (TransitionDurableCommitter)
- Modify: `KnitNote/CloudSync/CloudAccountTransitionCoordinator.swift` (versioned schedule call sites)
- Modify: `KnitNote.xcodeproj/project.pbxproj` (new App test consumer only)
- All concrete conformers/callers of changed journal/transport/event contracts found by `rg`, including tests; no production default success fallback

**Interfaces:** Replace App conflict commit signature with `commitServerRecordChanged(input: SyncConflictInput, accountEpoch: CloudSyncAccountEpoch) async throws -> SyncConflictCommitResult`. Adapter validates/resolves once, prepares once, commits through ownership wrapper once. Change `.sent` to carry `token: SyncMutationVersionToken`, `attemptID: UUID`, `accountEpoch: CloudSyncAccountEpoch`. Extend failed events with the immutable attempted mutation plus its journal-authorized version token; no fallback to current payload. Change production scheduling to `schedule(_ mutations: [SyncVersionedMutation]) async throws`; coordinator/account-transition read atomic `journal.pendingVersioned()` and transport queues store these pairs. Standalone tests may explicitly construct revision0 issued inputs, but production cannot reconstruct revisions from plain pending() or default every replay to0.

Define `enum CloudConflictHandoffResult: Equatable, Sendable { case accepted, stale }` and `resolveFailedMutation(_ resolution: SyncConflictResolution, accountEpoch: CloudSyncAccountEpoch, expectedQueue: [SyncVersionedMutation]) async throws -> CloudConflictHandoffResult`. Add `verifySentMutation(_ token: SyncMutationVersionToken, attemptID: UUID, accountEpoch: CloudSyncAccountEpoch) async throws` and change cleanup to `acknowledgeSentMutation(_ token: SyncMutationVersionToken, attemptID: UUID) async throws`. Failed events carry `attempted: SyncVersionedMutation` in addition to existing failure/accountEpoch/attemptID fields; verify retained recordID/mutationID fields agree. Retain a failure-context entry containing attemptID, attempted token/full mutation, raw server digest and scoped persisted server-base evidence. A set of failed mutation IDs alone is insufficient. Registry entries live only while pending failed/handoff state requires them; generation/account reset invalidates them, restart rebuilds from durable journal and safe server refresh instead of guessing old attempt authority. Remove obsolete no-op ACK/default success conformances for the new signature.

- [ ] Build `/private/tmp/conflict-rebase-harness` with actual source symlinks and explicit test-file symlinks. Include `KnitNoteCloudSyncCoordinatorTests`, `CloudSyncEngineTransportTests`, `CloudAccountTransitionCoordinatorTests`, `CloudAssetFileStoreTests`, `RemoteBatchCommitterIntegrationTests`, `ConflictRebaseIntegrationTests`; compile/discover live integration tests but exclude them from all run filters. Verify every required suite has nonzero discovered tests.

Use a Package.swift with Swift tools6.0, macOS15, target KnitNote at Sources/KnitNote with sources `["KnitNoteCore", "CloudSync"]` and `.process("KnitNoteCore/Resources")`, plus testTarget KnitNoteAppTests at Tests/KnitNoteAppTests depending on KnitNote. Symlink Sources/KnitNote/KnitNoteCore and CloudSync to this worktree's actual directories; symlink the seven explicit test files (six required plus compile-only CloudKitDevelopmentIntegrationTests). If the target temporary path already exists, inspect ownership/layout instead of overwriting it. Supported discovery and actual run, from that harness directory:

```zsh
env CLANG_MODULE_CACHE_PATH=/tmp/conflict-rebase-clang-cache /usr/bin/arch -arm64 /usr/bin/swift test --disable-sandbox --cache-path /tmp/conflict-rebase-harness-cache --config-path /tmp/conflict-rebase-harness-config --security-path /tmp/conflict-rebase-harness-security list
set -o pipefail
env CLANG_MODULE_CACHE_PATH=/tmp/conflict-rebase-clang-cache /usr/bin/arch -arm64 /usr/bin/swift test --disable-sandbox --no-parallel --cache-path /tmp/conflict-rebase-harness-cache --config-path /tmp/conflict-rebase-harness-config --security-path /tmp/conflict-rebase-harness-security --filter 'KnitNoteCloudSyncCoordinatorTests|CloudSyncEngineTransportTests|CloudAccountTransitionCoordinatorTests|CloudAssetFileStoreTests|RemoteBatchCommitterIntegrationTests|ConflictRebaseIntegrationTests' 2>&1 | tee /tmp/conflict-rebase-nohost.log
```
- [ ] Add REDs: adapter real store no longer unsupported; delayed old `.sent` after same-ID rebase preserves pending/files; delayed old failed attempt cannot supersede newer failure; same identities with changed payload/queued suffix cannot pass transport handoff; stale preparation and stale transport share exactly three total attempts.
- [ ] Move raw conflict preparation into Core; remove obsolete coordinator partial premerge as an authority. Replace the unbounded conflict loop with one outer budget:

```swift
let account = try accountEpoch.verifiedAccountIdentity()
let failedIdentity = attempted.mutation.identity
for _ in 0..<3 {
    try accountEpoch.requireCurrent()
    let queue = try journal.pendingVersioned().filter { $0.mutation.recordID == serverRecord.id }
    guard queue.first?.mutation.identity == failedIdentity else { return }
    let input = try SyncConflictInput(accountIDHash: account.accountIDHash,
        failedAttemptID: attemptID, failedMutation: attempted.mutation,
        failedVersion: attempted.token, serverRecord: serverRecord,
        expectedRecordQueue: queue.map(\.mutation), expectedVersions: queue.map(\.token))
    switch try await fetchedBatchCommitter.commitServerRecordChanged(input: input, accountEpoch: accountEpoch) {
    case .stalePredecessor: continue
    case .obsoleteFailure: return
    case let .committed(resolution):
        let current = try journal.pendingVersioned().filter { $0.mutation.recordID == serverRecord.id }
        guard current.map(\.mutation) == [resolution.replacement] + resolution.followingReplacements,
              current.map(\.token) == resolution.versions else { continue }
        let accepted = try await transport.resolveFailedMutation(resolution,
            accountEpoch: accountEpoch, expectedQueue: current)
        guard accepted == .accepted else { continue }
        try accountEpoch.requireCurrent()
        clearConflictBlocker(failedIdentity)
        return
    }
}
failConflict(failedIdentity, issue: .durableCommit)
```

This is the retry/control-flow body inside handleMutationFailure after event validation; retain the existing status publish on accepted and existing typed catches outside it. `attempted`, `attemptID`, `serverRecord` and `accountEpoch` are the validated event fields. Preserve transport failure vs journal/authority error distinctions. Do not enlarge fetched-batch retries.
- [ ] Capture a version token from the actual queue head when creating `SendAttempt`; bind saved/deleted callbacks to its exact generation/attempt/intent/version. After all awaits, recheck context before mutating queue or publishing event. Persist/load matching scoped server system fields before retry; test wrong-account/server-body/change-tag context rejection with isolated CKRecord fixtures.
- [ ] Preserve a verified success context until journal ACK/cleanup finishes, keyed by token+attempt+epoch rather than mutationID alone. Ignore events lacking that exact transport success authority. If a success event is queued before another rebase, its old journalRevision must fail at the final journal CAS even for A→B→A content. Test duplicate upload attempts without rebase separately from a new rebase revision; do not conflate attempt identity with content equality.
- [ ] Coordinator first awaits `transport.verifySentMutation(token, attemptID: attemptID, accountEpoch: accountEpoch)`, then handles sent under final epoch ownership with `journal.acknowledgeCurrentVersion(token)`. The final CAS catches queue changes during that await. Stale is not success and must not invoke staged-asset cleanup; acknowledged/alreadyAcknowledged permit only exact-token transport cleanup. Change `acknowledgeSentMutation` to validate the same token/attempt so an old cleanup cannot remove new media.
- [ ] Transport replacement compares complete previous/candidate queue tokens and failure authority, not identity prefix. Preserve local suffix races by returning stale to the shared loop, not concatenating incompatible versions. Core committed + handoff failure stays durable; next retry/restart uses current journal. A recreated transport may safely receive another server conflict; no fabricated persisted failed event is needed.
- [ ] Tests exercise Core commit→transport rejection, restart, same-attempt duplicate after later local edit, new-generation old callbacks, raw delete without authority, stale server base, and injected cleanup error. Replace test scheduling-count waits with bounded observable completion, without weakening exact FIFO/error assertions.
- [ ] Run all six required no-host suites using arm64 and separate caches; run Core `SyncConflict|JSONProjectStoreConflict|SyncMutationJournal`; compile all conformers. Commit exact file list, include new App test in real Xcode test target if not auto-discovered, and report harness/warnings and still-disabled activation gates.

### Task 7: Combined acceptance, final review and frozen verification report

**Files:**
- Modify: `Tests/KnitNoteCoreTests/JSONProjectStoreConflictRecoveryTests.swift`
- Modify: `Tests/KnitNoteAppTests/ConflictRebaseIntegrationTests.swift`
- Create: `docs/superpowers/reports/2026-09-06-server-record-conflict-verification.md`

**Interfaces:** Consume completed Tasks1–6. No extra product behavior in this verification task without a concrete defect and scope ruling. Use the existing actual-source harness, real file-backed store and verified frozen-candidate commands.

- [ ] Add one combined Core case: three local saves interleaved with another project's FIFO, six Watch counter proofs, server field conflict, attachment history, interrupted publication, two fresh reopens. Assert entire manually expected canonical/queue and original unrelated records/proofs/files; do not only test each feature in isolation.
- [ ] Add one combined App case: server conflict→local durable rebase→transport handoff failure→later local edit→retry→late old ACK→correct new ACK. Assert precise pending versions after each step, unchanged unrelated FIFO/media and bounded attempt count. Expected queue/content values must be retained before triggering callbacks, not derived from the mutated result.
- [ ] Prove at least one exact-version oracle RED by temporarily changing expected token/payload, restore exact hash, then run covering Core and all six no-host suites. Record fixture setup failures separately from behavioral RED.
- [ ] Finish scoped task reviews and one whole-plan review from the recorded execution base. Address final source findings and review their scoped fix before freezing. Do not spend a full 20-minute run on a candidate already scheduled for a production fix.
- [ ] Freeze full SHA plus Sources/CloudSync/Tests trees and changed-file SHA-256 manifest. Inspect `/tmp/task4-run-bounded.py`; it must own its subprocess group and return124 on timeout, not kill unrelated builds. Run outside managed sandbox, arm64 and serially:

```zsh
env CLANG_MODULE_CACHE_PATH=/tmp/conflict-rebase-clang-cache /usr/bin/python3 /tmp/task4-run-bounded.py 1800 /usr/bin/arch -arm64 /usr/bin/swift test --disable-sandbox --no-parallel --cache-path /tmp/conflict-rebase-swift-cache --config-path /tmp/conflict-rebase-swift-config --security-path /tmp/conflict-rebase-swift-security > /tmp/conflict-rebase-full-core.log 2>&1
/usr/bin/xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/conflict-rebase-macos-derived CODE_SIGNING_ALLOWED=NO build-for-testing > /tmp/conflict-rebase-macos-build.log 2>&1
/usr/bin/xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/conflict-rebase-ios-derived CODE_SIGNING_ALLOWED=NO build > /tmp/conflict-rebase-ios-build.log 2>&1
```

Run each as a separate captured command, never hide an earlier failed exit behind the next success. The full command includes compilation; if using `--skip-build` after an exact frozen covering compilation, explicitly bind that binary and preserve its compiler warnings. No App test host execution, installation, signing, archive/export or live suite run.
- [ ] Report every exit/count/duration/warning/timeout, exact literal commands/workdirs, source/test/log hashes, review findings/fixes, legacy compatibility evidence and all controller rulings. Retained rebase-history capacity/latency, deferred lifecycle/deletion/UI/device gates remain explicit. Do not equate full-suite success with release readiness.
- [ ] Commit tests and report with exact file list; a later report-only finalization commit may update final evidence without altering source/tests. Verify tree equality and clean diff. Keep branch/worktree and this plan's scratch until an actual authorized integration; no push/submission in this plan.

## Plan self-review map

Spec §§1–3 → Tasks1/4/6, existing merge policy preserved. §4 → Tasks1–4/6, raw input and full CAS/ownership. §5 → Tasks2–4/6, preflight limits and shared3-attempt loop. §6 → Tasks2–5, native transitions/format7/fresh recovery. §7 → Task6, token+attempt ACK/cleanup and exact handoff. §8 → Tasks1–7, each matrix row has behavioral coverage. §9 → Task7, disabled-sync milestone and explicit release gates.

Implementation decisions needing particular review: retained checkpoint rebase history is capped by existing64MiB rather than pruned; history capacity exhaustion is fail-closed, not silently handled by dropping proof. Portable upload token excludes local path but complete CAS does not. Failure attempt ancestry during Core-committed/handoff retry must distinguish self-replay from newer unrelated failure. Journal effective cleanup proof cannot fall back to original issued content after rebase. These are review targets, not exemptions from the spec.
