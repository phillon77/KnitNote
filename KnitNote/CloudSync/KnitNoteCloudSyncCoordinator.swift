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

    /// Atomically compares the complete same-record FIFO identities with
    /// `expectedRecordQueue` and replaces that exact queue, or returns stale.
    /// The final synchronous durable CAS must run inside `accountEpoch.withCurrent`,
    /// including after any suspension, just like a fetched-batch commit.
    func commitServerRecordChanged(
        failedMutation: SyncMutation,
        accountEpoch: CloudSyncAccountEpoch,
        expectedRecordQueue: [SyncMutationIdentity],
        mergeResult: SyncMergeResult
    ) async throws -> SyncFailedMutationCommitResult
}

struct SyncFailedMutationResolution: Equatable, Sendable {
    let failedMutation: SyncMutationIdentity
    let replacement: SyncMutation
    let followingReplacements: [SyncMutation]
}
enum SyncFailedMutationCommitResult: Equatable, Sendable {
    case committed(SyncFailedMutationResolution)
    case staleRecordQueue
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
    private var resolvedFailedAttempts: [SyncMutationIdentity: Set<UUID>] = [:]
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
            let pending = try journal.pending()
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
        case let .sent(recordID, mutationID):
            await handleSent(recordID: recordID, mutationID: mutationID)
        case let .sendRequestCompleted(requestID):
            handleSendRequestCompleted(requestID)
        case let .mutationFailed(recordID, mutationID, failure, accountEpoch, attemptID):
            await handleMutationFailure(
                recordID: recordID,
                mutationID: mutationID,
                failure: failure,
                accountEpoch: accountEpoch,
                attemptID: attemptID
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
            let stagedPending = try journal.pending()
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

    private func handleSent(recordID: SyncEntityID, mutationID: UUID) async {
        do {
            let pending = try journal.pending()
            guard let head = pending.first(where: { $0.recordID == recordID }),
                  head.mutationID == mutationID else { return }
            try journal.acknowledge([head.identity])
            resolvedFailedAttempts.removeValue(forKey: head.identity)
            do {
                try await transport.acknowledgeSentMutation(head.identity)
            } catch {
                fail(.assetCleanup)
                return
            }
            let remaining = try journal.pending()
            let hasBlocker = !blockingFetchedBatches.isEmpty
                || !blockingConflictMutations.isEmpty
            publish(
                phase: hasBlocker
                    ? .needsAttention
                    : (activeCycle == nil ? .waiting : .syncing),
                pendingCount: remaining.count,
                issue: hasBlocker ? status.issue : nil
            )
        } catch {
            fail(.journal)
        }
    }

    private func handleMutationFailure(
        recordID: SyncEntityID,
        mutationID: UUID,
        failure: CloudSyncFailure,
        accountEpoch: CloudSyncAccountEpoch,
        attemptID: UUID
    ) async {
        guard case let .serverRecordChanged(serverRecordID, serverRecord) = failure else {
            handleTransportFailure(failure)
            return
        }
        let failedIdentity = SyncMutationIdentity(recordID: recordID, mutationID: mutationID)
        guard resolvedFailedAttempts[failedIdentity]?.contains(attemptID) != true else { return }
        do {
            try accountEpoch.requireCurrent()
            guard serverRecordID == recordID,
                  let serverRecord,
                  serverRecord.id == recordID else {
                fail(.inconsistentEvent)
                return
            }
            while true {
                try accountEpoch.requireCurrent()
                let pending = try journal.pending()
                guard let head = pending.first(where: { $0.recordID == recordID }),
                      head.mutationID == mutationID else { return }
                let localRecord: SyncRecord?
                if let immutableSave = head.savedRecordVersion?.record {
                    localRecord = immutableSave
                } else {
                    localRecord = try recordProvider.record(for: recordID)
                }
                let sameRecordQueue = pending.filter { $0.recordID == recordID }
                let expectedQueue = sameRecordQueue.map(\.identity)
                let result = try rebasedConflictResult(
                    localRecord: localRecord,
                    serverRecord: serverRecord,
                    mutations: sameRecordQueue
                )
                let commitResult: SyncFailedMutationCommitResult
                do {
                    commitResult = try await fetchedBatchCommitter.commitServerRecordChanged(
                        failedMutation: head,
                        accountEpoch: accountEpoch,
                        expectedRecordQueue: expectedQueue,
                        mergeResult: result
                    )
                } catch CloudSyncAccountEpochError.stale {
                    return
                } catch {
                    failConflict(failedIdentity, issue: .durableCommit)
                    return
                }
                guard case let .committed(resolution) = commitResult else { continue }
                try accountEpoch.requireCurrent()
                guard resolution.failedMutation == head.identity,
                      resolution.replacement.identity == head.identity,
                      resolution.followingReplacements.map(\.identity)
                        == sameRecordQueue.dropFirst().map(\.identity),
                      ([resolution.replacement] + resolution.followingReplacements)
                        .allSatisfy({ $0.recordID == head.recordID }) else {
                    fail(.inconsistentEvent)
                    return
                }
                let replacements = [resolution.replacement] + resolution.followingReplacements
                let durablePending = try journal.pending()
                let durableQueue = durablePending.filter { $0.recordID == recordID }
                guard durableQueue.map(\.identity).starts(with: replacements.map(\.identity)) else {
                    fail(.inconsistentEvent)
                    return
                }
                if durableQueue.count != replacements.count { continue }
                do {
                    try await transport.resolveFailedMutation(
                        mutationID,
                        replacement: resolution.replacement,
                        followingReplacements: resolution.followingReplacements
                    )
                } catch CloudSyncTransportError.invalidReplacement {
                    continue
                } catch {
                    failConflict(failedIdentity, issue: .operation)
                    return
                }
                clearConflictBlocker(failedIdentity)
                resolvedFailedAttempts[failedIdentity, default: []].insert(attemptID)
                publish(
                    phase: activeCycle == nil ? .waiting : .syncing,
                    pendingCount: durablePending.count,
                    issue: nil
                )
                return
            }
        } catch CloudSyncAccountEpochError.stale {
            return
        } catch let error as CoordinatorConsistencyError {
            switch error {
            case let .missingLocalRecord(id):
                fail(.missingLocalRecord(id))
            case .missingMergedRecord, .emptyConflictQueue:
                fail(.inconsistentEvent)
            }
        } catch {
            fail(.operation)
        }
    }

    private func requiredLocalRecords(
        remoteRecords: [SyncRecord],
        deletedRecordIDs: [SyncEntityID],
        pending: [SyncMutation]
    ) throws -> [SyncRecord] {
        let ids = Set(remoteRecords.map(\.id))
            .union(deletedRecordIDs)
            .union(pending.map(\.recordID))
            .sorted(by: entityIDLess)
        let pendingSaves = Set(pending.compactMap { mutation -> SyncEntityID? in
            mutation.intent == .save ? mutation.recordID : nil
        })
        return try ids.compactMap { id in
            let record = try recordProvider.record(for: id)
            if record == nil, pendingSaves.contains(id) {
                throw CoordinatorConsistencyError.missingLocalRecord(id)
            }
            return record
        }
    }

    private func rebasedConflictResult(
        localRecord: SyncRecord?,
        serverRecord: SyncRecord,
        mutations: [SyncMutation]
    ) throws -> SyncMergeResult {
        guard !mutations.isEmpty else { throw CoordinatorConsistencyError.emptyConflictQueue }
        var baseRecord: SyncRecord?
        var replacements: [SyncMutation] = []
        var conflicts: [SyncConflict] = []
        var recordsToUpload: Set<SyncEntityID> = []
        var legacyRecordIDsToDelete: Set<SyncEntityID> = []
        var resolvedAttachmentVersionIDs: [SyncAttachmentSlot: UUID] = [:]
        var lastResult: SyncMergeResult?

        for (index, mutation) in mutations.enumerated() {
            let result = try mergeEngine.merge(
                local: index == 0 ? localRecord.map { [$0] } ?? [] : baseRecord.map { [$0] } ?? [],
                remote: index == 0 ? [serverRecord] : [],
                pendingLocalMutations: [mutation]
            )
            let mergedRecord = result.records.first(where: { $0.id == mutation.recordID })
            let replacement: SyncMutation
            switch mutation {
            case .save:
                guard let mergedRecord else {
                    throw CoordinatorConsistencyError.missingMergedRecord(mutation.recordID)
                }
                replacement = try .save(
                    recordVersion: SyncRecordVersion(record: mergedRecord),
                    attachmentSource: mutation.attachmentSource,
                    mutationID: mutation.mutationID
                )
            case .delete:
                replacement = mutation
            }
            replacements.append(replacement)
            baseRecord = mergedRecord
            for conflict in result.conflicts where !conflicts.contains(conflict) {
                conflicts.append(conflict)
            }
            recordsToUpload.formUnion(result.recordsToUpload)
            legacyRecordIDsToDelete.formUnion(result.legacyRecordIDsToDelete)
            for (slot, versionID) in result.resolvedAttachmentVersionIDs {
                resolvedAttachmentVersionIDs[slot] = versionID
            }
            lastResult = result
        }

        guard let lastResult else { throw CoordinatorConsistencyError.emptyConflictQueue }
        return SyncMergeResult(
            records: lastResult.records,
            conflicts: conflicts,
            recordsToUpload: recordsToUpload,
            legacyRecordIDsToDelete: legacyRecordIDsToDelete,
            mutationsToUpload: replacements,
            resolvedAttachmentVersionIDs: resolvedAttachmentVersionIDs
        )
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
            let pending = try journal.pending()
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
