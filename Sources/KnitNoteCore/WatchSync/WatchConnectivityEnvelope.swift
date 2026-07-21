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
