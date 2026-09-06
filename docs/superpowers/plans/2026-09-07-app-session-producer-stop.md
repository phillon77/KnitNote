# App Session Producer Stop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the existing inbox and phone Watch producers irreversible stop-and-drain boundaries, then compose them with the already-verified store revoke/drain API.

**Architecture:** App-owned producers keep native Task handles through termination and reject late callbacks after synchronous closure. A fixed producer group coordinates one immutable store; it does not implement account identity, full UI freeze or CloudKit lifecycle. Actual-source no-host tests exercise App code with isolated external adapters.

**Tech Stack:** Swift6, MainActor, Swift Testing, Combine, SwiftUI, existing Core store/driver/Watch protocols, macOS actual-source SwiftPM harness and unsigned Xcode builds.

**Spec:** `docs/superpowers/specs/2026-09-07-app-session-producer-stop-design.md`; parent `docs/superpowers/specs/2026-09-06-cloud-sync-app-session-lifecycle-design.md`.

## Global Constraints

- Version1.7.0 (13), iOS18/macOS15/watchOS11 deployment floors unchanged.
- No data/backup/sync/Watch wire format, purchase authorization, language or development-story changes; retain100,000,000-byte and64MiB limits.
- No live CloudKit/Keychain/StoreKit/WatchConnectivity execution in tests. Use explicit UUID fixture roots and UserDefaults suites; no standard defaults writes, real accounts, installs or App hosts.
- No store rebinding, source deletion, new cleanup/inventory/seal authority, or late operation retry onto another session.
- Stop is synchronous/irreversible/idempotent; successful drain proves accepted local Task termination only. A cancelled drain caller must not cancel shared work; cancellation during join may be reported after joined tasks terminate.
- No synchronous lock across await; no sleep/arbitrary yield/time budget as a correctness assertion. Existing production timers remain timers, but tests use event/callback observations and real termination.
- No copied/rewritten App sources in the no-host harness; symlink exact source files. Keep source identities and test logs; cleanup fixture roots only after releasing/joining every owned Task.
- Implementers do not stage/commit or run full Core/platform commands. Controller reviews actual precommit diffs, commits approved changes, runs one frozen final validation after the whole-plan review, then updates report after all commands end.
- Execute Tasks1→2→3 sequentially: PBX and shared fixtures/harness references overlap. Preserve the active SDD workspace and all evidence.
- User delegated routine overnight decisions, not missing real-product acceptance. No merge/push/sign/install/upload/submission/live activation. Stop starting new work at2026-09-07 08:00Taipei; finish already accepted native work and leave truthful evidence.

## Shared file map and test harness

`AppSessionProducerLifecycle.swift` owns the small protocol/error only. `PatternBackupReminderPresenter.swift` holds the class extracted from RootView, with only the review-required reentry bookkeeping described below. Existing producers keep their responsibilities and own stop state. Task2 `AppSessionCallbackGate.swift` tracks Combine work admitted before its MainActor hop and accepted timer lifetimes. `AppSessionProducerGroup.swift` contains only fixed local stop/drain composition.

New App test files are `AppSessionProducerFixtures.swift`, `PatternInboxProcessorSessionTests.swift`, `PhoneWatchSessionProducerTests.swift`, `AppSessionProducerGroupTests.swift`; add each to existing KnitNoteAppTests PBX source membership. Production files belong to KnitNote App only, not the Watch app. No new shipping target or entitlement.

Task1 creates a unique preserved directory using `mktemp -d /tmp/knitnote-app-producer-XXXXXX`; record the absolute returned path in its report for subsequent tasks/controller. Do not reuse another plan's scratch. Use apply_patch for its Package.swift:

```swift
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AppSessionProducerTests", defaultLocalization: "en",
    platforms: [.macOS(.v15)], targets: [
        .target(name: "KnitNote", path: "Sources/KnitNote",
            sources: ["KnitNoteCore", "App"],
            resources: [.process("KnitNoteCore/Resources")]),
        .testTarget(name: "KnitNoteAppTests", dependencies: ["KnitNote"],
            path: "Tests/KnitNoteAppTests")
    ])
```

Create only directories and symlinks with shell tools; verify each target with readlink before testing. `Sources/KnitNote/KnitNoteCore` links this checkout's entire `Sources/KnitNoteCore`; `App` contains individual links to current-task App sources listed below, never RootView or KnitNoteApp. Test folder links only this plan's actual App test files. Do not compile live CloudKit development tests. Task2 adds exact entitlement source links `EntitlementCoordinator.swift`, `PurchaseService.swift`, `StoreKitPurchaseService.swift`, `KeychainTrialStore.swift` (declarations compile, no live factory invoked), and PhoneWatchSyncCoordinator. Task3 adds group source/test. If actual symbol dependencies require an additional existing source, inspect it first and record a controller scope ruling; never stub a production type to hide missing code.

From the recorded harness directory run `python3 /tmp/task4-run-bounded.py 600 arch -arm64 swift test --filter PatternInboxProcessorSessionTests` for Task1, the named Task2 filters below for Task2, and the unfiltered package for Task3, with unique no-clobber logs and scoped cache permission when needed. The inspected runner is reused as tooling, not test evidence. Cache denial is environment failure, not behavioral RED. No heavy tests in parallel.

## Review-driven amendments before downstream execution

These requirements supersede the minimal task sketches where they differ; they do not claim implementation or acceptance is complete.

- Task1 must retain cancelled/replaced notice tasks until their actual completion, not just the current handle at stop. A narrowly injected notice-delay closure may support deterministic cancellation-ignoring tests; production remains the same three-second timer.
- Task1 must handle synchronous `@Published` and presenter callouts that reenter stop. Restore stopped processor state after callouts and prohibit subsequent task creation. Presenter bookkeeping may depart from verbatim extraction only to preserve normal accept/dismiss/close semantics and newer synchronous user actions. An interrupted import cannot unconditionally roll back a later dismissal/settings request or any persistent reminder-history write. Add the corresponding real Combine regressions.
- Task2's existing gate must register all three timer kinds before task creation and finish their tokens only at actual task termination, including retired/replaced timers. The stop-time current-handle snapshot is not complete by itself. Preserve the serial tail; use a narrow production-equivalent sleep injection only if needed to prove retired-timer lifetime deterministically. Test synchronous transport reentry during activation/publication and reject subsequent work after closure.
- Task2 gate `waitUntilClosedAndIdle()` is `@MainActor`; synchronous begin/close/finish remain thread-safe. Actual production drain callers already use MainActor, and direct tests observe same-actor waiter registration before the first suspension. Never substitute an unrelated empty task for registration or completion.
- Ordinary Task2 cases retain `.configured(screenshotMode: true)`. The expiry/replacement fixture instead uses the actual entitlement coordinator's existing injected purchase/trial initializer, in-memory protocol fakes, a fixed `TrialRecord`/clock, an explicitly finished purchase-update stream, and real `prepare()`. A permanently legacy-paid screenshot fixture cannot exercise trial expiry. No live factories or widened purchase authorization APIs are allowed.

Costs: additional internal ownership/presenter bookkeeping and controlled fixtures; possible actor hop for future non-UI waiters. Data formats, production timer durations, authority and user-history semantics remain unchanged. Controller rulings and review evidence are retained in this plan's SDD workspace and must be summarized in the durable final report.

### Task 1: Irreversible inbox producer closure and actual-source tests

**Files:**
- Create `KnitNote/App/AppSessionProducerLifecycle.swift`.
- Create `KnitNote/Patterns/PatternBackupReminderPresenter.swift`; remove only that class from `KnitNote/App/RootView.swift`.
- Modify `KnitNote/Patterns/PatternInboxProcessor.swift` and `KnitNote.xcodeproj/project.pbxproj`.
- Create `Tests/KnitNoteAppTests/AppSessionProducerFixtures.swift` and `PatternInboxProcessorSessionTests.swift`.

**Interfaces:**
- Consumes actual `PatternInboxDriver(processing:)`, `PatternInboxProcessing`, `PatternImportOutcome`, `BackupHistory(defaults:)`.
- Produces `AppSessionProducer`, `AppSessionProducerDrainError`, and `PatternInboxProcessor.init(driver: PatternInboxDriver, backupReminderPresenter: PatternBackupReminderPresenter)`, retaining existing `init(store:backupReminderPresenter:)` as delegation.
- Produces shared test `ProducerTestInboxProcessing` actor with actual PatternInboxProcessing methods, buffered `waitUntilProcessStarts()`, cancellation-ignoring release-once `release()`, configurable `Result<PatternImportOutcome, Error>`, and call counts; plus fixture constructor/snapshot helpers under unique `ProducerTest` names.

- [ ] Move the presenter verbatim, add PBX production membership, prepare the actual-source harness and tests. Import SwiftUI/Combine as needed in the actual files rather than copying definitions into harness. The moved presenter retains identical methods and BackupHistory semantics.
- [ ] Define the common contract:

```swift
enum AppSessionProducerDrainError: Error, Equatable { case producerStillActive }
@MainActor protocol AppSessionProducer: AnyObject {
    func stopForSessionTransition()
    func waitForStoppedOperations() async throws
}
```

- [ ] Add new tests before stop implementation. A controlled processing actor returns one item from pendingItems and suspends inside process using a checked continuation that deliberately ignores cancellation. Buffer its start event and release flag so early release is safe. Use real driver, not a mocked driver. Construct the item exactly as:

```swift
let item = PatternInboxItem(originalFilename: "fixture.pdf",
    receivedAt: Date(timeIntervalSince1970: 1), origin: .shareExtension,
    targetProjectID: nil, stagedFilename: "fixture.pdf")
```

For success return `.created(patternID: UUID())`, for selection `.needsSelection(itemID: item.id, candidatePatternIDs: [UUID()])`, for failure throw a named test-only error. Normal driver turns the latter into a failure update; stop must prevent its publication too. Use one item so successful process can finish without another cancellation boundary obscuring the late result.

Essential test sequence (fixture helper constructs explicit defaults/presenter/actor/processor and owns cleanup):

```swift
processor.processPending()
await processing.waitUntilProcessStarts()
processor.stopForSessionTransition()
let entered = AsyncStream<Void>.makeStream()
var drained = false
let waiter = Task { @MainActor in
    entered.continuation.yield(())
    try await processor.waitForStoppedOperations()
    drained = true
}
var observed = entered.stream.makeAsyncIterator()
_ = await observed.next()
#expect(!drained)
await processing.release()
try await waiter.value
#expect(drained)
#expect(processor.pendingSelection == nil)
#expect(processor.failure == nil)
#expect(processor.notice == nil)
#expect(!presenter.isPresented)
```

Protect all throwing setup after tasks start with release/cancel/join catch cleanup, never delete the defaults suite or fixture first. Add separate tests for normal pre-stop success notification via actual published event observation, open wait error, repeated stop, all stopped entry methods leaving processing counts unchanged, two uncancelled waiters, and cancelled waiter isolation. Once stopped, `dismissFailure()` may harmlessly remain nil; no new task is created.
- [ ] Run `PatternInboxProcessorSessionTests` RED; distinguish missing-API compile RED from behavioral RED. After adding compiling stop skeleton, capture real late-result/early-drain failure before adding guards/join behavior. Do not manufacture pass with an arbitrary delay.
- [ ] Implement minimal producer ownership:

```swift
private var isStopped = false
private var stoppedTasks: [Task<Void, Never>] = []

func stopForSessionTransition() {
    guard !isStopped else { return }
    isStopped = true
    stoppedTasks = [operationTask, noticeTask].compactMap { $0 }
    pendingSelection = nil
    failure = nil
    notice = nil
    stoppedTasks.forEach { $0.cancel() }
}

func waitForStoppedOperations() async throws {
    guard isStopped else { throw AppSessionProducerDrainError.producerStillActive }
    try Task.checkCancellation()
    for task in stoppedTasks { await task.value }
    try Task.checkCancellation()
}
```

Class conforms to AppSessionProducer. Guard public entry mutation and `startOperation`, `apply`, post-await catch error publication, and notice continuation with `!isStopped`; never reopen. Keep task handles saved even when existing defer clears operationTask. New driver initializer assigns the actual driver and presenter; existing store initializer delegates using `PatternInboxStoreAdapter(store:)`.
- [ ] Fresh no-host suite GREEN and Core affected `arch -arm64 swift test --filter 'PatternInbox|BackupHistory|BackupSettingsViewContract|Task8XcodeProjectMembership'`; record exact selected counts (a nonexistent selector is not coverage). Read source contract tests before changing structure; preserve substantive assertions.
- [ ] Self-review, exact source/test/PBX hashes, raw log paths/hashes/exits/durations, harness path+every symlink target, warnings and limitations in task report. Independent precommit review then controller commit `feat(sync): stop and drain inbox session work`.

### Task 2: Explicit Watch transport and closed callback/queue boundary

**Files:**
- Modify `KnitNote/WatchSync/PhoneWatchSyncCoordinator.swift`, `KnitNote/App/KnitNoteApp.swift`, PBX.
- Create `KnitNote/App/AppSessionCallbackGate.swift` and add its actual-source harness link and App PBX membership.
- Modify shared `Tests/KnitNoteAppTests/AppSessionProducerFixtures.swift` only for needed transport helpers.
- Create `Tests/KnitNoteAppTests/PhoneWatchSessionProducerTests.swift`.

**Interfaces:**
- Consumes Task1 `AppSessionProducer`/error and recorded harness path. Add actual entitlement files specified in shared harness section.
- Produces coordinator conformance with `init(projectStore: JSONProjectStore, entitlementCoordinator: EntitlementCoordinator, transport: any WatchConnectivityTransport, applicationSupportRoot: URL? = nil, languageCode: @escaping () -> String, now: @escaping () -> Date)`; retain existing defaults for languageCode/now, remove only transport default/factory.
- Shared `ProducerTestWatchTransport` implements all actual WatchConnectivityTransport properties/methods, records envelopes/activation counts, and lets tests retain callback values before stop. It never calls system WatchConnectivity.
- Produces thread-safe internal `AppSessionCallbackGate.begin() -> UUID?`, `finish(_ token: UUID)`, `close()`, `waitUntilClosedAndIdle() async throws`. Gate owns issued tokens, rejects foreign/duplicate completion, and independently cancellable waiters. This is required because Combine sink callbacks can enqueue MainActor Tasks before stop without having reached that actor yet.

- [ ] Remove coordinator outer `#if os(iOS)` only after making transport mandatory; do not change PhoneWatchSession's platform guard. Actual iOS App initializer supplies `transport: PhoneWatchSession()`; no macOS App construction/start. Existing screenshot `start` gate remains, but this is not a claim of complete screenshot factory isolation (future owner gate).
- [ ] Tests use a real isolated JSONProjectStore at `fixtureRoot/A/Live/projects.json`, explicit Watch applicationSupportRoot `fixtureRoot/A/Watch`, fixed now/language, and `EntitlementCoordinator.configured(screenshotMode: true)`; no live default factory invocation. Add `.legacyPaidOwner` fixture store project through `try store.add(name: "A")` and derive actual counter IDs.
- [ ] Capture normal pre-stop snapshot and command behavior as baseline; an awaited `.command(WatchCounterCommand(projectID:counterID:operation:.increment))` must increment exactly once and duplicate replay not increment again. Keep actual ledger/prepared persistence; no fake store.
- [ ] Add deterministic queued-old-command test using synchronous ingress, not Task timing:

```swift
coordinator.start()
let ingress = try #require(transport.onReceivedEnvelope)
let project = try #require(store.projects.first)
let command = WatchCounterCommand(projectID: project.id,
    counterID: project.counters[0].id, operation: .increment)
let before = try ProducerTestDiskSnapshot.capture(root: fixtureRoot)
let sentBefore = transport.sentEnvelopes
ingress(.command(command), nil) // enqueue happens synchronously on MainActor
coordinator.stopForSessionTransition() // no await lets queued handle run first
try await coordinator.waitForStoppedOperations()
#expect(try ProducerTestDiskSnapshot.capture(root: fixtureRoot) == before)
#expect(transport.sentEnvelopes == sentBefore)
```

`ProducerTestDiskSnapshot.capture` throws on enumeration/read failure, records relative paths/type plus exact regular-file Data, and rejects symlinks rather than following them. Snapshot after start's legitimate recovery writes, before queued command. Use exclusive UUID root including all sibling work paths; clean after joins.
- [ ] Also retain and invoke old activation/reachability/transfer/ingress callbacks after stop; transport's four callback properties must be nil, no new activation/send/retry or disk change. Exercise scheduled retry/expiry cancellation by triggering their real setup callbacks before stop, then await their owned Tasks. Trigger a store/entitlement publication before stop to queue a Combine callback, stop in the same actor turn and verify no late send. Add direct gate tests: admitted token keeps closed wait pending, closure rejects begin, foreign/duplicate finish does not drain another token, one finish broadcasts to two registered waiters, cancelled waiter does not remove native work/peer. Add start/receive/publish-after-stop, repeated stop, open wait error, two waiter and cancellation-isolation checks. No 2-second wait assertions or sleep probes.
- [ ] Add a cancellation-isolated gate using a short NSLock with no await under it. The full state transition shape is:

```swift
final class AppSessionCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var tokens: Set<UUID> = []
    private var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    func begin() -> UUID? {
        lock.withLock {
            guard !closed else { return nil }
            let id = UUID(); tokens.insert(id); return id
        }
    }
    func close() { lock.withLock { closed = true } }
    func finish(_ token: UUID) {
        let ready: [AsyncStream<Void>.Continuation] = lock.withLock {
            guard tokens.remove(token) != nil, tokens.isEmpty else { return [] }
            let ready = Array(waiters.values); waiters.removeAll(); return ready
        }
        ready.forEach { $0.yield(()); $0.finish() }
    }
    func waitUntilClosedAndIdle() async throws {
        try Task.checkCancellation()
        let id = UUID()
        let event = AsyncStream<Void>.makeStream()
        let wait = try lock.withLock {
            guard closed else { throw AppSessionProducerDrainError.producerStillActive }
            guard !tokens.isEmpty else { return false }
            waiters[id] = event.continuation
            return true
        }
        defer { _ = lock.withLock { waiters.removeValue(forKey: id) } }
        if wait {
            var iterator = event.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        try Task.checkCancellation()
    }
}
```

Gate UUID tokens are instance-owned by membership; an unrelated instance's token is absent. Finish resumes continuations outside the lock. Preserve close-before-wait contract; no finish call grants data authority. Tests cover cancellation racing registration/finish. Do not use public mutable task lists or synchronously block MainActor to simulate queued work.
- [ ] Run no-host `PhoneWatchSessionProducerTests` RED on compiling existing behavior; then add closed flag and saved task list:

```swift
func stopForSessionTransition() {
    guard !isStopped else { return }
    isStopped = true
    callbackGate.close()
    projectSubscription?.cancel()
    entitlementSubscription?.cancel()
    projectSubscription = nil
    entitlementSubscription = nil
    transport.onReceivedEnvelope = nil
    transport.onActivationCompleted = nil
    transport.onReachabilityChanged = nil
    transport.onTransferCompleted = nil
    stoppedTasks = [serialTask, activationRetryTask,
        reliableSnapshotRetryTask, entitlementExpiryTask].compactMap { $0 }
    stoppedTasks.forEach { $0.cancel() }
}
```

Use Task1 wait implementation, additionally `try await callbackGate.waitUntilClosedAndIdle()` before final cancellation check. Capture callbackGate strongly in both Combine sink closures; call begin before creating Task, and finish in the Task's defer even if self is gone:

```swift
.sink { [weak self, callbackGate] _ in
    guard let token = callbackGate.begin() else { return }
    Task { @MainActor [weak self] in
        defer { callbackGate.finish(token) }
        guard let self, !self.isStopped else { return }
        self.publishLatestSnapshotIfChanged()
    }
}
```

Apply the same envelope to the entitlement sink while preserving its verifiedSnapshot guard and original expiry/recovery/publication calls. Guard public start/publish/receive path, transport callback entries, post-previous.value queue handling, timer continuations, activation/retry/recovery/send/publication helpers. A stopped receive returns without appending new serial work: make private enqueue return optional Task and return nil when closed; receive only awaits a nonnil Task. Existing ingress `self?.enqueue(envelope, reply: reply)` remains synchronous. Preserve original command handlers, language/entitlement/ledger and reliable-transfer semantics.
- [ ] Fresh no-host Task1+Task2 suites GREEN; Core affected `arch -arm64 swift test --filter 'Watch|PatternInboxAppContract|BackupSettingsViewContract'`. Do not alter source-contract assertions to weaken ingress synchronous ordering or existing failure semantics; if exact formatting changes require a scanner update, preserve actual relationships and report it for review.
- [ ] Report source/test/PBX/harness identities, RED/GREEN outputs, native task ownership/self-review; independent precommit review then controller commit `feat(sync): stop stale Watch session callbacks and queued work`.

### Task 3: Fixed local producer group and mixed A/B acceptance

**Files:**
- Create `KnitNote/App/AppSessionProducerGroup.swift`, `Tests/KnitNoteAppTests/AppSessionProducerGroupTests.swift`, durable `docs/superpowers/reports/2026-09-07-app-session-producer-stop-verification.md`.
- Modify PBX and shared test fixtures only as needed for real-store mixed setup.

**Interfaces:**
- Consumes `JSONProjectStore.revokeSessionWrites()`, `waitForTrackedBackgroundWritesAfterRevocation() async throws`, Task1/2 protocol and actual producers.
- Produces `@MainActor final class AppSessionProducerGroup: AppSessionProducer`, initializer `(store: JSONProjectStore, producers: [any AppSessionProducer])`. No App or CloudAccountDomainLifecycle caller in this task.

- [ ] Add actual mixed A/B tests. A uses actual inbox driver with controlled processing, actual Watch coordinator with transport spy, and actual store; B has independently initialized root/store and a full snapshot. Start A processing and observe process boundary; synchronously enqueue old Watch command, then group.stop. Before any await a new A `store.add(name:)` must throw StoreSessionAccessError.revoked. B remains writable/unrevoked and byte-identical until its explicit later normal edit.
- [ ] Group waiter entry uses buffered MainActor registration observation as Task1; it remains pending until controlled inbox processing is released, even though Watch queue has stopped. After release await actual group result, assert no A late UI/watch output, exact A/B evidence, and `try bStore.add(name: "B remains active")` succeeds. Native sources are not copied or deleted. Add open/error, empty producers, repeat stop, two waiter/cancel isolation tests; use same cleanup ownership discipline.
- [ ] Independently prove the group's store-drain delegation is necessary, not only its producer loop. Start real `store.importPattern(from:projectID:)` with existing `PatternFileService(root:copyFile:)` injection; the copy callback records a buffered start event and blocks only the actual detached native worker. Use valid one-page PDF or PNG fixture bytes and a nonblocking MainActor event observer. With group producers empty, stop and enter group wait while native copy remains blocked: assert wait has not ended. Release copy, await the actual `StoreSessionAccessError.revoked` result and group completion; assert no pattern publication, original source bytes retained and independent B unchanged. A worker that exits before its hook must emit a terminal false observation; failure cleanup releases and joins before fixture deletion. Do not force unchanged temporary-directory inventory across native cleanup; compare authoritative store/source/B evidence and document native directory outcomes. This case must fail at the early-completion assertion if the group's store wait is omitted, with native work still released/joined afterward.
- [ ] Compile missing-API RED, then behavioral RED with a minimal early-return stub; implement:

```swift
@MainActor final class AppSessionProducerGroup: AppSessionProducer {
    private let store: JSONProjectStore
    private let producers: [any AppSessionProducer]
    private var isStopped = false
    init(store: JSONProjectStore, producers: [any AppSessionProducer]) {
        self.store = store
        self.producers = producers
    }
    func stopForSessionTransition() {
        guard !isStopped else { return }
        isStopped = true
        store.revokeSessionWrites()
        for producer in producers { producer.stopForSessionTransition() }
    }
    /// Waits for these registered local producers and store operations only.
    /// Success is not complete App freeze, durable health or cleanup authority.
    func waitForStoppedOperations() async throws {
        guard isStopped else { throw AppSessionProducerDrainError.producerStillActive }
        try Task.checkCancellation()
        for producer in producers { try await producer.waitForStoppedOperations() }
        try await store.waitForTrackedBackgroundWritesAfterRevocation()
        try Task.checkCancellation()
    }
}
```

- [ ] Fresh entire no-host App producer package GREEN (no filter, all linked plan test files); Core affected `arch -arm64 swift test --filter 'StoreSession|StoreBackground|StorePatternSession|StoreMediaSession|PatternInbox|Watch|BackupSettingsViewContract'` GREEN. Report all counts, real exits/durations, expected diagnostics and unchanged formats/boundaries; full Core/platform pending until controller evidence.
- [ ] Independent precommit review, controller commit `feat(sync): compose local session producer termination`.

## Final controller verification and handoff

- [ ] One complete current-plan BASE delta review plus concrete affected App/native callers, with deferred findings. One consolidated final fix wave and scoped rereview; no repeat historical completed-plan implementation.
- [ ] Freeze HEAD and all tracked contents; record Sources, KnitNote/App, KnitNote/Patterns, KnitNote/WatchSync, Tests trees and PBX blob. Verify harness symlinks resolve to exact candidate. Serial complete Core `arch -arm64 swift test --no-parallel` bound3600, complete no-host harness `arch -arm64 swift test --no-parallel` bound900, unsigned macOS build-for-testing and generic iOS build bound900 each, unique no-clobber logs. Use `/tmp/app-session-producer-macos-derived` and `/tmp/app-session-producer-ios-derived`.
- [ ] No tracked docs or HEAD changes during any final command. After all native processes terminate, update durable report with exact evidence, warnings, limitations and remaining full owner/identity/UI/cloud/Watch/device/store gates; docs-only commit and source identity readback.
- [ ] Keep existing branch/worktree/evidence under delegated routine authority; no merge/push or activation. At08:00 stop starting new work, safely join accepted work, pause existing heartbeat and leave truthful handoff. Partial or timed-out validation is not a pass.

## Self-review

- [x] Every local spec responsibility maps to Task1,2 or3; full owner/account/remote Watch/activation deliberately outside this spec.
- [x] Shared protocol/error/signatures and mandatory transport agree; existing iOS caller supplied explicitly; no macOS live Watch construction.
- [x] Source separation belongs to producer testing task, no standalone scaffolding task; no cloned production definitions.
- [x] Same MainActor turn proves queue-before-stop order; buffered events prove inbox accepted work; no synchronous blocker across actor awaits.
- [x] Cancellation policy is explicit and does not promise prompt cancelled-waiter return. Fixed group errors cannot be mislabeled health/authority.
- [x] Test cleanup joins precede fixture removal; all selected suite names are actual new or inspected existing declarations.
