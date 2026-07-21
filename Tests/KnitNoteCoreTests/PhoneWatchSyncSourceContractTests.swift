import Foundation
import Testing

@Suite struct PhoneWatchSyncSourceContractTests {
    @Test func appOwnsAndStartsPhoneCoordinatorForItsLifetime() throws {
        let app = try source("KnitNote/App/KnitNoteApp.swift")

        #expect(app.contains("@StateObject private var phoneWatchSyncCoordinator"))
        #expect(app.contains("PhoneWatchSyncCoordinator("))
        #expect(app.contains("phoneWatchSyncCoordinator.start()"))
    }

    @Test func coordinatorObservesProjectChangesAndSerializesIncomingEnvelopes() throws {
        let coordinator = try source("KnitNote/WatchSync/PhoneWatchSyncCoordinator.swift")

        #expect(coordinator.contains("projectStore.$projects"))
        #expect(coordinator.contains("private var serialTask"))
        #expect(coordinator.contains("await previous.value"))
    }

    @Test func coordinatorHandlesEveryEnvelopeKindWithoutTraps() throws {
        let coordinator = try source("KnitNote/WatchSync/PhoneWatchSyncCoordinator.swift")

        for kind in [
            "case .snapshotRequest:",
            "case .snapshot:",
            "case let .command(",
            "case .acknowledgement:",
            "case let .queueHandshake(",
        ] {
            #expect(coordinator.contains(kind))
        }
        #expect(!coordinator.contains("try!"))
        #expect(!coordinator.contains("as!"))
        #expect(!coordinator.contains("fatalError"))
    }

    @Test func queueHandshakeOnlySeedsIDsDuringRecovery() throws {
        let coordinator = try source("KnitNote/WatchSync/PhoneWatchSyncCoordinator.swift")

        #expect(coordinator.contains("if requiresFreshHandshake {"))
        #expect(coordinator.contains("completeWatchQueueHandshake("))
        #expect(coordinator.contains("recoverWatchCommandPersistence("))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }
}
