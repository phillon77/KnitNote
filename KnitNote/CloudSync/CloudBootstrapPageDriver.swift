import CloudKit
import Foundation

enum CloudBootstrapPageEvent {
    case record(CKRecord)
    case deleted(CKRecord.ID, recordType: CKRecord.RecordType)
}
struct CloudBootstrapPageResult: Sendable {
    let zoneID: CKRecordZone.ID
    let token: CKServerChangeToken
    let moreComing: Bool
}
protocol CloudBootstrapPageDriving: Sendable {
    func requireScope(_ scope: CloudBootstrapSessionScope) throws
    func fetchPage(zoneID: CKRecordZone.ID, previousToken: CKServerChangeToken?,
        receive: @escaping @Sendable (CloudBootstrapPageEvent) throws -> Void) async throws -> CloudBootstrapPageResult
    func cancelAndWait() async
}
enum CloudBootstrapReadError: Error { case incomplete, reused, invalidCallback, capacity, invalidAsset }
final class CloudBootstrapPageDriver: CloudBootstrapPageDriving, @unchecked Sendable {
    private let scope: CloudBootstrapSessionScope
    private let schedule: @Sendable (CKFetchRecordZoneChangesOperation, @escaping @Sendable () -> Void) -> Void
    private let lock = NSLock()
    private var active: BootstrapPageGate?
    private var stopped = false

    init(scope: CloudBootstrapSessionScope,
         schedule: @escaping @Sendable (CKFetchRecordZoneChangesOperation, @escaping @Sendable () -> Void) -> Void) {
        self.scope = scope; self.schedule = schedule
    }

    func requireScope(_ scope: CloudBootstrapSessionScope) throws {
        guard self.scope === scope else { throw SyncBootstrapError.contextChanged }
        try scope.requireCurrent()
    }

    /// Not called by normal startup. No consumer can choose another database.
    static func live(scope: CloudBootstrapSessionScope) -> CloudBootstrapPageDriver {
        let database = CKContainer(identifier: scope.account.containerIdentifier).privateCloudDatabase
        return .init(scope: scope) { operation, completion in
            operation.completionBlock = completion
            database.add(operation)
        }
    }

    func fetchPage(zoneID: CKRecordZone.ID, previousToken: CKServerChangeToken?,
        receive: @escaping @Sendable (CloudBootstrapPageEvent) throws -> Void) async throws -> CloudBootstrapPageResult {
        try scope.requireCurrent()
        guard zoneID == scope.zoneID else { throw CloudBootstrapReadError.invalidCallback }
        return try await withTaskCancellationHandler {
            let result: CloudBootstrapPageResult = try await withCheckedThrowingContinuation { continuation in
                let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
                configuration.previousServerChangeToken = previousToken
                let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID], configurationsByRecordZoneID: [zoneID: configuration])
                operation.fetchAllChanges = false
                let gate = BootstrapPageGate(scope: scope, continuation: continuation, receive: receive,
                    cancel: { [weak operation] in operation?.cancel() })
                let admitted = lock.withLock { () -> Bool in
                    guard !stopped, active == nil else { return false }
                    active = gate; return true
                }
                guard admitted else { continuation.resume(throwing: CloudBootstrapReadError.reused); return }
                operation.recordWasChangedBlock = { id, result in
                    gate.callback {
                        let record = try result.get()
                        guard id == record.recordID, id.zoneID == zoneID else { throw CloudBootstrapReadError.invalidCallback }
                        try gate.receive(.record(record))
                    }
                }
                operation.recordWithIDWasDeletedBlock = { id, type in
                    gate.callback {
                        guard id.zoneID == zoneID else { throw CloudBootstrapReadError.invalidCallback }
                        try gate.receive(.deleted(id, recordType: type))
                    }
                }
                operation.recordZoneFetchResultBlock = { id, result in
                    gate.zone(id: id, result: result.map { .init(zoneID: id, token: $0.serverChangeToken, moreComing: $0.moreComing) })
                }
                operation.recordZoneChangeTokensUpdatedBlock = { id, _, _ in
                    gate.callback {
                        guard id == zoneID else { throw CloudBootstrapReadError.invalidCallback }
                    }
                }
                operation.fetchRecordZoneChangesResultBlock = { gate.operationResult($0) }
                schedule(operation) { gate.complete() }
            }
            lock.withLock { active = nil }
            try scope.requireCurrent()
            return result
        } onCancel: {
            self.requestCancellation()
        }
    }

    private func requestCancellation() {
        scope.invalidate()
        let gate = lock.withLock { stopped = true; return active }
        gate?.cancel()
    }
    func cancelAndWait() async {
        requestCancellation()
        let gate = lock.withLock { active }
        await gate?.wait()
    }
}

/// Serializes callback admission, including inline download work, with the native
/// completion boundary. The operation alone owns these callback closures.
private final class BootstrapPageGate: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let scope: CloudBootstrapSessionScope
    private let nativeCancel: @Sendable () -> Void
    private var consumer: (@Sendable (CloudBootstrapPageEvent) throws -> Void)?
    private var continuation: CheckedContinuation<CloudBootstrapPageResult, any Error>?
    private var zoneResult: CloudBootstrapPageResult?
    private var hasOperationResult = false
    private var completed = false
    private var error: (any Error)?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(scope: CloudBootstrapSessionScope, continuation: CheckedContinuation<CloudBootstrapPageResult, any Error>,
         receive: @escaping @Sendable (CloudBootstrapPageEvent) throws -> Void, cancel: @escaping @Sendable () -> Void) {
        self.scope = scope; self.continuation = continuation; self.consumer = receive; self.nativeCancel = cancel
    }
    func receive(_ event: CloudBootstrapPageEvent) throws {
        // Called inside callback's gate lock. Native completion cannot release
        // the collector while an accepted synchronous download is using it.
        guard let consumer else { throw CloudBootstrapReadError.invalidCallback }
        try consumer(event)
    }
    private func fail(_ failure: any Error) {
        if error == nil { error = failure }
        nativeCancel()
    }
    func callback(_ body: () throws -> Void) {
        lock.withLock {
            guard !completed, !hasOperationResult, zoneResult == nil else {
                fail(CloudBootstrapReadError.invalidCallback); scope.invalidate(); return
            }
            guard error == nil else { return }
            do { try scope.requireCurrent(); try body(); try scope.requireCurrent() }
            catch { fail(error) }
        }
    }
    func zone(id: CKRecordZone.ID, result: Result<CloudBootstrapPageResult, any Error>) {
        callback {
            guard id == scope.zoneID else { throw CloudBootstrapReadError.invalidCallback }
            zoneResult = try result.get()
        }
    }
    func operationResult(_ result: Result<Void, any Error>) {
        lock.withLock {
            guard !completed, !hasOperationResult else { fail(CloudBootstrapReadError.invalidCallback); scope.invalidate(); return }
            hasOperationResult = true
            if case let .failure(failure) = result { fail(failure) }
        }
    }
    func complete() {
        lock.withLock {
            guard !completed else { scope.invalidate(); return }
            completed = true
            if error == nil, !hasOperationResult || zoneResult == nil { error = CloudBootstrapReadError.incomplete }
            if error == nil { do { try scope.requireCurrent() } catch { self.error = error } }
            // CloudKit may retain a completed cancelled operation and all of
            // its callbacks. Those callbacks still reject/revoke late events,
            // but must no longer own the collector's account storage after the
            // native completion barrier. The reader retains its own evidence.
            consumer = nil
            if let error { continuation?.resume(throwing: error) }
            else if let zoneResult { continuation?.resume(returning: zoneResult) }
            continuation = nil
            let pending = waiters; waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }
    // Revocation and native cancellation must never wait behind accepted IO.
    func cancel() { scope.invalidate(); nativeCancel() }
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if completed { continuation.resume() } else { waiters.append(continuation) }
            }
        }
    }
}
