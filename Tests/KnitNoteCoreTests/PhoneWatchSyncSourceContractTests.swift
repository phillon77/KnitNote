import Foundation
import Testing

@Suite struct PhoneWatchSyncSourceContractTests {
    @Test func appOwnsAndStartsPhoneCoordinatorForItsLifetime() throws {
        let app = try source("KnitNote/App/KnitNoteApp.swift")

        #expect(app.contains("@StateObject private var phoneWatchSyncCoordinator"))
        #expect(app.contains("PhoneWatchSyncCoordinator("))
        #expect(app.contains("phoneWatchSyncCoordinator.start()"))
        #expect(!app.contains(".onAppear"))
    }

    @Test func coordinatorObservesProjectChangesAndSerializesIncomingEnvelopes() throws {
        let coordinator = try source("KnitNote/WatchSync/PhoneWatchSyncCoordinator.swift")

        #expect(coordinator.contains("projectStore.$projects"))
        #expect(coordinator.contains("private var serialTask"))
        #expect(coordinator.contains("await previous.value"))
        #expect(coordinator.contains("entitlementCoordinator.$snapshot"))
        #expect(coordinator.contains("entitlementCoordinator.verifiedSnapshot"))
        #expect(coordinator.contains("scheduleEntitlementExpiryRefresh"))
        #expect(coordinator.contains("entitlementExpiryTask"))
    }

    @Test func entitlementBlockDurablyAcknowledgesRemovalWithoutMutating() throws {
        let coordinator = try source("KnitNote/WatchSync/PhoneWatchSyncCoordinator.swift")

        #expect(coordinator.contains("entitlement: entitlement"))
        #expect(coordinator.contains("catch ProjectStoreError.accessRestricted"))
        #expect(coordinator.contains("acknowledgeRejectedWatchCommandDurably("))
        #expect(coordinator.contains("rejection: .entitlementRequired"))
        #expect(coordinator.contains("send(acknowledgement, reply: reply)"))
        #expect(coordinator.contains("publish(acknowledgement.snapshot)"))
    }

    @Test func watchPersistsEveryMatchedHeadAcknowledgementBeforeAdvancingDelivery() throws {
        let coordinator = try source("KnitNoteWatch/Sync/WatchSyncCoordinator.swift")
        let handler = try #require(sourceSection(
            coordinator,
            from: "private func handleAcknowledgement(",
            to: "private func beginHandshakeAndReplay()"
        ))

        #expect(handler.contains("guard candidate.acknowledge(acknowledgement) else { return }"))
        #expect(handler.contains("guard persistThenPublish(candidate) else"))
        #expect(handler.contains("deliveryState.acknowledge(acknowledgement.commandID)"))
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

        #expect(coordinator.contains("recoveryState: WatchCommandRecoveryState?"))
        #expect(coordinator.contains("reconcileWatchQueueHandshakeDurably("))
        #expect(!coordinator.contains("completeWatchQueueHandshake("))
    }

    @Test func transientCommandFailureNeverAcknowledgesTheCommand() throws {
        let coordinator = try source("KnitNote/WatchSync/PhoneWatchSyncCoordinator.swift")

        #expect(!coordinator.contains("rejection: .storageFailure"))
        #expect(coordinator.contains("catch WatchCommandPersistenceError.requiresFreshHandshake"))
        #expect(coordinator.contains("catch {\n            recoveryState = nil\n            sendSnapshot(reply: reply)"))
    }

    @Test func ingressEnqueuesSynchronouslyBeforeAnotherCallbackCanOvertakeIt() throws {
        let coordinator = try source("KnitNote/WatchSync/PhoneWatchSyncCoordinator.swift")
        let ingress = try #require(coordinator.range(of: "transport.onReceivedEnvelope"))
        let nextCallback = try #require(
            coordinator.range(of: "transport.onActivationCompleted", range: ingress.upperBound..<coordinator.endIndex)
        )
        let callbackBody = coordinator[ingress.lowerBound..<nextCallback.lowerBound]

        #expect(callbackBody.contains("self?.enqueue(envelope, reply: reply)"))
        #expect(!callbackBody.contains("Task {"))
    }

    @Test func failedApplicationContextPublicationRemainsDirty() throws {
        let coordinator = try source("KnitNote/WatchSync/PhoneWatchSyncCoordinator.swift")
        let publish = try #require(coordinator.range(of: "private func publish(_ snapshot:"))
        let suffix = coordinator[publish.lowerBound...]
        let update = try #require(suffix.range(of: "try transport.updateApplicationContext"))
        let marker = try #require(suffix.range(of: "lastPublishedProjects = snapshot.projects"))

        #expect(update.lowerBound < marker.lowerBound)
        #expect(coordinator.contains("publishLatestSnapshotIfChanged()"))
    }

    @Test func startupSeparatesOneTimeSetupFromRetryableActivation() throws {
        let coordinator = try source("KnitNote/WatchSync/PhoneWatchSyncCoordinator.swift")

        #expect(coordinator.contains("private func configureOnce()"))
        #expect(coordinator.contains("private func activate()"))
        #expect(coordinator.contains("scheduleActivationRetry()"))
        #expect(coordinator.contains("activationRetryTask"))
    }

    @Test func coldLaunchAndStructuralChangesAlsoUseReliableTransfer() throws {
        let coordinator = try source("KnitNote/WatchSync/PhoneWatchSyncCoordinator.swift")

        #expect(coordinator.contains("reliableSnapshotTransferState"))
        #expect(coordinator.contains("prepareTransfer(of: snapshot)"))
        #expect(coordinator.contains("transport.transferUserInfo(.snapshot(snapshot))"))
        #expect(coordinator.contains("transport.onTransferCompleted ="))
        #expect(coordinator.contains("recordFailure(of: snapshot)"))
        #expect(coordinator.contains("scheduleReliableSnapshotRetry()"))
        #expect(!coordinator.contains("lastReliablyTransferredFingerprint"))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    private func sourceSection(
        _ source: String,
        from start: String,
        to end: String
    ) -> Substring? {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            return nil
        }
        return source[startRange.lowerBound..<endRange.lowerBound]
    }
}
