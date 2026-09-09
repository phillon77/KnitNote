# App Bootstrap Transport Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect a verified full-zone read to owned bootstrap and the existing App domain, without activating production sync.

**Architecture:** A bounded, initialization-only reader issues a private in-process lease. Native source/capacity and download primitives feed the existing owned transaction, then the existing App factory and ordinary transport take over. The reader never issues normal ACK/send readiness, modifies engine serialization, or creates a zone.

**Tech Stack:** Swift 6, Foundation/Darwin, CloudKit operation callbacks, existing KnitNoteCore transactions, Swift Testing, actual-source App SwiftPM harnesses, unsigned Xcode builds.

**Spec:** `docs/superpowers/specs/2026-09-09-app-bootstrap-transport-bridge-design.md` (user confirmed 2026-09-09).

## Global Constraints

- 版本維持 **1.7.0 (13)**。iOS18/macOS15/watchOS11 deployment floors remain unchanged.
- 不改遠端 record、journal、publication 或已完成的 owned v3 格式；不新增合併策略、清除策略或容量豁免。
- 沿用 record 非 asset payload 256 KiB、檔案／bootstrap／canonical 100,000,000 bytes、journal 64 MiB、incoming 128 batches／16 MiB、control 8192 bytes 與既有封存 aggregate cap。初始化在記憶體保留的 metadata（含刪除與收集證據）上限16 MiB，最多128頁。
- 不跨 await 持有同步 storage lock。取消等待者不是停止 native operation 的證據。
- 初始化 lease 不可偽裝成 `CloudInitialFetchReceipt`，也不能直接開啟上傳或顯示「已同步」。
- 本次不在錯誤處自動建立 zone。本次不得自動搬移正式 local store。
- 自動委任維持關閉；本規格不授權推送、合併、簽署、上傳或送審。
- All service/device/keychain operations in tests use isolated fixtures or injected drivers. Keep `.superpowers/absent-source-design-progress.md` untouched and preserve this plan's execution evidence.

---

## Verified baseline and execution setup

Planning baseline: `19acf71e20ad6fb63495516e0946936531a06c37`; previous code checkpoint `d68b557b4bfa7fbd90f0bcdb84adf2a19c0eb9ba`. Worktree `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`, branch `docs/cross-device-sync-design`. No implementation or test execution is claimed by this document.

Before execution inspect HEAD/status again. Do not repeat completed owned-bootstrap Tasks1–4. Establish this plan's own SDD ledger, not the previous plan's ledger. One compiler lane; no source edits during a frozen validation run. Use fresh log suffixes and inspect exit/status before the next command. Local checkpoint commits only, after review.

Existing commands and harnesses to verify before use:

```sh
env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --disable-xctest --no-parallel --filter SyncBootstrapSourceAccessTests
KNITNOTE_RUN_CLOUDKIT_INTEGRATION=0 CLANG_MODULE_CACHE_PATH=/tmp/knitnote-account-domain-jnjVrd/clang-cache python3 /tmp/task4-run-bounded.py 900 swift test --disable-xctest --disable-sandbox --cache-path /tmp/knitnote-account-domain-jnjVrd/cache --config-path /tmp/knitnote-account-domain-jnjVrd/config --security-path /tmp/knitnote-account-domain-jnjVrd/security --package-path /tmp/knitnote-account-domain-jnjVrd --no-parallel --filter CloudBootstrapDownloadStoreTests
```

Account-domain Package.swift SHA256 `be651083b0427f1d2067dbc2b4fe0e6f1248d46211ff0d125baf7ef7d3c3f04b`; root harness `/tmp/knitnote-app-root-kbh3SM`, manifest SHA256 `9d80d3ca53ffbb96203f5cb590a54dac7a095a102d5bba3148afa4eb828e89eb`. Runner SHA256 `c9fbdb35fa3743e27a7fbf63a1a0cbabfb02ca10e299167c214841a915faec0b`. Existing account harness has198 source/test links, root26; new files increase these counts. Verify every link resolves into this worktree, never overwrite an existing off-worktree link. Add exact new Core/App/test links to the existing account harness as their files arrive; root's whole-Core link follows new Core files.

## File and interface map

| Owner | New files | Existing seams |
| --- | --- | --- |
| Task1: actual source and recovery accounting | Core `CloudSync/SyncBootstrapSourceAccess.swift`, `CloudSync/SyncBootstrapDownloadBudget.swift`; matching Core tests | Inventory actual codec, recovery Envelope codec, owned source fingerprint, native mapper/Watch metadata |
| Task2: bounded download, no startup reconciliation | App `CloudSync/CloudBootstrapDownloadStore.swift`; App test/helper | `CloudAssetFileStore.swift`, `CloudAssetStagingService.swift` native publication/locator |
| Task3: reader, driver, lease | App `CloudSync/CloudBootstrapPageDriver.swift`, `CloudSync/CloudBootstrapSnapshotReader.swift`; two App test files | `CloudRecordCodec.swift`, small shared reduction seam in `SyncMergeEngine.swift` if required |
| Task4: actual owned installation | App `CloudSync/AppAccountBootstrapBridge.swift`; App bridge tests | Core source access, owned prepare/install/commit/recover, App context |
| Task5: lifecycle handoff | App lifecycle tests | `AppAccountDomainFactory.swift`, `AppAccountDomainLifecycle.swift`, `CloudAccountTransitionCoordinator.swift`, controller shutdown |
| Task6: coherent verification | App `AppBootstrapTransitionIntegrationTests.swift`; execution report | PBX membership, harnesses, existing root/ordinary transport tests |

All App paths start `KnitNote/`; Core paths start `Sources/KnitNoteCore/`; tests start `Tests/KnitNoteCoreTests/` or `Tests/KnitNoteAppTests/`. Add Core production files to existing KnitNote/KnitNoteWatch source phases, App-only CloudKit files to KnitNote, App tests to KnitNoteAppTests where existing membership applies. Never compile `@testable import KnitNoteCore` into KnitNote-only Xcode tests.

## Cross-task contracts

The following are NEW internal signatures to implement, not claims that these APIs already exist. Store/reader objects cannot be substituted for cleanup authority.

```swift
struct SyncBootstrapSourceSnapshot {
    let archive: ProjectArchive
    let local: SyncExportPackage?
    let pending: SyncBootstrapPendingSnapshot?
    let counterReminderContext: SyncCounterReminderMergeContext
}
final class SyncBootstrapSourceAccess {
    init(storage: SyncAccountStorage, paths: SyncAccountStorage.Paths,
         account: SyncAccountIdentity, maximumBytes: Int)
    func capture(deviceID: String) throws -> SyncBootstrapSourceSnapshot
}
struct SyncBootstrapDownloadFootprint {
    let directoryPaths: [String] // exact account-relative native directories
    let files: [String: Int64]   // exact native file/temporary paths and peak lengths
}
enum SyncBootstrapDownloadBudget {
    static func requireFits(storage: SyncAccountStorage, paths: SyncAccountStorage.Paths,
        account: SyncAccountIdentity, footprint: SyncBootstrapDownloadFootprint,
        maximumBytes: Int) throws
}
```

Budget data is not an allocation permission. Task2 executes its exact producer-generated footprint under the same storage owner; no caller-supplied path list can authorize a write. If a helper needs a retained RecoveryAccess, use a synchronous internal overload and never return it.

```swift
final class CloudBootstrapSessionScope: @unchecked Sendable {
    let account: CloudAccountBinding
    let zoneID: CKRecordZone.ID
    let context: SyncBootstrapContext
    init(account: CloudAccountBinding, zoneID: CKRecordZone.ID, context: SyncBootstrapContext)
    func requireCurrent() throws
    func invalidate()
    func withCurrent<T>(_ body: () throws -> T) throws -> T
}
final class CloudBootstrapDownloadStore: @unchecked Sendable {
    let runtimeAssets: CloudAssetStagingService // cold native instance, same root
    init(storage: SyncAccountStorage, paths: SyncAccountStorage.Paths,
         scope: CloudBootstrapSessionScope, maximumBytes: Int) throws
    func accept(version: SyncAttachmentVersion, sourceURL: URL) throws -> SyncAttachmentSource
    func revalidate(version: SyncAttachmentVersion, source: SyncAttachmentSource) throws
}
```

Task2 owns `CloudBootstrapSessionScope` in its file so Task3 can consume it. It uses a real lock/invalidation latch, not an unchecked mutable bag: admitted synchronous work holds `withCurrent`; invalidation revokes future work and shutdown subsequently joins accepted native work. Lock order is scope → storage → asset file-store; no path reverses it, and no lock spans network await. App-actor closures are not called from SDK callback threads or while holding storage ownership.

## Task 1: Native read-only source and prospective download capacity

**Files:** Create the two Core files/tests from the map. Modify `SyncAccountRecoveryInventory.swift`, `SyncAccountRecoveryTransaction.swift`, `SyncBootstrapOwnedTransaction.swift` only to share existing codec/source logic; no new wire. Update PBX membership and exact Core harness links.

**Interfaces:** Produces `SyncBootstrapSourceAccess`, `SyncBootstrapSourceSnapshot`, `SyncBootstrapDownloadFootprint`, `SyncBootstrapDownloadBudget` above. Consumes actual inventory capture, `projectedEncodedByteCount`, `projectedEnvelopeByteCount`, `captureSourceDependencies`, mapper export and `WatchSyncPaths` in `WatchSync/AtomicWatchSyncFile.swift`.

- [ ] Write `SyncBootstrapSourceAccessTests` using existing `OwnedBootstrapFixture`/`SourceInventoryFixture`, with real fresh absence and archive fixtures. Initial executable assertion:

```swift
@Test func verifiedFreshAbsenceDoesNotCreateArchiveOrJournal() throws {
    let f = try OwnedBootstrapFixture(); defer { f.remove() }
    let before = try SyncAccountRecoveryInventory.capture(storage: f.source.storage,
        paths: f.source.paths, account: f.source.account,
        journal: FileSyncMutationJournal(url: f.source.paths.mutationJournalURL),
        archiveURL: f.source.paths.workingSet.appendingPathComponent("projects-v1.json"))
    let value = try SyncBootstrapSourceAccess(storage: f.source.storage,
        paths: f.source.paths, account: f.source.account, maximumBytes: 100_000_000)
        .capture(deviceID: "source-access-test")
    #expect(value.local == nil)
    #expect(value.archive.projects.isEmpty)
    let after = try SyncAccountRecoveryInventory.capture(storage: f.source.storage,
        paths: f.source.paths, account: f.source.account,
        journal: FileSyncMutationJournal(url: f.source.paths.mutationJournalURL),
        archiveURL: f.source.paths.workingSet.appendingPathComponent("projects-v1.json"))
    #expect(after.entries == before.entries)
    #expect(after.packet.mutations == before.packet.mutations)
}
```

- [ ] Run the Core command above; identify missing-API RED separately from behavioral failures. Add real restored pending, FIFO/payload/deletion source, archive corruption, foreign control, unresolved next, Watch prepared/processed metadata cases before production code.
- [ ] Implement capture under actual `withRecoveryOwnership`: observe exact control, call native inventory/dependency capture, bounded-read archive only if its admitted Entry exists, decode and export with `ProjectArchiveSyncMapper.export`. Absence must come from valid sourceAuthority; return only an in-memory empty source archive, never write it. Derive `pending.sourceTreeFingerprint` using the same exact live FileProof-map encoding as owned `plan`, extracting that helper rather than copying it. Preserve nil-vs-empty native journal presence semantics. Read existing Watch metadata through native bounded validated files; empty Watch context is allowed only after proved absence, never a blanket default. Revalidate source/control/entries after export; changed evidence rejects.
- [ ] Implement budget using real inventory and native packet count plus prospective Entries for the declared footprint. These future Entries are accounting-only: use conservative numeric identity widths and codec-bound unknown SHA bytes, never pass them to capture/restore. Include all ancestor/lock/temp/final file entries and peak raw bytes. Use actual legacy/v2 Envelope codec branches, extracting a shared count helper from recovery `prepare` where needed; count source-control main/next, current owned history, packet and deletion bytes at every Base64 layer. No parallel DTO or byte-count-only cap.
- [ ] Add `SyncBootstrapDownloadBudgetTests`: empty footprint parity with actual sealing bytes; exact accepted cap and cap-minus-one; long UTF-8 path/unknown-digest encoding; existing nonempty packet/history; overflow; a rejected footprint leaves files/control unchanged. Future footprint cannot grant source authority, and extra arbitrary paths cannot enter Task2's writer. Run both new suites plus `SyncAccountRecoveryInventoryTests|SyncAccountRecoveryTransactionTests|SyncBootstrapOwnedBudgetTests` once on the final task tree, record actual results, review, then local commit `feat: expose verified bootstrap source and download accounting`.

## Task 2: Download primitive with admission before the first write

**Files:** Create `KnitNote/CloudSync/CloudBootstrapDownloadStore.swift`, `Tests/KnitNoteAppTests/CloudBootstrapDownloadStoreTests.swift`, `Tests/KnitNoteAppTests/CloudBootstrapFixture.swift`. Modify native asset files only for scoped construction/publication seams. Add actual App harness links and PBX memberships.

**Interfaces:** Produces `CloudBootstrapSessionScope` and `CloudBootstrapDownloadStore`. Consumes Task1 budget. Reuses native account hash, Installed filename, xattr binding, no-follow file checks and `publishNoClobber`; no independent writer or cleanup.

- [ ] Build the shared App fixture using actual storage, no live identity/Keychain:

```swift
@MainActor final class CloudBootstrapFixture {
    let root: URL
    let account: CloudAccountBinding
    let storage: SyncAccountStorage
    let paths: SyncAccountStorage.Paths
    let context: SyncBootstrapContext
    let scope: CloudBootstrapSessionScope
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("CloudBootstrap-" + UUID().uuidString)
        account = try CloudAccountBinding(containerIdentifier: "test.container", userRecordName: "bootstrap")
        storage = SyncAccountStorage(baseURL: root)
        paths = try storage.openForVerifiedAccount(identity: account.identity, validateAccount: {})
        context = .init(accountIDHash: account.identity.accountIDHash, epoch: UUID(), freezeID: UUID())
        scope = .init(account: account, zoneID: CKRecordZone.ID(zoneName: "BootstrapTest"), context: context)
    }
    func remove() { try? storage.close(); try? FileManager.default.removeItem(at: root) }
}
```

Only this explicitly created test root is removable. Add fixture helpers for JPEG bytes/attachment records by extracting the actual `AccountDomainFixture` test construction, not by copying production mapping. Controlled keys use the existing memory-only vault fixture, never CloudRecoveryVaultKeychain.live.

- [ ] Write RED: constructing a download store makes zero new disk entries; `accept` with maximumBytes0 rejects before directory/lock/temp creation; rejected hash/size leaves no quarantine/eviction; existing pending-backed Installed bytes and inode remain unchanged. Sample source-free cap test:

```swift
@Test @MainActor func constructionCannotCreateAssetTree() throws {
    let f = try CloudBootstrapFixture(); defer { f.remove() }
    let url = f.paths.staging.appendingPathComponent("cloud-assets")
    #expect(!FileManager.default.fileExists(atPath: url.path))
    _ = try CloudBootstrapDownloadStore(storage: f.storage, paths: f.paths,
        scope: f.scope, maximumBytes: 0)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}
```

- [ ] Implement cold native service construction without calling `reconcileIndependentlyOnInitialization`. Keep ordinary init/installDownload behavior unchanged. Add an internal native planned-publication object retaining exact Installed name, generated temp UUID, xattr binding, input proof and directory/lock footprint; both accounting and execution consume this one object. `openTree` currently creates Accounts/hash/Uploads/Installed/Quarantine and a lock, and `publishNoClobber` currently allocates `.tmp-UUID`: include these before the first mkdir, not after acquiring a creation-producing asset lock.

The cold construction seam is `CloudAssetStagingService.makeForBootstrap(rootURL: URL, accountIdentifier: String, maximumAssetBytes: Int) throws -> CloudAssetStagingService`. It shares native initialization without reconciliation and is used by `CloudBootstrapDownloadStore` and Task5's preliminary cold runtime; `runtimeAssets` exposes the download store's exact instance for post-handoff factory construction. Before handoff the wrapper alone may invoke its new admitted publication primitive. Do not invoke ordinary `installDownload`, `installedDownload` or `reconcile` through this reference during initialization.
- [ ] Implement `accept` under scope→storage→native asset locks: actual source/control capture; produce native exact plan; budget admission; bounded-read CKAsset source with expected count/hash; repeat scope/source admission before effects; execute existing no-clobber publication and verify actual file/xattr/identity. Invalid data never enters ordinary quarantine/reconcile. Existing exact Installed file may be reused only after full binding/read validation; a conflicting file rejects unchanged. The initializer and missing-file locator must not create directories. No generic `allowCleanup=false` Boolean or caller-supplied target path.
- [ ] On thrown error use only the existing primitive's cleanup of its own newly issued temporary. A crash-retained native temp remains inventory data; do not sweep siblings or waive invalid source files. Prove actual inventory/capture after partial and final publication fits the preflight bound. Test partial write, fsync, rename, directory sync, old file replacement, symlink/hardlink, invalidation before/inside admission, exact source-byte/identity preservation, and all existing asset download/file-store tests. Run filtered App command with `CloudBootstrapDownloadStoreTests|CloudAssetDownloadStagingTests|CloudAssetFileStoreTests`, inspect failures, review, then local commit `feat: admit bootstrap downloads before native cache writes`.

## Task 3: Full-zone driver, ordered collection and private lease

**Files:** Create the two App files and `CloudBootstrapPageDriverTests.swift`, `CloudBootstrapSnapshotReaderTests.swift`. Modify `SyncMergeEngine.swift` only for shared existing duplicate-version reduction if its private API must be exposed internally; add corresponding Core regression tests. No ordinary transport changes.

**Interfaces:** Task2 scope/download store plus these NEW contracts:

```swift
enum CloudBootstrapPageEvent {
    case record(CKRecord)
    case deleted(CKRecord.ID)
}
struct CloudBootstrapPageResult {
    let zoneID: CKRecordZone.ID
    let token: CKServerChangeToken
    let moreComing: Bool
}
protocol CloudBootstrapPageDriving: Sendable {
    func fetchPage(zoneID: CKRecordZone.ID, previousToken: CKServerChangeToken?,
        receive: @escaping @Sendable (CloudBootstrapPageEvent) throws -> Void)
        async throws -> CloudBootstrapPageResult
    func cancelAndWait() async
}
final class CloudBootstrapSnapshotLease {
    // fileprivate initializer in the reader file; no memberwise/test issuer.
    func withSnapshot<T>(context: SyncBootstrapContext,
        counterContext: SyncCounterReminderMergeContext,
        _ body: (SyncBootstrapRemoteSnapshot) throws -> T) throws -> T
    func consume()
}
final class CloudBootstrapSnapshotReader {
    init(scope: CloudBootstrapSessionScope, driver: any CloudBootstrapPageDriving,
        downloads: CloudBootstrapDownloadStore)
    func read() async throws -> CloudBootstrapSnapshotLease
    func cancelAndWait() async
}
```

`CloudBootstrapPageEvent` remains callback-local: do not send raw CKAsset URLs across an actor hop. SDK concurrency annotations must compile as provided; do not add unchecked Sendable conformances to imported CloudKit classes. Reader's synchronized collector consumes callbacks inline, including bounded copying through Task2. The driver is tied to the scope's fixed private database; it does not accept arbitrary database overrides from consumers.

Any existing merge reduction requiring local counter/reminder context runs inside `withSnapshot` against the freshly captured `counterContext`, not a context captured before network await. Until then retain ordered validated record segments within the same metadata cap; validate every observed attachment branch. Lease identity binds those immutable observations and their source proofs. Context-independent validation occurs during collection; context-dependent reduction and full owned validation must finish before preparing can write anything.

- [ ] Add controlled operation injection beneath the actual driver, not a fake successful lease. Tests drive record callback, zone callback, operation result and operation completion separately. Required assertion sequence: record+zone success alone does not resolve `fetchPage`; operation-result success without completion also does not resolve it; completion after every callback resolves once. A missing terminal callback at operation completion throws, not hangs/succeeds. Test cancellation requests native cancel and waits for the held completion gate.
- [ ] Implement the live driver with `CKFetchRecordZoneChangesOperation`, `fetchAllChanges = false`, one zone, and `previousServerChangeToken` from the exact previous successful page (first nil). Configure record/deletion/result handlers before scheduling. Store first error in a locked result state and cancel, but resume the waiting continuation only after operation completion and accepted callback work is drained. Match callback zone/operation identity; record-level errors poison the operation. No save/delete/zone creation, engine state writes or normal incoming ACKs. The live factory remains uncalled by normal App/tests.
- [ ] Implement reader with at most one read and one page operation; reject concurrent reuse. Maintain bounded actual encoded metadata including event/deletion evidence and the unique final record map. Enforce16MiB and128pages with checked arithmetic before retention; do not keep an unbounded AsyncStream or raw record array outside this accounting. Release CKAsset handles after synchronous verification/copy. Continue only from successful page token; token expiration is an error, not automatic mid-scan reset. Final operation must be successful with `moreComing == false`.
- [ ] Validate record/type/full zone using CloudRecordCodec; retain ordered delete boundaries. Equal immutable attachment-version mismatches reject; reduce duplicate entity versions using existing `SyncMergeEngine` field/atomic-domain routines, not last-callback-wins. If a small internal reducer is extracted, delay whole-graph reminder migration until collection completes and preserve ordinary merge/error order. A physical delete ends that ID's current remote segment; later recreated observations start the next segment. It never deletes local records/pending or fabricates deletedAt stamps. Final mapper/graph validation remains in owned preparation.
- [ ] Before lease issuance validate complete records and every required live attachment version, including conflict branches, with native Installed locator and actual file identity. Bind scope/context, request UUID, fixed zone, encoded metadata digest and exact version/source proofs. `withSnapshot` checks scope and current sources before/after the synchronous body; construct `isComplete:true` only there. Normal reader completion preserves the lease, explicit cancel/account invalidation or `consume` invalidates it. No disk lease or normal CloudInitialFetchReceipt is created.
- [ ] Test with an empty controlled zone through the real reader and driver:

```swift
// Driver fixture must execute the actual callback/result/completion adapter.
let task = Task { try await reader.read() }
try await operation.emitSuccessfulEmptyZone(moreComing: false)
#expect(!operation.readerCompleted)
operation.completeSuccessfully()
let lease = try await task.value
try lease.withSnapshot(context: fixture.context, counterContext: .init()) { snapshot in
    #expect(snapshot.records.isEmpty)
    #expect(snapshot.isComplete)
}
fixture.scope.invalidate()
#expect(throws: (any Error).self) {
    try lease.withSnapshot(context: fixture.context, counterContext: .init()) { _ in () }
}
```

Here `operation` is the Task3 test helper around the injected native-operation adapter; implement `emitSuccessfulEmptyZone`, `completeSuccessfully` and `readerCompleted` with a held completion callback and locked observation, not sleeps or fake lease construction. Also cover multipage partial failure, per-record failure, missing/wrong zone, token expiry, duplicate/late callbacks, record recreation, stale/equal conflicting versions, every attachment error, exact limits, no state/ACK/send calls and cancellation during an accepted download. Run new App suites plus ordinary `CloudSyncEngineTransportTests`, related Core merge tests if changed; review and local commit `feat: issue bootstrap leases from complete zone reads`.

## Task 4: Real source to owned installation bridge

**Files:** Create `AppAccountBootstrapBridge.swift`, `AppAccountBootstrapBridgeTests.swift`. Add optional storage to `AppAccountDomainContext` with an explicit initializer preserving existing test call sites; nil is rejected by the new bridge, never guessed. No production factory default.

**Interfaces:** `@MainActor final class AppAccountBootstrapBridge` has `init(context: AppAccountDomainContext, scope: CloudBootstrapSessionScope, reader: CloudBootstrapSnapshotReader, source: SyncBootstrapSourceAccess, deviceID: String)`; `func install() async throws -> SyncCanonicalBootstrapHandoff`; `func stop()`; `func waitUntilStopped() async`. `deviceID` is an injected already-resolved installation identity, not a new per-retry UUID or a default string. The controller/live installation identity factory is outside this slice.

- [ ] Write RED on actual source fixture: successful empty-zone lease + genuine fresh absence reaches a real committed archive/handoff; last-page failure leaves original source and selector unchanged; a direct `SyncBootstrapRemoteSnapshot(isComplete:true)` cannot enter the bridge API. Use reader's controlled operation, not an injected handoff closure.
- [ ] Implement single in-flight bridge ownership. Call App context ownership validation on MainActor before/after awaits; actual synchronous writer validation uses the scope latch and native ownership, never a recursive App recovery lock. Recover existing owned/legacy state before new input; accept genuine committed handoff without new fetch. Corrupt/foreign evidence propagates, not caught as absence. Source capture occurs again after reader success, and scope/context must still match the lifecycle freeze.
- [ ] Use the actual interfaces in one non-suspending install segment:

```swift
let lease = try await reader.read()
try context.validateOwnership()
let input = try source.capture(deviceID: deviceID)
let storage = try requireStorage(context) // helper throws wrongAccount for nil
let tx = try SyncBootstrapOwnedTransaction(storage: storage, paths: context.paths,
    account: context.account.identity, context: scope.context,
    validateContext: { value in
        guard value == scope.context else { throw SyncBootstrapError.contextChanged }
        try scope.requireCurrent()
    })
let result = try lease.withSnapshot(context: scope.context,
    counterContext: input.counterReminderContext) { remote in
    let prepared = try tx.prepare(.init(local: input.local, sourceArchive: input.archive,
        remote: remote, pending: input.pending, counterReminderContext: input.counterReminderContext))
    try tx.install(prepared)
    _ = try tx.commit(prepared)
    guard let handoff = try tx.recover() else { throw SyncBootstrapError.invalidPhase }
    return handoff
}
lease.consume()
return result
```

Do not call source `revalidate` against pre-install live contents after tx commits: those contents legitimately changed. Lease postvalidation is limited to scope and retained remote source identities; owned transaction validates source-to-output authority. On any error revoke bridge availability, drain reader, retain evidence and let later native recovery run. `stop` synchronously invalidates scope before requesting cancellation; `waitUntilStopped` joins read/accepted native work without canceling the shared drain when one waiter cancels.
- [ ] Test archive+local-only assets, fresh absence, actual seal/restore pending, owned abort/rollback retry, Watch pending context, source edits during held network page, stale context before each irreversible local boundary, failures after prepare/install/commit, and restart after commit-before-return. Verify resulting canonical data and FIFO payload/attachment bytes; never just count events. Run bridge + Task1/source + existing owned recovery suites on final task tree, review, local commit `feat: install verified cloud bootstrap through owned core`.

## Task 5: Lifecycle selection and ordinary transport handoff

**Files:** Modify `AppAccountDomainLifecycle.swift`, `CloudAccountTransitionCoordinator.swift`, `AppAccountSessionController.swift` only for bootstrap cancellation/drain, `AppAccountDomainFactory.swift` context definition; extend actual lifecycle/controller/transition App tests. Keep KnitNoteApp's shipping composition and Watch creation unchanged.

**Interfaces:** Add injected `@MainActor (AppAccountDomainContext, SyncBootstrapContext, CKRecordZone.ID) throws -> AppAccountBootstrapBridge` factory to lifecycle, optional default nil preserves unactivated `bootstrapRequired`. The factory constructs scope/downloads/reader/source for that exact account and paths. Add `AppAccountBootstrapBridge.runtimeAssets: CloudAssetStagingService`, retaining the Task2 instance used by its reader; after successful handoff lifecycle constructs `AppAccountDomainRuntime(assets: bridge.runtimeAssets, incoming: runtime.incoming, zoneID: runtime.zoneID)` for the existing factory. No normal cloud factory is started by default. `AppAccountDomainContext.storage` is populated by the coordinator's actual destination Session. Existing lifecycle.install remains the async bootstrap admission point after read-only canonical absence.

- [ ] Write RED using actual lifecycle and controlled bridge dependencies: absent canonical invokes reader once; existing canonical or recovered committed handoff invokes it zero times; fresh zone success reaches factory/local-ready; missing zone stays blocked without publication/zone creation. Assert no engineFactory calls until initialization succeeds, and no normal engine state/ACK writes during reader operation.
- [ ] Refactor `recoverBootstrap` to dispatch verified native legacy/owned recovery using actual storage and current freeze, not path guessing or catch-all fallback. In install, probe canonical read-only first. If absent and no handoff, require the injected bridge; await install, validate generation/ownership, then call the existing factory. Retain active/rejected bridges just like retired session resources; beginTransition invalidates them synchronously, and freeze/waitForStoppedOperations joins them before inventory capture or storage close.
- [ ] Do not construct the ordinary `CloudAssetStagingService` before the missing-canonical bridge if its default initializer would reconcile files. Split coordinator runtime construction into cold initialization dependencies and normal runtime admission: Task2 cold service supplies the same native account-root asset store for bridge and factory, with ordinary reconciliation permitted only after bootstrap handoff and a current source check. State/fields/incoming construction must retain existing exact paths and cannot duplicate ownership. Normal canonical route behavior remains unchanged.

At the existing pre-install runtime construction point, choose the existing ordinary constructor only after a successful read-only canonical probe; for genuine canonical absence use `makeForBootstrap` with the same existing root/account arguments. This temporary cold runtime performs no asset calls. The successful bridge's exact `runtimeAssets` replaces it for factory installation and subsequent transport construction; return the selected runtime alongside the installed domain rather than accidentally retaining the preliminary instance. Corrupt canonical probes propagate and do not select the absence route. No reconciliation is newly scheduled merely because a bridge completed.
- [ ] Preserve existing factory installation then coordinator transport construction/publication ordering; do not move UI publication into the reader. Use this assertion shape in real transition tests:

```swift
#expect(owner.visibleSession == nil) // while last page is held
#expect(engineFactoryCalls == 0)
// Release the actual final zone/result/completion callbacks and await transition.
#expect(owner.visibleSession != nil)
#expect(engineFactoryCalls == 1)
#expect(coordinator.localAccessReady)
#expect(!coordinator.completed) // until ordinary durable fetch/send proof
```

The three observed values are locked counters/session properties in the test fixture, not injected readiness flags. Feed existing controlled ordinary driver events to prove a bootstrap lease alone cannot schedule a send; require actual ordinary fetch completion/commit/ACK receipt. Test retryable/quota failure leaves an established current local session available, account invalidation hides/revokes it, unknown identity does not open old data, and repeated retry/foreground does not create a second bridge/engine.
- [ ] Run actual `AppAccountDomainLifecycleTests|AppAccountSessionControllerTests|CloudAccountTransitionCoordinatorTests|AppAccountDomainFactoryTests|CloudSyncEngineTransportTests`; root controller composition tests remain unchanged and are rerun at Task6. Review/local commit `feat: hand off bootstrapped accounts to app lifecycle`.

## Task 6: Coherent fault matrix and frozen local checkpoint

**Files:** Create `Tests/KnitNoteAppTests/AppBootstrapTransitionIntegrationTests.swift`; update shared fixture; final report only during execution at `docs/superpowers/reports/2026-09-09-app-bootstrap-transport-bridge-verification.md`. Resolve any actual PBX/harness membership differences; do not add unrelated sources.

- [ ] Add a table-driven interruption matrix using actual reader→download→owned→factory→ordinary transport chain: last page, accepted asset write, completed lease, before preparing, after preparing, installed, committed-before-App-publish, and ordinary-first-fetch. Inject account invalidation/cancel separately from local IO failure. Observe source/pending/control bytes, output authority, owner visibility, canceled-operation completion, engine/ACK/send call counts and same-root restart result.
- [ ] Add two actual built-test child exits for after preparing and after committed-before-App-publish. Reuse the existing built SwiftPM helper pattern with a worker-only filter, isolated explicit root, live CloudKit env removed, exit86,60second deadline and terminate/kill grace. Retain failed fixture/logs. No nested compiler. On reopen recover at the same root before ordinary journal access; compare actual handoff/canonical/pending and prohibit duplicate bootstrap or unintended cleanup.
- [ ] Complete source/asset capacity parity under largest representative media fixture; compare native actual inventory+recovery encoding at each observed crash prefix to the admitted bound. Record an unexplained timeout as incomplete, not a production fix. Verify unchanged ordinary asset reconciliation behavior separately; tests cannot relax bootstrap retention to satisfy ordinary cleanup.
- [ ] Review this task, then the complete coherent unit once, including all new internal construction/reachability and both default-unactivated and injected-success paths. Resolve important findings with the skill's scoped fix loop. Confirm no production App factory, live keychain/schema call, new record/wire, arbitrary path/Boolean bypass or changed version was introduced.
- [ ] Freeze full Sources/Tests/KnitNote/PBX hashes and individual changed-file hashes. After final review, run the serial chain below with fresh logs; preserve failures and changed-candidate reruns. Full Core budget3600seconds is based on the last actual2842/204 run taking2080.985seconds, not a test omission. Other commands remain900seconds.

```sh
env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION python3 /tmp/task4-run-bounded.py 3600 arch -arm64 swift test --disable-xctest --no-parallel
KNITNOTE_RUN_CLOUDKIT_INTEGRATION=0 CLANG_MODULE_CACHE_PATH=/tmp/knitnote-account-domain-jnjVrd/clang-cache python3 /tmp/task4-run-bounded.py 900 swift test --disable-xctest --disable-sandbox --cache-path /tmp/knitnote-account-domain-jnjVrd/cache --config-path /tmp/knitnote-account-domain-jnjVrd/config --security-path /tmp/knitnote-account-domain-jnjVrd/security --package-path /tmp/knitnote-account-domain-jnjVrd --no-parallel
KNITNOTE_RUN_CLOUDKIT_INTEGRATION=0 python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --package-path /tmp/knitnote-app-root-kbh3SM --no-parallel
python3 /tmp/task4-run-bounded.py 900 xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/app-bootstrap-bridge-macos-derived CODE_SIGNING_ALLOWED=NO build-for-testing
python3 /tmp/task4-run-bounded.py 900 xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/app-bootstrap-bridge-ios-derived CODE_SIGNING_ALLOWED=NO build
```

- [ ] Recheck frozen hashes, actual built Info.plist1.7.0/13, all new source/test memberships and harness link targets. Write exact test counts/exit codes/log hashes/warnings, review closure and remaining live activation/legacy/zone/Watch/device/release gates. Only then stage explicit task files/report and local commit `test: verify app bootstrap transport handoff boundaries`. Preserve branch and evidence; no push/merge/sign/export/submission.

## Plan self-review / coverage map

| Spec concern | Task and verifiable boundary |
| --- | --- |
| Full nil-token scan, all callbacks, terminal proof, no zone creation | Task3 driver tests, Task6 chain |
| Private lease vs ordinary fetch ACK | Tasks3–5; compile-time API shape plus actual send gate |
| Genuine source/pending/Watch context, no fake absence | Tasks1/4; actual native snapshots and archive/absence/recovery fixtures |
| Capacity before any cache directory/temp write | Tasks1/2; native footprint and actual encoded crash-prefix parity |
| Source identity, all attachment branches, no quarantine/reconcile side effects | Tasks2/3; current inode/proof checks and old pending preservation |
| Native merge, physical deletion order, no changed remote wire | Task3 shared reduction/ordinary regression; Task4 full mapper |
| Ownership locks and async cancellation/drain | Tasks2–5; scope→storage→asset order and held native completions |
| Restart and committed handoff without duplicate initialization | Tasks4/6; real same-root child restart |
| Canonical reopen/offline local readiness stays intact | Task5 actual lifecycle and ordinary transport tests |
| Normal shipping activation/legacy/zone/Watch remain gated | Tasks5/6 default nil factory and reachability audit |

Shared-file ordering: Task1 Core source/budget precedes Task2 native download; Task2 scope/download precedes Task3 reader; Task3 lease precedes Task4 bridge; Task4 context initializer precedes Task5 coordinator changes. Task6 changes tests/report only unless review reveals a scoped defect. No parallel authors on asset/lifecycle source. API names in cross-task contracts and consumers match; helpers shown in test snippets are explicitly assigned to their task fixtures. This is a plan, not an executed verification report.
