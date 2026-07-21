import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct WatchConnectivityAdapterSourceContractTests {
    @Test func adaptersIsolateCallbacksAndExposeInjectableSessionOperations() throws {
        for path in [
            "KnitNote/WatchSync/PhoneWatchSession.swift",
            "KnitNoteWatch/Sync/WatchSession.swift"
        ] {
            let adapter = try source(path)

            #expect(adapter.contains("protocol WatchConnectivitySessionOperations"))
            #expect(adapter.contains("extension WCSession: WatchConnectivitySessionOperations"))
            #expect(adapter.contains("@MainActor\nfinal class"))
            #expect(adapter.contains("any WatchConnectivitySessionOperations"))
            #expect(adapter.contains("isSupported: @escaping @Sendable () -> Bool"))
            #expect(adapter.contains("nonisolated func session("))
            #expect(adapter.contains("Task { @MainActor"))
            #expect(!adapter.contains("final class PhoneWatchSession: NSObject, WCSessionDelegate, @unchecked Sendable"))
            #expect(!adapter.contains("final class WatchSession: NSObject, WCSessionDelegate, @unchecked Sendable"))
        }
    }

    @Test func interactiveCallbacksHaveOneShotFailurePaths() throws {
        for path in [
            "KnitNote/WatchSync/PhoneWatchSession.swift",
            "KnitNoteWatch/Sync/WatchSession.swift"
        ] {
            let adapter = try source(path)

            #expect(adapter.contains("WatchConnectivityReplyHandlerBox"))
            #expect(adapter.contains("replyBox.fail()"))
            #expect(adapter.contains("WatchConnectivityMessageCompletion"))
            #expect(!adapter.contains("guard let dictionary = try? envelope.dictionaryRepresentation() else { return }"))
        }
    }

    @Test func everyRawReceivePathUsesOneSharedFIFODrain() throws {
        for path in [
            "KnitNote/WatchSync/PhoneWatchSession.swift",
            "KnitNoteWatch/Sync/WatchSession.swift"
        ] {
            let adapter = try source(path)

            #expect(adapter.contains("private nonisolated let receiveFIFO"))
            #expect(adapter.components(separatedBy: "enqueueReceived(").count - 1 == 5)
            #expect(adapter.contains("while let delivery = receiveFIFO.dequeue()"))
            #expect(!adapter.contains("Task { @MainActor [weak self] in\n            self?.receive(dictionaryBox.value)"))
        }
    }

    @Test func receiveFIFORequestsExactlyOneDrainAndKeepsInsertionOrder() throws {
        let fifo = WatchConnectivityReceiveFIFO()
        let deliveries = (0..<4).map {
            WatchConnectivityInboundDelivery(dictionary: ["sequence": $0], replyBox: nil)
        }

        #expect(fifo.enqueue(deliveries[0]))
        #expect(!fifo.enqueue(deliveries[1]))
        #expect(!fifo.enqueue(deliveries[2]))
        #expect(!fifo.enqueue(deliveries[3]))

        var received: [Int] = []
        while let delivery = fifo.dequeue() {
            received.append(try #require(delivery.dictionary["sequence"] as? Int))
        }
        #expect(received == [0, 1, 2, 3])

        #expect(fifo.enqueue(deliveries[0]))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }
}
