# Account Source Control Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the backward-compatible source control codec, portable baseline and verified fresh/existing storage open APIs needed by account-source recovery.

**Architecture:** Extend the existing recovery main/next control as a tagged v2 state machine and carry source evidence in authenticated inventory. Atomically hand restored pending sources into durable absence provenance; bind the existing bootstrap installer to spend that provenance before its live move. Keep transport session paths within already inventoried account roots.

**Tech Stack:** Swift 6, Foundation, Darwin descriptor-relative filesystem operations, CryptoKit hashes, Swift Testing, existing isolated App harnesses, unsigned Xcode validation.

**Spec:** `docs/superpowers/specs/2026-09-08-account-source-provenance-design.md` in `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`.

## Global Constraints

- Baseline d8fb343 / source08c7475. Execute only this independent control foundation; inventory/sealing and owned-bootstrap integration are subsequent scoped work.
- Keep1.7.0(13), iOS18/macOS15/watchOS11, existing remote record/journal/publication formats, exact FIFO and attachment bytes, deletion/expiry policy, incoming128batches/16MiB, journal64MiB, file/canonical/batch100,000,000bytes, recovery aggregate cap and control8192bytes.
- No live account/Keychain/device/signing/schema/push/upload/submission or user-data cleanup. All implementation tests use isolated fixtures.
- One worker per cohesive task, sequential production edits, one independent review per task. Main owns the final review and frozen validation. No worker changes unrelated files or starts its own agents.
- Reuse existing intent.json/intent-next.json, authenticated vault, storage lock and installer; no additional excluded control, parent history, fake archive, v3 bootstrap format, new key lifecycle or retention change.
- Source checks use cooperative sandbox integrity, not cryptographic same-user protection. Source provenance never authorizes cleanup independently of selected vault authentication.
- Actual filesystem creation is the only fresh-allocation input. Interrupted existing namespace without provenance fails closed. Complete namespace deletion is outside the stronger historical guarantee.
- No domain/journal writer before canonical activation; changed baseline is an error, never implicitly recertified.
- No storage lock crosses await or recursively invokes the App ownership callback. Current account generation validation happens before and after synchronous storage-owned operations.
- All commands below run from the spec worktree. Log RED, GREEN, command exit, source SHA and errors per task; do not change a failure expectation to hide an integration gap.

---

## File structure and task boundaries

Two focused new Core files in Task 1: `Sources/KnitNoteCore/CloudSync/SyncAccountSourceState.swift` owns portable source models/baselines, and `Sources/KnitNoteCore/CloudSync/SyncAccountRecoveryControl.swift` owns the small control codec and descriptor-scoped atomic replacement. They are values/helpers, not a second storage or recovery owner. Existing `SyncAccountRecoveryTransaction` retains authentication and state transitions.

**Regression-safe activation boundary:** Task 1 adds `openForVerifiedAccount(identity:validateAccount:)`, but leaves generic `open(identity:)` unchanged for legacy/non-account fixtures. The following App integration plan must switch the actual App entry point and prove it cannot use generic open. The new route derives creation internally; its callback validates the current account generation and is not a caller-provided freshness claim. Activating fresh records on all existing open calls in Task 1 would break old recovery readers before Task 2; do not do that. This foundation does not change existing consume/seal semantics or claim missing-archive account switching.

## Shared interface contract

All following types are internal unless an existing cross-module public entry point requires public visibility. Do not expose a public source-state/capability initializer. Core sources are compiled directly into the App harness/module, so App use itself does not require a public initializer.

Task 1 defines these complete value contracts in `SyncAccountSourceState.swift`:

```swift
struct SyncAccountSourceFileProof: Codable, Equatable, Sendable {
    let relativePath: String
    let isDirectory: Bool
    let byteCount: Int64
    let sha256: Data
}
enum SyncAccountSourceOrigin: Codable, Equatable, Sendable {
    case freshAllocation(allocationID: UUID)
    case restoredSelection(vaultID: UUID, captureID: UUID,
        envelopeSHA256: Data, packetSHA256: Data, deletionSHA256: Data?)
    case bootstrapRollback(transactionID: UUID, activeRelativePath: String,
        activeEnvelopeSHA256: Data)
}
struct SyncAccountSourceState: Codable, Equatable, Sendable {
    let authorityID: UUID
    let generation: UUID
    let accountIDHash: String
    let accountRoot: URL
    let accountDevice: UInt64
    let accountInode: UInt64
    let archiveURL: URL
    let journalURL: URL
    let baselineSHA256: Data
    let origin: SyncAccountSourceOrigin
}
enum SyncAccountSourceBaseline {
    static func digest(entries: [SyncAccountRecoveryInventory.Entry],
        accountRoot: URL, journalURL: URL, mutations: [SyncMutation],
        selectedFiles: [SyncPendingRecoveryPacket.File],
        deletionLedger: Data?, pendingMarkerVersions: [SyncRecordVersion]) throws -> Data
}
```

Baseline implementation filters all working-set proofs plus selected dependency paths outside working-set and configured journal file family (exact journal path and its recognized checkpoint/segment/lock siblings), sorts proofs by relative path, and hashes canonical encoded proofs + ordered mutations + selected ledger/marker metadata. Drop device/inode only from these portable proofs. File payload bytes are represented by validated byte-count/digest proofs; do not create another encoded copy of media. The following inventory integration must validate membership, native journal and dependencies before accepting the digest. For a genuinely empty new scaffold all these collections are empty, with the actual fixed runtime journal URL bound in SourceState.

Task 1 moves the current private `Intent` stored properties unchanged into internal `SyncAccountRecoveryIntent` in `SyncAccountRecoveryControl.swift`; its `phase` remains `SyncAccountRecoveryTransaction.Phase`. The transaction can retain `private typealias Intent = SyncAccountRecoveryIntent` during refactoring. No v1 encoding changes.

```swift
enum SyncAccountRecoveryControl: Equatable, Sendable {
    case legacySelection(SyncAccountRecoveryIntent)
    case selectedRecovery(SyncAccountRecoveryIntent, predecessorSHA256: Data)
    case absentSource(SyncAccountSourceState)
    case sourceSpent(SyncAccountSourceState, transactionID: UUID,
        preparedManifestSHA256: Data)
}
struct SyncAccountControlObservation: Equatable, Sendable {
    let mainBytes: Data?
    let nextBytes: Data?
    let state: SyncAccountRecoveryControl?
}
struct SyncAccountRecoveryControlFile {
    init(synchronize: @escaping @Sendable (Int32) throws -> Void)
    func observe(access: SyncAccountStorage.RecoveryAccess) throws -> SyncAccountControlObservation
    func synchronize(_ observation: SyncAccountControlObservation,
        access: SyncAccountStorage.RecoveryAccess) throws
    func replace(_ observation: SyncAccountControlObservation,
        with state: SyncAccountRecoveryControl,
        access: SyncAccountStorage.RecoveryAccess,
        validateSource: () throws -> Void) throws -> SyncAccountControlObservation
    static func encode(_ state: SyncAccountRecoveryControl,
        predecessorSHA256: Data?) throws -> Data
    static func decode(_ bytes: Data) throws -> SyncAccountRecoveryControl
}
```

Control v2 wire is `{formatVersion:2, predecessorSHA256:<Data?>, payload:<Data>, checksum:<Data>}`, with checksum SHA256(canonical `{predecessorSHA256,payload}`); payload uses an explicit `kind` and exactly one state's fields. Initial fresh main has an explicit null predecessor; every replacement has SHA256(old main), including an old v1 main. `replace` computes that predecessor from its exact observation and passes it into `encode`; callers cannot omit it. `selectedRecovery` also binds the source predecessor in its state for authenticated inventory correspondence, and the decoder requires both values equal. Direct fresh issuance calls encode with nil only after actual creation; encode of legacySelection requires nil and preserves the exact old wire. `decode` validates the envelope and required state fields; observation validates next's predecessor against current main. A next without main is invalid.

## Task 1: Control codec, source baseline and actual fresh allocation

**Files:** Create the two Task 1 Core files above and `Tests/KnitNoteCoreTests/SyncAccountSourceStateTests.swift`. Modify `SyncAccountStorage.swift`, `SyncAccountRecoveryTransaction.swift` (Intent extraction only), `SyncAccountStorageTests.swift`, and PBX source membership.

**Consumes:** Existing `SyncAccountStorage.RecoveryAccess`, inventory Entry, journal mutation types, and existing Intent properties/Phase.

**Produces:** Every Task 1 shared interface above; add `SyncAccountStorage.openForVerifiedAccount(identity: SyncAccountIdentity, validateAccount: () throws -> Void) throws -> Paths` and `SyncAccountStorage.openExistingAccount(identity: SyncAccountIdentity, validateAccount: () throws -> Void) throws -> Paths`. The latter requires the account directory already exist using descriptor-relative `create:false`, never allocates/mints freshness, and rejects ambiguous missing source. Keep generic `open(identity:)` unchanged. All three share one private open implementation with an internal mode enum, not duplicated directory logic.

- [ ] Add codec RED tests named `v1IntentBytesStayUnchanged`, `v2ControlRejectsUnknownMixedAndNullFields`, `derivativeNeedsExactMainPredecessor`, and `portableBaselineBindsFIFOAndSelectedSources`. Copy a real encoded v1 intent from the existing test fixture, assert decode/encode exact bytes, and mutate JSON dictionaries for unknown/mixed/null cases.

```swift
@Test func freshAllocationOnlyComesFromActualDirectoryCreation() throws {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("source-state-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let account = try SyncAccountIdentity(containerIdentifier: "test", userRecordName: "fresh")
    let storage = SyncAccountStorage(baseURL: base)
    let paths = try storage.openForVerifiedAccount(identity: account, validateAccount: {})
    defer { try? storage.close() }
    try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: 100_000_000) { access in
        let control = SyncAccountRecoveryControlFile(synchronize: { _ in })
        guard case .absentSource(let state)? = try control.observe(access: access).state else {
            Issue.record("Actual fresh allocation did not persist absence provenance"); return
        }
        #expect(state.accountIDHash == account.accountIDHash)
        #expect(state.archiveURL == paths.workingSet.appendingPathComponent("projects-v1.json"))
        #expect(state.journalURL == paths.mutationJournalURL)
    }
}
```

- [ ] Run RED: `env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --no-parallel --filter 'SyncAccountSourceStateTests|SyncAccountStorageTests|SyncAccountRecoveryTransactionTests'`. Record a missing-symbol or new behavioral failure, not merely an environment error.
- [ ] Implement custom codecs, canonical baseline projection, and no-follow <=8192-byte descriptor reads/writes by moving/reusing the existing transaction helper logic. `replace` compares exact main/next observation, resynchronizes old main, validates source, writes/syncs next, repeats predecessor/source checks, renames, fsyncs control/account, rereads exact committed bytes. Existing authenticated transaction checks remain outside this low-level helper.

```swift
// Replacement skeleton inside the helper; all named methods are in its contract.
guard try observe(access: access) == observation else {
    throw SyncAccountRecoveryTransaction.Error.changedInventory
}
try synchronize(observation, access: access)
try validateSource()
// Descriptor-relative write(next), fsync(next/control), repeated comparison,
// renameat(next, main), fsync(control/account), and exact reread follow here.
// Preserve existing transaction Error and regular-file/link/identity checks.
```

- [ ] Add storage injection `init(baseURL: URL, synchronize: @escaping @Sendable (Int32) throws -> Void)` internally; existing public init supplies fsync. Use it for fresh main/file/control/account fsync fault tests. The new open route captures successful mkdir internally, validates current account callback outside its mutex before and after, acquires account lock, verifies the exact empty scaffold, writes fresh main with the original physical root and empty portable baseline, synchronizes and validates before returning Paths. Existing namespace with no record returns Paths only if an archive or pre-existing recovery/bootstrap evidence remains for downstream exact validation; ambiguous missing state is rejected before producer exposure. Never issue fresh state for existing directories.
- [ ] Add actual-existing-empty, corrupted archive, interrupted creation before main durability, validator generation change, invalid owner/root replacement and symlink tests. Preserve existing directory bytes on rejection; a successfully durable fresh main after a reported sync fault may be resynchronized on reopen, but a mainless derivative or no durable provenance stays blocked.
- [ ] Run the focused command again. Record GREEN. Independently inspect legacy transaction tests to ensure Intent extraction did not change v1 output or delete semantics yet. Task 1 does not activate the new App route.
- [ ] Self-review, run git diff --check, and commit only exact task production/test/PBX files with subject `feat(sync): add owned account source control state`. Local task commit authorized, no push. Main independently reviews after complete report. Preserve all RED/GREEN logs and report hashes.


## Task 2: Main review and validation

- [ ] Read Task1 report and exact final log/exit/hash; dispatch independent spec+quality review and resolve load-bearing findings through original implementer.
- [ ] Verify new Core files compile in actual-source App and PBX targets without activating verified-open in shipping. Record exact source tree/harness changes; source symlinks must point to current worktree.
- [ ] Run one final review then frozen Core/App/root/unsigned macOS/iOS chain using established commands in docs/superpowers/reports/2026-09-08-missing-archive-bootstrap-verification.md, fresh `/tmp/account-source-control-frozen-01-*` logs/derived paths. Core unsets KNITNOTE integration override, App/root explicit0, next only previousexit0. No source edits while frozen.
- [ ] Record source/log hashes, outcomes, all rulings/costs and retained source inventory/bootstrap lineage gates in docs/superpowers/reports/2026-09-08-account-source-control-verification.md; commit docs and continue source-inventory integration.

## Deferred integration, not a foundation success claim

Completed draft /tmp/account-source-provenance-plan-draft-20260908.md contains later inventory/seal/restore, owned bootstrap and engine-namespace work. Main is resolving repeated-bootstrap predecessor history in /tmp/bootstrap-predecessor-lineage-design-20260908.md before those implementation tasks are dispatched. This foundation's codecs/open APIs do not depend on that format. No premature activation, full sealing or release claim is allowed.

