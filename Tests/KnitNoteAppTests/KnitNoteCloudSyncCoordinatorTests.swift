import CloudKit
import CryptoKit
import Foundation
import Testing
@testable import KnitNote

@Suite @MainActor struct KnitNoteCloudSyncCoordinatorTests {
    @Test func transitionWaiterCancellationDoesNotJoinTheStartupTask() async throws {
        let fixture = try StateStoreFixture()
        let driver = TestSyncEngineDriver()
        let transport = CKSyncEngineTransport(zoneID: testZoneID(), stateStore: fixture.store,
            initialAccountIdentifier: "startup-account", requiresInitialFetchReceipt: true,
            containerIdentifier: "startup.container", engineFactory: { _, _ in driver })
        let coordinator = KnitNoteCloudSyncCoordinator(transport: transport,
            journal: FileSyncMutationJournal(url: fixture.root.appendingPathComponent("journal")),
            mergeEngine: SyncMergeEngine(), recordProvider: FakeCoordinatorRecordProvider(records: [:]),
            fetchedBatchCommitter: FakeFetchedBatchCommitter(), screenshotMode: false)
        await driver.suspendNextFetch()
        let startup = Task { try await coordinator.startForAccountTransition { _ in Issue.record("Stopped startup published readiness") } }
        var join: Task<Void, Never>?
        let result: Result<Void, any Error>
        do {
            for _ in 0..<3_000 {
                if await driver.isFetchSuspended() { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            try #require(await driver.isFetchSuspended())
            coordinator.stopForAccountTransition()
            await #expect(throws: CancellationError.self) { try await startup.value }
            let cancellation = await transport.invalidateForAccountTransition(); await cancellation?.value
            #expect(await driver.completedCancellationCount() == 1)
            var joined = false
            join = Task { await coordinator.waitForStoppedOperations(); joined = true }
            await drainCoordinatorTasks()
            #expect(!joined)
            #expect(await driver.isFetchSuspended())
            await driver.resumeFetch()
            await join?.value
            #expect(joined)
            result = .success(())
        } catch { result = .failure(error) }
        coordinator.stopForAccountTransition()
        await driver.resumeFetch()
        let cancellation = await transport.invalidateForAccountTransition(); await cancellation?.value
        _ = await startup.result
        await join?.value
        await coordinator.waitForStoppedOperations()
        fixture.remove()
        try result.get()
    }

    @Test func failureCallbackRequestsStopWithoutJoiningItsOwnStartupOrEventLoop() async {
        let transport = FakeCoordinatorTransport(startFailure: CKError(.notAuthenticated))
        let coordinator = makeCoordinator(transport: transport)
        var stopped = false
        coordinator.failureHandler = { [weak coordinator] _ in coordinator?.stopForAccountTransition(); stopped = true }
        await coordinator.start()
        await coordinator.waitForStoppedOperations()
        #expect(stopped)
        #expect(coordinator.status.lastCompleteSuccess == nil)
    }

    @Test func retryableStartFailureIsTypedAndRetryReentersStartup() async {
        let transport = FakeCoordinatorTransport(startFailure: CKError(.networkFailure))
        let coordinator = makeCoordinator(transport: transport)
        await coordinator.start()
        #expect(coordinator.status.issue == .transport(.retryable(code: CKError.Code.networkFailure.rawValue, retryAfterSeconds: nil)))
        await coordinator.syncNow()
        #expect(await eventually { coordinator.status.lastCompleteSuccess == fixedNow })
        #expect(transport.operations.filter { $0 == "start" }.count == 2)
        coordinator.stopForAccountTransition()
    }
    @Test func postJournalCleanupFailureRetriesOnNextSyncWithoutResendingAttachment() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let mutation = try integrationAttachment(root: fixture.root)
        let journal = FileSyncMutationJournal(url: fixture.root.appendingPathComponent("journal"))
        try journal.enqueue(mutation)
        let fault = CleanupFaultOnce()
        let staging = try CloudAssetStagingService(rootURL: fixture.root.appendingPathComponent("assets"), accountIdentifier: "account",
            beforeBoundary: { boundary in try fault.check(boundary) })
        let transport = CKSyncEngineTransport(zoneID: testZoneID(), stateStore: fixture.store,
            initialAccountIdentifier: "account", assetStaging: staging, containerIdentifier: "test.container", engineFactory: { _, _ in TestSyncEngineDriver() })
        let coordinator = KnitNoteCloudSyncCoordinator(transport: transport, journal: journal,
            mergeEngine: SyncMergeEngine(), recordProvider: FakeCoordinatorRecordProvider(records: [:]),
            fetchedBatchCommitter: FakeFetchedBatchCommitter(), screenshotMode: false)
        await coordinator.start()
        await drainCoordinatorTasks()
        await transport.receiveZoneReady(testZoneID())
        let cloudID = try CloudRecordCodec().encode(mutation.savedRecordVersion!.record, zoneID: testZoneID()).recordID
        let outgoing = try await coordinatorOutgoing(transport, cloudID)
        let stagedURL = try #require((outgoing["asset"] as? CKAsset)?.fileURL)
        await transport.receiveSentChanges(savedRecords: [outgoing], deletedRecordIDs: [])
        #expect(await eventually { coordinator.status.phase == .needsAttention })
        #expect(try journal.pending().isEmpty)
        #expect(FileManager.default.fileExists(atPath: stagedURL.path))
        let version = try #require(mutation.savedRecordVersion?.record.payload.attachment)
        let concurrentMutationID = UUID()
        try staging.stageUpload(version: version, source: mutation.attachmentSource!, mutationID: concurrentMutationID)
        let concurrentURL = try #require(staging.assetForUpload(versionID: version.versionID, mutationID: concurrentMutationID).fileURL)
        await coordinator.syncNow()
        #expect(await eventually { !FileManager.default.fileExists(atPath: stagedURL.path) })
        #expect(FileManager.default.fileExists(atPath: concurrentURL.path))
        #expect(await transport.recordZoneChangeBatch(pendingChanges: [.saveRecord(cloudID)], scope: .all) == nil)
    }

    @Test func composedTransportRebasesTwoConflictsThenAcknowledgesHeadAndSuccessor() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let head = try saveMutation(revision: 1, mutationSuffix: 94)
        let tail = try saveMutation(revision: 2, mutationSuffix: 95)
        let journal = FakeCoordinatorJournal([head, tail])
        let transport = CKSyncEngineTransport(zoneID: testZoneID(), stateStore: fixture.store,
            systemFieldsStore: FileCloudRecordSystemFieldsStore(url: fixture.root.appendingPathComponent("system.json"), zoneID: testZoneID()),
            initialAccountIdentifier: "account", containerIdentifier: "test.container", engineFactory: { _, _ in TestSyncEngineDriver() })
        let committer = FakeFetchedBatchCommitter(journal: journal)
        let coordinator = KnitNoteCloudSyncCoordinator(transport: transport, journal: journal,
            mergeEngine: SyncMergeEngine(), recordProvider: FakeCoordinatorRecordProvider(records: [:]),
            fetchedBatchCommitter: committer, screenshotMode: false)
        await coordinator.start()
        await drainCoordinatorTasks()
        await transport.receiveZoneReady(testZoneID())
        let cloudID = try CloudRecordCodec().encode(head.savedRecordVersion!.record, zoneID: testZoneID()).recordID
        var attempts: Set<String> = []
        for revision: UInt64 in [3, 4] {
            let outgoing = try await coordinatorOutgoing(transport, cloudID)
            attempts.insert(try #require(outgoing["syncAttemptID"] as? String))
            let server = try CloudRecordCodec().encode(projectRecord(id: head.recordID, revision: revision, name: "server-\(revision)"), zoneID: testZoneID())
            await transport.receiveFailedSave(outgoing, error: CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server]))
            #expect(await eventually { committer.conflictMutationIDs.count == Int(revision - 2) })
            await drainCoordinatorTasks()
        }
        #expect(attempts.count == 2)
        #expect(journal.pendingMutations.last?.savedRecordVersion?.record.payload.fields["name"]?.value == .string("server-4"))
        for mutation in [head, tail] {
            let outgoing = try await coordinatorOutgoing(transport, cloudID)
            #expect(outgoing["syncMutationID"] as? String == mutation.mutationID.uuidString.lowercased())
            await transport.receiveSentChanges(savedRecords: [outgoing], deletedRecordIDs: [])
            await drainCoordinatorTasks()
        }
        #expect(journal.pendingMutations.isEmpty)
    }

    @Test func accountInvalidationRejectsSuspendedTransportConflictDurableCommit() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let mutation = try saveMutation(revision: 1, mutationSuffix: 93)
        let journal = FakeCoordinatorJournal([mutation])
        let transport = CKSyncEngineTransport(zoneID: testZoneID(), stateStore: fixture.store,
            systemFieldsStore: FileCloudRecordSystemFieldsStore(url: fixture.root.appendingPathComponent("system.json"), zoneID: testZoneID()),
            initialAccountIdentifier: "old-account", containerIdentifier: "test.container", engineFactory: { _, _ in TestSyncEngineDriver() })
        let committer = FakeFetchedBatchCommitter(journal: journal, suspendConflictCommit: true)
        let coordinator = KnitNoteCloudSyncCoordinator(transport: transport, journal: journal,
            mergeEngine: SyncMergeEngine(), recordProvider: FakeCoordinatorRecordProvider(records: [:]),
            fetchedBatchCommitter: committer, screenshotMode: false)
        await coordinator.start()
        await drainCoordinatorTasks()
        await transport.receiveZoneReady(testZoneID())
        let server = try CloudRecordCodec().encode(projectRecord(id: mutation.recordID, revision: 3, name: "server"), zoneID: testZoneID())
        let outgoing = try #require(await transport.recordZoneChangeBatch(pendingChanges: [.saveRecord(server.recordID)], scope: .all)?.recordsToSave.first)
        await transport.receiveFailedSave(outgoing, error: CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server]))
        #expect(await committer.waitUntilConflictCommitSuspended())
        await transport.receiveAccountChange(previous: "old-account", current: "new-account")
        await committer.resumeConflictCommit()
        await drainCoordinatorTasks()
        #expect(journal.pendingMutations == [mutation])
        #expect(committer.conflictMutationIDs.isEmpty)
    }

    @Test func twoFreshConflictsForStableMutationBothRebaseBeforeAcknowledgement() async throws {
        let first = try saveMutation(revision: 1, mutationSuffix: 91)
        let later = try saveMutation(revision: 2, mutationSuffix: 92)
        let journal = FakeCoordinatorJournal([first, later])
        let transport = FakeCoordinatorTransport()
        let committer = FakeFetchedBatchCommitter(journal: journal)
        let coordinator = makeCoordinator(transport: transport, journal: journal, committer: committer)
        await coordinator.start()
        for revision: UInt64 in [3, 4] {
            transport.emit(.mutationFailed(attempted: try #require(journal.pendingVersioned().first { $0.mutation.identity == first.identity }),
                failure: .serverRecordChanged(recordID: first.recordID, serverRecord: projectRecord(
                    id: first.recordID, revision: revision, name: "server-\(revision)"
                ))
            ))
            #expect(await eventually { transport.resolvedMutationIDs.count == Int(revision - 2) })
        }
        #expect(committer.conflictMutationIDs.count == 2)
        #expect(journal.pendingMutations.last?.savedRecordVersion?.record.payload.fields["name"]?.value == .string("server-4"))
        transport.emit(.sent(token: try (journal.pendingVersioned().first { $0.mutation.identity == first.identity }?.token ?? SyncMutationVersionToken(mutation: first)), attemptID: UUID(), accountEpoch: transport.accountEpoch))
        #expect(await eventually { journal.pendingMutations.map(\.identity) == [later.identity] })
    }

    @Test func screenshotModeNeverStartsCloudSync() async {
        let transport = FakeCoordinatorTransport()
        let coordinator = makeCoordinator(
            transport: transport,
            screenshotMode: true
        )

        await coordinator.start()

        #expect(transport.operations.isEmpty)
        #expect(coordinator.status == CloudSyncStatusSnapshot(
            phase: .disabled,
            pendingCount: 0,
            lastCompleteSuccess: nil,
            issue: nil
        ))
    }

    @Test func restartReschedulesTheExactDurableJournalEntriesAfterTransportStart() async throws {
        let first = try saveMutation(revision: 1, mutationSuffix: 1)
        let second = SyncMutation.delete(
            recordID(suffix: 2),
            mutationID: uuid(suffix: 2)
        )
        let journal = FakeCoordinatorJournal([first, second])

        let firstTransport = FakeCoordinatorTransport()
        await makeCoordinator(
            transport: firstTransport,
            journal: journal,
            provider: FakeCoordinatorRecordProvider(records: [first.recordID: try #require(
                first.savedRecordVersion?.record
            )])
        ).start()

        let restartedTransport = FakeCoordinatorTransport()
        await makeCoordinator(
            transport: restartedTransport,
            journal: journal,
            provider: FakeCoordinatorRecordProvider(records: [first.recordID: try #require(
                first.savedRecordVersion?.record
            )])
        ).start()

        #expect(firstTransport.scheduledMutations == [first, second])
        #expect(restartedTransport.scheduledMutations == [first, second])
        #expect(restartedTransport.operations.prefix(2) == ["start", "schedule"])
    }

    @Test func startupFetchesBeforeItEnablesBootstrapSend() async {
        let transport = FakeCoordinatorTransport()
        let coordinator = makeCoordinator(transport: transport)

        await coordinator.start()
        await coordinator.start()

        #expect(await eventually { transport.operations == ["start", "fetch", "finishReplay"] })
        #expect(await eventually { coordinator.status.lastCompleteSuccess == fixedNow })
        #expect(transport.operations == ["start", "fetch", "finishReplay"])
        #expect(coordinator.status.phase == .waiting)
        #expect(coordinator.status.lastCompleteSuccess == fixedNow)
    }

    @Test func startupDoesNotEnableSendOrReportSuccessUntilFetchedEventsAreConsumed() async throws {
        let batchID = uuid(suffix: 6)
        let id = recordID(suffix: 6)
        let remote = projectRecord(id: id, revision: 1, name: "remote")
        let operations = CoordinatorOperationRecorder()
        let transport = FakeCoordinatorTransport(
            recorder: operations,
            automaticallyCompleteRequests: false
        )
        let committer = FakeFetchedBatchCommitter(recorder: operations)
        let coordinator = makeCoordinator(
            transport: transport,
            provider: FakeCoordinatorRecordProvider(records: [id: remote]),
            committer: committer
        )

        await coordinator.start()

        #expect(transport.operations == ["start", "fetch"])
        #expect(coordinator.status.lastCompleteSuccess == nil)
        let requestID = try #require(transport.fetchRequestIDs.first)

        transport.emit(.fetched(
            batchID: batchID, accountEpoch: transport.accountEpoch,
            records: [remote], deleted: []
        ))
        #expect(await eventually { transport.acknowledgedBatchIDs == [batchID] })
        transport.emit(.fetchRequestCompleted(requestID))
        #expect(await eventually { transport.operations.contains("finishReplay") })
        #expect(coordinator.status.lastCompleteSuccess == nil)

        transport.emit(.sendRequestCompleted(requestID))
        #expect(await eventually { coordinator.status.lastCompleteSuccess == fixedNow })
        #expect(operations.values.firstIndex(of: "ackFetched:\(batchID.uuidString)")! <
            operations.values.firstIndex(of: "finishReplay")!)
    }

    @Test func sentCallbacksAcknowledgeOnlyTheExactPerRecordJournalHead() async throws {
        let first = try saveMutation(revision: 1, mutationSuffix: 11)
        let second = try saveMutation(revision: 2, mutationSuffix: 12)
        let journal = FakeCoordinatorJournal([first, second])
        let transport = FakeCoordinatorTransport()
        let coordinator = makeCoordinator(
            transport: transport,
            journal: journal,
            provider: FakeCoordinatorRecordProvider(records: [first.recordID: try #require(
                second.savedRecordVersion?.record
            )])
        )
        await coordinator.start()

        transport.emit(.sent(token: try (journal.pendingVersioned().first { $0.mutation.identity == second.identity }?.token ?? SyncMutationVersionToken(mutation: second)), attemptID: UUID(), accountEpoch: transport.accountEpoch))
        await drainCoordinatorTasks()
        #expect(journal.pendingMutations == [first, second])

        transport.emit(.sent(token: try (journal.pendingVersioned().first { $0.mutation.identity == first.identity }?.token ?? SyncMutationVersionToken(mutation: first)), attemptID: UUID(), accountEpoch: transport.accountEpoch))
        #expect(await eventually { journal.pendingMutations == [second] })

        transport.emit(.sent(token: try (journal.pendingVersioned().first { $0.mutation.identity == first.identity }?.token ?? SyncMutationVersionToken(mutation: first)), attemptID: UUID(), accountEpoch: transport.accountEpoch))
        await drainCoordinatorTasks()

        #expect(journal.pendingMutations == [second])
        #expect(journal.acknowledgedIdentities == [first.identity])
        #expect(coordinator.status.pendingCount == 1)
    }

    @Test func fetchedBatchIsAcknowledgedOnceAndOnlyAfterItsMergeIsDurablyCommitted() async {
        let batchID = uuid(suffix: 21)
        let id = recordID(suffix: 21)
        let local = projectRecord(id: id, revision: 1, name: "local")
        let remote = projectRecord(id: id, revision: 2, name: "remote")
        let operations = CoordinatorOperationRecorder()
        let transport = FakeCoordinatorTransport(recorder: operations)
        let committer = FakeFetchedBatchCommitter(recorder: operations)
        let coordinator = makeCoordinator(
            transport: transport,
            provider: FakeCoordinatorRecordProvider(records: [id: local]),
            committer: committer
        )
        await coordinator.start()

        transport.emit(.fetched(
            batchID: batchID, accountEpoch: transport.accountEpoch,
            records: [remote], deleted: []
        ))
        #expect(await eventually { transport.acknowledgedBatchIDs == [batchID] })
        transport.emit(.fetched(
            batchID: batchID, accountEpoch: transport.accountEpoch,
            records: [remote], deleted: []
        ))
        await drainCoordinatorTasks()

        #expect(committer.fetchedBatchIDs == [batchID])
        #expect(committer.fetchedResults.first?.records == [remote])
        #expect(operations.values.suffix(2) == [
            "commitFetched:\(batchID.uuidString)",
            "ackFetched:\(batchID.uuidString)",
        ])
        #expect(transport.acknowledgedBatchIDs == [batchID])
    }

    @Test func failedFetchedBatchCommitLeavesBatchUnacknowledgedAndNeedsAttention() async {
        let batchID = uuid(suffix: 31)
        let id = recordID(suffix: 31)
        let record = projectRecord(id: id, revision: 1, name: "remote")
        let transport = FakeCoordinatorTransport()
        let committer = FakeFetchedBatchCommitter(failFetchedCommit: true)
        let coordinator = makeCoordinator(
            transport: transport,
            provider: FakeCoordinatorRecordProvider(records: [id: record]),
            committer: committer
        )
        await coordinator.start()

        transport.emit(.fetched(
            batchID: batchID, accountEpoch: transport.accountEpoch,
            records: [record], deleted: []
        ))
        #expect(await eventually { coordinator.status.phase == .needsAttention })

        #expect(transport.acknowledgedBatchIDs.isEmpty)
        #expect(coordinator.status.issue == .durableCommit)
    }

    @Test func failedFetchedCommitInvalidatesMatchingFetchAndSendCompletions() async throws {
        let batchID = uuid(suffix: 32)
        let record = projectRecord(id: recordID(suffix: 32), revision: 1, name: "remote")
        let pending = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: record),
            mutationID: uuid(suffix: 33)
        )
        let journal = FakeCoordinatorJournal([pending])
        let transport = FakeCoordinatorTransport(automaticallyCompleteRequests: false)
        let coordinator = makeCoordinator(
            transport: transport,
            journal: journal,
            provider: FakeCoordinatorRecordProvider(records: [record.id: record]),
            committer: FakeFetchedBatchCommitter(failFetchedCommit: true)
        )
        await coordinator.start()
        let requestID = try #require(transport.fetchRequestIDs.first)

        transport.emit(.fetched(
            batchID: batchID, accountEpoch: transport.accountEpoch,
            records: [record], deleted: []
        ))
        #expect(await eventually { coordinator.status.issue == .durableCommit })
        transport.emit(.sent(token: try (journal.pendingVersioned().first { $0.mutation.identity == pending.identity }?.token ?? SyncMutationVersionToken(mutation: pending)), attemptID: UUID(), accountEpoch: transport.accountEpoch))
        transport.emit(.fetchRequestCompleted(requestID))
        transport.emit(.sendRequestCompleted(requestID))
        await drainCoordinatorTasks()

        await coordinator.syncNow()
        let manualRequestID = try #require(transport.fetchRequestIDs.last)
        #expect(manualRequestID != requestID)
        transport.emit(.fetchRequestCompleted(manualRequestID))
        transport.emit(.sendRequestCompleted(manualRequestID))
        await drainCoordinatorTasks()

        #expect(transport.acknowledgedBatchIDs.isEmpty)
        #expect(coordinator.status.phase == .needsAttention)
        #expect(coordinator.status.issue == .durableCommit)
        #expect(coordinator.status.lastCompleteSuccess == nil)
    }

    @Test func successfulUnrelatedBatchDoesNotClearBlockedFetchedBatch() async {
        let failedBatchID = uuid(suffix: 34)
        let successfulBatchID = uuid(suffix: 35)
        let record = projectRecord(id: recordID(suffix: 34), revision: 1, name: "remote")
        let transport = FakeCoordinatorTransport()
        let committer = FakeFetchedBatchCommitter(
            failingFetchedBatchIDs: [failedBatchID]
        )
        let coordinator = makeCoordinator(
            transport: transport,
            provider: FakeCoordinatorRecordProvider(records: [record.id: record]),
            committer: committer
        )
        await coordinator.start()

        transport.emit(.fetched(
            batchID: failedBatchID, accountEpoch: transport.accountEpoch,
            records: [record], deleted: []
        ))
        #expect(await eventually { coordinator.status.issue == .durableCommit })
        transport.emit(.fetched(
            batchID: successfulBatchID, accountEpoch: transport.accountEpoch,
            records: [record], deleted: []
        ))
        #expect(await eventually {
            transport.acknowledgedBatchIDs == [successfulBatchID]
        })

        #expect(coordinator.status.phase == .needsAttention)
        #expect(coordinator.status.issue == .durableCommit)
        #expect(!transport.acknowledgedBatchIDs.contains(failedBatchID))
    }

    @Test func missingProviderRecordDoesNotBlockExactRawBatchForwarding() async throws {
        let batchID = uuid(suffix: 41)
        let mutation = try saveMutation(revision: 1, mutationSuffix: 41)
        let remote = projectRecord(id: mutation.recordID, revision: 2, name: "remote")
        let journal = FakeCoordinatorJournal([mutation])
        let transport = FakeCoordinatorTransport()
        let committer = FakeFetchedBatchCommitter()
        let coordinator = makeCoordinator(
            transport: transport,
            journal: journal,
            provider: FakeCoordinatorRecordProvider(records: [:]),
            committer: committer
        )
        await coordinator.start()

        transport.emit(.fetched(
            batchID: batchID, accountEpoch: transport.accountEpoch,
            records: [remote], deleted: []
        ))
        #expect(await eventually { transport.acknowledgedBatchIDs == [batchID] })

        #expect(committer.fetchedBatchIDs == [batchID])
        #expect(committer.fetchedResults.first?.records == [remote])
        #expect(transport.acknowledgedBatchIDs == [batchID])
    }

    @Test func transientFailureWaitsForTransportRetryWithoutACompetingRetryLoop() async {
        let transport = FakeCoordinatorTransport()
        let coordinator = makeCoordinator(transport: transport)
        await coordinator.start()
        #expect(await eventually { coordinator.status.lastCompleteSuccess == fixedNow })
        let callsBeforeFailure = transport.operations
        let failure = CloudSyncFailure.retryable(code: 7, retryAfterSeconds: 2)

        transport.emit(.failed(failure))
        #expect(await eventually { coordinator.status.issue == .transport(failure) })

        #expect(coordinator.status.phase == .waiting)
        #expect(transport.operations == callsBeforeFailure)
    }

    @Test func retryableFetchFailureDoesNotGetOverwrittenByGenericOperationFailure() async {
        let failure = CloudSyncFailure.retryable(code: 7, retryAfterSeconds: 2)
        let transport = FakeCoordinatorTransport(fetchFailure: failure)
        let coordinator = makeCoordinator(transport: transport)

        await coordinator.start()

        #expect(coordinator.status.phase == .waiting)
        #expect(coordinator.status.issue == .transport(failure))
    }

    @Test func manualSyncReloadsAndSchedulesMutationsCommittedAfterStartup() async throws {
        let journal = FakeCoordinatorJournal()
        let transport = FakeCoordinatorTransport()
        let coordinator = makeCoordinator(transport: transport, journal: journal)
        await coordinator.start()
        #expect(await eventually { coordinator.status.lastCompleteSuccess == fixedNow })
        let mutation = try saveMutation(revision: 1, mutationSuffix: 45)
        try journal.enqueue(mutation)

        await coordinator.syncNow()

        #expect(await eventually {
            transport.operations.suffix(3) == ["fetch", "schedule", "send"]
        })
        #expect(transport.scheduleBatches.last == [mutation])
        #expect(transport.operations.suffix(3) == ["fetch", "schedule", "send"])
    }

    @Test func accountChangeStopsThisAccountScopedCoordinator() async {
        let transport = FakeCoordinatorTransport()
        let coordinator = makeCoordinator(transport: transport)
        await coordinator.start()
        #expect(await eventually { coordinator.status.lastCompleteSuccess == fixedNow })
        let operationsBeforeChange = transport.operations

        transport.emit(.accountChanged(previous: "old", current: "new"))
        #expect(await eventually { coordinator.status.issue == .accountChanged })
        await coordinator.syncNow()

        #expect(coordinator.status.phase == .needsAttention)
        #expect(transport.operations == operationsBeforeChange)
    }

    @Test func accountChangeInvalidatesSuspendedFetchedCommitBeforeDurableBoundary() async {
        let batchID = uuid(suffix: 46)
        let record = projectRecord(id: recordID(suffix: 46), revision: 1, name: "remote")
        let transport = FakeCoordinatorTransport()
        let committer = FakeFetchedBatchCommitter(suspendFetchedCommit: true)
        let coordinator = makeCoordinator(
            transport: transport,
            provider: FakeCoordinatorRecordProvider(records: [record.id: record]),
            committer: committer
        )
        await coordinator.start()

        transport.emit(.fetched(
            batchID: batchID,
            accountEpoch: transport.accountEpoch,
            records: [record],
            deleted: []
        ))
        #expect(await committer.waitUntilFetchedCommitSuspended())

        transport.emit(.accountChanged(previous: "account-a", current: "account-b"))
        await committer.resumeFetchedCommit()
        #expect(await eventually { coordinator.status.issue == .accountChanged })

        #expect(committer.fetchedBatchIDs.isEmpty)
        #expect(transport.acknowledgedBatchIDs.isEmpty)
        #expect(coordinator.status.phase == .needsAttention)
    }

    @Test func serverRecordChangedMergesAndCommitsExactFailedHeadBeforeResolvingIt() async throws {
        let id = recordID(suffix: 10)
        let local = record(
            id: id,
            entityRevision: 2,
            fields: [
                "name": field("local", revision: 2),
                "localOnly": field("kept", revision: 2),
            ]
        )
        let first = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: local),
            mutationID: uuid(suffix: 51)
        )
        let later = try saveMutation(revision: 3, mutationSuffix: 52)
        let server = record(
            id: id,
            entityRevision: 3,
            fields: [
                "name": field("server-old", revision: 1),
                "serverOnly": field("preserved", revision: 3),
            ]
        )
        let journal = FakeCoordinatorJournal([first, later])
        let operations = CoordinatorOperationRecorder()
        let transport = FakeCoordinatorTransport(recorder: operations)
        let committer = FakeFetchedBatchCommitter(recorder: operations, journal: journal)
        let coordinator = makeCoordinator(
            transport: transport,
            journal: journal,
            provider: FakeCoordinatorRecordProvider(records: [first.recordID: local]),
            committer: committer
        )
        await coordinator.start()

        transport.emit(.mutationFailed(attempted: try #require(journal.pendingVersioned().first { $0.mutation.identity == later.identity }),
            failure: .serverRecordChanged(recordID: later.recordID, serverRecord: server)
        ))
        await drainCoordinatorTasks()
        #expect(transport.resolvedMutationIDs.isEmpty)

        let repeatedAttempt = UUID()
        transport.emit(.mutationFailed(attempted: try #require(journal.pendingVersioned().first { $0.mutation.identity == first.identity }),
            failure: .serverRecordChanged(recordID: first.recordID, serverRecord: server),
            accountEpoch: coordinatorTestEpoch(), attemptID: repeatedAttempt
        ))
        #expect(await eventually { transport.resolvedMutationIDs == [first.mutationID] })
        transport.emit(.mutationFailed(attempted: try #require(journal.pendingVersioned().first { $0.mutation.identity == first.identity }),
            failure: .serverRecordChanged(recordID: first.recordID, serverRecord: server),
            accountEpoch: coordinatorTestEpoch(), attemptID: repeatedAttempt
        ))
        await drainCoordinatorTasks()

        #expect(committer.conflictMutationIDs == [first.mutationID])
        #expect(operations.values.suffix(2) == [
            "commitConflict:\(first.mutationID.uuidString)",
            "resolve:\(first.mutationID.uuidString)",
        ])
        #expect(transport.resolvedMutationIDs == [first.mutationID])
        let replacement = try #require(transport.resolvedReplacements.first ?? nil)
        let mergedRecord = try #require(replacement.savedRecordVersion?.record)
        let rebasedLater = try #require(journal.pendingMutations.last)
        let rebasedLaterRecord = try #require(rebasedLater.savedRecordVersion?.record)
        #expect(mergedRecord.payload.fields["localOnly"]?.value == .string("kept"))
        #expect(mergedRecord.payload.fields["serverOnly"]?.value == .string("preserved"))
        #expect(rebasedLaterRecord.payload.fields["serverOnly"]?.value == .string("preserved"))
        #expect(replacement.mutationID == first.mutationID)
        #expect(rebasedLater.mutationID == later.mutationID)
        #expect(journal.pendingMutations == [replacement, rebasedLater])
        #expect(transport.resolvedFollowingReplacements.first == [rebasedLater])

        let restartedTransport = FakeCoordinatorTransport()
        await makeCoordinator(
            transport: restartedTransport,
            journal: journal,
            provider: FakeCoordinatorRecordProvider(records: [first.recordID: mergedRecord]),
            committer: committer
        ).start()
        #expect(restartedTransport.scheduledMutations == [replacement, rebasedLater])
    }

    @Test func conflictCommitCASRebasesMutationAppendedWhileCommitWasSuspended() async throws {
        let first = try saveMutation(revision: 1, mutationSuffix: 53)
        let second = try saveMutation(revision: 2, mutationSuffix: 54)
        let third = try saveMutation(revision: 3, mutationSuffix: 55)
        let server = record(
            id: first.recordID,
            entityRevision: 4,
            fields: [
                "name": field("name-1", revision: 1),
                "serverOnly": field("preserved", revision: 4),
            ]
        )
        let journal = FakeCoordinatorJournal([first, second])
        let transport = FakeCoordinatorTransport()
        let committer = FakeFetchedBatchCommitter(
            journal: journal,
            suspendConflictCommit: true
        )
        let coordinator = makeCoordinator(
            transport: transport,
            journal: journal,
            provider: FakeCoordinatorRecordProvider(records: [:]),
            committer: committer
        )
        await coordinator.start()

        transport.emit(.mutationFailed(attempted: try #require(journal.pendingVersioned().first { $0.mutation.identity == first.identity }),
            failure: .serverRecordChanged(recordID: first.recordID, serverRecord: server)
        ))
        #expect(await committer.waitUntilConflictCommitSuspended())
        try journal.enqueue(third)
        await committer.resumeConflictCommit()

        #expect(await eventually { transport.resolvedMutationIDs == [first.mutationID] })
        #expect(journal.pendingMutations.map(\.identity) == [
            first.identity, second.identity, third.identity,
        ])
        let rebasedThird = try #require(journal.pendingMutations.last?.savedRecordVersion?.record)
        #expect(rebasedThird.payload.fields["serverOnly"]?.value == .string("preserved"))
        #expect(transport.resolvedFollowingReplacements.first?.map(\.identity) == [
            second.identity, third.identity,
        ])
    }

    @Test func conflictRebasePreservesAttachmentHeadMetadataFromEveryPrefix() async throws {
        let owner = recordID(suffix: 56)
        let slot = SyncAttachmentSlot(owner: owner, role: "photo", slotID: "primary")
        let bytes = Data("attachment".utf8)
        let attachment = try SyncAttachmentVersion.issuing(
            slot: slot,
            contentSHA256: Data(SHA256.hash(data: bytes)),
            byteCount: Int64(bytes.count),
            mediaType: "image/jpeg",
            displayFilename: "photo.jpg"
        )
        let attachmentID = SyncEntityID(kind: .attachment, uuid: attachment.versionID)
        let stamp = SyncMutationStamp(
            logicalRevision: 1,
            modifiedAt: Date(timeIntervalSince1970: 1),
            deviceID: "attachment-device"
        )
        let attachmentRecord = SyncRecord(
            schemaVersion: 1,
            id: attachmentID,
            createdAt: Date(timeIntervalSince1970: 1),
            entityRevision: 1,
            payload: .init(fields: [:], attachment: attachment),
            relationships: [.init(role: "owner", target: owner)],
            deletedAt: .init(value: nil, stamp: stamp)
        )
        let source = try SyncAttachmentSource(
            fileURL: URL(fileURLWithPath: "/tmp/task-3-conflict-head.jpg"),
            contentSHA256: attachment.contentSHA256,
            byteCount: attachment.byteCount
        )
        let save = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: attachmentRecord),
            attachmentSource: source,
            mutationID: uuid(suffix: 56)
        )
        let delete = SyncMutation.delete(attachmentID, mutationID: uuid(suffix: 57))
        let journal = FakeCoordinatorJournal([save, delete])
        let transport = FakeCoordinatorTransport()
        let committer = FakeFetchedBatchCommitter(journal: journal)
        let coordinator = makeCoordinator(
            transport: transport,
            journal: journal,
            provider: FakeCoordinatorRecordProvider(records: [attachmentID: attachmentRecord]),
            committer: committer
        )
        await coordinator.start()

        transport.emit(.mutationFailed(
            attempted: try #require(journal.pendingVersioned().first { $0.mutation.identity == save.identity }),
            failure: .serverRecordChanged(recordID: attachmentID, serverRecord: attachmentRecord)
        ))

        #expect(await eventually { transport.resolvedMutationIDs == [save.mutationID] })
        let result = try #require(committer.conflictResults.first)
        #expect(result.resolvedAttachmentVersionIDs[slot] == attachment.versionID)
        #expect(result.mutationsToUpload.map(\.identity) == [save.identity, delete.identity])
    }

    @Test func failedConflictCommitLeavesExactMutationUnresolved() async throws {
        let mutation = try saveMutation(revision: 2, mutationSuffix: 61)
        let journal = FakeCoordinatorJournal([mutation])
        let transport = FakeCoordinatorTransport()
        let committer = FakeFetchedBatchCommitter(
            failConflictCommit: true,
            journal: journal
        )
        let coordinator = makeCoordinator(
            transport: transport,
            journal: journal,
            provider: FakeCoordinatorRecordProvider(records: [:]),
            committer: committer
        )
        await coordinator.start()
        let server = projectRecord(id: mutation.recordID, revision: 3, name: "server")

        transport.emit(.mutationFailed(attempted: try #require(journal.pendingVersioned().first { $0.mutation.identity == mutation.identity }),
            failure: .serverRecordChanged(recordID: mutation.recordID, serverRecord: server)
        ))
        #expect(await eventually { coordinator.status.issue == .durableCommit })

        #expect(transport.resolvedMutationIDs.isEmpty)
        #expect(journal.pendingMutations == [mutation])
    }

    @Test func conflictBlockerSurvivesUnrelatedSuccessAndClearsOnlyAfterExactResolution() async throws {
        let failed = try saveMutation(revision: 2, mutationSuffix: 63)
        let unrelatedID = recordID(suffix: 64)
        let unrelated = SyncMutation.delete(unrelatedID, mutationID: uuid(suffix: 64))
        let fetchedRecord = projectRecord(
            id: recordID(suffix: 65), revision: 1, name: "unrelated-remote"
        )
        let server = projectRecord(id: failed.recordID, revision: 3, name: "server")
        let journal = FakeCoordinatorJournal([failed, unrelated])
        let transport = FakeCoordinatorTransport()
        let committer = FakeFetchedBatchCommitter(
            conflictFailuresRemaining: 1,
            journal: journal
        )
        let coordinator = makeCoordinator(
            transport: transport,
            journal: journal,
            provider: FakeCoordinatorRecordProvider(records: [
                failed.recordID: try #require(failed.savedRecordVersion?.record),
                fetchedRecord.id: fetchedRecord,
            ]),
            committer: committer
        )
        await coordinator.start()
        let conflict = CloudSyncEvent.mutationFailed(attempted: try #require(journal.pendingVersioned().first { $0.mutation.identity == failed.identity }),
            failure: .serverRecordChanged(recordID: failed.recordID, serverRecord: server)
        )

        transport.emit(conflict)
        #expect(await eventually { coordinator.status.issue == .durableCommit })

        transport.emit(.sent(token: try (journal.pendingVersioned().first { $0.mutation.identity == unrelated.identity }?.token ?? SyncMutationVersionToken(mutation: unrelated)), attemptID: UUID(), accountEpoch: transport.accountEpoch))
        transport.emit(.fetched(
            batchID: uuid(suffix: 65),
            accountEpoch: transport.accountEpoch,
            records: [fetchedRecord],
            deleted: []
        ))
        #expect(await eventually { transport.acknowledgedBatchIDs == [uuid(suffix: 65)] })
        #expect(coordinator.status.phase == .needsAttention)
        #expect(coordinator.status.issue == .durableCommit)
        #expect(coordinator.status.lastCompleteSuccess == nil)

        transport.emit(conflict)
        #expect(await eventually {
            transport.resolvedMutationIDs == [failed.mutationID]
                && coordinator.status.issue == nil
                && coordinator.status.phase == .waiting
        })
    }

    @Test func transportResolutionFailureRetriesFromDurableSameIdentity() async throws {
        let mutation = try saveMutation(revision: 2, mutationSuffix: 62)
        let unrelated = projectRecord(
            id: recordID(suffix: 66), revision: 1, name: "unrelated"
        )
        let journal = FakeCoordinatorJournal([mutation])
        let transport = FakeCoordinatorTransport(resolveFailuresRemaining: 1)
        let committer = FakeFetchedBatchCommitter(journal: journal)
        let coordinator = makeCoordinator(
            transport: transport,
            journal: journal,
            provider: FakeCoordinatorRecordProvider(records: [
                mutation.recordID: try #require(mutation.savedRecordVersion?.record),
                unrelated.id: unrelated,
            ]),
            committer: committer
        )
        await coordinator.start()
        let server = projectRecord(id: mutation.recordID, revision: 3, name: "server")
        let event = CloudSyncEvent.mutationFailed(attempted: try #require(journal.pendingVersioned().first { $0.mutation.identity == mutation.identity }),
            failure: .serverRecordChanged(recordID: mutation.recordID, serverRecord: server)
        )

        transport.emit(event)
        #expect(await eventually { coordinator.status.issue == .operation })
        #expect(journal.pendingMutations.first?.identity == mutation.identity)
        transport.emit(.fetched(
            batchID: uuid(suffix: 66),
            accountEpoch: transport.accountEpoch,
            records: [unrelated],
            deleted: []
        ))
        #expect(await eventually { transport.acknowledgedBatchIDs == [uuid(suffix: 66)] })
        #expect(coordinator.status.phase == .needsAttention)
        #expect(coordinator.status.issue == .operation)
        transport.emit(event)
        #expect(await eventually { transport.resolvedMutationIDs == [mutation.mutationID] })

        #expect(committer.conflictMutationIDs == [mutation.mutationID]) // exact retry reuses durable resolution
    }

    private func makeCoordinator(
        transport: FakeCoordinatorTransport,
        journal: FakeCoordinatorJournal = FakeCoordinatorJournal(),
        provider: FakeCoordinatorRecordProvider = FakeCoordinatorRecordProvider(records: [:]),
        committer: FakeFetchedBatchCommitter = FakeFetchedBatchCommitter(),
        screenshotMode: Bool = false
    ) -> KnitNoteCloudSyncCoordinator {
        KnitNoteCloudSyncCoordinator(
            transport: transport,
            journal: journal,
            mergeEngine: SyncMergeEngine(),
            recordProvider: provider,
            fetchedBatchCommitter: committer,
            screenshotMode: screenshotMode,
            now: { fixedNow }
        )
    }
}

private final class CleanupFaultOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func check(_ boundary: CloudAssetUploadFaultBoundary) throws {
        try lock.withLock {
            if boundary == .acknowledgementAfterManifest, !fired {
                fired = true
                throw CloudAssetStagingError.unavailable
            }
        }
    }
}

private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

private func coordinatorTestEpoch() -> CloudSyncAccountEpoch {
    CloudSyncAccountEpoch(accountIdentifier: "test", zoneID: testZoneID(), generation: 1, containerIdentifier: "test.container")
}

private extension CloudSyncEvent {
    static func mutationFailed(attempted: SyncVersionedMutation, failure: CloudSyncFailure,
        accountEpoch: CloudSyncAccountEpoch = coordinatorTestEpoch(), attemptID: UUID = UUID()) -> Self {
        .mutationFailed(recordID: attempted.mutation.recordID, mutationID: attempted.mutation.mutationID,
            failure: failure, accountEpoch: accountEpoch, attemptID: attemptID, attempted: attempted)
    }
}

private func uuid(suffix: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
}

private func recordID(suffix: Int) -> SyncEntityID {
    SyncEntityID(kind: .project, uuid: uuid(suffix: suffix))
}

private func projectRecord(
    id: SyncEntityID,
    revision: UInt64,
    name: String
) -> SyncRecord {
    record(
        id: id,
        entityRevision: revision,
        fields: ["name": field(name, revision: revision)]
    )
}

private func field(_ value: String, revision: UInt64) -> SyncFieldVersion<SyncScalar> {
    .init(value: .string(value), stamp: SyncMutationStamp(
        logicalRevision: revision,
        modifiedAt: Date(timeIntervalSince1970: TimeInterval(revision)),
        deviceID: "device-\(revision)"
    ))
}

private func record(
    id: SyncEntityID,
    entityRevision: UInt64,
    fields: [String: SyncFieldVersion<SyncScalar>]
) -> SyncRecord {
    let deletedStamp = SyncMutationStamp(
        logicalRevision: entityRevision,
        modifiedAt: Date(timeIntervalSince1970: TimeInterval(entityRevision)),
        deviceID: "device-\(entityRevision)"
    )
    return SyncRecord(
        schemaVersion: 1,
        id: id,
        createdAt: Date(timeIntervalSince1970: 1),
        entityRevision: entityRevision,
        payload: .init(fields: fields),
        relationships: [],
        deletedAt: .init(value: nil, stamp: deletedStamp)
    )
}

private func saveMutation(revision: UInt64, mutationSuffix: Int) throws -> SyncMutation {
    let id = recordID(suffix: 10)
    return try .save(
        recordVersion: SyncRecordVersion(record: projectRecord(
            id: id,
            revision: revision,
            name: "name-\(revision)"
        )),
        mutationID: uuid(suffix: mutationSuffix)
    )
}

@MainActor
private func drainCoordinatorTasks() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<2_000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

private final class CoordinatorOperationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class FakeCoordinatorTransport: CloudSyncTransport, @unchecked Sendable {
    let events: AsyncStream<CloudSyncEvent>
    let accountEpoch = CloudSyncAccountEpoch(
        accountIdentifier: "fake-account",
        zoneID: CKRecordZone.ID(
            zoneName: "KnitNoteSync",
            ownerName: CKCurrentUserDefaultName
        ),
        generation: 1, containerIdentifier: "test.container"
    )
    private let continuation: AsyncStream<CloudSyncEvent>.Continuation
    private let lock = NSLock()
    private let recorder: CoordinatorOperationRecorder
    private let automaticallyCompleteRequests: Bool
    private let fetchFailure: CloudSyncFailure?
    private var startFailure: (any Error)?
    private var resolveFailuresRemaining: Int
    private var operationStorage: [String] = []
    private var scheduledStorage: [SyncMutation] = []
    private var scheduleBatchStorage: [[SyncMutation]] = []
    private var acknowledgedBatchStorage: [UUID] = []
    private var resolvedMutationStorage: [UUID] = []
    private var resolvedReplacementStorage: [SyncMutation?] = []
    private var resolvedFollowingReplacementStorage: [[SyncMutation]] = []
    private var fetchRequestIDStorage: [UUID] = []
    private var sentStorage: [UUID: (SyncMutationVersionToken, CloudSyncAccountEpoch)] = [:]

    init(
        recorder: CoordinatorOperationRecorder = CoordinatorOperationRecorder(),
        automaticallyCompleteRequests: Bool = true,
        fetchFailure: CloudSyncFailure? = nil,
        startFailure: (any Error)? = nil,
        resolveFailuresRemaining: Int = 0
    ) {
        self.recorder = recorder
        self.automaticallyCompleteRequests = automaticallyCompleteRequests
        self.fetchFailure = fetchFailure
        self.startFailure = startFailure
        self.resolveFailuresRemaining = resolveFailuresRemaining
        var captured: AsyncStream<CloudSyncEvent>.Continuation!
        events = AsyncStream { captured = $0 }
        continuation = captured
    }

    var operations: [String] { withLock { operationStorage } }
    var scheduledMutations: [SyncMutation] { withLock { scheduledStorage } }
    var scheduleBatches: [[SyncMutation]] { withLock { scheduleBatchStorage } }
    var acknowledgedBatchIDs: [UUID] { withLock { acknowledgedBatchStorage } }
    var resolvedMutationIDs: [UUID] { withLock { resolvedMutationStorage } }
    var resolvedReplacements: [SyncMutation?] { withLock { resolvedReplacementStorage } }
    var resolvedFollowingReplacements: [[SyncMutation]] {
        withLock { resolvedFollowingReplacementStorage }
    }
    var fetchRequestIDs: [UUID] { withLock { fetchRequestIDStorage } }

    func verifyFetchedBatchAcknowledgement(_ batchID: UUID) async throws {
        guard acknowledgedBatchIDs.contains(batchID) else { throw FakeCoordinatorError.commitFailed }
    }
    func finishFetchedBatchAcknowledgement(_ identity: SyncRemoteBatchIdentity) async throws {
        guard acknowledgedBatchIDs.contains(identity.batchID) else { throw FakeCoordinatorError.commitFailed }
    }
    func start() async throws {
        record("start")
        let failure = withLock { let value = startFailure; startFailure = nil; return value }
        if let failure { throw failure }
    }

    func schedule(_ versioned: [SyncVersionedMutation]) async throws {
        let mutations = versioned.map(\.mutation)
        withLock {
            scheduledStorage = mutations
            scheduleBatchStorage.append(mutations)
        }
        record("schedule")
    }

    func finishMutationReplay(completionID: UUID?) async throws {
        record("finishReplay")
        if automaticallyCompleteRequests, let completionID {
            continuation.yield(.sendRequestCompleted(completionID))
        }
    }

    func acknowledgeFetchedBatch(_ batchID: UUID) async throws {
        withLock { acknowledgedBatchStorage.append(batchID) }
        record("ackFetched:\(batchID.uuidString)")
    }

    func resolveFailedMutation(_ resolution: SyncConflictResolution, accountEpoch: CloudSyncAccountEpoch, expectedQueue: [SyncVersionedMutation]) async throws -> CloudConflictHandoffResult {
        let mutationID = resolution.input.failedMutation.mutationID
        let replacement = resolution.replacement
        let followingReplacements = resolution.followingReplacements
        let shouldFail = withLock { () -> Bool in
            guard resolveFailuresRemaining > 0 else { return false }
            resolveFailuresRemaining -= 1
            return true
        }
        if shouldFail { throw FakeCoordinatorError.transportResolutionFailed }
        withLock {
            resolvedMutationStorage.append(mutationID)
            resolvedReplacementStorage.append(replacement)
            resolvedFollowingReplacementStorage.append(followingReplacements)
        }
        record("resolve:\(mutationID.uuidString)")
        return .accepted
    }

    func verifySentMutation(_ token: SyncMutationVersionToken, attemptID: UUID, accountEpoch: CloudSyncAccountEpoch) async throws {
        try accountEpoch.requireCurrent()
        guard withLock({ sentStorage[attemptID]?.0 == token && sentStorage[attemptID]?.1 === accountEpoch }) else { throw CloudSyncTransportError.staleOperation }
    }
    func acknowledgeSentMutation(_ token: SyncMutationVersionToken, attemptID: UUID) async throws {
        try withLock {
            guard sentStorage[attemptID]?.0 == token else { throw CloudSyncTransportError.staleOperation }
            sentStorage.removeValue(forKey: attemptID)
        }
    }

    func fetchNow(completionID: UUID?) async throws {
        record("fetch")
        if let completionID {
            withLock { fetchRequestIDStorage.append(completionID) }
        }
        if let fetchFailure {
            continuation.yield(.failed(fetchFailure))
            throw fetchFailure
        }
        if automaticallyCompleteRequests, let completionID {
            continuation.yield(.fetchRequestCompleted(completionID))
        }
    }

    func sendNow(completionID: UUID?) async throws {
        record("send")
        if automaticallyCompleteRequests, let completionID {
            continuation.yield(.sendRequestCompleted(completionID))
        }
    }

    func emit(_ event: CloudSyncEvent) {
        if case let .sent(token, attemptID, epoch) = event {
            withLock { sentStorage[attemptID] = (token, epoch) }
        }
        if case .accountChanged = event {
            accountEpoch.invalidate()
        }
        continuation.yield(event)
    }

    private func record(_ operation: String) {
        lock.lock()
        operationStorage.append(operation)
        lock.unlock()
        recorder.append(operation)
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private final class FakeCoordinatorJournal: SyncMutationJournalProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SyncMutation]
    private var revisions: [SyncMutationIdentity: UInt64] = [:]
    private var acknowledgedStorage: [SyncMutationIdentity] = []

    init(_ mutations: [SyncMutation] = []) {
        storage = mutations
    }

    var pendingMutations: [SyncMutation] { withLock { storage } }
    var acknowledgedIdentities: [SyncMutationIdentity] { withLock { acknowledgedStorage } }

    func enqueue(_ mutations: [SyncMutation]) throws {
        lock.lock()
        storage.append(contentsOf: mutations)
        lock.unlock()
    }

    func pending() throws -> [SyncMutation] { pendingMutations }
    func pendingVersioned() throws -> [SyncVersionedMutation] { try withLock { try storage.map { try SyncVersionedMutation(mutation: $0, journalRevision: revisions[$0.identity, default: 0]) } } }
    func acknowledgeCurrentVersion(_ token: SyncMutationVersionToken) throws -> SyncVersionedAcknowledgementResult {
        try withLock {
            guard let head = storage.first(where: { $0.recordID == token.identity.recordID }),
                  try SyncMutationVersionToken(mutation: head, journalRevision: revisions[head.identity, default: 0]) == token else { return .staleVersion }
            storage.removeAll { $0.identity == token.identity }; acknowledgedStorage.append(token.identity)
            return .acknowledged
        }
    }

    func acknowledge(_ identities: Set<SyncMutationIdentity>) throws {
        lock.lock()
        acknowledgedStorage.append(contentsOf: storage.compactMap {
            identities.contains($0.identity) ? $0.identity : nil
        })
        storage.removeAll { identities.contains($0.identity) }
        lock.unlock()
    }

    func replaceExactRecordQueue(
        _ identity: SyncMutationIdentity,
        with replacements: [SyncMutation]
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let indices = storage.indices.filter { storage[$0].recordID == identity.recordID }
        guard let firstIndex = indices.first,
              storage[firstIndex].identity == identity,
              indices.map({ storage[$0].identity }) == replacements.map(\.identity) else {
            throw FakeCoordinatorError.inconsistentJournal
        }
        for (index, replacement) in zip(indices, replacements) {
            storage[index] = replacement
            revisions[replacement.identity, default: 0] += 1
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private struct FakeCoordinatorRecordProvider: SyncRecordProvider {
    let records: [SyncEntityID: SyncRecord]

    func record(for id: SyncEntityID) throws -> SyncRecord? {
        records[id]
    }
}

private struct FetchedCommitCapture {
    let batchID: UUID
    let result: SyncMergeResult
    let deleted: [SyncEntityID]
}

private final class FakeFetchedBatchCommitter: SyncFetchedBatchCommitting, @unchecked Sendable {
    private let lock = NSLock()
    private let recorder: CoordinatorOperationRecorder
    private let failFetchedCommit: Bool
    private let failingFetchedBatchIDs: Set<UUID>
    private let fetchedCommitGate: FetchedCommitGate?
    private let failConflictCommit: Bool
    private let conflictCommitGate: ConflictCommitGate?
    private var conflictFailuresRemaining: Int
    private let journal: FakeCoordinatorJournal?
    private var fetchedStorage: [FetchedCommitCapture] = []
    private var conflictStorage: [(UUID, SyncMergeResult)] = []
    private var conflictResolutions: [UUID: SyncConflictResolution] = [:]

    init(
        recorder: CoordinatorOperationRecorder = CoordinatorOperationRecorder(),
        failFetchedCommit: Bool = false,
        failingFetchedBatchIDs: Set<UUID> = [],
        suspendFetchedCommit: Bool = false,
        failConflictCommit: Bool = false,
        conflictFailuresRemaining: Int = 0,
        journal: FakeCoordinatorJournal? = nil,
        suspendConflictCommit: Bool = false
    ) {
        self.recorder = recorder
        self.failFetchedCommit = failFetchedCommit
        self.failingFetchedBatchIDs = failingFetchedBatchIDs
        fetchedCommitGate = suspendFetchedCommit ? FetchedCommitGate() : nil
        self.failConflictCommit = failConflictCommit
        self.conflictFailuresRemaining = conflictFailuresRemaining
        conflictCommitGate = suspendConflictCommit ? ConflictCommitGate() : nil
        self.journal = journal
    }

    var fetchedBatchIDs: [UUID] { withLock { fetchedStorage.map(\.batchID) } }
    var fetchedResults: [SyncMergeResult] { withLock { fetchedStorage.map(\.result) } }
    var conflictMutationIDs: [UUID] { withLock { conflictStorage.map(\.0) } }
    var conflictResults: [SyncMergeResult] { withLock { conflictStorage.map(\.1) } }

    func commitFetchedBatch(
        batch: SyncRemoteBatch,
        accountEpoch: CloudSyncAccountEpoch
    ) async throws {
        let batchID = batch.identity.batchID
        let deletedRecordIDs = batch.deletedRecordIDs
        let mergeResult = try SyncMergeEngine().merge(local: [], remote: batch.records, pendingLocalMutations: [])
        recorder.append("commitFetched:\(batchID.uuidString)")
        if let fetchedCommitGate {
            await fetchedCommitGate.suspend()
        }
        if failFetchedCommit || failingFetchedBatchIDs.contains(batchID) {
            throw FakeCoordinatorError.commitFailed
        }
        try accountEpoch.withCurrent {
            withLock {
                fetchedStorage.append(.init(
                    batchID: batchID,
                    result: mergeResult,
                    deleted: deletedRecordIDs
                ))
            }
        }
    }

    func didAcknowledgeFetchedBatch(batch: SyncRemoteBatchIdentity, accountEpoch: CloudSyncAccountEpoch) async throws {
        try accountEpoch.requireCurrent()
    }

    func waitUntilFetchedCommitSuspended() async -> Bool {
        guard let fetchedCommitGate else { return false }
        for _ in 0..<2_000 {
            if await fetchedCommitGate.isSuspended { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await fetchedCommitGate.isSuspended
    }

    func resumeFetchedCommit() async {
        await fetchedCommitGate?.resume()
    }

    func commitServerRecordChanged(input: SyncConflictInput, accountEpoch: CloudSyncAccountEpoch) async throws -> SyncConflictCommitResult {
        if let conflictCommitGate { await conflictCommitGate.suspendOnce() }
        return try accountEpoch.withCurrent {
            let shouldFail = withLock { () -> Bool in
                guard conflictFailuresRemaining > 0 else { return false }
                conflictFailuresRemaining -= 1; return true
            }
            if failConflictCommit || shouldFail { throw FakeCoordinatorError.commitFailed }
            guard let journal else { throw FakeCoordinatorError.inconsistentJournal }
            let current = try journal.pendingVersioned().filter { $0.mutation.recordID == input.serverRecord.id }
            guard current.map(\.mutation) == input.expectedRecordQueue, current.map(\.token) == input.expectedVersions else { return .stalePredecessor }
            if let prior = withLock({ conflictResolutions[input.failedAttemptID] }) {
                guard prior.input.failedVersion == input.failedVersion else { return .obsoleteFailure }
                if current.map(\.token) == prior.versions { return .committed(prior) }
            }
            var base = input.serverRecord
            var replacements: [SyncMutation] = []
            var last: SyncMergeResult?
            var attachmentHeads: [SyncAttachmentSlot: UUID] = [:]
            for mutation in input.expectedRecordQueue {
                let result = try SyncMergeEngine().merge(local: mutation.savedRecordVersion.map { [$0.record] } ?? [],
                    remote: [base], pendingLocalMutations: [mutation])
                guard let record = result.records.first(where: { $0.id == mutation.recordID }) else { throw FakeCoordinatorError.inconsistentJournal }
                base = record; last = result
                attachmentHeads.merge(result.resolvedAttachmentVersionIDs) { _, new in new }
                if mutation.intent == .delete { replacements.append(mutation) }
                else { replacements.append(try SyncMutation.save(recordVersion: SyncRecordVersion(record: record),
                    attachmentSource: mutation.attachmentSource, mutationID: mutation.mutationID)) }
            }
            guard let first = replacements.first, let last else { throw FakeCoordinatorError.inconsistentJournal }
            recorder.append("commitConflict:\(input.failedMutation.mutationID.uuidString)")
            let complete = SyncMergeResult(records: last.records, conflicts: last.conflicts,
                recordsToUpload: last.recordsToUpload, legacyRecordIDsToDelete: last.legacyRecordIDsToDelete,
                mutationsToUpload: replacements, resolvedAttachmentVersionIDs: attachmentHeads)
            withLock { conflictStorage.append((input.failedMutation.mutationID, complete)) }
            try journal.replaceExactRecordQueue(input.failedMutation.identity, with: replacements)
            let versions = try journal.pendingVersioned().filter { $0.mutation.recordID == input.serverRecord.id }.map(\.token)
            let resolution = try SyncConflictResolution(transactionID: UUID(), input: input, replacement: first,
                followingReplacements: Array(replacements.dropFirst()), versions: versions)
            withLock { conflictResolutions[input.failedAttemptID] = resolution }
            return .committed(resolution)
        }
    }

    func waitUntilConflictCommitSuspended() async -> Bool {
        guard let conflictCommitGate else { return false }
        for _ in 0..<2_000 {
            if await conflictCommitGate.isSuspended { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await conflictCommitGate.isSuspended
    }

    func resumeConflictCommit() async {
        await conflictCommitGate?.resume()
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private actor FetchedCommitGate {
    private var suspended = false
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    var isSuspended: Bool { suspended }

    func suspend() async {
        suspended = true
        await withCheckedContinuation { resumeContinuation = $0 }
        suspended = false
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private actor ConflictCommitGate {
    private var shouldSuspend = true
    private var suspended = false
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    var isSuspended: Bool { suspended }

    func suspendOnce() async {
        guard shouldSuspend else { return }
        shouldSuspend = false
        suspended = true
        await withCheckedContinuation { resumeContinuation = $0 }
        suspended = false
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private enum FakeCoordinatorError: Error {
    case commitFailed
    case inconsistentJournal
    case transportResolutionFailed
}

@MainActor private func coordinatorOutgoing(_ transport: CKSyncEngineTransport, _ id: CKRecord.ID) async throws -> CKRecord {
    for _ in 0..<1000 {
        if let record = await transport.recordZoneChangeBatch(pendingChanges: [.saveRecord(id)], scope: .all)?.recordsToSave.first { return record }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw SyncConflictError.missingAuthority
}
