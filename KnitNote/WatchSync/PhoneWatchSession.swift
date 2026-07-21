#if os(iOS)
import Foundation
import WatchConnectivity

protocol WatchConnectivitySessionOperations: AnyObject {
    var delegate: (any WCSessionDelegate)? { get set }
    var isReachable: Bool { get }

    func activate()
    func updateApplicationContext(_ applicationContext: [String: Any]) throws
    func sendMessage(
        _ message: [String: Any],
        replyHandler: (([String: Any]) -> Void)?,
        errorHandler: ((Error) -> Void)?
    )
    func enqueueUserInfo(_ userInfo: [String: Any])
}

extension WCSession: WatchConnectivitySessionOperations {
    func enqueueUserInfo(_ userInfo: [String: Any]) {
        transferUserInfo(userInfo)
    }
}

@MainActor
final class PhoneWatchSession: NSObject, WCSessionDelegate, WatchConnectivityTransport {
    var onReceivedEnvelope: WatchConnectivityReceivedEnvelope?
    var onReachabilityChanged: WatchConnectivityReachabilityChanged?
    var onActivationCompleted: WatchConnectivityActivationCompleted?
    var onTransferCompleted: WatchConnectivityTransferCompleted?

    private let session: any WatchConnectivitySessionOperations
    private let isSupported: @Sendable () -> Bool

    var isReachable: Bool {
        isSupported() && session.isReachable
    }

    init(
        session: any WatchConnectivitySessionOperations = WCSession.default,
        isSupported: @escaping @Sendable () -> Bool = { WCSession.isSupported() }
    ) {
        self.session = session
        self.isSupported = isSupported
        super.init()
    }

    func activate() {
        guard isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    func updateApplicationContext(_ envelope: WatchConnectivityEnvelope) throws {
        try session.updateApplicationContext(envelope.dictionaryRepresentation())
    }

    func sendMessage(
        _ envelope: WatchConnectivityEnvelope,
        reply: @escaping WatchConnectivityEnvelopeReply,
        failure: @escaping WatchConnectivityFailure
    ) {
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
            replyHandler: { dictionary in
                let dictionaryBox = WatchConnectivitySendableDictionary(dictionary)
                Task { @MainActor in
                    completion.receive(dictionaryBox.value)
                }
            },
            errorHandler: { error in
                Task { @MainActor in
                    completion.fail(error)
                }
            }
        )
    }

    func transferUserInfo(_ envelope: WatchConnectivityEnvelope) {
        do {
            session.enqueueUserInfo(try envelope.dictionaryRepresentation())
        } catch {
            onTransferCompleted?(envelope, error)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let activated = activationState == .activated
        Task { @MainActor [weak self] in
            self?.onActivationCompleted?(activated, error)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.onActivationCompleted?(false, nil)
        }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            onActivationCompleted?(false, nil)
            if isSupported() {
                self.session.activate()
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.onReachabilityChanged?(reachable)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        let dictionaryBox = WatchConnectivitySendableDictionary(applicationContext)
        Task { @MainActor [weak self] in
            self?.receive(dictionaryBox.value)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let dictionaryBox = WatchConnectivitySendableDictionary(message)
        Task { @MainActor [weak self] in
            self?.receive(dictionaryBox.value)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let dictionaryBox = WatchConnectivitySendableDictionary(message)
        let replyBox = WatchConnectivityReplyHandlerBox(replyHandler)
        Task { @MainActor [weak self] in
            guard let self else {
                replyBox.fail()
                return
            }
            receive(dictionaryBox.value, replyBox: replyBox)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let dictionaryBox = WatchConnectivitySendableDictionary(userInfo)
        Task { @MainActor [weak self] in
            self?.receive(dictionaryBox.value)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: Error?
    ) {
        let dictionaryBox = WatchConnectivitySendableDictionary(userInfoTransfer.userInfo)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let envelope = try WatchConnectivityEnvelope(dictionary: dictionaryBox.value)
                onTransferCompleted?(envelope, error)
            } catch let decodingError {
                onTransferCompleted?(nil, error ?? decodingError)
            }
        }
    }

    private func receive(
        _ dictionary: [String: Any],
        replyBox: WatchConnectivityReplyHandlerBox? = nil
    ) {
        guard let envelope = try? WatchConnectivityEnvelope(dictionary: dictionary) else {
            replyBox?.fail()
            return
        }
        guard let onReceivedEnvelope else {
            replyBox?.fail()
            return
        }

        let reply: WatchConnectivityEnvelopeReply?
        if let replyBox {
            reply = { envelope in replyBox.reply(with: envelope) }
        } else {
            reply = nil
        }
        onReceivedEnvelope(envelope, reply)
    }
}
#endif
