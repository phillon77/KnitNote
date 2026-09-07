# App Account Domain Installation and Local Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install a real, verified account-backed App session and keep its local editing available through recoverable cloud failures without weakening account or first-fetch authority.

**Architecture:** A concrete App factory consumes coordinator-owned storage/journal and actual attachment/ACK authorities, activates the existing canonical store, and returns a fixed session plus durable committer. A lifecycle adapter uses the existing AppSessionOwner for revocation/drain/publication. The existing transition and sync coordinators retain storage, recovery and real fetch-receipt authority; local access is separated from cloud completion.

**Tech Stack:** Swift 6, Swift Testing, CloudKit types with controlled engine driver, actual Core transactions and temporary roots, existing App composition.

**Spec:** `docs/superpowers/specs/2026-09-07-app-session-owner-integration-design.md` and `docs/superpowers/specs/2026-09-06-cloud-sync-app-session-lifecycle-design.md`. This implements concrete domain installation/readiness. System identity query/serialization and first-ever remote bootstrap preparation remain subsequent integration work, not claimed complete by this plan.

## Global Constraints

- 維持1.7.0(13)，iOS18/macOS15/watchOS11；不改100,000,000-byte與64MiB上限、資料/wire格式、購買、語言偏好、開發故事或30天復原條件。
- No live App, CloudKit, Keychain, Watch, user-data mutation, signing/install/schema/merge/push/upload/submission. Tests use explicit temporary roots, in-memory vault keys and controlled engines. Shipping KnitNoteApp stays on its existing cloud-disabled route.
- A path, UUID, cached identity, archive alone, empty remote snapshot or fake receipt never grants account readiness. Missing/unresolved canonical/bootstrap/media authority blocks installation without an empty replacement store.
- Use the single retained SyncAccountStorage and exact paths.mutationJournalURL. No second lock owner, App manifest decoder, guessed private attachment path, renamed source, re-exported immutable version ID, alternative cleanup or migration authority.
- App generation controls publication; existing CloudSyncAccountEpoch controls cloud commit. No synchronous ownership mutex across await. Close/discard only after actual producer/store drain and existing sealed-cleanup authority.
- Keep normal network/quota failure separate from account invalidation and durable/authority failure. A real initial fetch receipt remains mandatory for transport sends even when local editing is available.
- Preserve all evidence/worktrees. Prior bootstrap candidate 747d839 passed Core2528/186, actual-source App73/7 and unsigned macOS/iOS; those results are baseline only. One full frozen chain after all implementation tasks, not after each small seam.

## File responsibilities and handoff

Task 1 adds `KnitNote/CloudSync/AppAccountDomainFactory.swift` and `AppAccountAttachmentResolver.swift`: fixed inputs, actual canonical activation, attachment source resolution, immutable record snapshot, real committer and complete App resources. A narrow internal bootstrap-owned locator and optional candidate-aware activation resolver belong in their existing Core owners. Task 2 adds `AppAccountDomainLifecycle.swift`, extends the existing lifecycle protocol/coordinator and fixes recoverable first-fetch retry behavior in KnitNoteCloudSyncCoordinator. No new general framework.

### Task 1: Actual canonical domain factory and exact attachment sources

**Files:**
- Create `KnitNote/CloudSync/AppAccountDomainFactory.swift`, `KnitNote/CloudSync/AppAccountAttachmentResolver.swift`.
- Modify `Sources/KnitNoteCore/CloudSync/SyncBootstrapTransaction.swift` only for its owner-issued staged-source locator.
- Modify `Sources/KnitNoteCore/Projects/JSONProjectStore.swift` only for selected-candidate source acquisition during existing activation, if required by the daily interruption fixture.
- Test `Tests/KnitNoteAppTests/AppAccountDomainFactoryTests.swift`; extend existing Core bootstrap/canonical durability test fixtures instead of copying them wholesale.
- Register new files in `KnitNote.xcodeproj/project.pbxproj` using existing project generation conventions; no target/settings drift. Actual App compiles Core sources directly; internal APIs do not require new public exposure.

**Interfaces:** Define the following App-layer types. Task 2 consumes these exact names and fields; keep runtime authority creation outside this factory so transport uses the same instances.

```swift
@MainActor struct AppAccountDomainContext {
    let account: CloudAccountBinding
    let paths: SyncAccountStorage.Paths
    let journal: FileSyncMutationJournal
    let validateOwnership: () throws -> Void
}
@MainActor struct AppAccountDomainRuntime {
    let assets: CloudAssetStagingService
    let incoming: FileCloudIncomingBatchStore
    let zoneID: CKRecordZone.ID
}
@MainActor struct AppAccountInstalledDomain {
    let resources: AppSessionResources
    let recordProvider: any SyncRecordProvider
    let fetchedBatchCommitter: any SyncFetchedBatchCommitting
}
@MainActor final class AppAccountDomainFactory {
    init(entitlement: EntitlementCoordinator, backupHistory: BackupHistory)
    func install(context: AppAccountDomainContext,
                 runtime: AppAccountDomainRuntime,
                 bootstrap: SyncCanonicalBootstrapHandoff?) throws -> AppAccountInstalledDomain
}
```

The result is constructed only after real activation; no public initializer masquerades as a proof. AppAccountDomainContext's validator must remain valid during daily operations, independent from the short bootstrap freeze. The caller supplies current verified identity/ownership; Task 1 does not query a live account. Account sessions have no Watch adapter until the separate cross-account wire gate is met. Use existing inbox/presenters with `AppSessionComposition.make(..., makeWatch: { _ in nil })`.

- [x] **Step 1: Add real RED fixtures and bounded focused harness.** Seed actual bootstrap/canonical stores under SyncAccountStorage-owned temporary account roots using existing Core fixtures and immutable device IDs; use a temporary UserDefaults-backed entitlement/backup history as existing App composition tests do. New App tests compile actual App/Core source, not a mirrored factory. Extend or create a manifest under a new `/tmp/knitnote-account-domain-*` directory with explicit symlinked source files and the existing controlled engine fixture; preserve `/tmp/knitnote-app-root-kbh3SM`. Record exact manifest and command in report. Example behavioral assertions:

```swift
let installed = try factory.install(context: fixture.context,
    runtime: fixture.runtime, bootstrap: fixture.committedHandoff)
#expect(installed.resources.store.projects.map(\.id) == fixture.expectedProjectIDs)
#expect(installed.resources.presentation?.watch == nil)
try fixture.performDailyEdit(on: installed.resources.store)
#expect(try fixture.journal.pending().contains { $0.recordID == fixture.editedRecordID })
fixture.revokeOwnership()
#expect(throws: (any Error).self) { try fixture.performDailyEdit(on: installed.resources.store) }
```

Implement those fixture operations with real transactions/store mutations, not mutable success booleans. Cases: canonical-only reopen; recovered handoff; daily committed/uncommitted marker recovery selecting the correct checkpoint; missing/corrupt/foreign canonical; corrupt pending source; all live conflict heads; safe selected media role aliases; lost source; revoked ownership. API compile RED is recorded separately from behavioral RED; remove a load-bearing current/source guard temporarily, reproduce failure and restore it before GREEN.

- [x] **Step 2: Implement exact source acquisition and narrow owner locators.** Follow `/tmp/account-attachment-resolver-exact-map.md`, whose source references are mapping evidence, not a substitute for checking code. Validate records before dictionary construction; required canonical sources are every live lineage head, not every old ancestor and not only the displayed winner. Preserve journal source objects and match full immutable payload. Use existing SyncArchiveAttachmentReferences for displayed slots, normalizing only existing usage-markup/legacy-markup aliases. Use the existing account-bound installedDownload locator for other heads. Wrong/corrupt/unsafe sources throw; only checked absence permits another source. Every read is bounded to 100,000,000 bytes and verifies exact digest/count/current ownership.

```swift
let records = try SyncRecordValidator().validate(checkpoint.records)
let lineage = try SyncAttachmentLineage(records: records)
let required = Set(lineage.headsBySlot.values.flatMap { $0 }
    .filter { $0.deletedAt.value == nil }.map(\.id.uuid))
// For each required version, retain exact journal source, selected archive
// reference, owner-issued bootstrap source or installedDownload(version:).
// Validate immutable binding and bounded bytes before returning the map.
```

Add internal `stagedAttachmentSource: (SyncAttachmentVersion) throws -> SyncAttachmentSource?` to SyncCanonicalBootstrapHandoff, issued only inside canonicalHandoff. Its transaction computes private Attachments location, requires exact checkpoint version, validates before/after lookup, returns nil only for verified absence and retains staged-source identity. No public initializer, manifest format change or App path inference. Test recovered remote-only conflict head, corrupt bytes, source identity mismatch and released freeze. A handoff cannot be used after its exact installed authority advances.

Fetched resolver consumes the real partial SyncRemoteBatch, validates batch account, and resolves every nondeleted incoming attachment via the same account's installedDownload. Do not calculate lineage from a partial batch to omit versions. Existing committer owns epoch checks, durable commit and conflict handling. Preserve existing fail-closed rejection of unsupported raw-only installation; do not hide it as a source success.

If daily activation needs sources after Core selects/recovers its candidate, add an internal overload to activateSyncCanonicalState with `attachmentSourceResolver: (SyncCanonicalCheckpoint) throws -> [UUID: SyncAttachmentSource]`; keep existing signature unchanged and delegate to the same activation implementation. Call it at existing verifyCanonical points for the actual selected checkpoint, never select a publication in App or union predecessor-only IDs into the candidate. Resolver validates the exact archive digest at that point and reads references from those bound archive bytes. Test both committed and uncommitted daily marker paths. Any deeper source ownership gap is reported to controller with an exact failing fixture; never invent filenames.

- [x] **Step 3: Assemble actual store, snapshot and durable committer.** Under current ownership build SyncCanonicalCheckpointStore and a JSONProjectStore at `paths.workingSet/projects-v1.json`, using `JournalSyncMutationSink(journal: context.journal)` and unchanged entitlement authorizer/success closures. No `.live()` default root, disabled sink or hydrate-only readiness. Activate with the actual handoff/selected-source resolver; require no load/publication error and load the newly verified final checkpoint.

```swift
struct AppAccountRecordSnapshot: SyncRecordProvider {
    let recordsByID: [SyncEntityID: SyncRecord]
    func record(for id: SyncEntityID) throws -> SyncRecord? { recordsByID[id] }
}
```

Build this snapshot from validated final canonical records, never by re-export or a mutable MainActor store captured by Sendable lookup. Construct JSONProjectStoreRemoteBatchCommitter with the fixed store/account, real fetched resolver, and `runtime.incoming.verifyAcknowledgement(identity, accountIdentifier: context.account.userRecordName, zoneID: runtime.zoneID, account: context.account.identity)` after ownership validation. The incoming store must be the same authority passed to transport by Task 2. Release no account owner; start no engine or producer.

- [x] **Step 4: Verify focused behavior and commit.** Cover exactly100MB/100MB+1 before read, revoked locator, extra/missing conflict head, replaced/tombstoned ancestors, immutable snapshot lookup, exact pending source URLs, wrong account and real ACK refusal before durability. Use `/tmp/task4-run-bounded.py 900` around focused `swift test --package-path <new exact harness> --filter AppAccountDomainFactoryTests` and affected Core bootstrap/canonical tests. Record actual commands/logs/hashes, all warnings/failures, staged-source/activation mutation RED, and task diff. No full Core/platform chain yet. Commit exact production/test/PBX files and report DONE for fresh task review.

### Task 2: Concrete lifecycle, shared authority and retryable local readiness

**Files:**
- Create `KnitNote/CloudSync/AppAccountDomainLifecycle.swift`.
- Modify `KnitNote/CloudSync/CloudAccountTransitionCoordinator.swift`, `KnitNote/CloudSync/KnitNoteCloudSyncCoordinator.swift`, and `KnitNote/CloudSync/CloudSyncEngineTransport.swift` for the existing invalidation/cancellation join boundary.
- Test `Tests/KnitNoteAppTests/AppAccountDomainLifecycleTests.swift`; extend existing `CloudAccountTransitionCoordinatorTests.swift` and `KnitNoteCloudSyncCoordinatorTests.swift` if those fixtures are the smallest real driver route (verify exact existing test filenames before editing).
- Register new App/tests; preserve shipping KnitNoteApp and completed owner/root/Watch behavior.

**Interfaces:** Consume Task 1 context/runtime/factory/result. Extend existing CloudAccountDomainLifecycle with `recoverBootstrap(context: AppAccountDomainContext) throws`, and replace install parameters with `install(context: AppAccountDomainContext, runtime: AppAccountDomainRuntime) async throws -> CloudAccountDomainInstallation`. Existing freeze/stop/discard/resume responsibilities remain. Add `localAccessReady: Bool` to installation, default false for existing first-fetch-gated test adapters; concrete adapter returns true only after factory activation. This flag describes already established local access and cannot bypass the transport's real receipt requirement. Coordinator exposes read-only localAccessReady and cloud phase separately, plus `retrySync()` for current valid session. Account-invalidated callback is synchronous and does not recursively start a competing transition.

- [x] **Step 1: Add deterministic RED sequences.** Concrete adapter uses an injected existing AppSessionOwner, Task 1 factory and a current generation captured at `beginTransition() -> UUID`. This synchronous method calls owner.beginTransition before any Task/await. Protocol stopPublishingAndHide is idempotent within that transition. freeze awaits owner.waitForRetiredSessions, validates account/journal and joins any unpublished rejected candidate; never treats cancellation as drain. Sample assertions using real seeded account fixture:

```swift
let generation = lifecycle.beginTransition()
#expect(owner.visibleSession == nil)
#expect(oldStore.isSessionWriteRevoked)
let operation = Task { try await coordinator.transition(from: old, to: next, now: fixture.now) }
await fixture.driver.waitForFetchStart()
#expect(owner.visibleSession?.store.projects.map(\.id) == fixture.nextProjectIDs)
fixture.driver.deliverRetryableNetworkFailure()
try await operation.value
try fixture.performDailyEdit(on: #require(owner.visibleSession).store)
#expect(try coordinator.currentJournal!.pending().count > 0)
#expect(!coordinator.completed)
#expect(generation == owner.generation)
```

Fixture driver waits must be signaled/bounded and all operations joined before temp cleanup. Exercise A→B→A, signout, revoke during install/fetch, seal/install failure, local-ready network/quota, authority/auth ambiguity blocked, retry with actual committed receipt before sends, duplicate retry coalescing and released old closure. Never forge receipt in tests to prove production readiness.

Controller correction from real roundtrip fixture: existing SyncAccountRecoveryTransaction restores pending packet/deletion evidence, not normal canonical/archive/bootstrap after sealed cleanup. Therefore A→B→A in this slice proves exact pending/source restoration and hidden, distinguishable bootstrap-required state when canonical is absent; it does not prove local-ready roundtrip. Actual remote bootstrap/reconstruction remains required in the next integration. Preserve a separate ordinary same-account daily canonical reopen (without sealed cleanup), which must become local-ready. Retain the recovered account owner/pending for subsequent bootstrap; never manufacture an archive or re-seal on a sync retry.

- [x] **Step 2: Supply cycle-free context and recover in authority order.** Coordinator creates context validators capturing weak destination Session plus current coordinator/session identity, and calls existing storage.withRecoveryOwnership synchronously without escaping its RecoveryAccess or doing full inventory per daily mutation. Retired/closed/replaced sessions reject; separate transition generation from the short bootstrap freeze. Do not hold storage mutex over async work. Destination ordering: actual account recovery restore/consume or synchronized absence; bootstrap recovery if nonterminal; strict terminal namespace validation; shared runtime authorities; actual factory activation; local publication; background cloud startup.

For an already advanced canonical store, do not demand a stale bootstrap handoff. Use existing terminal namespace validation before constructing the checkpoint store; when terminal proofs validate and canonical exists, normal canonical activation owns daily recovery. If the terminal check specifically reports nonterminal phase, run recoverUnderCurrentContext under the new freeze then revalidate. If no canonical exists, obtain an actual committed handoff under current freeze or block as bootstrap-required. Corrupt/foreign/unsafe evidence never becomes an absent case. Do not catch arbitrary errors to choose another authority, and never construct checkpoint directories before unresolved nonterminal recovery. Keep private bootstrap metadata in Core.

The existing terminal validator combines invalid metadata and nonterminal phase in one guard. Split this guard inside SyncBootstrapTransaction: metadata/account/path/fingerprint rejection remains corruption/context failure, and only the phase check throws invalidPhase. Add corruption/nonterminal tests; do not expose manifest decoding to App. Add required `captureTransitionValidation() -> () throws -> Void` to lifecycle for an exact captured generation validator, with weak owner lifetime; no no-op default in production. Old controlled test adapters implement their test-only validator explicitly.

Prepared-bootstrap RED also demonstrates that ordinary SyncCanonicalCheckpointStore construction creates SyncMetadata even when canonical is absent, changing a rolled-back Original before handoff retry. Add a narrow internal Core-owned read-only loadIfPresent/open-if-existing using existing descriptor/no-follow ancestry and evidence validation, without mkdir/fsync or format change. Only checked absence returns nil; corrupt/foreign/unsafe canonical or abandoned temporary evidence throws. Use it after terminal namespace validation to choose ordinary canonical activation versus handoff/bootstrap-required. Cover actual rollback/retry plus missing, malformed, foreign, unsafe and temporary evidence. This probe is not readiness; factory activation remains mandatory.

Create assets/state/fields/incoming only after restore/bootstrap ordering permits normal stores. Reuse the exact assets and incoming store in both AppAccountDomainRuntime and CKSyncEngineTransport's injected incomingBatchStore. Use the existing relatedURL(pathExtension: "incoming-batches") convention. No duplicate authority instances with mismatched roots. Concrete lifecycle retains the fixed installed result until successful owner publication; rejected/stale results are stopped and drained before release. discard only drops already closed App references. No filesystem deletion.

- [x] **Step 3: Separate local access and cloud receipt; retain retry handshake.** For concrete verified reopen/handoff installation, call resumePublishing after actual activation and before waiting for cloud fetch; then release only bootstrap freeze. Daily storage validation remains live. Existing first-fetch-only adapters remain gated. Status localAccessReady stays true through explicit `.transport(.retryable)` and `.transport(.quotaExceeded)` while account remains current; completed stays false and pending stays durable. Unknown identity/account changes and authority/durable failures revoke/hide.

```swift
// Local publication is based on actual activated domain, not this receipt.
// The callback remains installed across recoverable failure until real fetch.
try await sync.startForAccountTransition { receipt in
    try receipt.epoch.requireCurrent()
    try validateCurrentDestination()
    if !localAccessReady { try lifecycle.resumePublishing() }
    // Only this actual receipt can open transport sends.
}
```

KnitNoteCloudSyncCoordinator currently leaves transition waiter suspended on retryable events and clears transitionReady on failure. Finish the waiter with a structured recoverable result/error while retaining the receipt callback until actual success; stop/account invalidation clears it. Ensure retrySync uses the same coordinator/engine, starts a new fetch and eventually acquires committedFetchReceipt, rather than leaving the send gate permanently closed after a failed initial fetch. Do not classify all `.operation` errors as recoverable or interpret `.notAuthenticated` as confirmed logout. Account change handler first synchronously invalidates lifecycle/owner and forwards a revalidation signal to its caller; no recursive `Task { transition(...) }`. System identity serialization is the next integration, not a guessed binding from an event string.

Post-startup blocking failures must also invoke existing transport invalidation, not only stop the App/event consumer after the first waiter has returned. Retain/join the actual cancellation task in Session before retry completion or subsequent freeze/inventory/close. Existing transport returns the same retained cancellation for repeated invalidation and event-stream-termination overlap; never lose a pending cancellation when engine is already detached. Preserve actor-side epoch/receipt invalidation before cancel awaits and synchronous App revoke before actor hop. Regress actual successful receipt/replay followed by blocking failure, stale send/delegate rejection, suspended cancellation, overlapping account event, and exactly one cancel. No new stop framework or competing transition.

- [x] **Step 4: Verify focused integration and commit.** Run the new actual-source account harness and relevant existing coordinator/recovery/owner tests in one bounded lane, with behavioral mutation RED for local access retained through retry and late account publication rejection. Verify seal-before-cleanup remains actual, no early inventory before drain, exact pending survives retries and all test operations join. Report exact source files, commands, logs, warnings, decisions and task commits for fresh review. Do not launch real factories or run full Core yet.

### Task 3: Independent final review and frozen validation

**Files:** Update this plan; create `docs/superpowers/reports/2026-09-08-app-account-domain-installation-verification.md`.

**Interfaces:** Consumes reviewed Task1/Task2 commits and exact harness report, produces a local verified candidate with explicit remaining identity/bootstrap/product/device/release gates.

- [x] **Step 1: Review the whole subplan.** Package baseline f5b8038 through final reviewed HEAD, include all task reports and parked findings. Fresh most-capable reviewer checks authority lifetime, candidate source selection, actual ACK, retry receipt callback and sync revoke before await. Resolve load-bearing findings through implementer/re-review, not controller edits.
- [x] **Step 2: Freeze identity and run one serial chain.** Record full SHA, branch, clean production/test/PBX diff and tree hashes. Run bounded full Core (`python3 /tmp/task4-run-bounded.py 3600 swift test`), new full actual-source account harness plus existing root/hosting coverage (900s each), unsigned macOS build-for-testing and unsigned iOS build (900s each), all in the worktree with fresh explicit derived/log paths. Copy exact proven platform commands from the bootstrap verification report; no App launch/signing. Start each only after previous exit0; save and resume the actual exec session, never duplicate it.
- [x] **Step 3: Record honest result and continue.** Inspect final logs, exits, hashes and diagnostics; verify frozen files unchanged and commit exact report/plan. Mark this ledger closed and route heartbeat to actual identity/serialized startup and first remote preparation integration. Preserve every worktree/evidence file under the user's delegated workflow. This is not cloud/device/Watch acceptance or push/submission approval.
