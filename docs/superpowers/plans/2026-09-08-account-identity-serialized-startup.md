# Account Identity and Serialized Startup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect real tri-state system identity evidence to one serialized, generation-safe account runtime without turning an ambiguous query or retry into account cleanup.

**Architecture:** An injectable CloudKit identity query maps SDK evidence, and a MainActor App controller owns query/transition scheduling. Existing AppSessionOwner, AppAccountDomainLifecycle and CloudAccountTransitionCoordinator remain the only publication, domain and transaction owners. Existing canonical accounts can reopen through actual activation; missing canonical remains explicitly bootstrap-required until the subsequent remote collection/install/ACK work.

**Tech Stack:** Swift6, Swift Testing, installed CloudKit SDK, controlled query/engine drivers, actual Core temporary-root transactions.

**Spec:** `docs/superpowers/specs/2026-09-06-cloud-sync-app-session-lifecycle-design.md` and `docs/superpowers/specs/2026-09-07-app-session-owner-integration-design.md`. User delegates routine implementation/technical decisions overnight. This plan implements their identity/serialization section, not a new product policy or live activation.

## Global Constraints

- 維持1.7.0(13)，iOS18/macOS15/watchOS11；不改100,000,000-byte與64MiB上限、資料/wire格式、購買、語言偏好、開發故事或30天復原條件。
- No real account query, CKContainer construction, Keychain, live App/Watch, signing/install/schema, merge/push/upload/submission or user-data operation during execution. System factory may be implemented but remains lazy and uncalled. Shipping KnitNoteApp stays cloud-disabled; screenshots/fixtures construct no live factories.
- Identity unknown is never confirmed logout. Cache, path, generation, availability Boolean, missing archive, probe nil or fake receipt never establishes account readiness. Bound cold unknown hides and preserves data; ordinary network/quota errors in a still-confirmed session retain local editing.
- One App owner and one retained account coordinator, no competing transitions or filesystem cleanup authority. Stop synchronously before async identity revalidation; join started work before next transition. No mutex across await.
- Preserve all worktrees/evidence. Baseline production2d44fa4, documentationdbb3d73: freshly passed Core2532/186, App203/10, root73/7, unsigned macOS/iOS. This is baseline, not new integration proof.
- Carry deferred canonical-probe temporary routing Minor1 and unexecuted live-helper identity issue into later remote-bootstrap/acceptance; this plan does not touch either unless actual new failure proves a dependency.

## File responsibilities

`CloudAccountIdentityQuery.swift` owns SDK result mapping and injectable async calls, not sessions. `AppAccountSessionController.swift` owns one query/transition loop and non-sensitive presentation state, not storage. `CloudAccountTransitionCoordinator.swift` gains a truthful retained-account reconciliation entry that reuses its existing transaction internals. Tests use the existing actual-source account harness and actual domain fixtures; no second framework or broad App rewrite.

### Task 1: SDK-backed tri-state identity query

**Files:** Create `KnitNote/CloudSync/CloudAccountIdentityQuery.swift` and `Tests/KnitNoteAppTests/CloudAccountIdentityQueryTests.swift`; register both in `KnitNote.xcodeproj/project.pbxproj`. No Core edits.

**Interfaces:** Consume existing `CloudAccountBinding`. Produce:

```swift
enum CloudAccountIdentityResult: Equatable, Sendable {
    case confirmed(CloudAccountBinding)
    case noAccount
    case unknown
}
struct CloudAccountIdentityQuery: Sendable {
    init(containerIdentifier: String,
         accountStatus: @escaping @Sendable () async throws -> CKAccountStatus,
         userRecordName: @escaping @Sendable () async throws -> String)
    func query() async -> CloudAccountIdentityResult
    static func live(containerIdentifier: String) -> CloudAccountIdentityQuery
}
```

The query object has no account cache or background task. The live factory lazily creates the CKContainer only when explicitly called; construction is not a default argument or static initializer. Query cancellation returns unknown, and generation acceptance belongs to Task2. Validate nonempty binding using existing CloudAccountBinding initializer. No SDK error text/account identifier is exposed to UI.

- [ ] **Step 1: Add focused RED tests using controlled closures.** Use these behavioral cases, not source-string-only checks:

```swift
let query = CloudAccountIdentityQuery(containerIdentifier: "test.container",
    accountStatus: { .available }, userRecordName: { "account-A" })
#expect(await query.query() == .confirmed(try CloudAccountBinding(
    containerIdentifier: "test.container", userRecordName: "account-A")))
let denied = CloudAccountIdentityQuery(containerIdentifier: "test.container",
    accountStatus: { .available }, userRecordName: { throw CKError(.notAuthenticated) })
#expect(await denied.query() == .unknown)
```

Also cover noAccount does not call record lookup; restricted/couldNotDetermine/temporarilyUnavailable do not call lookup; status error, lookup error, empty identifier/name and cancellation never confirm none. Controlled counters are concurrency-safe and all suspended queries are released/joined. No test calls `.live`.

- [ ] **Step 2: Implement the SDK mapping only after RED.** Installed CKContainer.h lines140-178 and237-254 are the primary contract: available alone is not identity; notAuthenticated also means disabled/restricted; account notification requires requery and may arrive on arbitrary queues. Successful noAccount maps noAccount; successful available plus successful binding maps confirmed; everything else unknown. Check cancellation after each await. Use one retained container in the explicitly invoked live factory and actual `accountStatus()`/`userRecordID().recordName`; follow Swift6 Sendable SDK annotations without unchecked global mutable state.

- [ ] **Step 3: Verify, register and commit.** Extend `/tmp/knitnote-account-domain-jnjVrd` with actual source/test symlinks (apply_patch for any manifest edits; retain existing sources). Run bounded focused `CloudAccountIdentityQueryTests` with explicit `KNITNOTE_RUN_CLOUDKIT_INTEGRATION=0` and established --disable-xctest/--disable-sandbox/cache arguments. Record a behavioral RED for available-with-failed-record accidentally confirming logout or account. Do not rerun full Core/platform yet. Commit exact App/test/PBX files and write task report with commands, logs/hashes, warnings, test count and scope. No real factories.

### Task 2: Single serialized App account controller and safe reconciliation

**Files:** Create `KnitNote/CloudSync/AppAccountSessionController.swift`, `Tests/KnitNoteAppTests/AppAccountSessionControllerTests.swift`; modify existing `CloudAccountTransitionCoordinator.swift`, `AppAccountDomainLifecycle.swift` only for truthful reconcile/reopen boundary; extend existing `AppAccountDomainLifecycleTests.swift` and register files. Keep shipping `KnitNote/App/KnitNoteApp.swift` unchanged.

**Interfaces:** Consume Task1 query/result and existing concrete owner/lifecycle/coordinator. Produce:

```swift
@MainActor final class AppAccountSessionController: ObservableObject {
    enum State: Equatable { case idle, checking, noAccount, unknown, opening, localReady, bootstrapRequired, blocked }
    @Published private(set) var state: State
    init(query: CloudAccountIdentityQuery, lifecycle: AppAccountDomainLifecycle,
         coordinator: CloudAccountTransitionCoordinator, now: @escaping () -> Date)
    func start()
    func accountDidChange() // synchronous revoke, then schedule requery
    func retry()
    func foreground() // no healthy-session identity invalidation
    func stop()
    func waitUntilStopped() async
}
// Existing coordinator additions, not a second transaction manager:
var retainedAccount: CloudAccountBinding? { get }
func reconcileConfirmedAccount(_ account: CloudAccountBinding?, now: Date) async throws
```

`retainedAccount` describes the current storage session only; never identity proof. `reconcileConfirmedAccount` operates from actual retained state even after partial failure. Distinct confirmed account/logout uses existing seal/drain/cleanup transition; identical retained account reopens using existing destination validation/restore/bootstrap/activation on the same storage owner, without sealing/cleanup or a competing lock. Factor existing destination opening code once into private helpers; do not copy the whole transition. Unknown never calls reconcile. Failed bootstrap retains exact owner/pending and remains hidden. No legacy conversion, new persistence format or empty store.

- [ ] **Step 1: Add actual controlled RED sequences.** Construct actual AppSessionOwner/factory/lifecycle/coordinator with existing temporary-root fixture and in-memory vault keychain. Query closure controlled by continuations, engine uses existing driver. Assert:

```swift
controller.start(); controller.start(); controller.foreground()
// Release one controlled available+record result; exactly one install/engine.
await fixture.waitForLocalPublication()
let old = try #require(owner.visibleSession)
controller.accountDidChange()
#expect(owner.visibleSession == nil)
#expect(old.store.isSessionWriteRevoked)
// Before releasing the second lookup, no seal/cleanup may occur.
```

Also test delayed query superseded by event, event during suspended transition/drain, repeated retry coalescing, unknown cold start byte/journal preservation, confirmed logout versus lookup notAuthenticated, healthy foreground/network error retains editing, same-account revalidation reopens advanced canonical without vault/seal, source-cleaned/destination-failed retry uses actual retained account, bootstrap-required retry does not re-seal, stop plus late result never publishes. Join every query/transition/driver before fixture deletion. Use actual tree and receipt assertions, no fake readiness/empty store.

- [ ] **Step 2: Add truthful coordinator reconcile/reopen.** Preserve old `transition(from:to:now:)` for existing clients/tests. Reconcile uses retainedAccount inside coordinator, not caller-maintained last successful identity. Reopen invalidates/joins old transport, revokes/drains unpublished resources, revalidates destination and recreates transport with same assets/incoming authority per new session generation. Reuse the held storage owner; never close/reopen around uncertain ownership. An unresolved seal/restore transaction still follows existing recovery rules before normal domain mutation. Await/cancellation failures preserve ownership and proof. Add necessary private helper extraction only; report any ambiguity in recovery selection to controller before changing Core policy.

- [ ] **Step 3: Implement a retained serial pump.** MainActor start coalesces; authoritative account event calls lifecycle.beginTransition synchronously, increments request generation, marks latest requery, and invalidates acceptance of all older results. Do not create parallel transition Tasks. Let current transition safely finish/drain, then requery latest; a stale query may finish but never reconcile/publish. Keep pump Task retained and joined by stop; no cycle via infinite task retaining owner. Coordinator accountInvalidatedHandler forwards to this entry without deriving identity from event strings. Foreground on healthy confirmed session only retries sync and refreshes non-sensitive state; unknown retry initiates query. Stop synchronously revokes then joins query and transaction work. Do not implement native notification observer or live launch in this task; the explicitly callable accountDidChange boundary is ready for later authorized system composition.

State projection keeps localReady distinct from cloud completed: map only from actual coordinator.localAccessReady and requiresBootstrap, never successful query alone. Missing archive remains bootstrapRequired. No raw account/path/error payload in observable state. Controller is a concrete injectable runtime and does not activate shipping.

- [ ] **Step 4: Focused validation and commit.** Run all new controller and affected actual lifecycle/coordinator/owner tests under the actual-source harness. Mutation RED: remove query-generation acceptance or same-account reuse and observe a real stale publication/extra seal failure, restore code. Record source inventory, commands/log hashes, unchanged Core/data policy, and exact commits for independent task review. Keep full Core/platform chain for Task3.

### Task 3: Final integration review, frozen validation and direct remote-bootstrap handoff

**Files:** This plan and `docs/superpowers/reports/2026-09-08-account-identity-serialized-startup-verification.md`.

**Interfaces:** Reviewed Task1/2 candidate, actual-source account/root harnesses and unchanged Core. Completion is this injectable identity/runtime only, not shipping notification wiring or remote bootstrap.

- [ ] **Step 1: Independent whole-plan review.** Use exact baseline through final task HEAD and reports, then adjudicate current task findings; carry canonical-probe Minor1/live-helper follow-ups rather than silently closing them.
- [ ] **Step 2: Run one final serial chain.** Full account harness explicit opt-out0; Core `env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION python3 /tmp/task4-run-bounded.py 3600 arch -arm64 swift test --no-parallel`; existing root harness; unsigned macOS build-for-testing and iOS build. Use fresh logs/derived paths and proven commands in prior verification report. No duplicate lane or live factories. Verify five exits and frozen trees; preserve any failures and diagnose before rerun.
- [ ] **Step 3: Commit exact report/plan and continue real remote bootstrap.** Report rulings/costs and remaining gates. Next source map `/tmp/account-remote-bootstrap-exact-map-20260908.md`: break install-before-transport cycle; establish full rather than delta authority; Core-owned missing-archive preparation; crash-safe exact consumed-input/ACK bridge. This is the immediate following integration, not a reason to repeat completed owner/factory plans. No merge/push/submission yet.
