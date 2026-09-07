import Combine
import Foundation
import Testing
@testable import KnitNote

@Suite(.serialized)
@MainActor
struct AppSessionOwnerTests {
    @Test func transitionImmediatelyHidesAndRevokesOldStore() async throws {
        try await withOwnerFixture { fixture in
            let owner = AppSessionOwner()
            #expect(owner.visibleSession == nil)
            try owner.publishPreparedSession(fixture.first, for: owner.generation)
            let previous = owner.generation
            let next = owner.beginTransition()
            #expect(next != previous)
            #expect(owner.visibleSession == nil)
            #expect(fixture.first.isStopped)
            #expect(fixture.first.store.isSessionWriteRevoked)
            #expect(throws: StoreSessionAccessError.revoked) { try fixture.first.store.add(name: "late") }
            try await owner.waitForRetiredSessions()
            try owner.publishPreparedSession(fixture.second, for: next)
            #expect(owner.visibleSession === fixture.second)
        }
    }

    @Test func staleAndReplacementFailuresLeaveCandidateUsable() async throws {
        try await withOwnerFixture { fixture in
            let owner = AppSessionOwner()
            let old = owner.generation
            try owner.publishPreparedSession(fixture.first, for: old)
            #expect(throws: AppSessionOwner.Failure.sessionAlreadyVisible) {
                try owner.publishPreparedSession(fixture.second, for: old)
            }
            _ = owner.beginTransition()
            _ = owner.beginTransition()
            try await owner.waitForRetiredSessions()
            #expect(throws: AppSessionOwner.Failure.staleGeneration) {
                try owner.publishPreparedSession(fixture.second, for: old)
            }
            #expect(!fixture.second.isStopped)
            try fixture.second.store.add(name: "caller still owns B")
            try owner.publishPreparedSession(fixture.second, for: owner.generation)
        }
    }

    @Test func stoppedOrRevokedCandidatesAreRejectedAndOpenDrainFails() async throws {
        try await withOwnerFixture { fixture in
            let owner = AppSessionOwner()
            await #expect(throws: AppSessionProducerDrainError.producerStillActive) {
                try await fixture.first.waitForStoppedOperations()
            }
            fixture.first.stopForSessionTransition()
            fixture.first.stopForSessionTransition()
            #expect(throws: AppSessionOwner.Failure.stoppedSession) {
                try owner.publishPreparedSession(fixture.first, for: owner.generation)
            }
            fixture.second.store.revokeSessionWrites()
            #expect(throws: AppSessionOwner.Failure.stoppedSession) {
                try owner.publishPreparedSession(fixture.second, for: owner.generation)
            }
            var factoryCalled = false
            #expect(throws: AppSessionOwner.Failure.stoppedSession) {
                _ = try AppSessionResources(store: fixture.second.store) { _ in
                    factoryCalled = true
                    return []
                }
            }
            #expect(!factoryCalled)
        }
    }

    @Test func sameSessionPublicationDoesNotNotifyAgain() async throws {
        try await withOwnerFixture { fixture in
            let owner = AppSessionOwner()
            var notifications = 0
            let subscription = owner.$visibleSession.sink { _ in notifications += 1 }
            defer { subscription.cancel() }
            try owner.publishPreparedSession(fixture.first, for: owner.generation)
            try owner.publishPreparedSession(fixture.first, for: owner.generation)
            #expect(notifications == 2)
        }
    }

    @Test func publicationSubscriberTransitionCannotLeaveStaleVisibleCandidate() async throws {
        try await withOwnerFixture { fixture in
            let owner = AppSessionOwner()
            let requested = owner.generation
            let subscription = owner.$visibleSession.sink { session in
                if session === fixture.first { _ = owner.beginTransition() }
            }
            defer { subscription.cancel() }
            #expect(throws: AppSessionOwner.Failure.staleGeneration) {
                try owner.publishPreparedSession(fixture.first, for: requested)
            }
            #expect(owner.visibleSession == nil)
            #expect(owner.generation != requested)
            #expect(!fixture.first.isStopped)
            try fixture.first.store.add(name: "candidate remains caller owned")
            try await owner.waitForRetiredSessions()
            try owner.publishPreparedSession(fixture.second, for: owner.generation)
            #expect(owner.visibleSession === fixture.second)
        }
    }

    @Test func hideSubscriberCannotPublishDuringIncompleteStop() async throws {
        try await withOwnerFixture { fixture in
            let owner = AppSessionOwner()
            try owner.publishPreparedSession(fixture.first, for: owner.generation)
            var armed = true
            let subscription = owner.$visibleSession.dropFirst().sink { session in
                guard session == nil, armed else { return }
                armed = false
                _ = owner.beginTransition()
                #expect(throws: AppSessionOwner.Failure.retiredWorkPending) {
                    try owner.publishPreparedSession(fixture.second, for: owner.generation)
                }
            }
            defer { subscription.cancel() }
            _ = owner.beginTransition()
            #expect(owner.visibleSession == nil)
            #expect(fixture.first.isStopped)
            #expect(!fixture.second.isStopped)
            try await owner.waitForRetiredSessions()
            try owner.publishPreparedSession(fixture.second, for: owner.generation)
            #expect(owner.visibleSession === fixture.second)
        }
    }

    @Test func allActualProducersStopSynchronouslyAndHeldInboxBlocksPublication() async throws {
        try await withOwnerWorkFixture { work in
            try await withOwnerFixture { candidates in
                let owner = AppSessionOwner()
                try owner.publishPreparedSession(work.resource, for: owner.generation)
                work.watch.start()
                work.inbox.processPending()
                await work.processing.waitUntilProcessStarts()
                _ = owner.beginTransition()
                #expect(work.resource.isStopped)
                #expect(work.store.isSessionWriteRevoked)
                #expect(work.probe.stops == 1)
                #expect(work.native.owner == nil)
                #expect(work.native.removals == 1)
                #expect(work.adapter.onReceivedEnvelope == nil)
                #expect(throws: PhoneWatchSessionError.stopped) {
                    try work.adapter.updateApplicationContext(.snapshotRequest)
                }
                let activations = work.native.activations
                work.watch.start()
                work.adapter.activate()
                #expect(work.native.activations == activations)
                let processingBefore = await work.processing.snapshot()
                work.inbox.processPending()
                #expect(await work.processing.snapshot() == processingBefore)

                let entered = ProducerTestMainActorEvent()
                let finished = ProducerTestMainActorEvent()
                let drain = work.waiter {
                    entered.signal()
                    try await owner.waitForRetiredSessions()
                    finished.signal()
                }
                await entered.wait()
                #expect(finished.count == 0)
                #expect(throws: AppSessionOwner.Failure.retiredWorkPending) {
                    try owner.publishPreparedSession(candidates.second, for: owner.generation)
                }
                try candidates.second.store.add(name: "rejected but usable")
                await work.processing.release()
                try await drain.value
                #expect(finished.count == 1)
                try owner.publishPreparedSession(candidates.second, for: owner.generation)
            }
        }
    }

    @Test func oneCancelledWaiterDoesNotAuthorizePublicationOrCancelItsPeer() async throws {
        try await withOwnerWorkFixture { work in
            try await withOwnerFixture { candidates in
                let owner = AppSessionOwner()
                try owner.publishPreparedSession(work.resource, for: owner.generation)
                work.inbox.processPending()
                await work.processing.waitUntilProcessStarts()
                _ = owner.beginTransition()
                let entered = ProducerTestMainActorEvent()
                let finished = ProducerTestMainActorEvent()
                let cancelled = work.waiter {
                    entered.signal()
                    try await owner.waitForRetiredSessions()
                }
                let peer = work.waiter {
                    entered.signal()
                    try await owner.waitForRetiredSessions()
                    finished.signal()
                }
                await entered.wait(for: 2)
                cancelled.cancel()
                #expect(finished.count == 0)
                #expect(throws: AppSessionOwner.Failure.retiredWorkPending) {
                    try owner.publishPreparedSession(candidates.second, for: owner.generation)
                }
                await work.processing.release()
                await #expect(throws: CancellationError.self) { try await cancelled.value }
                try await peer.value
                #expect(finished.count == 1)
                try owner.publishPreparedSession(candidates.second, for: owner.generation)
            }
        }
    }

    @Test func failedDrainRetainsResourceUntilSuccessfulRetry() async throws {
        try await withOwnerWorkFixture(mode: .failFirst) { work in
            try await withOwnerFixture { candidates in
                let owner = AppSessionOwner()
                try owner.publishPreparedSession(work.resource, for: owner.generation)
                _ = owner.beginTransition()
                await #expect(throws: ProducerTestFailure.processingFailed) {
                    try await owner.waitForRetiredSessions()
                }
                #expect(throws: AppSessionOwner.Failure.retiredWorkPending) {
                    try owner.publishPreparedSession(candidates.second, for: owner.generation)
                }
                #expect(!candidates.second.isStopped)
                try await owner.waitForRetiredSessions()
                try owner.publishPreparedSession(candidates.second, for: owner.generation)
            }
        }
    }

    @Test func earlierWaiterCannotEraseNewerRetirement() async throws {
        try await withOwnerWorkFixture(mode: .holdFirst) { old in
            try await withOwnerWorkFixture { newer in
                try await withOwnerFixture { candidates in
                    let owner = AppSessionOwner()
                    try owner.publishPreparedSession(old.resource, for: owner.generation)
                    _ = owner.beginTransition()
                    let finished = ProducerTestMainActorEvent()
                    let resumed = ProducerTestMainActorEvent()
                    let firstWaiter = old.waiter {
                        try await owner.waitForRetiredSessions()
                        finished.signal()
                        resumed.signal()
                    }
                    await old.probe.entered.wait()
                    try await owner.waitForRetiredSessions()
                    try owner.publishPreparedSession(newer.resource, for: owner.generation)
                    newer.inbox.processPending()
                    await newer.processing.waitUntilProcessStarts()
                    _ = owner.beginTransition()
                    newer.probe.onWait = { resumed.signal() }
                    old.probe.release.signal()
                    // Wakes on real newer-producer entry OR an incorrect early
                    // owner return, so drain mutants fail without trapping cleanup.
                    await resumed.wait()
                    #expect(newer.probe.entered.count == 1)
                    #expect(finished.count == 0)
                    let peer = newer.waiter {
                        try await owner.waitForRetiredSessions()
                    }
                    #expect(throws: AppSessionOwner.Failure.retiredWorkPending) {
                        try owner.publishPreparedSession(candidates.second, for: owner.generation)
                    }
                    await newer.processing.release()
                    try await firstWaiter.value
                    try await peer.value
                    try owner.publishPreparedSession(candidates.second, for: owner.generation)
                }
            }
        }
    }

    @Test func producerStopReentryCannotInstallNewSession() async throws {
        try await withOwnerWorkFixture { work in
            try await withOwnerFixture { candidates in
                let owner = AppSessionOwner()
                try owner.publishPreparedSession(work.resource, for: owner.generation)
                var nested: UUID?
                work.probe.onStop = {
                    #expect(owner.visibleSession == nil)
                    work.resource.stopForSessionTransition()
                    nested = owner.beginTransition()
                    #expect(throws: AppSessionOwner.Failure.retiredWorkPending) {
                        try owner.publishPreparedSession(candidates.second, for: owner.generation)
                    }
                }
                let outer = owner.beginTransition()
                #expect(owner.generation == nested)
                #expect(owner.generation != outer)
                #expect(work.probe.stops == 1)
                #expect(owner.visibleSession == nil)
                try await owner.waitForRetiredSessions()
                try owner.publishPreparedSession(candidates.second, for: owner.generation)
            }
        }
    }

    @Test func subscriberRevocationIsRecheckedBeforeCandidateOwnershipTransfers() async throws {
        try await withOwnerFixture { fixture in
            let owner = AppSessionOwner()
            let subscription = owner.$visibleSession.sink { session in
                if session === fixture.first { fixture.first.store.revokeSessionWrites() }
            }
            defer { subscription.cancel() }
            #expect(throws: AppSessionOwner.Failure.stoppedSession) {
                try owner.publishPreparedSession(fixture.first, for: owner.generation)
            }
            #expect(owner.visibleSession == nil)
            #expect(!fixture.first.isStopped)
            try owner.publishPreparedSession(fixture.second, for: owner.generation)
            #expect(owner.visibleSession === fixture.second)
        }
    }

    @Test func objectWillChangeTransitionAlsoReconcilesThePublishedProjection() async throws {
        try await withOwnerFixture { fixture in
            let owner = AppSessionOwner()
            var armed = true
            let subscription = owner.objectWillChange.sink {
                guard armed else { return }
                armed = false
                _ = owner.beginTransition()
            }
            defer { subscription.cancel() }
            #expect(throws: AppSessionOwner.Failure.staleGeneration) {
                try owner.publishPreparedSession(fixture.first, for: owner.generation)
            }
            #expect(owner.visibleSession == nil)
            #expect(!fixture.first.isStopped)
            try owner.publishPreparedSession(fixture.second, for: owner.generation)
            #expect(owner.visibleSession === fixture.second)
        }
    }

    @Test func cancelledFixtureCallerStillIndependentlyJoinsBeforeDeletingRoots() async throws {
        let started = ProducerTestMainActorEvent()
        let release = ProducerTestMainActorEvent()
        var root: URL?
        let caller = Task { @MainActor in
            try await withOwnerWorkFixture { work in
                root = work.root
                work.inbox.processPending()
                await work.processing.waitUntilProcessStarts()
                started.signal()
                await release.wait()
                try Task.checkCancellation()
            }
        }
        await started.wait()
        caller.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(root.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
    }
}

@MainActor
private struct OwnerFixture {
    let root: URL
    let first: AppSessionResources
    let second: AppSessionResources

    init() throws {
        root = URL(filePath: "/tmp/AppSessionOwnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let a = root.appending(path: "A", directoryHint: .isDirectory)
        let b = root.appending(path: "B", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let firstStore = JSONProjectStore(url: a.appending(path: "projects.json"))
        let secondStore = JSONProjectStore(url: b.appending(path: "projects.json"))
        try firstStore.add(name: "A")
        try secondStore.add(name: "B")
        first = try AppSessionResources(store: firstStore) { store in
            #expect(store === firstStore)
            return []
        }
        second = try AppSessionResources(store: secondStore) { _ in [] }
    }

    func cleanup() async throws {
        // Independent of owner/resources drain, including deliberately broken RED runs.
        first.store.revokeSessionWrites()
        second.store.revokeSessionWrites()
        try await first.store.waitForTrackedBackgroundWritesAfterRevocation()
        try await second.store.waitForTrackedBackgroundWritesAfterRevocation()
        try FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func withOwnerFixture(_ operation: @MainActor (OwnerFixture) async throws -> Void) async throws {
    let fixture = try OwnerFixture()
    let result: Result<Void, any Error>
    do { result = .success(try await operation(fixture)) }
    catch { result = .failure(error) }
    let cleanup = Task { @MainActor in try await fixture.cleanup() }
    try await cleanup.value
    try result.get()
}
