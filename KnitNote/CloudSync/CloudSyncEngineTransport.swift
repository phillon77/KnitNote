import CloudKit
import Foundation

protocol CloudSyncTransport: AnyObject {
    var events: AsyncStream<CloudSyncEvent> { get }
    func start() async throws
    func schedule(_ mutations: [SyncMutation]) async throws
    func fetchNow() async throws
    func sendNow() async throws
}

enum CloudSyncEvent: Sendable {
    case accountChanged(previous: String?, current: String?)
    case fetched(records: [SyncRecord], deleted: [SyncEntityID])
    case sent(recordID: SyncEntityID, mutationID: UUID)
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
             .requestRateLimited, .zoneBusy, .operationCancelled, .batchRequestFailed:
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
}

protocol CKSyncEngineDriving: Sendable {
    var cloudKitEngineIdentifier: ObjectIdentifier? { get }
    func pendingChanges() async -> [CKSyncEngine.PendingRecordZoneChange]
    func add(_ changes: [CKSyncEngine.PendingRecordZoneChange]) async
    func remove(_ changes: [CKSyncEngine.PendingRecordZoneChange]) async
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

    nonisolated let events: AsyncStream<CloudSyncEvent>
    private nonisolated let eventContinuation: AsyncStream<CloudSyncEvent>.Continuation
    private let zoneID: CKRecordZone.ID
    private let stateStore: FileCloudSyncEngineStateStore
    private let engineFactory: EngineFactory
    private let codec = CloudRecordCodec()
    private var engine: (any CKSyncEngineDriving)?
    private var cloudKitEngineIdentifier: ObjectIdentifier?
    /// The first entry is the mutation currently represented in CKSyncEngine.
    /// Later entries stay here until their predecessor is acknowledged.
    private var queues: [SyncEntityID: [SyncMutation]] = [:]

    init(
        container: CKContainer,
        zoneID: CKRecordZone.ID,
        stateStore: FileCloudSyncEngineStateStore
    ) {
        let database = container.privateCloudDatabase
        self.init(zoneID: zoneID, stateStore: stateStore) { serialization, delegate in
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
        stateStore: FileCloudSyncEngineStateStore
    ) {
        self.init(
            container: CKContainer(identifier: containerIdentifier),
            zoneID: zoneID,
            stateStore: stateStore
        )
    }

    init(
        zoneID: CKRecordZone.ID,
        stateStore: FileCloudSyncEngineStateStore,
        engineFactory: @escaping EngineFactory
    ) {
        let pair = AsyncStream<CloudSyncEvent>.makeStream()
        events = pair.stream
        eventContinuation = pair.continuation
        self.zoneID = zoneID
        self.stateStore = stateStore
        self.engineFactory = engineFactory
    }

    func start() async throws {
        guard engine == nil else { return }
        let serialization = try stateStore.load()
        let created = engineFactory(serialization, self)
        engine = created
        cloudKitEngineIdentifier = created.cloudKitEngineIdentifier
    }

    func schedule(_ mutations: [SyncMutation]) async throws {
        guard let engine else { throw CloudSyncTransportError.notStarted }
        var enginePending = await engine.pendingChanges()
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
                enginePending: &enginePending
            )
        }
    }

    func fetchNow() async throws {
        guard let engine else { throw CloudSyncTransportError.notStarted }
        do {
            try await engine.fetchChanges(.init(scope: .zoneIDs([zoneID])))
        } catch let error as CKError {
            eventContinuation.yield(.failed(.map(error, codec: codec)))
            throw error
        }
    }

    func sendNow() async throws {
        guard let engine else { throw CloudSyncTransportError.notStarted }
        do {
            try await engine.sendChanges(.init(scope: .zoneIDs([zoneID])))
        } catch let error as CKError {
            eventContinuation.yield(.failed(.map(error, codec: codec)))
            throw error
        }
    }

    func receiveStateUpdate(_ serialization: CKSyncEngine.State.Serialization) {
        do {
            let data = try stateStore.save(serialization)
            eventContinuation.yield(.stateUpdated(data))
        } catch {
            eventContinuation.yield(.failed(.statePersistence))
        }
    }

    func receiveAccountChange(previous: String?, current: String?) async {
        do {
            try stateStore.clear()
        } catch {
            eventContinuation.yield(.failed(.statePersistence))
        }
        await engine?.cancelOperations()
        engine = nil
        cloudKitEngineIdentifier = nil
        queues.removeAll(keepingCapacity: false)
        eventContinuation.yield(.accountChanged(previous: previous, current: current))
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
            deleted.append(entityID)
        }
        eventContinuation.yield(.fetched(records: decodedRecords, deleted: deleted))
    }

    func receiveSentChanges(savedRecordIDs: [CKRecord.ID], deletedRecordIDs: [CKRecord.ID]) async {
        for recordID in savedRecordIDs {
            await acknowledge(recordID, intent: .save)
        }
        for recordID in deletedRecordIDs {
            await acknowledge(recordID, intent: .delete)
        }
    }

    func recordZoneChangeBatch(
        pendingChanges: [CKSyncEngine.PendingRecordZoneChange],
        scope: CKSyncEngine.SendChangesOptions.Scope
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let requested = pendingChanges.lazy
            .filter { scope.contains($0) && Self.recordID(for: $0)?.zoneID == self.zoneID }
            .prefix(250)
        let bounded = Array(requested)
        guard !bounded.isEmpty else { return nil }
        let current = Dictionary(uniqueKeysWithValues: queues.compactMap { entityID, queue in
            queue.first.map { (entityID, $0) }
        })
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: bounded) { [zoneID] recordID in
            guard recordID.zoneID == zoneID,
                  let entityID = Self.entityID(for: recordID),
                  case let .save(save)? = current[entityID] else { return nil }
            return try? CloudRecordCodec().encode(save.recordVersion.record, zoneID: zoneID)
        }
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
        case let .fetchedRecordZoneChanges(changes):
            receiveFetchedChanges(
                records: changes.modifications.map(\.record),
                deletedRecordIDs: changes.deletions.map(\.recordID)
            )
        case let .sentRecordZoneChanges(changes):
            await receiveSentChanges(
                savedRecordIDs: changes.savedRecords.map(\.recordID),
                deletedRecordIDs: changes.deletedRecordIDs
            )
            for failure in changes.failedRecordSaves {
                eventContinuation.yield(.failed(.map(failure.error, codec: codec)))
            }
            for error in changes.failedRecordDeletes.values {
                eventContinuation.yield(.failed(.map(error, codec: codec)))
            }
        case let .didFetchRecordZoneChanges(result):
            if let error = result.error {
                eventContinuation.yield(.failed(.map(error, codec: codec)))
            }
        case .fetchedDatabaseChanges, .sentDatabaseChanges,
             .willFetchChanges, .willFetchRecordZoneChanges, .didFetchChanges,
             .willSendChanges, .didSendChanges:
            break
        @unknown default:
            eventContinuation.yield(.failed(.fatal(code: -1)))
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await recordZoneChangeBatch(
            pendingChanges: syncEngine.state.pendingRecordZoneChanges,
            scope: context.options.scope
        )
    }

    private func acknowledge(_ cloudRecordID: CKRecord.ID, intent: SyncMutationIntent) async {
        guard cloudRecordID.zoneID == zoneID,
              let entityID = Self.entityID(for: cloudRecordID),
              var queue = queues[entityID],
              let completed = queue.first,
              completed.intent == intent else { return }
        queue.removeFirst()
        eventContinuation.yield(.sent(recordID: entityID, mutationID: completed.mutationID))
        if queue.isEmpty {
            queues.removeValue(forKey: entityID)
            return
        }
        queues[entityID] = queue
        guard let engine else { return }
        var pending = await engine.pendingChanges()
        do {
            try await representCurrentMutation(queue[0], engine: engine, enginePending: &pending)
        } catch {
            eventContinuation.yield(.failed(.invalidRecord(recordID: entityID)))
        }
    }

    private func representCurrentMutation(
        _ mutation: SyncMutation,
        engine: any CKSyncEngineDriving,
        enginePending: inout [CKSyncEngine.PendingRecordZoneChange]
    ) async throws {
        let desired = pendingChange(for: mutation)
        let sameRecord = enginePending.filter {
            Self.recordID(for: $0) == Self.recordID(for: desired)
        }
        if sameRecord.count == 1, sameRecord[0] == desired { return }
        if !sameRecord.isEmpty {
            await engine.remove(sameRecord)
            enginePending.removeAll { sameRecord.contains($0) }
        }
        await engine.add([desired])
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
}
