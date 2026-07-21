import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct WatchConnectivityEnvelopeTests {
    @Test func commandEnvelopeRoundTripsThroughPropertyListDictionary() throws {
        let command = WatchCounterCommand(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            counterID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            operation: .reset,
            createdAt: Date(timeIntervalSince1970: 42)
        )

        let dictionary = try WatchConnectivityEnvelope.command(command).dictionaryRepresentation()

        #expect(try WatchConnectivityEnvelope(dictionary: dictionary) == .command(command))
    }

    @Test func everyEnvelopeKindRoundTripsWithADataPayload() throws {
        let snapshot = WatchSyncSnapshot(
            generatedAt: Date(timeIntervalSince1970: 100),
            projects: []
        )
        let commandID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let acknowledgement = WatchCommandAcknowledgement(
            commandID: commandID,
            rejection: nil,
            snapshot: snapshot
        )
        let queueIDs = [
            commandID,
            UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        ]
        let envelopes: [WatchConnectivityEnvelope] = [
            .snapshotRequest,
            .snapshot(snapshot),
            .acknowledgement(acknowledgement),
            .queueHandshake(queueIDs)
        ]

        for envelope in envelopes {
            let dictionary = try envelope.dictionaryRepresentation()
            #expect(dictionary["kind"] is String)
            #expect(dictionary["payload"] is Data)
            #expect(try WatchConnectivityEnvelope(dictionary: dictionary) == envelope)
        }
    }

    @Test func missingKindIsRejected() {
        #expect(throws: WatchConnectivityEnvelopeError.missingKind) {
            _ = try WatchConnectivityEnvelope(dictionary: ["payload": Data()])
        }
    }

    @Test func missingPayloadIsRejected() {
        #expect(throws: WatchConnectivityEnvelopeError.missingPayload) {
            _ = try WatchConnectivityEnvelope(dictionary: ["kind": "snapshotRequest"])
        }
    }

    @Test func wrongPayloadTypeIsRejected() {
        #expect(throws: WatchConnectivityEnvelopeError.invalidPayloadType) {
            _ = try WatchConnectivityEnvelope(dictionary: [
                "kind": "snapshotRequest",
                "payload": "not data"
            ])
        }
    }

    @Test func unsupportedKindIsRejected() {
        #expect(throws: WatchConnectivityEnvelopeError.unsupportedKind("futureKind")) {
            _ = try WatchConnectivityEnvelope(dictionary: [
                "kind": "futureKind",
                "payload": Data()
            ])
        }
    }

    @Test func replyHandlerBoxInvokesItsHandlerOnlyOnceAcrossConcurrentCalls() async {
        let invocationCount = LockedInvocationCount()
        let box = WatchConnectivityReplyHandlerBox { _ in
            invocationCount.increment()
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    box.call([:])
                }
            }
        }

        #expect(invocationCount.value == 1)
    }

    @Test func replyEncodingFailureReturnsOneDeterministicInvalidDictionary() {
        let replies = LockedReplies()
        let box = WatchConnectivityReplyHandlerBox { dictionary in
            replies.append(dictionary)
        }
        let invalidSnapshot = WatchSyncSnapshot(
            generatedAt: Date(timeIntervalSince1970: .infinity),
            projects: []
        )

        box.reply(with: .snapshot(invalidSnapshot))
        box.reply(with: .snapshotRequest)

        #expect(replies.values.count == 1)
        #expect(replies.values[0].isEmpty)
    }

    @MainActor
    @Test func transportProtocolSupportsFakeInjectionWithoutWatchConnectivity() throws {
        let transport: any WatchConnectivityTransport = FakeWatchConnectivityTransport()
        let snapshot = WatchSyncSnapshot(generatedAt: .now, projects: [])

        try transport.updateApplicationContext(.snapshot(snapshot))
        transport.transferUserInfo(.snapshotRequest)

        #expect(transport.isReachable)
    }
}

private final class LockedInvocationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class LockedReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String: Any]] = []

    var values: [[String: Any]] {
        lock.withLock { storage }
    }

    func append(_ dictionary: [String: Any]) {
        lock.withLock { storage.append(dictionary) }
    }
}

@MainActor
private final class FakeWatchConnectivityTransport: WatchConnectivityTransport {
    var onReceivedEnvelope: WatchConnectivityReceivedEnvelope?
    var onReachabilityChanged: WatchConnectivityReachabilityChanged?
    var onActivationCompleted: WatchConnectivityActivationCompleted?
    var onTransferCompleted: WatchConnectivityTransferCompleted?
    let isReachable = true

    func activate() {}

    func updateApplicationContext(_ envelope: WatchConnectivityEnvelope) throws {}

    func sendMessage(
        _ envelope: WatchConnectivityEnvelope,
        reply: @escaping WatchConnectivityEnvelopeReply,
        failure: @escaping WatchConnectivityFailure
    ) {}

    func transferUserInfo(_ envelope: WatchConnectivityEnvelope) {}
}
