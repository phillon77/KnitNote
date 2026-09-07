import Foundation
import Testing
@testable import KnitNote

private struct NativeWatchTestError: Error, Sendable {}

@MainActor
private final class NativeWatchOperationsSpy: WatchConnectivitySessionOperations {
    weak var owner: PhoneWatchSession?
    var installCount = 0
    var removalCount = 0
    var activationCount = 0
    var reachabilityReadCount = 0
    var contexts: [[String: Any]] = []
    var messages: [[String: Any]] = []
    var userInfos: [[String: Any]] = []
    var replies: [([String: Any]) -> Void] = []
    var errors: [(Error) -> Void] = []
    var onInstall: (() -> Void)?
    var onActivate: (() -> Void)?
    var onRemove: (() -> Void)?
    var reachable = true

    var isReachable: Bool {
        reachabilityReadCount += 1
        return reachable
    }
    func installDelegate(_ owner: PhoneWatchSession) {
        self.owner = owner
        installCount += 1
        onInstall?()
    }
    func removeDelegate(ifOwnedBy owner: PhoneWatchSession) {
        removalCount += 1
        if self.owner === owner { self.owner = nil }
        onRemove?()
    }
    func activate() { activationCount += 1; onActivate?() }
    func updateApplicationContext(_ applicationContext: [String: Any]) throws {
        contexts.append(applicationContext)
    }
    func sendMessage(
        _ message: [String: Any],
        replyHandler: (([String: Any]) -> Void)?,
        errorHandler: ((Error) -> Void)?
    ) {
        messages.append(message)
        if let replyHandler { replies.append(replyHandler) }
        if let errorHandler { errors.append(errorHandler) }
    }
    func enqueueUserInfo(_ userInfo: [String: Any]) { userInfos.append(userInfo) }
}

// Independent immutable observations join accepted work even when the public
// drain is deliberately broken during a RED run. No sleeps or scheduler fences.
private final class NativeWatchGateProbe: @unchecked Sendable {
    struct Snapshot: Sendable {
        var state = AppSessionCallbackGate.State(isClosed: false, activeTokenCount: 0, waiterCount: 0)
        var returnedWhileActive: [String: Bool] = [:]
        var maximumActive = 0
    }
    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var waiters: [(@Sendable (Snapshot) -> Bool, CheckedContinuation<Void, Never>)] = []
    func record(_ state: AppSessionCallbackGate.State) {
        change { $0.state = state; $0.maximumActive = max($0.maximumActive, state.activeTokenCount) }
    }
    func returned(_ waiter: String) { change { $0.returnedWhileActive[waiter] = $0.state.activeTokenCount > 0 } }
    func read() -> Snapshot { lock.withLock { snapshot } }
    private func change(_ body: (inout Snapshot) -> Void) {
        let ready = lock.withLock {
            body(&snapshot)
            let ready = waiters.filter { $0.0(snapshot) }.map(\.1)
            waiters.removeAll { $0.0(snapshot) }
            return ready
        }
        ready.forEach { $0.resume() }
    }
    func wait(_ predicate: @escaping @Sendable (Snapshot) -> Bool) async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if predicate(snapshot) { return true }
                waiters.append((predicate, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
    func joinAcceptedWork() async { await wait { $0.state.activeTokenCount == 0 } }
}

private final class NativeWatchResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    func read() -> [String] { lock.withLock { values } }
}

// WCSession may invoke these retained native closures on different threads.
// The box moves only the closures; the production adapter owns synchronization.
private final class NativeWatchConcurrentCallbacks: @unchecked Sendable {
    let reply: ([String: Any]) -> Void
    let failure: (Error) -> Void
    init(reply: @escaping ([String: Any]) -> Void, failure: @escaping (Error) -> Void) {
        self.reply = reply
        self.failure = failure
    }
}

private final class NativeWatchAdmissionHold: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    func hold() {
        condition.lock()
        defer { condition.unlock() }
        while !released { condition.wait() }
    }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

@Suite(.serialized)
@MainActor
struct PhoneWatchNativeSessionLifecycleTests {
    private func makeAdapter(
        _ native: NativeWatchOperationsSpy,
        _ probe: NativeWatchGateProbe
    ) -> PhoneWatchSession {
        PhoneWatchSession(session: native, isSupported: { true }, observeCallbackGateState: probe.record)
    }

    private func drainAndIndependentlyJoin(
        _ adapter: PhoneWatchSession,
        _ probe: NativeWatchGateProbe
    ) async throws {
        let result: Result<Void, Error>
        do {
            try await adapter.waitForStoppedOperations()
            #expect(probe.read().state.activeTokenCount == 0)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        // This non-cancellable observation precedes rethrow and teardown, and
        // also protects cleanup when the deliberately broken drain returns early.
        await probe.joinAcceptedWork()
        try result.get()
    }

    @Test func stoppedAdapterRejectsQueuedActivation() async throws {
        let native = NativeWatchOperationsSpy()
        let probe = NativeWatchGateProbe()
        let adapter = makeAdapter(native, probe)
        var callbacks = 0
        adapter.onActivationCompleted = { _, _ in callbacks += 1 }
        adapter.deactivated()
        adapter.stopForSessionTransition()
        try await drainAndIndependentlyJoin(adapter, probe)
        #expect(probe.read().state.activeTokenCount == 0)
        await probe.joinAcceptedWork()
        #expect(callbacks == 0)
        #expect(native.activationCount == 0)
    }

    @Test func normalNativeOperationsAndNotificationsRemainIntact() async throws {
        let native = NativeWatchOperationsSpy()
        let probe = NativeWatchGateProbe()
        let adapter = makeAdapter(native, probe)
        let results = NativeWatchResults()
        adapter.onActivationCompleted = { active, error in
            results.append("activation:\(active):\(error != nil)")
        }
        adapter.onReachabilityChanged = { results.append("reachable:\($0)") }
        adapter.onTransferCompleted = { envelope, error in
            results.append("transfer:\(envelope == .snapshotRequest):\(error != nil)")
        }
        adapter.activate()
        #expect(native.owner === adapter)
        #expect(adapter.isReachable)
        try adapter.updateApplicationContext(.snapshotRequest)
        adapter.transferUserInfo(.snapshotRequest)
        adapter.sendMessage(.snapshotRequest, reply: { _ in }, failure: { _ in })
        #expect(native.activationCount == 1)
        #expect(native.reachabilityReadCount == 1)
        #expect(try native.contexts.map(WatchConnectivityEnvelope.init(dictionary:)) == [.snapshotRequest])
        #expect(try native.messages.map(WatchConnectivityEnvelope.init(dictionary:)) == [.snapshotRequest])
        #expect(try native.userInfos.map(WatchConnectivityEnvelope.init(dictionary:)) == [.snapshotRequest])
        adapter.activationCompleted(activated: true, error: nil)
        await probe.joinAcceptedWork()
        adapter.becameInactive()
        await probe.joinAcceptedWork()
        adapter.deactivated()
        await probe.joinAcceptedWork()
        adapter.reachabilityChanged(false)
        await probe.joinAcceptedWork()
        adapter.transferCompleted(try WatchConnectivityEnvelope.snapshotRequest.dictionaryRepresentation(), error: nil)
        await probe.joinAcceptedWork()
        adapter.transferCompleted([:], error: NativeWatchTestError())
        await probe.joinAcceptedWork()
        #expect(results.read() == ["activation:true:false", "activation:false:false", "activation:false:false", "reachable:false", "transfer:true:false", "transfer:false:true"])
        #expect(native.activationCount == 2)
        adapter.stopForSessionTransition()
        try await drainAndIndependentlyJoin(adapter, probe)
    }

    @Test func allRawRoutesPreserveFIFOAndNormalReplyFailuresAreOneShot() async throws {
        let native = NativeWatchOperationsSpy()
        let probe = NativeWatchGateProbe()
        let adapter = makeAdapter(native, probe)
        let envelopes: [WatchConnectivityEnvelope] = [.snapshotRequest, .queueHandshake([]), .queueHandshake([UUID(uuidString: "00000000-0000-0000-0000-000000000001")!]), .queueHandshake([UUID(uuidString: "00000000-0000-0000-0000-000000000002")!])]
        let dictionaries = try envelopes.map { try $0.dictionaryRepresentation() }
        var received: [WatchConnectivityEnvelope] = []
        let replies = NativeWatchResults()
        adapter.onReceivedEnvelope = { envelope, reply in
            received.append(envelope)
            reply?(.snapshotRequest)
            reply?(.queueHandshake([]))
        }
        adapter.receivedApplicationContext(dictionaries[0])
        adapter.receivedMessage(dictionaries[1])
        adapter.receivedMessage(dictionaries[2], replyHandler: {
            replies.append((try? WatchConnectivityEnvelope(dictionary: $0)) == .snapshotRequest ? "valid" : "wrong")
        })
        adapter.receivedUserInfo(dictionaries[3])
        adapter.receivedMessage([:], replyHandler: { replies.append($0.isEmpty ? "invalid" : "wrong") })
        await probe.joinAcceptedWork()
        #expect(received == envelopes)
        #expect(replies.read().sorted() == ["invalid", "valid"])
        adapter.onReceivedEnvelope = nil
        adapter.receivedMessage(dictionaries[0], replyHandler: { replies.append($0.isEmpty ? "no-listener" : "wrong") })
        await probe.joinAcceptedWork()
        #expect(replies.read().last == "no-listener")
        adapter.stopForSessionTransition()
        try await drainAndIndependentlyJoin(adapter, probe)
    }

    @Test func queuedNotificationsAndAllRawRoutesAreDiscardedWithoutReplies() async throws {
        let native = NativeWatchOperationsSpy()
        let probe = NativeWatchGateProbe()
        let adapter = makeAdapter(native, probe)
        let results = NativeWatchResults()
        let dictionary = try WatchConnectivityEnvelope.snapshotRequest.dictionaryRepresentation()
        adapter.onActivationCompleted = { _, _ in results.append("activation") }
        adapter.onReachabilityChanged = { _ in results.append("reachable") }
        adapter.onTransferCompleted = { _, _ in results.append("transfer") }
        adapter.onReceivedEnvelope = { _, _ in results.append("receive") }
        adapter.activationCompleted(activated: true, error: nil)
        adapter.becameInactive()
        adapter.deactivated()
        adapter.reachabilityChanged(true)
        adapter.transferCompleted(dictionary, error: nil)
        adapter.receivedApplicationContext(dictionary)
        adapter.receivedMessage(dictionary)
        adapter.receivedUserInfo(dictionary)
        adapter.receivedMessage(dictionary, replyHandler: { _ in results.append("valid-reply") })
        adapter.receivedMessage([:], replyHandler: { _ in results.append("invalid-reply") })
        #expect(probe.read().state.activeTokenCount == 6)
        adapter.stopForSessionTransition()
        try await drainAndIndependentlyJoin(adapter, probe)
        #expect(probe.read().state.activeTokenCount == 0)
        await probe.joinAcceptedWork()
        #expect(results.read().isEmpty)
        #expect(native.activationCount == 0)
    }

    @Test func activationAndNativeInstallReentryCannotReactivateStoppedAdapter() async throws {
        for stopDuringInstall in [false, true] {
            let native = NativeWatchOperationsSpy()
            let probe = NativeWatchGateProbe()
            let adapter = makeAdapter(native, probe)
            if stopDuringInstall {
                native.onInstall = { [weak adapter] in adapter?.stopForSessionTransition() }
                adapter.activate()
            } else {
                adapter.onActivationCompleted = { [weak adapter] _, _ in adapter?.stopForSessionTransition() }
                adapter.deactivated()
            }
            await probe.joinAcceptedWork()
            try await drainAndIndependentlyJoin(adapter, probe)
            #expect(native.activationCount == 0)
            #expect(native.owner == nil)
        }
    }

    @Test func savedInboundReplyChecksLifetimeWhenUsed() async throws {
        let native = NativeWatchOperationsSpy()
        let probe = NativeWatchGateProbe()
        let adapter = makeAdapter(native, probe)
        var saved: WatchConnectivityEnvelopeReply?
        let replies = NativeWatchResults()
        adapter.onReceivedEnvelope = { _, reply in saved = reply }
        adapter.receivedMessage(try WatchConnectivityEnvelope.snapshotRequest.dictionaryRepresentation(), replyHandler: { _ in replies.append("reply") })
        await probe.joinAcceptedWork()
        #expect(saved != nil)
        adapter.stopForSessionTransition()
        saved?(.snapshotRequest)
        try await drainAndIndependentlyJoin(adapter, probe)
        #expect(probe.read().state.activeTokenCount == 0)
        #expect(replies.read().isEmpty)
    }

    @Test func replyQueuedBeforeStopAndRemainderOfFIFOAreSilent() async throws {
        let native = NativeWatchOperationsSpy()
        let probe = NativeWatchGateProbe()
        let adapter = makeAdapter(native, probe)
        let replies = NativeWatchResults()
        var received = 0
        adapter.onReceivedEnvelope = { [weak adapter] _, reply in
            received += 1
            reply?(.snapshotRequest)
            adapter?.stopForSessionTransition()
        }
        let dictionary = try WatchConnectivityEnvelope.snapshotRequest.dictionaryRepresentation()
        adapter.receivedMessage(dictionary, replyHandler: { _ in replies.append("reply") })
        adapter.receivedMessage(dictionary)
        adapter.receivedMessage([:], replyHandler: { _ in replies.append("failure") })
        await probe.joinAcceptedWork()
        try await drainAndIndependentlyJoin(adapter, probe)
        #expect(received == 1)
        #expect(replies.read().isEmpty)
    }

    @Test func supportAndNativeActivationCalloutsCanSynchronouslyStop() async throws {
        for entry in ["activate", "reachability", "deactivated"] {
            let native = NativeWatchOperationsSpy()
            let probe = NativeWatchGateProbe()
            let adapter = PhoneWatchSession(session: native, isSupported: {
                MainActor.assumeIsolated {
                    native.owner?.stopForSessionTransition()
                    return true
                }
            }, observeCallbackGateState: probe.record)
            native.owner = adapter
            switch entry {
            case "activate": adapter.activate()
            case "reachability": #expect(!adapter.isReachable)
            default: adapter.deactivated()
            }
            await probe.joinAcceptedWork()
            try await drainAndIndependentlyJoin(adapter, probe)
            #expect(native.installCount == 0 && native.activationCount == 0)
            #expect(native.reachabilityReadCount == 0)
        }

        let native = NativeWatchOperationsSpy()
        let probe = NativeWatchGateProbe()
        let adapter = makeAdapter(native, probe)
        native.onActivate = { [weak adapter] in adapter?.stopForSessionTransition() }
        adapter.activate()
        try await drainAndIndependentlyJoin(adapter, probe)
        #expect(native.activationCount == 1)
        #expect(native.owner == nil)
        adapter.activate()
        #expect(native.activationCount == 1)
    }

    @Test func unsupportedAdapterDoesNotInstallActivateOrQueryReachability() async throws {
        let native = NativeWatchOperationsSpy()
        let probe = NativeWatchGateProbe()
        let adapter = PhoneWatchSession(session: native, isSupported: { false }, observeCallbackGateState: probe.record)
        adapter.activate()
        #expect(!adapter.isReachable)
        adapter.deactivated()
        await probe.joinAcceptedWork()
        #expect(native.installCount == 0 && native.activationCount == 0)
        #expect(native.reachabilityReadCount == 0)
        adapter.stopForSessionTransition()
        try await drainAndIndependentlyJoin(adapter, probe)
    }

    @Test func outgoingReplyErrorCompetitionIsOneShotAndArrivalsAreOwned() async throws {
        for errorFirst in [false, true] {
            let native = NativeWatchOperationsSpy()
            let probe = NativeWatchGateProbe()
            let adapter = makeAdapter(native, probe)
            let results = NativeWatchResults()
            adapter.sendMessage(.snapshotRequest, reply: { _ in results.append("reply") }, failure: { _ in results.append("error") })
            #expect(probe.read().state.activeTokenCount == 0)
            let dictionary = try WatchConnectivityEnvelope.snapshotRequest.dictionaryRepresentation()
            if errorFirst { native.errors[0](NativeWatchTestError()) }
            else { native.replies[0](dictionary) }
            #expect(probe.read().state.activeTokenCount == 1)
            await probe.joinAcceptedWork()
            native.replies[0](dictionary)
            native.errors[0](NativeWatchTestError())
            #expect(probe.read().state.activeTokenCount == 2)
            await probe.joinAcceptedWork()
            #expect(results.read() == [errorFirst ? "error" : "reply"])
            adapter.stopForSessionTransition()
            try await drainAndIndependentlyJoin(adapter, probe)
        }
    }

    @Test func concurrentNativeReplyAndErrorHaveExactlyOneWinner() async throws {
        let native = NativeWatchOperationsSpy()
        let probe = NativeWatchGateProbe()
        let adapter = makeAdapter(native, probe)
        let results = NativeWatchResults()
        adapter.sendMessage(.snapshotRequest, reply: { _ in results.append("reply") }, failure: { _ in results.append("error") })
        let callbacks = NativeWatchConcurrentCallbacks(reply: native.replies[0], failure: native.errors[0])
        await withTaskGroup(of: Void.self) { group in
            group.addTask { callbacks.reply(["kind": "snapshotRequest", "payload": Data()]) }
            group.addTask { callbacks.failure(NativeWatchTestError()) }
        }
        await probe.joinAcceptedWork()
        #expect(results.read().count == 1)
        #expect(results.read() == ["reply"] || results.read() == ["error"])
        adapter.stopForSessionTransition()
        try await drainAndIndependentlyJoin(adapter, probe)
    }

    @Test func malformedOutgoingReplyFailsOnceAndNativeClosuresDoNotRetainAdapter() async throws {
        let native = NativeWatchOperationsSpy()
        let probe = NativeWatchGateProbe()
        var adapter: PhoneWatchSession? = makeAdapter(native, probe)
        let weakAdapter = { [weak adapter] in adapter }
        let results = NativeWatchResults()
        adapter?.activate()
        adapter?.sendMessage(.snapshotRequest, reply: { _ in results.append("reply") }, failure: { _ in results.append("error") })
        native.replies[0]([:])
        await probe.joinAcceptedWork()
        native.errors[0](NativeWatchTestError())
        await probe.joinAcceptedWork()
        #expect(results.read() == ["error"])
        adapter?.stopForSessionTransition()
        try await adapter?.waitForStoppedOperations()
        adapter = nil
        #expect(weakAdapter() == nil)
        native.replies[0]([:])
        native.errors[0](NativeWatchTestError())
        #expect(results.read() == ["error"])
    }

    @Test func queuedAndLateOutgoingCompletionsCannotPublishAfterStop() async throws {
        let native = NativeWatchOperationsSpy()
        let probe = NativeWatchGateProbe()
        let adapter = makeAdapter(native, probe)
        let results = NativeWatchResults()
        adapter.sendMessage(.snapshotRequest, reply: { _ in results.append("reply") }, failure: { _ in results.append("error") })
        let dictionary = try WatchConnectivityEnvelope.snapshotRequest.dictionaryRepresentation()
        native.replies[0](dictionary)
        native.errors[0](NativeWatchTestError())
        #expect(probe.read().state.activeTokenCount == 2)
        adapter.stopForSessionTransition()
        try await drainAndIndependentlyJoin(adapter, probe)
        await probe.joinAcceptedWork()
        native.replies[0](dictionary)
        native.errors[0](NativeWatchTestError())
        #expect(probe.read().state.activeTokenCount == 0)
        #expect(results.read().isEmpty)
    }

    @Test func stoppedPublicAPIsAndLateIngressDoNotTouchNativeOrAdmitWork() async throws {
        let native = NativeWatchOperationsSpy()
        let probe = NativeWatchGateProbe()
        let adapter = makeAdapter(native, probe)
        let results = NativeWatchResults()
        adapter.onReceivedEnvelope = { _, _ in results.append("receive") }
        adapter.onActivationCompleted = { _, _ in results.append("activation") }
        adapter.onReachabilityChanged = { _ in results.append("reachable") }
        adapter.onTransferCompleted = { _, _ in results.append("transfer") }
        adapter.activate()
        native.onRemove = { [weak adapter] in
            adapter?.activate()
            adapter?.stopForSessionTransition()
        }
        adapter.stopForSessionTransition()
        adapter.stopForSessionTransition()
        #expect(adapter.onReceivedEnvelope == nil)
        #expect(adapter.onActivationCompleted == nil)
        #expect(adapter.onReachabilityChanged == nil)
        #expect(adapter.onTransferCompleted == nil)
        #expect(!adapter.isReachable)
        adapter.activate()
        #expect(throws: PhoneWatchSessionError.stopped) { try adapter.updateApplicationContext(.snapshotRequest) }
        adapter.transferUserInfo(.snapshotRequest)
        adapter.sendMessage(.snapshotRequest, reply: { _ in results.append("reply") }, failure: { _ in results.append("error") })
        adapter.activationCompleted(activated: true, error: nil)
        adapter.becameInactive()
        adapter.deactivated()
        adapter.reachabilityChanged(true)
        adapter.transferCompleted([:], error: nil)
        adapter.receivedApplicationContext([:])
        adapter.receivedMessage([:])
        adapter.receivedMessage([:], replyHandler: { _ in results.append("inbound") })
        adapter.receivedUserInfo([:])
        try await drainAndIndependentlyJoin(adapter, probe)
        #expect(probe.read().maximumActive == 0)
        #expect(native.installCount == 1 && native.activationCount == 1)
        #expect(native.removalCount == 1 && native.owner == nil)
        #expect(native.reachabilityReadCount == 0)
        #expect(native.contexts.isEmpty && native.messages.isEmpty && native.userInfos.isEmpty)
        #expect(results.read().isEmpty)
    }

    @Test func openWaitThrowsAndStoppingOldOwnerLeavesReplacementLive() async throws {
        let native = NativeWatchOperationsSpy()
        let oldProbe = NativeWatchGateProbe()
        let newProbe = NativeWatchGateProbe()
        let old = makeAdapter(native, oldProbe)
        let replacement = makeAdapter(native, newProbe)
        await #expect(throws: AppSessionProducerDrainError.producerStillActive) { try await old.waitForStoppedOperations() }
        old.activate()
        replacement.activate()
        old.stopForSessionTransition()
        #expect(native.owner === replacement)
        var received = 0
        replacement.onReceivedEnvelope = { _, _ in received += 1 }
        replacement.receivedMessage(try WatchConnectivityEnvelope.snapshotRequest.dictionaryRepresentation())
        await newProbe.joinAcceptedWork()
        #expect(received == 1)
        #expect(replacement.isReachable)
        try await old.waitForStoppedOperations()
        replacement.stopForSessionTransition()
        try await replacement.waitForStoppedOperations()
    }

    @Test func twoWaitersAndCancellationJoinAnActuallyAcceptedCallback() async throws {
        let native = NativeWatchOperationsSpy()
        let probe = NativeWatchGateProbe()
        let hold = NativeWatchAdmissionHold()
        let adapter = PhoneWatchSession(session: native, isSupported: { true }, observeCallbackGateState: { state in
            probe.record(state)
            if !state.isClosed && state.activeTokenCount == 1 { hold.hold() }
        })
        // Hold the real callback after admission but before creating its MainActor
        // Task. This leaves MainActor free for two actual drain registrations.
        let ingress = Task.detached { adapter.activationCompleted(activated: true, error: nil) }
        await probe.wait { $0.state.activeTokenCount == 1 }
        adapter.stopForSessionTransition()
        let cancelled = Task { @MainActor in
            defer { probe.returned("cancelled") }
            try await adapter.waitForStoppedOperations()
        }
        let peer = Task { @MainActor in
            defer { probe.returned("peer") }
            try await adapter.waitForStoppedOperations()
        }
        // Early drain returns also wake the test so the broken-drain RED can
        // assert, release and independently join instead of hanging at a fence.
        await probe.wait { $0.state.waiterCount == 2 || !$0.returnedWhileActive.isEmpty }
        #expect(probe.read().state.waiterCount == 2)
        cancelled.cancel()
        let cancelledResult = await cancelled.result
        #expect(probe.read().returnedWhileActive["peer"] == nil)
        #expect(probe.read().state.activeTokenCount == 1)
        hold.release()
        await ingress.value
        await probe.joinAcceptedWork()
        let peerResult = await peer.result
        #expect(throws: CancellationError.self) { try cancelledResult.get() }
        try peerResult.get()
        #expect(probe.read().returnedWhileActive["peer"] == false)
        #expect(probe.read().state.activeTokenCount == 0)
        #expect(probe.read().state.waiterCount == 0)
    }
}
