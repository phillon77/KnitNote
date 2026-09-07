import Foundation
#if os(iOS)
import WatchConnectivity
#endif

@MainActor
protocol WatchConnectivitySessionOperations: AnyObject {
    var isReachable: Bool { get }

    func installDelegate(_ owner: PhoneWatchSession)
    func removeDelegate(ifOwnedBy owner: PhoneWatchSession)
    func activate()
    func updateApplicationContext(_ applicationContext: [String: Any]) throws
    func sendMessage(
        _ message: [String: Any],
        replyHandler: (([String: Any]) -> Void)?,
        errorHandler: ((Error) -> Void)?
    )
    func enqueueUserInfo(_ userInfo: [String: Any])
}

enum PhoneWatchSessionError: Error, Equatable {
    case stopped
}

@MainActor
final class PhoneWatchSession: NSObject, WatchConnectivityTransport, AppSessionProducer {
    var onReceivedEnvelope: WatchConnectivityReceivedEnvelope?
    var onReachabilityChanged: WatchConnectivityReachabilityChanged?
    var onActivationCompleted: WatchConnectivityActivationCompleted?
    var onTransferCompleted: WatchConnectivityTransferCompleted?

    private let session: any WatchConnectivitySessionOperations
    private let isSupported: @Sendable () -> Bool
    private nonisolated let receiveFIFO = WatchConnectivityReceiveFIFO()
    private nonisolated let callbackGate: AppSessionCallbackGate
    private var stopped = false

    var isReachable: Bool {
        guard !stopped, isSupported(), !stopped else { return false }
        let reachable = session.isReachable
        return !stopped && reachable
    }

    init(
        session: any WatchConnectivitySessionOperations,
        isSupported: @escaping @Sendable () -> Bool,
        observeCallbackGateState: @escaping @Sendable (AppSessionCallbackGate.State) -> Void = { _ in }
    ) {
        self.session = session
        self.isSupported = isSupported
        callbackGate = AppSessionCallbackGate(observeState: observeCallbackGateState)
        super.init()
    }

    #if os(iOS)
    override convenience init() {
        self.init(session: WCSession.default, isSupported: { WCSession.isSupported() })
    }
    #endif

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

    func activate() {
        guard !stopped, isSupported(), !stopped else { return }
        session.installDelegate(self)
        guard !stopped else { return }
        session.activate()
    }

    func updateApplicationContext(_ envelope: WatchConnectivityEnvelope) throws {
        guard !stopped else { throw PhoneWatchSessionError.stopped }
        try session.updateApplicationContext(envelope.dictionaryRepresentation())
    }

    func sendMessage(
        _ envelope: WatchConnectivityEnvelope,
        reply: @escaping WatchConnectivityEnvelopeReply,
        failure: @escaping WatchConnectivityFailure
    ) {
        guard !stopped else { return }
        let dictionary: [String: Any]
        do {
            dictionary = try envelope.dictionaryRepresentation()
        } catch {
            failure(error)
            return
        }

        let completion = WatchConnectivityMessageCompletion(reply: reply, failure: failure)
        session.sendMessage(
            dictionary,
            replyHandler: { [weak self] dictionary in
                let dictionaryBox = WatchConnectivitySendableDictionary(dictionary)
                self?.enqueueCallback { _ in
                    completion.receive(dictionaryBox.value)
                }
            },
            errorHandler: { [weak self] error in
                self?.enqueueCallback { _ in
                    completion.fail(error)
                }
            }
        )
    }

    func transferUserInfo(_ envelope: WatchConnectivityEnvelope) {
        guard !stopped else { return }
        do {
            session.enqueueUserInfo(try envelope.dictionaryRepresentation())
        } catch {
            onTransferCompleted?(envelope, error)
        }
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

    nonisolated func activationCompleted(activated: Bool, error: Error?) {
        enqueueCallback { adapter in
            adapter.onActivationCompleted?(activated, error)
        }
    }

    nonisolated func becameInactive() {
        activationCompleted(activated: false, error: nil)
    }

    nonisolated func deactivated() {
        enqueueCallback { adapter in
            adapter.onActivationCompleted?(false, nil)
            guard !adapter.stopped, adapter.isSupported(), !adapter.stopped else { return }
            adapter.session.activate()
        }
    }

    nonisolated func reachabilityChanged(_ reachable: Bool) {
        enqueueCallback { adapter in
            adapter.onReachabilityChanged?(reachable)
        }
    }

    nonisolated func receivedApplicationContext(_ applicationContext: [String: Any]) {
        enqueueReceived(applicationContext)
    }

    nonisolated func receivedMessage(_ message: [String: Any]) {
        enqueueReceived(message)
    }

    nonisolated func receivedMessage(
        _ message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let replyBox = WatchConnectivityReplyHandlerBox(replyHandler)
        enqueueReceived(message, replyBox: replyBox)
    }

    nonisolated func receivedUserInfo(_ userInfo: [String: Any]) {
        enqueueReceived(userInfo)
    }

    private nonisolated func enqueueReceived(
        _ dictionary: [String: Any],
        replyBox: WatchConnectivityReplyHandlerBox? = nil
    ) {
        guard let token = callbackGate.begin() else { return }
        let delivery = WatchConnectivityInboundDelivery(
            dictionary: dictionary,
            replyBox: replyBox
        )
        guard receiveFIFO.enqueue(delivery) else {
            callbackGate.finish(token)
            return
        }
        Task { @MainActor in
            defer { callbackGate.finish(token) }
            drainReceiveFIFO()
        }
    }

    private func drainReceiveFIFO() {
        while let delivery = receiveFIFO.dequeue() {
            guard !stopped else { continue }
            receive(delivery.dictionary, replyBox: delivery.replyBox)
        }
    }

    nonisolated func transferCompleted(
        _ userInfo: [String: Any],
        error: Error?
    ) {
        let dictionaryBox = WatchConnectivitySendableDictionary(userInfo)
        enqueueCallback { adapter in
            do {
                let envelope = try WatchConnectivityEnvelope(dictionary: dictionaryBox.value)
                adapter.onTransferCompleted?(envelope, error)
            } catch let decodingError {
                adapter.onTransferCompleted?(nil, error ?? decodingError)
            }
        }
    }

    private func receive(
        _ dictionary: [String: Any],
        replyBox: WatchConnectivityReplyHandlerBox? = nil
    ) {
        guard let envelope = try? WatchConnectivityEnvelope(dictionary: dictionary) else {
            if let replyBox { replyBox.fail() }
            return
        }
        guard let onReceivedEnvelope else {
            if let replyBox { replyBox.fail() }
            return
        }

        let reply: WatchConnectivityEnvelopeReply?
        if let replyBox {
            reply = { [weak self] envelope in
                self?.enqueueCallback { _ in replyBox.reply(with: envelope) }
            }
        } else {
            reply = nil
        }
        onReceivedEnvelope(envelope, reply)
    }
}

#if os(iOS)
extension WCSession: WatchConnectivitySessionOperations {
    func installDelegate(_ owner: PhoneWatchSession) {
        delegate = owner
    }

    func removeDelegate(ifOwnedBy owner: PhoneWatchSession) {
        if delegate === owner { delegate = nil }
    }

    func enqueueUserInfo(_ userInfo: [String: Any]) {
        transferUserInfo(userInfo)
    }
}

extension PhoneWatchSession: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        activationCompleted(activated: activationState == .activated, error: error)
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        becameInactive()
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        deactivated()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        reachabilityChanged(session.isReachable)
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receivedApplicationContext(applicationContext)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receivedMessage(message)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        receivedMessage(message, replyHandler: replyHandler)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        receivedUserInfo(userInfo)
    }

    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        transferCompleted(userInfoTransfer.userInfo, error: error)
    }
}
#endif
