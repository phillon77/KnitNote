import Foundation
import Testing
@testable import KnitNote

private struct ProducerTestTransportError: Error, Sendable {}

@Suite(.serialized)
@MainActor
struct PhoneWatchSessionProducerTests {
    @Test func normalSnapshotAndCommandBehaviorRemainIntact() async throws {
        try await withProducerTestWatchFixture { fixture, coordinator in
        let project = try #require(fixture.store.projects.first)
        let counter = try #require(project.counters.first)
        let command = try WatchCounterCommand(
            validating: WatchCounterCommand.currentSchemaVersion,
            id: UUID(),
            projectID: project.id,
            counterID: counter.id,
            operation: .increment,
            createdAt: fixture.now
        )

        coordinator.start()
        #expect(fixture.transport.activationCount == 1)
        #expect(!fixture.transport.applicationContexts.isEmpty)
        #expect(!fixture.transport.sentEnvelopes.isEmpty)
        await coordinator.receive(.command(command))
        #expect(fixture.store.project(id: project.id)?.counters.first?.value == 1)
        await coordinator.receive(.command(command))
        #expect(fixture.store.project(id: project.id)?.counters.first?.value == 1)

        coordinator.stopForSessionTransition()
        try await coordinator.waitForStoppedOperations()
        }
    }

    @Test func queuedIngressCannotMutateOrSendAfterSynchronousStop() async throws {
        try await withProducerTestWatchFixture { fixture, coordinator in
        let project = try #require(fixture.store.projects.first)
        let counter = try #require(project.counters.first)
        let command = try WatchCounterCommand(
            validating: WatchCounterCommand.currentSchemaVersion,
            projectID: project.id,
            counterID: counter.id,
            operation: .increment,
            createdAt: fixture.now
        )
        coordinator.start()
        let ingress = fixture.transport.onReceivedEnvelope
        #expect(ingress != nil)
        guard let ingress else {
            coordinator.stopForSessionTransition()
            try await coordinator.waitForStoppedOperations()
            return
        }
        let before = try ProducerTestDiskSnapshot.capture(root: fixture.root)
        let sentBefore = fixture.transport.sentEnvelopes
        ingress(.command(command), nil)
        coordinator.stopForSessionTransition()
        try await coordinator.waitForStoppedOperations()

        #expect(try ProducerTestDiskSnapshot.capture(root: fixture.root) == before)
        #expect(fixture.transport.sentEnvelopes == sentBefore)
        #expect(fixture.store.project(id: project.id)?.counters.first?.value == 0)
        }
    }

    @Test func retainedTransportCallbacksAndPublicEntriesAreClosedAfterStop() async throws {
        try await withProducerTestWatchFixture { fixture, coordinator in
        let project = try #require(fixture.store.projects.first)
        let counter = try #require(project.counters.first)
        let command = try WatchCounterCommand(
            validating: WatchCounterCommand.currentSchemaVersion,
            projectID: project.id,
            counterID: counter.id,
            operation: .increment,
            createdAt: fixture.now
        )
        coordinator.start()
        let callbacks = (
            fixture.transport.onReceivedEnvelope,
            fixture.transport.onActivationCompleted,
            fixture.transport.onReachabilityChanged,
            fixture.transport.onTransferCompleted
        )
        #expect(callbacks.0 != nil && callbacks.1 != nil && callbacks.2 != nil && callbacks.3 != nil)
        guard let ingress = callbacks.0,
              let activation = callbacks.1,
              let reachability = callbacks.2,
              let transfer = callbacks.3 else {
            coordinator.stopForSessionTransition()
            try await coordinator.waitForStoppedOperations()
            return
        }
        let transferred = fixture.transport.sentEnvelopes.last

        coordinator.stopForSessionTransition()
        let before = try ProducerTestDiskSnapshot.capture(root: fixture.root)
        let contextsBefore = fixture.transport.applicationContexts
        let sentBefore = fixture.transport.sentEnvelopes
        let activationCountBefore = fixture.transport.activationCount

        #expect(fixture.transport.onReceivedEnvelope == nil)
        #expect(fixture.transport.onActivationCompleted == nil)
        #expect(fixture.transport.onReachabilityChanged == nil)
        #expect(fixture.transport.onTransferCompleted == nil)
        ingress(.command(command), nil)
        activation(false, ProducerTestTransportError())
        reachability(true)
        transfer(transferred, ProducerTestTransportError())
        coordinator.start()
        coordinator.publishLatestSnapshot()
        coordinator.publishLatestSnapshotIfChanged()
        await coordinator.receive(.command(command))
        coordinator.stopForSessionTransition()
        try await coordinator.waitForStoppedOperations()

        #expect(try ProducerTestDiskSnapshot.capture(root: fixture.root) == before)
        #expect(fixture.transport.applicationContexts == contextsBefore)
        #expect(fixture.transport.sentEnvelopes == sentBefore)
        #expect(fixture.transport.activationCount == activationCountBefore)
        }
    }

    @Test func queuedProjectPublicationCannotSendAfterStop() async throws {
        try await withProducerTestWatchFixture { fixture, coordinator in
        let project = try #require(fixture.store.projects.first)
        let counter = try #require(project.counters.first)
        coordinator.start()
        let sentBefore = fixture.transport.sentEnvelopes
        let contextsBefore = fixture.transport.applicationContexts

        try fixture.store.incrementCounter(projectID: project.id, counterID: counter.id)
        coordinator.stopForSessionTransition()
        try await coordinator.waitForStoppedOperations()

        #expect(fixture.transport.sentEnvelopes == sentBefore)
        #expect(fixture.transport.applicationContexts == contextsBefore)
        }
    }

    @Test func queuedEntitlementPublicationCannotSendOrRecoverAfterStop() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let entitlement = EntitlementCoordinator(
            purchaseService: ProducerTestTrialPurchaseService(),
            trialStore: ProducerTestFixedTrialStore(
                record: TrialRecord(startedAt: fixedNow.addingTimeInterval(-60))
            ),
            now: { fixedNow }
        )
        try await withProducerTestWatchFixture(entitlement: entitlement) { fixture, coordinator in
        coordinator.start()
        let before = try ProducerTestDiskSnapshot.capture(root: fixture.root)
        let sentBefore = fixture.transport.sentEnvelopes
        let contextsBefore = fixture.transport.applicationContexts

        await entitlement.prepare()
        coordinator.stopForSessionTransition()
        try await coordinator.waitForStoppedOperations()

        #expect(try ProducerTestDiskSnapshot.capture(root: fixture.root) == before)
        #expect(fixture.transport.sentEnvelopes == sentBefore)
        #expect(fixture.transport.applicationContexts == contextsBefore)
        }
    }

    @Test func activationReentryClosesBeforeFollowingPublication() async throws {
        try await withProducerTestWatchFixture { fixture, coordinator in
        fixture.transport.onActivate = { [weak coordinator] in
            coordinator?.stopForSessionTransition()
        }

        coordinator.start()
        try await coordinator.waitForStoppedOperations()

        #expect(fixture.transport.activationCount == 1)
        #expect(fixture.transport.applicationContexts.isEmpty)
        #expect(fixture.transport.sentEnvelopes.isEmpty)
        }
    }

    @Test func publicationReentryCannotQueueReliableTransfer() async throws {
        try await withProducerTestWatchFixture { fixture, coordinator in
        fixture.transport.onUpdateApplicationContext = { [weak coordinator] in
            coordinator?.stopForSessionTransition()
        }

        coordinator.start()
        try await coordinator.waitForStoppedOperations()

        #expect(fixture.transport.applicationContexts.count == 1)
        #expect(fixture.transport.sentEnvelopes.isEmpty)
        }
    }

    @Test func activationRetryRemainsOwnedUntilItsActualTermination() async throws {
        let sleep = ProducerTestWatchSleep()
        try await withProducerTestWatchFixture(controlledSleep: sleep) { fixture, coordinator in
        coordinator.start()
        fixture.transport.onActivationCompleted?(false, ProducerTestTransportError())
        await sleep.waitUntilCallCount(1)

        coordinator.stopForSessionTransition()
        let entered = ProducerTestMainActorEvent()
        let finished = ProducerTestMainActorEvent()
        let drain = Task { @MainActor in
            entered.signal()
            try await coordinator.waitForStoppedOperations()
            finished.signal()
        }
        await entered.wait()
        #expect(finished.count == 0)
        sleep.release(call: 1)
        try await drain.value
        #expect(finished.count == 1)
        }
    }

    @Test func reliableRetryRemainsOwnedUntilItsActualTermination() async throws {
        let sleep = ProducerTestWatchSleep()
        try await withProducerTestWatchFixture(controlledSleep: sleep) { fixture, coordinator in
        coordinator.start()
        let snapshot = fixture.transport.sentEnvelopes.last
        #expect(snapshot != nil)
        guard let snapshot else {
            coordinator.stopForSessionTransition()
            try await coordinator.waitForStoppedOperations()
            return
        }
        fixture.transport.onTransferCompleted?(snapshot, ProducerTestTransportError())
        await sleep.waitUntilCallCount(1)

        coordinator.stopForSessionTransition()
        let entered = ProducerTestMainActorEvent()
        let finished = ProducerTestMainActorEvent()
        let drain = Task { @MainActor in
            entered.signal()
            try await coordinator.waitForStoppedOperations()
            finished.signal()
        }
        await entered.wait()
        #expect(finished.count == 0)
        sleep.release(call: 1)
        try await drain.value
        #expect(finished.count == 1)
        }
    }

    @Test func replacedExpiryTimerRemainsOwnedAfterCancellationAndStop() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let entitlement = EntitlementCoordinator(
            purchaseService: ProducerTestTrialPurchaseService(),
            trialStore: ProducerTestFixedTrialStore(
                record: TrialRecord(startedAt: fixedNow.addingTimeInterval(-60))
            ),
            now: { fixedNow }
        )
        let sleep = ProducerTestWatchSleep()
        let probe = ProducerTestGateProbe()
        let lifecycleCheckpoint = ProducerTestMainActorEvent()
        var registeredState: AppSessionCallbackGate.State?
        var currentTimerFinishedState: AppSessionCallbackGate.State?
        var finalState: AppSessionCallbackGate.State?
        let lifecycleObserver = Task { @MainActor in
            for await state in probe.states {
                if registeredState == nil,
                   state.isClosed,
                   state.waiterCount == 1 {
                    registeredState = state
                    lifecycleCheckpoint.signal()
                } else if registeredState != nil,
                          currentTimerFinishedState == nil,
                          state.isClosed,
                          state.activeTokenCount == 1,
                          state.waiterCount == 1 {
                    currentTimerFinishedState = state
                    lifecycleCheckpoint.signal()
                } else if state.isClosed,
                          state.activeTokenCount == 0,
                          state.waiterCount == 0 {
                    finalState = state
                }
            }
            if registeredState == nil {
                lifecycleCheckpoint.signal()
            }
            if currentTimerFinishedState == nil {
                lifecycleCheckpoint.signal()
            }
        }
        try await withProducerTestWatchFixture(
            entitlement: entitlement,
            controlledSleep: sleep,
            observeCallbackGateState: probe.record
        ) { fixture, coordinator in
        coordinator.start()
        await entitlement.prepare()
        await sleep.waitUntilCallCount(1)
        await entitlement.prepare()
        await sleep.waitUntilCallCount(2)

        coordinator.stopForSessionTransition()
        let drain = Task { @MainActor in
            defer { probe.finish() }
            try await coordinator.waitForStoppedOperations()
        }

        await lifecycleCheckpoint.wait()
        #expect(registeredState?.activeTokenCount == 2)
        guard registeredState?.activeTokenCount == 2 else {
            sleep.releaseAll()
            _ = try? await drain.value
            await lifecycleObserver.value
            return
        }

        sleep.release(call: 2)
        await lifecycleCheckpoint.wait(for: 2)
        #expect(currentTimerFinishedState != nil)
        guard currentTimerFinishedState != nil else {
            sleep.releaseAll()
            _ = try? await drain.value
            await lifecycleObserver.value
            return
        }

        sleep.release(call: 1)
        try await drain.value
        await lifecycleObserver.value
        #expect(finalState?.activeTokenCount == 0)
        #expect(finalState?.waiterCount == 0)
        }
    }

    @Test func openDrainErrorsAndRepeatedStopIsSafe() async throws {
        try await withProducerTestWatchFixture { _, coordinator in
        await #expect(throws: AppSessionProducerDrainError.producerStillActive) {
            try await coordinator.waitForStoppedOperations()
        }
        coordinator.stopForSessionTransition()
        coordinator.stopForSessionTransition()
        try await coordinator.waitForStoppedOperations()
        }
    }

    @Test func fixtureTeardownJoinsAcceptedWorkBeforeCleanupOnThrowAndCancellation() async throws {
        let throwingSleep = ProducerTestWatchSleep()
        var throwingRoot: URL?
        await #expect(throws: ProducerTestFailure.processingFailed) {
            try await withProducerTestWatchFixture(controlledSleep: throwingSleep) { fixture, coordinator in
                throwingRoot = fixture.root
                coordinator.start()
                fixture.transport.onActivationCompleted?(false, ProducerTestTransportError())
                await throwingSleep.waitUntilCallCount(1)
                throw ProducerTestFailure.processingFailed
            }
        }
        #expect(throwingRoot.map { !FileManager.default.fileExists(atPath: $0.path) } == true)

        let cancellingSleep = ProducerTestWatchSleep()
        let operationStarted = ProducerTestMainActorEvent()
        let operationRelease = ProducerTestMainActorEvent()
        var cancellingRoot: URL?
        let cancelled = Task { @MainActor in
            try await withProducerTestWatchFixture(controlledSleep: cancellingSleep) { fixture, coordinator in
                cancellingRoot = fixture.root
                coordinator.start()
                fixture.transport.onActivationCompleted?(false, ProducerTestTransportError())
                await cancellingSleep.waitUntilCallCount(1)
                operationStarted.signal()
                await operationRelease.wait()
                try Task.checkCancellation()
            }
        }
        await operationStarted.wait()
        cancelled.cancel()
        operationRelease.signal()
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        #expect(cancellingRoot.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test func gateRejectsOpenWaitAndNewEntriesAfterClose() async throws {
        let gate = AppSessionCallbackGate()
        await #expect(throws: AppSessionProducerDrainError.producerStillActive) {
            try await gate.waitUntilClosedAndIdle()
        }
        gate.close()
        #expect(gate.begin() == nil)
        try await gate.waitUntilClosedAndIdle()
    }

    @Test func gateRejectsForeignAndDuplicateFinishesAndBroadcastsToWaiters() async throws {
        let gate = AppSessionCallbackGate()
        let foreignGate = AppSessionCallbackGate()
        let firstToken = try #require(gate.begin())
        let secondToken = try #require(gate.begin())
        let foreign = try #require(foreignGate.begin())
        gate.close()
        let entered = ProducerTestMainActorEvent()
        let finished = ProducerTestMainActorEvent()
        let first = Task { @MainActor in
            entered.signal()
            try await gate.waitUntilClosedAndIdle()
            finished.signal()
        }
        let second = Task { @MainActor in
            entered.signal()
            try await gate.waitUntilClosedAndIdle()
            finished.signal()
        }
        await entered.wait(for: 2)

        #expect(gate.state().activeTokenCount == 2)
        #expect(gate.state().waiterCount == 2)

        gate.finish(foreign)
        gate.finish(UUID())
        gate.finish(firstToken)
        gate.finish(firstToken)
        #expect(gate.state().activeTokenCount == 1)
        #expect(gate.state().waiterCount == 2)

        gate.finish(secondToken)
        try await first.value
        try await second.value
        #expect(finished.count == 2)
        #expect(gate.state().activeTokenCount == 0)
        #expect(gate.state().waiterCount == 0)
        gate.finish(secondToken)
        foreignGate.finish(foreign)
    }

    @Test func cancellingOneGateWaiterDoesNotCancelPeerOrNativeWork() async throws {
        let gate = AppSessionCallbackGate()
        let token = try #require(gate.begin())
        gate.close()
        let entered = ProducerTestMainActorEvent()
        let peerFinished = ProducerTestMainActorEvent()
        let cancelled = Task { @MainActor in
            entered.signal()
            try await gate.waitUntilClosedAndIdle()
        }
        let peer = Task { @MainActor in
            entered.signal()
            try await gate.waitUntilClosedAndIdle()
            peerFinished.signal()
        }
        await entered.wait(for: 2)
        cancelled.cancel()
        #expect(peerFinished.count == 0)
        gate.finish(token)
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await peer.value
        #expect(peerFinished.count == 1)
    }
}
