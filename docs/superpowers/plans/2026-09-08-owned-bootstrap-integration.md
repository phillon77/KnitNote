# Owned Bootstrap Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. This is one cohesive Core integration unit with review checkpoints, not authorization to dispatch or activate the App. Steps use checkbox syntax for tracking.

**Goal:** Execute the existing three helper programs only after durable owned preparing, recover every admitted attempt to a sealable terminal, spend and reissue exact source authority, and retain linear predecessor evidence through authenticated account recovery.

**Architecture:** Keep ordinary bootstrap/helper behavior available for generic non-account callers. Introduce an internal account-owned transaction entry point whose private output issuer is reached only through a synchronized preparing selector; consume complete helper programs, including validation and synchronization steps. Land writer, terminal reader, source lifecycle and committed-plus-spent full sealing together before any account runtime caller can activate the route.

**Tech Stack:** Existing Swift Core package, Foundation, CryptoKit, Darwin descriptor operations, Swift Testing; existing Xcode source membership and App harness.

**Spec:** `docs/superpowers/specs/2026-09-08-owned-bootstrap-integration-design.md` (architectural direction accepted through the user's next-step request). The empty-before-root clarification is recorded with this plan for review; it preserves exact absence and adds no write or cleanup authority. Read the full spec and `2026-09-08-account-source-provenance-design.md` first; completed helper specs are dependencies, not tasks to redo.

**Execution mode (updated 2026-09-08):** The user explicitly reopened automatic delegation after Task 1A. Existing heartbeat `knitnote-1-7-0-9-7` is ACTIVE every 3 minutes, continuing safe local implementation, verification and review toward release preparation. Latest user cancellation overrides this record. App activation remains gated by this plan; signing, merge, push, upload and submission still require exact-candidate authorization.

**Execution progress (2026-09-08):** Task 1A mapper extraction implemented in the working tree; its evidence is in `docs/superpowers/reports/2026-09-08-owned-bootstrap-mapper-slice.md` (193 Core tests / 6 suites and 241 App tests / 12 suites passed). Task 1B's shared existing EnvelopeV2 allowance extraction is implemented and wired to the actual recovery call site and both production source phases. Final strengthened Core checks passed 122 tests / 4 suites; App passed 241 tests / 12 suites. Scoped independent reviewer `/root/owned_mapper_budget_review` found no Critical, Important or Minor issues in these two slices. Controller serial session 10140 finished exit 0; reviewer is done. The full prospective budget, manifest/history codecs, Tasks 1C/1D and 2–4 remain unimplemented; the full Task 1 review gate has not passed. Preserve all uncommitted source/test changes and continue the remaining Task 1B, not another standalone helper release.

### Latest allowance slice evidence

**Checkpoint2 review (2026-09-09 03:47):** Real preparing/output/abort implemented; Important frozen-output durability finding fixed and scoped re-review approved. Relevant136/7 and post-fix App241/12 passed on frozen candidate. Report docs/superpowers/reports/2026-09-09-owned-bootstrap-checkpoint-2.md lists evidence and remaining gates. Next Task3 source/install/rollback/authenticated recovery integration; broad helper trace Minor remains checkpoint4, no new v3 retry/production activation yet.

**Checkpoint1 review (2026-09-09 02:24):** All1A–1D data-only slices implemented and independently approved, no Critical/Important findings. Relevant Core348/16 and controller App241/12 passed on frozen source. One Minor committed-budget regression-strength item is deferred to full fault coverage, not claimed as exclusive committed rejection evidence. See docs/superpowers/reports/2026-09-09-owned-bootstrap-checkpoint-1.md. Next is coherent checkpoint2 durable preparing and actual no-delete output execution; no partial runtime reader or production activation.

**Latest continuation (2026-09-09 00:48, supersedes historical slice status below):** Mapper, allowance extraction, strict manifest, pure history and journal trace slices are implemented and independently reviewed. Final journal candidate focused39/2 passed; actual App241/12 passed, log `/tmp/owned-journal-app-green-01.log` SHA `f2e437c93d5b8c358bccefd7036a512eb7fcc390fe84786b50d7ba9d6cedb9d7`. Task1D `/root/owned_composition` is active for complete read-only composition/lifetime accounting; API RED confirmed, no behavioral GREEN yet. The full Task1 checkpoint is incomplete/uncommitted. See plan-scoped progress.md and task-1d-composition-brief.md for exact interface rulings. No actual owned writer, physical v3 retry admission or release readiness is claimed.

**Active continuation (23:16):** Task 1B pure v3 manifest wire slice is implemented, independently reviewed and fixed for exact Unicode cross-field path bindings. Final Core56 tests/2 suites and actual App241 tests/12 suites passed for the fixed candidate; no runtime activation or partial checkpoint commit. Plan-scoped ledger/brief/report live under `.superpowers/sdd/2026-09-08-owned-bootstrap-integration/`; read `progress.md` before redispatch. HistoryRecord/iterative embedded-chain validation is next, then full lifetime budgeting, journal trace, composition and physical terminal integration. Do not repeat the completed manifest codec slice.

- Codec final Core `/tmp/owned-manifest-review1-green.log`, exit0, SHA256 `0ca5c2a31647ef81860a71b4b78c76a09e33ba15f80954b2fadef70dd25df1f9`.
- Codec final App `/tmp/owned-manifest-app-green-02.log`, session64584 DONE exit0, SHA256 `7cf3dba96cc2a1ee3438158dbb19bfda33cbbce951c6176d5f91d02121c6db50`.
- Source manifest `31a935d6f1d248c380c3a2146b438fe261944a7e80d96b3656098898ddca0be1`, history ref `c9449b917d7db33039a2e15a34d6c5c678bc4beb618f4b41a23da6ae5106a3d2`, manifest tests `25f71fc5bc3bdeb065c18c994438f17931dbb852c420ed6f970136680c173afa`, PBX `b774339fb2a3ac04fa9cc6831fecf932500bc22cd79c12c65027a9a6262a52e6`.
- `/root/owned_manifest_codec_review` scoped re-review approved: prior P2 addressed, no new Critical/Important/Minor. App per-file source links and PBX membership include both new codec files. Full Task1 and release readiness remain incomplete.

**History continuation (23:48):** HistoryRecord and iterative provided-observation validation implemented and independently approved, with narrow actual legacy parser bridge. Core70/3 exit0 (`/tmp/owned-history-verified.log`, SHA `ae356501e8e295497128a5d3f978cd2347e5b6d0bfb2dae3e96d0e879c5cedb2`) and actual App241/12 exit0 (`/tmp/owned-history-app-green-01.log`, SHA `eed7b4799758e7afd0c479b908399371911ed25a242e0a24ced2c16da9ccbbfb`). Sources/report in plan-scoped task-1b-history-report.md. No authority/runtime/physical-enumeration claim. Next is1C journal trace, then1D actual complete lifetime/composition budget; full Task1 still uncommitted and incomplete.

- API RED: `/tmp/owned-budget-api-red-01.log`, missing type, exit 1; SHA256 `734e10c989124cc4f8bf14bc20c60ce08e06d1304fe1ed760a5ec20b655619f2`.
- Runtime RED: `/tmp/owned-budget-runtime-red-01.log`, 3 tests / 24 issues against zero-allowance scaffold, exit 1; SHA256 `6bbc316c55fa9897ad45f13bee727cef0cb1f5dbeca053050f59751a9f611a51`.
- Final Core: `/tmp/owned-budget-integration-green-02.log`, 122 tests / 4 suites, exit 0; SHA256 `19e22fff6f8310ffbcd65463ca75270d5507cf8dd7b769f2eaecc2d4da9bfc9f`. Includes real account recovery and inventory regressions plus mapper and new allowance tests.
- Final App: `/tmp/owned-budget-app-green-01.log`, 241 tests / 12 suites, exit 0; SHA256 `72496b25188151a5e6c6789331737f6729d58b92eda4882576a989804a4cac9c`.
- Frozen source SHA256: budget `9bc87a74317349b7306f4bac884a3f0898139089f2ae8f66a9b65ea61296058f`; recovery transaction `53b22a822c14635e60fec6892ceaf8b6ed9ef12a355d71942159d491fc890680`; budget tests `e4f93275ef73161b518b5d83a48884d2dd1d06bbc1e362d8ff44fabee0120db5`; project `725384b650c150b92a1db0f6ddba0e569830ceb9ba9746db17d7884fa4961c2a`.
- Encoding tests use the production `.withoutEscapingSlashes` setting and both zero and slash-producing bytes. The actual empty EnvelopeV2 supplies overhead; no guessed percentage, increased cap or source authority was introduced. New source membership and actual App harness symlink were reviewed; `plutil -lint` and `git diff --check` passed. Full Core, App-root and unsigned Xcode builds await the coherent checkpoint; no merge, source commit, push, upload or submission occurred.

## Global constraints

- Baseline inspected: `d0019f0c28c47859e1dd7e424a7aca4198149d59`, worktree `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`.
- Preserve version 1.7.0 (13), iOS18/macOS15/watchOS11; no signing, push, submission, live cloud/account/device use, schema change or App activation.
- Per-file/bootstrap/history/canonical/batch 100,000,000 bytes; journal 64MiB; incoming 128 batches/16MiB; control 8192 bytes; existing recovery aggregate cap unchanged.
- Preserve ordinary backup limits: archive20,000,000, manifest1,000,000, markup2,000,000/512 entries, media200,000,000, package4,000,000,000. Owned output intersects its independent100,000,000 file cap.
- Publication authority/tombstone16MiB, Watch1MiB, head64MiB; no invented count cap or retention duration.
- Caller holds producer freeze; context verification occurs outside synchronous account ownership; pure comparisons inside it. No lock across await and no recursive public sourceState/capture/context callback while holding storage ownership.
- No cleanup, unlink, pruning, arbitrary UUID adoption, source recreation from absence, fake `isJournalStaged` authority or test-only capability issuer. Retain outputs on first error; abort interrupted preparation instead of resuming it with new temporary identities.
- The public `remote.isComplete` Boolean remains insufficient transport provenance. This Core unit exposes no new public caller that blesses it; transport issuance and App factory activation remain separately gated.

## File ownership and shared seams

All paths below are relative to the inspected worktree. Existing source prefix is `Sources/KnitNoteCore/`; test prefix is `Tests/KnitNoteCoreTests/`.

| File | Responsibility |
| --- | --- |
| CloudSync/SyncBootstrapOwnedTransaction.swift (new) | Internal orchestration, ownership, phase-bound issuance; no public factory |
| CloudSync/SyncBootstrapOwnedProgram.swift (new) | Complete ordered copy/generated/helper composition; no I/O authority |
| CloudSync/SyncBootstrapOwnedManifest.swift (new) | Strict v3 wire types from spec, normalized digest; no directory adoption |
| CloudSync/SyncBootstrapHistory.swift (new) | Iterative bounded history decode and exact namespace/tree validation |
| CloudSync/SyncBootstrapRecoveryBudget.swift (new) | Prospective complete terminal/recovery encoding accounting |
| CloudSync/SyncBootstrapOwnedOutput.swift (new) | Descriptor operations invoked only through transaction-private issuer |
| CloudSync/ProjectArchiveSyncMapper.swift | Share unvalidated archive/path projection, preserve ordinary physical validation order |
| CloudSync/SyncMutationJournal.swift | Share actual encoders/reduction and internal phase-bound journal trace; ordinary path unchanged |
| CloudSync/SyncBootstrapTransaction.swift | Narrow shared install/rollback adapters and handoff construction; no second rollback algorithm |
| Backup/KnitNoteBackupService.swift | Existing package program plus read-only physical inspection |
| CloudSync/SyncDeletionLedger.swift | Existing capture program plus actual validation jobs |
| Projects/JSONProjectStore.swift | Existing publication program and required lock/sync obligations |
| CloudSync/SyncAccountStorage.swift | Existing descriptor ownership and restart routing, exact v3 recognition only |
| CloudSync/SyncAccountSourceState.swift and SyncAccountRecoveryControl.swift | Exact captured/spent/reissued authority comparisons |
| CloudSync/SyncAccountRecoveryInventory.swift and SyncAccountRecoveryTransaction.swift | Typed terminal evidence, source control observation, full authenticated seal/restore |

New tests: `SyncBootstrapOwnedTransactionTests.swift`, `SyncBootstrapOwnedBudgetTests.swift`, `SyncBootstrapOwnedManifestTests.swift`, `SyncBootstrapOwnedHistoryTests.swift`, `SyncBootstrapOwnedJournalTests.swift`. Put shared test scaffolding in `SyncBootstrapOwnedFixture.swift`; it constructs real storage/vault/transactions, never capabilities. Extend existing mapper/journal/bootstrap/account tests at their actual filenames.

Concrete existing seams verified at the baseline:

- Mapper `materialize(records:attachments:baseArchive:)`: source lookup, staged flag, proof match, physical read, then destination/collision, then required slots. Projection must not move later destination errors ahead of earlier physical errors.
- Journal `recoverySnapshot(accountRoot:inventoryEntries:maximumBytes:)`: existing base-envelope/partial-final-frame/cleanup-intent rejection; clean segmented versions 1–5 supported.
- Storage `withRecoveryOwnership(paths:account:maximumBytes:createControl:_:)`: synchronous descriptor scope. Context callbacks execute outside it.
- Control `replace(_:with:access:validateSource:)`: exact predecessor compare-and-publish, not unconditional replacement.
- Recovery `prepare(now:)`, `seal(_:now:)`, `cleanup(_:)`, `restore(vaultID:now:)`, `consumeRestoredSelection(vaultID:now:)`: use the real authenticated chain in tests.
- Existing bootstrap private install/rollback and private handoff initializer require narrow internal adapters; merely adding a sibling file cannot access them. Share their actual algorithm, not a copied implementation.

## Run contract and evidence

Do not rerun historical completed helper tests before making a new candidate. For each numbered checkpoint: write its first failing test, run its exact filter and inspect the failure, implement one behavior, rerun to green, then extend its negative matrix. A missing-symbol compile failure is initial API RED only; behavioral claims also require a runtime regression that fails for the intended invariant. Record both separately.

Run all commands from the worktree. The following shell function is session-local and writes no repository file:

```sh
owned_core_test() {
  env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION \
    python3 /tmp/task4-run-bounded.py 900 \
    arch -arm64 swift test --disable-xctest --no-parallel --filter "$1"
}
```

Use the inspected bounded runner (SHA256 `c9fbdb35fa3743e27a7fbf63a1a0cbabfb02ca10e299167c214841a915faec0b`); verify it still matches before execution. If cache access is denied, request the scoped cache/build permission; do not change test semantics. Capture each red/green output in a unique /tmp log. Exit 124 is incomplete, never a pass. Never run two compilers against the same build cache.

Start a local checkpoint commit only after its tests and review. Stage explicit changed paths only, preserve `.superpowers/absent-source-design-progress.md`, and record baseline/head/diff/log hashes in the final verification report. Intermediate checkpoints are not App-ready or release-ready.

## One deliverable, four review checkpoints

These checkpoints may use separate local commits after explicit execution authority and successful review, but no partial runtime v3 reader or issuer becomes available to existing account callers between checkpoints. Checkpoint4 is the activation gate for the internal route. The entire unit is necessary for accepting owned execution. If a checkpoint fails, keep existing callers on their current paths and preserve evidence; do not ship a successful prepared writer that cannot later seal.

### Task 1 / Checkpoint 1: Compose a complete admitted attempt and its actual lifetime budget

**Files:** create `Sources/KnitNoteCore/CloudSync/SyncBootstrapOwnedTransaction.swift`, `SyncBootstrapOwnedProgram.swift`, `SyncBootstrapOwnedManifest.swift`, `SyncBootstrapHistory.swift`, and `SyncBootstrapRecoveryBudget.swift`; modify `ProjectArchiveSyncMapper.swift`, `SyncMutationJournal.swift`, `SyncAccountRecoveryInventory.swift`, `SyncAccountRecoveryTransaction.swift` only for shared pure semantics/encoding consumed in this unit. Tests: new `SyncBootstrapOwnedTransactionTests.swift`, `SyncBootstrapOwnedBudgetTests.swift`; extend `ProjectArchiveSyncMapperTests.swift`, `SyncMutationJournalTests.swift`, `SyncMutationJournalSegmentTests.swift`.

**Proposed internal interfaces:** Names below are new and must be defined in this checkpoint, not presumed existing.

```swift
struct SyncBootstrapOwnedInput {
    let local: SyncExportPackage?
    let sourceArchive: ProjectArchive
    let remote: SyncBootstrapRemoteSnapshot
    let pending: SyncBootstrapPendingSnapshot?
    let counterReminderContext: SyncCounterReminderMergeContext
}
// Internal only, a request and accounting description; no initializer grants authority.
struct SyncBootstrapOwnedProgram {
    let transactionID: UUID
    let actions: [SyncBootstrapOutputAction]
    let backupPackages: [KnitNoteBackupPackagePlan]
    let deletion: SyncDeletionCaptureProgram
    let publication: SyncPublicationEvidenceOutputProgram
    let reservation: SyncBootstrapOutputPlan
    let preparingEnvelope: Data
    let maximumRecoveryEnvelopeBytes: Int
}
```

Keep concrete content and execution order in private implementation fields; use ordered `bytes(Data)` and `copy(sourceID, proof)` steps, not a mutable path-keyed content table. Sources are exact frozen live entries, exact selected local/remote attachments, or prior immutable output indices. Never overwrite an operation's content because a later operation has the same destination. Retain original helper programs and dispatch their original validation/sync steps at their exact positions.

- [ ] Add failing public-behavior mapper regression that supplies an invalid first attachment and an invalid later destination; verify the existing first physical failure remains first after sharing projection semantics. Add projection parity over legacy/library markup, labels, counters, deletion restoration and empty attachment maps. Use actual fixtures already in `ProjectArchiveSyncMapperTests.swift`; unvalidated projection has no source-read callback and cannot be returned as `ProjectArchiveSyncMaterialization`.
- [ ] Implement shared projection routines while keeping ordinary materialize's callback boundary before each destination and final required-slot validation. At execution compare actual archive/records/file paths/proofs with the preflight projection; mismatch aborts.
- [ ] Add journal trace parity tests for empty/duplicate enqueue, clean segmented checkpoint v1–v5 upgrades, segmented append, proof-shard rollover, checkpoint threshold, attachment staging/reuse, conflicting duplicate, and the already-existing base-envelope/partial-final-frame/cleanup-intent account rejection. The trace must represent directory/create/replace/append/sync with expected prior bytes, exact new bytes and fixed temporary IDs; existing journal parent flock adds no lock-file entry. This is private to the owned integration and is immediately paired with its actual executor in checkpoint2; do not deliver it as another detached planner.
- [ ] Implement complete source and copy composition: source-read metadata preflight first; selected attachment bytes admitted only after size/Base64 allowance, then descriptor verified. Build all generated UUIDs once, preserve mapper deterministic mutation IDs and FIFO, and reject cross-request child identities and full-path aliases before publication. Incoming-deletion request construction shares the actual restrictions currently in `retainIncomingDeletions`, including supporting-media obligations for media-free deleted projects.
- [ ] Use real helper projections in order: original backup, owned attachment copy, materialization, deletion program, canonical checkpoint, publication program, merged backup. The Staged projection after deletion is the publication program's `expectedInitialTree`; after publication it is the merged backup source. Validate both exact initial-tree preconditions. Include markup descendants selected by backup planning and preserve unselected ledger/publication history.
- [ ] Implement exact v3 wire codecs and history contracts from the accepted integration spec. Explicit source tag; strict keys/version/phase/non-null/hash/path/root checks; terminal-only history records. `preparationSHA256` hashes durable preparing payload. Prepared digest is encoded v3 normalized to prepared with historyHead and all original/installed/mutations/preparation fields intact. Receipt keeps existing source-proof formatVersion1/2 meaning, not manifest version3.
- [ ] Extract actual EnvelopeV2 inventory allowance calculation used at recovery.prepare lines144–152; use checked `(available / 4) * 3` and actual codec overhead. Build prospective capture representations for abortedPreparation, prepared-to-rolledBack, installed/commit-failed-to-rolledBack and committed+spent. Reserve each complete recovery shape, not an arbitrary fraction or sum of incompatible states. Include real escaped path costs, maximum physical identities, controls included/excluded exactly as current inventory, frozen output/current/history entries, exact terminal/history bytes and every Data Base64 layer.
- [ ] Map postinstall paths separately: Staged moves to working-set; Original stays; old live becomes Displaced; a failed new live becomes Failed; on rollback Displaced becomes working-set. Include live/Failed journal attachment files, `.attachments` parents, proof shards/checkpoint/segment paths, all planned journal temps/locks, receipt and receipt temp. These are phase-bound installation/commit effects, not new preparing allocation roles. Bounds must also cover next retry's one pending-history envelope and metadata.
- [ ] Add exact cap/cap+1 injected-small-limit tests that execute the real preflight and assert no active-next/new UUID/History output on rejection. Tests must include a case where five-role Entry accounting fits but embedded abort history fails, and a case where preparation fits but journal/receipt committed capture does not. Preserve file caps independently.


#### Task 1 executable slices

Execute 1A → 1B → 1C → 1D serially; each slice has its own red/green cycle, and the checkpoint review covers all four.

**1A — shared unvalidated mapper projection.** Add these internal types in `ProjectArchiveSyncMapper.swift`; they must not contain URLs or a validated-materialization conversion:

```swift
struct ProjectArchiveSyncUnvalidatedProjection {
    struct File {
        let relativePath: String
        let version: SyncAttachmentVersion
        let proof: SyncBootstrapOutputProof
    }
    let archive: ProjectArchive
    let files: [File]
    let records: [SyncRecord]
    let counterStates: [UUID: SyncCounterReminderState]
    let localOnlyRelativePaths: [String]
}
```

Add `static func projectUnvalidated(records: [SyncRecord], attachmentProofs: [UUID: SyncBootstrapOutputProof], baseArchive: ProjectArchive) throws -> ProjectArchiveSyncUnvalidatedProjection`. Extract the existing archive construction and attachment walk into private `project(records:baseArchive:attachmentProof:)`, where the last argument is `(SyncAttachmentVersion) throws -> SyncBootstrapOutputProof`. Invoke that closure at the existing source-lookup point, before destination and collision checks for each slot. The ordinary closure keeps source lookup/staged/proof/physical-reader checks in precisely the current order and records the admitted real source by version ID; only after projection succeeds rebuild its existing public materialization. The preflight closure is:

```swift
let projection = try project(records: records, baseArchive: baseArchive) { version in
    guard let proof = attachmentProofs[version.versionID] else {
        throw ProjectArchiveSyncMappingError.missingAttachment(version.slot)
    }
    guard proof.byteCount == version.byteCount,
          proof.sha256 == version.contentSHA256 else {
        throw ProjectArchiveSyncMappingError.invalidDomain(
            .init(kind: .attachment, uuid: version.versionID))
    }
    return proof
}
return projection
```

First test, inside the existing mapper test struct so its private real `stage` helper stays usable:

```swift
@Test func unvalidatedProjectionDoesNotReadAndCannotBypassMaterialization() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("owned-projection-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try BackupFixture.writeCompleteArchive(to: root)
    let archive = try JSONDecoder().decode(ProjectArchive.self,
        from: Data(contentsOf: root.appendingPathComponent("projects-v1.json")))
    let package = try ProjectArchiveSyncMapper.export(
        archive: archive, liveRoot: root, deviceID: "projection-test")
    let staged = try stage(package, root: root)
    let proofs = staged.mapValues {
        SyncBootstrapOutputProof(byteCount: $0.byteCount, sha256: $0.contentSHA256)
    }
    let projection = try ProjectArchiveSyncMapper.projectUnvalidated(
        records: package.records, attachmentProofs: proofs, baseArchive: archive)
    let actual = try ProjectArchiveSyncMapper.materialize(
        records: package.records, attachments: staged, baseArchive: archive)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(try encoder.encode(projection.archive) == encoder.encode(actual.archive))
    #expect(projection.files.map(\.relativePath) == actual.files.map(\.relativePath))
    #expect(projection.records == actual.records)
    let source = try #require(staged.values.first)
    try Data("damaged after planning".utf8).write(to: source.fileURL)
    _ = try ProjectArchiveSyncMapper.projectUnvalidated(
        records: package.records, attachmentProofs: proofs, baseArchive: archive)
    #expect(throws: (any Error).self) {
        try ProjectArchiveSyncMapper.materialize(
            records: package.records, attachments: staged, baseArchive: archive)
    }
}
```

- [x] Run `owned_core_test ProjectArchiveSyncMapperTests`: initial RED is missing `projectUnvalidated`; after the extraction expect all selected tests green.
- [x] Add separate runtime ordering regressions at the shared walk boundary: missing source, unstaged source and changed physical bytes must each precede that slot's invalid destination. Retain the ordinary loop traversal order; do not sort it as part of this extraction.
- [x] Extend the same parity test to `BackupFixture.writePatternLibraryArchive(to:includeLinkedYarn:)`, missing required media, label photos, optional markup and empty records. Reuse actual fixtures, never manufacture staged authority in production.

**1B — manifest/history codecs and complete recovery allowance.** Define the spec's `BootstrapManifestV3`, `BootstrapHistoryRef`, `BootstrapHistoryRecordV1`, `PreparedBody`, `RolledBackBody`, `CommitProgram` and `InstallRootIdentity` in the new manifest/history files. Wire proof structs must explicitly conform to Codable or use narrow private codable proof wrappers; the existing output proof does not currently conform. Add internal `SyncBootstrapOwnedManifestCodec.encode(_:)`, `decode(_:)`, `preparedSHA256(_:)` with Data input/output and a BootstrapManifestV3 decoded result. Digest calculation must unwrap only rolledBack's frozen entries, then normalize the phase to prepared. Use exhaustive phase switches; ordinary v1/v2 decoding remains in its existing owner.

Add the shared checked inventory allowance function to `SyncBootstrapRecoveryBudget`, then call it from the actual recovery EnvelopeV2 encoding path:

```swift
static func inventoryAllowance(maximumEnvelopeBytes: Int,
                               fixedOverheadBytes: Int) throws -> Int {
    guard (0...100_000_000).contains(maximumEnvelopeBytes),
          fixedOverheadBytes >= 0 else {
        throw SyncAccountRecoveryTransaction.Error.tooLarge
    }
    let remaining = maximumEnvelopeBytes.subtractingReportingOverflow(fixedOverheadBytes)
    guard !remaining.overflow, remaining.partialValue >= 0 else {
        throw SyncAccountRecoveryTransaction.Error.tooLarge
    }
    let raw = (remaining.partialValue / 4).multipliedReportingOverflow(by: 3)
    guard !raw.overflow else { throw SyncAccountRecoveryTransaction.Error.tooLarge }
    return raw.partialValue
}
```

This helper alone is not the full lifetime estimator. The complete composer below must construct each prospective actual inventory/envelope shape.

```swift
@Test func envelopeAllowanceIsCheckedAndRoundsDown() throws {
    #expect(try SyncBootstrapRecoveryBudget.inventoryAllowance(
        maximumEnvelopeBytes: 104, fixedOverheadBytes: 100) == 3)
    #expect(try SyncBootstrapRecoveryBudget.inventoryAllowance(
        maximumEnvelopeBytes: 103, fixedOverheadBytes: 100) == 0)
    #expect(throws: SyncAccountRecoveryTransaction.Error.tooLarge) {
        try SyncBootstrapRecoveryBudget.inventoryAllowance(
            maximumEnvelopeBytes: 99, fixedOverheadBytes: 100)
    }
}
```

- [ ] Run `owned_core_test 'SyncBootstrapOwnedBudgetTests|SyncBootstrapOwnedManifestTests|SyncBootstrapOwnedHistoryTests'` for RED and GREEN. Add strict unknown-key/version/phase/null/hash/root/path tests and the declared empty-abort-before-root case. An empty rolledBack tree must reject.
- [ ] Build history walk from the spec's explicit head and bytes reader using one mutable remaining count/byte budget and visited hash/UUID sets. Bind each decoded entry to its own terminal, and compare exact current namespace union only after the full walk. Do not call today's live-source comparison on every historical Original.
- [ ] Test maximum physical-identity metadata only in the prospective encoder, never in authority construction. Actual root identity tests must read real descriptors.

**1C — exact journal trace.** Keep the actual candidate state/duplicate proof/frame/checkpoint encoders in `SyncMutationJournal.swift`. Add instance method `func planOwnedEnqueue(_ mutations: [SyncMutation], accountRoot: URL, inventoryEntries: [SyncAccountRecoveryInventory.Entry], temporaryID: () -> UUID) throws -> CommitProgram`; the instance's existing journal URL fixes the journal path. Its result is data-only. Hold account ownership before journal coordination/parent flock; use the read-only loader and existing recovery admission. Share reduction functions with ordinary enqueue, keeping its actual validation and I/O ordering. No public method may execute a CommitProgram.

Trace construction must include the existing v5 conflict-persistence preflight/effects as well as the v1–v4 upgrade, shard and compaction cases from the spec; a v5 fixture cannot be declared covered by a v4-only test. Reuse of existing attachment files performs a real persisted-source validation. Empty requests remain a no-op; duplicate-only requests preserve the ordinary compaction decision. The fixed receipt is appended by the transaction composer, not the journal helper.

- [ ] Run `owned_core_test 'SyncBootstrapOwnedJournalTests|SyncMutationJournalTests|SyncMutationJournalSegmentTests|SyncMutationJournalFinalFixTests'` for RED/GREEN around each trace slice. Compare exact emitted bytes and pending mutation FIFO against an ordinary journal with the same admitted input; fixed temporary names may differ, final artifact bytes may not.
- [ ] Add bad-base-envelope, partial-frame and unresolved-cleanup fixtures. Both actual account recovery admission and owned planning must reject them without mutation. Ordinary generic journal behavior must still work.

**1D — complete composition.** The new transaction's internal `plan(_ input: SyncBootstrapOwnedInput) throws -> SyncBootstrapOwnedProgram` is read-only accounting, not an issuer. It validates actual source/control/pending snapshots under ownership and returns finite data. Private ordered execution content lives alongside the original helper programs; the public-looking signatures in this document remain module-internal.

Integration boundary clarification: this checkpoint's physical admission exercises supported archive/fresh/restored/legacy rolledBack sources. V3/history future accounting uses strict data-only fixtures, not a partial trusted terminal override. Physical v3 retry admission and exact terminal/history authenticated capture remain Task3's coherent writer/reader gate, mandatory before internal activation. Shared encoding-only Inventory v2 bootstrapEvidence follows the accepted spec; no runtime decode/capture acceptance is enabled early. The owned-only journal preflight source binding may select actual verified source bytes while preserving future owned mutation URLs, with exact version/proof binding and no ordinary behavior change.

For each possible terminal shape, encode the actual v3 envelope, history records and recovery inventory shape with maximum metadata identities, then add the actual selected control/packet bytes and all Base64 layers. Compare the largest complete shape to the existing cap. Include the next retry's one pending predecessor record. Do not add sizes of mutually exclusive live/Displaced placements as if all were live, and do not omit retained Failed.

- [ ] Run `owned_core_test 'SyncBootstrapOwnedTransactionTests|SyncBootstrapOwnedBudgetTests'`. Use a small injected cap where five-role planning fits but the full envelope cannot. Assert `plan` and rejected `prepare` leave exact main/next, UUID/history namespace and source bytes unchanged.
- [ ] Reject unsupported/unbounded helper effects before preparing. Finish this checkpoint with the whole program/budget, not a runtime reader or standalone planner release.
- [ ] Review the checkpoint against all task requirements; stage its exact source/test paths and commit locally as `feat: compose bounded owned bootstrap attempts`.

Review gate: one complete program/budget exists with no authority issued and every remaining I/O effect named. If journal trace cannot preserve existing reduction and physical write ordering, fail this gate with that specific operation; do not publish preparing with an estimate.

### Task 2 / Checkpoint 2: Durable preparing issues the only executor; real helper obligations run

**Files:** create `SyncBootstrapOwnedOutput.swift`; modify new owned transaction/program/history files, `SyncAccountStorage.swift`, narrow internal seams in `KnitNoteBackupService.swift`, `SyncDeletionLedger.swift`, `JSONProjectStore.swift`, `SyncMutationJournal.swift`. Preserve existing ordinary helper calls and cleanup policies.

**Interfaces:** owned transaction takes existing `storage`, `paths`, `account`, `context`, journal-relative path, pattern context and current-context validator. Define the internal entry signatures for real isolated tests; production callers may use them only after all checkpoints are complete. Output issuer lives as a private nested type of the owned transaction implementation; its constructor accepts the exact selected preparing readback and current `RecoveryAccess`, and cannot escape the synchronous lifetime. No `@testable` constructor or Boolean bypass.

- [ ] Write the first vertical fault fixture using actual verified storage allocation and real pending journal. Start a real owned preparation, fail the actual Staged output write, reopen and certify abortedPreparation, then invoke real recovery seal/cleanup/restore. Use shared `SourceInventoryFixture` at `SyncAccountRecoveryInventoryTests.swift:859` and `RecoveryInventoryFixture` at885 as fixture starting points; add a new shared owned fixture rather than exposing existing private `TransactionKeys` or issuing capabilities in tests.
- [ ] Implement fixed active/active-next publication: observe exact old selector/source/control/tree; prove chosen UUID absent and no unexplained siblings; write next, fsync next, recompare, rename, fsync namespace/account ancestry, reread/re-synchronize selected main. Do not create new UUID or History before that barrier. Context callback outside lock; inside revalidate captured context plus source and exact control observation.
- [ ] Handle first initialization partial main/next fail-closed as specified. Old authoritative main plus derivative next can be retried only after exact predecessor/source revalidation. A readable main after fsync uncertainty must be synchronized before output/install/handoff. Incomplete next never grants allocation.
- [ ] Implement history derivative handling from preparing's exact pending record: absent creation, exact complete resync, exact-prefix repair from durable bytes; reject conflicting bytes, link, directory, oversize or unknown record. Record names are lowercase SHA256 of full record envelope. After completion record immutable, and no record or UUID cleanup occurs.
- [ ] Implement no-follow descriptor output execution with expected parent identity, `O_EXCL` new temp, exact old target proof for replace, full-byte/length/hash verification, file fsync, rename and parent sync. Keep failed partial temp, package and scratch files; stop on first failure and invalidate issuer. Exact immutable reuse allocates no temp and still synchronizes parent. Lock spans declaration to required completion; publication lock remains held through compact-head durability.
- [ ] Execute backup exact package plan archive/manifest/copies at its fixed packageID/temporaryIDs, call `validateFrozenPackageSource` against actual role projection and real `inspectPackage` validation before prepared. Do not call ordinary `createPackage`, which has Foundation atomics and deleting catch behavior. Share read-only validation internals, not package cleanup.
- [ ] Execute every deletion `.output` and `.validate`; resolve incoming/initialRetained/earlierOutput exactly, verify before copying, then call actual materializer at validation steps including empty sources. Compare liveArchive or restorationPaths as encoded by the job. Validation sources are only preceding scratch step outputs. Scratch remains in ValidationMerged; no scratch migrates into live Staged. Reject purge intents before publication through nonmutating frozen ledger admission.
- [ ] Execute publication steps unchanged; preserve exact existing immutable bytes after semantic reuse, including noncanonical encodings; synchronize every specified parent. Verify actual final Staged against final projection. Execute actual local roundtrip/materialization and both backup validations before replacing preparing with prepared.
- [ ] Execute planned journal operations only after installation using shared actual journal state reduction and trace, with no cleanup/temp removal fallback. Do not truncate a failed append on reopen; interrupted commit routes through existing rollback preserving that failed live tree. Trace adoption checks exact expected installed journal state before any write and rejects additional callbacks/paths or changed source bytes.
- [ ] Failure/cancellation/restart while preparing joins all writers, completes exact pending history, revalidates unchanged live/pending/control/historical trees and enumerates bounded actual outputs. Match allocation role limits and safe-kind/no-follow ownership, freeze exact entries, publish abortedPreparation with final historyHead. No canonical handoff and no spend. Changed source/pending/control leaves all evidence unresolved and untouched.


#### Task 2 executable slices

**2A — real fixture and entry contract.** Define the following initializer and methods on internal `SyncBootstrapOwnedTransaction`. They are callable by `@testable` fixtures while the implementation is incomplete, but no App/transport/production factory may reference them until Task 4's gate:

```swift
init(storage: SyncAccountStorage, paths: SyncAccountStorage.Paths,
     account: SyncAccountIdentity, context: SyncBootstrapContext,
     journalRelativePath: String = SyncBootstrapTransaction.defaultJournalRelativePath,
     patternFolderNameContext: PatternFolderNameContext? = nil,
     maximumBytes: Int = 100_000_000,
     validateContext: @escaping (SyncBootstrapContext) throws -> Void,
     boundary: @escaping (SyncBootstrapOwnedBoundary) throws -> Void = { _ in }) throws
func plan(_ input: SyncBootstrapOwnedInput) throws -> SyncBootstrapOwnedProgram
func prepare(_ input: SyncBootstrapOwnedInput) throws -> SyncBootstrapPreparation
func install(_ prepared: SyncBootstrapPreparation) throws
func commit(_ prepared: SyncBootstrapPreparation) throws -> SyncBootstrapReceipt
func recover() throws -> SyncCanonicalBootstrapHandoff?
```

Define `SyncBootstrapOwnedBoundary: Equatable` with these cases in the owned transaction file: `beforePreparingPublication`, `afterPreparingPublication`, `beforeTransactionRootCreation`, `afterTransactionRootCreation`, `afterPreparationOutput(index: Int)`, `afterPreparedPublication`, `beforeSourceSpend`, `afterSourceSpend`, `afterLiveMove`, `afterStagedMove`, `afterInstalled`, `afterJournalOperation(index: Int)`, `afterReceipt`, `afterRollbackIntent`, `afterFailedMove`, `afterOriginalRestore`, `beforeAbortPublication`, `afterAbortPublication`. Hooks observe/fail real boundaries; they never return authority.

Add this shared fixture in the new test fixture file:

```swift
enum OwnedFixtureFailure: Error { case injected }
struct OwnedBootstrapFixture {
    let source: SourceInventoryFixture
    let context: SyncBootstrapContext
    init() throws {
        source = try SourceInventoryFixture()
        context = .init(accountIDHash: source.account.accountIDHash,
                        epoch: UUID(), freezeID: UUID())
    }
    func input() -> SyncBootstrapOwnedInput {
        .init(local: nil,
              sourceArchive: .init(version: ProjectArchive.currentVersion, projects: []),
              remote: .init(context: context, records: [], attachments: [:], isComplete: true),
              pending: nil, counterReminderContext: .init())
    }
    func transaction(maximumBytes: Int = 100_000_000,
                     boundary: @escaping (SyncBootstrapOwnedBoundary) throws -> Void = { _ in })
        throws -> SyncBootstrapOwnedTransaction {
        try .init(storage: source.storage, paths: source.paths, account: source.account,
                  context: context, maximumBytes: maximumBytes,
                  validateContext: { candidate in
                      guard candidate == context else { throw SyncBootstrapError.contextChanged }
                  }, boundary: boundary)
    }
    var namespace: URL {
        let live = source.paths.workingSet.standardizedFileURL
        let key = Data(SHA256.hash(data: Data(live.path.utf8)))
            .map { String(format: "%02x", $0) }.joined()
        return source.paths.accountRoot.appendingPathComponent(".KnitNote-SyncBootstrap")
            .appendingPathComponent(source.account.accountIDHash).appendingPathComponent(key)
    }
    func manifest() throws -> BootstrapManifestV3 {
        try SyncBootstrapOwnedManifestCodec.decode(
            Data(contentsOf: namespace.appendingPathComponent("active.json")))
    }
    func remove() { source.remove() }
}
```

Include Foundation, CryptoKit, Testing and `@testable import KnitNoteCore` in the test files. Empty pending is permitted only when actual live journal observation proves no mutations/no journal artifacts; adding an actual journal requires an exact pending fingerprint. The fixture's context callback is for isolated account simulation, not a production account-query bypass.

```swift
@Test func noAllocatedOutputBeforeDurablePreparing() throws {
    let f = try OwnedBootstrapFixture(); defer { f.remove() }
    let before = try f.source.diskBytes()
    var hit = false
    let tx = try f.transaction { point in
        if point == .beforePreparingPublication {
            hit = true
            throw OwnedFixtureFailure.injected
        }
    }
    #expect(throws: OwnedFixtureFailure.injected) { try tx.prepare(f.input()) }
    #expect(hit)
    #expect(try f.source.diskBytes() == before)
    #expect(!FileManager.default.fileExists(atPath: f.namespace.path))
}

@Test func abortBeforeRootFreezesExactAbsence() throws {
    let f = try OwnedBootstrapFixture(); defer { f.remove() }
    var hit = false
    let tx = try f.transaction { point in
        if point == .afterPreparingPublication {
            hit = true
            throw OwnedFixtureFailure.injected
        }
    }
    #expect(throws: (any Error).self) { try tx.prepare(f.input()) }
    #expect(hit)
    _ = try f.transaction().recover()
    let terminal = try f.manifest()
    guard case let .abortedPreparation(body) = terminal.body else {
        Issue.record("expected abortedPreparation"); return
    }
    #expect(body.frozenOutputEntries.isEmpty)
    #expect(!FileManager.default.fileExists(
        atPath: f.namespace.appendingPathComponent(terminal.id.uuidString).path))
    #expect(!FileManager.default.fileExists(atPath: f.source.archiveURL.path))
}
```

- [ ] Run `owned_core_test SyncBootstrapOwnedTransactionTests` and retain the initial failing output. Then implement one barrier at a time, preserving the original first error on a normal failure if abort succeeds; if abort fails, report unresolved recovery with both errors retained for diagnostics.
- [ ] Put namespace scaffolding creation AFTER the `beforePreparingPublication` test hook. Such fixed ancestors are publication scaffolding, not UUID/history output authority. Selector failures must preserve any actual scaffolding; no cleanup to satisfy the no-output test.
- [ ] Add a process-interruption simulation that stops before the catch/abort path by invoking injected syscall failure with the bounded child-process mechanism specified in Task 4A, then constructs a NEW storage instance using `openExistingAccount(identity:validateAccount:)`. Do not call normal close as proof of abrupt termination. Only exact transaction fixture files may be altered.

**2B — private executor.** Private issuer construction requires the exact synchronized preparing readback and current `RecoveryAccess`; it cannot escape that synchronous closure. Use the existing descriptor-open/no-follow helpers, not Foundation atomic writes. The actual operation sequence is:

```text
validate current account descriptors + captured source/control/pending
validate exact selected preparing readback and declared role/path/old proof
open exact parent; revalidate parent identity
create fixed temporary with O_EXCL | O_NOFOLLOW
copy/write only declared bytes; verify length/hash; fsync file
recompare destination's absence or old proof
rename fixed temporary to exact declared destination; fsync parent
revalidate owner, source/control/pending and current selected preparing
dispatch the next original helper step (including locks/sync/validation)
```

This is the implementation order, not permission to skip checked POSIX error handling. For syscall faults, add an internal I/O dependency with `write: (Int32, Data) throws -> Void` and `synchronize: (Int32) throws -> Void`; default write loops until complete and retries EINTR, default synchronize checks fsync. Only the private executor calls these dependencies. Inject a partial write in tests by writing an actual prefix through the passed descriptor, then throwing; the executor must retain that exact partial temp and stop. Do not expose a root/path override or capability initializer.

- [ ] Execute the original helper step enums directly. Directory-root reconciliation is limited to the identical known role-root declaration; publication lock encompasses the final head durability barrier. Resolve deletion's earlierOutput against its LOCAL program indices.
- [ ] After a successful helper output, compare actual descriptor proof to its planned proof. At validation steps run actual mapper and package inspector. A projection/physical mismatch aborts; it is not normalized away.
- [ ] Add partial Staged write, backup inspection failure, deletion restoration-path mismatch, reused immutable parent fsync failure and head fsync failure. Each must preserve original source/control/pending; no further forward output after failure.
- [ ] Run `owned_core_test 'SyncBootstrapOwnedTransactionTests|KnitNoteBackupPackagePlanTests|SyncDeletionCaptureProgramTests|SyncPublicationEvidenceOutputProgramTests'`.
- [ ] Review the complete real preparing→output→abort path; commit scoped paths locally as `feat: execute bootstrap outputs behind durable preparing`.

Review gate: captured operation log equals composed actions plus declared sync/validation and phase effects. Simulated fsync/write/rename cuts are ordinary injected failures through the real issuer; tests never fabricate ownership. No v3 runtime inventory activation yet.

### Task 3 / Checkpoint 3: SourceSpent, existing installer, exact terminal history and sealable recovery

Required legacy admission bridge: an exact no-control legacy missingArchive rolledBack source cannot directly supply v3 preparing's required source-control digest. Before planning that route, implement and fault-test a distinct owned durable absentSource handoff with exact legacy terminal/Original/source/pending/root and nil/nil control rechecks; then plan afresh using actual control bytes. Preserve unchanged rejection before that bridge exists. Inventory's transient generated source identity is not a control observation. Do not loosen the v3 nil-control-only-for-archive rule or certify this bridge through data-only history tests.

**Files:** modify `SyncBootstrapTransaction.swift`, `SyncBootstrapOwnedTransaction.swift`, `SyncAccountSourceState.swift`, `SyncAccountRecoveryControl.swift`, `SyncAccountRecoveryInventory.swift`, `SyncAccountRecoveryTransaction.swift`. Extend their actual existing test files and new owned tests.

**Interfaces:** share the existing install/commit/rollback algorithm through private phase load/persist/read-write adapters; do not maintain a second rollback algorithm. Keep ordinary `prepare/install/commit/recoverUnderCurrentContext` behavior on generic routes. Owned adapter calls phase-bound source checks before each existing live move and routes manifest persistence through fixed slots. Internal source-control transitions use actual `SyncAccountRecoveryControlFile.replace(_:with:access:validateSource:)`.

- [ ] Add real legacy missingArchive rolledBack → owned preparing → prepared → spent → install → commit → seal/cleanup/restore fixture. Add freshAllocation and restoredSelection starting routes with pending media/deletions and exact FIFO. Assert prior UUID contents/physical identities unchanged until authenticated cleanup.
- [ ] Implement prepared→sourceSpent after durable prepared and before first live move. Bind exact UUID and normalized prepared digest plus original source identity/baseline. Exact matching visible spent must be resynchronized before installation. Archive-source legacy route keeps its distinct source proof; no absence authority is invented for archives.
- [ ] Implement prepared-before-spend recovery through existing rollback under the exact unchanged initial source; do not silently spend to pass validation. Prepared/installed/rollingBack with matching spent use existing phase recovery. After exact rolledBack Original/live equality and matching spent UUID/digest, atomically issue a fresh absent generation. Preserve exact terminal bytes/context as origin; never rewrite to current epoch.
- [ ] Implement abortedPreparation handoff only against exact captured initial active source control or exactly already-issued terminal origin. Account hash/root/path/baseline and pending/deletion selected data must still match; conflicting selection/spent generation rejects. Archive-source abort remains archive provenance.
- [ ] Implement iterative v3 terminal/history validation with shared budget, exact chain counts/bytes, visited digest/UUID sets, explicit allowed phase bindings and exact namespace union. Unknown history file, extra UUID, replaced root, symlink, hardlink, special file, missing entry, path aliases or altered oldest tree reject. Historical Original matches that historical manifest; only selected current source matches today's live/pending baseline.
- [ ] Extend terminal evidence to carry exact ordered history envelope bytes and typed current terminal. Strictly extend source evidence so old `{state,rollbackEnvelope}` decodes unchanged and v3 evidence adds only its specified typed history fields. Do not reuse `rollbackEnvelope` as a permissive generic terminal boolean. Authenticated decode reconstructs history from embedded bytes and entries after plaintext cleanup.
- [ ] Move exact terminal classification before inventory compatibilityGate. Allow `.tmp`/`.transaction.json` only when it is the exact frozen abandoned preparation entry in active aborted/history evidence. For postinstall failed journal/receipt partials, certify them only as exact phase-owned retained Failed output under rolledBack evidence, with live restored to exact Original; never exempt canonical live paths. This requires a deliberate strict typed terminal evidence extension rather than suffix checks. Preserve old v1/v2 reader restrictions.
- [ ] Add committed+spent archive route in recovery.prepare and inventory.capture together: exact current committed UUID/normalized prepared binding, valid receipt/source proof/history, present valid canonical archive and current journal/export required. Selected recovery envelope retains the actual spent control snapshot. Corrupt/missing committed archive rejects; spent never becomes absence.
- [ ] Recheck seal's actual complete encoding against preflight bound, including exact control observation outside entries fingerprint. Authenticated cleanup and restore retain current policy and source selection only; historical data/partial output is captured evidence, not restored pending source. No new deletion authority.


#### Task 3 executable slices

**3A — existing installer and exact spent binding.** Extend the ordinary bootstrap internals with private phase adapters for load, validate, persist and journal/receipt commit. Keep the public ordinary methods calling their original adapters. The owned adapter must validate matching prepared digest/source state BEFORE each live move. Source-control replacement stays inside the existing storage ownership scope; do not call public `sourceState` while that scope is held.

- [ ] Write the source-spend test before the adapter change. At `afterSourceSpend`, decode the actual `.sealed-recovery-v1/intent.json`, require `.sourceSpent` with the prepared UUID and `SyncBootstrapOwnedManifestCodec.preparedSHA256`; assert live still matches Original and Staged has not moved.
- [ ] At each existing install/rollback boundary throw once, reopen with a new context, and require exact legal root placements. Freeze rolledBack's complete UUID entries only AFTER restored live equals Original and Failed is a legal durable CommitProgram prefix. Test altered Failed bytes, unplanned temp and replaced root rejection.
- [ ] Run `owned_core_test 'SyncBootstrapOwnedTransactionTests|SyncBootstrapTransactionTests|SyncAccountSourceStateTests'`, inspect RED/GREEN and preserve generic archive v1/missing-source v2 expectations.

**3B — real seal/cleanup/restore chain.** Add a memory-only test key store in `SyncBootstrapOwnedFixture.swift`:

```swift
final class OwnedFixtureKeys: SyncRecoveryVaultKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: Data] = [:]
    func insert(_ key: Data, for vaultID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard values[vaultID] == nil else { throw OwnedFixtureFailure.injected }
        values[vaultID] = key
    }
    func key(for vaultID: UUID) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[vaultID]
    }
    func remove(for vaultID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: vaultID)
    }
}
```

The first full committed-source test uses no mocked recovery or authority:

```swift
@Test func committedSpentCanCompleteAuthenticatedRecovery() throws {
    let f = try OwnedBootstrapFixture(); defer { f.remove() }
    let tx = try f.transaction()
    let prepared = try tx.prepare(f.input())
    try tx.install(prepared)
    let receipt = try tx.commit(prepared)
    #expect(receipt.transactionID == prepared.transactionID)
    #expect(FileManager.default.fileExists(atPath: f.source.archiveURL.path))
    let journal = FileSyncMutationJournal(url: f.source.paths.mutationJournalURL)
    let expected = try journal.pending()
    let keys = OwnedFixtureKeys()
    let vault = SyncRecoveryVault(directory: f.source.paths.vault, keychain: keys)
    let recovery = SyncAccountRecoveryTransaction(
        storage: f.source.storage, paths: f.source.paths, account: f.source.account,
        vault: vault, journal: journal)
    let now = Date.now
    let sealed = try recovery.seal(recovery.prepare(now: now), now: now)
    try recovery.cleanup(sealed)
    try recovery.restore(vaultID: sealed.vaultID, now: now)
    try recovery.consumeRestoredSelection(vaultID: sealed.vaultID, now: now)
    #expect(try FileSyncMutationJournal(url: f.source.paths.mutationJournalURL)
        .pending().map(\.mutationID) == expected.map(\.mutationID))
}
```

- [ ] Run `owned_core_test 'SyncBootstrapOwnedTransactionTests|SyncAccountRecoveryInventoryTests|SyncAccountRecoveryTransactionTests'`. Before changing the current spent admission, the committed capture test must fail for the actual invalidAuthority branch, not an unrelated path or fixture error.
- [ ] Capture current committed+spent control bytes and typed terminal/history. Require present valid canonical archive and ordinary journal recovery snapshot. Extend BOTH recovery.prepare and inventory.capture; changing only the former is insufficient.
- [ ] Add equivalent full-chain tests for nonempty pending/media/deletion data using `RecoveryInventoryFixture.makeMissingArchiveRollback(withMedia: true)`; construct the new owned input from the real pending snapshot and source fingerprint. Compare mutation payload/version and selected file bytes, not just IDs. Preserve the old UUID tree's inode/hash inventory until actual authenticated cleanup.
- [ ] Add the empty-before-root aborted terminal to full seal/restore and repeated predecessor retry coverage. Inserting its reserved-but-absent UUID afterward must fail inventory capture.
- [ ] For a successful commit, delete/corrupt the archive ONLY inside the isolated fixture; capture and sourceState must fail without replacing sourceSpent with absence.
- [ ] Retain expiry/wrong-key/wrong-account/incomplete-inventory rejection. Embedded history must suffice after plaintext cleanup; no fallback reads from now-removed trees.
- [ ] Verify full candidate envelope encoding against Task 1's bound after actual capture. Exceeding the bound is an implementation defect, not permission to increase the cap.
- [ ] Review source spending, rollback/reissue and committed/full-seal together; commit scoped changes as `feat: bind owned bootstrap recovery to exact terminal authority`.

### Task 4 / Checkpoint 4: Complete fault matrix, target membership and internal activation gate

**Files:** new/modified Core and test files above; explicit Xcode project source/test membership and actual App Core test harness references as used for completed helper units; integration report under `docs/superpowers/reports/2026-09-08-owned-bootstrap-integration-verification.md` only during execution.

- [ ] Add parameterized faults before/after active-next create/write/file sync/rename/namespace+account sync/readback; history create/prefix completion; each role output write/sync/rename; backup inspection; deletion validation; publication reuse parent sync/head durability; prepared selector; spent next/main/fsync; live→Displaced; Staged→live; journal attachment/frame/shard/checkpoint/segment/sync; receipt write/sync; rollback intent/Failed move/Original restore; abort selector and source reissue.
- [ ] For each cut assert exact before/after source bytes, phase and authority, retained names/content and terminal recovery outcome, not only an error count. No new UUID/history before preparing barrier; no live move before synchronized spent; after first failure no further preparation/commit output (only declared history repair, abort publication and rollback recovery); no source origin rewrite. Reopen fixtures must go through actual storage opening and current account validation. Include preparing-before-UUID-creation: exact empty abort output and history entries, exact continued UUID absence, seal/restore/retry, and rejection if that UUID later appears.
- [ ] Add repeated abort→abort→rollback→retry chains across new contexts, matching legacy migration and historical source generations; test cycles, duplicate UUIDs/hashes, wrong chain totals, unreferenced record, oldest metadata/file mutation, directory inode replacement, exact-prefix history corruption, and source-control-only change without entry fingerprint change.
- [ ] Add source mutation cuts for pending FIFO, mutation payload, selected attachment/deletion bytes, live archive absent/appeared/directory, root replacement, wrong account/session, expired selected recovery before handoff and matching durable origin after handoff. Existing restore/cleanup expiry semantics remain unchanged.
- [ ] Add exact Failed partial-output capture tests so the postinstall no-delete route cannot strand sealing. Same partial filename in live/undeclared role/extra UUID must reject. Committed archive removal/corruption must never pass sourceState as absent.
- [ ] Run targeted Swift tests listed in this plan, inspect every failure, then relevant existing suites once. Update exact Xcode target membership for every new source and test; run proportionate frozen App harness/root/unsigned platform validation consistent with completed helper reports. No live signing or service access.

```sh
owned_core_test SyncBootstrapOwnedTransactionTests
owned_core_test SyncBootstrapOwnedBudgetTests
owned_core_test 'ProjectArchiveSyncMapperTests|SyncMutationJournalTests|SyncMutationJournalSegmentTests|SyncMutationJournalFinalFixTests'
owned_core_test 'SyncBootstrapTransactionTests|SyncAccountSourceStateTests|SyncAccountRecoveryInventoryTests|SyncAccountRecoveryTransactionTests'
owned_core_test 'SyncBootstrapOutputPlannerTests|KnitNoteBackupPackagePlanTests|KnitNoteBackupServiceTests|SyncDeletionCaptureProgramTests|SyncDeletionLedgerTests|SyncPublicationEvidenceOutputProgramTests|SyncPublicationEvidenceDurabilityTests'
```

Commands are to run from the inspected worktree during implementation, not evidence that tests have run in this planning turn. Resolve the current repository's documented Xcode commands and destinations at execution; do not invent a simulator ID or imply a prior build proves the new branch.

- [ ] Independent review gate: actual helpers consumed with no hidden writer, strict durable issuer, iterative linear history, complete prospective budget, committed+spent full seal, unchanged ordinary helper/error ordering, no v3 reader without writer discipline, no public transport/factory activation. Report every boundary tested and explicit remaining App/transport/device/release gates. Only after this gate make the internal owned entry callable by its intended Core integration; App remains unactivated.

## State and authority acceptance table

| Selected state | Required authority and evidence | Permitted next action |
| --- | --- | --- |
| no selector, exact fresh/restored/legacy supported source | verified current owner, source/control/pending baseline, complete bound, absent chosen UUID | publish preparing only |
| old terminal + derivative next | exact authoritative old main and unchanged source/history | resynchronize/rebuild derivative; no output before preparing barrier |
| preparing | synchronized exact main, captured source/pending/control, declared allocation/history | execute once in current attempt; on failure/restart certify abort |
| preparing + changed baseline or unowned entry | no valid abort certification | preserve evidence and reject |
| abortedPreparation | exact frozen safe output union and unchanged source, completed history | reissue matching absent origin; full seal; retry with predecessor record |
| prepared, unspent | normalized prepared digest and exact initial source | spend then install, or existing rollback; never infer spent |
| prepared/installed/rollingBack, spent | exact transaction/digest/source match | existing install/recovery sequence; no second preparation |
| rolledBack, spent | exact original/live equality and terminal/history proof | reissue fresh absent generation when source was absent |
| committed, spent | exact receipt + transaction/prepared digest + present valid archive/journal/history | canonical handoff and full seal; never reuse absence |
| corrupt/mainless first selector or mismatched spent | no selector/authority substitution | fail closed; preserve files |


#### Task 4 executable slices and final validation

**4A — actual interruption matrix.** Faults must record what was issued and what existed; an error count alone is not an assertion. For each exact syscall boundary described in the task, assert: selected main/next bytes, whether UUID/history output exists, original live/pending/control bytes, permitted terminal phase, any retained partial path/length/hash, and whether full authenticated recovery succeeds or deliberately fails closed.

Use a child process for abrupt termination evidence, separately from ordinary thrown errors. Parent and child run the built test executable (no nested compiler). A dedicated worker test reads `KNITNOTE_OWNED_CRASH_CHILD` and `KNITNOTE_OWNED_CRASH_ROOT`; the parent orchestration test returns immediately when the child marker exists. The worker constructs real storage at that explicit empty test root and calls `Darwin._exit(86)` at the chosen real boundary. Add a test-only root-parameter fixture constructor that performs the same real storage initialization as the normal fixture.

Parent process launch body:

```swift
let child = Process()
child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
child.arguments = Array(CommandLine.arguments.dropFirst())
var environment = ProcessInfo.processInfo.environment
environment["KNITNOTE_OWNED_CRASH_CHILD"] = cutName
environment["KNITNOTE_OWNED_CRASH_ROOT"] = root.path
environment.removeValue(forKey: "KNITNOTE_RUN_CLOUDKIT_INTEGRATION")
child.environment = environment
try child.run()
child.waitUntilExit()
#expect(child.terminationStatus == 86)
```

Here `cutName: String` is the selected declared boundary and `root: URL` is the parent's freshly created isolated fixture root. Keep parent and worker in the same selected test suite so the reused runner filter includes the worker. All parent-spawning tests check the marker before spawning to prevent recursion. Bound the child to 60 seconds with terminate/kill fallback and mark timeout incomplete; after exit, openExistingAccount with a NEW storage instance at the SAME root (do not copy it, which changes inode evidence). Ensure unrelated tests cannot access this root.

- [ ] Test preparing-after-publication/before-root and partial Staged output first. Then include actual installed journal partial append, proof-shard publication, checkpoint replacement, receipt partial write, and rollback afterFailedMove. Restart through owned recovery BEFORE creating an ordinary journal instance over failed live files.
- [ ] Test valid ordinary journal reopen AFTER commit and AFTER exact rollback, comparing pending FIFO, file bytes, duplicate behavior and subsequent enqueue/ACK to the matching ordinary fixture.
- [ ] Add cap/cap+1 for per-file, Entry metadata, actual envelope/Base64/history and subsequent retry budget; no source/selector/tree changes when preflight rejects.
- [ ] Add tampered oldest history record/tree, duplicate UUID/hash, cycles, wrong totals, symlink/hardlink, directory replacement, extra namespace sibling, source-control-only change, selected attachment change and current context change. Each rejected attempt preserves evidence.

**4B — target membership and frozen validation.** Add new production files to both relevant existing Xcode source phases (KnitNote/KnitNoteWatch) using the same explicit membership pattern as the completed helper files. Add actual App Core harness symlinks for new files; the root harness's whole-Core link already follows additions. Keep new Core test helpers in the Swift package test target; add Xcode test membership only where that target already compiles the corresponding test module, never compile `@testable import KnitNoteCore` into a KnitNote-only test target.

- [ ] Improve the deferred publication wrong-id test while touching its integration tests: supply a valid other-ID immutable envelope with mutually consistent authority/version/record, then assert expected-path ID rejection. Do not claim this was a demonstrated production defect.
- [ ] Freeze Sources/Tests/KnitNote/PBX tree hashes after code review. Run the focused suites listed above, then full Core once for this journal/state-machine change using `env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --disable-xctest --no-parallel`.
- [ ] Verify the real App harness paths and Package manifests before using these serial commands; do not recreate a harness using guessed source subsets:

```sh
KNITNOTE_RUN_CLOUDKIT_INTEGRATION=0 CLANG_MODULE_CACHE_PATH=/tmp/knitnote-account-domain-jnjVrd/clang-cache python3 /tmp/task4-run-bounded.py 900 swift test --disable-xctest --disable-sandbox --cache-path /tmp/knitnote-account-domain-jnjVrd/cache --config-path /tmp/knitnote-account-domain-jnjVrd/config --security-path /tmp/knitnote-account-domain-jnjVrd/security --package-path /tmp/knitnote-account-domain-jnjVrd --no-parallel
KNITNOTE_RUN_CLOUDKIT_INTEGRATION=0 python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --package-path /tmp/knitnote-app-root-kbh3SM --no-parallel
python3 /tmp/task4-run-bounded.py 900 xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/owned-bootstrap-macos-derived CODE_SIGNING_ALLOWED=NO build-for-testing
python3 /tmp/task4-run-bounded.py 900 xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/owned-bootstrap-ios-derived CODE_SIGNING_ALLOWED=NO build
```

Run one command at a time and continue only after its exit/status is understood. Use fresh log suffixes for reruns; never overwrite earlier failure evidence. Verify build/version values stay 1.7.0 (13). A build is not physical-device acceptance.

- [ ] Check no App/CloudKit factory calls the internal entry and no public Boolean/source-path bypass was introduced. Review exact issuer reachability, source freeze, synchronous ownership, full history admission, clean journal reopen and authenticated cleanup.
- [ ] Record passed counts, failures/fixes, exit codes, full source SHA/tree hashes, log hashes and explicit remaining App/transport/device/release gates in `docs/superpowers/reports/2026-09-08-owned-bootstrap-integration-verification.md`. Do not create that report as if execution happened in this planning turn.
- [ ] Commit reviewed target/test/report changes locally as `test: verify owned bootstrap interruption and recovery boundaries`. Keep the internal route inactive for production callers pending its separate App/transport integration approval.

## Plan self-review and scope coverage

| Spec requirement | Implementing checkpoint |
| --- | --- |
| Preparing-first durable authority, no UUID/history output before barrier | Task 2A/2B and Task 4A |
| Complete helper programs, actual validation, no hidden deleting writer | Task 1D and Task 2B |
| Shared mapper order, clean v1–v5 journal semantics/trace | Task 1A/1C and Tasks 2/4 |
| Strict v3 phases, linear immutable predecessor history | Task 1B, Task 3 and Task 4A |
| No-root empty abort, exact absence, later-appearance rejection | Tasks 1B/2A/3B/4A |
| Original/Staged actual root identities, legal Failed prefix/freeze | Tasks 1/3A/4A |
| Actual prospective abort/rollback/commit/next-history affordability | Tasks 1B/1D/3B/4A |
| Exact spent/reissue, preserved historical context, committed full seal | Task 3 |
| Legacy wire/error behavior, no source invention, no new cleanup | All checkpoint regression gates |
| Actual Core/App/root/unsigned validation; inactive App/transport | Task 4B |

Self-review corrected path-base ambiguity by deferring to the spec's live-relative CommitProgram paths, retained actual root identities in the normalized digest, added clean v5 conflict persistence to the trace matrix, and closed the preparing-before-root empty-terminal case without granting new allocation or cleanup authority. Pure programs remain accounting only. Signatures above describe NEW internal APIs, not existing production capabilities. Runtime activation is not part of this plan.

This is an execution plan, not proof of implementation or release readiness. Continue from the recorded actual progress rather than repeating Task 1A. Task 1B's shared envelope allowance is now in progress; the full prospective budget and state codecs remain open. Automatic delegation was explicitly reopened by the user; use its existing heartbeat, not a duplicate, and obey any later cancellation immediately.
