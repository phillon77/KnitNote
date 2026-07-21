#if os(iOS)
import Foundation
import WatchConnectivity

final class PhoneWatchSession: NSObject, WCSessionDelegate, @unchecked Sendable {
    typealias EnvelopeReply = @Sendable (WatchConnectivityEnvelope) -> Void
    typealias ReceivedEnvelope = @Sendable (
        WatchConnectivityEnvelope,
        EnvelopeReply?
    ) -> Void

    var onReceivedEnvelope: ReceivedEnvelope?
    var onReachabilityChanged: (@Sendable (Bool) -> Void)?
    var onActivationCompleted: (@Sendable (WCSessionActivationState, Error?) -> Void)?
    var onTransferCompleted: (@Sendable (WatchConnectivityEnvelope?, Error?) -> Void)?

    private let session: WCSession

    var isReachable: Bool {
        WCSession.isSupported() && session.isReachable
    }

    init(session: WCSession = .default) {
        self.session = session
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    func updateApplicationContext(_ envelope: WatchConnectivityEnvelope) throws {
        try session.updateApplicationContext(envelope.dictionaryRepresentation())
    }

    func sendMessage(
        _ envelope: WatchConnectivityEnvelope,
        reply: @escaping @Sendable (WatchConnectivityEnvelope) -> Void,
        failure: @escaping @Sendable (Error) -> Void
    ) {
        do {
            session.sendMessage(
                try envelope.dictionaryRepresentation(),
                replyHandler: { dictionary in
                    do {
                        reply(try WatchConnectivityEnvelope(dictionary: dictionary))
                    } catch {
                        failure(error)
                    }
                },
                errorHandler: failure
            )
        } catch {
            failure(error)
        }
    }

    func transferUserInfo(_ envelope: WatchConnectivityEnvelope) {
        do {
            session.transferUserInfo(try envelope.dictionaryRepresentation())
        } catch {
            onTransferCompleted?(envelope, error)
        }
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        onActivationCompleted?(activationState, error)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        onActivationCompleted?(.inactive, nil)
    }

    func sessionDidDeactivate(_ session: WCSession) {
        onActivationCompleted?(.notActivated, nil)
        if WCSession.isSupported() {
            session.activate()
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        onReachabilityChanged?(session.isReachable)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receive(message)
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let replyBox = ReplyHandlerBox(replyHandler)
        receive(message) { envelope in
            guard let dictionary = try? envelope.dictionaryRepresentation() else { return }
            replyBox.call(dictionary)
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        receive(userInfo)
    }

    func session(
        _ session: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: Error?
    ) {
        let envelope = try? WatchConnectivityEnvelope(dictionary: userInfoTransfer.userInfo)
        onTransferCompleted?(envelope, error)
    }

    private func receive(_ dictionary: [String: Any], reply: EnvelopeReply? = nil) {
        guard let envelope = try? WatchConnectivityEnvelope(dictionary: dictionary) else { return }
        onReceivedEnvelope?(envelope, reply)
    }
}

private final class ReplyHandlerBox: @unchecked Sendable {
    private let handler: ([String: Any]) -> Void

    init(_ handler: @escaping ([String: Any]) -> Void) {
        self.handler = handler
    }

    func call(_ dictionary: [String: Any]) {
        handler(dictionary)
    }
}
#endif
