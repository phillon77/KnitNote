# Cross-Device Sync 2: CloudKit and Assets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Map validated sync records to CloudKit, exchange them through CKSyncEngine, and transfer immutable attachments without exposing CloudKit to the core model.

**Architecture:** Concrete CloudKit code lives in the iOS/macOS app target under `KnitNote/CloudSync`; the Watch target never compiles or receives CloudKit capability. A protocol adapter makes engine events deterministic in tests, while a file-backed asset staging service guarantees CKAsset source files survive until server acknowledgement.

**Tech Stack:** Swift 6, CloudKit, CKSyncEngine, CryptoKit, Foundation, Swift Testing

**Spec:** `docs/superpowers/specs/2026-09-02-cross-device-icloud-sync-design.md`

## Global Constraints

- Complete Plan 1 first; consume its type names without renaming them.
- Use the CloudKit private database and one custom record zone.
- Keep non-asset record payload below 1 MB and enforce a 256 KB application limit.
- Use CKAsset for photos, PDFs, and markup; never upload rebuildable thumbnails.
- Do not add CloudKit capability to KnitNoteWatch.
- Development-container writes are allowed only in explicit integration tests; production schema deployment remains manual.

---

### Task 1: CKRecord codec

**Files:**
- Create: `KnitNote/CloudSync/CloudRecordCodec.swift`
- Test: `Tests/KnitNoteAppTests/CloudRecordCodecTests.swift`

**Interfaces:**
- Consumes: `SyncRecord`.
- Produces: `CloudRecordCodec.encode(_:zoneID:) throws -> CKRecord` and `decode(_:) throws -> SyncRecord`.

- [ ] Write failing round-trip, unknown-field, future-schema, and size-limit tests using `CKRecord(recordType:recordID:)`.
- [ ] Run `xcodebuild test -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -only-testing:KnitNoteAppTests/CloudRecordCodecTests` and confirm missing codec failure.
- [ ] Implement one record type per `SyncEntityKind`, canonical JSON Data for versioned field maps, explicit relationship fields, and no user text in record names. Decode unknown optional fields, but reject unsupported `schemaVersion` and payloads over 256 KB.

```swift
struct CloudRecordCodec {
    func encode(_ record: SyncRecord, zoneID: CKRecordZone.ID) throws -> CKRecord
    func decode(_ record: CKRecord) throws -> SyncRecord
}
```

- [ ] Run focused app tests and `swift test`; expect PASS.
- [ ] Commit with `git commit -m "feat: map sync records to CloudKit"`.

### Task 2: CKSyncEngine protocol adapter and state persistence

**Files:**
- Create: `KnitNote/CloudSync/CloudSyncEngineTransport.swift`
- Create: `KnitNote/CloudSync/CloudSyncEngineStateStore.swift`
- Test: `Tests/KnitNoteAppTests/CloudSyncEngineTransportTests.swift`

**Interfaces:**
- Produces: `CloudSyncTransport`, `CloudSyncEvent`, `CKSyncEngineTransport`, `FileCloudSyncEngineStateStore`.

- [ ] Write failing tests proving state updates persist atomically, fetched changes preserve order within one callback, and account change clears engine state without clearing the Plan 1 mutation journal.
- [ ] Run the focused macOS app test and verify RED.
- [ ] Implement the adapter:

```swift
protocol CloudSyncTransport: AnyObject {
    var events: AsyncStream<CloudSyncEvent> { get }
    func start() async throws
    func schedule(_ mutations: [SyncMutation]) async throws
    func fetchNow() async throws
    func sendNow() async throws
}

enum CloudSyncEvent: Sendable {
    case accountChanged(previous: String?, current: String?)
    case fetched(records: [SyncRecord], deleted: [SyncEntityID])
    case sent(recordID: SyncEntityID, mutationID: UUID)
    case stateUpdated(Data)
    case failed(CloudSyncFailure)
}
```

Persist CKSyncEngine state with temporary-file write, file sync, atomic replacement, and parent sync. Map transient CK errors to retryable failures; surface `serverRecordChanged`, quota, invalid arguments, and account changes for coordinator policy.

- [ ] Run focused tests, `swift test`, and a generic iOS build; expect PASS.
- [ ] Commit with `git commit -m "feat: adapt and persist CKSyncEngine state"`.

### Task 3: Private zone coordinator

**Files:**
- Create: `KnitNote/CloudSync/KnitNoteCloudSyncCoordinator.swift`
- Test: `Tests/KnitNoteAppTests/KnitNoteCloudSyncCoordinatorTests.swift`

**Interfaces:**
- Consumes: `CloudSyncTransport`, `SyncMutationJournalProtocol`, `SyncMergeEngine`, `CloudRecordCodec`, and injected `SyncRecordProvider.record(for:) throws -> SyncRecord?`.
- Produces: `KnitNoteCloudSyncCoordinator.start()`, `syncNow()`, and `CloudSyncStatusSnapshot`.

- [ ] Write failing fake-transport tests for start, journal rescheduling after restart, fetch-before-bootstrap-send, duplicate acknowledgement, transient failure, and server-record-changed merge.
- [ ] Run focused tests and confirm RED.
- [ ] Implement a `@MainActor final class KnitNoteCloudSyncCoordinator: ObservableObject` that owns one event loop, never starts in screenshot mode, reschedules durable journal entries after engine initialization, and acknowledges only matching mutation IDs.

```swift
struct CloudSyncStatusSnapshot: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case disabled, waiting, syncing, needsAttention }
    let phase: Phase
    let pendingCount: Int
    let lastCompleteSuccess: Date?
    let issue: CloudSyncIssue?
}
```

Do not mark `lastCompleteSuccess` until fetch and send complete and the journal is empty. A missing record from `SyncRecordProvider` is a blocking consistency error, never an acknowledgement or silent skip; Plan 3 supplies the live domain implementation while this task uses a deterministic fake.

- [ ] Run coordinator tests plus `swift test --filter Sync`; expect PASS.
- [ ] Commit with `git commit -m "feat: coordinate private CloudKit sync"`.

### Task 4: Immutable attachment staging

**Files:**
- Create: `Sources/KnitNoteCore/CloudSync/SyncAttachment.swift`
- Create: `KnitNote/CloudSync/CloudAssetStagingService.swift`
- Test: `Tests/KnitNoteCoreTests/SyncAttachmentTests.swift`
- Test: `Tests/KnitNoteAppTests/CloudAssetStagingServiceTests.swift`

**Interfaces:**
- Produces: `SyncAttachmentMetadata`, `CloudAssetStagingService.stageUpload`, `installDownload`, `acknowledgeUpload`, and `quarantine`.

- [ ] Write failing tests for SHA-256 identity, immutable replacement, source-file survival until acknowledgement, hash mismatch rejection, and reference-safe cleanup.
- [ ] Run both focused suites and verify RED.
- [ ] Implement:

```swift
public struct SyncAttachmentMetadata: Codable, Equatable, Sendable {
    public let id: UUID
    public let owner: SyncEntityID
    public let role: String
    public let contentHash: String
    public let byteCount: Int64
    public let mediaType: String
    public let displayFilename: String
    public let replacementOf: UUID?
    public let conflictGroupID: UUID?
}
```

Copy upload sources into account-scoped staging; create a fresh CKAsset for each save attempt from that stable URL. Download to a temporary file, verify byte count and SHA-256, synchronize, then atomically install. Never attach one CKAsset object to multiple records.

- [ ] Run attachment, backup, pattern, yarn-photo, and full tests; expect PASS.
- [ ] Commit with `git commit -m "feat: stage immutable CloudKit assets"`.

### Task 5: Development-container integration harness

**Files:**
- Create: `Tests/KnitNoteAppTests/CloudKitDevelopmentIntegrationTests.swift`
- Create: `Tests/Fixtures/CloudKit/README.md`
- Modify: `project.yml`
- Modify: `KnitNote/KnitNote-iOS.entitlements`
- Modify: `KnitNote/KnitNote-macOS.entitlements`
- Test: `Tests/KnitNoteCoreTests/CloudKitEntitlementContractTests.swift`

**Interfaces:**
- Consumes all Plan 2 components.
- Produces an opt-in `KNITNOTE_RUN_CLOUDKIT_INTEGRATION=1` integration suite.

- [ ] Write source-contract tests that require the same iCloud container on iOS/macOS, CloudKit and remote-notification capabilities, and no CloudKit key in Watch configuration.
- [ ] Run contract tests and verify RED.
- [ ] Add the container identifier in one project-level configuration constant, generate entitlements through XcodeGen, and add an opt-in test that creates a unique test-zone record, fetches it, updates it, and deletes its test zone in cleanup. The test must refuse to run against a production environment marker.
- [ ] Run `xcodegen generate`, entitlement contract tests, full `swift test`, unsigned generic iOS/macOS builds, and the opt-in development integration only when the configured development container is available.
- [ ] Commit with `git commit -m "test: verify CloudKit development transport"` and run `git diff --check`.

Phase gate: review CKRecord schema, entitlements, test-container safety, asset lifetime, and ensure no production schema deployment occurred.
