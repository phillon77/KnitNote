# Cross-Device Sync Core Correction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct the Phase 1 synchronization foundation so attachment versions are immutable, revisions are causal, counter/reminder merges are deterministic, file reads cannot block on unsafe nodes, and persistence hot paths scale incrementally.

**Architecture:** Preserve the existing CloudKit-independent record and publication boundary, but introduce focused stores for installation identity, logical revisions, safe descriptor reads, segmented journal persistence, and attachment manifests. `JSONProjectStore` composes these units and publishes exact immutable mutations after its archive commit; `SyncMergeEngine` treats attachment lineage and counter/reminder state as explicit atomic domains.

**Tech Stack:** Swift 6, Foundation, CryptoKit, Darwin POSIX APIs, Swift Testing, Xcode 16

**Spec:** `docs/superpowers/specs/2026-09-02-cross-device-sync-core-correction-design.md`

## Global Constraints

- Support iOS 18.0, macOS 15.0, and watchOS 11.0; `Sources/KnitNoteCore/CloudSync` must not import CloudKit.
- Preserve archive schema 14 readability and all user-created/imported bytes and text.
- Failed or uncertain local persistence must publish no mutation and must retain recoverable evidence.
- Unlinking yarn deletes only `ProjectYarnLink`, never `Yarn`.
- Equal mutation stamps with divergent payloads are corruption, never a tie to resolve arbitrarily.
- Apple Watch remains CloudKit-free and existing command/revision/exactly-once invariants remain binding.
- Do not begin CloudKit Phase 2 until all six tasks, the full suite, generic iOS/Watch builds, and the final review pass.

---

### Task 1: Persistent installation identity and causal revision ledger

**Files:**
- Create: `Sources/KnitNoteCore/CloudSync/SyncInstallationIdentity.swift`
- Create: `Sources/KnitNoteCore/CloudSync/SyncRevisionLedger.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift:98-172, 1100-1410, 4193-4495`
- Test: `Tests/KnitNoteCoreTests/SyncInstallationIdentityTests.swift`
- Test: `Tests/KnitNoteCoreTests/SyncRevisionLedgerTests.swift`
- Modify test: `Tests/KnitNoteCoreTests/JSONProjectStoreSyncPublicationTests.swift`

**Interfaces:**
- Produces: `SyncInstallationIdentityStore.loadOrCreate() throws -> String`.
- Produces: `SyncRevisionLedger.allocate(for:mutationID:observedRemoteRevision:) throws -> SyncRevisionReceipt`.
- Produces: `SyncRevisionReceipt { entityID, mutationID, logicalRevision, deviceID }` and idempotent retry semantics.
- Consumes: existing `SyncEntityID`, `SyncMutationStamp`, publication sidecar transaction, and store Application Support URL.

- [ ] **Step 1: Add failing installation identity tests**

```swift
@Test func identityPersistsAcrossRestartAndDoesNotDependOnStorePath() throws {
    let rootA = try temporaryDirectory()
    let rootB = try temporaryDirectory()
    let first = try SyncInstallationIdentityStore(url: rootA.appending(path: "identity.json")).loadOrCreate()
    let restarted = try SyncInstallationIdentityStore(url: rootA.appending(path: "identity.json")).loadOrCreate()
    let otherInstallation = try SyncInstallationIdentityStore(url: rootB.appending(path: "identity.json")).loadOrCreate()
    #expect(first == restarted)
    #expect(first != otherInstallation)
}

@Test func corruptIdentityFailsClosedWithoutReplacement() throws {
    let fixture = try IdentityFixture(bytes: Data("not-json".utf8))
    #expect(throws: SyncInstallationIdentityError.corrupt) {
        _ = try SyncInstallationIdentityStore(url: fixture.url).loadOrCreate()
    }
    #expect(try Data(contentsOf: fixture.url) == Data("not-json".utf8))
}
```

- [ ] **Step 2: Run the identity tests and verify RED**

Run: `swift test --filter SyncInstallationIdentityTests`

Expected: compilation fails because `SyncInstallationIdentityStore` is undefined.

- [ ] **Step 3: Implement the atomic installation identity store**

```swift
public enum SyncInstallationIdentityError: Error, Equatable, Sendable {
    case corrupt
    case unsafeFile
}

public final class SyncInstallationIdentityStore: @unchecked Sendable {
    public init(url: URL)
    public func loadOrCreate() throws -> String
}
```

Persist a versioned JSON envelope containing one random `UUID().uuidString`. Serialize access with `NSLock`; create through a sibling temporary regular file, `fsync`, atomic rename, and parent-directory synchronization. Existing malformed, symlink, or non-regular data throws and remains untouched. Do not accept a caller-supplied path-derived identity except through an internal deterministic test initializer.

- [ ] **Step 4: Add failing causal revision tests**

```swift
@Test func newMutationIncrementsAndRetryReusesReceipt() throws {
    let ledger = try RevisionLedgerFixture().ledger
    let entity = SyncEntityID(kind: .project, uuid: UUID())
    let firstID = UUID()
    let first = try ledger.allocate(for: entity, mutationID: firstID, observedRemoteRevision: 0)
    let retry = try ledger.allocate(for: entity, mutationID: firstID, observedRemoteRevision: 999)
    let second = try ledger.allocate(for: entity, mutationID: UUID(), observedRemoteRevision: 25)
    #expect(first == retry)
    #expect(second.logicalRevision == 26)
    #expect(second.logicalRevision > first.logicalRevision)
}

@Test func twoInstallationsAtTheSameArchivePathUseDifferentDeviceIDs() throws {
    let a = try RevisionLedgerFixture(installationID: "A").ledger
    let b = try RevisionLedgerFixture(installationID: "B").ledger
    let entity = SyncEntityID(kind: .project, uuid: UUID())
    #expect(try a.allocate(for: entity, mutationID: UUID(), observedRemoteRevision: 0).deviceID !=
            b.allocate(for: entity, mutationID: UUID(), observedRemoteRevision: 0).deviceID)
}
```

- [ ] **Step 5: Run revision tests and verify RED**

Run: `swift test --filter SyncRevisionLedgerTests`

Expected: compilation fails because `SyncRevisionLedger` and `SyncRevisionReceipt` are undefined.

- [ ] **Step 6: Implement durable receipt allocation and store composition**

```swift
public struct SyncRevisionReceipt: Codable, Equatable, Sendable {
    public let entityID: SyncEntityID
    public let mutationID: UUID
    public let logicalRevision: UInt64
    public let deviceID: String
}

public protocol SyncRevisionAllocating: Sendable {
    func allocate(
        for entityID: SyncEntityID,
        mutationID: UUID,
        observedRemoteRevision: UInt64
    ) throws -> SyncRevisionReceipt
}
```

Persist an envelope keyed by mutation ID plus the greatest issued revision per entity. An existing mutation ID returns its exact receipt. A new mutation allocates `max(lastIssued, observedRemoteRevision) + 1`, rejecting `UInt64.max`. Wire one identity store and ledger through every enabled `JSONProjectStore.live` factory branch. Replace `syncRevision(for:)` content-hash revisions and path-derived `syncPublicationDeviceID`; save the receipt in the publication marker before archive publication so recovery reuses it.

- [ ] **Step 7: Run focused publication and identity tests**

Run: `swift test --filter 'SyncInstallationIdentityTests|SyncRevisionLedgerTests|JSONProjectStoreSyncPublicationTests'`

Expected: PASS, including restart recovery and same-path/different-installation coverage.

- [ ] **Step 8: Commit Task 1**

```bash
git add Sources/KnitNoteCore/CloudSync/SyncInstallationIdentity.swift Sources/KnitNoteCore/CloudSync/SyncRevisionLedger.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/SyncInstallationIdentityTests.swift Tests/KnitNoteCoreTests/SyncRevisionLedgerTests.swift Tests/KnitNoteCoreTests/JSONProjectStoreSyncPublicationTests.swift
git commit -m "fix: persist causal sync revisions"
```

### Task 2: Immutable attachment issuance and slot lineage

**Files:**
- Modify: `Sources/KnitNoteCore/CloudSync/SyncRecord.swift:82-220`
- Modify: `Sources/KnitNoteCore/CloudSync/SyncRecordValidation.swift:150-175`
- Modify: `Sources/KnitNoteCore/CloudSync/SyncMergeEngine.swift:180-290`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift:490-565, 4435-4755`
- Test: `Tests/KnitNoteCoreTests/SyncAttachmentVersionTests.swift`
- Modify test: `Tests/KnitNoteCoreTests/SyncFinalFixMergePolicyTests.swift`
- Modify test: `Tests/KnitNoteCoreTests/SyncMutationJournalFinalFixTests.swift`

**Interfaces:**
- Replaces content-derived attachment identity with `SyncAttachmentVersion.init(slot:versionID:conflictGroupID:contentSHA256:byteCount:mediaType:displayFilename:replacesVersionID:)`.
- Produces: `SyncAttachmentVersion.issuing(slot:contentSHA256:byteCount:mediaType:displayFilename:replacesVersionID:versionID:) throws` where production defaults to a new UUID and tests inject an explicit UUID.
- Consumes: Task 1 causal stamps and existing journal-staged `SyncAttachmentSource`.

- [ ] **Step 1: Add failing issuance and A→B→A tests**

```swift
@Test func sameBytesIssuedAgainReceiveDifferentVersionIDsAndPreserveLineage() throws {
    let slot = SyncAttachmentSlot(owner: .init(kind: .project, uuid: UUID()), role: "project-photo", slotID: "cover")
    let digestA = Data(repeating: 0xA1, count: 32)
    let digestB = Data(repeating: 0xB2, count: 32)
    let a1 = try SyncAttachmentVersion.issuing(slot: slot, contentSHA256: digestA, byteCount: 1, mediaType: "image/jpeg", displayFilename: "a.jpg")
    let b = try SyncAttachmentVersion.issuing(slot: slot, contentSHA256: digestB, byteCount: 1, mediaType: "image/jpeg", displayFilename: "b.jpg", replacesVersionID: a1.versionID)
    let a2 = try SyncAttachmentVersion.issuing(slot: slot, contentSHA256: digestA, byteCount: 1, mediaType: "image/jpeg", displayFilename: "a.jpg", replacesVersionID: b.versionID)
    #expect(a1.versionID != a2.versionID)
    #expect(a2.replacesVersionID == b.versionID)
    #expect(Set([a1.conflictGroupID, b.conflictGroupID, a2.conflictGroupID]).count == 1)
}

@Test func sameVersionIDWithDifferentLineageIsCorruption() throws {
    let pair = try AttachmentFixtures.sameVersionIDDifferentLineage()
    #expect(throws: SyncMergeError.corruptAttachmentVersion(pair.versionID)) {
        _ = try SyncMergeEngine().merge(local: [pair.first], remote: [pair.second], pendingLocal: [])
    }
}
```

- [ ] **Step 2: Run attachment tests and verify RED**

Run: `swift test --filter 'SyncAttachmentVersionTests|SyncFinalFixMergePolicyTests'`

Expected: the A→B→A assertion fails because content-derived identity reuses the first ID.

- [ ] **Step 3: Implement immutable version IDs and validation**

```swift
public struct SyncAttachmentVersion: Codable, Equatable, Sendable {
    public let slot: SyncAttachmentSlot
    public let versionID: UUID
    public let conflictGroupID: UUID
    public let contentSHA256: Data
    public let byteCount: Int64
    public let mediaType: String
    public let displayFilename: String
    public let replacesVersionID: UUID?

    public static func issuing(
        slot: SyncAttachmentSlot,
        contentSHA256: Data,
        byteCount: Int64,
        mediaType: String,
        displayFilename: String,
        replacesVersionID: UUID? = nil,
        versionID: UUID = UUID()
    ) throws -> Self
}
```

Keep deterministic `conflictGroupID` derived only from the validated slot, but never derive `versionID` from content. `validated()` checks metadata and self-replacement, while batch validation verifies a version ID maps to exactly one immutable snapshot and every replacement remains inside the same slot. Group conflicts by `slot`, not owner/role alone.

- [ ] **Step 4: Update store projection and journal restart coverage**

Store the issued version ID in publication evidence so retry/restart never calls `issuing` again for the same mutation. Update attachment mutation construction to reuse the prior slot head only as `replacesVersionID`. Add a real journal test that saves A, replaces with B, replaces with A, restarts, and verifies three exact record snapshots and staged byte hashes remain pending.

- [ ] **Step 5: Run focused attachment, journal, merge, and validation tests**

Run: `swift test --filter 'SyncAttachmentVersionTests|SyncMutationJournalFinalFixTests|SyncFinalFixMergePolicyTests|SyncRecordValidationTests'`

Expected: PASS; two legitimate label-photo slots produce no conflict, while divergent versions of one slot do.

- [ ] **Step 6: Commit Task 2**

```bash
git add Sources/KnitNoteCore/CloudSync/SyncRecord.swift Sources/KnitNoteCore/CloudSync/SyncRecordValidation.swift Sources/KnitNoteCore/CloudSync/SyncMergeEngine.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/SyncAttachmentVersionTests.swift Tests/KnitNoteCoreTests/SyncFinalFixMergePolicyTests.swift Tests/KnitNoteCoreTests/SyncMutationJournalFinalFixTests.swift
git commit -m "fix: issue immutable attachment versions"
```

### Task 3: Deterministic atomic counter and reminder merge

**Files:**
- Modify: `Sources/KnitNoteCore/CloudSync/SyncRecord.swift:68-82`
- Modify: `Sources/KnitNoteCore/CloudSync/SyncRecordValidation.swift:118-145`
- Modify: `Sources/KnitNoteCore/CloudSync/SyncMergeEngine.swift:18-390`
- Test: `Tests/KnitNoteCoreTests/SyncCounterReminderMergeTests.swift`
- Modify test: `Tests/KnitNoteCoreTests/SyncFinalFixMergePolicyTests.swift`
- Modify test: `Tests/KnitNoteCoreTests/WatchCommandApplicationTests.swift`

**Interfaces:**
- Replaces separate `SyncAtomicDomainValue.projectCounter` and `.knittingReminder` selection with `SyncCounterReminderState` for one counter/reminder aggregate.
- Produces: `SyncCounterReminderMergePolicy.merge(_:_:context:) throws -> SyncFieldVersion<SyncCounterReminderState>`.
- Produces: `SyncReminderStopOutcome.persisted(SyncCounterReminderState)` and `.noOp(SyncCounterReminderState)`.
- Consumes: existing `PreparedWatchCommand`, `ProcessedWatchCommandLedger`, counter mutation revision, reminder occurrence, and Task 1 causal stamp.

- [ ] **Step 1: Add failing equal-stamp permutation and stop tests**

```swift
@Test func divergentEqualStampAtomicStatesAlwaysThrowForEveryPermutation() throws {
    let pair = try CounterReminderFixtures.equalStampDifferentValues()
    for (local, remote) in [(pair.a, pair.b), (pair.b, pair.a)] {
        #expect(throws: SyncMergeError.corruptEqualStamp(entity: pair.entityID, field: "counterReminderState")) {
            _ = try SyncMergeEngine().merge(local: [local], remote: [remote], pendingLocal: [])
        }
    }
}

@Test func ledgeredStopReturnsPersistedOrNoOpWithoutThrowing() throws {
    let first = try CounterReminderFixtures.applyStop(alreadyStopped: false)
    let replay = try CounterReminderFixtures.applyStop(alreadyStopped: true)
    #expect(first.isPersisted)
    #expect(replay.isNoOp)
    #expect(first.state.processedCommandIDs == replay.state.processedCommandIDs)
}
```

- [ ] **Step 2: Run counter/reminder tests and verify RED**

Run: `swift test --filter 'SyncCounterReminderMergeTests|SyncFinalFixMergePolicyTests'`

Expected: equal-stamp divergent values are tie-selected or stop processing throws after ledgering.

- [ ] **Step 3: Implement the atomic state and validator**

```swift
public struct SyncCounterReminderState: Codable, Equatable, Sendable {
    public let counter: ProjectCounter
    public let reminder: KnittingReminder?
    public let preparedCommand: PreparedWatchCommand?
    public let processedCommandIDs: Set<UUID>
    public let occurrence: Int?
}

public enum SyncReminderStopOutcome: Equatable, Sendable {
    case persisted(SyncCounterReminderState)
    case noOp(SyncCounterReminderState)
}
```

Validate counter revision alignment, reminder revision/occurrence, prepared command target/revision, processed-ledger monotonicity, and no counter rollback. Equal stamps require byte-for-byte equal decoded state. Unequal stamps select the newer complete state, then union only processed IDs proven compatible with that state; they never add concurrent absolute counter values.

- [ ] **Step 4: Integrate explicit stop outcomes and real Watch fixtures**

Replace the unconditional `.stopReminder` throw path with `.persisted` when state changed and `.noOp` when the matching stop is already reflected. Exercise prepared→apply→ledger, duplicate delivery, stale revision, occurrence precedence, complete and stop using real `PreparedWatchCommand` and `ProcessedWatchCommandLedger` fixtures.

- [ ] **Step 5: Run sync and Watch regression groups**

Run: `swift test --filter 'SyncCounterReminderMergeTests|SyncFinalFixMergePolicyTests|WatchCommandApplicationTests|WatchSyncPersistenceTests|CounterReminderTests'`

Expected: PASS with permutation-independent corruption and exactly-once stop behavior.

- [ ] **Step 6: Commit Task 3**

```bash
git add Sources/KnitNoteCore/CloudSync/SyncRecord.swift Sources/KnitNoteCore/CloudSync/SyncRecordValidation.swift Sources/KnitNoteCore/CloudSync/SyncMergeEngine.swift Tests/KnitNoteCoreTests/SyncCounterReminderMergeTests.swift Tests/KnitNoteCoreTests/SyncFinalFixMergePolicyTests.swift Tests/KnitNoteCoreTests/WatchCommandApplicationTests.swift
git commit -m "fix: merge counter reminders atomically"
```

### Task 4: Shared nonblocking safe regular-file reader

**Files:**
- Create: `Sources/KnitNoteCore/CloudSync/SyncRegularFileReader.swift`
- Modify: `Sources/KnitNoteCore/CloudSync/SyncMutationJournal.swift:370-610`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift:599-650, 1360-1465, 4495-4755`
- Test: `Tests/KnitNoteCoreTests/SyncRegularFileReaderTests.swift`
- Modify test: `Tests/KnitNoteCoreTests/SyncMutationJournalFinalFixTests.swift`
- Modify test: `Tests/KnitNoteCoreTests/JSONProjectStoreSyncPublicationTests.swift`

**Interfaces:**
- Produces: `SyncRegularFileReader.read(_ url: URL, maximumBytes: Int, expected: SyncRegularFileExpectation?) throws -> SyncRegularFileRead`.
- Produces: `SyncRegularFileRead { data, identity, byteCount, sha256 }` and typed `SyncRegularFileReadError`.
- Consumes: no store state; journal and store adapters map typed errors to their public error enums.

- [ ] **Step 1: Add failing FIFO, symlink, replacement, and growth tests**

```swift
@Test(.timeLimit(.minutes(1))) func fifoFailsWithoutBlocking() throws {
    let fifo = try POSIXFixture.makeFIFO()
    #expect(throws: SyncRegularFileReadError.unsafeFile) {
        _ = try SyncRegularFileReader().read(fifo, maximumBytes: 1_024)
    }
}

@Test func descriptorIdentityRejectsPathReplacement() throws {
    let fixture = try ReplacementRaceFixture()
    #expect(throws: SyncRegularFileReadError.replaced) {
        _ = try fixture.reader.read(fixture.url, maximumBytes: 1_024)
    }
}
```

Add separate assertions for symlink, socket/non-regular node, oversize `st_size`, file growth beyond cap, and a regular file whose expected byte count/hash matches.

- [ ] **Step 2: Run safe-reader tests and verify RED**

Run: `swift test --filter SyncRegularFileReaderTests`

Expected: compilation fails because `SyncRegularFileReader` is undefined.

- [ ] **Step 3: Implement descriptor-safe bounded reads**

```swift
public struct SyncRegularFileExpectation: Sendable {
    public let byteCount: Int64?
    public let sha256: Data?
}

public struct SyncRegularFileRead: Sendable {
    public let data: Data
    public let device: UInt64
    public let inode: UInt64
    public let byteCount: Int64
    public let sha256: Data
}

public struct SyncRegularFileReader: Sendable {
    public func read(
        _ url: URL,
        maximumBytes: Int,
        expected: SyncRegularFileExpectation? = nil
    ) throws -> SyncRegularFileRead
}
```

Use `lstat`, then `open(O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)`, then `fstat`; require regular type and matching device/inode, enforce cap before and during reads, hash incrementally, and compare final `fstat` identity/size. Retry `EINTR`, close every descriptor, and never fall back to `Data(contentsOf:)` for scoped sync artifacts.

- [ ] **Step 4: Route all scoped journal/store reads through the reader**

Replace journal envelope reads, staged attachment verification, publication sidecar reads, `syncRegularFileMetadata`, and archive attachment hashing. Preserve each caller's public error mapping and byte caps. Add restart tests where the staged attachment and archive attachment paths are FIFOs; both must terminate within the test limit and return unsafe-file errors.

- [ ] **Step 5: Run file safety and publication tests**

Run: `swift test --filter 'SyncRegularFileReaderTests|SyncMutationJournalFinalFixTests|JSONProjectStoreSyncPublicationTests'`

Expected: PASS with no blocking FIFO reads.

- [ ] **Step 6: Commit Task 4**

```bash
git add Sources/KnitNoteCore/CloudSync/SyncRegularFileReader.swift Sources/KnitNoteCore/CloudSync/SyncMutationJournal.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/SyncRegularFileReaderTests.swift Tests/KnitNoteCoreTests/SyncMutationJournalFinalFixTests.swift Tests/KnitNoteCoreTests/JSONProjectStoreSyncPublicationTests.swift
git commit -m "fix: harden sync artifact reads"
```

### Task 5: Segmented mutation journal with checkpoints

**Files:**
- Modify: `Sources/KnitNoteCore/CloudSync/SyncMutationJournal.swift`
- Test: `Tests/KnitNoteCoreTests/SyncMutationJournalSegmentTests.swift`
- Modify test: `Tests/KnitNoteCoreTests/SyncMutationJournalTests.swift`
- Modify test: `Tests/KnitNoteCoreTests/SyncMutationJournalFinalFixTests.swift`

**Interfaces:**
- Preserves: `SyncMutationJournalProtocol.enqueue(_:)`, `pending()`, and `acknowledge(_:)`.
- Produces internal Codable types: `SyncJournalFrame`, `SyncJournalFrameKind`, `SyncJournalCheckpoint`.
- Adds internal test instrumentation: `SyncJournalIOCounters { appendedFrameCount, fullCheckpointRewriteCount, bytesRead }`.
- Consumes: Task 4 `SyncRegularFileReader` for checkpoint and segment recovery.

- [ ] **Step 1: Add failing scaling and recovery tests**

```swift
@Test func twoThousandSequentialOperationsDoNotRewriteEverySuffix() throws {
    let fixture = try SegmentedJournalFixture()
    for index in 0..<2_000 {
        let mutation = try fixture.mutation(index: index)
        try fixture.journal.enqueue(mutation)
        try fixture.journal.acknowledge([mutation.identity])
    }
    #expect(fixture.counters.appendedFrameCount == 4_000)
    #expect(fixture.counters.fullCheckpointRewriteCount < 20)
}

@Test func truncatedFinalFramePreservesEarlierPendingMutations() throws {
    let fixture = try SegmentedJournalFixture()
    let first = try fixture.mutation(index: 1)
    let second = try fixture.mutation(index: 2)
    try fixture.journal.enqueue([first, second])
    try fixture.truncateLastFrame()
    #expect(try fixture.reopened().pending() == [first])
}
```

Add checksum-corruption, interrupted checkpoint rename, duplicate-identical mutation, duplicate-divergent mutation, and legacy envelope migration tests.

- [ ] **Step 2: Run journal segment tests and verify RED**

Run: `swift test --filter SyncMutationJournalSegmentTests`

Expected: current journal rewrites the complete envelope and lacks frame/checkpoint recovery.

- [ ] **Step 3: Implement append frames and atomic checkpoints**

```swift
enum SyncJournalFrameKind: UInt8, Codable, Sendable {
    case enqueue = 1
    case acknowledge = 2
}

struct SyncJournalFrame: Codable, Sendable {
    let sequence: UInt64
    let kind: SyncJournalFrameKind
    let payload: Data
    let checksum: Data
}

struct SyncJournalCheckpoint: Codable, Sendable {
    let version: Int
    let throughSequence: UInt64
    let pending: [SyncMutation]
}
```

Append length-prefixed frames with sorted deterministic payload encoding and SHA-256 checksum. Batch enqueue/ack performs one file synchronization. Replay checkpoint then valid frames in sequence order. A partial final frame is ignored only when it is provably the final interrupted append; checksum or sequence corruption inside committed history throws. Compact after at least 256 frames and at least 50% acknowledged operations, using fsync + atomic rename + directory sync before rotating the segment.

- [ ] **Step 4: Migrate the version-2 envelope without losing evidence**

On first open, decode the legacy envelope through Task 4's safe reader, validate every immutable mutation and staged attachment, write checkpoint zero plus an empty segment, synchronize, then rename the legacy envelope to a retained `.migrated` diagnostic file. If validation fails, leave the legacy bytes and attachments untouched and throw `corrupt`; never create an empty new journal.

- [ ] **Step 5: Run all journal and publication restart tests**

Run: `swift test --filter 'SyncMutationJournalSegmentTests|SyncMutationJournalTests|SyncMutationJournalFinalFixTests|JSONProjectStoreSyncPublicationTests'`

Expected: PASS; operation counters demonstrate bounded checkpoint rewrites.

- [ ] **Step 6: Commit Task 5**

```bash
git add Sources/KnitNoteCore/CloudSync/SyncMutationJournal.swift Tests/KnitNoteCoreTests/SyncMutationJournalSegmentTests.swift Tests/KnitNoteCoreTests/SyncMutationJournalTests.swift Tests/KnitNoteCoreTests/SyncMutationJournalFinalFixTests.swift
git commit -m "fix: segment the sync mutation journal"
```

### Task 6: Incremental attachment manifest and phase verification

**Files:**
- Create: `Sources/KnitNoteCore/CloudSync/SyncAttachmentManifest.swift`
- Create: `Sources/KnitNoteCore/CloudSync/SyncPublicationProjection.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift:98-565, 4193-4755`
- Test: `Tests/KnitNoteCoreTests/SyncAttachmentManifestTests.swift`
- Modify test: `Tests/KnitNoteCoreTests/JSONProjectStoreSyncPublicationTests.swift`
- Modify: `docs/superpowers/plans/2026-09-02-cross-device-sync-1-core.md`

**Interfaces:**
- Produces: `SyncAttachmentManifestStore.load()`, `commit(_:)`, and `projection(for:changes:)`.
- Produces: `SyncAttachmentManifestEntry { normalizedPath, device, inode, byteCount, modificationNanoseconds, contentSHA256, slot, versionID }`.
- Produces: `SyncPublicationProjector.project(before:after:manifest:) throws -> SyncPublicationProjection`.
- Consumes: Tasks 1–4 identity, revision, immutable attachment, and safe-read APIs; publishes through the Task 5 journal protocol.

- [ ] **Step 1: Add failing real-attachment operation-count tests**

```swift
@Test func unchangedSecondPersistDoesNotRehashFiveHundredAttachments() throws {
    let fixture = try AttachmentManifestFixture(realAttachmentCount: 500)
    try fixture.persistWithoutAttachmentChanges()
    fixture.readerCounters.reset()
    try fixture.persistWithoutAttachmentChanges()
    #expect(fixture.readerCounters.hashedFileCount == 0)
}

@Test func replacingOneAttachmentHashesOnlyTheNewVersion() throws {
    let fixture = try AttachmentManifestFixture(realAttachmentCount: 500)
    fixture.readerCounters.reset()
    try fixture.replaceAttachment(at: 211)
    #expect(fixture.readerCounters.hashedFileCount == 1)
}
```

Add deletion, inode replacement with identical path/size/mtime, corrupt manifest, and restart tests. The inode-replacement case must rehash and reject stale manifest evidence.

- [ ] **Step 2: Run manifest tests and verify RED**

Run: `swift test --filter SyncAttachmentManifestTests`

Expected: current publication projection hashes every attachment on every enabled persist.

- [ ] **Step 3: Implement manifest persistence and invalidation**

```swift
public struct SyncAttachmentManifestEntry: Codable, Equatable, Sendable {
    public let normalizedPath: String
    public let device: UInt64
    public let inode: UInt64
    public let byteCount: Int64
    public let modificationNanoseconds: Int64
    public let contentSHA256: Data
    public let slot: SyncAttachmentSlot
    public let versionID: UUID
}

public protocol SyncAttachmentManifestStoring: Sendable {
    func load() throws -> [String: SyncAttachmentManifestEntry]
    func commit(_ entries: [String: SyncAttachmentManifestEntry]) throws
}
```

Persist a versioned, sorted manifest through atomic write/fsync/rename. Reuse a hash only when normalized path, descriptor device/inode, byte count, modification nanoseconds, slot, and immutable version ID all match. Any mismatch uses Task 4's reader and recomputes bytes/hash. Corrupt or unsafe manifest blocks publication and remains preserved.

- [ ] **Step 4: Extract pure publication projection and wire incremental changes**

Move archive-to-record and attachment-delta computation from `JSONProjectStore.swift` into `SyncPublicationProjection.swift`. Pass the before/after archive plus the loaded manifest; enumerate current attachment references once, reuse valid manifest entries, and hash only added/replaced identities. Commit the updated manifest only after archive commit and durable journal enqueue are reconciled; publication failure retains the marker and candidate manifest for repair.

- [ ] **Step 5: Run focused sync, store, Watch, and yarn-link regressions**

Run: `swift test --filter 'SyncAttachmentManifestTests|JSONProjectStoreSyncPublicationTests|SyncMutationJournal|SyncMerge|WatchCommandApplicationTests|WatchSyncPersistenceTests|YarnLink'`

Expected: PASS, including 500 real attachments and single-file invalidation.

- [ ] **Step 6: Run the complete package test suite**

Run: `swift test`

Expected: exit 0 with no failed tests; record the exact suite/test counts in the implementation report.

- [ ] **Step 7: Build generic iOS and Watch targets**

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`

Expected: `BUILD SUCCEEDED`.

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteWatch -destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO build`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 8: Verify the committed diff and phase gates**

Run: `git diff --check && git status --short`

Expected: no whitespace errors; only the intended plan status/report edits remain before commit. Update the original Phase 1 plan status to point to this corrective plan without claiming CloudKit or release completion.

- [ ] **Step 9: Commit Task 6**

```bash
git add Sources/KnitNoteCore/CloudSync/SyncAttachmentManifest.swift Sources/KnitNoteCore/CloudSync/SyncPublicationProjection.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/SyncAttachmentManifestTests.swift Tests/KnitNoteCoreTests/JSONProjectStoreSyncPublicationTests.swift docs/superpowers/plans/2026-09-02-cross-device-sync-1-core.md
git commit -m "fix: publish attachment deltas incrementally"
```

## Final review gate

After Task 6, generate one review package from `fe65996` through the final implementation commit. Dispatch a fresh reviewer who did not implement any task. The reviewer must verify every completion criterion in the corrective spec, inspect the complete correction diff for Critical/Important regressions, and distinguish later CloudKit work from Phase 1 defects. Any Critical or Important finding stops the phase; do not begin `2026-09-02-cross-device-sync-2-cloudkit-assets.md` until the corrective review is clean.
