# Daily Sync Canonical Durability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve exact canonical sync state through daily local commits and interrupted publication, so a bootstrapped store can reopen and continue editing without rebuilding issued versions.

**Architecture:** Extend the existing publication transaction, not a second coordinator. A bounded account-bound checkpoint holds complete canonical records; the same transaction carries its candidate and predecessor proof. The store finishes recovery before installing editable canonical caches.

**Tech Stack:** Swift 6, Foundation, CryptoKit, Darwin descriptor I/O, Swift Testing; existing SwiftPM Core and Xcode targets.

**Spec:** `docs/superpowers/specs/2026-09-05-daily-sync-canonical-durability-design.md` (user approved on 2026-09-05).

## Global Constraints

- Version stays 1.7.0（13）. Baseline `9b8da43` on `docs/cross-device-sync-design`; verify full SHA before executing.
- Worktree: `.worktrees/cross-device-sync-design`; do not alter the user's main checkout.
- Checkpoint path is account working-set `SyncMetadata/canonical.json`; preserve `bootstrap-canonical.json` as initial evidence.
- Encoded checkpoint and entire transaction each have a hard maximum of 100,000,000 bytes. Include encoding overhead; reject before modifying the live archive or artifacts.
- Preserve exact mutation IDs, revisions, tombstones, attachment predecessors/source URLs and Watch atomic state. Never reconstruct acknowledged history from the pending journal or archive timestamps.
- Account ownership plus caller freeze are required; MainActor is not a cross-process lock. Validate ownership at entry and before each durable transition.
- Pending-only account recovery stays pending-only. Missing full canonical authority blocks activation until the later remote refetch integration; do not expand vault scope.
- No live CloudKit, Keychain, App host, user-data probing, UI, pricing, localization, signing, version changes, push, schema deployment, upload or submission.
- Use injected faults on isolated temporary paths. Build-for-testing is permitted with signing disabled; executing the App test host is not.
- Keep previous transaction compatibility and fail-closed semantics. A committed archive is not rolled back because later publication failed.

## File and Interface Map

- New `Sources/KnitNoteCore/CloudSync/SyncCanonicalCheckpoint.swift`: versioned value, validation and deterministic encoding.
- New `Sources/KnitNoteCore/CloudSync/SyncCanonicalCheckpointStore.swift`: account/path binding, bounded reads, durable replace and exact retry; no transaction decisions.
- Existing `Sources/KnitNoteCore/CloudSync/SyncMutationPublishing.swift`: versioned transaction candidate and integrity; committed replay authority.
- Existing `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`: prepare candidates, publish and hydrate on restart. Keep unrelated store behavior untouched.
- Existing `Sources/KnitNoteCore/CloudSync/SyncBootstrapTransaction.swift`: verified initial checkpoint handoff, without changing original receipt evidence.
- Existing `Sources/KnitNoteCore/CloudSync/SyncAccountStorage.swift` and `SyncAccountRecoveryTransaction.swift`: compatibility checks only where the new checkpoint is classified/consumed; no vault expansion.
- Tests added per task below; existing regression fixtures remain owned by their original test files.

Public names introduced by this plan:

```swift
public struct SyncCanonicalCheckpoint: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let accountIDHash: String
    public let commitID: UUID
    public let archiveSHA256: Data
    public let records: [SyncRecord]
    public let legacyRecordIDsToDelete: Set<SyncEntityID>
    public init(accountIDHash: String, commitID: UUID, archiveSHA256: Data,
                records: [SyncRecord], legacyRecordIDsToDelete: Set<SyncEntityID>) throws
    public func validated() throws -> Self
    public func encoded() throws -> Data
}

public final class SyncCanonicalCheckpointStore {
    public init(liveRoot: URL, account: SyncAccountIdentity,
                validateOwnership: @escaping () throws -> Void) throws
    public func load() throws -> SyncCanonicalCheckpoint?
    public func install(_ candidate: SyncCanonicalCheckpoint,
                        replacing predecessorSHA256: Data?) throws
}
```

`nil` predecessor means verified absence only. `install` accepts the exact predecessor or the exact candidate already present (retry), never an unrelated third state. These APIs do not manufacture account locks. The owning runtime must retain its existing ownership/freeze across calls. Add an internal test initializer with `beforeBoundary: (SyncDurableFileWriteBoundary) throws -> Void`; default production behavior uses real synchronization.

## Task 1: Bounded checkpoint codec and durable account-bound storage

**Files:** Create the two checkpoint source files above and `Tests/KnitNoteCoreTests/SyncCanonicalCheckpointTests.swift`.

**Interfaces:** Produces the two public types above. Consumes `SyncRecordValidator.validate`, `SyncRegularFileReader.read` and existing durable directory synchronization. No store integration in this task.

- [ ] Write a round-trip test and exact predecessor/retry tests. A minimal independent fixture is:

```swift
@Test func checkpointRoundTripPreservesCommitIdentity() throws {
    let account = try SyncAccountIdentity(containerIdentifier: "test.container", userRecordName: "A")
    let value = try SyncCanonicalCheckpoint(accountIDHash: account.accountIDHash,
        commitID: UUID(), archiveSHA256: Data(repeating: 7, count: 32),
        records: [], legacyRecordIDsToDelete: [])
    let bytes = try value.encoded()
    #expect(try JSONDecoder().decode(SyncCanonicalCheckpoint.self, from: bytes).validated() == value)
    #expect(try value.encoded() == bytes)
}
```

- [ ] Run `swift test --filter SyncCanonicalCheckpointTests`; record the expected missing-type RED, then add behavioral RED tests before fixing each validation/storage condition.
- [ ] Implement format 1 validation: account hash exactly 64 lowercase hex characters, digest exactly 32 bytes, unique entity IDs, records validated by `SyncRecordValidator`, deterministic record and legacy-ID ordering, unknown format rejection. Counter state remains embedded in records, not a second independently mutable table. Include all fields in the integrity envelope; exclude the integrity field itself when hashing.

```swift
let validatedRecords = try SyncRecordValidator().validate(records)
guard Set(validatedRecords.map(\.id)).count == validatedRecords.count else {
    throw SyncPublicationError.corruptTransaction
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
```

Use the repository's entity ordering rather than dictionary iteration. `encoded()` checks final envelope length against the exact cap. Read cap is checked before allocation/decoding; do not use unbounded `SyncDurableFile.readRegularFile` for checkpoint reads.
- [ ] Implement storage with descriptor-bound no-follow ancestry validation from existing account storage patterns. Pin/recheck parent identity; reject symlinks, aliases/hard-linked metadata, unexpected file types and revoked ownership. Do not assume the generic pathname writer alone secures parent ancestry. Return `nil` only for verified ENOENT. Write privately in the same directory, synchronize file, atomically rename, synchronize parent and verify named candidate. Exact-candidate retries must synchronize again, not return on byte equality. Only clean owned temporary files; bound/recover their namespace without touching unknown files.
- [ ] Add tests for wrong account, duplicate entity, invalid version/hash, above-cap input, exact cap boundary, corrupted encoding, replaced parent/file, symlink/FIFO, revoked ownership, failed file sync, rename and parent sync. For each injected failure snapshot original files and assert no unauthorized overwrite. Confirm the retry retains the same `commitID` and no accumulating temporary files.
- [ ] Run the focused suite and `git diff --check`; stage only the two source files and test file. Commit `feat(sync): add bounded canonical checkpoint storage`.

## Task 2: Put canonical candidate authority in the existing publication transaction

**Files:** Modify `SyncMutationPublishing.swift`; create `Tests/KnitNoteCoreTests/SyncCanonicalPublicationTransactionTests.swift`; extend existing `SyncPublicationEvidenceDurabilityTests.swift` only for shared transaction compatibility coverage.

**Interfaces:** Task 1 checkpoint codec. Add optional `canonicalTransition: SyncCanonicalTransition? = nil` to the existing transaction initializer; old callers remain source-compatible. Define internal `SyncCanonicalTransition: Codable, Equatable, Sendable` with `predecessorSHA256: Data?` and `candidate: SyncCanonicalCheckpoint`, validated initializer and no alternate transaction file.

- [ ] Write integrity round-trip tests using a real empty-record candidate and the existing transaction initializer:

```swift
let transition = try SyncCanonicalTransition(predecessorSHA256: nil, candidate: candidate)
let transaction = try SyncPublicationTransaction(
    expectedArchiveSHA256: candidate.archiveSHA256, mutations: [],
    revisionReceipts: [], canonicalTransition: transition)
let decoded = try JSONDecoder().decode(SyncPublicationTransaction.self,
    from: JSONEncoder().encode(transaction)).validated()
#expect(decoded.canonicalTransition == transition)
```

Construct `candidate` with the full constructor shown in Task 1; use distinct commits for tampering/predecessor mismatch tests.
- [ ] Run `swift test --filter SyncCanonicalPublicationTransactionTests` and capture RED before implementation.
- [ ] Introduce transaction format 5; preserve validation/integrity algorithms for formats 2, 3 and 4 without re-encoding them as 5. Include transition and predecessor in v5 integrity. Require candidate archive digest to equal `expectedArchiveSHA256`; validate every candidate and reject invalid predecessor digest lengths. Preserve exact mutation and receipt order. A v5 transition must not mint a second mutation or candidate during recovery.
- [ ] Raise both write and read bounds for the existing transaction file from 1 MiB to 100,000,000 bytes, and update all preallocation guards. Test a valid transaction above the old 1 MiB cap and one beyond the new cap; final encoded length, not just candidate length, controls acceptance. Preflight must happen before archive/artifact writes in Task 3.
- [ ] Test old formats remain readable with `canonicalTransition == nil`, integrity tampering fails, wrong archive binding fails, and artifact-only commits with equal archive digests retain distinct candidate identities. Do not decide full canonical recovery from old format absence alone; activation policy belongs to Task 3.
- [ ] Run focused transaction and publication-evidence suites plus `git diff --check`; commit exact changed files as `feat(sync): bind canonical candidates to publication transactions`.

## Task 3: Integrate daily commits, bootstrap activation and restart recovery

**Files:** Modify `JSONProjectStore.swift` and `SyncBootstrapTransaction.swift`; create `Tests/KnitNoteCoreTests/JSONProjectStoreCanonicalDurabilityTests.swift`; extend `SyncBootstrapTransactionTests.swift` with actual transaction handoff coverage.

**Interfaces:** Consumes Tasks 1–2. Add public store method `activateSyncCanonicalState(checkpointStore: SyncCanonicalCheckpointStore, bootstrap: SyncCanonicalBootstrapHandoff?, attachmentSources: [UUID: SyncAttachmentSource]) throws`. Caller holds ownership/freeze. Existing initializers and unsynchronized mode retain their current behavior. Persist the injected checkpoint store privately only after validating it; the new path must not permit mutations before activation/recovery is complete.

Define `public struct SyncCanonicalBootstrapHandoff` in `SyncBootstrapTransaction.swift`, with a fileprivate initializer and internal immutable account hash, live-root identity, transaction ID, checkpoint and a throwing revalidation closure. Its sole producer is `public func canonicalHandoff(_ prepared: SyncBootstrapPreparation) throws -> SyncCanonicalBootstrapHandoff` on `SyncBootstrapTransaction`. The producer and the closure both validate the original committed manifest, receipt, context/freeze, archive and named live-root identity. Activation invokes the closure immediately before first durable installation. Do not expose a memberwise/public decoder initializer for this capability. Existing `checkpoint(_:)` and `hydrateSyncBootstrap` compatibility APIs remain unchanged, but do not authorize creating daily state.

- [ ] Add a real temporary-store test. Create a UUID directory under `FileManager.default.temporaryDirectory.resolvingSymlinksInPath()`, write `ProjectArchive(version: ProjectArchive.currentVersion, projects: [try StoredProject(name: "Before")])` to `projects-v1.json`, and export with `ProjectArchiveSyncMapper.export(archive:liveRoot:deviceID:)`. Construct `SyncBootstrapContext` using the test account hash and UUID epoch/freeze; create `SyncBootstrapTransaction(liveRoot:context:validateContext:)` with an equality-checking context validator. Prepare with exported local records and an empty complete remote snapshot of the same context, install and commit, then bind `bootstrap = try transaction.canonicalHandoff(prepared)`. Construct an account-bound checkpoint store with a test ownership validator, and real `FileSyncMutationJournal` at `SyncMetadata/pending.json`.

```swift
let store = JSONProjectStore(url: archiveURL,
    syncMutationSink: JournalSyncMutationSink(journal: journal))
try store.activateSyncCanonicalState(checkpointStore: checkpoints,
    bootstrap: bootstrap, attachmentSources: [:])
try store.updateProject(id: projectID, name: "After", toolType: nil,
    toolSize: nil, toolNotes: nil, photoChange: .unchanged)
let committed = try #require(checkpoints.load())
let reopened = JSONProjectStore(url: archiveURL,
    syncMutationSink: JournalSyncMutationSink(journal: journal))
try reopened.activateSyncCanonicalState(checkpointStore: checkpoints,
    bootstrap: nil, attachmentSources: [:])
#expect(try checkpoints.load() == committed)
try reopened.updateProject(id: projectID, name: "Again", toolType: nil,
    toolSize: nil, toolNotes: nil, photoChange: .unchanged)
#expect(try checkpoints.load()?.commitID != committed.commitID)
```

All names in the snippet are local fixture bindings from the preceding construction steps. Use the fixture's project UUID, not a newly generated project identity. Clean only this test-owned UUID root in `defer`. Then extend to actual prepare/install/commit bootstrap using existing fixture code in `SyncBootstrapTransactionTests` (its private fixture remains private).
- [ ] Run `swift test --filter JSONProjectStoreCanonicalDurabilityTests`; capture RED.
- [ ] Prepare full candidate records from the exact prior canonical state plus allocated mutations before constructing/writing the transaction. Refactor the existing projection callback only as needed to make candidate calculation pure and available before commit. Include attachment-only and metadata-only changes; never collect only live records or pending mutations. Carry `legacyRecordIDsToDelete` unchanged until its existing durable cleanup authority proves consumption.
- [ ] Add transition to the same publication marker and encode/preflight it before `beforeArchiveWrite`, archive writes or artifact commit. Keep existing revision allocation receipts/retries; do not generate a new candidate on retry.
- [ ] In `publish`, preserve version-receipt, attachment-evidence and journal ordering; install the exact candidate before finishing manifest/deletion/restoration and removing the publication marker. Hydrate caches only from verified candidate state. Preserve pendingRepair if installation or directory sync fails after archive commit.
- [ ] Activation first examines an unresolved transaction. For a committed v5 transition, restore exact candidate and finish publication; for a verified uncommitted transition preserve predecessor using existing rollback rules; corrupt/mixed state blocks. Recheck archive and attachments before hydrating. Old transactions lacking complete canonical proof remain blocked in canonical mode. When daily state exists, never fall back to bootstrap on mismatch. When absent, initialize only from the opaque `SyncCanonicalBootstrapHandoff` specified above after its live revalidation; a raw caller-provided checkpoint must not bypass terminal verification.
- [ ] Add tests for journal ACK followed by reopen (checkpoint unchanged); no-op edits; equal archive/different metadata; unchanged remote revisions; fresh edits increasing revisions; missing/corrupt daily file with an existing transition; stale bootstrap; missing attachment evidence; disabled sync behavior. Explicitly test the new initial handoff cannot be forged by supplying a structurally valid raw checkpoint.
- [ ] Run canonical, bootstrap, publication, deletion and Watch-focused Core suites. Commit only source/test files for this task as `feat(sync): persist and recover daily canonical state`.

## Task 4: Fault boundaries, account lifecycle regression and target membership

**Files:** Extend `JSONProjectStoreCanonicalDurabilityTests.swift`, `SyncAccountRecoveryInventoryTests.swift`, `SyncAccountRecoveryTransactionTests.swift`, `JSONProjectStoreSyncDeletionTests.swift`; modify `project.yml` or `KnitNote.xcodeproj/project.pbxproj` only if new Core files are not automatically included. Add `docs/superpowers/reports/2026-09-05-daily-canonical-verification.md`.

**Interfaces:** Tasks 1–3 public APIs. Internal test enum `SyncCanonicalPublicationBoundary: CaseIterable` with cases `afterIntent`, `afterArchive`, `afterJournal`, `afterCheckpoint`, `beforeIntentRemoval`; test hook defaults to a no-op and never replaces actual disk operations. Existing checkpoint write boundaries cover file/rename/directory fsync. Thread hook through internal test initializer only.

- [ ] Parameterize a real fixture through each boundary, throw once, discard store and journal instances, reopen new instances, then activate and compare exact records and mutation identities. Test source must assert equivalence, not merely absence of an error:

```swift
#expect(recovered.records == expected.records)
#expect(recovered.commitID == expected.commitID)
#expect(Set(try journal.pending().map(\.identity)).count == journal.pending().count)
```

`SyncMutation.identity` is an existing public accessor; use the real journal. For an interruption before commit, `expected` is the predecessor; after commit it is the exact transaction candidate. Unprovable states must throw and retain the marker.
- [ ] Run the failing boundary cases before adding hooks/recovery corrections. Add exact after-rename directory-sync failure retries, after-checkpoint/before-marker-removal retries and second-reopen assertions. No additional coordinator or alternate recovery file is permitted.
- [ ] Extend account inventory tests with a real canonical checkpoint: inventory binds it; cleanup removes it only under existing authenticated selection authority; pending-only packet does not gain full ACK history. Partial replay followed by activation refuses until complete state is available. A→B rejects A's checkpoint. Preserve ciphertext on refusal and keep all existing cleanup namespace and fsync protections.
- [ ] Extend actual domain flows: six counters/Watch proofs across reopen; both markup roles with same original source identity; delete then day-29 restore followed by another reopen. Use existing domain fixture APIs and assert exact exported records and original media bytes, not source-text contract tests as substitute.
- [ ] Add the two new source files to app/Watch build membership if required. Do not regenerate unrelated project settings or change Watch's CloudKit-free contract.
- [ ] Run focused suites, then bounded full Core validation. Record exit codes, source SHA, suite counts and failures separately; a timed-out full run is incomplete, not PASS. Run signing-disabled macOS `build-for-testing` without launching the host:

```sh
swift test --filter 'SyncCanonical|JSONProjectStoreCanonical|SyncBootstrap|SyncAccountRecovery|SyncPublication|JSONProjectStoreSyncDeletion'
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/daily-canonical-derived CODE_SIGNING_ALLOWED=NO build-for-testing
git diff --check
```

Use a unique log per run and preserve actual command/status. If the sandbox blocks caches or socket fixtures, diagnose narrowly; do not relaunch a live App host as a workaround. Test initialization/reopen does not establish power-loss or real process termination acceptance.
- [ ] Record remaining live/remote/refetch/physical gates in the report and commit exact files as `test(sync): verify canonical crash recovery boundaries`.

## Self-Review and Handoff

Coverage: codec/account/path/size → Task 1; immutable transaction authority/compatibility → Task 2; daily central commit/bootstrap/restart → Task 3; fault matrix/ACK/account/Watch/media/project build → Task 4. Release and live integration stay explicitly outside scope.

Interface self-review: first initialization uses the opaque Task 3 handoff, while later reopen uses `bootstrap: nil`; Task 2 embeds Task 1's exact checkpoint; Task 4 uses the existing mutation identity accessor. No task treats raw checkpoint content as proof of a terminal bootstrap.

Execution should use the existing isolated worktree, one implementer at a time and a review gate per independently testable task. This document is a plan, not evidence that any task or test has run.
