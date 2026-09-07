# Native Watch Session Stop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the actual phone Watch adapter synchronously stoppable with a trustworthy local accepted-work drain.

**Architecture:** Keep one platform-neutral PhoneWatchSession with an iOS-only WCSession operations/delegate bridge. Own one private AppSessionCallbackGate; admit callbacks before their MainActor hop and retain ownership through FIFO completion. Inject only native operations and immutable diagnostic observations, never mutable lifecycle authority.

**Tech Stack:** Swift 6, Swift Testing, WatchConnectivity, actual-source SwiftPM no-host harness, unsigned Xcode builds.

**Spec:** `docs/superpowers/specs/2026-09-07-native-watch-session-stop-design.md` (user approved 2026-09-07, delegated ordinary decisions until 19:00 Asia/Taipei).

## Global Constraints

- 版本維持 1.7.0 (13)，iOS 18、macOS 15、watchOS 11。
- 不改資料／備份／同步／Watch wire 格式、購買授權、語言、開發故事、100,000,000-byte 與 64 MiB 上限。
- 不修改 Watch 端 `KnitNoteWatch/Sync/WatchSession.swift` 的行為。
- 不改綁 store、不新增資料清理／inventory／seal 權威，不操作正式資料。
- 不新增 shipping target；不啟動 App host、真實 WCSession、CloudKit、Keychain 或 StoreKit。
- 本段不接入 App owner、UI generation 或 CloudAccountDomainLifecycle；不對已送出的 OS 傳輸作撤回／清空保證。
- Do not merge, push, sign, install, upload or submit. Stop starting work at 2026-09-07 19:00 Asia/Taipei; safely finish owned work and record remaining gates.
- Work only in existing `docs/cross-device-sync-design` linked worktree. Preserve old completed plan's workspace. Use this plan's own ledger and harness.

## File responsibilities

- Modify `KnitNote/WatchSync/PhoneWatchSession.swift`: neutral operations, adapter-owned stop/drain, native callback entries, thin iOS bridge. Preserve four calls plus definition of enqueueReceived and the existing shared FIFO contract.
- Create `Tests/KnitNoteAppTests/PhoneWatchNativeSessionLifecycleTests.swift`: real adapter behavioral tests; no live factory.
- Create `Tests/KnitNoteAppTests/PhoneWatchNativeSessionTestSupport.swift` only if fixtures merit separation: fake native endpoint, immutable observation events, deterministic joins.
- Modify `Tests/KnitNoteCoreTests/WatchConnectivityAdapterSourceContractTests.swift` only to add checks of iOS forwarding, never weaken existing behavioral requirements merely to pass.
- Create `docs/superpowers/reports/2026-09-07-native-watch-session-stop-verification.md`: final exact-candidate evidence and remaining limits.

### Task 1: Implement and exercise actual native adapter lifetime

**Files:** PhoneWatchSession and the test/support files listed above.

**Interfaces:**
- Consumes `AppSessionProducer.stopForSessionTransition()`, `waitForStoppedOperations() async throws`, existing `AppSessionCallbackGate`, FIFO, envelope and one-shot boxes.
- Produces `@MainActor WatchConnectivitySessionOperations` with `installDelegate(_ owner: PhoneWatchSession)`, `removeDelegate(ifOwnedBy owner: PhoneWatchSession)`; retain activate/context/send/enqueue/reachability signatures.
- Produces required-injection `PhoneWatchSession.init(session:isSupported:)` with optional immutable gate State observer; only iOS supplies zero-argument convenience init.
- Neutral nonisolated entries: `activationCompleted(activated:error:)`, `becameInactive()`, `deactivated()`, `reachabilityChanged(_:)`, `receivedApplicationContext(_:)`, `receivedMessage(_:)`, `receivedMessage(_:replyHandler:)`, `receivedUserInfo(_:)`, `transferCompleted(_:error:)`. iOS delegates synchronously forward without extra Task.

- [ ] **Step 1: Prepare isolated actual-source test target and baseline.** Create a unique directory using `mktemp -d /tmp/knitnote-native-watch-XXXXXX`; use apply_patch for its Package.swift, symlinks for Core, actual AppSessionProducerLifecycle.swift, AppSessionCallbackGate.swift, PhoneWatchSession.swift and the new tests. Record every symlink target and exact manifest in report. Use target name KnitNote and test target KnitNoteAppTests, macOS v15, sources directories Core/App and Core resources. No copies of production Swift. Do not run old producer harness as this task's evidence.

```swift
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NativeWatchLifecycle", defaultLocalization: "en",
    platforms: [.macOS(.v15)], targets: [
        .target(name: "KnitNote", path: "Sources/KnitNote",
            sources: ["Core", "App"], resources: [.process("Core/Resources")]),
        .testTarget(name: "KnitNoteAppTests", dependencies: ["KnitNote"])
    ])
```

- [ ] **Step 2: Write failing lifecycle tests before implementation.** An initial unavailable-type failure may establish the platform extraction RED, but subsequent behavior needs runtime RED (remove the relevant guard/drain temporarily and restore via patch before GREEN). Build a MainActor operations fake recording delegate owner identity and native calls. Use native callback completion or immutable gate observations as explicit events; never sleep/yield/empty Task fence to infer completion.

```swift
@Test @MainActor func stoppedAdapterRejectsQueuedActivation() async throws {
    let native = NativeWatchOperationsSpy()
    let adapter = PhoneWatchSession(session: native, isSupported: { true })
    var callbacks = 0
    adapter.onActivationCompleted = { _, _ in callbacks += 1 }
    adapter.deactivated()
    adapter.stopForSessionTransition()
    try await adapter.waitForStoppedOperations()
    #expect(callbacks == 0)
    #expect(native.activationCount == 0)
}
```

Implement `NativeWatchOperationsSpy` conforming the neutral operations: weak owner, reachability read count, activation count, context/message/userInfo arrays, retained native reply/error closures, synchronous install/activation callout hooks. Do not hide adapter behavior inside fake.

- [ ] **Step 3: Extract neutral adapter and add minimal lifetime implementation.** Keep imports/extension/delegate-only symbols conditional, preserve iOS caller. Use private gate and stopped flag. Operations detach only when delegate identity matches the owner. Throw an App-layer stopped error from context update; stopped void methods no-op and reachability false without native query. Close before nil callbacks and external removal; repeat stop safe.

```swift
func stopForSessionTransition() {
    guard !stopped else { return }
    stopped = true
    callbackGate.close()
    onReceivedEnvelope = nil
    onReachabilityChanged = nil
    onActivationCompleted = nil
    onTransferCompleted = nil
    session.removeDelegate(ifOwnedBy: self)
}
func waitForStoppedOperations() async throws {
    try await callbackGate.waitUntilClosedAndIdle()
}
private nonisolated func enqueueCallback(
    _ body: @escaping @MainActor @Sendable (PhoneWatchSession) -> Void
) {
    guard let token = callbackGate.begin() else { return }
    Task { @MainActor in
        defer { callbackGate.finish(token) }
        guard !stopped else { return }
        body(self)
    }
}
```

Use this pattern for notification and native reply/error arrival. Retained outgoing closures capture weak adapter and only admit on arrival, never hold a gate token waiting on external network. Recheck stopped after synchronous external callouts before subsequent native operation. A retained inbound reply closure checks stopped at use. For FIFO: begin before enqueue; finish enqueue token immediately if another drain exists; otherwise Task owns token until loop has dequeued everything. On stopped drain, discard without coordinator notification or replyBox.fail. Normal invalid/no-listener failure remains one-shot. No extra Task in iOS delegate forwarding.

- [ ] **Step 4: Complete deterministic regression matrix.** Cover normal activation/reachability/context/send/enqueue; all four raw input routes FIFO order and valid/invalid reply; one-shot reply/error competition; queued activation/inactive/deactivate/reachability/transfer and raw deliveries stopped before execution; onActivationCompleted and native install synchronous stop reentry; saved inbound reply after stop; outgoing reply/error before/after stop; repeated stop and every public stopped API; open wait throws; two waiters with one canceled; A stop after B delegate replacement leaves B live; late ingress cannot acquire ownership. All throwing/canceled test paths release and independently join owned work before any cleanup, including deliberately broken drain RED. Use in-memory fixtures where possible.

- [ ] **Step 5: Run focused and complete task harness plus source contracts, self-review and commit.** Commands below use an existing bounded subprocess runner; inspect it first. Request sandbox escalation for Swift caches only if needed. Capture command, exit status, complete log path, counts, warnings and source SHA; do not claim expected warnings pristine.

```sh
python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --no-parallel
# Above in new harness; below in worktree:
python3 /tmp/task4-run-bounded.py 600 arch -arm64 swift test --no-parallel --filter WatchConnectivityAdapterSourceContractTests
git diff --check
git add -- KnitNote/WatchSync/PhoneWatchSession.swift Tests/KnitNoteAppTests/PhoneWatchNativeSessionLifecycleTests.swift
git commit -m 'fix(watch): stop and drain native phone session callbacks'
```

Stage optional support/source-contract files explicitly only if changed. Report actual-source harness path, TDD failure mechanisms and cleanup proof, all passing command evidence, iOS-only unchecked assumptions, full commit SHA and concerns. Controller runs task review and fixes before final branch review.

### Task 2: Freeze and verify the reviewed candidate (controller-owned)

**Files:** Create verification report listed above; update plan checkboxes only after evidence.

**Interfaces:** Consumes reviewed Task 1 SHA and harness inventory. Produces immutable local verification report, not release approval.

- [ ] **Step 1: Complete final independent review of this subplan's full diff and resolve load-bearing findings.** Use baseline `5b0dd6c` (the subplan boundary, not the unrelated ancestral feature history). Check bridge forwarding, callback registration races, owner replacement, cancellation, tests and deferred findings. Record rulings and exact review range.
- [ ] **Step 2: Freeze HEAD and run full Core, combined actual-source no-host tests, unsigned macOS and iOS builds serially.** Extend the new harness inventory with existing producer test sources/dependencies by symlink, not copies, so full local evidence covers existing 34 producer tests and new native tests. Inspect the old harness manifest and symlinks only as routing, not its completed SDD. Do not include App host. Confirm remaining deadline before each expensive run; if insufficient, record pending rather than downgrade gate.

```sh
python3 /tmp/task4-run-bounded.py 3600 arch -arm64 swift test --no-parallel
# Above at worktree, then new combined harness:
python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --no-parallel
python3 /tmp/task4-run-bounded.py 900 xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/native-watch-stop-macos-derived CODE_SIGNING_ALLOWED=NO build-for-testing
python3 /tmp/task4-run-bounded.py 900 xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/native-watch-stop-ios-derived CODE_SIGNING_ALLOWED=NO build
git status --short
git rev-parse HEAD
```

- [ ] **Step 3: Record and commit evidence only after inspecting full summaries and diagnostics.** Report exact frozen SHA, command/workdir/log hash/exit/count, harness provenance, reviewed range, warnings, version identity and missing live/device/owner/release gates. Docs-only final commit must preserve tested code/test/PBX trees. Preserve local branch; pause this automation when complete or deadline reached. Do not delete evidence without preserving durable report.

## Plan self-review

All spec sections map to Task 1 (behavior/ownership/bridge/tests) or Task 2 (frozen validation/evidence). No Task 2 production edits are intended; any review fix goes back through the implementer and affected tests before freezing. Task 1 is deliberately one reviewable unit because gate admission, FIFO ownership, callbacks and stop share one adapter invariant. Splitting those would create a misleading intermediate stop guarantee.
