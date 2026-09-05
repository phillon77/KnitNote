# Recoverable Sync Deletion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete migration/account-safety Plan3 Task3 with durable deleted-content retention, actual restoration, and acknowledged reference-safe purge.

**Architecture:** A deletion ledger stores only selected canonical content and verified independent attachment copies, not a whole-account archive. The existing publication transaction is the commit witness; ledger preparation precedes destructive file operations, activation precedes publication-marker reclamation. Restore publishes new causal state; compact markers outlive purged content and reject resurrection at merge entry.

**Tech Stack:** Swift 6, Foundation, CryptoKit, Darwin, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-02-cross-device-icloud-sync-design.md`, sections on relationships, deletion, and recent deletion. This plan refines Task3 of `docs/superpowers/plans/2026-09-02-cross-device-sync-3-migration-account-safety.md` without enabling live sync or changing its remaining tasks.

## Global Constraints

- 使用者刪除 entity 時寫入 `deletedAt` 與 deletion mutation，項目從一般列表移至「最近刪除」。
- 30 天內復原會清除 deleted state、恢復必要關聯，並產生新的同步 mutation。
- 30 天後先確認刪除 mutation 已傳至雲端，才清除使用者內容及無引用 attachments。
- `ProjectYarnLink` 是一級同步 entity。解除「使用毛線」只刪除 link，永遠不刪除 `Yarn`。
- Yarn 或 pattern asset 若仍被其他 project／usage 引用，不得因單一 project 刪除而清除。
- 使用者建立或匯入的名稱、筆記、毛線文字與織圖內容原樣同步，不翻譯。
- Compact markers are retained indefinitely; no supported maximum offline window has been defined.
- Preserve no-sync behavior. No live user data, CloudKit schema, account switching, UI, push, archive, upload or submission operations.
- Acknowledgement means an explicit exact immutable deletion/removal version, never absence from a journal snapshot. All pending record versions and bytes remain protected.
- Ongoing daily canonical checkpoint advancement and real account/freeze lifecycle remain mandatory Plan4 integration gates. Do not substitute archive timestamps for remote canonical authority.
- Reuse completed mapper/bootstrap contracts at base `0c46e1dff81c9bc6b016d39238a0472a18fb4e66`. Existing full-suite attempt is incomplete; run changed-surface tests, not unchanged release-audit matrices for every task. Final phase retains full-validation gate.

## Locked boundaries and file responsibilities

| File | Responsibility |
| --- | --- |
| `Sources/KnitNoteCore/CloudSync/SyncDeletedDomain.swift` | Select owned canonical records and removed atomic reminders; validate a recoverable selection against current supporting parents. |
| `Sources/KnitNoteCore/CloudSync/SyncDeletionLedger.swift` | Account-root-owned verified copies, prepared/active/restoring/purging state, publication witness recovery and compact marker persistence. |
| `Sources/KnitNoteCore/CloudSync/SyncDeletionPolicy.swift` | Pure clock/ack/reference decision, compact marker payload conversion and validation. |
| `Sources/KnitNoteCore/Projects/JSONProjectStore.swift` | Narrow pre-deletion capture and central publication hooks, actual restore/incoming/purge adapters. Do not restructure the large store. |
| `Sources/KnitNoteCore/CloudSync/SyncMutationPublishing.swift` | Optional backward-compatible deletion-ledger witness in the existing publication transaction, if needed to bind recovery. |
| `Sources/KnitNoteCore/CloudSync/SyncMergeEngine.swift` | Marker gate for both overloads and frozen pending payloads. Preserve merge policy for admissible records. |
| `Sources/KnitNoteCore/CloudSync/SyncRecordValidation.swift` | Validate content-free deletion-marker shape. |

### Domain and ownership decision

Retain selected canonical records, not `beforeArchive` wholesale. Existing mapper roundtrip is the field authority. A group stores its selected root IDs, owned cascade IDs, complete canonical payloads for those IDs (including attachment history and Watch proofs), and only IDs of shared supporting parents. Do not copy unrelated projects, yarn text or shared pattern content into a group. Shared supporting parents are resolved from current canonical state on restore; absence is an explicit restoration error with the group untouched.

Direct reminder deletion is not a standalone legacy reminder record. Retain only the removed `KnittingReminder` values keyed by their counter ID, and the exact aggregate removal version. Restoration adds those reminders to the current counter state without reverting counter value, occurrence, prepared command or processed Watch proofs. Removing a project retains its complete owned counter state as part of its project cascade.

```swift
struct SyncDeletedDomain: Codable, Sendable {
    let rootIDs: Set<SyncEntityID>
    let ownedRecords: [SyncRecord]
    let supportingParentIDs: Set<SyncEntityID>
    let removedReminders: [UUID: [KnittingReminder]]
    let removedLegacyPatterns: [UUID: [PatternDocument]]
}

struct SyncDeletionFileProof: Codable, Equatable, Sendable {
    let attachmentVersionID: UUID
    let restoreRelativePath: String
    let retainedRelativePath: String
    let byteCount: Int64
    let sha256: Data
}

struct SyncDeletionEntry: Codable, Sendable {
    let id: UUID
    let deletedAt: Date
    let domain: SyncDeletedDomain
    let exactRemovalVersions: [SyncRecordVersion]
    let files: [SyncDeletionFileProof]
}
```

For validation only, form a temporary live view of retained tombstones by clearing deletion overlays/cascades in a copy, combine required current supporting records, and use existing mapper/domain validators. Never publish this temporary view. Preserve authoritative tombstones unchanged in the ledger. New restored overlays are allocated through the normal causal publication path.

### Files and recovery decision

Retain independent verified copies under a dedicated hidden ledger root derived from the archive URL; these are not original photo folders, journal-owned staged files, or bootstrap backups. No collector owns this root. Capture before any pattern-deletion staging or physical cleanup can move the source. Verify regular no-follow ancestry, link count, bounded read, hash and size; synchronize copies and containing directories before allowing destructive operations. Same relative filename with later new bytes cannot mutate retained copies.

Because copies are independent, ordinary collectors may reclaim the removed original after commit. Do not protect the originals forever or modify unrelated collector algorithms. Tests must deliberately remove/replace original files and still restore retained bytes. Startup recovery must run before publication evidence reclamation and collectors; corrupt/ambiguous ledger state blocks synced mutation/cleanup.

## Task 1: Ledger and selected-domain proof storage

**Files:** Create `SyncDeletedDomain.swift`, `SyncDeletionLedger.swift`, and `Tests/KnitNoteCoreTests/SyncDeletionLedgerTests.swift`. Store integration is Task2 and is not part of this task.

**Interfaces:**
- `SyncDeletionLedger(root: URL)` owns validated ledger storage only.
- `stage(domain:attachments:restoreRelativePaths:deletedAt:) throws -> UUID` creates invisible retained copies; sources use `[UUID: SyncAttachmentSource]` and destinations `[UUID: String]`. Required copies include all unresolved live lineage heads, not just the selected winner; metadata retains ancestors/tombstones without requiring nonexistent historical bytes.
- `prepare(id:beforeArchiveSHA256:afterArchiveSHA256:exactRemovalVersions:publicationSHA256:) throws` binds a staged group to canonical JSON-encoded existing publication transaction bytes after causal revision allocation.
- `activate(id:publicationSHA256:) throws` makes a group visible only after archive commit and successful journal publication. A durable per-group witness allows the publication marker to be removed afterward.
- `recover(archiveSHA256:publication:) throws`, with `publication: SyncPublicationTransaction?`, resolves precommit/committed/pending-repair states before later store mutations and collectors.
- `recentlyDeleted() throws -> [SyncDeletionEntry]` is durable across process recreation and requires no live canonical cache for reading.

- [ ] Write failing ledger tests for invisible stage, source replacement independence, unsafe source refusal, corrupt manifest, exact witness mismatch, and recreation.
- [ ] Write failing exact-proof tests for owned record tombstones, removed reminders' aggregate counter saves and removed legacy patterns' aggregate project saves. Missing/extra/mismatched removal versions and mismatched required-head file proof sets must fail both preparation and reload, even when the manifest envelope checksum is correct.
- [ ] Exercise witness transitions with actual encoded `SyncPublicationTransaction` values: wrong fingerprint, same archive but wrong publication, pending repair, durable activation and replay. This verifies the ledger's caller contract; actual sink/archive ordering is Task2.

```swift
@Test func newLedgerStartsEmpty() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let ledger = try SyncDeletionLedger(root: directory)
    #expect(try ledger.recentlyDeleted().isEmpty)
}
```

- [ ] Run `CLANG_MODULE_CACHE_PATH=/tmp/plan3-clang-cache swift test --disable-sandbox --filter SyncDeletionLedgerTests`; record actual behavioral RED for each missing invariant. The existing three untracked drafts are incomplete input, not approved implementation.
- [ ] Implement supplied-domain validation and independent copies, including selected embedded reminder/legacy-pattern shapes; no automatic whole-store domain selector yet. Retain exact immutable metadata, validate required copies on recreation, and bound manifest/file reads. Failed writes cannot lose the last active manifest or retained copies. Serialize cooperating ledger handles consistently with existing durable storage conventions.
- [ ] Run ledger and affected record-validation/attachment tests. Commit `feat: store verified recoverable deletion entries`. Do not claim actual synced deletion is protected until Task2 passes.

## Task 2: Connect retention to store publication

**Files:** Modify `SyncDeletedDomain.swift`, `SyncDeletionLedger.swift`, `JSONProjectStore.swift` and, only for a backward-compatible witness field, `SyncMutationPublishing.swift`; create `Tests/KnitNoteCoreTests/JSONProjectStoreSyncDeletionTests.swift` and update affected sync-publication fixtures.

**Interfaces:** Consume Task1 stage/prepare/activate/recover/recentlyDeleted. Add a selected-domain capture helper taking the actual current canonical before/after record sets and existing archive domain values for embedded removals; its output is Task1 `SyncDeletedDomain`. No guessed revisions. Existing recording-sink deletion fixtures must establish explicit known-local bootstrap hydration.

- [ ] Write failing store tests for project/yarn/pattern/journal/link/reminder and legacy-pattern removal capture and no-sync compatibility. Use existing complete backup fixtures for media. Missing/stale hydration must refuse synced deletion without changing originals.
- [ ] Exercise failure before archive write, after rename with thrown writer, after journal failure, and after ledger activation before publication marker removal. Assert original or retained content, never neither; a prepared entry cannot falsely appear after an uncommitted deletion.

```swift
let before = try ledger.recentlyDeleted()
try store.delete(id: projectID)
let after = try ledger.recentlyDeleted()
#expect(after.count == before.count + 1)
#expect(after.last?.domain.rootIDs.contains(.init(kind: .project, uuid: projectID)) == true)
```

- [ ] Run `CLANG_MODULE_CACHE_PATH=/tmp/plan3-clang-cache swift test --disable-sandbox --filter 'JSONProjectStoreSyncDeletionTests|JSONProjectStoreSyncPublicationTests'` and record RED.
- [ ] Implement selected-domain capture from actual before/after canonical diff and removed embedded IDs. Stage before any existing `PatternLibraryDeletionTransaction.stage` or other destructive source operation; bind exact versions after `allocateCausalRevisions`.
- [ ] Make `publish` activate after durable mutation sink publication and before `transactionFile.remove()`. Reconcile ledger/publication before collectors and later writes; retain pending content while journal repair is required. Independent copies let original collectors retain their normal ownership.
- [ ] Run deletion/publication/backup/yarn and existing pattern deletion suites. Commit `feat: connect deletion retention to store transactions`.

## Task 3: Actual restoration and incoming deleted content

**Files:** Modify `SyncDeletedDomain.swift`, `SyncDeletionLedger.swift`, `JSONProjectStore.swift`; extend `JSONProjectStoreSyncDeletionTests.swift`; create `Tests/KnitNoteCoreTests/SyncDeletedDomainTests.swift`.

**Interfaces:**
- Consume Task1 `SyncDeletionEntry` and durable staged files.
- `JSONProjectStore.restoreRecentlyDeleted(id: UUID, now: Date) throws` requires an unexpired group and current exact hydrated authority. Missing parents/bytes or stale hydration fail without changing ledger or live archive.
- `SyncDeletionLedger.captureIncomingDeleted(domain:exactRemovalVersions:attachments:deletedAt:) throws -> UUID` consumes complete validated recoverable domain, not metadata-only tombstones. Repeated identical input is idempotent; newer concurrent canonical content updates the same logical group without restarting its retention clock arbitrarily.
- `beginRestore(id:publicationSHA256:)`, `finishRestore(id:publicationSHA256:)`, and startup replay use the same publication witness as deletion. Do not remove the last retained copy before restored archive/files/journal are durable.

- [ ] Write a day-29 test that deletes a complete project, removes original media, recreates ledger/store, hydrates exact current records, restores, and checks all UUIDs, six counters, reminders, notes, journals, links, pattern usages/markup and bytes.
- [ ] Write tests proving another project's edits and shared yarn/pattern data remain unchanged; missing shared parent refuses restoration with retained content still readable.
- [ ] Write direct-reminder restoration test: delete reminder, advance counter and Watch processed ledger, restore reminder, assert the later counter/Watch state remains exact.
- [ ] Write incoming-delete/concurrent-edit test using actual `SyncMergeEngine` output and a complete recoverable domain: newest edited deleted content survives reopen and restores. Metadata-only/mismatched domain/hash inputs must fail.

```swift
let deadline = deletedAt.addingTimeInterval(30 * 24 * 60 * 60)
let day29 = deletedAt.addingTimeInterval(29 * 24 * 60 * 60)
#expect(day29 < deadline)
try store.restoreRecentlyDeleted(id: deletionID, now: day29)
#expect(store.projects.contains { $0.id == originalProjectID })
```

- [ ] Run `CLANG_MODULE_CACHE_PATH=/tmp/plan3-clang-cache swift test --disable-sandbox --filter 'SyncDeletedDomainTests|JSONProjectStoreSyncDeletionTests'` and record behavioral RED.
- [ ] Build candidate by inserting only selected retained records into current canonical state with newly allocated restoration overlays; do not replace the entire archive. Use mapper/normal store persistence and transaction-owned verified copies. For direct reminders merge into current atomic group, not old aggregate state.
- [ ] Incoming materialization validates the complete selected revived view but persists exact deleted canonical records. Record-to-domain mismatches, missing files, account-root escape and counter/Watch regressions fail before activation.
- [ ] Inject interruptions before/after restored archive, journal publication and group retirement. Reopen must yield either active retained group or complete restoration, never lost content or double effects. Run focused tests plus mapper/publication/counter-reminder suites. Commit `feat: restore retained synchronized content`.

## Task 4: Reference-safe purge and permanent compact markers

**Files:** Create `SyncDeletionPolicy.swift`, `Tests/KnitNoteCoreTests/SyncDeletionPolicyTests.swift`; modify ledger/store/merge engine/record validator and their targeted tests.

**Interfaces:**
- `DeletionMarker` stores only target identity, optional aggregate parent identity, deletion/removal stamp and exact removal-version UUID. It contains no user text or attachment metadata/bytes.
- `SyncDeletionReferences` contains exact acknowledged removal-version UUIDs, protected record IDs, protected attachment version IDs and protected ledger-relative paths, captured under the current store/journal freeze.
- `SyncDeletionActions` contains `eligibleEntryIDs: Set<UUID>` and marker candidates. `SyncDeletionPolicy.evaluate(now:records:references:)` is pure.
- `JSONProjectStore.purgeRecentlyDeleted(now:acknowledgedVersions:references:) throws` revalidates explicit versions and fresh references under freeze, then persists marker/purge intent before deleting ledger-owned content only.
- Both `SyncMergeEngine.merge` overloads gain default-empty `deletionMarkers: [DeletionMarker]`. Apply the gate to local, remote and frozen pending payloads before existing merge policy; marker records from transport use the same validated compact representation.

```swift
public enum SyncDeletionPolicy {
    public static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
    public static func retentionDeadline(deletedAt: Date) -> Date {
        deletedAt.addingTimeInterval(retentionInterval)
    }
}
```

- [ ] Write pure boundary tests: day29 retained, exactly day30 eligible only with every exact removal acknowledgement, stale/missing ack retained, live/shared/pending references retained. NaN/infinite clock or malformed proof refuses purge.
- [ ] Write purge/reopen tests: crash after marker before unlink resumes; crash after unlink before completion is idempotent; markers remain after content purge and contain no names/text/hash/file payload.
- [ ] Write real merge tests for stale remote and pending entity resurrection, cascaded child resurrection, and a purged reminder reappearing inside an atomic aggregate. Reject/stage the incompatible atomic record rather than partially modifying its counter/Watch payload. New arbitrary higher stamps do not erase permanent purge authority; intentionally recreating content needs a new UUID.
- [ ] Run `CLANG_MODULE_CACHE_PATH=/tmp/plan3-clang-cache swift test --disable-sandbox --filter 'SyncDeletionPolicyTests|JSONProjectStoreSyncDeletionTests|SyncMergeEngineTests'` and record RED.
- [ ] Implement exact-proof and reference subset checks, not entity-ID-only acknowledgement. Persist compact markers and exact pending marker publication in the durable purge intent before unlinking group-owned paths. Preserve journal/bootstrap/other-account roots regardless of missing references. Directory fsync and no-follow verification follow existing durable file conventions.
- [ ] Validate `.deletionMarker` fields explicitly: target kind/UUID, optional aggregate parent, removal stamp/version; deterministic marker ID binds target identity, no user payload. Codec already carries generic scalar records; add offline encode/decode coverage if existing handling omits this kind, without changing live schema.
- [ ] Run affected ledger/store/deletion/merge/validator and backup/yarn-reference tests; final independent review covers all three tasks and cross-task witnesses. Commit `feat: purge acknowledged deletions without resurrection`.

## Self-review and parent completion gates

- Task1 reviews ledger/domain proofs, Task2 reviews actual publication integration, Task3 reviews restoration without purge, and Task4 adds content cleanup after those gates.
- Selected records and removed reminders are shared interfaces across all tasks; whole-account archive retention is prohibited.
- Exact publication versions bind capture/restore/purge; neither archive existence nor missing pending operations alone prove cloud acknowledgement.
- All four tasks and their final review must complete before marking parent Plan3 Task3 complete. Carry every unresolved integration/full-suite gate into parent ledger and final release checklist.
- Continue with the previously selected subagent-driven workflow; no new execution-method choice is needed.
