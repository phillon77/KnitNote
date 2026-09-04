import Combine
import Foundation

enum CloudSyncIssue: Equatable, Sendable {
    case transport(CloudSyncFailure)
    case missingLocalRecord(SyncEntityID)
    case durableCommit
    case journal
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
    func commitFetchedBatch(
        batchID: UUID,
        mergeResult: SyncMergeResult,
        deletedRecordIDs: [SyncEntityID]
    ) async throws

    func commitServerRecordChanged(
        failedMutation: SyncMutation,
        mergeResult: SyncMergeResult
    ) async throws -> SyncFailedMutationResolution
}

struct SyncFailedMutationResolution: Equatable, Sendable {
    let failedMutation: SyncMutationIdentity
    let replacement: SyncMutation
    let followingReplacements: [SyncMutation]
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
    private var acknowledgedBatchIDs = RecentUUIDs()
    private var blockingFetchedBatches: [UUID: CloudSyncIssue] = [:]
    private var blockingFetchedBatchOrder: [UUID] = []
    private var resolvedFailedMutationIDs = RecentUUIDs()

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
        case .accountChanged:
            accountInvalidated = true
            activeCycle = nil
            fail(.accountChanged)
        case let .fetched(batchID, records, deleted):
            await handleFetched(batchID: batchID, records: records, deleted: deleted)
        case let .fetchRequestCompleted(requestID):
            await handleFetchRequestCompleted(requestID)
        case let .sent(recordID, mutationID):
            handleSent(recordID: recordID, mutationID: mutationID)
        case let .sendRequestCompleted(requestID):
            handleSendRequestCompleted(requestID)
        case let .mutationFailed(recordID, mutationID, failure):
            await handleMutationFailure(
                recordID: recordID,
                mutationID: mutationID,
                failure: failure
            )
        case .zoneReady, .zoneDeleted:
            if activeCycle == nil, !accountInvalidated, status.issue == nil {
                publish(phase: .waiting, pendingCount: currentPendingCount(), issue: nil)
            }
        case .stateUpdated:
            break
        case let .failed(failure):
            handleTransportFailure(failure)
        }
    }

    private func handleFetched(
        batchID: UUID,
        records: [SyncRecord],
        deleted: [SyncEntityID]
    ) async {
        guard !acknowledgedBatchIDs.contains(batchID) else { return }
        do {
            let pending = try journal.pending()
            let local = try requiredLocalRecords(
                remoteRecords: records,
                deletedRecordIDs: deleted,
                pending: pending
            )
            let result = try mergeEngine.merge(
                local: local,
                remote: records,
                pendingLocalMutations: pending
            )
            do {
                try await fetchedBatchCommitter.commitFetchedBatch(
                    batchID: batchID,
                    mergeResult: result,
                    deletedRecordIDs: deleted
                )
            } catch {
                failFetched(batchID, issue: .durableCommit)
                return
            }
            let stagedPending = try journal.pending()
            if !stagedPending.isEmpty {
                try await transport.schedule(stagedPending)
            }
            try await transport.acknowledgeFetchedBatch(batchID)
            blockingFetchedBatches.removeValue(forKey: batchID)
            blockingFetchedBatchOrder.removeAll { $0 == batchID }
            acknowledgedBatchIDs.insert(batchID)
            publish(
                phase: activeCycle == nil ? .waiting : .syncing,
                pendingCount: stagedPending.count,
                issue: nil
            )
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

    private func handleSent(recordID: SyncEntityID, mutationID: UUID) {
        do {
            let pending = try journal.pending()
            guard let head = pending.first(where: { $0.recordID == recordID }),
                  head.mutationID == mutationID else { return }
            try journal.acknowledge([head.identity])
            let remaining = try journal.pending()
            let hasBlockingFetchedBatch = !blockingFetchedBatches.isEmpty
            publish(
                phase: hasBlockingFetchedBatch
                    ? .needsAttention
                    : (activeCycle == nil ? .waiting : .syncing),
                pendingCount: remaining.count,
                issue: hasBlockingFetchedBatch ? status.issue : nil
            )
        } catch {
            fail(.journal)
        }
    }

    private func handleMutationFailure(
        recordID: SyncEntityID,
        mutationID: UUID,
        failure: CloudSyncFailure
    ) async {
        guard case let .serverRecordChanged(serverRecordID, serverRecord) = failure else {
            handleTransportFailure(failure)
            return
        }
        guard !resolvedFailedMutationIDs.contains(mutationID) else { return }
        do {
            guard serverRecordID == recordID,
                  let serverRecord,
                  serverRecord.id == recordID else {
                fail(.inconsistentEvent)
                return
            }
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
            let result = try rebasedConflictResult(
                localRecord: localRecord,
                serverRecord: serverRecord,
                mutations: sameRecordQueue
            )
            let resolution: SyncFailedMutationResolution
            do {
                resolution = try await fetchedBatchCommitter.commitServerRecordChanged(
                    failedMutation: head,
                    mergeResult: result
                )
            } catch {
                fail(.durableCommit)
                return
            }
            guard resolution.failedMutation == head.identity,
                  resolution.replacement.identity == head.identity,
                  resolution.followingReplacements.map(\.identity)
                    == sameRecordQueue.dropFirst().map(\.identity),
                  ([resolution.replacement] + resolution.followingReplacements)
                    .allSatisfy({ $0.recordID == head.recordID }) else {
                fail(.inconsistentEvent)
                return
            }
            let durablePending = try journal.pending()
            let durableQueue = durablePending.filter { $0.recordID == recordID }
            guard durableQueue == [resolution.replacement] + resolution.followingReplacements else {
                fail(.inconsistentEvent)
                return
            }
            try await transport.resolveFailedMutation(
                mutationID,
                replacement: resolution.replacement,
                followingReplacements: resolution.followingReplacements
            )
            resolvedFailedMutationIDs.insert(mutationID)
            publish(
                phase: activeCycle == nil ? .waiting : .syncing,
                pendingCount: durablePending.count,
                issue: nil
            )
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
            lastResult = result
        }

        guard let lastResult else { throw CoordinatorConsistencyError.emptyConflictQueue }
        return SyncMergeResult(
            records: lastResult.records,
            conflicts: lastResult.conflicts,
            recordsToUpload: lastResult.recordsToUpload,
            legacyRecordIDsToDelete: lastResult.legacyRecordIDsToDelete,
            mutationsToUpload: replacements,
            resolvedAttachmentVersionIDs: lastResult.resolvedAttachmentVersionIDs
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
        guard pending.isEmpty, blockingFetchedBatches.isEmpty else {
            publish(
                phase: blockingFetchedBatches.isEmpty
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
        if let blockingIssue = firstBlockingFetchedIssue() {
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

    private func handleOperationError(_ error: Error) {
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

private struct RecentUUIDs {
    private static let capacity = 512
    private var values: Set<UUID> = []
    private var order: [UUID] = []

    func contains(_ value: UUID) -> Bool {
        values.contains(value)
    }

    mutating func insert(_ value: UUID) {
        guard values.insert(value).inserted else { return }
        order.append(value)
        if order.count > Self.capacity {
            values.remove(order.removeFirst())
        }
    }
}

private enum CoordinatorConsistencyError: Error {
    case missingLocalRecord(SyncEntityID)
    case missingMergedRecord(SyncEntityID)
    case emptyConflictQueue
}
