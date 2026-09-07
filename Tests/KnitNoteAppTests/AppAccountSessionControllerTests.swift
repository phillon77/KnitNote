import CloudKit
import Combine
import Foundation
import Testing
@testable import KnitNote

@MainActor @Suite struct AppAccountSessionControllerTests {
    @Test func nestedStopDuringVisibilityHideCannotRestoreCheckingOrScheduleQuery() async throws {
        try await withControllerFixture { f, q, c in
            try await openA(f, q, c)
            let observer = f.owner.$visibleSession.sink { if $0 == nil { c.stop() } }
            c.accountDidChange()
            #expect(c.state == .idle && f.owner.visibleSession == nil)
            await c.waitUntilStopped()
            c.start(); c.retry(); c.accountDidChange()
            #expect(c.state == .idle)
            #expect(await q.statusCount == 1)
            observer.cancel()
        }
    }

    @Test(arguments: [false, true])
    func completedDriverCancellationDoesNotFinishSuspendedSyncWork(manual: Bool) async throws {
        try await withControllerFixture { f, q, c in
            if manual { try await openA(f, q, c) }
            await f.driver.suspendNextFetch()
            if manual { c.foreground() }
            else { c.start(); try await q.waitForStatus(1); await q.resolve(account: "A") }
            try await f.waitForSuspendedFetch()
            let freezeCount = f.recording.freezeCount
            c.stop()
            var joined = false
            let stop = f.operation { await c.waitUntilStopped(); joined = true }
            await f.driver.waitUntilCancelled()
            for _ in 0..<20 { await Task.yield() }
            #expect(await f.driver.completedCancellationCount() == 1)
            #expect(await f.driver.isFetchSuspended())
            #expect(!joined)
            #expect(f.recording.freezeCount == freezeCount)
            await f.driver.resumeFetch()
            try await stop.value
            #expect(joined && c.state == .idle && f.owner.visibleSession == nil)
        }
    }

    @Test(arguments: ["stop", "same", "logout"])
    func actualAttachmentResolutionMustFinishBeforeShutdownOrNextIdentity(action: String) async throws {
        try await withControllerFixture { f, q, c in
            let gate = AccountLifecycleAttachmentGate()
            f.suspendAttachmentResolution(with: gate)
            c.start(); try await q.waitForStatus(1); await q.resolve(account: "A")
            try await f.waitUntil { gate.entered }
            let journal = try #require(f.coordinator.currentJournal)
            let pending = try journal.pending()
            let before = try accountTree(f.root)
            let freezeCount = f.recording.freezeCount
            var joined = false
            var stop: Task<Void, any Error>?
            if action == "stop" {
                c.stop()
                stop = f.operation { await c.waitUntilStopped(); joined = true }
            } else { c.accountDidChange() }
            await f.driver.waitUntilCancelled()
            for _ in 0..<20 { await Task.yield() }
            #expect(!joined && gate.completed == 0)
            #expect(await q.statusCount == 1)
            #expect(f.recording.freezeCount == freezeCount)
            #expect(try accountTree(f.root) == before)
            #expect(try journal.pending() == pending)
            gate.release()
            if let stop {
                try await stop.value
                #expect(joined && c.state == .idle)
            } else {
                try await q.waitForStatus(2)
                #expect(gate.completed == 1)
                if action == "same" {
                    await q.resolve(account: "A")
                    try await f.waitUntil { f.coordinator.completed }
                    #expect(c.state == .localReady && f.coordinator.currentJournal === journal)
                    #expect(try vaultFiles(f.root, f.a).isEmpty)
                } else {
                    await q.resolveStatus(.noAccount)
                    try await f.waitUntil { c.state == .noAccount }
                    #expect(f.coordinator.retainedAccount == nil)
                }
            }
            #expect(gate.completed >= 1)
        }
    }

    @Test func observerStopAtOpeningCannotStartStorageOrOverwriteIdle() async throws {
        try await withControllerFixture { f, q, c in
            let before = try accountTree(f.root)
            let observer = c.$state.sink { if $0 == .opening { c.stop() } }
            c.start(); try await q.waitForStatus(1); await q.resolve(account: "A")
            try await f.waitUntil { c.state != .checking }
            await c.waitUntilStopped()
            #expect(c.state == .idle)
            #expect(f.coordinator.retainedAccount == nil && f.owner.visibleSession == nil)
            #expect(try accountTree(f.root) == before)
            observer.cancel()
        }
    }

    @Test func observerAccountEventAtLocalPublicationRejectsOldRuntime() async throws {
        try await withControllerFixture { f, q, c in
            var signalled = false
            var old: AppSessionResources?
            let observer = c.$state.sink { value in
                if value == .localReady && !signalled {
                    signalled = true; old = f.owner.visibleSession
                    c.accountDidChange()
                }
            }
            c.start(); try await q.waitForStatus(1); await q.resolve(account: "A")
            try await q.waitForStatus(2)
            #expect(c.state == .checking && f.owner.visibleSession == nil)
            #expect(old?.store.isSessionWriteRevoked == true)
            #expect(await f.driver.sendCallCount() == 0)
            await q.resolveStatus(.couldNotDetermine)
            try await f.waitUntil { c.state == .unknown }
            #expect(f.coordinator.retainedAccount == f.a)
            #expect(try vaultFiles(f.root, f.a).isEmpty)
            observer.cancel()
        }
    }

    @Test func nestedAccountEventDuringHideKeepsNewestLifecycleGeneration() async throws {
        try await withControllerFixture { f, q, c in
            try await openA(f, q, c)
            var nested = false
            let observer = f.owner.$visibleSession.sink { value in
                if value == nil && !nested { nested = true; c.accountDidChange() }
            }
            c.accountDidChange()
            try await q.waitForStatus(2)
            await q.resolve(account: "A")
            try await f.waitUntil { f.coordinator.completed || c.state == .blocked }
            #expect(f.coordinator.completed && c.state == .localReady)
            #expect(f.owner.visibleSession?.store.projects.map(\.id) == [f.aID])
            observer.cancel()
        }
    }
    // Duplicate pumps would install more than once; waiting for fetch to finish
    // before projecting readiness would hide valid offline local access.
    @Test func repeatedStartAndForegroundPublishOneLocalSessionBeforeFetch() async throws {
        try await withControllerFixture { f, q, c in
            await f.driver.suspendNextFetch()
            c.start(); c.start(); c.foreground()
            try await q.waitForStatus(1)
            await q.resolve(account: "A")
            try await f.waitForSuspendedFetch()
            #expect(c.state == .localReady)
            #expect(!f.coordinator.completed)
            #expect(f.owner.visibleSession?.store.projects.map(\.id) == [f.aID])
            #expect(f.recording.installationCount == 1)
            #expect(await q.statusCount == 1)
            await f.driver.resumeFetch()
            try await f.waitUntil { f.coordinator.completed }
        }
    }

    // Removing request-generation acceptance publishes stale A and mutates its
    // recovery selection before the authoritative event's query has completed.
    @Test func delayedRecordResultSupersededByEventNeverOpensOldAccount() async throws {
        try await withControllerFixture { f, q, c in
            let before = try accountTree(f.root)
            c.start()
            try await q.waitForStatus(1)
            await q.resolveStatus(.available)
            try await q.waitForRecord(1)
            c.accountDidChange()
            await q.resolveRecord(.success("A"))
            try await q.waitForStatus(2)
            #expect(f.owner.visibleSession == nil)
            #expect(f.coordinator.retainedAccount == nil)
            #expect(f.recording.installationCount == 0)
            #expect(try accountTree(f.root) == before)
            await q.resolve(account: "B")
            try await f.waitUntil { c.state == .localReady }
            #expect(f.owner.visibleSession?.store.projects.map(\.id) == [f.bID])
        }
    }

    // Replacing retained reopen with transition(A,A) seals the advanced local
    // canonical and incorrectly makes this valid account bootstrap-required.
    @Test func sameAccountRevalidationRetainsStorageAndAdvancedCanonicalWithoutSeal() async throws {
        try await withControllerFixture { f, q, c in
            try await openA(f, q, c)
            let old = try #require(f.owner.visibleSession)
            try f.rename(old.store, id: f.aID, name: "Advanced canonical")
            let journal = try #require(f.coordinator.currentJournal)
            let pending = try journal.pending()
            let before = try accountTree(f.root)
            let context = try #require(f.recording.context)
            let transport = f.coordinator.currentTransport
            c.accountDidChange()
            #expect(f.owner.visibleSession == nil && old.store.isSessionWriteRevoked)
            try await q.waitForStatus(2)
            #expect(try accountTree(f.root) == before)
            await q.resolve(account: "A")
            try await f.waitUntil { c.state == .localReady || c.state == .bootstrapRequired || c.state == .blocked }
            #expect(c.state == .localReady)
            #expect(f.coordinator.currentJournal === journal)
            #expect(try journal.pending() == pending)
            #expect(f.owner.visibleSession?.store.projects.first?.name == "Advanced canonical")
            #expect(f.coordinator.currentTransport !== transport)
            #expect(throws: (any Error).self) { try context.validateOwnership() }
            #expect(try vaultFiles(f.root, f.a).isEmpty)
            try await f.waitUntil { f.coordinator.completed || c.state == .blocked }
            #expect(f.coordinator.completed && c.state == .localReady)
        }
    }

    @Test func eventDuringProducerDrainWaitsThenQueriesLatestAccount() async throws {
        try await withControllerFixture { f, q, c in
            let drain = AccountLifecycleDrain(); f.drains.append(drain)
            let legacy = JSONProjectStore(url: f.root.appendingPathComponent("isolated-unbound.json"))
            let resources = try AppSessionResources(store: legacy, makeProducers: { _ in [drain] })
            try f.owner.publishPreparedSession(resources, for: f.owner.generation)
            c.start(); try await q.waitForStatus(1); await q.resolve(account: "A")
            try await f.waitUntil { drain.entered }
            c.accountDidChange(); c.accountDidChange()
            for _ in 0..<20 { await Task.yield() }
            #expect(await q.statusCount == 1)
            #expect(f.owner.visibleSession == nil && legacy.isSessionWriteRevoked)
            #expect(f.recording.installationCount == 0)
            drain.release()
            try await q.waitForStatus(2)
            #expect(f.recording.installationCount == 0)
            await q.resolve(account: "B")
            try await f.waitUntil { c.state == .localReady }
            #expect(f.owner.visibleSession?.store.projects.map(\.id) == [f.bID])
        }
    }

    @Test func unknownColdStartAndRepeatedRetryPreserveEntireBoundTree() async throws {
        try await withControllerFixture { f, q, c in
            let before = try accountTree(f.root)
            c.start(); try await q.waitForStatus(1); await q.resolveStatus(.temporarilyUnavailable)
            try await f.waitUntil { c.state == .unknown }
            #expect(f.owner.visibleSession == nil && f.coordinator.retainedAccount == nil)
            #expect(try accountTree(f.root) == before)
            c.retry(); c.retry(); c.foreground(); c.start()
            try await q.waitForStatus(2)
            await q.resolve(account: "A")
            try await f.waitUntil { c.state == .localReady }
            #expect(await q.statusCount == 2)
            #expect(f.recording.installationCount == 1)
        }
    }

    @Test func lookupNotAuthenticatedPreservesPendingButConfirmedLogoutSeals() async throws {
        try await withControllerFixture { f, q, c in
            try await openA(f, q, c)
            let old = try #require(f.owner.visibleSession).store
            try f.rename(old, id: f.aID, name: "Preserve pending")
            let pending = try f.coordinator.currentJournal?.pending()
            c.accountDidChange(); try await q.waitForStatus(2)
            await q.resolveStatus(.available); try await q.waitForRecord(2)
            await q.resolveRecord(.failure(CKError(.notAuthenticated)))
            try await f.waitUntil { c.state == .unknown }
            #expect(f.coordinator.retainedAccount == f.a)
            #expect(f.owner.visibleSession == nil && old.isSessionWriteRevoked)
            #expect(try f.coordinator.currentJournal?.pending() == pending)
            #expect(try vaultFiles(f.root, f.a).isEmpty)
            c.retry(); try await q.waitForStatus(3); await q.resolveStatus(.noAccount)
            try await f.waitUntil { c.state == .noAccount }
            #expect(f.coordinator.retainedAccount == nil)
            #expect(!(try vaultFiles(f.root, f.a)).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(f.a.identity.accountIDHash + "/working-set/projects-v1.json").path))
        }
    }

    @Test func healthyForegroundNetworkErrorKeepsEditingAndReceiptGate() async throws {
        try await withControllerFixture { f, q, c in
            await f.driver.failNextFetch(with: .networkFailure)
            c.start(); try await q.waitForStatus(1); await q.resolve(account: "A")
            try await f.waitUntil { c.state == .localReady && f.coordinator.cloudStatus?.issue != nil }
            let visible = try #require(f.owner.visibleSession)
            let generation = f.owner.generation
            let transport = try #require(f.coordinator.currentTransport)
            await f.driver.suspendNextFetch()
            c.foreground(); c.foreground(); c.retry()
            try await f.waitForSuspendedFetch()
            try f.rename(visible.store, id: f.aID, name: "Offline save")
            #expect(!(try #require(f.coordinator.currentJournal).pending()).isEmpty)
            #expect(f.owner.generation == generation && f.owner.visibleSession === visible)
            #expect(c.state == .localReady && !f.coordinator.completed)
            #expect(await q.statusCount == 1)
            #expect(f.recording.installationCount == 1)
            await #expect(throws: (any Error).self) { try await transport.sendNow() }
            #expect(await f.driver.sendCallCount() == 0)
            await f.driver.resumeFetch()
            try await f.waitUntil { f.coordinator.completed }
        }
    }

    @Test func destinationFailedAfterSourceCleanupRetryUsesRetainedDestination() async throws {
        try await withControllerFixture { f, q, c in
            try await openA(f, q, c)
            c.accountDidChange(); try await q.waitForStatus(2); await q.resolve(account: "B")
            try await f.waitUntil { f.coordinator.completed && f.coordinator.retainedAccount == f.b }
            c.accountDidChange(); try await q.waitForStatus(3); await q.resolve(account: "A")
            try await f.waitUntil { c.state == .bootstrapRequired }
            #expect(f.coordinator.retainedAccount == f.a)
            let journal = f.coordinator.currentJournal
            let exact = try journal?.pending()
            let before = try accountTree(f.root)
            c.retry(); c.retry(); try await q.waitForStatus(4); await q.resolve(account: "A")
            try await f.waitUntil { c.state == .bootstrapRequired || c.state == .blocked }
            #expect(c.state == .bootstrapRequired)
            #expect(f.coordinator.currentJournal === journal)
            #expect(try journal?.pending() == exact)
            #expect(try accountTree(f.root) == before)
        }
    }

    @Test func accountSignalRequeriesWithoutTrustingEventString() async throws {
        try await withControllerFixture { f, q, c in
            try await openA(f, q, c)
            let old = try #require(f.owner.visibleSession).store
            await f.coordinator.currentTransport?.receiveAccountChange(previous: "A", current: "unverified-string")
            try await q.waitForStatus(2)
            #expect(f.owner.visibleSession == nil && old.isSessionWriteRevoked)
            #expect(f.coordinator.retainedAccount == f.a)
            await q.resolve(account: "A")
            try await f.waitUntil { c.state == .localReady }
            #expect(f.owner.visibleSession?.store.projects.map(\.id) == [f.aID])
            try await f.waitUntil { f.coordinator.completed || c.state == .blocked }
            #expect(f.coordinator.completed && c.state == .localReady)
        }
    }

    @Test func stopJoinsLateQueryAndRejectsRestart() async throws {
        try await withControllerFixture { f, q, c in
            c.start(); try await q.waitForStatus(1)
            c.stop(); c.start(); c.retry(); c.foreground(); c.accountDidChange()
            var joined = false
            let stop = f.operation { await c.waitUntilStopped(); joined = true }
            for _ in 0..<20 { await Task.yield() }
            #expect(!joined && f.owner.visibleSession == nil)
            await q.resolve(account: "A")
            try await stop.value
            #expect(joined && c.state == .idle)
            #expect(f.recording.installationCount == 0 && f.coordinator.retainedAccount == nil)
        }
    }

    @Test func stopDuringFetchJoinsTransportCancellationBeforeReturning() async throws {
        try await withControllerFixture { f, q, c in
            await f.driver.suspendNextFetch()
            c.start(); try await q.waitForStatus(1); await q.resolve(account: "A")
            try await f.waitForSuspendedFetch()
            let old = try #require(f.owner.visibleSession).store
            await f.driver.suspendNextCancellation()
            c.stop()
            #expect(f.owner.visibleSession == nil && old.isSessionWriteRevoked)
            var joined = false
            let stop = f.operation { await c.waitUntilStopped(); joined = true }
            for _ in 0..<3_000 {
                if await f.driver.isCancellationSuspended() { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(await f.driver.isCancellationSuspended())
            #expect(!joined)
            await f.driver.resumeCancellation(); await f.driver.resumeFetch()
            try await stop.value
            #expect(joined && f.owner.visibleSession == nil && c.state == .idle)
            #expect(try vaultFiles(f.root, f.a).isEmpty)
        }
    }

    @Test func eventDuringSuspendedTransitionJoinsCancellationBeforeNextQuery() async throws {
        try await withControllerFixture { f, q, c in
            await f.driver.suspendNextFetch()
            c.start(); try await q.waitForStatus(1); await q.resolve(account: "A")
            try await f.waitForSuspendedFetch()
            await f.driver.suspendNextCancellation()
            let old = try #require(f.owner.visibleSession).store
            c.accountDidChange(); c.accountDidChange()
            #expect(f.owner.visibleSession == nil && old.isSessionWriteRevoked)
            for _ in 0..<3_000 {
                if await f.driver.isCancellationSuspended() { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(await f.driver.isCancellationSuspended())
            #expect(await q.statusCount == 1)
            #expect(try vaultFiles(f.root, f.a).isEmpty)
            await f.driver.resumeFetch(); await f.driver.resumeCancellation()
            try await q.waitForStatus(2)
            await q.resolve(account: "B")
            try await f.waitUntil { f.coordinator.completed && f.coordinator.retainedAccount == f.b }
            #expect(c.state == .localReady)
            #expect(f.owner.visibleSession?.store.projects.map(\.id) == [f.bID])
        }
    }

    @Test func cancelledStopWaiterStillJoinsRetiredProducer() async throws {
        try await withControllerFixture { f, _, c in
            let drain = AccountLifecycleDrain(); f.drains.append(drain)
            let store = JSONProjectStore(url: f.root.appendingPathComponent("isolated-unbound.json"))
            let resources = try AppSessionResources(store: store, makeProducers: { _ in [drain] })
            try f.owner.publishPreparedSession(resources, for: f.owner.generation)
            c.stop()
            var entered = false
            var joined = false
            let wait = f.operation { entered = true; await c.waitUntilStopped(); joined = true }
            wait.cancel()
            try await f.waitUntil { entered }
            for _ in 0..<20 { await Task.yield() }
            #expect(!joined)
            drain.release()
            try await wait.value
            #expect(joined && c.state == .idle && store.isSessionWriteRevoked)
        }
    }
}

@MainActor private func openA(_ f: AccountLifecycleFixture, _ q: AccountControllerQuery, _ c: AppAccountSessionController) async throws {
    c.start(); try await q.waitForStatus(1); await q.resolve(account: "A")
    try await f.waitUntil { f.coordinator.completed }
    #expect(c.state == .localReady)
}

@MainActor private func withControllerFixture(_ body: (AccountLifecycleFixture, AccountControllerQuery, AppAccountSessionController) async throws -> Void) async throws {
    try await withAccountLifecycleFixture { f in
        let q = AccountControllerQuery()
        var controller: AppAccountSessionController? = AppAccountSessionController(query: q.query, lifecycle: f.lifecycle, coordinator: f.coordinator, now: { f.now })
        let result: Result<Void, any Error>
        do { result = .success(try await body(f, q, controller!)) } catch { result = .failure(error) }
        controller?.stop()
        await q.finish()
        for drain in f.drains { drain.release() }
        for gate in f.attachmentGates { gate.release() }
        await f.driver.resumeFetch(); await f.driver.resumeCancellation()
        try? await f.waitUntil { f.attachmentGates.allSatisfy { $0.completed >= $0.enteredCount } }
        await controller?.waitUntilStopped()
        weak let released = controller
        controller = nil
        #expect(released == nil)
        try result.get()
    }
}

private actor AccountControllerQuery {
    private var status: CheckedContinuation<CKAccountStatus, Never>?
    private var record: CheckedContinuation<String, any Error>?
    private var finished = false
    private(set) var statusCount = 0
    private(set) var recordCount = 0
    nonisolated var query: CloudAccountIdentityQuery {
        .init(containerIdentifier: "test.container", accountStatus: { await self.nextStatus() }, userRecordName: { try await self.nextRecord() })
    }
    func nextStatus() async -> CKAccountStatus {
        statusCount += 1
        if finished { return .couldNotDetermine }
        return await withCheckedContinuation { status = $0 }
    }
    func nextRecord() async throws -> String {
        recordCount += 1
        if finished { throw CancellationError() }
        return try await withCheckedThrowingContinuation { record = $0 }
    }
    private func statusReady(_ count: Int) -> Bool { statusCount >= count && status != nil }
    private func recordReady(_ count: Int) -> Bool { recordCount >= count && record != nil }
    // Poll on the controller executor, so synchronous filesystem fixtures cannot
    // consume the probe budget while the controller itself is queued behind them.
    @MainActor func waitForStatus(_ count: Int) async throws {
        for _ in 0..<3_000 { if await statusReady(count) { return }; try await Task.sleep(for: .milliseconds(1)) }
        throw ControllerTestError.queryTimeout(stage: "status", expected: count, actual: await statusCount)
    }
    @MainActor func waitForRecord(_ count: Int) async throws {
        for _ in 0..<3_000 { if await recordReady(count) { return }; try await Task.sleep(for: .milliseconds(1)) }
        throw ControllerTestError.queryTimeout(stage: "record", expected: count, actual: await recordCount)
    }
    func resolveStatus(_ value: CKAccountStatus) { status?.resume(returning: value); status = nil }
    func resolveRecord(_ value: Result<String, any Error>) { record?.resume(with: value); record = nil }
    func resolve(account: String) async {
        let next = recordCount + 1
        resolveStatus(.available)
        try? await waitForRecord(next)
        resolveRecord(.success(account))
    }
    func finish() { finished = true; resolveStatus(.couldNotDetermine); resolveRecord(.failure(CancellationError())) }
}
private enum ControllerTestError: Error { case queryTimeout(stage: String, expected: Int, actual: Int) }

private func accountTree(_ root: URL) throws -> [String: Data] {
    let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
    var result: [String: Data] = [:]
    for case let url as URL in enumerator {
        if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(root.path.count))] = try Data(contentsOf: url)
        }
    }
    return result
}
private func vaultFiles(_ root: URL, _ account: CloudAccountBinding) throws -> [String] {
    let tree = try accountTree(root.appendingPathComponent(account.identity.accountIDHash))
    return tree.keys.filter { $0.contains("/vault/") }.sorted()
}
