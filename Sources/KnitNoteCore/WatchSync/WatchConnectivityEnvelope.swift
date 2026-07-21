import Foundation

public enum WatchConnectivityEnvelopeError: Error, Equatable, Sendable {
    case missingKind
    case invalidKindType
    case missingPayload
    case invalidPayloadType
    case unsupportedKind(String)
}

public enum WatchConnectivityEnvelope: Equatable, Sendable {
    case snapshotRequest
    case snapshot(WatchSyncSnapshot)
    case command(WatchCounterCommand)
    case acknowledgement(WatchCommandAcknowledgement)
    case queueHandshake([UUID])

    public func dictionaryRepresentation() throws -> [String: Any] {
        let kind: Kind
        let payload: Data

        switch self {
        case .snapshotRequest:
            kind = .snapshotRequest
            payload = Data()
        case let .snapshot(snapshot):
            kind = .snapshot
            payload = try WatchSyncCodec.encode(snapshot)
        case let .command(command):
            kind = .command
            payload = try WatchSyncCodec.encode(command)
        case let .acknowledgement(acknowledgement):
            kind = .acknowledgement
            payload = try WatchSyncCodec.encode(acknowledgement)
        case let .queueHandshake(commandIDs):
            kind = .queueHandshake
            payload = try WatchSyncCodec.encode(commandIDs)
        }

        return [
            Keys.kind: kind.rawValue,
            Keys.payload: payload
        ]
    }

    public init(dictionary: [String: Any]) throws {
        guard let rawKind = dictionary[Keys.kind] else {
            throw WatchConnectivityEnvelopeError.missingKind
        }
        guard let kindString = rawKind as? String else {
            throw WatchConnectivityEnvelopeError.invalidKindType
        }
        guard let kind = Kind(rawValue: kindString) else {
            throw WatchConnectivityEnvelopeError.unsupportedKind(kindString)
        }
        guard let rawPayload = dictionary[Keys.payload] else {
            throw WatchConnectivityEnvelopeError.missingPayload
        }
        guard let payload = rawPayload as? Data else {
            throw WatchConnectivityEnvelopeError.invalidPayloadType
        }

        self = switch kind {
        case .snapshotRequest:
            .snapshotRequest
        case .snapshot:
            .snapshot(try WatchSyncCodec.decode(WatchSyncSnapshot.self, from: payload))
        case .command:
            .command(try WatchSyncCodec.decode(WatchCounterCommand.self, from: payload))
        case .acknowledgement:
            .acknowledgement(try WatchSyncCodec.decode(
                WatchCommandAcknowledgement.self,
                from: payload
            ))
        case .queueHandshake:
            .queueHandshake(try WatchSyncCodec.decode([UUID].self, from: payload))
        }
    }
}

public typealias WatchConnectivityEnvelopeReply = @Sendable (WatchConnectivityEnvelope) -> Void
public typealias WatchConnectivityFailure = @Sendable (Error) -> Void
public typealias WatchConnectivityReceivedEnvelope = @MainActor @Sendable (
    WatchConnectivityEnvelope,
    WatchConnectivityEnvelopeReply?
) -> Void
public typealias WatchConnectivityReachabilityChanged = @MainActor @Sendable (Bool) -> Void
public typealias WatchConnectivityActivationCompleted = @MainActor @Sendable (Bool, Error?) -> Void
public typealias WatchConnectivityTransferCompleted = @MainActor @Sendable (
    WatchConnectivityEnvelope?,
    Error?
) -> Void

@MainActor
public protocol WatchConnectivityTransport: AnyObject {
    var onReceivedEnvelope: WatchConnectivityReceivedEnvelope? { get set }
    var onReachabilityChanged: WatchConnectivityReachabilityChanged? { get set }
    var onActivationCompleted: WatchConnectivityActivationCompleted? { get set }
    var onTransferCompleted: WatchConnectivityTransferCompleted? { get set }
    var isReachable: Bool { get }

    func activate()
    func updateApplicationContext(_ envelope: WatchConnectivityEnvelope) throws
    func sendMessage(
        _ envelope: WatchConnectivityEnvelope,
        reply: @escaping WatchConnectivityEnvelopeReply,
        failure: @escaping WatchConnectivityFailure
    )
    func transferUserInfo(_ envelope: WatchConnectivityEnvelope)
}

final class WatchConnectivityReplyHandlerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (([String: Any]) -> Void)?

    init(_ handler: @escaping ([String: Any]) -> Void) {
        self.handler = handler
    }

    func reply(with envelope: WatchConnectivityEnvelope) {
        do {
            call(try envelope.dictionaryRepresentation())
        } catch {
            fail()
        }
    }

    func fail() {
        call([:])
    }

    func call(_ dictionary: [String: Any]) {
        let handler = lock.withLock {
            defer { self.handler = nil }
            return self.handler
        }
        handler?(dictionary)
    }
}

final class WatchConnectivitySendableDictionary: @unchecked Sendable {
    let value: [String: Any]

    init(_ value: [String: Any]) {
        self.value = value
    }
}

final class WatchConnectivityInboundDelivery: @unchecked Sendable {
    let dictionary: [String: Any]
    let replyBox: WatchConnectivityReplyHandlerBox?

    init(
        dictionary: [String: Any],
        replyBox: WatchConnectivityReplyHandlerBox?
    ) {
        self.dictionary = dictionary
        self.replyBox = replyBox
    }
}

final class WatchConnectivityReceiveFIFO: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveries: [WatchConnectivityInboundDelivery] = []
    private var head = 0
    private var drainScheduled = false

    func enqueue(_ delivery: WatchConnectivityInboundDelivery) -> Bool {
        lock.withLock {
            deliveries.append(delivery)
            guard !drainScheduled else { return false }
            drainScheduled = true
            return true
        }
    }

    func dequeue() -> WatchConnectivityInboundDelivery? {
        lock.withLock {
            guard head < deliveries.count else {
                deliveries.removeAll(keepingCapacity: true)
                head = 0
                drainScheduled = false
                return nil
            }
            let delivery = deliveries[head]
            head += 1
            if head == deliveries.count {
                deliveries.removeAll(keepingCapacity: true)
                head = 0
            }
            return delivery
        }
    }
}

@MainActor
final class WatchConnectivityMessageCompletion {
    private var reply: WatchConnectivityEnvelopeReply?
    private var failure: WatchConnectivityFailure?

    init(
        reply: @escaping WatchConnectivityEnvelopeReply,
        failure: @escaping WatchConnectivityFailure
    ) {
        self.reply = reply
        self.failure = failure
    }

    func receive(_ dictionary: [String: Any]) {
        do {
            complete(with: .success(try WatchConnectivityEnvelope(dictionary: dictionary)))
        } catch {
            complete(with: .failure(error))
        }
    }

    func fail(_ error: Error) {
        complete(with: .failure(error))
    }

    private func complete(with result: Result<WatchConnectivityEnvelope, Error>) {
        guard reply != nil || failure != nil else { return }
        let reply = self.reply
        let failure = self.failure
        self.reply = nil
        self.failure = nil

        switch result {
        case let .success(envelope):
            reply?(envelope)
        case let .failure(error):
            failure?(error)
        }
    }
}

private extension WatchConnectivityEnvelope {
    enum Keys {
        static let kind = "kind"
        static let payload = "payload"
    }

    enum Kind: String {
        case snapshotRequest
        case snapshot
        case command
        case acknowledgement
        case queueHandshake
    }
}
