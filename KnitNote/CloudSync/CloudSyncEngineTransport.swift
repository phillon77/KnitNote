import CloudKit
import Foundation

protocol CloudSyncTransport: AnyObject {
    var events: AsyncStream<CloudSyncEvent> { get }
    func start() async throws
    func schedule(_ mutations: [SyncMutation]) async throws
    func finishMutationReplay() async throws
    func acknowledgeFetchedBatch(_ batchID: UUID) async throws
    func resolveFailedMutation(_ mutationID: UUID, replacement: SyncMutation?) async throws
    func fetchNow() async throws
    func sendNow() async throws
}

enum CloudSyncEvent: Sendable {
    case accountChanged(previous: String?, current: String?)
    case fetched(batchID: UUID, records: [SyncRecord], deleted: [SyncEntityID])
    case sent(recordID: SyncEntityID, mutationID: UUID)
    case mutationFailed(recordID: SyncEntityID, mutationID: UUID, failure: CloudSyncFailure)
    case zoneReady
    case zoneDeleted
    case stateUpdated(Data)
    case failed(CloudSyncFailure)
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
    case statePersistence
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

private final class LiveCKSyncEngineDriver: CKSyncEngineDriving, @unchecked Sendable {
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
    private let zoneID: CKRecordZone.ID
    private let stateStore: FileCloudSyncEngineStateStore
    private let systemFieldsStore: FileCloudRecordSystemFieldsStore?
    private let recordMaterializer: RecordMaterializer
    private let engineFactory: EngineFactory
    private let codec = CloudRecordCodec()
    private var engine: (any CKSyncEngineDriving)?
    private var cloudKitEngineIdentifier: ObjectIdentifier?
    private var generation: UInt64 = 0
    private var unacknowledgedFetchedBatchIDs: [UUID] = []
    private var deferredStateUpdates: [DeferredStateUpdate] = []
    private var mutationReplayFinished = false
    private var configuredZoneIsReady = false
    private var sendAttempts: [SyncEntityID: SendAttempt] = [:]
    private var failedMutationIDs: Set<UUID> = []
    private var deleteCallbackBarriers: Set<SyncEntityID> = []
    private var currentAccountIdentifier: String?
    private var accountResetBlocksRestart = false
    /// The first entry is the mutation currently represented in CKSyncEngine.
    /// Later entries stay here until their predecessor is acknowledged.
    private var queues: [SyncEntityID: [SyncMutation]] = [:]

    init(
        container: CKContainer,
        zoneID: CKRecordZone.ID,
        stateStore: FileCloudSyncEngineStateStore,
        systemFieldsStore: FileCloudRecordSystemFieldsStore,
        initialAccountIdentifier: String? = nil
    ) {
        let database = container.privateCloudDatabase
        self.init(
            zoneID: zoneID,
            stateStore: stateStore,
            systemFieldsStore: systemFieldsStore,
            initialAccountIdentifier: initialAccountIdentifier
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
        initialAccountIdentifier: String? = nil
    ) {
        self.init(
            container: CKContainer(identifier: containerIdentifier),
            zoneID: zoneID,
            stateStore: stateStore,
            systemFieldsStore: systemFieldsStore,
            initialAccountIdentifier: initialAccountIdentifier
        )
    }

    init(
        zoneID: CKRecordZone.ID,
        stateStore: FileCloudSyncEngineStateStore,
        systemFieldsStore: FileCloudRecordSystemFieldsStore? = nil,
        initialAccountIdentifier: String? = nil,
        recordMaterializer: RecordMaterializer? = nil,
        engineFactory: @escaping EngineFactory
    ) {
        let pair = AsyncStream<CloudSyncEvent>.makeStream()
        events = pair.stream
        eventContinuation = pair.continuation
        self.zoneID = zoneID
        self.stateStore = stateStore
        self.systemFieldsStore = systemFieldsStore
        currentAccountIdentifier = initialAccountIdentifier
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
        eventContinuation.onTermination = { [weak self] _ in
            Task { await self?.terminateForEndedEventStream() }
        }
    }

    func start() async throws {
        guard !accountResetBlocksRestart else {
            throw CloudSyncTransportError.accountResetIncomplete
        }
        guard engine == nil else { return }
        let serialization = try stateStore.load()
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
    }

    func schedule(_ mutations: [SyncMutation]) async throws {
        guard let engine else { throw CloudSyncTransportError.notStarted }
        let operationGeneration = generation
        var enginePending = await engine.pendingChanges()
        try requireCurrentGeneration(operationGeneration)
        for mutation in mutations {
            let validated = try mutation.validated()
            if case let .save(save) = validated {
                _ = try codec.encode(save.recordVersion.record, zoneID: zoneID)
            }
            var queue = queues[validated.recordID, default: []]
            guard !queue.contains(where: { $0.mutationID == validated.mutationID }) else { continue }
            queue.append(validated)
            queues[validated.recordID] = queue
            guard queue.count == 1 else { continue }
            try await representCurrentMutation(
                validated,
                engine: engine,
                enginePending: &enginePending,
                generation: operationGeneration
            )
        }
    }

    func fetchNow() async throws {
        guard let engine else { throw CloudSyncTransportError.notStarted }
        let operationGeneration = generation
        do {
            try await engine.fetchChanges(.init(scope: .zoneIDs([zoneID])))
            try requireCurrentGeneration(operationGeneration)
        } catch let error as CKError {
            guard generation == operationGeneration else {
                throw CloudSyncTransportError.staleOperation
            }
            eventContinuation.yield(.failed(.map(error, codec: codec)))
            throw error
        }
    }

    func finishMutationReplay() async throws {
        guard engine != nil else { throw CloudSyncTransportError.notStarted }
        mutationReplayFinished = true
        try await sendNow()
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
        guard unacknowledgedFetchedBatchIDs.contains(batchID) else {
            throw CloudSyncTransportError.unknownFetchedBatch
        }
        let remaining = Set(unacknowledgedFetchedBatchIDs.filter { $0 != batchID })
        let persistableCount = deferredStateUpdates.prefix {
            $0.requiredBatchIDs.isDisjoint(with: remaining)
        }.count
        if persistableCount > 0 {
            do {
                let data = try stateStore.save(
                    deferredStateUpdates[persistableCount - 1].serialization
                )
                eventContinuation.yield(.stateUpdated(data))
            } catch {
                eventContinuation.yield(.failed(.statePersistence))
                throw error
            }
        }
        unacknowledgedFetchedBatchIDs.removeAll { $0 == batchID }
        deferredStateUpdates.removeFirst(persistableCount)
    }

    func resolveFailedMutation(_ mutationID: UUID, replacement: SyncMutation?) async throws {
        guard let entry = queues.first(where: { $0.value.first?.mutationID == mutationID }),
              failedMutationIDs.contains(mutationID) else {
            throw CloudSyncTransportError.unknownFailedMutation
        }
        var queue = entry.value
        if let replacement {
            let validated = try replacement.validated()
            guard validated.recordID == entry.key else {
                throw CloudSyncTransportError.invalidReplacement
            }
            if case let .save(save) = validated {
                _ = try codec.encode(save.recordVersion.record, zoneID: zoneID)
            }
            queue[0] = validated
        } else {
            queue.removeFirst()
        }
        failedMutationIDs.remove(mutationID)
        if queue.isEmpty {
            queues.removeValue(forKey: entry.key)
        } else {
            queues[entry.key] = queue
        }
        guard let engine else { return }
        let operationGeneration = generation
        var pending = await engine.pendingChanges()
        try requireCurrentGeneration(operationGeneration)
        if queue.isEmpty {
            let recordID = Self.cloudRecordID(for: entry.key, zoneID: zoneID)
            let obsolete = pending.filter { Self.recordID(for: $0) == recordID }
            if !obsolete.isEmpty {
                await engine.remove(obsolete)
                try requireCurrentGeneration(operationGeneration)
            }
            return
        }
        try await representCurrentMutation(
            queue[0],
            engine: engine,
            enginePending: &pending,
            generation: operationGeneration
        )
    }

    func sendNow() async throws {
        guard let engine else { throw CloudSyncTransportError.notStarted }
        let operationGeneration = generation
        do {
            try await engine.sendChanges(.init(scope: .zoneIDs([zoneID])))
            try requireCurrentGeneration(operationGeneration)
        } catch let error as CKError {
            guard generation == operationGeneration else {
                throw CloudSyncTransportError.staleOperation
            }
            eventContinuation.yield(.failed(.map(error, codec: codec)))
            throw error
        }
    }

    func receiveStateUpdate(_ serialization: CKSyncEngine.State.Serialization) {
        guard !unacknowledgedFetchedBatchIDs.isEmpty else {
            persistStateUpdate(serialization)
            return
        }
        deferredStateUpdates.append(DeferredStateUpdate(
            serialization: serialization,
            requiredBatchIDs: Set(unacknowledgedFetchedBatchIDs)
        ))
    }

    private func persistStateUpdate(_ serialization: CKSyncEngine.State.Serialization) {
        do {
            let data = try stateStore.save(serialization)
            eventContinuation.yield(.stateUpdated(data))
        } catch {
            eventContinuation.yield(.failed(.statePersistence))
        }
    }

    func receiveAccountChange(previous: String?, current: String?) async {
        generation &+= 1
        let detachedEngine = engine
        engine = nil
        cloudKitEngineIdentifier = nil
        queues.removeAll(keepingCapacity: false)
        unacknowledgedFetchedBatchIDs.removeAll(keepingCapacity: false)
        deferredStateUpdates.removeAll(keepingCapacity: false)
        mutationReplayFinished = false
        configuredZoneIsReady = false
        sendAttempts.removeAll(keepingCapacity: false)
        failedMutationIDs.removeAll(keepingCapacity: false)
        deleteCallbackBarriers.removeAll(keepingCapacity: false)
        do {
            try stateStore.clear()
            accountResetBlocksRestart = false
            currentAccountIdentifier = current
        } catch {
            accountResetBlocksRestart = true
            currentAccountIdentifier = nil
            eventContinuation.yield(.failed(.statePersistence))
        }
        eventContinuation.yield(.accountChanged(previous: previous, current: current))
        await detachedEngine?.cancelOperations()
    }

    func receiveFetchedChanges(records: [CKRecord], deletedRecordIDs: [CKRecord.ID]) {
        var decodedRecords: [SyncRecord] = []
        decodedRecords.reserveCapacity(records.count)
        for record in records {
            guard record.recordID.zoneID == zoneID else {
                eventContinuation.yield(.failed(.invalidRecord(recordID: Self.entityID(for: record.recordID))))
                continue
            }
            do {
                try persistSystemFields(record)
                decodedRecords.append(try codec.decode(record))
            } catch {
                eventContinuation.yield(.failed(.invalidRecord(recordID: Self.entityID(for: record.recordID))))
            }
        }

        var deleted: [SyncEntityID] = []
        deleted.reserveCapacity(deletedRecordIDs.count)
        for recordID in deletedRecordIDs {
            guard recordID.zoneID == zoneID, let entityID = Self.entityID(for: recordID) else {
                eventContinuation.yield(.failed(.invalidRecord(recordID: Self.entityID(for: recordID))))
                continue
            }
            do {
                try removeSystemFields(recordID)
            } catch {
                eventContinuation.yield(.failed(.statePersistence))
            }
            deleted.append(entityID)
        }
        let batchID = UUID()
        unacknowledgedFetchedBatchIDs.append(batchID)
        eventContinuation.yield(.fetched(
            batchID: batchID,
            records: decodedRecords,
            deleted: deleted
        ))
    }

    func receiveZoneReady(_ readyZoneID: CKRecordZone.ID) {
        guard readyZoneID == zoneID else { return }
        configuredZoneIsReady = true
        eventContinuation.yield(.zoneReady)
    }

    func receiveDeletedZones(_ deletedZoneIDs: [CKRecordZone.ID]) {
        guard deletedZoneIDs.contains(zoneID) else { return }
        configuredZoneIsReady = false
        eventContinuation.yield(.zoneDeleted)
    }

    func receiveSentChanges(savedRecords: [CKRecord], deletedRecordIDs: [CKRecord.ID]) async {
        let operationGeneration = generation
        for record in savedRecords {
            guard generation == operationGeneration else { return }
            guard let entityID = Self.entityID(for: record.recordID),
                  let mutationID = Self.uuidField("syncMutationID", in: record),
                  let attemptID = Self.uuidField("syncAttemptID", in: record),
                  sendAttempts[entityID] == SendAttempt(
                    attemptID: attemptID,
                    mutationID: mutationID,
                    intent: .save
                  ),
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
        guard let entityID = Self.entityID(for: record.recordID),
              let mutationID = Self.uuidField("syncMutationID", in: record),
              let attemptID = Self.uuidField("syncAttemptID", in: record),
              sendAttempts[entityID] == SendAttempt(
                attemptID: attemptID,
                mutationID: mutationID,
                intent: .save
              ) else { return }
        sendAttempts.removeValue(forKey: entityID)
        let failure = CloudSyncFailure.map(error, codec: codec)
        if case .serverRecordChanged = failure, let serverRecord = error.serverRecord {
            do {
                try persistSystemFields(serverRecord)
            } catch {
                failedMutationIDs.insert(mutationID)
                eventContinuation.yield(.mutationFailed(
                    recordID: entityID,
                    mutationID: mutationID,
                    failure: .statePersistence
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
                failure: failure
            ))
        }
    }

    func receiveFailedDelete(_ recordID: CKRecord.ID, error: CKError) {
        guard let entityID = Self.entityID(for: recordID),
              let attempt = sendAttempts[entityID],
              attempt.intent == .delete else { return }
        sendAttempts.removeValue(forKey: entityID)
        let failure = CloudSyncFailure.map(error, codec: codec)
        if failure.isRetryable {
            eventContinuation.yield(.failed(failure))
        } else {
            failedMutationIDs.insert(attempt.mutationID)
            eventContinuation.yield(.mutationFailed(
                recordID: entityID,
                mutationID: attempt.mutationID,
                failure: failure
            ))
        }
    }

    func receiveSendCycleCompleted() {
        deleteCallbackBarriers.removeAll(keepingCapacity: false)
    }

    func recordZoneChangeBatch(
        pendingChanges: [CKSyncEngine.PendingRecordZoneChange],
        scope: CKSyncEngine.SendChangesOptions.Scope
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let operationGeneration = generation
        guard mutationReplayFinished, configuredZoneIsReady else { return nil }
        var current: [SyncEntityID: SyncMutation] = [:]
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
                return self.pendingChange(for: mutation) == change
            }
        let bounded = Array(requested.prefix(250))
        guard !bounded.isEmpty else { return nil }
        var attempts: [SyncEntityID: SendAttempt] = [:]
        for change in bounded {
            guard let recordID = Self.recordID(for: change),
                  let entityID = Self.entityID(for: recordID),
                  let mutation = current[entityID] else { continue }
            attempts[entityID] = SendAttempt(
                attemptID: UUID(),
                mutationID: mutation.mutationID,
                intent: mutation.intent
            )
        }
        let currentSnapshot = current
        let attemptSnapshot = attempts
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
                let record = try await recordMaterializer(mutation, baseRecord)
                guard generation == operationGeneration else { return nil }
                record["syncMutationID"] = attempt.mutationID.uuidString.lowercased() as NSString
                record["syncAttemptID"] = attempt.attemptID.uuidString.lowercased() as NSString
                materializedRecords[recordID] = record
            } catch {
                eventContinuation.yield(.failed(.invalidRecord(recordID: entityID)))
            }
        }
        guard generation == operationGeneration else { return nil }
        let materializedSnapshot = materializedRecords
        let batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: bounded) { recordID in
            materializedSnapshot[recordID]
        }
        guard generation == operationGeneration, let batch else { return nil }
        let representedIDs = Set(batch.recordsToSave.map { $0.recordID } + batch.recordIDsToDelete)
        for (entityID, attempt) in attempts where representedIDs.contains(
            Self.cloudRecordID(for: entityID, zoneID: zoneID)
        ) {
            sendAttempts[entityID] = attempt
        }
        return batch
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard cloudKitEngineIdentifier == ObjectIdentifier(syncEngine) else { return }
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
                receiveZoneReady(modification.zoneID)
            }
            receiveDeletedZones(changes.deletions.map(\.zoneID))
        case let .sentDatabaseChanges(changes):
            for zone in changes.savedZones where zone.zoneID == zoneID {
                receiveZoneReady(zone.zoneID)
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
            }
        case .didSendChanges:
            receiveSendCycleCompleted()
        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchChanges,
             .willSendChanges:
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
        let batch = await recordZoneChangeBatch(
            pendingChanges: syncEngine.state.pendingRecordZoneChanges,
            scope: context.options.scope
        )
        guard generation == callbackGeneration,
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
              sendAttempts[entityID] == SendAttempt(
                attemptID: attemptID,
                mutationID: mutationID,
                intent: intent
              ),
              var queue = queues[entityID],
              let completed = queue.first,
              completed.intent == intent,
              completed.mutationID == mutationID else { return }
        sendAttempts.removeValue(forKey: entityID)
        if intent == .delete { deleteCallbackBarriers.insert(entityID) }
        queue.removeFirst()
        eventContinuation.yield(.sent(recordID: entityID, mutationID: completed.mutationID))
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
                queue[0],
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
        guard generation == expected, engine != nil else {
            throw CloudSyncTransportError.staleOperation
        }
    }

    private func persistSystemFields(_ record: CKRecord) throws {
        guard let systemFieldsStore else { return }
        let accountIdentifier = currentAccountIdentifier
            ?? record.creatorUserRecordID?.recordName
        guard let accountIdentifier else {
            throw CloudRecordSystemFieldsStoreError.unavailable
        }
        try systemFieldsStore.save(record, accountIdentifier: accountIdentifier)
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
              sendAttempts[entityID] == SendAttempt(
                attemptID: attemptID,
                mutationID: mutationID,
                intent: queues[entityID]?.first?.intent ?? .save
              ) else { return }
        sendAttempts.removeValue(forKey: entityID)
        failedMutationIDs.insert(mutationID)
        eventContinuation.yield(.mutationFailed(
            recordID: entityID,
            mutationID: mutationID,
            failure: failure
        ))
    }

    private func terminateForEndedEventStream() async {
        generation &+= 1
        let detachedEngine = engine
        engine = nil
        cloudKitEngineIdentifier = nil
        queues.removeAll(keepingCapacity: false)
        unacknowledgedFetchedBatchIDs.removeAll(keepingCapacity: false)
        deferredStateUpdates.removeAll(keepingCapacity: false)
        mutationReplayFinished = false
        configuredZoneIsReady = false
        sendAttempts.removeAll(keepingCapacity: false)
        failedMutationIDs.removeAll(keepingCapacity: false)
        deleteCallbackBarriers.removeAll(keepingCapacity: false)
        await detachedEngine?.cancelOperations()
    }
}

private struct DeferredStateUpdate {
    let serialization: CKSyncEngine.State.Serialization
    let requiredBatchIDs: Set<UUID>
}

private struct SendAttempt: Equatable {
    let attemptID: UUID
    let mutationID: UUID
    let intent: SyncMutationIntent
}

private extension CloudSyncFailure {
    var isRetryable: Bool {
        if case .retryable = self { return true }
        return false
    }
}
