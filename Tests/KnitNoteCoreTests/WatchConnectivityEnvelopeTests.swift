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
}
