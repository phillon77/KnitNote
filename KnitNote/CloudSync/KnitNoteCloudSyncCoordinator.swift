import Combine
import Foundation

private enum CloudSyncIssueError: Error { case failed }

enum CloudSyncIssue: Equatable, Sendable {
    case transport(CloudSyncFailure)
    case missingLocalRecord(SyncEntityID)
    case durableCommit
    case journal
    case assetCleanup
    case operation
    case inconsistentEvent
    case accountChanged
}

struct CloudSyncStatusSnapshot: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case disabled
        case waiting
        case syncing
        case needsAttention
    }

    let phase: Phase
    let pendingCount: Int
    let lastCompleteSuccess: Date?
    let issue: CloudSyncIssue?
}

protocol SyncFetchedBatchCommitting: Sendable {
    /// The final synchronous durable boundary must execute through
    /// `accountEpoch.withCurrent` so an account switch and the write are
    /// linearly ordered.
    func commitFetchedBatch(
        batch: SyncRemoteBatch,
        accountEpoch: CloudSyncAccountEpoch
    ) async throws

    func didAcknowledgeFetchedBatch(batch: SyncRemoteBatchIdentity,
        accountEpoch: CloudSyncAccountEpoch) async throws

    func commitServerRecordChanged(input: SyncConflictInput, accountEpoch: CloudSyncAccountEpoch) async throws -> SyncConflictCommitResult
}

@MainActor
final class KnitNoteCloudSyncCoordinator: ObservableObject {
    @Published private(set) var status = CloudSyncStatusSnapshot(
        phase: .disabled,
        pendingCount: 0,
        lastCompleteSuccess: nil,
        issue: nil
    )

    private let transport: any CloudSyncTransport
    private let journal: any SyncMutationJournalProtocol
    private let mergeEngine: SyncMergeEngine
    private let recordProvider: any SyncRecordProvider
    private let fetchedBatchCommitter: any SyncFetchedBatchCommitting
    private let screenshotMode: Bool
    private let now: () -> Date

    private var eventLoopTask: Task<Void, Never>?
    private var started = false
    private var activeCycle: SyncCycle?
    private var accountInvalidated = false
    private var acknowledgedBatchIDs: Set<UUID> = []
    private var committedFetchedBatches: [UUID: SyncRemoteBatchIdentity] = [:]
    private var blockingFetchedBatches: [UUID: CloudSyncIssue] = [:]
    private var blockingFetchedBatchOrder: [UUID] = []
    private var blockingConflictMutations: [SyncMutationIdentity: CloudSyncIssue] = [:]
    private var blockingConflictMutationOrder: [SyncMutationIdentity] = []
    private var transitionWaiter: CheckedContinuation<Void, any Error>?
    private var transitionReady: ((CloudInitialFetchReceipt) throws -> Void)?
    var accountChangeHandler: ((String?, String?) -> Void)?

    func startForAccountTransition(onReady: @escaping (CloudInitialFetchReceipt) throws -> Void) async throws {
        guard !started else { throw CloudSyncIssueError.failed }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transitionWaiter = continuation
                transitionReady = onReady
                Task { await self.start() }
            }
        } onCancel: {
            Task { @MainActor in self.stopForAccountTransition() }
        }
    }

    func stopForAccountTransition() {
        accountInvalidated = true
        activeCycle = nil
        eventLoopTask?.cancel()
        finishTransitionWaiter(.failure(CancellationError()))
    }

    private func finishTransitionWaiter(_ result: Result<Void, any Error>) {
        let waiter = transitionWaiter
        transitionWaiter = nil; transitionReady = nil
        waiter?.resume(with: result)
    }

    init(
        transport: any CloudSyncTransport,
        journal: any SyncMutationJournalProtocol,
        mergeEngine: SyncMergeEngine,
        recordProvider: any SyncRecordProvider,
        fetchedBatchCommitter: any SyncFetchedBatchCommitting,
        screenshotMode: Bool,
        now: @escaping () -> Date = Date.init
    ) {
        self.transport = transport
        self.journal = journal
        self.mergeEngine = mergeEngine
        self.recordProvider = recordProvider
        self.fetchedBatchCommitter = fetchedBatchCommitter
        self.screenshotMode = screenshotMode
        self.now = now
    }

    deinit {
        eventLoopTask?.cancel()
    }

    func start() async {
        guard !started else { return }
        started = true
        guard !screenshotMode else { return }

        let events = transport.events
        eventLoopTask = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                await self.handle(event)
            }
        }

        do {
            try await transport.start()
            let pending = try journal.pendingVersioned()
            publish(phase: .waiting, pendingCount: pending.count, issue: nil)
            if !pending.isEmpty {
                try await transport.schedule(pending)
            }
            await performInitialSync()
        } catch {
            fail(.operation)
        }
    }

    func syncNow() async {
        guard !screenshotMode, !accountInvalidated else { return }
        guard started else {
            await start()
            return
        }
        await beginCycle(mode: .manual)
    }

    private func performInitialSync() async {
        await beginCycle(mode: .initial)
    }

    private func beginCycle(mode: SyncCycle.Mode) async {
        guard activeCycle == nil, !accountInvalidated else { return }
        let cycle = SyncCycle(id: UUID(), mode: mode)
        activeCycle = cycle
        publish(phase: .syncing, pendingCount: currentPendingCount(), issue: nil)
        do {
            try await transport.fetchNow(completionID: cycle.id)
        } catch {
            handleOperationError(error)
        }
    }

    private func handle(_ event: CloudSyncEvent) async {
        if accountInvalidated {
            guard case .accountChanged = event else { return }
        }
        switch event {
        case let .accountChanged(previous, current):
            accountInvalidated = true
            activeCycle = nil
            fail(.accountChanged)
            accountChangeHandler?(previous, current)
        case let .fetched(batchID, accountEpoch, records, deleted):
            await handleFetched(
                batchID: batchID,
                accountEpoch: accountEpoch,
                records: records,
                deleted: deleted
            )
        case let .acknowledgedFetched(identity, accountEpoch):
            await reconcileAcknowledgement(identity, accountEpoch: accountEpoch)
        case let .fetchRequestCompleted(requestID):
            await handleFetchRequestCompleted(requestID)
        case let .sent(token, attemptID, accountEpoch):
            await handleSent(token: token, attemptID: attemptID, accountEpoch: accountEpoch)
        case let .sendRequestCompleted(requestID):
            handleSendRequestCompleted(requestID)
        case let .mutationFailed(recordID, mutationID, failure, accountEpoch, attemptID, attempted):
            await handleMutationFailure(
                recordID: recordID,
                mutationID: mutationID,
                failure: failure,
                accountEpoch: accountEpoch,
                attemptID: attemptID, attempted: attempted
            )
        case .zoneReady, .zoneDeleted:
            if activeCycle == nil, !accountInvalidated, status.issue == nil {
                publish(phase: .waiting, pendingCount: currentPendingCount(), issue: nil)
            }
        case .stateUpdated:
            acknowledgedBatchIDs.removeAll(keepingCapacity: true)
        case let .failed(failure):
            handleTransportFailure(failure)
        }
    }

    private func handleFetched(
        batchID: UUID,
        accountEpoch: CloudSyncAccountEpoch,
        records: [SyncRecord],
        deleted: [SyncEntityID]
    ) async {
        guard !acknowledgedBatchIDs.contains(batchID) else { return }
        do {
            try accountEpoch.requireCurrent()
            let batch = try SyncRemoteBatch(accountIDHash: accountEpoch.verifiedAccountIdentity().accountIDHash,
                batchID: batchID, records: records, deletedRecordIDs: deleted)
            do {
                if let committed = committedFetchedBatches[batchID] {
                    guard committed == batch.identity else { throw SyncRemoteBatchError.identityCollision }
                } else {
                    try await fetchedBatchCommitter.commitFetchedBatch(batch: batch, accountEpoch: accountEpoch)
                    committedFetchedBatches[batchID] = batch.identity
                }
            } catch CloudSyncAccountEpochError.stale {
                return
            } catch {
                failFetched(batchID, issue: .durableCommit)
                return
            }
            try accountEpoch.requireCurrent()
            let stagedPending = try journal.pendingVersioned()
            if !stagedPending.isEmpty {
                try await transport.schedule(stagedPending)
            }
            try await transport.acknowledgeFetchedBatch(batchID)
            try await transport.verifyFetchedBatchAcknowledgement(batchID)
            try await fetchedBatchCommitter.didAcknowledgeFetchedBatch(batch: batch.identity, accountEpoch: accountEpoch)
            try await transport.finishFetchedBatchAcknowledgement(batch.identity)
            committedFetchedBatches.removeValue(forKey: batchID)
            blockingFetchedBatches.removeValue(forKey: batchID)
            blockingFetchedBatchOrder.removeAll { $0 == batchID }
            acknowledgedBatchIDs.insert(batchID)
            publish(
                phase: activeCycle == nil ? .waiting : .syncing,
                pendingCount: stagedPending.count,
                issue: nil
            )
        } catch CloudSyncAccountEpochError.stale {
            return
        } catch let error as CoordinatorConsistencyError {
            switch error {
            case let .missingLocalRecord(id):
                failFetched(batchID, issue: .missingLocalRecord(id))
            case .missingMergedRecord, .emptyConflictQueue:
                failFetched(batchID, issue: .inconsistentEvent)
            }
        } catch {
            failFetched(batchID, issue: .operation)
        }
    }

    private func reconcileAcknowledgement(_ identity: SyncRemoteBatchIdentity, accountEpoch: CloudSyncAccountEpoch) async {
        do {
            try accountEpoch.requireCurrent()
            guard try accountEpoch.verifiedAccountIdentity().accountIDHash == identity.accountIDHash else {
                throw SyncRemoteBatchError.missingAuthority
            }
            try await transport.verifyFetchedBatchAcknowledgement(identity.batchID)
            try await fetchedBatchCommitter.didAcknowledgeFetchedBatch(batch: identity, accountEpoch: accountEpoch)
            try await transport.finishFetchedBatchAcknowledgement(identity)
            acknowledgedBatchIDs.insert(identity.batchID)
            blockingFetchedBatches.removeValue(forKey: identity.batchID)
            blockingFetchedBatchOrder.removeAll { $0 == identity.batchID }
        } catch CloudSyncAccountEpochError.stale {
            return
        } catch {
            failFetched(identity.batchID, issue: .durableCommit)
        }
    }

    private func handleSent(token: SyncMutationVersionToken, attemptID: UUID, accountEpoch: CloudSyncAccountEpoch) async {
        do {
            do {
                try await transport.verifySentMutation(token, attemptID: attemptID, accountEpoch: accountEpoch)
            } catch CloudSyncAccountEpochError.stale { return }
              catch CloudSyncTransportError.staleOperation { return }
            let result = try accountEpoch.withCurrent { try journal.acknowledgeCurrentVersion(token) }
            guard result != .staleVersion else { return }
            do {
                try await transport.acknowledgeSentMutation(token, attemptID: attemptID)
            } catch { fail(.assetCleanup); return }
            let remaining = try journal.pending()
            let hasBlocker = !blockingFetchedBatches.isEmpty || !blockingConflictMutations.isEmpty
            publish(phase: hasBlocker ? .needsAttention : (activeCycle == nil ? .waiting : .syncing),
                pendingCount: remaining.count, issue: hasBlocker ? status.issue : nil)
        } catch CloudSyncAccountEpochError.stale { return }
          catch { fail(.journal) }
    }

    private func handleMutationFailure(recordID: SyncEntityID, mutationID: UUID,
        failure: CloudSyncFailure, accountEpoch: CloudSyncAccountEpoch, attemptID: UUID,
        attempted: SyncVersionedMutation) async {
        guard attempted.mutation.identity == SyncMutationIdentity(recordID: recordID, mutationID: mutationID),
              attempted.token.identity == attempted.mutation.identity else { fail(.inconsistentEvent); return }
        guard case let .serverRecordChanged(serverRecordID, serverRecord) = failure else {
            handleTransportFailure(failure); return
        }
        let failedIdentity = attempted.mutation.identity
        do {
            try accountEpoch.requireCurrent()
            guard serverRecordID == recordID, let serverRecord, serverRecord.id == recordID else {
                fail(.inconsistentEvent); return
            }
            let account = try accountEpoch.verifiedAccountIdentity()
            for _ in 0..<3 {
                try accountEpoch.requireCurrent()
                let queue = try journal.pendingVersioned().filter { $0.mutation.recordID == recordID }
                guard queue.first?.mutation.identity == failedIdentity else { return }
                let input = try SyncConflictInput(accountIDHash: account.accountIDHash,
                    failedAttemptID: attemptID, failedMutation: attempted.mutation, failedVersion: attempted.token,
                    serverRecord: serverRecord, expectedRecordQueue: queue.map(\.mutation), expectedVersions: queue.map(\.token))
                let result: SyncConflictCommitResult
                do { result = try await fetchedBatchCommitter.commitServerRecordChanged(input: input, accountEpoch: accountEpoch) }
                catch CloudSyncAccountEpochError.stale { return }
                catch { failConflict(failedIdentity, issue: .durableCommit); return }
                switch result {
                case .stalePredecessor: continue
                case .obsoleteFailure: return
                case let .committed(resolution):
                    let current = try journal.pendingVersioned().filter { $0.mutation.recordID == recordID }
                    guard current.map(\.mutation) == [resolution.replacement] + resolution.followingReplacements,
                          current.map(\.token) == resolution.versions else { continue }
                    do {
                        guard try await transport.resolveFailedMutation(resolution,
                            accountEpoch: accountEpoch, expectedQueue: current) == .accepted else { continue }
                    } catch CloudSyncAccountEpochError.stale { return }
                      catch { failConflict(failedIdentity, issue: .operation); return }
                    try accountEpoch.requireCurrent()
                    clearConflictBlocker(failedIdentity)
                    publish(phase: activeCycle == nil ? .waiting : .syncing, pendingCount: currentPendingCount(), issue: nil)
                    return
                }
            }
            failConflict(failedIdentity, issue: .durableCommit)
        } catch CloudSyncAccountEpochError.stale { return }
          catch { failConflict(failedIdentity, issue: .journal) }
    }

    private func handleTransportFailure(_ failure: CloudSyncFailure) {
        activeCycle = nil
        if case .retryable = failure {
            publish(
                phase: .waiting,
                pendingCount: currentPendingCount(),
                issue: .transport(failure)
            )
        } else {
            fail(.transport(failure))
        }
    }

    private func handleFetchRequestCompleted(_ requestID: UUID) async {
        guard let cycle = activeCycle, cycle.id == requestID else { return }
        do {
            if let transitionReady {
                guard blockingFetchedBatches.isEmpty else {
                    throw CloudSyncIssueError.failed
                }
                let receipt = try await transport.committedFetchReceipt(requestID: requestID)
                try receipt.epoch.requireCurrent()
                try transitionReady(receipt)
            }
            let pending = try journal.pendingVersioned()
            if !pending.isEmpty {
                try await transport.schedule(pending)
            }
            switch cycle.mode {
            case .initial:
                try await transport.finishMutationReplay(completionID: cycle.id)
            case .manual:
                try await transport.sendNow(completionID: cycle.id)
            }
            finishTransitionWaiter(.success(()))
        } catch {
            handleOperationError(error)
        }
    }

    private func handleSendRequestCompleted(_ requestID: UUID) {
        guard activeCycle?.id == requestID else { return }
        activeCycle = nil
        do {
            try markCompleteIfPossible()
        } catch {
            fail(.journal)
        }
    }

    private func markCompleteIfPossible() throws {
        let pending = try journal.pending()
        guard pending.isEmpty,
              blockingFetchedBatches.isEmpty,
              blockingConflictMutations.isEmpty else {
            publish(
                phase: blockingFetchedBatches.isEmpty && blockingConflictMutations.isEmpty
                    ? (activeCycle == nil ? .waiting : .syncing)
                    : .needsAttention,
                pendingCount: pending.count,
                issue: status.issue
            )
            return
        }
        status = CloudSyncStatusSnapshot(
            phase: .waiting,
            pendingCount: 0,
            lastCompleteSuccess: now(),
            issue: nil
        )
    }

    private func currentPendingCount() -> Int {
        (try? journal.pending().count) ?? status.pendingCount
    }

    private func publish(
        phase: CloudSyncStatusSnapshot.Phase,
        pendingCount: Int,
        issue: CloudSyncIssue?
    ) {
        if accountInvalidated {
            status = CloudSyncStatusSnapshot(
                phase: .needsAttention,
                pendingCount: pendingCount,
                lastCompleteSuccess: status.lastCompleteSuccess,
                issue: .accountChanged
            )
            return
        }
        if let blockingIssue = firstBlockingFetchedIssue() {
            status = CloudSyncStatusSnapshot(
                phase: .needsAttention,
                pendingCount: pendingCount,
                lastCompleteSuccess: status.lastCompleteSuccess,
                issue: blockingIssue
            )
            return
        }
        if let blockingIssue = firstBlockingConflictIssue() {
            status = CloudSyncStatusSnapshot(
                phase: .needsAttention,
                pendingCount: pendingCount,
                lastCompleteSuccess: status.lastCompleteSuccess,
                issue: blockingIssue
            )
            return
        }
        status = CloudSyncStatusSnapshot(
            phase: phase,
            pendingCount: pendingCount,
            lastCompleteSuccess: status.lastCompleteSuccess,
            issue: issue
        )
    }

    private func fail(_ issue: CloudSyncIssue) {
        finishTransitionWaiter(.failure(CloudSyncIssueError.failed))
        activeCycle = nil
        publish(
            phase: .needsAttention,
            pendingCount: currentPendingCount(),
            issue: issue
        )
    }

    private func failFetched(_ batchID: UUID, issue: CloudSyncIssue) {
        if blockingFetchedBatches[batchID] == nil {
            blockingFetchedBatchOrder.append(batchID)
        }
        blockingFetchedBatches[batchID] = issue
        fail(issue)
    }

    private func firstBlockingFetchedIssue() -> CloudSyncIssue? {
        blockingFetchedBatchOrder.lazy.compactMap { self.blockingFetchedBatches[$0] }.first
    }

    private func failConflict(
        _ identity: SyncMutationIdentity,
        issue: CloudSyncIssue
    ) {
        if blockingConflictMutations[identity] == nil {
            blockingConflictMutationOrder.append(identity)
        }
        blockingConflictMutations[identity] = issue
        fail(issue)
    }

    private func clearConflictBlocker(_ identity: SyncMutationIdentity) {
        blockingConflictMutations.removeValue(forKey: identity)
        blockingConflictMutationOrder.removeAll { $0 == identity }
    }

    private func firstBlockingConflictIssue() -> CloudSyncIssue? {
        blockingConflictMutationOrder.lazy.compactMap {
            self.blockingConflictMutations[$0]
        }.first
    }

    private func handleOperationError(_ error: Error) {
        finishTransitionWaiter(.failure(error))
        activeCycle = nil
        if let failure = error as? CloudSyncFailure {
            handleTransportFailure(failure)
        } else {
            fail(.operation)
        }
    }

    private func entityIDLess(_ lhs: SyncEntityID, _ rhs: SyncEntityID) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.uuid.uuidString < rhs.uuid.uuidString
    }
}

private struct SyncCycle: Equatable {
    enum Mode: Equatable {
        case initial
        case manual
    }

    let id: UUID
    let mode: Mode
}

private enum CoordinatorConsistencyError: Error {
    case missingLocalRecord(SyncEntityID)
    case missingMergedRecord(SyncEntityID)
    case emptyConflictQueue
}
