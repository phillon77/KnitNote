import CloudKit
import CryptoKit
import Foundation

protocol CloudSyncTransport: AnyObject, Sendable {
    var events: AsyncStream<CloudSyncEvent> { get }
    func start() async throws
    func schedule(_ mutations: [SyncVersionedMutation]) async throws
    func finishMutationReplay(completionID: UUID?) async throws
    func acknowledgeFetchedBatch(_ batchID: UUID) async throws
    func verifyFetchedBatchAcknowledgement(_ batchID: UUID) async throws
    func finishFetchedBatchAcknowledgement(_ identity: SyncRemoteBatchIdentity) async throws
    func verifySentMutation(_ token: SyncMutationVersionToken, attemptID: UUID, accountEpoch: CloudSyncAccountEpoch) async throws
    func acknowledgeSentMutation(_ token: SyncMutationVersionToken, attemptID: UUID) async throws
    func resolveFailedMutation(_ resolution: SyncConflictResolution, accountEpoch: CloudSyncAccountEpoch,
        expectedQueue: [SyncVersionedMutation]) async throws -> CloudConflictHandoffResult
    func fetchNow(completionID: UUID?) async throws
    func sendNow(completionID: UUID?) async throws
    func committedFetchReceipt(requestID: UUID) async throws -> CloudInitialFetchReceipt
}

struct CloudInitialFetchReceipt: Sendable {
    let requestID: UUID
    let batchIDs: Set<UUID>
    let epoch: CloudSyncAccountEpoch
    fileprivate init(requestID: UUID, batchIDs: Set<UUID>, epoch: CloudSyncAccountEpoch) {
        self.requestID = requestID; self.batchIDs = batchIDs; self.epoch = epoch
    }
}

extension CloudSyncTransport {
    func committedFetchReceipt(requestID: UUID) async throws -> CloudInitialFetchReceipt {
        throw CloudSyncTransportError.unknownFetchedBatch
    }
    func finishMutationReplay() async throws {
        try await finishMutationReplay(completionID: nil)
    }

    func fetchNow() async throws {
        try await fetchNow(completionID: nil)
    }

    func sendNow() async throws {
        try await sendNow(completionID: nil)
    }
}

enum CloudConflictHandoffResult: Equatable, Sendable { case accepted, stale }

enum CloudSyncEvent: Sendable {
    case accountChanged(previous: String?, current: String?)
    case fetched(
        batchID: UUID,
        accountEpoch: CloudSyncAccountEpoch,
        records: [SyncRecord],
        deleted: [SyncEntityID]
    )
    case acknowledgedFetched(SyncRemoteBatchIdentity, accountEpoch: CloudSyncAccountEpoch)
    case fetchRequestCompleted(UUID)
    case sent(token: SyncMutationVersionToken, attemptID: UUID, accountEpoch: CloudSyncAccountEpoch)
    case sendRequestCompleted(UUID)
    case mutationFailed(recordID: SyncEntityID, mutationID: UUID, failure: CloudSyncFailure,
                        accountEpoch: CloudSyncAccountEpoch, attemptID: UUID, attempted: SyncVersionedMutation)
    case zoneReady
    case zoneDeleted
    case stateUpdated(Data)
    case failed(CloudSyncFailure)
}

enum CloudSyncAccountEpochError: Error, Equatable {
    case stale
}

/// Immutable identity plus a thread-safe invalidation latch. Durable domain
/// committers must check this latch at their atomic commit boundary.
final class CloudSyncAccountEpoch: @unchecked Sendable {
    let accountIdentifier: String
    let zoneName: String
    let ownerName: String
    let generation: UInt64
    let containerIdentifier: String?

    func verifiedAccountIdentity() throws -> SyncAccountIdentity {
        guard let containerIdentifier else { throw CloudSyncTransportError.missingAccountIdentity }
        return try SyncAccountIdentity(containerIdentifier: containerIdentifier, userRecordName: accountIdentifier)
    }

    private let lock = NSLock()
    private var current = true

    init(
        accountIdentifier: String,
        zoneID: CKRecordZone.ID,
        generation: UInt64,
        containerIdentifier: String? = nil
    ) {
        self.accountIdentifier = accountIdentifier
        zoneName = zoneID.zoneName
        ownerName = zoneID.ownerName
        self.generation = generation
        self.containerIdentifier = containerIdentifier
    }

    func requireCurrent() throws {
        lock.lock()
        defer { lock.unlock() }
        guard current else { throw CloudSyncAccountEpochError.stale }
    }

    /// Runs the actual durable write while account invalidation is excluded,
    /// making the write and an account switch linearly ordered.
    func withCurrent<T>(_ durableWrite: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard current else { throw CloudSyncAccountEpochError.stale }
        return try durableWrite()
    }

    func invalidate() {
        lock.lock()
        current = false
        lock.unlock()
    }
}

enum CloudSyncFailure: Error, Equatable, Sendable {
    case retryable(code: Int, retryAfterSeconds: Double?)
    case serverRecordChanged(recordID: SyncEntityID?, serverRecord: SyncRecord?)
    case quotaExceeded
    case invalidArguments
    case notAuthenticated
    case changeTokenExpired
    case zoneNotFound
    case invalidRecord(recordID: SyncEntityID?)
    case incomingBackpressure
    case statePersistence
    case limitExceeded
    case fatal(code: Int)

    static func map(_ error: CKError, codec: CloudRecordCodec) -> Self {
        switch error.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable,
             .requestRateLimited, .zoneBusy, .operationCancelled, .batchRequestFailed,
             .accountTemporarilyUnavailable:
            .retryable(code: error.code.rawValue, retryAfterSeconds: error.retryAfterSeconds)
        case .serverRecordChanged:
            .serverRecordChanged(
                recordID: error.serverRecord.flatMap { CKSyncEngineTransport.entityID(for: $0.recordID) },
                serverRecord: error.serverRecord.flatMap { try? codec.decode($0) }
            )
        case .quotaExceeded:
            .quotaExceeded
        case .limitExceeded:
            .limitExceeded
        case .invalidArguments:
            .invalidArguments
        case .notAuthenticated:
            .notAuthenticated
        case .changeTokenExpired:
            .changeTokenExpired
        case .zoneNotFound:
            .zoneNotFound
        default:
            .fatal(code: error.code.rawValue)
        }
    }
}

enum CloudSyncTransportError: Error, Equatable {
    case notStarted
    case terminated
    case missingAccountIdentity
    case unknownFetchedBatch
    case unknownFailedMutation
    case invalidReplacement
    case staleOperation
    case accountResetIncomplete
}

protocol CKSyncEngineDriving: Sendable {
    var cloudKitEngineIdentifier: ObjectIdentifier? { get }
    func pendingChanges() async -> [CKSyncEngine.PendingRecordZoneChange]
    func pendingDatabaseChanges() async -> [CKSyncEngine.PendingDatabaseChange]
    func add(_ changes: [CKSyncEngine.PendingRecordZoneChange]) async
    func remove(_ changes: [CKSyncEngine.PendingRecordZoneChange]) async
    func addDatabaseChanges(_ changes: [CKSyncEngine.PendingDatabaseChange]) async
    func removeDatabaseChanges(_ changes: [CKSyncEngine.PendingDatabaseChange]) async
    func fetchChanges(_ options: CKSyncEngine.FetchChangesOptions) async throws
    func sendChanges(_ options: CKSyncEngine.SendChangesOptions) async throws
    func cancelOperations() async
}

final class LiveCKSyncEngineDriver: CKSyncEngineDriving, @unchecked Sendable {
    let engine: CKSyncEngine
    var cloudKitEngineIdentifier: ObjectIdentifier? { ObjectIdentifier(engine) }

    init(engine: CKSyncEngine) {
        self.engine = engine
    }

    func pendingChanges() async -> [CKSyncEngine.PendingRecordZoneChange] {
        engine.state.pendingRecordZoneChanges
    }

    func add(_ changes: [CKSyncEngine.PendingRecordZoneChange]) async {
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    func pendingDatabaseChanges() async -> [CKSyncEngine.PendingDatabaseChange] {
        engine.state.pendingDatabaseChanges
    }

    func addDatabaseChanges(_ changes: [CKSyncEngine.PendingDatabaseChange]) async {
        engine.state.add(pendingDatabaseChanges: changes)
    }

    func removeDatabaseChanges(_ changes: [CKSyncEngine.PendingDatabaseChange]) async {
        engine.state.remove(pendingDatabaseChanges: changes)
    }

    func remove(_ changes: [CKSyncEngine.PendingRecordZoneChange]) async {
        engine.state.remove(pendingRecordZoneChanges: changes)
    }

    func fetchChanges(_ options: CKSyncEngine.FetchChangesOptions) async throws {
        try await engine.fetchChanges(options)
    }

    func sendChanges(_ options: CKSyncEngine.SendChangesOptions) async throws {
        try await engine.sendChanges(options)
    }

    func cancelOperations() async {
        await engine.cancelOperations()
    }
}

actor CKSyncEngineTransport: CloudSyncTransport, CKSyncEngineDelegate {
    typealias EngineFactory = @Sendable (
        CKSyncEngine.State.Serialization?,
        any CKSyncEngineDelegate
    ) -> any CKSyncEngineDriving
    typealias RecordMaterializer = @Sendable (SyncMutation, CKRecord?) async throws -> CKRecord

    nonisolated let events: AsyncStream<CloudSyncEvent>
    private nonisolated let eventContinuation: AsyncStream<CloudSyncEvent>.Continuation
    private nonisolated let terminalLatch: CloudSyncTerminalLatch
    private let zoneID: CKRecordZone.ID
    private let stateStore: FileCloudSyncEngineStateStore
    private let incomingBatchStore: FileCloudIncomingBatchStore
    private let systemFieldsStore: FileCloudRecordSystemFieldsStore?
    private let assetStaging: CloudAssetStagingService?
    private let recordMaterializer: RecordMaterializer
    private let engineFactory: EngineFactory
    private let codec = CloudRecordCodec()
    private var engine: (any CKSyncEngineDriving)?
    private var cloudKitEngineIdentifier: ObjectIdentifier?
    private var generation: UInt64 = 0
    private var incomingBatchGeneration: UInt64 = 0
    private var accountEpoch: CloudSyncAccountEpoch
    private var activeFetchedBatchIDs: [UUID] = []
    private var sourceObservedFetchedBatchIDs: Set<UUID> = []
    private var sourcePendingFetchedBatchIDs: Set<UUID> = []
    private var unacknowledgedFetchedBatchIDs: [UUID] = []
    private var deferredStateUpdates: [DeferredStateUpdate] = []
    private var sourceObservationCycleDepth = 0
    private var sourceObservationCycleFailed = false
    private var sourceObservationCycleAllowsSpillover = false
    private var sourceObservationSequence: UInt64 = 0
    private var sourceObservationEntityIDs: Set<SyncEntityID> = []
    private var sourceObservationStoreBaseline: CloudIncomingBatchSourceObservationSnapshot?
    private var sourceObservedBatchBaseline: Set<UUID> = []
    private var sourcePendingBatchBaseline: Set<UUID> = []
    private var deferredStateBaseline: [DeferredStateUpdate] = []
    private var inboundDurabilityBlocked = false
    private var mutationReplayFinished = false
    private var configuredZoneIsReady = false
    private var zoneEpoch: UInt64 = 0
    private var zoneResetInProgress = false
    private var zoneResetDurabilityBlocked = false
    private var sendAttempts: [SyncEntityID: SendAttempt] = [:]
    private var failedMutationIDs: Set<UUID> = []
    private var failedContexts: [SyncEntityID: FailedSendContext] = [:]
    private var successContexts: [UUID: SendAttempt] = [:]
    private var deleteCallbackBarriers: Set<SyncEntityID> = []
    private var currentAccountIdentifier: String?
    private var accountResetBlocksRestart = false
    private var detachedEngineCancellation: Task<Void, Never>?
    private let requiresInitialFetchReceipt: Bool
    private let syncContainerIdentifier: String?
    private var activeReceiptFetch: UUID?
    private var receiptFetchBatches: [UUID: Set<UUID>] = [:]
    private var incompleteReceiptBatches: Set<UUID> = []
    private var completedReceiptFetches: Set<UUID> = []
    private var committedReceiptBatches: Set<UUID> = []
    private var sendReadinessReceipt: CloudInitialFetchReceipt?
    /// The first entry is the mutation currently represented in CKSyncEngine.
    /// Later entries stay here until their predecessor is acknowledged.
    private var queues: [SyncEntityID: [SyncVersionedMutation]] = [:]
    private var acknowledgedUploadsAwaitingCleanup: Set<UUID> = []
    private var batchLimit = 250
    private var splitRetryPending = false

    init(
        container: CKContainer,
        zoneID: CKRecordZone.ID,
        stateStore: FileCloudSyncEngineStateStore,
        systemFieldsStore: FileCloudRecordSystemFieldsStore,
        accountIdentifier: String,
        assetStaging: CloudAssetStagingService? = nil
    ) {
        let database = container.privateCloudDatabase
        self.init(
            zoneID: zoneID,
            stateStore: stateStore,
            systemFieldsStore: systemFieldsStore,
            initialAccountIdentifier: accountIdentifier,
            assetStaging: assetStaging,
            containerIdentifier: container.containerIdentifier
        ) { serialization, delegate in
            var configuration = CKSyncEngine.Configuration(
                database: database,
                stateSerialization: serialization,
                delegate: delegate
            )
            configuration.automaticallySync = true
            return LiveCKSyncEngineDriver(engine: CKSyncEngine(configuration))
        }
    }

    init(
        containerIdentifier: String,
        zoneID: CKRecordZone.ID,
        stateStore: FileCloudSyncEngineStateStore,
        systemFieldsStore: FileCloudRecordSystemFieldsStore,
        accountIdentifier: String,
        assetStaging: CloudAssetStagingService? = nil
    ) {
        self.init(
            container: CKContainer(identifier: containerIdentifier),
            zoneID: zoneID,
            stateStore: stateStore,
            systemFieldsStore: systemFieldsStore,
            accountIdentifier: accountIdentifier,
            assetStaging: assetStaging
        )
    }

    init(
        zoneID: CKRecordZone.ID,
        stateStore: FileCloudSyncEngineStateStore,
        incomingBatchStore: FileCloudIncomingBatchStore? = nil,
        systemFieldsStore: FileCloudRecordSystemFieldsStore? = nil,
        initialAccountIdentifier: String? = nil,
        assetStaging: CloudAssetStagingService? = nil,
        recordMaterializer: RecordMaterializer? = nil,
        requiresInitialFetchReceipt: Bool = false,
        containerIdentifier: String? = nil,
        engineFactory: @escaping EngineFactory
    ) {
        let pair = AsyncStream<CloudSyncEvent>.makeStream()
        let terminalLatch = CloudSyncTerminalLatch()
        events = pair.stream
        eventContinuation = pair.continuation
        self.terminalLatch = terminalLatch
        self.zoneID = zoneID
        self.requiresInitialFetchReceipt = requiresInitialFetchReceipt
        self.syncContainerIdentifier = containerIdentifier
        self.stateStore = stateStore
        self.incomingBatchStore = incomingBatchStore ?? FileCloudIncomingBatchStore(
            url: stateStore.relatedURL(pathExtension: "incoming-batches")
        )
        self.systemFieldsStore = systemFieldsStore
        self.assetStaging = assetStaging
        currentAccountIdentifier = initialAccountIdentifier
        accountEpoch = CloudSyncAccountEpoch(
            accountIdentifier: initialAccountIdentifier ?? "",
            zoneID: zoneID,
            generation: 0, containerIdentifier: containerIdentifier
        )
        self.recordMaterializer = recordMaterializer ?? { mutation, baseRecord in
            guard case let .save(save) = mutation else {
                throw CloudSyncTransportError.invalidReplacement
            }
            let freshRecord = try CloudRecordCodec().encode(
                save.recordVersion.record,
                zoneID: zoneID
            )
            guard let baseRecord else { return freshRecord }
            guard baseRecord.recordID == freshRecord.recordID,
                  baseRecord.recordType == freshRecord.recordType else {
                throw CloudSyncTransportError.invalidReplacement
            }
            for key in baseRecord.allKeys() { baseRecord[key] = nil }
            for key in freshRecord.allKeys() { baseRecord[key] = freshRecord[key] }
            return baseRecord
        }
        self.engineFactory = engineFactory
        eventContinuation.onTermination = { [weak self, terminalLatch] _ in
            terminalLatch.terminate()
            Task { await self?.terminateForEndedEventStream() }
        }
    }

    func start() async throws {
        try requireNotTerminated()
        guard !accountResetBlocksRestart else { throw CloudSyncTransportError.accountResetIncomplete }
        if let assetStaging, assetStaging.accountIdentifier != currentAccountIdentifier {
            throw CloudSyncTransportError.missingAccountIdentity
        }
        if systemFieldsStore != nil {
            guard let currentAccountIdentifier,
                  !currentAccountIdentifier.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty else {
                throw CloudSyncTransportError.missingAccountIdentity
            }
        }
        do {
            try prepareAccountScope()
        } catch {
            accountResetBlocksRestart = true
            throw CloudSyncTransportError.accountResetIncomplete
        }
        guard engine == nil else { return }
        let serialization = try stateStore.load()
        let durableState = try serialization.map { try Self.encodedState($0) }
        let incoming = try incomingBatchStore.beginGeneration(
            accountIdentifier: incomingAccountIdentifier,
            zoneID: zoneID,
            persistedEngineState: durableState
        )
        let acknowledgements = try acknowledgementSnapshot()
        let provenIDs = Set(acknowledgements.acknowledged.map(\.batchID))
        // Replay has no CKAsset handles: its immutable versions must still
        // resolve to verified durable bytes before they can be acknowledged.
        for envelope in incoming.batches where !provenIDs.contains(envelope.batchID) {
            for record in envelope.records where record.deletedAt.value == nil {
                if let version = record.payload.attachment {
                    _ = try requireAssetStaging().installedDownload(version: version)
                }
            }
        }
        incomingBatchGeneration = incoming.generation
        accountEpoch.invalidate()
        accountEpoch = CloudSyncAccountEpoch(
            accountIdentifier: incomingAccountIdentifier,
            zoneID: zoneID,
            generation: incoming.generation, containerIdentifier: syncContainerIdentifier
        )
        activeFetchedBatchIDs = incoming.batches.map(\.batchID)
        sourceObservedFetchedBatchIDs.removeAll(keepingCapacity: false)
        sourcePendingFetchedBatchIDs.removeAll(keepingCapacity: false)
        unacknowledgedFetchedBatchIDs = activeFetchedBatchIDs.filter { !provenIDs.contains($0) }
        committedReceiptBatches.formUnion(provenIDs)
        sourceObservationCycleDepth = 0
        sourceObservationCycleFailed = false
        sourceObservationCycleAllowsSpillover = false
        sourceObservationSequence = 0
        sourceObservationEntityIDs.removeAll(keepingCapacity: false)
        sourceObservationStoreBaseline = nil
        sourceObservedBatchBaseline.removeAll(keepingCapacity: false)
        sourcePendingBatchBaseline.removeAll(keepingCapacity: false)
        deferredStateBaseline.removeAll(keepingCapacity: false)
        let created = engineFactory(serialization, self)
        generation &+= 1
        let operationGeneration = generation
        engine = created
        cloudKitEngineIdentifier = created.cloudKitEngineIdentifier
        let pendingDatabaseChanges = await created.pendingDatabaseChanges()
        try requireCurrentGeneration(operationGeneration)
        let zoneSave = CKSyncEngine.PendingDatabaseChange.saveZone(CKRecordZone(zoneID: zoneID))
        if !pendingDatabaseChanges.contains(zoneSave) {
            await created.addDatabaseChanges([zoneSave])
            try requireCurrentGeneration(operationGeneration)
        }
        for identity in acknowledgements.requiringRetirement {
            eventContinuation.yield(.acknowledgedFetched(identity, accountEpoch: accountEpoch))
        }
        for batch in incoming.batches where !provenIDs.contains(batch.batchID) {
            eventContinuation.yield(.fetched(
                batchID: batch.batchID,
                accountEpoch: accountEpoch,
                records: batch.records,
                deleted: batch.deletedRecordIDs
            ))
        }
    }

    func schedule(_ mutations: [SyncVersionedMutation]) async throws {
        try requireNotTerminated()
        guard let engine else { throw CloudSyncTransportError.notStarted }
        let operationGeneration = generation
        var enginePending = await engine.pendingChanges()
        try requireCurrentGeneration(operationGeneration)
        for versioned in mutations {
            let validated = try SyncVersionedMutation(mutation: versioned.mutation, journalRevision: versioned.token.journalRevision)
            guard validated == versioned else { throw CloudSyncTransportError.invalidReplacement }
            if case let .save(save) = validated.mutation { _ = try codec.encode(save.recordVersion.record, zoneID: zoneID) }
            // Pending journal replay may occur before the exact success event is consumed.
            if successContexts.values.contains(where: { $0.attempted.token == validated.token }) { continue }
            successContexts = successContexts.filter { $0.value.attempted.identity != validated.identity || $0.value.attempted.token == validated.token }
            acknowledgedUploadsAwaitingCleanup = acknowledgedUploadsAwaitingCleanup.filter { successContexts[$0] != nil }
            var queue = queues[validated.recordID, default: []]
            if let index = queue.firstIndex(where: { $0.identity == validated.identity }) {
                guard queue[index] != validated else { continue }
                guard validated.token.journalRevision > queue[index].token.journalRevision else {
                    throw CloudSyncTransportError.invalidReplacement
                }
                queue[index] = validated
                sendAttempts.removeValue(forKey: validated.recordID)
            } else { queue.append(validated) }
            queues[validated.recordID] = queue
            guard queue.first == validated else { continue }
            try await representCurrentMutation(validated.mutation, engine: engine,
                enginePending: &enginePending, generation: operationGeneration)
        }
    }

    func fetchNow(completionID: UUID?) async throws {
        try requireNotTerminated()
        guard let engine else { throw CloudSyncTransportError.notStarted }
        let operationGeneration = generation
        let observedSequence = sourceObservationSequence
        if requiresInitialFetchReceipt {
            guard let completionID, activeReceiptFetch == nil else { throw CloudSyncTransportError.staleOperation }
            receiptFetchBatches.removeAll(); completedReceiptFetches.removeAll(); committedReceiptBatches.removeAll()
            incompleteReceiptBatches.removeAll()
            activeReceiptFetch = completionID
            receiptFetchBatches[completionID] = []
        }
        defer { if requiresInitialFetchReceipt { activeReceiptFetch = nil } }
        do {
            try beginSourceObservationCycle()
        } catch {
            inboundDurabilityBlocked = true
            eventContinuation.yield(.failed(.statePersistence))
            throw CloudSyncFailure.statePersistence
        }
        do {
            try await engine.fetchChanges(.init(scope: .zoneIDs([zoneID])))
            try Task.checkCancellation()
            try requireCurrentGeneration(operationGeneration)
            if requiresInitialFetchReceipt, sourceObservationSequence == observedSequence {
                // This is the successful current fetch's empty result. Give it
                // the same durable incoming/merge/ACK chain as a populated batch.
                receiveFetchedChanges(records: [], deletedRecordIDs: [])
            }
            completeSourceObservationCycle(succeeded: true)
            if let completionID {
                if requiresInitialFetchReceipt { completedReceiptFetches.insert(completionID) }
                eventContinuation.yield(.fetchRequestCompleted(completionID))
            }
        } catch let error as CKError {
            completeSourceObservationCycle(succeeded: false)
            guard generation == operationGeneration else {
                throw CloudSyncTransportError.staleOperation
            }
            let failure = CloudSyncFailure.map(error, codec: codec)
            eventContinuation.yield(.failed(failure))
            throw failure
        } catch {
            completeSourceObservationCycle(succeeded: false)
            throw error
        }
    }

    func finishMutationReplay(completionID: UUID?) async throws {
        try requireNotTerminated()
        guard engine != nil else { throw CloudSyncTransportError.notStarted }
        if requiresInitialFetchReceipt {
            guard let sendReadinessReceipt else { throw CloudSyncTransportError.unknownFetchedBatch }
            try sendReadinessReceipt.epoch.requireCurrent()
        }
        mutationReplayFinished = true
        try await sendNow(completionID: completionID)
    }

    func configuredFetchOptions(
        from options: CKSyncEngine.FetchChangesOptions
    ) -> CKSyncEngine.FetchChangesOptions {
        var scoped = CKSyncEngine.FetchChangesOptions(
            scope: .zoneIDs([zoneID]),
            operationGroup: options.operationGroup
        )
        scoped.prioritizedZoneIDs = options.prioritizedZoneIDs.filter { $0 == zoneID }
        return scoped
    }

    func acknowledgeFetchedBatch(_ batchID: UUID) async throws {
        try requireNotTerminated()
        guard activeFetchedBatchIDs.contains(batchID) else {
            if try acknowledgementIdentities().contains(where: { $0.batchID == batchID }) {
                try await verifyFetchedBatchAcknowledgement(batchID)
                return
            }
            throw CloudSyncTransportError.unknownFetchedBatch
        }
        try incomingBatchStore.acknowledge(
            batchID,
            accountIdentifier: incomingAccountIdentifier,
            zoneID: zoneID,
            account: try syncContainerIdentifier.map { try SyncAccountIdentity(containerIdentifier: $0, userRecordName: incomingAccountIdentifier) }
        )
        if requiresInitialFetchReceipt {
            committedReceiptBatches.insert(batchID)
        }
        guard unacknowledgedFetchedBatchIDs.contains(batchID) else { return }
        if sourceObservationCycleDepth > 0 {
            unacknowledgedFetchedBatchIDs.removeAll { $0 == batchID }
            return
        }
        let remaining = Set(unacknowledgedFetchedBatchIDs.filter { $0 != batchID })
        do {
            if let data = try persistEligibleDeferredState(
                remainingUnacknowledgedBatchIDs: remaining
            ) {
                eventContinuation.yield(.stateUpdated(data))
            }
        } catch {
            eventContinuation.yield(.failed(.statePersistence))
            throw error
        }
        unacknowledgedFetchedBatchIDs.removeAll { $0 == batchID }
    }

    private func acknowledgementIdentities() throws -> [SyncRemoteBatchIdentity] {
        try acknowledgementSnapshot().acknowledged
    }

    private func acknowledgementSnapshot() throws -> CloudIncomingBatchAcknowledgementSnapshot {
        guard let syncContainerIdentifier else { return .init(acknowledged: [], requiringRetirement: []) }
        let account = try SyncAccountIdentity(containerIdentifier: syncContainerIdentifier, userRecordName: incomingAccountIdentifier)
        return try incomingBatchStore.acknowledgementSnapshot(accountIdentifier: incomingAccountIdentifier, zoneID: zoneID, account: account)
    }

    func verifyFetchedBatchAcknowledgement(_ batchID: UUID) async throws {
        try requireNotTerminated()
        let account = try accountEpoch.verifiedAccountIdentity()
        guard let identity = try acknowledgementIdentities().first(where: { $0.batchID == batchID }) else {
            throw CloudSyncTransportError.unknownFetchedBatch
        }
        try accountEpoch.withCurrent {
            try incomingBatchStore.verifyAcknowledgement(identity, accountIdentifier: incomingAccountIdentifier, zoneID: zoneID, account: account)
        }
    }

    func finishFetchedBatchAcknowledgement(_ identity: SyncRemoteBatchIdentity) async throws {
        try requireNotTerminated()
        let account = try accountEpoch.verifiedAccountIdentity()
        try accountEpoch.withCurrent {
            try incomingBatchStore.finishAcknowledgement(identity, accountIdentifier: incomingAccountIdentifier, zoneID: zoneID, account: account)
        }
    }

    func resolveFailedMutation(_ resolution: SyncConflictResolution, accountEpoch expectedEpoch: CloudSyncAccountEpoch,
        expectedQueue: [SyncVersionedMutation]) async throws -> CloudConflictHandoffResult {
        try requireNotTerminated()
        try expectedEpoch.requireCurrent()
        guard expectedEpoch === accountEpoch, let engine else { throw CloudSyncAccountEpochError.stale }
        let id = resolution.input.failedMutation.recordID
        guard let failure = failedContexts[id],
              failure.attempt.attemptID == resolution.input.failedAttemptID,
              failure.attempt.attempted.mutation == resolution.input.failedMutation,
              failure.attempt.attempted.token == resolution.input.failedVersion,
              failure.serverRecord == resolution.input.serverRecord,
              failure.serverSHA256 == (try serverDigest(resolution.input.serverRecord)),
              try expectedEpoch.verifiedAccountIdentity().accountIDHash == resolution.input.accountIDHash else { return .stale }
        let previous = zip(resolution.input.expectedRecordQueue, resolution.input.expectedVersions)
        let previousQueue = try previous.map { mutation, token in
            let pair = try SyncVersionedMutation(mutation: mutation, journalRevision: token.journalRevision)
            guard pair.token == token else { throw CloudSyncTransportError.invalidReplacement }
            return pair
        }
        let replacements = [resolution.replacement] + resolution.followingReplacements
        guard expectedQueue.map(\.mutation) == replacements, expectedQueue.map(\.token) == resolution.versions,
              queues[id] == previousQueue else { return .stale }
        try verifyServerBase(failure)
        let operationGeneration = generation
        var pending = await engine.pendingChanges()
        try requireCurrentGeneration(operationGeneration)
        try expectedEpoch.requireCurrent()
        guard expectedEpoch === accountEpoch, failedContexts[id] == failure, queues[id] == previousQueue else { return .stale }
        try verifyServerBase(failure)
        queues[id] = expectedQueue
        failedContexts.removeValue(forKey: id)
        failedMutationIDs.remove(resolution.input.failedMutation.mutationID)
        try await representCurrentMutation(expectedQueue[0].mutation, engine: engine,
            enginePending: &pending, generation: operationGeneration)
        try expectedEpoch.requireCurrent()
        guard queues[id] == expectedQueue else { return .stale }
        // The handoff is installed before the ordinary send kick. Its callbacks
        // may consume the queue, but an account/generation reset cannot accept it.
        await kickConfiguredZoneSend()
        try expectedEpoch.requireCurrent()
        try requireCurrentGeneration(operationGeneration)
        return .accepted
    }

    private func serverDigest(_ record: SyncRecord) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(record)))
    }

    private func verifyServerBase(_ failure: FailedSendContext) throws {
        guard let systemFieldsStore, let expected = failure.systemFields,
              let account = currentAccountIdentifier,
              try systemFieldsStore.verificationEvidence(recordID: Self.cloudRecordID(for: failure.attempt.attempted.recordID, zoneID: zoneID),
                accountIdentifier: account) == expected else { throw CloudSyncTransportError.invalidReplacement }
    }

    func sendNow(completionID: UUID?) async throws {
        try requireNotTerminated()
        try await sendConfiguredZoneChanges(completionID: completionID)
    }

    private func sendConfiguredZoneChanges(completionID: UUID? = nil) async throws {
        guard let engine else { throw CloudSyncTransportError.notStarted }
        if requiresInitialFetchReceipt {
            guard mutationReplayFinished, let sendReadinessReceipt else { throw CloudSyncTransportError.unknownFetchedBatch }
            try sendReadinessReceipt.epoch.requireCurrent()
        }
        for attemptID in acknowledgedUploadsAwaitingCleanup {
            try cleanupAcknowledgedUpload(attemptID)
        }
        let operationGeneration = generation
        // 250 -> 125 -> ... -> 1. Bound request-level retries even when a
        // driver rejects before asking us to materialize a batch.
        for _ in 0..<9 {
            do {
                try await engine.sendChanges(.init(scope: .zoneIDs([zoneID])))
                try requireCurrentGeneration(operationGeneration)
                if let completionID {
                    eventContinuation.yield(.sendRequestCompleted(completionID))
                }
                return
            } catch let error as CKError {
                guard generation == operationGeneration else {
                    throw CloudSyncTransportError.staleOperation
                }
                let failure = CloudSyncFailure.map(error, codec: codec)
                if failure == .limitExceeded {
                    let rejected = sendAttempts
                    let largest = rejected.values.map(\.batchSize).max() ?? batchLimit
                    if largest > 1 {
                        batchLimit = min(batchLimit, max(1, largest / 2))
                        sendAttempts.removeAll()
                        continue
                    }
                    for (entityID, attempt) in rejected {
                        failAttemptPermanently(recordID: Self.cloudRecordID(for: entityID, zoneID: zoneID),
                            mutationID: attempt.mutationID, attemptID: attempt.attemptID, failure: failure)
                    }
                }
                eventContinuation.yield(.failed(failure))
                throw failure
            }
        }
        eventContinuation.yield(.failed(.limitExceeded))
        throw CloudSyncFailure.limitExceeded
    }

    func receiveStateUpdate(_ serialization: CKSyncEngine.State.Serialization) {
        guard !accountResetBlocksRestart else { return }
        guard !terminalLatch.isTerminated else { return }
        guard !inboundDurabilityBlocked else { return }
        let coveredBatchIDs = sourceObservedFetchedBatchIDs
        let requiredBatchIDs = Set(
            unacknowledgedFetchedBatchIDs.filter { coveredBatchIDs.contains($0) }
        )
        let incompleteSourceBatchIDs = sourcePendingFetchedBatchIDs
        let awaitsSuccessfulFetchBoundary = sourceObservationCycleDepth > 0
        guard !requiredBatchIDs.isEmpty || !incompleteSourceBatchIDs.isEmpty
                || awaitsSuccessfulFetchBoundary else {
            do {
                let data = try persistStateUpdate(
                    serialization,
                    coveredBatchIDs: coveredBatchIDs
                )
                deferredStateUpdates.removeAll(keepingCapacity: true)
                eventContinuation.yield(.stateUpdated(data))
            } catch {
                eventContinuation.yield(.failed(.statePersistence))
            }
            return
        }
        deferredStateUpdates.removeAll {
            !$0.incompleteSourceBatchIDs.isEmpty || $0.awaitsSuccessfulFetchBoundary
        }
        let update = DeferredStateUpdate(
            serialization: serialization,
            requiredBatchIDs: requiredBatchIDs,
            coveredBatchIDs: coveredBatchIDs,
            incompleteSourceBatchIDs: incompleteSourceBatchIDs,
            sourceObservationSequence: sourceObservationSequence,
            awaitsSuccessfulFetchBoundary: awaitsSuccessfulFetchBoundary
        )
        if let last = deferredStateUpdates.last,
           last.requiredBatchIDs == update.requiredBatchIDs,
           last.coveredBatchIDs == update.coveredBatchIDs,
           last.incompleteSourceBatchIDs == update.incompleteSourceBatchIDs {
            deferredStateUpdates[deferredStateUpdates.count - 1] = update
        } else {
            deferredStateUpdates.append(update)
        }
    }

    #if DEBUG
    func pendingStateUpdateCountForTesting() -> Int {
        deferredStateUpdates.count
    }
    #endif

    private func persistEligibleDeferredState(
        remainingUnacknowledgedBatchIDs: Set<UUID>
    ) throws -> Data? {
        let persistableCount = deferredStateUpdates.prefix {
            !$0.awaitsSuccessfulFetchBoundary
                && $0.incompleteSourceBatchIDs.isEmpty
                && $0.requiredBatchIDs.isDisjoint(with: remainingUnacknowledgedBatchIDs)
        }.count
        guard persistableCount > 0 else { return nil }
        let update = deferredStateUpdates[persistableCount - 1]
        let data = try persistStateUpdate(
            update.serialization,
            coveredBatchIDs: update.coveredBatchIDs
        )
        let retiredBatchIDs = update.coveredBatchIDs
        deferredStateUpdates.removeFirst(persistableCount)
        if !retiredBatchIDs.isEmpty {
            for index in deferredStateUpdates.indices {
                deferredStateUpdates[index].requiredBatchIDs.subtract(retiredBatchIDs)
                deferredStateUpdates[index].coveredBatchIDs.subtract(retiredBatchIDs)
                deferredStateUpdates[index].incompleteSourceBatchIDs.subtract(retiredBatchIDs)
            }
        }
        return data
    }

    private func persistStateUpdate(
        _ serialization: CKSyncEngine.State.Serialization,
        coveredBatchIDs: Set<UUID>
    ) throws -> Data {
        guard !coveredBatchIDs.isEmpty else {
            return try stateStore.save(serialization)
        }
        let encoded = try Self.encodedState(serialization)
        try incomingBatchStore.stageStateCommit(
            engineState: encoded,
            coveredBatchIDs: coveredBatchIDs
        )
        let data = try stateStore.save(serialization)
        try incomingBatchStore.completeStateCommit(engineState: encoded)
        activeFetchedBatchIDs.removeAll { coveredBatchIDs.contains($0) }
        sourceObservedFetchedBatchIDs.subtract(coveredBatchIDs)
        sourcePendingFetchedBatchIDs.subtract(coveredBatchIDs)
        unacknowledgedFetchedBatchIDs.removeAll { coveredBatchIDs.contains($0) }
        return data
    }

    func receiveAccountChange(previous: String?, current: String?) async {
        let cancellation = invalidateForAccountTransition()
        eventContinuation.yield(.accountChanged(previous: previous, current: current))
        await cancellation?.value
    }

    /// Detaches before cancellation can suspend. Durable files remain untouched
    /// until the account owner's authenticated recovery transaction cleans them.
    func invalidateForAccountTransition() -> Task<Void, Never>? {
        guard !accountResetBlocksRestart else { return detachedEngineCancellation }
        accountResetBlocksRestart = true
        activeReceiptFetch = nil
        receiptFetchBatches.removeAll(); completedReceiptFetches.removeAll(); committedReceiptBatches.removeAll()
        incompleteReceiptBatches.removeAll()
        sendReadinessReceipt = nil
        accountEpoch.invalidate()
        successContexts.removeAll()
        acknowledgedUploadsAwaitingCleanup.removeAll()
        splitRetryPending = false
        batchLimit = 250
        generation &+= 1
        let detachedEngine = engine
        engine = nil
        cloudKitEngineIdentifier = nil
        queues.removeAll(keepingCapacity: false)
        activeFetchedBatchIDs.removeAll(keepingCapacity: false)
        sourceObservedFetchedBatchIDs.removeAll(keepingCapacity: false)
        sourcePendingFetchedBatchIDs.removeAll(keepingCapacity: false)
        unacknowledgedFetchedBatchIDs.removeAll(keepingCapacity: false)
        deferredStateUpdates.removeAll(keepingCapacity: false)
        sourceObservationCycleDepth = 0
        sourceObservationCycleFailed = false
        sourceObservationCycleAllowsSpillover = false
        sourceObservationSequence = 0
        sourceObservationEntityIDs.removeAll(keepingCapacity: false)
        sourceObservationStoreBaseline = nil
        sourceObservedBatchBaseline.removeAll(keepingCapacity: false)
        sourcePendingBatchBaseline.removeAll(keepingCapacity: false)
        deferredStateBaseline.removeAll(keepingCapacity: false)
        inboundDurabilityBlocked = false
        mutationReplayFinished = false
        configuredZoneIsReady = false
        zoneEpoch &+= 1
        zoneResetInProgress = false
        zoneResetDurabilityBlocked = false
        sendAttempts.removeAll(keepingCapacity: false)
        failedMutationIDs.removeAll(keepingCapacity: false)
        failedContexts.removeAll()
        successContexts.removeAll()
        acknowledgedUploadsAwaitingCleanup.removeAll()
        deleteCallbackBarriers.removeAll(keepingCapacity: false)
        if let driver = detachedEngine {
            detachedEngineCancellation = Task { await driver.cancelOperations() }
        }
        return detachedEngineCancellation
    }

    func committedFetchReceipt(requestID: UUID) async throws -> CloudInitialFetchReceipt {
        try accountEpoch.requireCurrent()
        guard requiresInitialFetchReceipt, completedReceiptFetches.contains(requestID),
              let batches = receiptFetchBatches[requestID], !batches.isEmpty,
              batches.isSubset(of: committedReceiptBatches), incompleteReceiptBatches.isEmpty,
              !inboundDurabilityBlocked else {
            throw CloudSyncTransportError.unknownFetchedBatch
        }
        let receipt = CloudInitialFetchReceipt(requestID: requestID, batchIDs: batches, epoch: accountEpoch)
        sendReadinessReceipt = receipt
        return receipt
    }

    func validateRecoveryBinding(account: CloudAccountBinding, paths: SyncAccountStorage.Paths) throws {
        guard currentAccountIdentifier == account.userRecordName,
              paths.accountRoot.lastPathComponent == account.identity.accountIDHash else {
            throw CloudSyncTransportError.accountResetIncomplete
        }
        let expected = paths.engineState.appendingPathComponent("engine.json")
        guard stateStore.recoveryURLs == [expected, expected.appendingPathExtension("account-reset"), expected.appendingPathExtension("account-owner")],
              incomingBatchStore.recoveryURL == expected.appendingPathExtension("incoming-batches"),
              systemFieldsStore?.recoveryURL == paths.engineState.appendingPathComponent("system-fields.json") else {
            throw CloudSyncTransportError.accountResetIncomplete
        }
        if let assetStaging {
            // The legacy asset hash is nested explicitly under this account's
            // staging root. It is never treated as the identity namespace.
            let token = SHA256.hash(data: Data(account.userRecordName.utf8)).map { String(format: "%02x", $0) }.joined()
            guard assetStaging.accountIdentifier == account.userRecordName,
                  assetStaging.accountRootURL.standardizedFileURL.path == paths.staging.appendingPathComponent("cloud-assets/Accounts/" + token).standardizedFileURL.path else {
                throw CloudSyncTransportError.accountResetIncomplete
            }
        }
    }

    func retireAfterSealedCleanup(transaction: SyncAccountRecoveryTransaction, account: CloudAccountBinding,
                                  paths: SyncAccountStorage.Paths, now: Date) throws {
        guard accountResetBlocksRestart, engine == nil else { throw CloudSyncTransportError.accountResetIncomplete }
        try validateRecoveryBinding(account: account, paths: paths)
        guard let current = try transaction.lifecycleSnapshot(now: now), current.phase == .cleanupComplete,
              current.account == account.identity, current.accountRoot == paths.accountRoot else {
            throw CloudSyncTransportError.accountResetIncomplete
        }
        // The transaction has already removed and synchronized every captured
        // engine/incoming/system-field/asset file. Do not recreate reset files.
        terminalLatch.terminate()
        eventContinuation.finish()
    }

    private func prepareAccountScope() throws {
        guard !accountResetBlocksRestart, try !stateStore.hasPendingAccountReset() else {
            throw CloudSyncTransportError.accountResetIncomplete
        }
        let accountIdentifier = incomingAccountIdentifier
        let durableOwner = try stateStore.loadAccountOwner()
        let storedState = try stateStore.load()
        let hasUnboundState = durableOwner == nil && storedState != nil
        let hasForeignIncomingWork = try incomingBatchStore.containsForeignAccount(
            accountIdentifier
        )
        if accountResetBlocksRestart
            || hasUnboundState
            || durableOwner.map({ $0 != accountIdentifier }) == true
            || hasForeignIncomingWork {
            throw CloudSyncTransportError.accountResetIncomplete
        }
        try stateStore.bindAccountOwner(accountIdentifier)
        accountResetBlocksRestart = false
    }

    private func beginSourceObservationCycle() throws {
        if sourceObservationCycleDepth == 0 {
            let snapshot = try incomingBatchStore.sourceObservationSnapshot(
                accountIdentifier: incomingAccountIdentifier,
                zoneID: zoneID,
                generation: incomingBatchGeneration
            )
            sourceObservationStoreBaseline = snapshot
            sourceObservationCycleAllowsSpillover = snapshot.batches.values.contains {
                $0.awaitingSourceRedelivery
            }
            sourceObservedBatchBaseline = sourceObservedFetchedBatchIDs
            sourcePendingBatchBaseline = sourcePendingFetchedBatchIDs
            deferredStateBaseline = deferredStateUpdates
            sourceObservationCycleFailed = false
            sourceObservationEntityIDs.removeAll(keepingCapacity: true)
        }
        sourceObservationCycleDepth += 1
    }

    private func completeSourceObservationCycle(succeeded: Bool) {
        guard sourceObservationCycleDepth > 0 else { return }
        if !succeeded {
            sourceObservationCycleFailed = true
        }
        sourceObservationCycleDepth -= 1
        guard sourceObservationCycleDepth == 0 else { return }
        defer {
            sourceObservationCycleFailed = false
            sourceObservationCycleAllowsSpillover = false
            sourceObservationEntityIDs.removeAll(keepingCapacity: true)
            sourceObservationStoreBaseline = nil
            sourceObservedBatchBaseline.removeAll(keepingCapacity: true)
            sourcePendingBatchBaseline.removeAll(keepingCapacity: true)
            deferredStateBaseline.removeAll(keepingCapacity: true)
        }
        guard !sourceObservationCycleFailed else {
            do {
                guard let sourceObservationStoreBaseline else {
                    throw CloudIncomingBatchStoreError.corrupt
                }
                let restored = try incomingBatchStore.restoreSourceObservation(
                    sourceObservationStoreBaseline,
                    accountIdentifier: incomingAccountIdentifier,
                    zoneID: zoneID,
                    generation: incomingBatchGeneration
                )
                sourceObservedFetchedBatchIDs = sourceObservedBatchBaseline.intersection(
                    restored.currentBatchIDs
                )
                sourcePendingFetchedBatchIDs = sourcePendingBatchBaseline.intersection(
                    restored.currentBatchIDs
                ).union(restored.awaitingSourceRedeliveryBatchIDs)
                deferredStateUpdates = deferredStateBaseline
                if let data = try persistEligibleDeferredState(
                    remainingUnacknowledgedBatchIDs: Set(unacknowledgedFetchedBatchIDs)
                ) {
                    eventContinuation.yield(.stateUpdated(data))
                }
            } catch {
                inboundDurabilityBlocked = true
                eventContinuation.yield(.failed(.statePersistence))
            }
            return
        }
        let recording: CloudIncomingBatchRecordingResult
        do {
            recording = try incomingBatchStore.completeSourceObservation(
                entityIDs: sourceObservationEntityIDs,
                accountIdentifier: incomingAccountIdentifier,
                zoneID: zoneID,
                generation: incomingBatchGeneration
            )
        } catch CloudIncomingBatchStoreError.capacityExceeded {
            inboundDurabilityBlocked = true
            eventContinuation.yield(.failed(.incomingBackpressure))
            return
        } catch {
            inboundDurabilityBlocked = true
            eventContinuation.yield(.failed(.statePersistence))
            return
        }
        sourcePendingFetchedBatchIDs.subtract(recording.fullyObservedBatchIDs)
        sourcePendingFetchedBatchIDs.formUnion(recording.partiallyObservedBatchIDs)
        sourceObservedFetchedBatchIDs.formUnion(recording.fullyObservedBatchIDs)
        do { try recordReceiptObservation(recording) }
        catch {
            inboundDurabilityBlocked = true
            eventContinuation.yield(.failed(.statePersistence))
            return
        }
        let newlyRequiredBatchIDs = Set(unacknowledgedFetchedBatchIDs).intersection(
            recording.fullyObservedBatchIDs
        )
        for index in deferredStateUpdates.indices
        where deferredStateUpdates[index].sourceObservationSequence
            == sourceObservationSequence {
            deferredStateUpdates[index].awaitsSuccessfulFetchBoundary = false
            deferredStateUpdates[index].requiredBatchIDs.formUnion(newlyRequiredBatchIDs)
            deferredStateUpdates[index].coveredBatchIDs.formUnion(
                recording.fullyObservedBatchIDs
            )
            deferredStateUpdates[index].incompleteSourceBatchIDs.subtract(
                recording.fullyObservedBatchIDs
            )
            deferredStateUpdates[index].incompleteSourceBatchIDs.formUnion(
                recording.partiallyObservedBatchIDs
            )
        }
        do {
            if let data = try persistEligibleDeferredState(
                remainingUnacknowledgedBatchIDs: Set(unacknowledgedFetchedBatchIDs)
            ) {
                eventContinuation.yield(.stateUpdated(data))
            }
        } catch {
            eventContinuation.yield(.failed(.statePersistence))
        }
    }

    func receiveFetchedChanges(records: [CKRecord], deletedRecordIDs: [CKRecord.ID]) {
        guard !accountResetBlocksRestart else { return }
        guard !inboundDurabilityBlocked else {
            eventContinuation.yield(.failed(.statePersistence))
            return
        }
        var decodedRecords: [SyncRecord] = []
        decodedRecords.reserveCapacity(records.count)
        for record in records {
            guard record.recordID.zoneID == zoneID else {
                eventContinuation.yield(.failed(.invalidRecord(recordID: Self.entityID(for: record.recordID))))
                inboundDurabilityBlocked = true
                if sourceObservationCycleDepth > 0 { sourceObservationCycleFailed = true }
                return
            }
            do {
                let decoded = try codec.decode(record)
                if let version = decoded.payload.attachment, decoded.deletedAt.value == nil {
                    let staging = try requireAssetStaging()
                    guard let url = (record["asset"] as? CKAsset)?.fileURL else {
                        throw CloudAssetStagingError.unavailable
                    }
                    _ = try accountEpoch.withCurrent {
                        try staging.installDownload(version: version, sourceURL: url)
                    }
                }
                decodedRecords.append(decoded)
            } catch {
                eventContinuation.yield(.failed(.invalidRecord(recordID: Self.entityID(for: record.recordID))))
                inboundDurabilityBlocked = true
                if sourceObservationCycleDepth > 0 { sourceObservationCycleFailed = true }
                return
            }
        }

        var deleted: [SyncEntityID] = []
        deleted.reserveCapacity(deletedRecordIDs.count)
        for recordID in deletedRecordIDs {
            guard recordID.zoneID == zoneID, let entityID = Self.entityID(for: recordID) else {
                eventContinuation.yield(.failed(.invalidRecord(recordID: Self.entityID(for: recordID))))
                inboundDurabilityBlocked = true
                if sourceObservationCycleDepth > 0 { sourceObservationCycleFailed = true }
                return
            }
            deleted.append(entityID)
        }
        do {
            if let systemFieldsStore {
                guard let currentAccountIdentifier else {
                    throw CloudRecordSystemFieldsStoreError.unavailable
                }
                try systemFieldsStore.apply(
                    records: records,
                    deletedRecordIDs: deletedRecordIDs,
                    accountIdentifier: currentAccountIdentifier
                )
            }
        } catch {
            inboundDurabilityBlocked = true
            if sourceObservationCycleDepth > 0 { sourceObservationCycleFailed = true }
            eventContinuation.yield(.failed(.statePersistence))
            return
        }
        let recording: CloudIncomingBatchRecordingResult
        do {
            recording = try incomingBatchStore.record(
                records: decodedRecords,
                deletedRecordIDs: deleted,
                accountIdentifier: incomingAccountIdentifier,
                zoneID: zoneID,
                generation: incomingBatchGeneration,
                allowsReconciliationSpillover: sourceObservationCycleAllowsSpillover
            )
        } catch CloudIncomingBatchStoreError.capacityExceeded {
            inboundDurabilityBlocked = true
            if sourceObservationCycleDepth > 0 { sourceObservationCycleFailed = true }
            eventContinuation.yield(.failed(.incomingBackpressure))
            return
        } catch {
            inboundDurabilityBlocked = true
            if sourceObservationCycleDepth > 0 { sourceObservationCycleFailed = true }
            eventContinuation.yield(.failed(.statePersistence))
            return
        }
        if sourceObservationCycleDepth > 0 {
            sourceObservationEntityIDs.formUnion(decodedRecords.map(\.id))
            sourceObservationEntityIDs.formUnion(deleted)
            sourceObservationSequence &+= 1
        }
        sourcePendingFetchedBatchIDs.subtract(recording.fullyObservedBatchIDs)
        sourcePendingFetchedBatchIDs.formUnion(recording.partiallyObservedBatchIDs)
        sourceObservedFetchedBatchIDs.formUnion(recording.fullyObservedBatchIDs)
        do { try recordReceiptObservation(recording) }
        catch {
            inboundDurabilityBlocked = true
            if sourceObservationCycleDepth > 0 { sourceObservationCycleFailed = true }
            eventContinuation.yield(.failed(.statePersistence))
            return
        }
        guard let envelope = recording.deliveredEnvelope else { return }
        let batchID = envelope.batchID
        activeFetchedBatchIDs.append(batchID)
        unacknowledgedFetchedBatchIDs.append(batchID)
        if let activeReceiptFetch { receiptFetchBatches[activeReceiptFetch, default: []].insert(batchID) }
        eventContinuation.yield(.fetched(
            batchID: batchID,
            accountEpoch: accountEpoch,
            records: envelope.records,
            deleted: envelope.deletedRecordIDs
        ))
    }

    /// Source redelivery may be fully deduplicated without a new envelope.
    /// Observation selects this fetch's members, but only an exact durable ACK
    /// can establish commitment. Verify before engine-state persistence can
    /// retire a fully observed acknowledged envelope and its evidence.
    private func recordReceiptObservation(_ recording: CloudIncomingBatchRecordingResult) throws {
        guard requiresInitialFetchReceipt, let request = activeReceiptFetch else { return }
        try accountEpoch.requireCurrent()
        receiptFetchBatches[request, default: []].formUnion(recording.fullyObservedBatchIDs)
        receiptFetchBatches[request, default: []].formUnion(recording.partiallyObservedBatchIDs)
        incompleteReceiptBatches.subtract(recording.fullyObservedBatchIDs)
        incompleteReceiptBatches.formUnion(recording.partiallyObservedBatchIDs)
        let account = try accountEpoch.verifiedAccountIdentity()
        let proofs = try acknowledgementSnapshot().acknowledged
        for identity in proofs where recording.fullyObservedBatchIDs.contains(identity.batchID) {
            try accountEpoch.withCurrent {
                try incomingBatchStore.verifyAcknowledgement(identity, accountIdentifier: incomingAccountIdentifier,
                    zoneID: zoneID, account: account)
            }
            committedReceiptBatches.insert(identity.batchID)
        }
    }

    func receiveZoneReady(_ readyZoneID: CKRecordZone.ID) async {
        guard !accountResetBlocksRestart else { return }
        guard readyZoneID == zoneID,
              !configuredZoneIsReady,
              !zoneResetInProgress,
              !zoneResetDurabilityBlocked else { return }
        configuredZoneIsReady = true
        zoneEpoch &+= 1
        eventContinuation.yield(.zoneReady)
        await kickConfiguredZoneSend()
    }

    func receiveDeletedZones(_ deletedZoneIDs: [CKRecordZone.ID]) async {
        guard !accountResetBlocksRestart else { return }
        guard deletedZoneIDs.contains(zoneID), !zoneResetInProgress else { return }
        zoneResetInProgress = true
        configuredZoneIsReady = false
        zoneEpoch &+= 1
        let resetGeneration = generation
        let resetZoneEpoch = zoneEpoch
        defer {
            if generation == resetGeneration, zoneEpoch == resetZoneEpoch {
                zoneResetInProgress = false
            }
        }
        sendAttempts.removeAll(keepingCapacity: false)
        failedContexts.removeAll(); failedMutationIDs.removeAll()
        successContexts.removeAll(); acknowledgedUploadsAwaitingCleanup.removeAll()
        deleteCallbackBarriers.removeAll(keepingCapacity: false)
        zoneResetDurabilityBlocked = false
        eventContinuation.yield(.zoneDeleted)
        if let systemFieldsStore {
            do {
                guard let currentAccountIdentifier else {
                    throw CloudRecordSystemFieldsStoreError.unavailable
                }
                try systemFieldsStore.removeAll(accountIdentifier: currentAccountIdentifier)
            } catch {
                zoneResetDurabilityBlocked = true
                eventContinuation.yield(.failed(.statePersistence))
            }
        }
        guard let engine else { return }
        let operationGeneration = generation
        let operationZoneEpoch = zoneEpoch
        let pending = await engine.pendingDatabaseChanges()
        guard isCurrentOperation(
            generation: operationGeneration,
            zoneEpoch: operationZoneEpoch
        ) else { return }
        let zoneSave = CKSyncEngine.PendingDatabaseChange.saveZone(CKRecordZone(zoneID: zoneID))
        if !pending.contains(zoneSave) {
            await engine.addDatabaseChanges([zoneSave])
            guard isCurrentOperation(
                generation: operationGeneration,
                zoneEpoch: operationZoneEpoch
            ) else { return }
        }
        await kickConfiguredZoneSend()
    }

    func receiveSentChanges(savedRecords: [CKRecord], deletedRecordIDs: [CKRecord.ID]) async {
        guard !accountResetBlocksRestart else { return }
        let operationGeneration = generation
        for record in savedRecords {
            guard generation == operationGeneration else { return }
            guard let entityID = Self.entityID(for: record.recordID),
                  let mutationID = Self.uuidField("syncMutationID", in: record),
                  let attemptID = Self.uuidField("syncAttemptID", in: record),
                  attemptMatches(entityID, attemptID: attemptID, mutationID: mutationID, intent: .save),
                  queues[entityID]?.first?.mutationID == mutationID else { continue }
            do {
                try persistSystemFields(record)
            } catch {
                failAttemptPermanently(
                    recordID: record.recordID,
                    mutationID: mutationID,
                    attemptID: attemptID,
                    failure: .statePersistence
                )
                continue
            }
            await acknowledge(
                record.recordID,
                intent: .save,
                mutationID: mutationID,
                attemptID: attemptID
            )
            guard generation == operationGeneration else { return }
        }
        for recordID in deletedRecordIDs {
            guard generation == operationGeneration else { return }
            guard let entityID = Self.entityID(for: recordID),
                  let attempt = sendAttempts[entityID],
                  attempt.intent == .delete else { continue }
            do {
                try removeSystemFields(recordID)
            } catch {
                failAttemptPermanently(
                    recordID: recordID,
                    mutationID: attempt.mutationID,
                    attemptID: attempt.attemptID,
                    failure: .statePersistence
                )
                continue
            }
            await acknowledge(
                recordID,
                intent: .delete,
                mutationID: attempt.mutationID,
                attemptID: attempt.attemptID
            )
            guard generation == operationGeneration else { return }
        }
    }

    func receiveFailedSave(_ record: CKRecord, error: CKError) async {
        guard !accountResetBlocksRestart else { return }
        guard let entityID = Self.entityID(for: record.recordID),
              let mutationID = Self.uuidField("syncMutationID", in: record),
              let attemptID = Self.uuidField("syncAttemptID", in: record),
              attemptMatches(entityID, attemptID: attemptID, mutationID: mutationID, intent: .save) else { return }
        let failedAttempt = sendAttempts.removeValue(forKey: entityID)!
        let failure = CloudSyncFailure.map(error, codec: codec)
        if failure == .limitExceeded, reduceBatch(after: failedAttempt) { return }
        if case .serverRecordChanged = failure, let serverRecord = error.serverRecord {
            do {
                guard let systemFieldsStore, let currentAccountIdentifier,
                      let raw = try? codec.decode(serverRecord), raw.id == failedAttempt.attempted.recordID else {
                    throw CloudRecordSystemFieldsStoreError.unavailable
                }
                try accountEpoch.withCurrent {
                    if let version = raw.payload.attachment, raw.deletedAt.value == nil {
                        guard let url = (serverRecord["asset"] as? CKAsset)?.fileURL else { throw CloudAssetStagingError.unavailable }
                        _ = try requireAssetStaging().installDownload(version: version, sourceURL: url)
                    }
                    try systemFieldsStore.save(serverRecord, accountIdentifier: currentAccountIdentifier)
                }
                guard
                      let evidence = try systemFieldsStore.verificationEvidence(recordID: serverRecord.recordID, accountIdentifier: currentAccountIdentifier),
                      raw.id == failedAttempt.attempted.recordID else { throw CloudRecordSystemFieldsStoreError.unavailable }
                failedContexts[entityID] = FailedSendContext(attempt: failedAttempt, serverRecord: raw, serverSHA256: try serverDigest(raw), systemFields: evidence)
            } catch {
                failedMutationIDs.insert(mutationID)
                eventContinuation.yield(.mutationFailed(
                    recordID: entityID,
                    mutationID: mutationID,
                    failure: .statePersistence, accountEpoch: accountEpoch, attemptID: attemptID, attempted: failedAttempt.attempted
                ))
                return
            }
        }
        if failure.isRetryable {
            eventContinuation.yield(.failed(failure))
        } else {
            failedMutationIDs.insert(mutationID)
            eventContinuation.yield(.mutationFailed(
                recordID: entityID,
                mutationID: mutationID,
                failure: failure, accountEpoch: accountEpoch, attemptID: attemptID, attempted: failedAttempt.attempted
            ))
        }
    }

    func receiveFailedDelete(_ recordID: CKRecord.ID, error: CKError) {
        guard !accountResetBlocksRestart else { return }
        guard let entityID = Self.entityID(for: recordID),
              let attempt = sendAttempts[entityID],
              attempt.intent == .delete else { return }
        sendAttempts.removeValue(forKey: entityID)
        let failure = CloudSyncFailure.map(error, codec: codec)
        if failure == .limitExceeded, reduceBatch(after: attempt) { return }
        if failure.isRetryable {
            eventContinuation.yield(.failed(failure))
        } else {
            failedMutationIDs.insert(attempt.mutationID)
            eventContinuation.yield(.mutationFailed(
                recordID: entityID,
                mutationID: attempt.mutationID,
                failure: failure, accountEpoch: accountEpoch, attemptID: attempt.attemptID, attempted: attempt.attempted
            ))
        }
    }

    func receiveSendCycleCompleted() async {
        guard !deleteCallbackBarriers.isEmpty || splitRetryPending else { return }
        deleteCallbackBarriers.removeAll(keepingCapacity: false)
        splitRetryPending = false
        await kickConfiguredZoneSend()
    }

    func recordZoneChangeBatch(
        pendingChanges: [CKSyncEngine.PendingRecordZoneChange],
        scope: CKSyncEngine.SendChangesOptions.Scope
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let operationGeneration = generation
        let operationZoneEpoch = zoneEpoch
        guard !terminalLatch.isTerminated,
              mutationReplayFinished,
              configuredZoneIsReady else { return nil }
        var current: [SyncEntityID: SyncVersionedMutation] = [:]
        for (entityID, queue) in queues {
            guard let mutation = queue.first,
                  !failedMutationIDs.contains(mutation.mutationID),
                  sendAttempts[entityID] == nil,
                  !deleteCallbackBarriers.contains(entityID) else { continue }
            current[entityID] = mutation
        }
        let requested = pendingChanges
            .filter { change in
                guard scope.contains(change),
                      let recordID = Self.recordID(for: change),
                      recordID.zoneID == self.zoneID,
                      let entityID = Self.entityID(for: recordID),
                      let mutation = current[entityID] else { return false }
                return self.pendingChange(for: mutation.mutation) == change
            }
        let bounded = Array(requested.prefix(batchLimit))
        guard !bounded.isEmpty else { return nil }
        var attempts: [SyncEntityID: SendAttempt] = [:]
        for change in bounded {
            guard let recordID = Self.recordID(for: change),
                  let entityID = Self.entityID(for: recordID),
                  let mutation = current[entityID] else { continue }
            attempts[entityID] = SendAttempt(
                attemptID: UUID(),
                attempted: mutation, generation: operationGeneration, zoneEpoch: operationZoneEpoch,
                epoch: accountEpoch, batchSize: bounded.count
            )
        }
        let currentSnapshot = current
        var attemptSnapshot = attempts
        let accountIdentifier = currentAccountIdentifier
        var materializedRecords: [CKRecord.ID: CKRecord] = [:]
        for change in bounded {
            guard case let .saveRecord(recordID) = change,
                  let entityID = Self.entityID(for: recordID),
                  let mutation = currentSnapshot[entityID],
                  let attempt = attemptSnapshot[entityID] else { continue }
            let baseRecord: CKRecord?
            do {
                if let accountIdentifier {
                    baseRecord = try systemFieldsStore?.load(
                        recordID: recordID,
                        accountIdentifier: accountIdentifier
                    )
                } else {
                    baseRecord = try systemFieldsStore?.loadUnique(recordID: recordID)
                }
            } catch {
                eventContinuation.yield(.failed(.statePersistence))
                continue
            }
            do {
                let record = try await recordMaterializer(mutation.mutation, baseRecord)
                guard batchContextIsCurrent(
                    entityID: entityID,
                    mutation: mutation,
                    generation: operationGeneration,
                    zoneEpoch: operationZoneEpoch
                ) else { return nil }
                if let version = mutation.savedRecordVersion?.record.payload.attachment,
                   mutation.savedRecordVersion?.record.deletedAt.value == nil {
                    let staging = try requireAssetStaging()
                    guard let source = mutation.attachmentSource else {
                        throw CloudAssetStagingError.unavailable
                    }
                    try staging.stageUpload(version: version, source: source, mutationID: mutation.mutationID)
                    let asset = try staging.assetForUpload(versionID: version.versionID, mutationID: mutation.mutationID)
                    record["asset"] = asset
                    guard let fileURL = asset.fileURL, let source = mutation.attachmentSource else { throw CloudAssetStagingError.unavailable }
                    let relocated = try SyncMutation.save(recordVersion: mutation.savedRecordVersion!,
                        attachmentSource: SyncAttachmentSource(fileURL: fileURL, contentSHA256: source.contentSHA256, byteCount: source.byteCount), mutationID: mutation.mutationID)
                    attemptSnapshot[entityID]?.attempted = try SyncVersionedMutation(mutation: relocated, journalRevision: mutation.token.journalRevision)
                }
                record["syncMutationID"] = attempt.mutationID.uuidString.lowercased() as NSString
                record["syncAttemptID"] = attempt.attemptID.uuidString.lowercased() as NSString
                materializedRecords[recordID] = record
            } catch {
                guard batchContextIsCurrent(
                    entityID: entityID,
                    mutation: mutation,
                    generation: operationGeneration,
                    zoneEpoch: operationZoneEpoch
                ) else { return nil }
                failedMutationIDs.insert(mutation.mutationID)
                eventContinuation.yield(.failed(.invalidRecord(recordID: entityID)))
            }
        }
        guard isCurrentOperation(
            generation: operationGeneration,
            zoneEpoch: operationZoneEpoch
        ), configuredZoneIsReady, mutationReplayFinished else { return nil }
        attempts = attemptSnapshot
        let materializedSnapshot = materializedRecords
        let batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: bounded) { recordID in
            materializedSnapshot[recordID]
        }
        guard isCurrentOperation(
            generation: operationGeneration,
            zoneEpoch: operationZoneEpoch
        ), configuredZoneIsReady, mutationReplayFinished, let batch else { return nil }
        let representedIDs = Set(batch.recordsToSave.map { $0.recordID } + batch.recordIDsToDelete)
        for (entityID, attempt) in attempts where representedIDs.contains(
            Self.cloudRecordID(for: entityID, zoneID: zoneID)
        ) {
            guard queues[entityID]?.first?.token == attempt.attempted.token, batchContextIsCurrent(
                entityID: entityID,
                mutationID: attempt.mutationID,
                intent: attempt.intent,
                generation: operationGeneration,
                zoneEpoch: operationZoneEpoch
            ) else { return nil }
        }
        for (entityID, attempt) in attempts where representedIDs.contains(
            Self.cloudRecordID(for: entityID, zoneID: zoneID)
        ) {
            sendAttempts[entityID] = attempt
        }
        return batch
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard !terminalLatch.isTerminated,
              cloudKitEngineIdentifier == ObjectIdentifier(syncEngine) else { return }
        switch event {
        case let .stateUpdate(update):
            receiveStateUpdate(update.stateSerialization)
        case let .accountChange(change):
            switch change.changeType {
            case let .signIn(currentUser):
                await receiveAccountChange(previous: nil, current: currentUser.recordName)
            case let .signOut(previousUser):
                await receiveAccountChange(previous: previousUser.recordName, current: nil)
            case let .switchAccounts(previousUser, currentUser):
                await receiveAccountChange(
                    previous: previousUser.recordName,
                    current: currentUser.recordName
                )
            @unknown default:
                await receiveAccountChange(previous: nil, current: nil)
            }
        case let .fetchedDatabaseChanges(changes):
            for modification in changes.modifications where modification.zoneID == zoneID {
                await receiveZoneReady(modification.zoneID)
            }
            await receiveDeletedZones(changes.deletions.map(\.zoneID))
        case let .sentDatabaseChanges(changes):
            for zone in changes.savedZones where zone.zoneID == zoneID {
                await receiveZoneReady(zone.zoneID)
            }
            for failure in changes.failedZoneSaves where failure.zone.zoneID == zoneID {
                eventContinuation.yield(.failed(.map(failure.error, codec: codec)))
            }
            for (failedZoneID, error) in changes.failedZoneDeletes where failedZoneID == zoneID {
                eventContinuation.yield(.failed(.map(error, codec: codec)))
            }
        case let .fetchedRecordZoneChanges(changes):
            receiveFetchedChanges(
                records: changes.modifications.map(\.record),
                deletedRecordIDs: changes.deletions.map(\.recordID)
            )
        case .willFetchRecordZoneChanges:
            do {
                try beginSourceObservationCycle()
            } catch {
                inboundDurabilityBlocked = true
                eventContinuation.yield(.failed(.statePersistence))
            }
        case let .sentRecordZoneChanges(changes):
            let callbackGeneration = generation
            await receiveSentChanges(
                savedRecords: changes.savedRecords,
                deletedRecordIDs: changes.deletedRecordIDs
            )
            guard generation == callbackGeneration,
                  cloudKitEngineIdentifier == ObjectIdentifier(syncEngine) else { return }
            for failure in changes.failedRecordSaves {
                await receiveFailedSave(failure.record, error: failure.error)
                guard generation == callbackGeneration,
                      cloudKitEngineIdentifier == ObjectIdentifier(syncEngine) else { return }
            }
            for (recordID, error) in changes.failedRecordDeletes {
                receiveFailedDelete(recordID, error: error)
            }
        case let .didFetchRecordZoneChanges(result):
            if let error = result.error {
                eventContinuation.yield(.failed(.map(error, codec: codec)))
                completeSourceObservationCycle(succeeded: false)
            } else {
                completeSourceObservationCycle(succeeded: true)
            }
        case .didSendChanges:
            await receiveSendCycleCompleted()
        case .willFetchChanges, .didFetchChanges, .willSendChanges:
            break
        @unknown default:
            eventContinuation.yield(.failed(.fatal(code: -1)))
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard cloudKitEngineIdentifier == ObjectIdentifier(syncEngine) else { return nil }
        let callbackGeneration = generation
        let callbackZoneEpoch = zoneEpoch
        let batch = await recordZoneChangeBatch(
            pendingChanges: syncEngine.state.pendingRecordZoneChanges,
            scope: context.options.scope
        )
        guard generation == callbackGeneration,
              zoneEpoch == callbackZoneEpoch,
              cloudKitEngineIdentifier == ObjectIdentifier(syncEngine) else { return nil }
        return batch
    }

    func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        guard cloudKitEngineIdentifier == ObjectIdentifier(syncEngine) else {
            return .init(scope: .zoneIDs([]))
        }
        return configuredFetchOptions(from: context.options)
    }

    private func acknowledge(
        _ cloudRecordID: CKRecord.ID,
        intent: SyncMutationIntent,
        mutationID: UUID,
        attemptID: UUID
    ) async {
        guard cloudRecordID.zoneID == zoneID,
              let entityID = Self.entityID(for: cloudRecordID),
              attemptMatches(entityID, attemptID: attemptID, mutationID: mutationID, intent: intent),
              var queue = queues[entityID],
              let completed = queue.first,
              completed.intent == intent,
              completed.mutationID == mutationID else { return }
        guard let attempt = sendAttempts.removeValue(forKey: entityID),
              completed.token == attempt.attempted.token else { return }
        if intent == .delete { deleteCallbackBarriers.insert(entityID) }
        queue.removeFirst()
        successContexts[attemptID] = attempt
        eventContinuation.yield(.sent(token: completed.token, attemptID: attemptID, accountEpoch: attempt.epoch))
        if queue.isEmpty {
            queues.removeValue(forKey: entityID)
            return
        }
        queues[entityID] = queue
        guard let engine else { return }
        let operationGeneration = generation
        var pending = await engine.pendingChanges()
        guard generation == operationGeneration else { return }
        do {
            try await representCurrentMutation(
                queue[0].mutation,
                engine: engine,
                enginePending: &pending,
                generation: operationGeneration
            )
        } catch {
            eventContinuation.yield(.failed(.invalidRecord(recordID: entityID)))
        }
    }

    private func representCurrentMutation(
        _ mutation: SyncMutation,
        engine: any CKSyncEngineDriving,
        enginePending: inout [CKSyncEngine.PendingRecordZoneChange],
        generation operationGeneration: UInt64
    ) async throws {
        let desired = pendingChange(for: mutation)
        let sameRecord = enginePending.filter {
            Self.recordID(for: $0) == Self.recordID(for: desired)
        }
        if sameRecord.count == 1, sameRecord[0] == desired { return }
        if !sameRecord.isEmpty {
            await engine.remove(sameRecord)
            try requireCurrentGeneration(operationGeneration)
            enginePending.removeAll { sameRecord.contains($0) }
        }
        await engine.add([desired])
        try requireCurrentGeneration(operationGeneration)
        enginePending.append(desired)
    }

    private func pendingChange(for mutation: SyncMutation) -> CKSyncEngine.PendingRecordZoneChange {
        let recordID = Self.cloudRecordID(for: mutation.recordID, zoneID: zoneID)
        switch mutation.intent {
        case .save: return .saveRecord(recordID)
        case .delete: return .deleteRecord(recordID)
        }
    }

    private static func recordID(
        for change: CKSyncEngine.PendingRecordZoneChange
    ) -> CKRecord.ID? {
        switch change {
        case let .saveRecord(recordID), let .deleteRecord(recordID): return recordID
        @unknown default: return nil
        }
    }

    private static func cloudRecordID(for entityID: SyncEntityID, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(
            recordName: "\(entityID.kind.rawValue)-\(entityID.uuid.uuidString.lowercased())",
            zoneID: zoneID
        )
    }

    static func entityID(for recordID: CKRecord.ID) -> SyncEntityID? {
        for kind in SyncEntityKind.allCases {
            let prefix = "\(kind.rawValue)-"
            guard recordID.recordName.hasPrefix(prefix) else { continue }
            let rawUUID = String(recordID.recordName.dropFirst(prefix.count))
            guard let uuid = UUID(uuidString: rawUUID) else { return nil }
            return SyncEntityID(kind: kind, uuid: uuid)
        }
        return nil
    }

    private static func uuidField(_ key: String, in record: CKRecord) -> UUID? {
        guard let rawValue = record[key] as? String else { return nil }
        return UUID(uuidString: rawValue)
    }

    private func requireCurrentGeneration(_ expected: UInt64) throws {
        try requireNotTerminated()
        guard generation == expected, engine != nil else {
            throw CloudSyncTransportError.staleOperation
        }
    }

    private func isCurrentOperation(generation expectedGeneration: UInt64, zoneEpoch: UInt64) -> Bool {
        !terminalLatch.isTerminated
            && generation == expectedGeneration
            && self.zoneEpoch == zoneEpoch
            && engine != nil
    }

    private func batchContextIsCurrent(
        entityID: SyncEntityID,
        mutation: SyncVersionedMutation,
        generation: UInt64,
        zoneEpoch: UInt64
    ) -> Bool {
        queues[entityID]?.first == mutation && batchContextIsCurrent(
            entityID: entityID,
            mutationID: mutation.mutationID,
            intent: mutation.intent,
            generation: generation,
            zoneEpoch: zoneEpoch
        )
    }

    private func batchContextIsCurrent(
        entityID: SyncEntityID,
        mutationID: UUID,
        intent: SyncMutationIntent,
        generation: UInt64,
        zoneEpoch: UInt64
    ) -> Bool {
        isCurrentOperation(generation: generation, zoneEpoch: zoneEpoch)
            && configuredZoneIsReady
            && mutationReplayFinished
            && queues[entityID]?.first?.mutationID == mutationID
            && queues[entityID]?.first?.intent == intent
            && sendAttempts[entityID] == nil
            && !failedMutationIDs.contains(mutationID)
            && !deleteCallbackBarriers.contains(entityID)
    }

    private func kickConfiguredZoneSend() async {
        do {
            try await sendConfiguredZoneChanges()
        } catch {
            // CK errors are surfaced by sendConfiguredZoneChanges; stale/terminal work is discarded.
        }
    }

    private func requireNotTerminated() throws {
        guard !terminalLatch.isTerminated else {
            throw CloudSyncTransportError.terminated
        }
    }

    private var incomingAccountIdentifier: String {
        currentAccountIdentifier ?? ""
    }

    private static func encodedState(
        _ serialization: CKSyncEngine.State.Serialization
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(serialization)
    }

    private func persistSystemFields(_ record: CKRecord) throws {
        guard let systemFieldsStore else { return }
        guard let accountIdentifier = currentAccountIdentifier,
              !accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudRecordSystemFieldsStoreError.unavailable
        }
        try accountEpoch.withCurrent { try systemFieldsStore.save(record, accountIdentifier: accountIdentifier) }
    }

    private func removeSystemFields(_ recordID: CKRecord.ID) throws {
        guard let systemFieldsStore else { return }
        guard let currentAccountIdentifier else {
            throw CloudRecordSystemFieldsStoreError.unavailable
        }
        try systemFieldsStore.remove(
            recordID: recordID,
            accountIdentifier: currentAccountIdentifier
        )
    }

    private func failAttemptPermanently(
        recordID: CKRecord.ID,
        mutationID: UUID,
        attemptID: UUID,
        failure: CloudSyncFailure
    ) {
        guard let entityID = Self.entityID(for: recordID),
              attemptMatches(entityID, attemptID: attemptID, mutationID: mutationID, intent: queues[entityID]?.first?.intent ?? .save) else { return }
        guard let failedAttempt = sendAttempts.removeValue(forKey: entityID) else { return }
        failedMutationIDs.insert(mutationID)
        eventContinuation.yield(.mutationFailed(
            recordID: entityID,
            mutationID: mutationID,
            failure: failure, accountEpoch: accountEpoch, attemptID: attemptID, attempted: failedAttempt.attempted
        ))
    }

    private func requireAssetStaging() throws -> CloudAssetStagingService {
        guard let assetStaging, assetStaging.accountIdentifier == currentAccountIdentifier else {
            throw CloudAssetStagingError.invalidAccount
        }
        return assetStaging
    }

    func verifySentMutation(_ token: SyncMutationVersionToken, attemptID: UUID, accountEpoch expectedEpoch: CloudSyncAccountEpoch) async throws {
        try requireNotTerminated()
        try expectedEpoch.requireCurrent()
        guard expectedEpoch === accountEpoch, let attempt = successContexts[attemptID],
              attempt.epoch === expectedEpoch, attempt.generation == generation, attempt.zoneEpoch == zoneEpoch,
              attempt.attempted.token == token else { throw CloudSyncTransportError.staleOperation }
    }

    func acknowledgeSentMutation(_ token: SyncMutationVersionToken, attemptID: UUID) async throws {
        try await verifySentMutation(token, attemptID: attemptID, accountEpoch: accountEpoch)
        acknowledgedUploadsAwaitingCleanup.insert(attemptID)
        try cleanupAcknowledgedUpload(attemptID)
    }

    private func cleanupAcknowledgedUpload(_ attemptID: UUID) throws {
        guard let attempt = successContexts[attemptID],
              attempt.epoch === accountEpoch, attempt.generation == generation,
              attempt.zoneEpoch == zoneEpoch else { throw CloudSyncTransportError.staleOperation }
        try accountEpoch.withCurrent {
            if let version = attempt.attempted.savedRecordVersion?.record.payload.attachment {
                // Never remove an upload reference now owned by a different journal revision.
                guard !queues.values.joined().contains(where: {
                    $0.identity == attempt.attempted.identity && $0.token != attempt.attempted.token
                }) else { throw CloudSyncTransportError.staleOperation }
                try requireAssetStaging().acknowledgeUpload(versionID: version.versionID, mutationID: attempt.mutationID)
            }
        }
        successContexts.removeValue(forKey: attemptID)
        acknowledgedUploadsAwaitingCleanup.remove(attemptID)
    }

    private func attemptMatches(_ id: SyncEntityID, attemptID: UUID, mutationID: UUID, intent: SyncMutationIntent) -> Bool {
        guard let attempt = sendAttempts[id] else { return false }
        return attempt.attemptID == attemptID && attempt.mutationID == mutationID && attempt.intent == intent
            && attempt.generation == generation && attempt.zoneEpoch == zoneEpoch && attempt.epoch === accountEpoch
            && queues[id]?.first?.token == attempt.attempted.token
    }

    private func reduceBatch(after attempt: SendAttempt) -> Bool {
        guard attempt.batchSize > 1 else { return false }
        batchLimit = min(batchLimit, max(1, attempt.batchSize / 2))
        splitRetryPending = true
        return true
    }

    private func terminateForEndedEventStream() async {
        terminalLatch.terminate()
        generation &+= 1
        let detachedEngine = engine
        engine = nil
        cloudKitEngineIdentifier = nil
        queues.removeAll(keepingCapacity: false)
        activeFetchedBatchIDs.removeAll(keepingCapacity: false)
        sourceObservedFetchedBatchIDs.removeAll(keepingCapacity: false)
        sourcePendingFetchedBatchIDs.removeAll(keepingCapacity: false)
        unacknowledgedFetchedBatchIDs.removeAll(keepingCapacity: false)
        deferredStateUpdates.removeAll(keepingCapacity: false)
        sourceObservationCycleDepth = 0
        sourceObservationCycleFailed = false
        sourceObservationCycleAllowsSpillover = false
        sourceObservationSequence = 0
        sourceObservationEntityIDs.removeAll(keepingCapacity: false)
        sourceObservationStoreBaseline = nil
        sourceObservedBatchBaseline.removeAll(keepingCapacity: false)
        sourcePendingBatchBaseline.removeAll(keepingCapacity: false)
        deferredStateBaseline.removeAll(keepingCapacity: false)
        inboundDurabilityBlocked = false
        mutationReplayFinished = false
        configuredZoneIsReady = false
        zoneResetInProgress = false
        sendAttempts.removeAll(keepingCapacity: false)
        failedMutationIDs.removeAll(keepingCapacity: false)
        failedContexts.removeAll()
        successContexts.removeAll()
        acknowledgedUploadsAwaitingCleanup.removeAll()
        deleteCallbackBarriers.removeAll(keepingCapacity: false)
        if let driver = detachedEngine {
            detachedEngineCancellation = Task { await driver.cancelOperations() }
        }
        await detachedEngineCancellation?.value
    }
}

private final class CloudSyncTerminalLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var terminated = false

    var isTerminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminated
    }

    func terminate() {
        lock.lock()
        terminated = true
        lock.unlock()
    }
}

private struct DeferredStateUpdate {
    let serialization: CKSyncEngine.State.Serialization
    var requiredBatchIDs: Set<UUID>
    var coveredBatchIDs: Set<UUID>
    var incompleteSourceBatchIDs: Set<UUID>
    let sourceObservationSequence: UInt64
    var awaitsSuccessfulFetchBoundary: Bool
}

private struct SendAttempt: Equatable {
    let attemptID: UUID
    var attempted: SyncVersionedMutation
    let generation: UInt64
    let zoneEpoch: UInt64
    let epoch: CloudSyncAccountEpoch
    var batchSize = 1
    var mutationID: UUID { attempted.mutation.mutationID }
    var intent: SyncMutationIntent { attempted.mutation.intent }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.attemptID == rhs.attemptID && lhs.attempted == rhs.attempted
            && lhs.generation == rhs.generation && lhs.zoneEpoch == rhs.zoneEpoch && lhs.epoch === rhs.epoch
    }
}

private struct FailedSendContext: Equatable {
    let attempt: SendAttempt
    let serverRecord: SyncRecord
    let serverSHA256: Data
    let systemFields: Data?
}

private extension SyncVersionedMutation {
    var recordID: SyncEntityID { mutation.recordID }
    var mutationID: UUID { mutation.mutationID }
    var identity: SyncMutationIdentity { mutation.identity }
    var intent: SyncMutationIntent { mutation.intent }
    var savedRecordVersion: SyncRecordVersion? { mutation.savedRecordVersion }
    var attachmentSource: SyncAttachmentSource? { mutation.attachmentSource }
}

private extension CloudSyncFailure {
    var isRetryable: Bool {
        if case .retryable = self { return true }
        return false
    }
}
