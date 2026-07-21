import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct WatchOptimisticStateTests {
    @Test func enqueueRecordsCommandBeforeChangingDisplayedValue() throws {
        let fixture = try Fixture(value: 4)
        var state = WatchOptimisticState(cache: fixture.cache)
        let command = fixture.command(.increment)

        #expect(state.enqueue(command) == nil)

        #expect(state.pendingCommands == [command])
        #expect(state.cache.snapshot == fixture.snapshot)
        #expect(state.displayedValue(projectID: fixture.projectID, counterID: fixture.counterID) == 5)
    }

    @Test func threeOfflineOperationsReplayInOriginalOrder() throws {
        let fixture = try Fixture(value: 1)
        var state = WatchOptimisticState(cache: fixture.cache)
        let commands = [
            fixture.command(.increment, offset: 1),
            fixture.command(.reset, offset: 2),
            fixture.command(.increment, offset: 3)
        ]

        for command in commands {
            #expect(state.enqueue(command) == nil)
        }

        #expect(state.pendingCommands == commands)
        #expect(state.displayedValue(projectID: fixture.projectID, counterID: fixture.counterID) == 1)
    }

    @Test func pendingOperationsReapplyAfterCacheReload() throws {
        let fixture = try Fixture(value: 2)
        let commands = [
            fixture.command(.increment, offset: 1),
            fixture.command(.increment, offset: 2),
            fixture.command(.decrement, offset: 3)
        ]
        let cache = WatchSyncCache(
            snapshot: fixture.snapshot,
            pendingCommands: commands,
            selectedProjectID: fixture.projectID,
            selectedCounterID: fixture.counterID
        )

        let restarted = WatchOptimisticState(cache: cache)

        #expect(restarted.pendingCommands == commands)
        #expect(restarted.displayedValue(
            projectID: fixture.projectID,
            counterID: fixture.counterID
        ) == 3)
    }

    @Test func immediateAcknowledgementRemovesOnlyMatchingCommand() throws {
        let fixture = try Fixture(value: 4)
        var state = WatchOptimisticState(cache: fixture.cache)
        let first = fixture.command(.increment, offset: 1)
        let second = fixture.command(.increment, offset: 2)
        #expect(state.enqueue(first) == nil)
        #expect(state.enqueue(second) == nil)

        let acknowledged = state.acknowledge(.init(
            commandID: first.id,
            rejection: nil,
            snapshot: try fixture.snapshot(value: 5)
        ))

        #expect(acknowledged)
        #expect(state.pendingCommands == [second])
        #expect(state.displayedValue(projectID: fixture.projectID, counterID: fixture.counterID) == 6)
    }

    @Test func rejectionRemovesCommandAndUsesPhoneSnapshot() throws {
        let fixture = try Fixture(value: 4)
        var state = WatchOptimisticState(cache: fixture.cache)
        let command = fixture.command(.increment)
        #expect(state.enqueue(command) == nil)
        #expect(state.displayedValue(projectID: fixture.projectID, counterID: fixture.counterID) == 5)

        let acknowledged = state.acknowledge(.init(
            commandID: command.id,
            rejection: .projectCompleted,
            snapshot: fixture.snapshot
        ))

        #expect(acknowledged)
        #expect(state.pendingCommands.isEmpty)
        #expect(state.displayedValue(projectID: fixture.projectID, counterID: fixture.counterID) == 4)
    }

    @Test func unmatchedAcknowledgementCannotRemoveOrReconcilePendingState() throws {
        let fixture = try Fixture(value: 4)
        var state = WatchOptimisticState(cache: fixture.cache)
        let command = fixture.command(.increment)
        #expect(state.enqueue(command) == nil)

        let acknowledged = state.acknowledge(.init(
            commandID: UUID(),
            rejection: nil,
            snapshot: try fixture.snapshot(value: 99)
        ))

        #expect(!acknowledged)
        #expect(state.pendingCommands == [command])
        #expect(state.displayedValue(projectID: fixture.projectID, counterID: fixture.counterID) == 5)
    }

    @Test func acknowledgementForLaterCommandCannotAdvancePastQueueHead() throws {
        let fixture = try Fixture(value: 4)
        var state = WatchOptimisticState(cache: fixture.cache)
        let first = fixture.command(.increment, offset: 1)
        let second = fixture.command(.increment, offset: 2)
        #expect(state.enqueue(first) == nil)
        #expect(state.enqueue(second) == nil)

        let acknowledged = state.acknowledge(.init(
            commandID: second.id,
            rejection: nil,
            snapshot: try fixture.snapshot(value: 6)
        ))

        #expect(!acknowledged)
        #expect(state.pendingCommands == [first, second])
        #expect(state.displayedValue(projectID: fixture.projectID, counterID: fixture.counterID) == 6)
    }

    @Test func duplicateHeadAcknowledgementCannotRegressNextPendingCommand() throws {
        let fixture = try Fixture(value: 4)
        var state = WatchOptimisticState(cache: fixture.cache)
        let first = fixture.command(.increment, offset: 1)
        let second = fixture.command(.increment, offset: 2)
        #expect(state.enqueue(first) == nil)
        #expect(state.enqueue(second) == nil)
        let firstAcknowledged = state.acknowledge(.init(
            commandID: first.id,
            rejection: nil,
            snapshot: try fixture.snapshot(value: 5)
        ))
        #expect(firstAcknowledged)

        let duplicate = state.acknowledge(.init(
            commandID: first.id,
            rejection: nil,
            snapshot: try fixture.snapshot(value: 99)
        ))

        #expect(!duplicate)
        #expect(state.nextPendingCommand == second)
        #expect(state.pendingCommands == [second])
        #expect(state.displayedValue(projectID: fixture.projectID, counterID: fixture.counterID) == 6)
    }

    @Test func delayedHeadAcknowledgementKeepsNewerAuthorityAndReplaysOnlyRemainingSuffix() throws {
        let fixture = try Fixture(value: 4)
        var state = WatchOptimisticState(cache: fixture.cache)
        let first = fixture.command(.increment, offset: 1)
        let second = fixture.command(.increment, offset: 2)
        #expect(state.enqueue(first) == nil)
        #expect(state.enqueue(second) == nil)
        let newerApplicationContext = try fixture.snapshot(
            value: 5,
            generatedAt: Date(timeIntervalSince1970: 40)
        )
        state.replaceSnapshot(newerApplicationContext)

        let acknowledged = state.acknowledge(.init(
            commandID: first.id,
            rejection: nil,
            snapshot: try fixture.snapshot(
                value: 5,
                generatedAt: Date(timeIntervalSince1970: 30)
            )
        ))

        #expect(acknowledged)
        #expect(state.pendingCommands == [second])
        #expect(state.cache.snapshot == newerApplicationContext)
        #expect(state.displayedValue(projectID: fixture.projectID, counterID: fixture.counterID) == 6)
    }

    @Test func equalTimestampHeadAcknowledgementDeterministicallyReplacesAuthority() throws {
        let fixture = try Fixture(value: 4)
        var state = WatchOptimisticState(cache: fixture.cache)
        let command = fixture.command(.increment)
        #expect(state.enqueue(command) == nil)
        state.replaceSnapshot(try fixture.snapshot(
            value: 99,
            generatedAt: Date(timeIntervalSince1970: 30)
        ))
        let acknowledgementSnapshot = try fixture.snapshot(
            value: 5,
            generatedAt: Date(timeIntervalSince1970: 30)
        )

        let acknowledged = state.acknowledge(.init(
            commandID: command.id,
            rejection: nil,
            snapshot: acknowledgementSnapshot
        ))

        #expect(acknowledged)
        #expect(state.pendingCommands.isEmpty)
        #expect(state.cache.snapshot == acknowledgementSnapshot)
        #expect(state.displayedValue(projectID: fixture.projectID, counterID: fixture.counterID) == 5)
    }

    @Test func retryKeepsTheOriginalCommandIdentity() throws {
        let fixture = try Fixture(value: 0)
        var state = WatchOptimisticState(cache: fixture.cache)
        let commandID = UUID()
        let command = fixture.command(.increment, id: commandID)
        #expect(state.enqueue(command) == nil)
        #expect(state.enqueue(command) == nil)

        let retry = try #require(state.pendingCommands.first)

        #expect(state.pendingCommands == [command])
        #expect(state.displayedValue(projectID: fixture.projectID, counterID: fixture.counterID) == 1)
        #expect(retry == command)
        #expect(retry.id == commandID)
    }

    @Test func replacementSnapshotWinsThenPendingCommandsReplayOnTop() throws {
        let fixture = try Fixture(value: 4)
        var state = WatchOptimisticState(cache: fixture.cache)
        let command = fixture.command(.increment)
        let replacement = try fixture.snapshot(value: 10)
        #expect(state.enqueue(command) == nil)

        state.replaceSnapshot(replacement)

        #expect(state.cache.snapshot == replacement)
        #expect(state.displayedValue(projectID: fixture.projectID, counterID: fixture.counterID) == 11)
    }

    @Test func replacementSnapshotRepairsSelectionsThatNoLongerExist() throws {
        let fixture = try Fixture(value: 4)
        let other = try Fixture(value: 8)
        var state = WatchOptimisticState(cache: fixture.cache)

        state.replaceSnapshot(other.snapshot)

        #expect(state.selectedProjectID == other.projectID)
        #expect(state.selectedCounterID == other.counterID)
    }

    @Test func completedAndMissingTargetsAreRejectedWithoutQueueing() throws {
        let completed = try Fixture(value: 4, isCompleted: true)
        var completedState = WatchOptimisticState(cache: completed.cache)
        let completedCommand = completed.command(.increment)

        #expect(completedState.enqueue(completedCommand) == .projectCompleted)
        #expect(completedState.pendingCommands.isEmpty)

        let active = try Fixture(value: 4)
        var activeState = WatchOptimisticState(cache: active.cache)
        #expect(activeState.enqueue(.init(
            projectID: UUID(),
            counterID: active.counterID,
            operation: .increment
        )) == .projectMissing)
        #expect(activeState.enqueue(.init(
            projectID: active.projectID,
            counterID: UUID(),
            operation: .increment
        )) == .counterMissing)
        #expect(activeState.pendingCommands.isEmpty)
    }

    @Test func explicitSelectionAcceptsOnlyIDsFromTheCurrentSnapshot() throws {
        let fixture = try Fixture(value: 4)
        var state = WatchOptimisticState(cache: fixture.cache)

        let selectedCounter = state.selectCounter(fixture.counterIDs[1])
        #expect(selectedCounter)
        #expect(state.selectedCounterID == fixture.counterIDs[1])
        let rejectedCounter = state.selectCounter(UUID())
        #expect(!rejectedCounter)
        #expect(state.selectedCounterID == fixture.counterIDs[1])
        let rejectedProject = state.selectProject(UUID())
        #expect(!rejectedProject)
        #expect(state.selectedProjectID == fixture.projectID)

        let clearedProject = state.selectProject(nil)
        #expect(clearedProject)
        #expect(state.selectedProjectID == fixture.projectID)
        #expect(state.selectedCounterID == fixture.counterIDs[1])
    }

    @Test func pendingStateIsQueryablePerCounter() throws {
        let fixture = try Fixture(value: 4)
        var state = WatchOptimisticState(cache: fixture.cache)
        let first = fixture.command(.increment)
        let second = WatchCounterCommand(
            projectID: fixture.projectID,
            counterID: fixture.counterIDs[1],
            operation: .reset
        )
        #expect(state.enqueue(first) == nil)
        #expect(state.enqueue(second) == nil)

        #expect(state.nextPendingCommand == first)
        #expect(state.pendingCounterIDs == Set([fixture.counterID, fixture.counterIDs[1]]))
        #expect(state.hasPending(projectID: fixture.projectID, counterID: fixture.counterID))
        #expect(!state.hasPending(projectID: UUID(), counterID: fixture.counterID))
    }

    @Test func headDeliveryTransfersOnceAndAdvancesOnlyAfterMatchingAck() throws {
        let fixture = try Fixture(value: 0)
        let first = fixture.command(.increment, offset: 1)
        let second = fixture.command(.increment, offset: 2)
        var delivery = WatchHeadDeliveryState()

        let firstTransfer = delivery.prepareBackgroundTransfer(for: first.id)
        let duplicateTransfer = delivery.prepareBackgroundTransfer(for: first.id)
        let overtakingTransfer = delivery.prepareBackgroundTransfer(for: second.id)
        #expect(firstTransfer)
        #expect(!duplicateTransfer)
        #expect(!overtakingTransfer)
        #expect(delivery.headCommandID == first.id)

        let firstAck = delivery.acknowledge(first.id)
        let secondTransfer = delivery.prepareBackgroundTransfer(for: second.id)
        let duplicateAck = delivery.acknowledge(first.id)
        #expect(firstAck)
        #expect(secondTransfer)
        #expect(!duplicateAck)
        #expect(delivery.headCommandID == second.id)
    }

    @Test func failedBackgroundTransferMakesOnlyTheMatchingHeadRetryable() throws {
        let fixture = try Fixture(value: 0)
        let first = fixture.command(.increment, offset: 1)
        let second = fixture.command(.increment, offset: 2)
        var delivery = WatchHeadDeliveryState()
        let firstPreparation = delivery.prepareBackgroundTransfer(for: first.id)
        #expect(firstPreparation)

        let mismatchedFailure = delivery.failBackgroundTransfer(for: second.id)
        let stillPrepared = delivery.prepareBackgroundTransfer(for: first.id)
        let matchingFailure = delivery.failBackgroundTransfer(for: first.id)
        let retryPreparation = delivery.prepareBackgroundTransfer(for: first.id)
        #expect(!mismatchedFailure)
        #expect(!stillPrepared)
        #expect(matchingFailure)
        #expect(retryPreparation)

        let firstAcknowledgement = delivery.acknowledge(first.id)
        let secondPreparation = delivery.prepareBackgroundTransfer(for: second.id)
        let staleFailure = delivery.failBackgroundTransfer(for: first.id)
        let duplicateSecondPreparation = delivery.prepareBackgroundTransfer(for: second.id)
        #expect(firstAcknowledgement)
        #expect(secondPreparation)
        #expect(!staleFailure)
        #expect(!duplicateSecondPreparation)
    }

    @Test func coordinatorSourcePreservesDurabilityAndReplayContracts() throws {
        let coordinator = try source("KnitNoteWatch/Sync/WatchSyncCoordinator.swift")

        #expect(coordinator.contains("@MainActor\nfinal class WatchSyncCoordinator: ObservableObject"))
        #expect(coordinator.contains("@Published private(set) var snapshot"))
        #expect(coordinator.contains("@Published private(set) var pendingCount"))
        #expect(coordinator.contains("@Published private(set) var selectedProjectID"))
        #expect(coordinator.contains("@Published private(set) var selectedCounterID"))
        #expect(coordinator.contains("@Published private(set) var localizedErrorReason"))
        #expect(coordinator.contains("WatchSyncCache.loadRecoveringCorruption"))
        #expect(coordinator.contains("func increment(projectID: UUID, counterID: UUID)"))
        #expect(coordinator.contains("func decrement(projectID: UUID, counterID: UUID)"))
        #expect(coordinator.contains("func reset(projectID: UUID, counterID: UUID)"))

        let save = try #require(coordinator.range(of: "try cacheFile.save(candidate.cache)"))
        let publish = try #require(coordinator.range(of: "publish(candidate)", range: save.upperBound..<coordinator.endIndex))
        #expect(save.lowerBound < publish.lowerBound)

        #expect(coordinator.contains("case let .acknowledgement(acknowledgement):"))
        #expect(coordinator.contains("candidate.acknowledge(acknowledgement)"))
        #expect(coordinator.contains("case .queueHandshake:"))
        #expect(coordinator.contains("pendingCommands.map(\\.id)"))
        #expect(!coordinator.contains("for command in state.pendingCommands"))
        #expect(coordinator.contains("state.nextPendingCommand"))
        #expect(coordinator.contains("private func deliverHeadIfNeeded()"))

        let transferCompletion = try #require(coordinator.range(of: "onTransferCompleted ="))
        let receiveConfiguration = try #require(coordinator.range(
            of: "onReceivedEnvelope =",
            range: transferCompletion.upperBound..<coordinator.endIndex
        ))
        let completionBody = coordinator[transferCompletion.lowerBound..<receiveConfiguration.lowerBound]
        #expect(!completionBody.contains("acknowledge"))
        #expect(!completionBody.contains("remove"))
    }

    @Test func watchAppOwnsStartsAndInjectsOneCoordinator() throws {
        let app = try source("KnitNoteWatch/KnitNoteWatchApp.swift")

        #expect(app.contains("@StateObject private var watchSyncCoordinator"))
        #expect(app.contains("WatchSyncCoordinator()"))
        #expect(app.contains("watchSyncCoordinator.start()"))
        #expect(app.contains("WatchCounterView(coordinator: watchSyncCoordinator)"))
        #expect(app.components(separatedBy: "WatchSyncCoordinator()").count - 1 == 1)
    }

    @Test func transportCompletionsHopToMainActorAndDoNotOvertakeQueueHead() throws {
        let coordinator = try source("KnitNoteWatch/Sync/WatchSyncCoordinator.swift")

        #expect(coordinator.components(separatedBy: "Task { @MainActor").count - 1 >= 4)
        #expect(coordinator.contains("reachableHandshakeCompleted"))

        let sendNext = try #require(coordinator.range(of: "private func deliverHeadIfNeeded()"))
        let requestSnapshot = try #require(coordinator.range(
            of: "private func requestSnapshotInBackground()",
            range: sendNext.upperBound..<coordinator.endIndex
        ))
        let sendNextBody = coordinator[sendNext.lowerBound..<requestSnapshot.lowerBound]
        let interactiveSend = try #require(sendNextBody.range(of: "transport.sendMessage("))
        let retainedTransfer = try #require(sendNextBody.range(of: "transport.transferUserInfo(.command(command))"))
        #expect(retainedTransfer.lowerBound < interactiveSend.lowerBound)
    }

    @Test func coordinatorRetriesLifecycleAndPublishesPerCounterPendingState() throws {
        let coordinator = try source("KnitNoteWatch/Sync/WatchSyncCoordinator.swift")

        #expect(coordinator.contains("@Published private(set) var pendingCounterIDs"))
        #expect(coordinator.contains("func hasPending(projectID: UUID, counterID: UUID)"))
        #expect(coordinator.contains("private func configureOnce()"))
        #expect(coordinator.contains("private func activate()"))
        #expect(coordinator.contains("scheduleActivationRetry()"))
        #expect(coordinator.contains("activationRetryTask"))
        #expect(coordinator.contains("private func invalidateDeliveryAttempts()"))
        #expect(coordinator.components(separatedBy: "invalidateDeliveryAttempts()").count - 1 >= 3)
        #expect(coordinator.contains("case .snapshot:"))
        #expect(coordinator.contains("beginHandshakeAndReplay()"))
    }

    @Test func coordinatorRetriesOnlyFailedMatchingCommandTransfersAfterDelay() throws {
        let coordinator = try source("KnitNoteWatch/Sync/WatchSyncCoordinator.swift")

        let transferCompletion = try #require(coordinator.range(of: "onTransferCompleted ="))
        let receiveConfiguration = try #require(coordinator.range(
            of: "onReceivedEnvelope =",
            range: transferCompletion.upperBound..<coordinator.endIndex
        ))
        let completionBody = coordinator[transferCompletion.lowerBound..<receiveConfiguration.lowerBound]
        #expect(completionBody.contains("case let .command(command)? = envelope"))
        #expect(completionBody.contains("error != nil"))
        #expect(completionBody.contains("deliveryState.failBackgroundTransfer(for: command.id)"))
        #expect(completionBody.contains("scheduleHandshakeRetry()"))
        #expect(coordinator.contains("Task.sleep(for: .seconds(2))"))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }
}

private struct Fixture {
    let projectID = UUID()
    let counterIDs = (0..<6).map { _ in UUID() }
    let snapshot: WatchSyncSnapshot

    var counterID: UUID { counterIDs[0] }

    var cache: WatchSyncCache {
        WatchSyncCache(
            snapshot: snapshot,
            pendingCommands: [],
            selectedProjectID: projectID,
            selectedCounterID: counterIDs[0]
        )
    }

    init(value: Int, isCompleted: Bool = false) throws {
        let counters = counterIDs.enumerated().map { index, id in
            WatchCounterSnapshot(id: id, name: "Counter \(index + 1)", value: index == 0 ? value : 0)
        }
        let project = try WatchProjectSnapshot(
            id: projectID,
            name: "Sweater",
            isCompleted: isCompleted,
            updatedAt: Date(timeIntervalSince1970: 10),
            counters: counters,
            selectedCounterID: counterIDs[0]
        )
        snapshot = WatchSyncSnapshot(
            generatedAt: Date(timeIntervalSince1970: 11),
            projects: [project]
        )
    }

    func command(
        _ operation: WatchCounterOperation,
        id: UUID = UUID(),
        offset: TimeInterval = 0
    ) -> WatchCounterCommand {
        WatchCounterCommand(
            id: id,
            projectID: projectID,
            counterID: counterID,
            operation: operation,
            createdAt: Date(timeIntervalSince1970: 20 + offset)
        )
    }

    func snapshot(
        value: Int,
        generatedAt: Date = Date(timeIntervalSince1970: 30)
    ) throws -> WatchSyncSnapshot {
        let counters = counterIDs.enumerated().map { index, id in
            WatchCounterSnapshot(id: id, name: "Counter \(index + 1)", value: index == 0 ? value : 0)
        }
        return WatchSyncSnapshot(
            generatedAt: generatedAt,
            projects: [try WatchProjectSnapshot(
                id: projectID,
                name: "Sweater",
                isCompleted: false,
                updatedAt: Date(timeIntervalSince1970: 29),
                counters: counters,
                selectedCounterID: counterID
            )]
        )
    }
}
