# Account Source Inventory and Atomic Restore Handoff Implementation Plan

## Execution outcome — 2026-09-08

- [x] Task 1 implemented and independently reviewed at bd78c2a.
- [x] Task 2 implemented and independently reviewed at 820e887.
- [x] Task 3 implemented and independently reviewed at de86182.
- [x] Whole-plan review, sealed-session lifetime fix 42403d9 and scoped re-review completed.
- [x] Frozen Core/App/root tests and unsigned macOS/iOS builds passed on 42403d955ccdafade6a3470be3c3d1864dc2b93e.

The detailed checklist below is retained as the original execution specification, not a live progress ledger. Actual implementations, approved adjustments, evidence and deferred gates are reconciled in `../reports/2026-09-08-account-source-inventory-verification.md` and the three task reports under `.superpowers/sdd/2026-09-08-account-source-inventory/`. This scoped completion does not close nil-control rollback admission, abrupt-crash orphan handling, App integration, live-device or release gates.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Controller-approved scoped implementation plan. Main owns sequential dispatch, independent reviews and frozen validation; workers do not dispatch additional agents.

**Goal:** Make legitimate fresh, restored-pending, and single validated legacy rollback sources sealable, and consume replayComplete by atomically publishing durable absence provenance.

**Architecture:** Extend the existing inventory and authenticated transaction envelope while retaining the original archive wire. Use the existing transaction as sole vault-authentication/cleanup/restore owner and its storage ownership scope for exact source/control checks. The existing control helper performs source-backed replacement; a narrow legacy-selector bridge handles the first selection of a legitimate rollback with no main control.

**Tech Stack:** Swift 6, Foundation, CryptoKit, Darwin descriptor-relative filesystem operations, Swift Testing, existing native journal and encrypted recovery vault.

**Spec:** `docs/superpowers/specs/2026-09-08-account-source-provenance-design.md` in `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`.

## Global Constraints

- Inspected implementation baseline: `cc0ae51b7aaba5670864aa5f52a3dfdeb2752aa6`. The earlier broad draft's Task 2 is context; current source and controller rulings take precedence.
- Keep1.7.0(13), iOS18/macOS15/watchOS11, existing remote record/journal/publication formats, exact FIFO and attachment bytes, deletion/expiry policy, incoming128batches/16MiB, journal64MiB, file/canonical/batch100,000,000bytes, recovery aggregate cap and control8192bytes.
- No live account/Keychain/device/signing/schema/push/upload/submission or user-data cleanup. All implementation tests use isolated fixtures.
- No new recovery/storage owner, excluded sidecar, public provenance initializer or freshness boolean. No App activation, sourceSpent installer integration, transport descriptor/engine, v3 bootstrap writer/reader/history, or repeated-preparation repair in this unit.
- Existing generic storage open remains unchanged. Verified/existing open must continue retaining abandoned temporary sessions. Only authenticated exact inventory cleanup can remove those bytes.
- Unknown missing archive, corrupt/mainless control, contradictory canonical state, changed baseline, unsafe path or sourceSpent without its later owned-bootstrap resolver fails closed. Never mint authority from absence of bootstrap files.
- No ownership lock crosses await or recursively enters storage, bootstrap context callbacks, or App ownership callbacks. Caller still holds producer freeze; this unit does not own freezing.
- Use one compiler at a time. Worker runs only its focused RED/GREEN commands; main owns the separate frozen full-chain validation. Do not copy or edit external harness sources or run Xcode/fullchain in a worker.
- Preserve existing untracked controller scratch. Main owns SDD/report artifacts. Implement only each dispatched task, not later tasks.

## Controller rulings

### A. Accepted no-main legacy rollback compatibility bridge

Concrete source constraint: `SyncAccountRecoveryControlFile.replace` requires a main. `encode(.selectedRecovery, predecessorSHA256:)` requires a real 32-byte prior-main hash, and `encode(.absentSource, predecessorSHA256:nil)` permits only freshAllocation. A legitimate existing v2 rolledBack bootstrap currently has neither account main nor next. Calling these APIs with nil, an empty-data hash, or the rollback envelope hash as a supposed prior-main digest is invalid.

Accepted scoped extension: retain the existing initial **v1 Intent selector** for this one compatibility route, while its selected vault contains **recovery Envelope v2 + Inventory v2 + exact rollback evidence**. This is an explicitly reviewed exception to the spec's ordinary archive-only v1 route. It does not alter v1 Intent bytes or the frozen v2 control codec. Every subsequent phase remains a v1 transition owned by the existing authenticated transaction. Consumption then replaces the actual v1 replayComplete main with v2 absentSource using its real main hash. A later reseal replaces that source with normal v2 selectedRecovery.

Publication order: verify main=nil/next=nil and actual terminal rollback; capture exact entries/source witness; seal and synchronize the new vault; decode/authenticate those exact bytes; repeat exact root, entries, rollback and nil/nil control checks; create/write/sync v1 main using the existing initial writer; synchronize control/account and reread exact bytes. No cleanup starts before this barrier. A visible complete main after failed fsync is authenticated and resynchronized by retry. A torn first main remains fail-closed, preserving plaintext/vault; a next without main is never adopted. This retains the existing initial-publication interruption limit, rather than claiming automatic repair.

Alternative: extend the control wire with a distinct initial-selection source-witness form and a separately checked no-main publisher. That changes a just-validated codec and expands the crash matrix. It is unnecessary for this unit if the compatibility bridge is accepted. Main accepts the v1 selector bridge above; do not implement the alternate wire extension.

### B. Immutable source binding versus per-phase predecessor

Concrete source constraint: selectedRecovery's payload predecessor must equal its v2 envelope predecessor. Both represent the **immediate old main** and change at every phase transition. They cannot also equal the original source-control digest through cleanup/restore.

Keep the current edge semantics. Store immutable original source authority and exact original control observation in authenticated Envelope v2. The selected Intent's existing envelopeSHA256 and inventoryFingerprint bind that immutable witness on every phase. At the first sealed replacement, check the immediate predecessor against captured source main; at later phase transitions, hash the actual previous selected main and preserve the receipt/capture/envelope/inventory identities. Never compare later phase-edge hashes with the original source-control hash. This requires no control-codec change.

### C. Retained temporary sessions

Concrete source constraint: transaction `decode` currently requires every temporary descendant to belong to the capture's one current session. Verified/existing open now preserves old sessions, so that check can reject exact inventoried retained plaintext before it reaches authenticated cleanup.

For Envelope v2, allow only complete, sorted, safe-path entries under syntactically valid lowercase UUID session directories already present in the authenticated inventory. Require the capture's current session entry. Capture and decode reject malformed session names, missing parent directory proofs and reserved owner/control entries. During cleanup, old sessions and descendants remain ordinary exact physical inventory targets. Only the newly opened current empty session gets the existing explicitly checked retained-directory exception. No blanket temporary wildcard, ignoring missing captured sessions at sealed phase, or account-validation cleanup is permitted. Keep legacy v1 compatibility semantics unchanged.

## File map and shared contracts

Modify these existing production files only:

- `Sources/KnitNoteCore/CloudSync/SyncBootstrapTransaction.swift`: extract a pure terminal validator using its existing private Manifest/Envelope/source decoder; keep legacy terminal public-internal wrapper behavior.
- `Sources/KnitNoteCore/CloudSync/SyncAccountSourceState.swift`: source evidence/authority models and shared validation projections, not a writer/owner.
- `Sources/KnitNoteCore/CloudSync/SyncAccountRecoveryInventory.swift`: versioned authenticated source evidence, same bounded inventory capture/dependency rules.
- `Sources/KnitNoteCore/CloudSync/SyncAccountRecoveryTransaction.swift`: versioned prepared envelope, version-aware authenticated selectors, seal/phase adapter, atomic consume.
- `Sources/KnitNoteCore/CloudSync/SyncAccountRecoveryControl.swift`: extract the existing pure observation decoder for validating authenticated captured control bytes; no wire or authority relaxation. New-helper replacement must still reject opaque legacy derivatives.

Tests stay in `Tests/KnitNoteCoreTests/SyncAccountSourceStateTests.swift`, `SyncAccountRecoveryInventoryTests.swift`, `SyncAccountRecoveryTransactionTests.swift`, and `SyncBootstrapTransactionTests.swift`. No new source file or PBX membership change is needed. Do not expose previously private test key stores; transaction tests can reuse their same-file `TransactionKeys` and `TransactionSyncFault`.

### New internal value and reader interfaces

```swift
struct SyncAccountSourceEvidence: Codable, Equatable, Sendable {
    let state: SyncAccountSourceState
    let rollbackEnvelope: Data? // present iff origin is bootstrapRollback
}
enum SyncAccountRecoverySourceAuthority: Codable, Equatable, Sendable {
    case archive(relativePath: String, sha256: Data)
    case absent(SyncAccountSourceEvidence)
}
struct SyncBootstrapTerminalRecoveryEvidence: Equatable, Sendable {
    enum Phase: String, Sendable { case committed, rolledBack }
    let transactionID: UUID
    let activeRelativePath: String
    let activeEnvelope: Data
    let phase: Phase
    let sourceProof: SyncBootstrapSourceProof
    fileprivate init(transactionID: UUID, activeRelativePath: String,
        activeEnvelope: Data, phase: Phase, sourceProof: SyncBootstrapSourceProof)
}
extension SyncBootstrapTransaction {
    static func terminalRecoveryEvidence(account: SyncAccountIdentity,
        accountRoot: URL, liveRoot: URL, journalURL: URL,
        entries: [SyncAccountRecoveryInventory.Entry],
        read: (String) throws -> Data) throws -> SyncBootstrapTerminalRecoveryEvidence?
}
extension SyncAccountRecoveryInventory {
    // sourceAuthority == nil means precisely the old unversioned archive wire.
    var sourceAuthority: SyncAccountRecoverySourceAuthority? { get }
    static func capture(access: SyncAccountStorage.RecoveryAccess,
        paths: SyncAccountStorage.Paths, account: SyncAccountIdentity,
        journal: FileSyncMutationJournal, archiveURL: URL,
        control: SyncAccountControlObservation, maximumBytes: Int) throws -> Self
}
extension SyncAccountRecoveryTransaction {
    // Revalidates active absence; never manufactures it or consumes a selection.
    func sourceState(now: Date) throws -> SyncAccountSourceState?
}
extension SyncAccountRecoveryControlFile {
    // Same pure main/next rules used by observe(access:); no filesystem I/O.
    static func observation(mainBytes: Data?, nextBytes: Data?) throws
        -> SyncAccountControlObservation
}
```

The terminal reader itself parses the existing Manifest/Envelope and calls `validateSourceEvidence`; do not expose a second parser taking arbitrary pre-decoded source flags. It calls `read` only for exact inventory entries, verifies returned byte count/hash against entries, and validates fixed namespace, selected UUID/Original proof map and phase-specific current proofs. `validateTerminalRecovery` wraps it with the existing physical identity checking reader. For authenticated absent rollback decode, `read(activeRelativePath)` returns embedded rollbackEnvelope and every other read rejects; rolledBack validation requires no receipt read. Committed archive validation retains its existing receipt read and is not converted into an absent origin. Missing active or nonterminal evidence never returns missing-source authority.

Only rolledBack + `.missingArchive` can produce the no-control compatibility evidence. It must prove current working-set == Original and no archive/canonical/publication authority. Reject unknown bootstrap UUID/file siblings as today; do not add a history reader. The existing terminal reader checks file namespace membership; for this new absent-origin acceptance also require directory entries to lie in its exact known ancestor/current UUID tree, so empty unknown UUID directories do not become a permission to adopt lineage.

### Wire and frozen-envelope contract

1. Keep the original private inventory Payload as the legacy wire. Add a separate strict PayloadV2, containing `formatVersion:2`, existing fields and required `sourceAuthority`. All authority enum cases use explicit `kind` and exactly their own keys. Legacy decode rejects attempts to smuggle v2 fields through an unversioned payload; preserve legitimately encoded legacy bytes and fingerprint SHA256(canonical entries).
2. Inventory v2 fingerprint is SHA256(canonical `{entries,sourceAuthority}`). Absent authority binds root device/inode, account/hash, exact archive and actual configured journal URL, baseline, origin, and exact rollback bytes when required. Archive authority binds the exact archive entry path/hash; new captures in this unit use nil authority for ordinary no-control archives, so no migration is forced.
3. Introduce private transaction `SourceControlSnapshot: Codable` with `let mainBytes: Data?` and `let nextBytes: Data?`, explicitly encoding both keys (null for absence). Do not persist decoded `state` twice. Reconstruct with `SyncAccountRecoveryControlFile.observation(mainBytes:nextBytes:)`, extracted from the current observer; `observe(access:)` keeps all descriptor before/after checks and calls this same pure function. Only absentSource snapshots are valid nonempty source predecessors here, never selectedRecovery or sourceSpent. Existing strict-v2 and routing-only legacy derivative tests apply to both entry points.
4. Keep recovery Envelope v1 property shape/encoding unchanged. Add Envelope v2 with existing envelope fields plus required immutable `sourceControl` (exact captured main/next bytes, both may be absent only for the reviewed rollback bridge). Its inventory must be v2. Decode validates this route matrix: no-control legacy archive -> v1; no-control exact legacy rollback -> v2 + both controls absent; active absentSource -> v2 + matching decoded source main. No optional-field combination can turn unknown absence into a valid source.
5. Source state for compatibility rollback is a transaction-created capture witness, not published reusable authority. Choose authorityID/generation once during capture; bind them in the prepared bytes and authenticated inventory. Repeated capture may create a different unselected witness without modifying storage; only selected vault authentication permits cleanup. After restore, publish a new restoredSelection generation.
6. Original sourceControl is authenticated evidence, never current cleanup authority. At seal compare the exact captured observation. At every later authorization authenticate current selector/vault and validate its receipt, physical root and embedded payload. Validate rollback against original embedded entries/bytes even after cleanup; current remaining-entry checks separately validate what plaintext remains.

### Source projection and budget contract

Use `SyncAccountSourceBaseline.digest` exactly as implemented, with validated snapshot mutations, packet.files + deletionFiles, exported deletion ledger and ordered markers. It already recognizes the real journal family (`.checkpoint`, `.segment`, `.migrated`, `.proofs.00000000...00999999`) and does not recognize `.lock` or arbitrary suffixes. Do not widen it.

Capture reads `access.entries()`, control observation, native read-only journal snapshot, and deletion export in one ownership scope. Validate pending/deletion source membership before accepting any baseline. Portable proofs omit device/inode; authenticated inventory and source root retain them. Bind selected staging sources while allowing unrelated engine-state changes only before capture. Every byte of every owned root, including retained temporary data and unrelated staging/engine-state descendants, still joins inventory and must remain exact through seal/cleanup.

New metadata preflight must reserve Inventory v2 source fields, exact rollback envelope Base64, immutable control main/next Base64, packet/deletion Base64 and recovery Envelope v2's inventory Base64 expansion before selected attachment reads. Count outer envelope size, not just inventory's raw length. Do not materialize a potentially 100 MB bootstrap envelope merely to discover its encoded evidence will not fit: first use the inventoried byte count and conservative exact Base64 formula `4 * ((n + 2) / 3)` with checked arithmetic to reject impossible capacity; then bounded-read/parse it, complete exact metadata reservation, and only then read media. Final canonical encode still enforces the unchanged aggregate cap. Reserve all arrays/JSON punctuation before reads; no arbitrary fixed budget subtraction or limit relaxation.

## Preflight and command ownership

- [x] Main accepts A (authenticated v1 initial selector bridge), B (immutable source separate from phase edge), C (exact retained-session inventory). Costs: legacy selector can carry v2 vault payload, dual-version adapter tests required; snapshot bytes cost metadata capacity; retained sessions cost storage until authenticated cleanup.
- [ ] Executor reads current spec, foundation report and progress. Run only read-only preflight: `git status --short`, `git rev-parse HEAD`, and `git diff --stat`. Account for controller documentation commits after cc0ae51 and confirm production baseline before editing.
- [ ] Verify `/tmp/task4-run-bounded.py` exists and no other compiler/fullchain is running. Main assigns compiler ownership; process inspection does not grant permission to kill another process.
- [ ] Keep all new source-route fixtures on `paths.mutationJournalURL`. `RecoveryInventoryFixture.journal` intentionally uses `journal/pending.json`; leave legacy fixtures intact. A fresh source binds the runtime URL and must not be silently recertified around a different test journal.
- [ ] Use real vault/key fixtures, native journal, actual rollback producer and descriptor-owned storage. Baseline mutation and wrong-origin tests must compare all file bytes before/after rejection. Existing fixture archive bytes are intentionally arbitrary on some legacy routes; this unit must not turn corrupt archive into absence or gratuitously change archive parsing policy.

## Task 1: Pure terminal evidence and versioned source inventory

**Files:** BootstrapTransaction, SourceState, RecoveryInventory, RecoveryControl (pure decoder extraction) and their existing tests listed above. Controller-authorized narrow extension: SyncMutationJournal.swift and focused tests for an internal inventory-backed recovery snapshot using the existing native parser; ordinary recoverySnapshot remains unchanged. This is required because the existing native snapshot materializes selected media before inventory source metadata can be reserved. Transaction may receive only the envelope capacity plumbing needed for capture integration in Task 2.

Controller clarification: preserve every historical semantic/lineage/ACK/cleanup check, but substitute exact inventory proofs only for effective pending sources at the parser's existing physical validation boundary. Properly ACK-reclaimed historical media remains absent by design; requiring its physical presence would contradict existing authenticated reclamation. Selected payload reads and final ownership/inventory revalidation remain mandatory.

**Consumes:** Current `SyncAccountSourceState`, `SyncAccountControlObservation`, `SyncAccountSourceBaseline.digest`, RecoveryAccess, native journal snapshot, deletion RecoveryExport, private bootstrap Manifest/Envelope/validateSourceEvidence.

**Produces:** SourceEvidence/SourceAuthority, pure terminalRecoveryEvidence, inventory sourceAuthority and owned capture overload. Existing public capture delegates through a single `withRecoveryOwnership` and calls the overload; it must not nest `withRecoveryInventory` under storage ownership.

- [ ] Add direct evidence tests using the real v2 prepare/install/rollback setup already in `rolledBackReconstructionHasValidTerminalEvidenceButFullAccountSealingStillRequiresArchive`. Capture its entries and bounded active bytes, validate through the pure reader, then make every filesystem read closure throw except the embedded active bytes. The second validation must still pass using embedded entries. Mutate active bytes/hash/Original/current proof/account/journal and assert rejection.

```swift
let evidence = try #require(SyncBootstrapTransaction.terminalRecoveryEvidence(
    account: f.account, accountRoot: f.paths.accountRoot,
    liveRoot: f.paths.workingSet, journalURL: f.paths.mutationJournalURL,
    entries: entries, read: { path in
        try Data(contentsOf: f.paths.accountRoot.appendingPathComponent(path))
    }))
#expect(evidence.phase == .rolledBack)
let decoded = try SyncBootstrapTransaction.terminalRecoveryEvidence(
    account: f.account, accountRoot: f.paths.accountRoot,
    liveRoot: f.paths.workingSet, journalURL: f.paths.mutationJournalURL,
    entries: entries, read: { path in
        guard path == evidence.activeRelativePath else {
            throw SyncBootstrapError.corrupt
        }
        return evidence.activeEnvelope
    })
#expect(decoded == evidence)
```

- [ ] Add inventory tests named `legacyInventoryWireRemainsUnchanged`, `freshAllocationCapturesWithoutArchive`, `unknownMissingArchiveCannotCreateInventory`, `rollbackEvidenceMustMatchEmbeddedInventory`, `sourceV2RejectsMixedNullUnknownFields`, `sourceEvidenceOverheadRejectsBeforeSelectedMediaRead`, `absentSourceRejectsCanonicalAuthorityDirectories`, and `retainedTemporarySessionsAreExactInventoryEntries`. Preserve a literal real legacy encoded fixture generated before production change and compare byte-for-byte re-encoding with the old SHA256(entries).
- [ ] Run required RED (save stdout/stderr to `/tmp/account-source-inventory-task1-red.log`):

```sh
env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION python3 /tmp/task4-run-bounded.py 1200 arch -arm64 swift test --no-parallel --filter 'SyncAccountSourceStateTests|SyncAccountRecoveryInventoryTests|SyncBootstrapTransactionTests'
```

Expected: new behavioral failure or missing new reader/type symbols. Sandbox/compiler-cache failure is not RED; ask main to handle a precise authorized environment retry.

- [ ] Extract the terminal reader without changing bootstrap writers or existing phase/source wire. Refactor public capture into one scoped implementation. Its source choice is exhaustive: exact archive + no active source -> legacy; matching active absence + no archive -> v2; no control + valid missingArchive rolledBack -> compatibility v2; everything else rejects. Archive file/directory/descendants and the existing `isReconstructionAuthority` paths are contradictory to absence; share the exact pure predicate instead of inventing a second list.
- [ ] Implement strict inventory coding, rooted entry/dependency/deletion checks, original physical root binding, snapshot baseline comparison and metadata-first capacity reservation. Complete capture revalidates entries and exact control observation before returning. Decode invokes the same pure source proof checks against authenticated embedded bytes without reading cleanup-deleted plaintext.
- [ ] Add the deferred Minor tests in `SyncAccountSourceStateTests`: restoredSelection with/without deletion digest, bootstrapRollback and sourceSpent roundtrip; malformed hash/null/mixed-origin fields with recomputed outer checksum must reject; pending-marker permutation and content change alter baseline. Use two distinct real `SyncRecordVersion` values produced by the deletion fixture, not two identical markers.
- [ ] Run the same command for GREEN, logging `/tmp/account-source-inventory-task1-green.log`. Inspect exit code and test issues, review diff and `git diff --check`. Report exact SHA/diff, log paths and any capacity or purity gap. Main reviews this task before Task 2. Self-review and commit only exact scoped task files after focused GREEN; main independently reviews that commit before the next task. No push.

## Task 2: Authenticated selection adapter and exact source-backed seal

**Files:** RecoveryTransaction, RecoveryInventory (outer-budget integration), SourceStateTests, RecoveryTransactionTests. No new control helper authority.

**Consumes:** Task 1 inventory/terminal/source interfaces and existing observe/synchronize/replace. The initial rollback route uses the reviewed v1 writer bridge, not replace.

**Produces:** Strict Envelope v2, immutable captured control in Prepared, source-aware seal and version-aware authenticated selector/phase adapter; same public method signatures.

- [ ] Add `sourceControlOnlyMutationRejectsSeal`, `freshSourceSealAuthenticatesV2Inventory`, `legacyRollbackFirstSelectionUsesAuthenticatedBridge`, `selectedV2TransitionsPreserveCaptureWhileEdgesChange`, `legacyOpaqueDerivativeRequiresAuthenticatedOwner`, and `retainedOldSessionCannotDisappearBeforeCleanupStarted`. The source-only mutation test must leave `access.entries()` identical while changing main or next bytes; verify seal rejects before creating a new vault file.
- [ ] Run RED using the focused integrated command, logging `/tmp/account-source-inventory-task2-red.log`:

```sh
env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION python3 /tmp/task4-run-bounded.py 1200 arch -arm64 swift test --no-parallel --filter 'SyncAccountSourceStateTests|SyncAccountStorageTests|SyncAccountRecoveryInventoryTests|SyncAccountRecoveryTransactionTests|SyncBootstrapTransactionTests'
```

- [ ] Change prepare to capture root/inventory/control atomically in one synchronous storage ownership body. Encode route-specific envelope and run authenticated-payload structural/native replay validation before returning. Complete absent capture must retain exactly the source generation observed at prepare.

```swift
let captured = try storage.withRecoveryOwnership(paths: paths, account: account,
    maximumBytes: maximumBytes, createControl: true) { access in
    let observation = try controlFile.observe(access: access)
    let inventory = try SyncAccountRecoveryInventory.capture(access: access,
        paths: paths, account: account, journal: journal,
        archiveURL: paths.workingSet.appendingPathComponent("projects-v1.json"),
        control: observation, maximumBytes: maximumBytes)
    guard try controlFile.observe(access: access) == observation else {
        throw Error.changedInventory
    }
    return (inventory, observation, try identity(access.accountDescriptor))
}
```

Here `controlFile` is a private property initialized with the transaction's existing `synchronize` closure. Inside the same scope, before inventory media capture, choose the capture UUID and encode the route-specific outer envelope metadata with `inventory: Data()` and the known exact control/root/session fields. Use a 32-byte placeholder solely for measuring the fixed-length packetSHA256 field, replacing it with the actual digest before constructing Prepared. For v2, let `overhead` be that encoded byte count; the available raw inventory budget is `3 * ((maximumBytes - overhead) / 4)`, using checked arithmetic and rejecting negative remainder. The empty inventory's quoted empty Base64 value is already included in overhead; adding inventory replaces its empty contents with exactly `4 * ((n + 2) / 3)` bytes. Feed that smaller maximumBytes to the scoped inventory capture, so its existing packet/deletion reservation includes the outer Base64 bound before media reads. Read/control/physical entry checks remain under the same ownership scope; the example shows the scoped core rather than an additional unlocked capture. No public caller-provided source flag is added. Preserve the exact legacy envelope encoding and current maximum; any shared tighter preflight must preserve all legacy success cases that actually fit the final envelope.

- [ ] Replace `Authorized.intent`-only state with an authenticated value also carrying its exact `SyncAccountControlObservation`. `authorize` observes main, distinguishes legacySelection/selectedRecovery from absentSource/sourceSpent, and authenticates only actual selected vaults. Source/spent returns no Selection; callers requiring selection still reject, and absence APIs branch explicitly. Validate Intent account/root/archive/journal/capture/envelope/packet/fingerprint and root identity as today; Envelope v2 additionally validates immutable witness. `lifecycleSnapshot` never reports active/spent source as a selected phase.
- [ ] Adapt transition/barrier without decoding every main as raw Intent. A legacy selected main retains the current legacy barrier and transition. A v2 selected main authenticates/synchronizes current vault and exact observation, then uses replace with a next Intent preserving all immutable fields except phase. Compute `.selectedRecovery(nextIntent, predecessorSHA256: SHA256(currentMain))` at each edge. The replace validation closure checks exact phase-appropriate remaining/restored inventory and selected vault evidence; it cannot call public mutex-taking transaction methods.
- [ ] Preserve the opaque-legacy derivative routing rule. When a legitimate v1 selected main has complete/torn non-v2 next, authenticate and synchronize main/vault, validate phase-appropriate source state, then invoke the old authenticated transition to the required phase (or same replayComplete phase for normalization). Refresh authorization/observation afterward. Only that old transition rebuilds opaque next. `replace` itself must still reject this observation before any sync/source callback/write, and invalid/expired vault leaves all bytes unchanged.
- [ ] Implement seal route matrix and barriers: exact prepared observation/root/entries first, synchronized vault next, repeated source/control checks, then v1 initial write for legacy archive/approved no-control rollback or v2 replace for active absentSource. A stale Prepared cannot discard a new derivative; recapture may snapshot a valid v2 derivative alongside the unchanged authoritative absent main, then the existing helper can replace it after fresh source/vault checks. Derivative bytes themselves never grant cleanup authority.
- [ ] Add visible-initial-main/initial-fsync failure tests and failed replacement tests with actual vault authenticity. A partial first main, mainless next, torn v2 next, wrong predecessor or changed root remains fail-closed and byte-preserving. A fully valid surviving v2 derivative may retry under the authenticated current owner; do not broaden the observer to accept a torn v2 next.
- [ ] Validate exact old temporary session capture/decode/cleanup: reopen verified/existing with retained old files, capture includes all, seal includes all, deleting or modifying one before cleanupStarted rejects; legitimate cleanup removes exact captured descendants, then restore contains only selected pending/deletion files/current session. Preserve legacy-session regression behavior separately.
- [ ] Run integrated GREEN, logging `/tmp/account-source-inventory-task2-green.log`; review diff/check whitespace and report. No App/fullchain/Xcode work. Main's review gate must confirm no v1 byte change, no opaque derivative bypass, immutable-versus-edge binding and exact retained-session semantics before Task 3.

## Task 3: Atomic restore consumption and real roundtrip fault evidence

**Files:** RecoveryTransaction, RecoveryInventory (shared revalidation only), RecoveryTransactionTests, SourceStateTests. Reuse control replace unchanged.

**Consumes:** Task 2 authenticated selection/phase adapter, original receipt and pending restore verifier, Task 1 source snapshot/baseline, current root identity, exact control helper.

**Produces:** sourceState(now:), source-preserving selection-absence barrier, atomic consume semantics, and full fresh/rollback/restored-pending seal-cleanup-restore-reseal proof. Still no bootstrap install/spend or App readiness.

- [ ] Rename the existing rollback integration gate test to `rolledBackReconstructionFullSealRestoreAndResealPreservePending`; retain its real prepareReconstruction/install/rollback setup. Replace only the old expected unsafeBinding tail with the complete flow:

```swift
let receipt = try recovery.seal(recovery.prepare(now: .now), now: .now)
try recovery.cleanup(receipt)
try recovery.restore(vaultID: receipt.vaultID, now: .now)
#expect(try recovery.consumeRestoredSelection(vaultID: receipt.vaultID, now: .now))
let source = try #require(recovery.sourceState(now: .now))
#expect(try recovery.lifecycleSnapshot(now: .now) == nil)
#expect(try journal.pending() == pending)
#expect(!FileManager.default.fileExists(atPath: f.archiveURL.path))
if case .restoredSelection(let vaultID, let captureID, _, _, _) = source.origin {
    #expect(vaultID == receipt.vaultID)
    #expect(captureID == receipt.captureID)
} else { Issue.record("Consumed restore did not create exact restored origin") }
let next = try recovery.seal(recovery.prepare(now: .now), now: .now)
#expect(next.captureID != receipt.captureID)
try recovery.cleanup(next)
try recovery.restore(vaultID: next.vaultID, now: .now)
#expect(try recovery.consumeRestoredSelection(vaultID: next.vaultID, now: .now))
#expect(try journal.pending() == pending)
```

- [ ] Add `consumedPendingCanResealBeforeAnyBootstrapPrepare`, `freshEmptySourceFullRoundtrip`, `rollbackDecodeWorksAfterBootstrapPlaintextCleanup`, `consumptionRetryMatchesOnlyRecordedOrigin`, `expiryBeforeHandoffRejectsAndExpiryAfterHandoffDoesNotRevokeSource`, `atomicHandoffNeverLeavesAuthorityAbsent`, and `sourceBaselineChangeDoesNotRecertify`. Use explicit finite dates and actual vault lifetime instead of clock sleeps. Include media/deletion/marker variants using existing native ledger fixtures and byte-for-byte selected dependency assertions.
- [ ] Run integrated RED with the Task 2 command, logging `/tmp/account-source-inventory-task3-red.log`. Record the concrete old unlink/no-archive failure; do not count a scaffolding compiler error as sole evidence for the roundtrip regression.
- [ ] Implement consume in the current transaction mutex and one ownership scope. Branch on observation first. For selectedRecovery/legacySelection: authenticate exact requested vault at now; require replayComplete; normalize opaque legacy derivative only through the authenticated old transition; validate restored files and replay; reestablish durability of restored files/journal parent/directories/account and selected main/vault; revalidate; compute current root + actual native snapshot/deletion export/selected files baseline; construct a new source state with restoredSelection(vaultID,captureID,envelopeSHA256,packetSHA256,deletionSHA256); replace actual main atomically. Derive deletionSHA256 from exact authenticated selected deletion ledger bytes, nil iff none. The replace validation closure repeats exact restored state/source/control checks without taking a second ownership lock.
- [ ] An already-published matching restoredSelection source is durable current-local authority: revalidate current source baseline/root and synchronize exact control, then return true without accessing the old vault. Its capture/envelope/packet/deletion identity is the stored immutable origin; never rewrite those values from a different selection. With the unchanged public vaultID-only API, callers cannot request a capture separately: validate the entire recorded origin and match the requested vaultID. A stronger explicit expected-capture API belongs to later caller integration, not an invented success condition here.
- [ ] An absent source with different origin/vault rejects consumption; selected wrong vault/phase rejects; sourceSpent rejects; missing both controls synchronizes and returns false, which remains no replay/source proof. Matching source baseline change rejects before true, including selected attachment/deletion/journal/working-set bytes. A durable handoff that later expires only makes the old vault unreplayable, not local source invalid. A newly selected capture prevents old-vault consumption from succeeding.
- [ ] Implement `sourceState(now:)` as read/revalidate only: for active absentSource capture/verify actual source under ownership and synchronize its exact main; return state. For selected/spent/no control return nil, preserving typed routing. It does not mint rollback compatibility authority. `synchronizeSelectionAbsence(now:)` accepts/synchronizes nil controls or structurally bound active/spent control without overwriting it, rejects selected recovery, and does not claim replay or canonical readiness. Consumers still need sourceState/owned bootstrap routes for actual data authority.
- [ ] Replace unlink-specific tests (`consumedIntentAbsenceMustBeSynchronizedBeforeLaterCapture` and assertions expecting no main after true) with atomic handoff cuts. Preserve cleanup unlink tests and their original guarantees. Inject faults at next-write completion/file fsync, control fsync, pre-rename source validation, rename, post-rename control/account fsync, and final readback. Reuse descriptor-path-aware sync hooks; if deterministic write/rename fault injection is needed, add a narrow internal defaulted syscall/boundary hook to the existing helper, not a second writer. No broad crash simulator or new owner.
- [ ] For every cut reopen with old storage released and verify: either exact authenticated replayComplete remains authoritative, or exact matching restored absentSource resynchronizes and returns true; invalid/torn v2 derivative can instead fail closed with bytes preserved. There is never a successful unlink-to-nothing window. A complete visible replacement after failed parent sync must be resynchronized before success; next alone cannot produce success. Verify wrong account/root/receipt, replacement physical inode, stale next, missing key/expired pre-handoff vault, unknown canonical/temp/bootstrap files, pending reorder/media change and marker content/order all reject without data deletion.
- [ ] Run integrated GREEN and save `/tmp/account-source-inventory-task3-green.log`. Inspect warnings/issues, exact test summary/exit and diff checks. Main reviews the complete frozen source and owns any required App harness/fullchain runs. Worker reports scope, real roundtrip evidence, fail-closed cuts and retained future gates, then stops without triggering another compiler.

## Self-review and completion boundaries

- [ ] Check all source authority cases, no-main compatibility first selection, every selected phase, restored handoff and idempotent repeated handoff against the spec. Verify source state cannot authorize cleanup independently of the current selected authenticated vault.
- [ ] Confirm ordinary legacy archive inventory/envelope/Intent bytes unchanged; legacy opaque next remains old-owner-only; selected v2 phase predecessors change while immutable authenticated source witness stays constant.
- [ ] Confirm actual rollback bytes are embedded and validated after plaintext removal; no filesystem existence shortcut or second permissive bootstrap parser; capacity reservations cover all Base64 layers before selected media reads.
- [ ] Confirm sourceSpent is a blocking future-owned-bootstrap state, no consume method revives it, and archive loss/corruption cannot invoke rollback compatibility while conflicting control exists.
- [ ] Confirm exact retained temporary roots/descendants join capture and cleanup, and only current empty reopened session uses the narrow physical-directory exception.
- [ ] Run a text scan for unresolved placeholders and reconcile all named interfaces with the implemented files before calling the formal plan executable. The three rulings above are binding; new ambiguities must be reported to main, not guessed.

Deferred separately: `/tmp/bootstrap-predecessor-lineage-design-20260908.md` requires v3 preparing-first allocation/history/abortedPreparation with bounded output reservations before repeated owned bootstrap retries. This unit reads only existing v1/v2 terminal evidence and does not loosen unknown UUID/temp-file gates to pre-implement lineage. Later work also owns sourceSpent issuance/reissue, prepared digest capabilities, no-precanonical-writer App gates, account switching/session freeze integration, typed transport namespace descriptors and live cloud/device acceptance. Passing this unit is full source inventory/seal/restore-handoff evidence, not full sync or release acceptance.
