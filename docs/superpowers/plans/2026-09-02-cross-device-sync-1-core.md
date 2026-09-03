# Cross-Device Sync 1: Deterministic Core Implementation Plan

> **Status (2026-09-03):** This initial Phase 1 plan is corrected by
> `2026-09-02-cross-device-sync-core-correction.md`. That corrective plan
> must pass its complete test, build, and independent-review gates before
> CloudKit Phase 2 or any release work may begin.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add CloudKit-independent synchronization records, deterministic merging, a durable mutation journal, and a reliable post-commit publication boundary.

**Architecture:** New focused types under `Sources/KnitNoteCore/CloudSync` model sync identity and conflict semantics without importing CloudKit. `JSONProjectStore` publishes a domain snapshot mutation only after its existing atomic archive write succeeds; a file-backed actor persists pending mutations independently of CKSyncEngine.

**Tech Stack:** Swift 6, Foundation, CryptoKit, Swift Testing

**Spec:** `docs/superpowers/specs/2026-09-02-cross-device-icloud-sync-design.md`

## Global Constraints

- Support iOS 18.0, macOS 15.0, and watchOS 11.0; core files must compile in all three targets.
- No CloudKit imports in `Sources/KnitNoteCore/CloudSync`.
- Mutation ordering must be deterministic across devices and must not rely only on wall-clock time.
- Existing archive schema 14 remains readable throughout this plan.
- Failed local archive writes publish no sync mutation.
- Unlinking yarn remains a relationship mutation and never deletes the yarn entity.

---

### Task 1: Sync identities and mutation stamps

**Files:**
- Create: `Sources/KnitNoteCore/CloudSync/SyncIdentity.swift`
- Test: `Tests/KnitNoteCoreTests/SyncIdentityTests.swift`

**Interfaces:**
- Produces: `SyncEntityKind`, `SyncEntityID`, `SyncMutationStamp`, and `SyncFieldVersion<Value>`.

- [ ] **Step 1: Write failing ordering and Codable tests**

```swift
@Test func mutationStampUsesLogicalRevisionBeforeClockAndDevice() throws {
    let older = SyncMutationStamp(logicalRevision: 3, modifiedAt: .distantFuture, deviceID: "z")
    let newer = SyncMutationStamp(logicalRevision: 4, modifiedAt: .distantPast, deviceID: "a")
    #expect(older < newer)
    #expect(try JSONDecoder().decode(SyncMutationStamp.self, from: JSONEncoder().encode(newer)) == newer)
}
```

- [ ] **Step 2: Run the focused test and confirm it fails to compile**

Run: `swift test --filter SyncIdentityTests`

Expected: FAIL because `SyncMutationStamp` is undefined.

- [ ] **Step 3: Implement the exact value types**

```swift
public enum SyncEntityKind: String, Codable, CaseIterable, Sendable {
    case project, projectCounter, rowNote, knittingReminder, journalEntry
    case yarn, projectYarnLink, patternFolder, pattern, patternUsage, attachment, deletionMarker
}

public struct SyncEntityID: Hashable, Codable, Sendable {
    public let kind: SyncEntityKind
    public let uuid: UUID
}

public struct SyncMutationStamp: Hashable, Codable, Comparable, Sendable {
    public let logicalRevision: UInt64
    public let modifiedAt: Date
    public let deviceID: String
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.logicalRevision, lhs.modifiedAt, lhs.deviceID) <
        (rhs.logicalRevision, rhs.modifiedAt, rhs.deviceID)
    }
}

public struct SyncFieldVersion<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let value: Value
    public let stamp: SyncMutationStamp
}
```

- [ ] **Step 4: Run identity tests and full core tests**

Run: `swift test --filter SyncIdentityTests && swift test`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/KnitNoteCore/CloudSync/SyncIdentity.swift Tests/KnitNoteCoreTests/SyncIdentityTests.swift
git commit -m "feat: add deterministic sync identities"
```

### Task 2: Versioned domain records and validation

**Files:**
- Create: `Sources/KnitNoteCore/CloudSync/SyncRecord.swift`
- Create: `Sources/KnitNoteCore/CloudSync/SyncRecordValidation.swift`
- Test: `Tests/KnitNoteCoreTests/SyncRecordValidationTests.swift`

**Interfaces:**
- Consumes: `SyncEntityID`, `SyncMutationStamp`, `SyncFieldVersion`.
- Produces: `SyncRecord`, `SyncRecordPayload`, `SyncRelationship`, `SyncRecordValidator.validate(_:)`.

- [ ] **Step 1: Write failing tests for schema and yarn-link validation**

```swift
@Test func yarnLinkRequiresProjectAndYarnWithoutDeletingYarn() throws {
    let link = SyncRecord.fixture(kind: .projectYarnLink, relationships: [
        .init(role: "project", target: .init(kind: .project, uuid: UUID())),
        .init(role: "yarn", target: .init(kind: .yarn, uuid: UUID()))
    ])
    #expect(try SyncRecordValidator().validate(link) == link)
    #expect(link.payload.deletedRelatedEntityIDs.isEmpty)
}

@Test func futureSchemaIsRejected() {
    #expect(throws: SyncRecordValidationError.unsupportedSchema(2)) {
        try SyncRecordValidator(currentSchemaVersion: 1).validate(.fixture(schemaVersion: 2))
    }
}
```

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter SyncRecordValidationTests`

Expected: FAIL because the record and validator types do not exist.

- [ ] **Step 3: Implement a field map rather than one archive blob**

```swift
public enum SyncScalar: Codable, Equatable, Sendable {
    case string(String), integer(Int64), decimal(Double), boolean(Bool), date(Date), uuid(UUID), data(Data)
}

public struct SyncRecordPayload: Codable, Equatable, Sendable {
    public var fields: [String: SyncFieldVersion<SyncScalar>]
    public var deletedRelatedEntityIDs: [SyncEntityID] = []
}

public struct SyncRelationship: Codable, Equatable, Sendable {
    public let role: String
    public let target: SyncEntityID
}

public struct SyncRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: SyncEntityID
    public var entityRevision: UInt64
    public var payload: SyncRecordPayload
    public var relationships: [SyncRelationship]
    public var deletedAt: SyncFieldVersion<Date?>
}
```

The validator must reject unknown schema versions, missing required relationship roles, duplicate roles that must be singular, scalar values larger than 256 KB, and illegal cross-kind relationships. It must never synthesize a missing project or yarn.

- [ ] **Step 4: Run focused and full tests**

Run: `swift test --filter SyncRecordValidationTests && swift test`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/KnitNoteCore/CloudSync/SyncRecord.swift Sources/KnitNoteCore/CloudSync/SyncRecordValidation.swift Tests/KnitNoteCoreTests/SyncRecordValidationTests.swift
git commit -m "feat: model validated sync records"
```

### Task 3: Deterministic merge engine

**Files:**
- Create: `Sources/KnitNoteCore/CloudSync/SyncMergeEngine.swift`
- Test: `Tests/KnitNoteCoreTests/SyncMergeEngineTests.swift`

**Interfaces:**
- Consumes: `[SyncRecord]` local, `[SyncRecord]` remote, `Set<SyncEntityID>` locally pending.
- Produces: `SyncMergeEngine.merge(local:remote:pendingLocal:) throws -> SyncMergeResult`.

- [ ] **Step 1: Write failing tests for field union, conflicts, deletion, and determinism**

```swift
@Test func concurrentDifferentFieldsMergeAndSameFieldUsesStamp() throws {
    let result = try SyncMergeEngine().merge(
        local: [.project(name: "Local", note: "Base", nameRevision: 4, noteRevision: 1)],
        remote: [.project(name: "Base", note: "Remote", nameRevision: 1, noteRevision: 5)],
        pendingLocal: []
    )
    #expect(result.records.single.string("name") == "Local")
    #expect(result.records.single.string("note") == "Remote")
}

@Test func inputOrderNeverChangesMergeOutput() throws {
    let a = try SyncMergeEngine().merge(local: fixtures, remote: fixtures.reversed(), pendingLocal: [])
    let b = try SyncMergeEngine().merge(local: fixtures.reversed(), remote: fixtures, pendingLocal: [])
    #expect(a == b)
}
```

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter SyncMergeEngineTests`

Expected: FAIL because `SyncMergeEngine` is undefined.

- [ ] **Step 3: Implement merge output and conflict categories**

```swift
public enum SyncConflict: Codable, Equatable, Sendable {
    case corruptEqualStamp(entity: SyncEntityID, field: String)
    case attachmentVersions(owner: SyncEntityID, role: String, ids: [SyncEntityID])
    case possibleDuplicate(ids: [SyncEntityID])
}

public struct SyncMergeResult: Equatable, Sendable {
    public let records: [SyncRecord]
    public let conflicts: [SyncConflict]
    public let recordsToUpload: Set<SyncEntityID>
}

public struct SyncMergeEngine: Sendable {
    public func merge(
        local: some Sequence<SyncRecord>,
        remote: some Sequence<SyncRecord>,
        pendingLocal: Set<SyncEntityID>
    ) throws -> SyncMergeResult
}
```

Sort records and fields before comparing. Equal stamps with unequal values throw `SyncMergeError.corruptEqualStamp`. A delete-plus-modify result stays deleted but retains the merged payload for 30-day restoration. Attachment roles return a conflict instead of discarding a version.

- [ ] **Step 4: Run merge, yarn-link, and full tests**

Run: `swift test --filter SyncMergeEngineTests && swift test --filter YarnLink && swift test`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/KnitNoteCore/CloudSync/SyncMergeEngine.swift Tests/KnitNoteCoreTests/SyncMergeEngineTests.swift
git commit -m "feat: add deterministic sync merge engine"
```

### Task 4: Durable mutation journal

**Files:**
- Create: `Sources/KnitNoteCore/CloudSync/SyncMutationJournal.swift`
- Test: `Tests/KnitNoteCoreTests/SyncMutationJournalTests.swift`

**Interfaces:**
- Produces: `SyncMutation`, `SyncMutationJournalProtocol`, `FileSyncMutationJournal`.

- [ ] **Step 1: Write failing persistence and acknowledgement tests**

```swift
@Test func journalSurvivesRestartAndAcknowledgesOnlyMatchingMutation() async throws {
    let first = FileSyncMutationJournal(url: fixture.url)
    try first.enqueue(.save(recordID, mutationID: mutationID))
    let reopened = FileSyncMutationJournal(url: fixture.url)
    #expect(try reopened.pending() == [.save(recordID, mutationID: mutationID)])
    try reopened.acknowledge(recordID: recordID, mutationID: UUID())
    #expect(try reopened.pending().count == 1)
}
```

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter SyncMutationJournalTests`

Expected: FAIL because the journal types are undefined.

- [ ] **Step 3: Implement an atomic file-backed actor**

```swift
public enum SyncMutation: Codable, Equatable, Sendable {
    case save(SyncEntityID, mutationID: UUID)
    case delete(SyncEntityID, mutationID: UUID)
}

public protocol SyncMutationJournalProtocol: Sendable {
    func enqueue(_ mutation: SyncMutation) throws
    func pending() throws -> [SyncMutation]
    func acknowledge(recordID: SyncEntityID, mutationID: UUID) throws
}

public final class FileSyncMutationJournal: SyncMutationJournalProtocol, @unchecked Sendable {
    public init(url: URL)
}
```

Protect in-memory state and the complete write transaction with one private `NSLock`. Write a versioned envelope to a sibling temporary file, synchronize it, atomically replace the live file, and synchronize the parent directory. On decode failure, throw `SyncMutationJournalError.corrupt` and preserve the bytes for diagnosis; never replace with an empty journal.

- [ ] **Step 4: Run interruption, restart, and full tests**

Run: `swift test --filter SyncMutationJournalTests && swift test`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/KnitNoteCore/CloudSync/SyncMutationJournal.swift Tests/KnitNoteCoreTests/SyncMutationJournalTests.swift
git commit -m "feat: persist pending sync mutations"
```

### Task 5: Post-commit store publication boundary

**Files:**
- Create: `Sources/KnitNoteCore/CloudSync/SyncMutationPublishing.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Test: `Tests/KnitNoteCoreTests/JSONProjectStoreSyncPublicationTests.swift`

**Interfaces:**
- Consumes: `SyncMutationSink.publish(_:) throws`.
- Produces: `SyncRecordProvider` for later mapper injection and `JSONProjectStore` initializer injection `syncMutationSink: any SyncMutationSink = DisabledSyncMutationSink()`.

- [ ] **Step 1: Write failing success, archive-failure, and yarn-unlink publication tests**

```swift
@Test func archiveFailurePublishesNothing() async throws {
    let sink = RecordingSyncMutationSink()
    let store = fixture.store(archiveWrite: { _, _ in throw CocoaError(.fileWriteUnknown) }, sink: sink)
    #expect(throws: (any Error).self) { try store.renameProject(id: fixture.projectID, name: "New") }
    #expect(await sink.mutations.isEmpty)
}

@Test func unlinkPublishesLinkDeletionWithoutYarnDeletion() async throws {
    try store.unlinkYarn(projectID: projectID, yarnID: yarnID)
    #expect(await sink.deletedKinds == [.projectYarnLink])
}
```

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter JSONProjectStoreSyncPublicationTests`

Expected: FAIL because the sink injection and sync export do not exist.

- [ ] **Step 3: Add the sink and a single post-commit hook**

```swift
public protocol SyncMutationSink: Sendable {
    func publish(_ mutation: SyncMutation) throws
}

public protocol SyncRecordProvider: Sendable {
    func record(for id: SyncEntityID) throws -> SyncRecord?
}

public struct DisabledSyncMutationSink: SyncMutationSink {
    public init() {}
    public func publish(_ mutation: SyncMutation) throws {}
}
```

Route every successful store mutation through one `commitArchiveAndPublish` helper. Do not sprinkle publication calls through views. If publication fails after archive commit, set a distinct durable `syncPublicationError` and block the next mutation until the journal can be repaired; never roll back to an older archive over a successful user write.

- [ ] **Step 4: Run store, backup, Watch, and full tests**

Run: `swift test --filter JSONProjectStoreSyncPublicationTests && swift test --filter KnitNoteBackupServiceTests && swift test --filter Watch && swift test`

Expected: PASS.

- [ ] **Step 5: Commit and review the phase**

```bash
git add Sources/KnitNoteCore/CloudSync/SyncMutationPublishing.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/JSONProjectStoreSyncPublicationTests.swift
git commit -m "feat: publish sync mutations after local commit"
git diff --check HEAD~5..HEAD
```

Phase gate: an independent reviewer confirms that no user mutation can succeed without either a durable journal entry or an explicit blocking sync-publication error.
