# Backup Session Drain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close backup admission on store revocation and await actual termination of accepted backup work without manufacturing account-switch authority.

**Architecture:** A MainActor-owned tracker belongs to one immutable store instance. It tracks accepted operations and their work-root ownership, closes monotonically, and asynchronously wakes cancellable waiters only after all operations end. Existing install/reload/rollback/commit transactions remain the authority for durable outcomes.

**Tech Stack:** Swift 6, Foundation, Swift Testing, KnitNoteCore Swift package, explicit Xcode source memberships.

**Spec:** `docs/superpowers/specs/2026-09-06-backup-session-drain-design.md` (user approved).

## Global Constraints

- Version **1.7.0 (13)**; baseline `140189cecd54a8f9a7bd8a5120b28b5fb278074e`.
- Work only in `.worktrees/cross-device-sync-design`, branch `docs/cross-device-sync-design`; verify clean/overlapping changes before editing.
- No backup/sync journal/publication format change, purchase-policy change, language change or account-path rebinding.
- Preserve **100,000,000-byte** file/authority and **64 MiB** journal metadata limits.
- No live CloudKit/Keychain/Watch/App factory activation, signing, installation, real-user migration/cleanup, merge, push, upload or submission. Preserve worktree and evidence.
- No lock across await; cancellation and elapsed time are not termination evidence. No general freeze receipt, seal, inventory capture, automatic recovery or cleanup is authorized by this tracker.
- Preserve `KnitNoteBackupService.install`, `rollback`, `commit` formats/order and successful restore semantics, including commit's deferred-cleanup artifacts.
- Tests use isolated temporary fixtures. Historical 819-test parallel success and prior full-Core/platform results do not validate this new implementation.

---

## File map and task dependency

1. Create `Sources/KnitNoteCore/Backup/BackupSessionWorkTracker.swift` and `Tests/KnitNoteCoreTests/BackupSessionWorkTrackerTests.swift`: one-store admission/ownership/waiter mechanics, no service calls.
2. Modify `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`, `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`, and minimally `KnitNote.xcodeproj/project.pbxproj`: actual backup lifetimes and integration tests. Create `docs/superpowers/reports/2026-09-06-backup-session-drain-verification.md` with frozen evidence.

Task 2 consumes Task 1; run sequentially. Tracker tests and store integration can be rejected independently, so each gets its own review gate. No other subsystem is part of this plan.

## Task 1: One-store closed-and-idle tracker

**Files:** create the tracker and tracker test files listed above.

**Interfaces produced:** internal `@MainActor final class BackupSessionWorkTracker`; nested opaque `Token`; `begin(protecting root: URL) throws -> Token`, `finish(_ token: Token)`, `close()`, `protects(_ artifact: URL) -> Bool`, `waitUntilClosedAndIdle() async throws`. Public payload-free `BackupSessionDrainError: Error, Equatable, Sendable` with case `sessionStillActive`. Existing `StoreSessionAccessError.revoked` remains the admission error.

- [ ] **Step 1: Write the failing behavioral tests.**

```swift
import Foundation
import Testing
@testable import KnitNoteCore

@Suite @MainActor struct BackupSessionWorkTrackerTests {
    @Test func openWaitIsRejectedAndCloseIsIrreversible() async throws {
        let tracker = BackupSessionWorkTracker()
        await #expect(throws: BackupSessionDrainError.sessionStillActive) {
            try await tracker.waitUntilClosedAndIdle()
        }
        tracker.close()
        tracker.close()
        #expect(throws: StoreSessionAccessError.revoked) {
            _ = try tracker.begin(protecting: URL(fileURLWithPath: "/tmp/unused-backup-root"))
        }
        try await tracker.waitUntilClosedAndIdle()
    }

    @Test func duplicateOrForeignFinishCannotReleaseAnotherOperation() async throws {
        let a = BackupSessionWorkTracker()
        let b = BackupSessionWorkTracker()
        let root = URL(fileURLWithPath: "/tmp/unused-backup-root")
        let first = try a.begin(protecting: root)
        let second = try a.begin(protecting: root)
        let foreign = try b.begin(protecting: root)
        a.close()
        a.finish(first)
        a.finish(first)
        a.finish(foreign)
        #expect(a.protects(root.appendingPathComponent("Staged-owned")))
        #expect(!a.protects(URL(fileURLWithPath: "/tmp/unused-backup-root-other")))
        let ready = AsyncStream<Void>.makeStream()
        var completed = false
        let waiter = Task { @MainActor in
            ready.continuation.yield(())
            try await a.waitUntilClosedAndIdle()
            completed = true
        }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(!completed)
        a.finish(second)
        try await waiter.value
        #expect(completed)
        #expect(!a.protects(root))
        b.finish(foreign)
    }

    @Test func cancelledWaiterDoesNotDrainWorkOrCancelPeer() async throws {
        let tracker = BackupSessionWorkTracker()
        let root = URL(fileURLWithPath: "/tmp/unused-backup-root")
        let work = try tracker.begin(protecting: root)
        tracker.close()
        let ready = AsyncStream<Void>.makeStream()
        let cancelled = Task { @MainActor in
            ready.continuation.yield(())
            try await tracker.waitUntilClosedAndIdle()
        }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(tracker.protects(root))
        let peer = Task { try await tracker.waitUntilClosedAndIdle() }
        tracker.finish(work)
        try await peer.value
    }
}
```

These paths perform no disk writes. The integration tests below own actual temporary roots. The event yield immediately precedes the same-actor wait call; do not replace readiness with sleep or assume Task creation proves execution.

- [ ] **Step 2: Run RED.**

```sh
swift test --filter BackupSessionWorkTrackerTests
```

Record intended missing-type/API errors separately from sandbox/toolchain errors. Then implement, without adding test-only public counters or a forgeable drain receipt.

- [ ] **Step 3: Implement the tracker.**

```swift
import Foundation

public enum BackupSessionDrainError: Error, Equatable, Sendable {
    case sessionStillActive
}

@MainActor final class BackupSessionWorkTracker {
    struct Token: Hashable {
        fileprivate let owner: UUID
        fileprivate let id: UUID
    }
    private let owner = UUID()
    private var closed = false
    private var operations: [Token: URL] = [:]
    private var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]

    func begin(protecting root: URL) throws -> Token {
        guard !closed else { throw StoreSessionAccessError.revoked }
        let token = Token(owner: owner, id: UUID())
        operations[token] = root.standardizedFileURL
        return token
    }

    func close() { closed = true }

    func finish(_ token: Token) {
        guard token.owner == owner,
              operations.removeValue(forKey: token) != nil,
              closed, operations.isEmpty else { return }
        let pending = Array(waiters.values)
        waiters.removeAll()
        for continuation in pending {
            continuation.yield(())
            continuation.finish()
        }
    }

    func protects(_ artifact: URL) -> Bool {
        let path = artifact.standardizedFileURL.pathComponents
        return operations.values.contains { path.starts(with: $0.pathComponents) }
    }

    func waitUntilClosedAndIdle() async throws {
        try Task.checkCancellation()
        guard closed else { throw BackupSessionDrainError.sessionStillActive }
        guard !operations.isEmpty else { return }
        let id = UUID()
        let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        waiters[id] = signal.continuation
        defer {
            waiters.removeValue(forKey: id)
            signal.continuation.finish()
        }
        for await _ in signal.stream {
            try Task.checkCancellation()
            return
        }
        throw CancellationError()
    }
}
```

The protected root is always the service's immutable `workRoot`. Conservatively protect its entire subtree while any accepted backup operation runs, because staging may allocate its UUID after dispatch. This intentionally leaves unrelated owned artifacts for a subsequent cleanup request; it is not ownership permission to delete anything. Existing filesystem/symlink validation stays mandatory in the store.

- [ ] **Step 4: GREEN, cancellation-before-registration and mutation checks.**

Add this test before running GREEN:

```swift
@Test func cancellationBeforeEntryCannotReturnSuccess() async throws {
    let tracker = BackupSessionWorkTracker()
    tracker.close()
    let waiter = Task { @MainActor in
        withUnsafeCurrentTask { $0?.cancel() }
        try await tracker.waitUntilClosedAndIdle()
    }
    await #expect(throws: CancellationError.self) { try await waiter.value }
}
```

Run `swift test --filter BackupSessionWorkTrackerTests`. Temporarily replace the waiting portion of `waitUntilClosedAndIdle` with an immediate return after its closed-state check, and prove the duplicate/foreign/two-operation test fails at the first `!completed` assertion; restore exactly and rerun. If scheduling makes the early-return assertion unobservable, fix the test handshake before accepting it, not with a larger sleep. Check foreign-token rejection and path-component ownership with the tests above.

- [ ] **Step 5: Independent review, then exact-file local commit.**

Review race/cancellation behavior and ensure no store-wide safety claims. Resolve Important/Critical findings with RED/GREEN evidence. Commit only the two new files, using message `feat(backup): track closed session work until termination`. No push. Record actual SHA and test logs.

## Task 2: Bind the tracker to complete store backup lifetimes

**Files:** modify `JSONProjectStore.swift`, `JSONProjectStoreTests.swift`, and required PBX source memberships; create the verification report. Read the approved spec, Task 1 interface, and current complete backup functions before edits. Do not extract or rewrite the large store class.

**Consumes:** Task 1 tracker and errors; existing `StoreSessionAccessError`, `requireSessionWriteAccess()`, `beginDataOperation()`, `KnitNoteBackupService.createPackage(appVersion:)`, `stagePackage(at:)`, `install(_:)`, `rollback(_:)`, `commit(_:)`, `reloadFromDiskDuringDataOperation()`.

**Produces:** `public func waitForBackupOperationsAfterRevocation() async throws -> Void` on `JSONProjectStore`. Void means backup work termination only, never a durable health/cleanup receipt. No App caller is introduced.

- [ ] **Step 1: Write store RED tests in the existing fixture's file.**

Add `@Suite(.serialized) @MainActor struct StoreBackupSessionDrainTests` in `JSONProjectStoreTests.swift`, so the private `StoreBackupFixture` and `StoreOperationBlocker` remain reusable. Begin with:

```swift
@Test func revokedBackupEntriesAndCleanupLeaveOwnedDataUntouched() async throws {
    let fixture = try StoreBackupFixture.make()
    defer { fixture.cleanup() }
    let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)
    let before = try Data(contentsOf: fixture.archiveURL)
    fixture.store.revokeSessionWrites()
    await #expect(throws: StoreSessionAccessError.revoked) {
        _ = try await fixture.store.exportBackup(appVersion: "1.0")
    }
    await #expect(throws: StoreSessionAccessError.revoked) {
        _ = try await fixture.store.prepareBackupRestore(from: fixture.replacementPackage)
    }
    await #expect(throws: StoreSessionAccessError.revoked) {
        try await fixture.store.restoreBackup(staged)
    }
    fixture.store.cancelBackupRestore(staged)
    fixture.store.cleanupBackupArtifact(at: fixture.replacementPackage)
    #expect(FileManager.default.fileExists(atPath: staged.root.path))
    #expect(FileManager.default.fileExists(atPath: fixture.replacementPackage.path))
    #expect(try Data(contentsOf: fixture.archiveURL) == before)
    try await fixture.store.waitForBackupOperationsAfterRevocation()
}

@Test(arguments: [false, true])
func lateBackupArtifactsStayOwnedAndAreNotReturned(prepare: Bool) async throws {
    let blocker = StoreOperationBlocker()
    let fixture = try StoreBackupFixture.make(
        metadataBlocker: prepare ? nil : blocker,
        stageBlocker: prepare ? blocker : nil)
    defer { blocker.resume(); fixture.cleanup() }
    let operation = Task { @MainActor in
        blocker.startObservingOperation()
        defer { blocker.finishObservation(reachedBlock: false) }
        if prepare {
            _ = try await fixture.store.prepareBackupRestore(from: fixture.replacementPackage)
        } else {
            _ = try await fixture.store.exportBackup(appVersion: "1.0")
        }
    }
    do { try #require(await blocker.waitForObservedBlock()) }
    catch { blocker.resume(); _ = try? await operation.value; throw error }
    fixture.store.revokeSessionWrites()
    let ready = AsyncStream<Void>.makeStream()
    var ended = false
    let drain = Task { @MainActor in
        ready.continuation.yield(())
        try await fixture.store.waitForBackupOperationsAfterRevocation()
        ended = true
    }
    var iterator = ready.stream.makeAsyncIterator()
    _ = await iterator.next()
    #expect(!ended)
    operation.cancel() // cancellation alone must not end detached work
    #expect(!ended)
    blocker.resume()
    await #expect(throws: StoreSessionAccessError.revoked) { try await operation.value }
    try await drain.value
    #expect(ended)
    #expect(FileManager.default.fileExists(atPath: fixture.replacementPackage.path))
    let artifacts = try FileManager.default.contentsOfDirectory(
        at: fixture.workRoot, includingPropertiesForKeys: nil)
    #expect(artifacts.contains {
        prepare ? $0.lastPathComponent.hasPrefix("Staged-") :
            ($0.pathExtension == "knitnote-backup" && $0 != fixture.replacementPackage)
    })
}
```

Run `swift test --filter StoreBackupSessionDrainTests`, record missing wait API plus existing unsafe cleanup/late-result behavior through a behavioral RED after the public wait API is wired. Missing symbols alone do not prove integration sensitivity.

- [ ] **Step 2: Add store state, synchronous revocation and specific wait API.**

```swift
private let backupSessionWork = BackupSessionWorkTracker()

public func revokeSessionWrites() {
    isSessionWriteRevoked = true
    backupSessionWork.close()
}

public func waitForBackupOperationsAfterRevocation() async throws {
    try await backupSessionWork.waitUntilClosedAndIdle()
}
```

Keep the existing monotonic flag/error; no setter or path/sink replacement. Store field initializes before constructor work but does not claim to track constructor recovery.

- [ ] **Step 3: Bind export and prepare from admission through result.**

Replace only these two method bodies:

```swift
public func exportBackup(appVersion: String) async throws -> URL {
    try requireSessionWriteAccess()
    let work = try backupSessionWork.begin(protecting: backupService.workRoot)
    defer { backupSessionWork.finish(work) }
    try beginDataOperation()
    defer { isDataOperationInProgress = false }
    let service = backupService
    let artifact = try await Task.detached(priority: .userInitiated) {
        try service.createPackage(appVersion: appVersion)
    }.value
    try requireSessionWriteAccess()
    return artifact
}

public func prepareBackupRestore(from packageURL: URL) async throws -> StagedKnitNoteBackup {
    try requireSessionWriteAccess()
    let work = try backupSessionWork.begin(protecting: backupService.workRoot)
    defer { backupSessionWork.finish(work) }
    let accessedSecurityScope = packageURL.startAccessingSecurityScopedResource()
    defer { if accessedSecurityScope { packageURL.stopAccessingSecurityScopedResource() } }
    let service = backupService
    let staged = try await Task.detached(priority: .userInitiated) {
        try service.stagePackage(at: packageURL)
    }.value
    try requireSessionWriteAccess()
    return staged
}
```

No `Task.checkCancellation()` between service return and the post-return admission check: canceled caller must still await real work. Native thrown failures propagate before the admission check. Late successful artifacts remain in the same workRoot.

- [ ] **Step 4: Wrap the full restore lifetime without rewriting its transaction.**

Insert these three executable statements at the start of `restoreBackup`, before existing `requireAccess(.restoreBackup)`:

```swift
try requireSessionWriteAccess()
let work = try backupSessionWork.begin(protecting: backupService.workRoot)
defer { backupSessionWork.finish(work) }
// Existing requireAccess / ensureSyncPublicationReady / beginDataOperation follow.
```

Keep every existing install/reload/catch/rollback/commit/thumbnail/notification line intact. The outer defer must run after existing inner data-operation defer and after security/service cleanup. An admission failure during the existing purchase callback must release the registration. Do not add a post-await revoked check inside the restore transaction: it must retain the native true outcome and recovery path on its original store.

- [ ] **Step 5: Protect external owned-artifact cleanup.**

Insert before any current path or filesystem inspection in `removeOwnedBackupArtifact(at:kind:)`:

```swift
guard !isSessionWriteRevoked,
      !backupSessionWork.protects(artifact) else { return }
```

Keep all current path/name/directory/symlink checks. No calls to `recoverInterruptedReplacement` from the tracker, result delivery or cleanup guard. Do not change service-internal rollback/commit cleanup.

- [ ] **Step 6: GREEN and real restore/failure/cleanup tests.**

Add the following integration test to `StoreBackupSessionDrainTests` before claiming store completion:

```swift
@Test(arguments: [KnitNoteBackupReplacementStep.beforeLiveMove,
                  .afterLiveMove, .afterStagedMove, .beforeCommitCleanup])
func restoreCannotDrainWhileNativeReplacementIsBlocked(
    step: KnitNoteBackupReplacementStep
) async throws {
    let blocker = StoreOperationBlocker()
    let fixture = try StoreBackupFixture.make(
        replacementBlocker: blocker, blockedReplacementStep: step)
    let other = try StoreBackupFixture.make()
    defer { blocker.resume(); fixture.cleanup(); other.cleanup() }
    let otherBytes = try Data(contentsOf: other.archiveURL)
    let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)
    let operation = Task { @MainActor in
        blocker.startObservingOperation()
        defer { blocker.finishObservation(reachedBlock: false) }
        try await fixture.store.restoreBackup(staged)
    }
    do { try #require(await blocker.waitForObservedBlock()) }
    catch { blocker.resume(); _ = try? await operation.value; throw error }
    // Before revocation, ownership alone must prevent deleting active stage.
    fixture.store.cancelBackupRestore(staged)
    if step == .beforeLiveMove || step == .afterLiveMove {
        #expect(FileManager.default.fileExists(atPath: staged.root.path))
    }
    fixture.store.revokeSessionWrites()
    let ready = AsyncStream<Void>.makeStream()
    var ended = false
    let waiter = Task { @MainActor in
        ready.continuation.yield(())
        try await fixture.store.waitForBackupOperationsAfterRevocation()
        ended = true
    }
    var iterator = ready.stream.makeAsyncIterator()
    _ = await iterator.next()
    #expect(!ended)
    blocker.resume()
    try await operation.value
    try await waiter.value
    #expect(ended)
    #expect(try fixture.diskProjectName() == "replacement")
    #expect(!fixture.store.isDataOperationInProgress)
    #expect(try Data(contentsOf: other.archiveURL) == otherBytes)
    try other.store.add(name: "Other session remains open")
}
```

Add parameterized failure coverage using the existing fixtures:

```swift
@Test(arguments: ["reload", "rollback", "commit-cleanup"])
func drainPreservesNativeFailureEvidence(mode: String) async throws {
    let blocker = StoreOperationBlocker()
    let fixture = try StoreBackupFixture.make(
        replacementBlocker: blocker,
        corruptInstalledArchive: mode != "commit-cleanup",
        failRollback: mode == "rollback",
        partialCommitCleanupFailure: mode == "commit-cleanup")
    defer { blocker.resume(); fixture.cleanup() }
    let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)
    let operation = Task { @MainActor in
        blocker.startObservingOperation()
        defer { blocker.finishObservation(reachedBlock: false) }
        try await fixture.store.restoreBackup(staged)
    }
    do { try #require(await blocker.waitForObservedBlock()) }
    catch { blocker.resume(); _ = try? await operation.value; throw error }
    fixture.store.revokeSessionWrites()
    blocker.resume()
    if mode == "reload" {
        await #expect(throws: KnitNoteBackupError.installFailedOriginalPreserved) {
            try await operation.value
        }
        #expect(try fixture.diskProjectName() == "original")
    } else if mode == "rollback" {
        await #expect(throws: KnitNoteBackupError.rollbackFailed) { try await operation.value }
        #expect(try fixture.rollbackRoots().count == 1)
    } else {
        try await operation.value
        #expect(try fixture.diskProjectName() == "replacement")
        #expect(try fixture.cleanupRoots().count == 1)
    }
    let before = try backupEvidenceBytes(fixture.workRoot)
    try await fixture.store.waitForBackupOperationsAfterRevocation()
    #expect(try backupEvidenceBytes(fixture.workRoot) == before)
}
```

Define this test-only evidence helper in the same file (test temporary roots only):

```swift
private func backupEvidenceBytes(_ root: URL) throws -> [String: Data] {
    let files = FileManager.default.enumerator(at: root,
        includingPropertiesForKeys: [.isRegularFileKey], options: [])
    var result: [String: Data] = [:]
    while let file = files?.nextObject() as? URL {
        if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[file.path] = try Data(contentsOf: file)
        }
    }
    return result
}
```

Run `swift test --filter 'BackupSessionWorkTrackerTests|StoreBackupSessionDrainTests|StoreBackupTransactionGateTests|restoreReloadFailure|restoreReportsRollbackFailure|restoreSucceedsWhenCommitCleanup'`. Retain actual failures; do not widen timeouts or remove cases to obtain green.

- [ ] **Step 7: Close the remaining multi-prepare and rollback timing coverage.**

The existing `StoreOperationBlocker` blocks only once. Do not pretend it proves two simultaneous prepare calls. Add an optional test-fixture parameter `stageObserver: (@Sendable (URL) -> Void)? = nil` to `StoreBackupFixture.make`, and route the stage branch when either the existing stageBlocker or stageObserver is supplied. In its existing `afterStageCopy` closure call `stageObserver?(url)` and then `stageBlocker?.blockOnce()`. Production service hooks already exist; no production test-only seam.

```swift
// New test-file helper, not production code.
private final class TwoStageBlocks: @unchecked Sendable {
    let first = StoreOperationBlocker()
    let second = StoreOperationBlocker()
    private let lock = NSLock()
    private var count = 0
    func visit(_ url: URL) {
        lock.lock(); count += 1; let index = count; lock.unlock()
        (index == 1 ? first : second).blockOnce()
    }
}
```

```swift
@Test func twoPrepareOperationsMustBothEndBeforeDrain() async throws {
    let gates = TwoStageBlocks()
    let fixture = try StoreBackupFixture.make(stageObserver: { gates.visit($0) })
    defer { gates.first.resume(); gates.second.resume(); fixture.cleanup() }
    let one = Task { @MainActor in
        gates.first.startObservingOperation()
        return try await fixture.store.prepareBackupRestore(from: fixture.replacementPackage)
    }
    do { try #require(await gates.first.waitForObservedBlock()) }
    catch { gates.first.resume(); _ = try? await one.value; throw error }
    let two = Task { @MainActor in
        gates.second.startObservingOperation()
        return try await fixture.store.prepareBackupRestore(from: fixture.replacementPackage)
    }
    do { try #require(await gates.second.waitForObservedBlock()) }
    catch {
        gates.first.resume(); gates.second.resume()
        _ = try? await one.value; _ = try? await two.value; throw error
    }
    fixture.store.revokeSessionWrites()
    let ready = AsyncStream<Void>.makeStream()
    var ended = false
    let waiter = Task { @MainActor in
        ready.continuation.yield(())
        try await fixture.store.waitForBackupOperationsAfterRevocation()
        ended = true
    }
    var iterator = ready.stream.makeAsyncIterator()
    _ = await iterator.next()
    gates.first.resume()
    await #expect(throws: StoreSessionAccessError.revoked) { _ = try await one.value }
    #expect(!ended)
    gates.second.resume()
    await #expect(throws: StoreSessionAccessError.revoked) { _ = try await two.value }
    try await waiter.value
    #expect(ended)
}
```

For actual rollback timing, extend the fixture with separate optional `rollbackBlocker: StoreOperationBlocker? = nil`; at `.beforeRollback` call it before the existing injected failRollback throw. It is separate from the existing afterStagedMove corruption hook. Add the following test:

```swift
@Test func drainIncludesRollbackAfterReloadFailure() async throws {
    let gate = StoreOperationBlocker()
    let fixture = try StoreBackupFixture.make(
        corruptInstalledArchive: true, rollbackBlocker: gate)
    defer { gate.resume(); fixture.cleanup() }
    let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)
    let operation = Task { @MainActor in
        gate.startObservingOperation()
        defer { gate.finishObservation(reachedBlock: false) }
        try await fixture.store.restoreBackup(staged)
    }
    do { try #require(await gate.waitForObservedBlock()) }
    catch { gate.resume(); _ = try? await operation.value; throw error }
    fixture.store.revokeSessionWrites()
    let ready = AsyncStream<Void>.makeStream()
    var ended = false
    let waiter = Task { @MainActor in
        ready.continuation.yield(())
        try await fixture.store.waitForBackupOperationsAfterRevocation()
        ended = true
    }
    var iterator = ready.stream.makeAsyncIterator()
    _ = await iterator.next()
    #expect(!ended)
    gate.resume()
    await #expect(throws: KnitNoteBackupError.installFailedOriginalPreserved) {
        try await operation.value
    }
    try await waiter.value
    #expect(try fixture.diskProjectName() == "original")
}
```

Place `rollbackBlocker` last in the fixture signature so this labelled call order compiles. Confirm fixtures still use their existing hook defaults and cleanup.

- [ ] **Step 8: Mutation RED, project membership, affected regression.**

Mutation-check the two independent prepare boundaries separately. Bypass both the prepare entry check and tracker begin/defer registration while retaining its post-return check: the revoked-entry test must detect an extra `Staged-` artifact even though the call still throws revoked. Therefore augment that test with `let workBefore = try backupEvidenceBytes(fixture.workRoot)` before revocation and `#expect(try backupEvidenceBytes(fixture.workRoot) == workBefore)` after all rejected calls. Separately remove only prepare's post-return admission check: the blocked late-artifact test must detect a returned result instead of revoked. Finally, temporarily finish restore's work token immediately before detached install and prove the blocked restore/rollback tests detect early drain. Restore exact changes and rerun the tests. No production mutation stays in the candidate.

Add the new tracker file's PBXFileReference, group entry, and the same two App/Watch Sources memberships as `KnitNoteBackupService.swift`. IDs must be unique in the actual project; do not regenerate the project. This is necessary because the new public error and internal tracker are used by the store in those explicit targets.

```sh
git diff --check
plutil -lint KnitNote.xcodeproj/project.pbxproj
swift test --filter 'JSONProjectStore|SyncConflict|SyncRemoteBatch|SyncPublication|SyncDeletion|Backup|Watch'
```

Use the original default-concurrent affected command. A serial-only diagnostic does not overwrite its failure. Capture complete log, actual count and exit code.

- [ ] **Step 9: Independent review and frozen source commit.**

Review the full Task 1+2 delta and all five backup entry/cleanup paths. Verify defer ordering, ownership protection, multi-waiter cancellation, original errors and residual journal evidence. Check that store wait cannot be consumed as account-ready. Correct Critical/Important findings with focused RED/GREEN and rereview before committing exact changed files. Message: `feat(backup): drain accepted work after session revocation`.

- [ ] **Step 10: Final validation on the frozen candidate.**

Run these commands serially, using unique logs and run-specific DerivedData paths (if present from another run, select fresh names and record them; do not delete). Use the inspected bounded runner or equivalent owned-process bounds: 3600 seconds for Core and 900 seconds per build, short progress polls. No App/test host execution.

```sh
swift test --no-parallel
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/backup-session-drain-macos-derived CODE_SIGNING_ALLOWED=NO build-for-testing
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/backup-session-drain-ios-derived CODE_SIGNING_ALLOWED=NO build
```

Report source SHA, Sources/Tests/PBX identities, RED/GREEN/mutation evidence, reviewer outcomes, exact commands, actual counts/exit codes, durations/warnings/log hashes, and all not-run gates. Timeout or failure blocks completion; focused green is not a substitute. Update only the verification report after successful frozen validation and commit documentation separately. Recheck source identities unchanged; no release action.

## Self-review and coverage map

- Spec §1/3/5: Task 1 plus the narrowly named store wait; no health/cleanup receipt and no live caller.
- Spec §2/4/6: Task 2 full-method lifetime wrapping, three admission gates, two artifact-delivery checks and shared cleanup guard; native restore body is retained.
- Matrix1/2: existing backup regressions plus revoked-entry/artifact tests; matrix3/7: late-artifact cancel test and tracker waiter tests; matrix4/5/6: replacement-step, rollback-block and failure-evidence tests; matrix8: two-prepare and stage-cleanup tests; matrix9: independent other-store bytes; matrix10: required mutation runs and retained handshake tests.
- The tracker needs no clock or semaphore. Runtime termination has no manufactured timeout success; only test runner bounds can terminate hung test processes.
- Filesystem ownership protection is deliberately conservative for the whole workRoot while any backup is active. This avoids guessing a not-yet-created artifact name, while existing lexical/symlink validation still limits deletion.
- Full App freeze, identity lookup, background inbox/photo/Watch work, constructor recovery, inventory, account opening and live device acceptance remain outside this approved backup-only spec and are not waived by this plan.
