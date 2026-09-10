# Legacy Import Native Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a complete, isolated-owner V4 legacy import through the existing native bootstrap transaction, including retained backup, recovery and committed handoff, without enabling App startup.

**Architecture:** Keep ordinary V3 wire semantics unchanged and dispatch owned V3/V4 through a variant-preserving manifest layer. A native isolated source owner issues scoped read and final-drain capabilities; observations and consent alone remain insufficient. Upgrade every recovery consumer and capacity projection before admitting V4 preparing.

**Tech Stack:** Swift 6, Swift Testing, Foundation, CryptoKit, existing descriptor-relative Darwin I/O and backup/CloudSync Core; no new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-10-legacy-import-durable-transaction-design.md`, including the approved section 8 compatibility revision; read its parent `2026-09-09-legacy-local-import-safety-design.md` before execution.

## Global Constraints

- 版本維持 1.7.0 (13)；最低 iOS 18、macOS 15、watchOS 11。
- 無新增套件、帳號、網路傳輸、CloudKit schema、Keychain 或真實使用者資料操作。
- shipping、screenshot、Watch 與 Share 啟動不接入新匯入能力。
- 原始內容、成功備份及復原證據不因取消、失敗或空間不足而刪除。
- caller Boolean、URL、帳號 hash、UUID、可解碼紀錄都不是來源／安裝／清理權限。
- 本機提交與雲端同步是不同狀態；不宣稱已推送、上傳、送審或發布。
- Source projection 1,000,000 bytes; directory inventory 4,000,000 bytes; native recovery 100,000,000 bytes. Do not increase these limits.
- Unsupported historical development binaries must not directly reopen V4 account storage. Maintained admission paths must reject unknown/unsupported evidence before mutation. Actual shipped-version upgrade validation remains a later release gate.
- Use existing worktree `docs/cross-device-sync-design`; inspected baseline `a13ce35c81bd3afa74538c9f71412c12cfe3fe3e`. Preserve unrelated untracked files. No merge, push, signing, export, upload or submission.

---

## Execution and evidence

Execute sequentially in the current session with executing-plans; no new parallel compiler lanes. Each task has its own RED/GREEN and scoped review checkpoint. Intermediate commits must leave shipping call sites disabled, even when native reader support is incomplete. A partial task is not the completed integration.

Run focused tests with the existing bounded runner after reading it, using a fresh log per run:

```sh
env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION CLANG_MODULE_CACHE_PATH=/tmp/knitnote-account-domain-jnjVrd/clang-cache python3 /tmp/knitnote-legacy-final-iHUGGh/run-bounded.py 900 arch -arm64 swift test --disable-xctest --disable-sandbox --cache-path /tmp/knitnote-account-domain-jnjVrd/cache --config-path /tmp/knitnote-account-domain-jnjVrd/config --security-path /tmp/knitnote-account-domain-jnjVrd/security --no-parallel --filter 'LegacyImport'
```

Replace only the filter per task below. Verify these temporary paths still exist; if absent, allocate a new temporary test runtime rather than assuming cached evidence. Request narrowly scoped execution approval if local sockets/locks require it. Record exit status, exact test functions/arguments, elapsed time and tested SHA; a timeout is not a pass. Before each commit run `git diff --check` and stage only that task's actual changed files.

## File and interface map

New Core files, each with one responsibility:

- `Sources/KnitNoteCore/CloudSync/SyncBootstrapOwnedManifestVariant.swift`: owned discriminated wrapper and shared structural validation policy.
- `Sources/KnitNoteCore/CloudSync/SyncBootstrapLegacyImportManifest.swift`: strict V4 wire and binding, not source authority.
- `Sources/KnitNoteCore/CloudSync/LegacyImportSourceOwner.swift`: closed isolated-owner lifecycle and nonconstructible source capabilities; no arbitrary-root adoption API.
- `Sources/KnitNoteCore/CloudSync/LegacyImportNativeCoordinator.swift`: preparation, current proposal, final drain, native install/commit and actual-operation join.

Existing native transaction, backup service, roles, budget, history, storage, inventory, recovery transaction, journal snapshot and handoff remain their respective owners. Do not create a second rename/install executor. Do not broadly refactor App session files in this plan.

New test suites: `SyncBootstrapLegacyImportManifestTests`, `LegacyImportSourceOwnerTests`, `SyncBootstrapLegacyImportBudgetTests`, `SyncBootstrapLegacyImportRecoveryTests`, `LegacyImportNativeCoordinatorTests`, `SyncBootstrapLegacyImportCrashTests`, all under `Tests/KnitNoteCoreTests/`. Keep existing V3 tests intact.

### Task 1: Maintained admission and strict variant foundations

**Files:** Create the two manifest files above and `Tests/KnitNoteCoreTests/SyncBootstrapLegacyImportManifestTests.swift`. Modify `SyncBootstrapOwnedManifest.swift`, `SyncBootstrapTransaction.swift`, `SyncAccountStorage.swift` under the Core CloudSync directory; extend `Tests/KnitNoteCoreTests/SyncAccountStorageTests.swift`.

**Interfaces:** Introduce `BootstrapManifestV4` with the common V3 root properties plus `legacyImport: LegacyImportBinding`; `LegacyImportBinding` contains exactly the seven fields in spec section 4 (including version). `SyncBootstrapOwnedManifest` has cases `.ordinary(BootstrapManifestV3)` and `.legacyImport(BootstrapManifestV4)`. It exposes common read-only properties `id`, `context`, `livePath`, `journalPath`, `sourceProof`, `original`, `historyHead`, `body`, and `transactionRelativePath`, plus these methods:

```swift
static func decodeEnvelope(_ bytes: Data, maximumBytes: Int = 100_000_000) throws -> Self
func encoded(maximumBytes: Int = 100_000_000) throws -> Data
func replacingBody(_ body: BootstrapManifestV3.Body) throws -> Self
func normalizedPreparedDigest() throws -> Data
func validateReceipt(_ receipt: SyncBootstrapReceipt) throws
```

- [ ] Add the storage regression before changing admission. In existing `SyncAccountStorageTests`, reuse its `Fixture` and identity helpers; write unknown selector bytes below the actual account namespace and abandoned temporary bytes, close the owner, then call legacy `open`. Snapshot regular-file bytes and directory names before/after. Test live-present/live-missing, active/active-next, no/empty/nonempty control, unknown version and malformed envelope. A representative existing-fixture assertion is:

```swift
#expect(throws: (any Error).self) { try storage.open(identity: account) }
#expect(try Data(contentsOf: temporaryFile) == bytes)
```

  Add a test-local `snapshot(_ root: URL) throws -> [String: Data?]` that enumerates all directory names and regular-file bytes without following links; include an entry for every directory with nil value. Assert entire snapshot equality, not only this sentinel. Run filter `SyncAccountStorageTests`; confirm the new unknown-selector test fails because legacy open mutates or succeeds.
- [ ] Add strict V4 and receipt tests using the existing V3 manifest test fixture's full root/phase dictionaries, copied into the new suite as explicit V4 fixtures. Set version 4, operation `legacyImport`, and the required binding. Missing/null/unknown fields, 31/33-byte digest, differing source/backup digest, wrong transaction/account, receipt version 1/2 with V4 and receipt 3 with V3 must reject. Confirm V3 decoder still rejects V4. Run filter `SyncBootstrapLegacyImportManifestTests` and capture RED.
- [ ] Implement strict version dispatch; never use `version != 3` as a legacy fallback:

```swift
switch version {
case 3: return .ordinary(try BootstrapManifestV3.decodeEnvelope(bytes, maximumBytes: maximumBytes))
case 4: return .legacyImport(try BootstrapManifestV4.decodeEnvelope(bytes, maximumBytes: maximumBytes))
default: throw SyncBootstrapError.corrupt
}
```

  Extract reusable structural validators taking an explicit allowed-role policy. Keep V3's accepted roles restricted to the original five even if its shared body role representation gains LegacyBackup. Do not validate V4 by constructing/encoding a V3 envelope. `replacingBody` reconstructs the same case with unchanged context, source, history and binding. Encode/hash complete V4 payload for every digest. Receipt gets an internal discriminated format, not a caller-writable optional digest. Keep its existing ordinary initializer and legacy wire behavior unchanged; add internal `init(transactionID:accountIDHash:sourceProof:legacyImportSHA256:)` for version 3, with exact strict root/tagged source validation.
- [ ] Before account lock/scaffold/session creation in legacy open, perform bounded, descriptor-relative admission of existing bootstrap evidence. Reject unsupported owned selectors and malformed/unknown evidence; legacy open need not recover V4. Do not synthesize recovery control to suppress cleanup. Preserve old no-bootstrap behavior and verified generation checks. Repeat both focused suites and existing `SyncBootstrapOwnedManifestTests`; commit as `feat: define strict legacy import wire and guarded admission` only after GREEN.

### Task 2: Native isolated source ownership and verified backup reads

**Files:** Create `LegacyImportSourceOwner.swift` and `Tests/KnitNoteCoreTests/LegacyImportSourceOwnerTests.swift`; modify `Sources/KnitNoteCore/Backup/KnitNoteBackupService.swift`. No App factory edits.

**Interfaces:** `@MainActor final class LegacyImportSourceOwner` has a private initializer and no public URL adoption method. Its only initial issuer is a DEBUG-only factory `static func makeIsolatedFixture(archive: ProjectArchive, files: [String: Data]) throws -> LegacyImportSourceOwner`, which creates its own fresh temporary root and owns all writers. It does not accept an existing root. Production release builds have no factory. The owner exposes `prepare() async throws -> LegacyImportSourcePreparation`, `stopAndDrain() async`, and `invalidate()`. `LegacyImportSourcePreparation` has fileprivate construction, native owner identity/generation, backup observation and preparation UUID. Source read operations remain owner-validated and do not grant target writes.

Add backup-service read-only APIs `legacyImportManifestSHA256(_ observation: LegacyImportBackupObservation) throws -> Data` and `readLegacyImportPackageFile(_ path: String, observation: LegacyImportBackupObservation, maximumBytes: Int) throws -> Data`. These use its existing private package observation and descriptor-safe reads; do not expose or make the observation's initializer public. Native capability validation calls full `revalidateLegacyImportBackup` before and after reading, checks bounded file proof and exact identity, and binds work/live/package roots.

The preparation itself is a non-actor final class with a private lock-protected owner-state reference, not a MainActor object invoked synchronously from the native transaction. Define synchronous `validateForPreparation() throws`, `validateForInstall() throws`, `readBackupFile(_ path: String, maximumBytes: Int) throws -> Data`, and `exportBackup() throws -> SyncExportPackage`. The owner updates this same state on invalidation and final drain; install validation additionally requires closed writer admission and completed drain. Never block the MainActor waiting for an actor hop or claim Sendable without synchronizing every mutable field. Preparation reads cannot issue target authority. Export reads the validated backup payload, not the still-editable legacy live root. Add `exportLegacyImportBackup(_ observation: LegacyImportBackupObservation, deviceID: String) throws -> SyncExportPackage` inside the backup service, where the verified payload root and decoded archive are available. The isolated owner supplies its own device ID and clean-source provenance; unknown account/Watch metadata rejects rather than being stripped and relabeled as clean.

- [ ] Write source-owner tests that obtain two independently created native owners with identical content and prove their preparation capabilities are not interchangeable. Exercise mutation after backup, same-content inode replacement, invalidation and A→B→A generation, stop during a blocked backup, cancellation, and repeated prepare. After failure assert source and successful backup still exist with their prior bytes. Use existing source observation fixture archive/media builders, not real store URLs. Run `LegacyImportSourceOwnerTests` and capture RED.
- [ ] Implement the closed owner state machine. Own a retained operation Task before any await; stop invalidates synchronously and joins that exact task. All fixture writes must pass owner admission, and the final drain must close writer admission before joining. Native validation requires identity plus generation, not merely digest equality:

```swift
guard preparation.ownerID == ownerID,
      preparation.generation == generation,
      !invalidated else { throw KnitNoteBackupError.accessDenied }
try service.revalidateLegacyImportBackup(preparation.observation)
```

  Define these fields privately/fileprivately in this file; none are caller-supplied assertions. Add DEBUG-only test mutation/fault hooks that act on the owner's own created root. They cannot adopt external roots or issue production capabilities. Backup happens while the source is still writable; final drain is separate from preparation. Never infer clean Watch/account state from content projection: the isolated factory constructs a clean source, and rejected fixture metadata is tested explicitly.
- [ ] Validate actual backup manifest bytes, payload entries and identities through the backup service APIs. Keep raw paths out of the durable binding. Run filter `LegacyImportSourceOwnerTests|LegacyImportSourceObservationTests|LegacyImportPreparationCoordinatorTests`; commit as `feat: issue isolated native legacy source preparations` after GREEN. Confirm no shipping/screenshot/Watch/Share call sites.

### Task 3: LegacyBackup output role and complete lifetime budget

**Files:** Modify `SyncBootstrapOutputPlanner.swift`, `SyncBootstrapOwnedProgram.swift`, `SyncBootstrapRecoveryBudget.swift`, the manifest variant validators, and `SyncBootstrapOwnedTransaction.swift`; create `Tests/KnitNoteCoreTests/SyncBootstrapLegacyImportBudgetTests.swift`.

**Interfaces:** Add `.legacyBackup = "LegacyBackup"` to native output roles. Extend the owned program source with `case legacyBackup(path: String, proof: SyncBootstrapOutputProof)` resolved only through Task 2's capability. Add internal `planLegacyImport(_ input: SyncBootstrapOwnedInput, source: LegacyImportSourcePreparation) throws -> SyncBootstrapOwnedProgram` and `prepareLegacyImport(_ input: SyncBootstrapOwnedInput, source: LegacyImportSourcePreparation) throws -> SyncBootstrapPreparation`. They initially reject until Task 4 reader integration is complete; a test-only planner exercise must not persist V4 early. Ordinary `plan`/`prepare` remain V3.

- [ ] Add budget tests with a real Task 2 backup: reserve every package directory/file, temporary output, backup manifest, receipt 3, V4 binding, predecessor and retry. For each computed boundary use the same program at inclusive limit and one byte below its required size; snapshot destination before the rejected call. Test a case where only committed or retry projection crosses the limit. Run `SyncBootstrapLegacyImportBudgetTests` and capture RED.
- [ ] Extend builder sources and role allocation. Establish LegacyBackup and copy actual verified package bytes into it through native output actions. Source bindings cannot resolve arbitrary URLs. Include this role in immutable output digest, aborted frozen entries and retained history. Share role validation with explicit V3/V4 policies:

```swift
let ordinaryRoles: Set<SyncBootstrapOutputRole> = [
    .original, .staged, .attachments, .validationOriginal, .validationMerged
]
let legacyRoles = ordinaryRoles.union([.legacyBackup])
```

  For every existing Role.allCases use determine whether it means structural enumeration or an accepted-format allowlist; replace the latter with the selected policy. Add a manifest variant parameter to budget composition and carry it through postinstall, abort, rollback, committed, history and next-retry construction. Count actual canonical encoding and base64 expansion; no fixed guessed allowance for binding or backup.
- [ ] Merge imported records into the local candidate stream alongside destination local records, leaving actual remote and destination pending snapshots distinct. Export verified legacy content with existing `ProjectArchiveSyncMapper.exportFrozenSource`; revalidate owner and backup around all reads. Preserve destination sourceArchive and sourceProof. Do not premerge away conflicts, deletion markers or upload intent. Duplicate attachment version ID with unequal proof rejects before output.
- [ ] Run `SyncBootstrapLegacyImportBudgetTests|SyncBootstrapOwnedBudgetTests|SyncBootstrapOutputPlannerTests`; verify ordinary V3 allocations and byte caps still hold. Commit as `feat: account for retained legacy backup across native lifetimes` after GREEN.

### Task 4: Upgrade the entire native read/recovery closure

**Files:** Modify Core CloudSync `SyncBootstrapOwnedTransaction.swift`, `SyncBootstrapHistory.swift`, `SyncAccountRecoveryInventory.swift`, `SyncAccountRecoveryTransaction.swift`, `SyncAccountStorage.swift`, `SyncMutationJournal.swift`, `SyncBootstrapOwnedHandoff.swift`; create `Tests/KnitNoteCoreTests/SyncBootstrapLegacyImportRecoveryTests.swift`.

**Interfaces:** Replace V3-only stored manifest and function parameters at these seams with `SyncBootstrapOwnedManifest`: InstallOwner, PreparationOwner, terminal evidence, history validation, prepared derivative, rollbackUnspent, validateSource, validateCommitPrefix, owned-original journal snapshot and owned handoff. Pure body/proof/program structs may remain shared V3-named types. Existing public account open/recovery APIs keep their signatures.

- [ ] Add tests for each maintained entry with V4 selected in every supported phase, not just decoder tests. Cover mixed V1/V2/V3/V4 history, missing live, archive and missingArchive source, actual authenticated archive capture with `OwnedBootstrapTestKeys`, rollback/retry and committed handoff. Wrong binding/backup/receipt/history must throw and preserve the damaged snapshot. Run `SyncBootstrapLegacyImportRecoveryTests` for RED.
- [ ] Replace all owned version dispatches explicitly: selector format, recover, readTerminal/history loop, inventory, missing-live preservation and account recovery auth-format selection. V1/2 use existing legacy handling; V3/4 use owned handling; anything else rejects. Account recovery V4 uses existing authenticated envelope format 2, never format 1. Preserve exact historical envelope bytes in history records. At phase transitions use:

```swift
let next = try selected.replacingBody(.committed(preparedBody))
let bytes = try next.encoded(maximumBytes: maximumBytes)
```

  Apply the corresponding existing body case at prepare/abort/install/rollback transitions. No constructor may silently select ordinary V3 for V4. Validate retained backup manifest/payload against binding during terminal handoff and authenticated recovery, not just during initial prepare. Validate receipt through the selected manifest variant; receipt existence remains insufficient without committed phase and full journal prefix.
- [ ] Audit all native callers with `rg -n 'BootstrapManifestV3|version == 3|version != 3|\[1, 2, 3\]|Role.allCases' Sources/KnitNoteCore/CloudSync`. Record each remaining occurrence as strict V3 codec, shared body/proof data, or intentionally unsupported legacy entry. Only after every entry has a defined policy remove Task 3's temporary rejection inside the new native preparation API.
- [ ] Run recovery, manifest, history, handoff, account inventory, account source-control, journal and budget suites in bounded sequential batches. Commit as `feat: recover legacy imports through all owned native readers` after GREEN. This is not App activation.

### Task 5: Current consent, final source drain and native commit coordinator

**Files:** Create `LegacyImportNativeCoordinator.swift` and `Tests/KnitNoteCoreTests/LegacyImportNativeCoordinatorTests.swift`; modify source owner and owned transaction only for scoped final validation. Keep `LegacyImportPreparationCoordinator.confirm` returning intent, not an install capability.

**Interfaces:** `@MainActor final class LegacyImportNativeCoordinator` owns one Task and one pending proposal. Initializer consumes `LegacyImportSourceOwner` and an already native-owned `SyncBootstrapOwnedTransaction` plus `SyncBootstrapOwnedInput`. Define nested nonconstructible `Proposal`. API: `prepare() async throws -> Proposal`, `confirm(_ proposal: Proposal) async throws -> SyncBootstrapReceipt`, `stopAndDrain() async`, `invalidate()`. The coordinator retains source preparation and target native preparation privately. Confirmation cannot accept a caller Boolean, path or replacement source.

- [ ] Add tests for foreign proposal, double confirm, stale target, source edit after prepare, source edit during drain, blocked worker cancellation, A→B→A and receipt-before-commit interruption. Use the actual owned transaction with existing injected boundaries, not mock install success. Confirm invalidation does not discard the join handle or delete backups. Run `LegacyImportNativeCoordinatorTests` for RED.
- [ ] Implement ordered prepare: source native prepare/backup, target native context validation, V4 native prepare, current proposal publication. Do not call App producer stop here. Implement confirm: exact proposal identity/current generation, close source writer admission and join, full native source/backup revalidation, then synchronous native install and commit under current target validation. Retain the operation before awaiting and reconcile its result exactly once:

```swift
guard let pending, pending.proposal === proposal,
      pending.generation == generation else { throw KnitNoteBackupError.accessDenied }
```

  `pending`, `generation` and `Proposal` are owned by this coordinator. A successful intent check is followed by actual source/target validation; it is never passed as an authority flag to the executor. The installed capability cannot be reused after final failure. On cancellation or failure, join actual native work and use native recovery for target state; retain source/backup/evidence. Restarted uncommitted state requires a fresh proposal, whereas committed recovery is idempotent and does not request a new import.
- [ ] Run coordinator, source-owner, existing preparation coordinator and owned transaction suites. Verify no production App import call sites. Commit as `feat: coordinate scoped legacy consent with native commit` after GREEN.

### Task 6: Real V4 interruption and preservation matrix

**Files:** Create `Tests/KnitNoteCoreTests/SyncBootstrapLegacyImportCrashTests.swift`; extend the new recovery/coordinator suites. Reuse child-launch mechanics from `SyncBootstrapOwnedCommitCrashTests.swift`, not its V3 result as V4 proof.

**Interfaces:** Child arguments identify an isolated test root, phase and test worker. The child creates a real source owner and target transaction; the parent never reconstructs them after interruption. Parent snapshots include source root, original successful package, target regular files and directories. Use exact native manifest/receipt/handoff readers, not dictionaries as success oracles.

- [ ] Add real process termination at preparing publication, partial LegacyBackup, prepared, live move, staged move, installed, each journal durable prefix, afterReceipt and committed-before-handoff. In the worker use the inherited test executable and existing filter stripping/timeout handling. The boundary action is actual termination:

```swift
if boundary == selectedBoundary { _exit(86) }
```

  Define `selectedBoundary` from the worker's validated test argument, using existing `SyncBootstrapOwnedBoundary` cases; add a narrowly scoped backup-output boundary only if existing I/O injection cannot select the needed prefix. Capture a negative-control RED by deliberately swapping installed/committed expectations; restore correct assertions before GREEN. This is test-oracle sensitivity, not a product defect claim.
- [ ] On the same paths, open/recover twice. Before committed expect rollback or preserved preparation failure, never imported publication. After committed expect native handoff, imported literal content and identical nonempty journal on second reopen. Corrupt/remove/swap backup, binding, receipt, history, attachment and account evidence on independently created cases; expect rejection and full damaged snapshot unchanged.
- [ ] Add write/file-sync/parent-sync failures through existing owned I/O injection. Explicitly label process kill versus simulated syscall durability failure. Test source identity substitution, counter/Watch nontransfer and capacity exact/+1 with retained originals. Run bounded crash/recovery/coordinator batches; commit as `test: verify legacy import crash recovery and evidence retention` after GREEN.

### Task 7: Native integration review and release-gate handoff

**Files:** Create `docs/superpowers/reports/2026-09-10-legacy-import-native-integration-verification.md`; update the preflight report only with verified outcomes. Do not mark unchecked plan tasks complete.

- [ ] Run all new suites together with the existing V3 owned transaction/manifest/history/budget/handoff, account recovery/source-control, legacy observation/coordinator and mapper suites. Inspect final summaries and exit codes. Run Core build for supported compilation configuration; retain exact commands and diagnostic boundaries. No real CloudKit integration environment variable.
- [ ] Review the entire source delta from the plan baseline for capability construction, stale generation, new-role rejection in V3, variant loss, underestimated capacity, cleanup on malformed input and production call sites. Fix findings with their own RED/GREEN evidence before completion. Verify version/build and platform floors unchanged.
- [ ] Record completed native evidence and explicitly list remaining gates: qualified shipping source issuer and App account transition wiring; actual shipped-version upgrade; Watch/account/cloud integration; physical iPhone/iPad/Mac/Watch acceptance; full candidate build/archive/signing; live App Store Connect state and exact candidate submission authorization. Commit report as `docs: record verified native legacy import integration` only after these local checks finish.

## Plan self-review

Spec coverage: sections 3–4 and receipt section 6 → Tasks 1/4; source capability and evidence section 5 → Tasks 2/3/5; write order section 6 → Tasks 3/5; interruption section 7 → Tasks 4/5/6; capacity and approved compatibility section 8 → Tasks 1/3/4/6; matrix section 9 → Tasks 6/7. Section 10's completed V3 prerequisite is retained, not rerun as substitute implementation. Global constraints apply to every task.

Type boundaries: V3/V4 share body/proof structures, not variant validation or receipt semantics. Observations remain data; source preparation is closed-owner scoped; target authority remains existing native storage/context; receipt remains data until verified by committed handoff. The new DEBUG fixture issuer cannot adopt caller paths and has no release factory. The existing App source-owner design is deliberately outside this isolated-native plan, as required by spec section 5.

Execution state: all tasks above are unchecked. This document is not implementation, passing tests, App integration, device acceptance or release approval.
