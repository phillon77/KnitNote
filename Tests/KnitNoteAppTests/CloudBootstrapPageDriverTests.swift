import CloudKit
import Foundation
import Testing
@testable import KnitNote

/// Holds the real operation, invoking its actual refined callbacks independently.
final class BootstrapControlledOperations: @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [CKFetchRecordZoneChangesOperation] = []
    private var waiter: CheckedContinuation<CKFetchRecordZoneChangesOperation, Never>?
    private var finished = false
    private var completions: [ObjectIdentifier: @Sendable () -> Void] = [:]
    var readerCompleted: Bool { lock.withLock { finished } }
    func markCompleted() { lock.withLock { finished = true } }
    func schedule(_ operation: CKFetchRecordZoneChangesOperation, completion: @escaping @Sendable () -> Void) {
        let resume = lock.withLock { () -> CheckedContinuation<CKFetchRecordZoneChangesOperation, Never>? in
            completions[ObjectIdentifier(operation)] = completion
            if let value = waiter { waiter = nil; return value }
            queued.append(operation); return nil
        }
        resume?.resume(returning: operation)
    }
    func next() async -> CKFetchRecordZoneChangesOperation {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> CKFetchRecordZoneChangesOperation? in
                if !queued.isEmpty { return queued.removeFirst() }
                precondition(waiter == nil); waiter = continuation; return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
    static func zoneSuccess(_ operation: CKFetchRecordZoneChangesOperation, moreComing: Bool = false,
                            zone: CKRecordZone.ID? = nil, token: CKServerChangeToken = makeToken()) {
        operation.recordZoneFetchResultBlock?(zone ?? operation.recordZoneIDs![0],
            .success((serverChangeToken: token, clientChangeTokenData: nil, moreComing: moreComing)))
    }
    static func emitSuccessfulEmptyZone(_ operation: CKFetchRecordZoneChangesOperation, moreComing: Bool = false) {
        zoneSuccess(operation, moreComing: moreComing)
        operation.fetchRecordZoneChangesResultBlock?(.success(()))
    }
    func completeSuccessfully(_ operation: CKFetchRecordZoneChangesOperation) {
        lock.withLock { completions.removeValue(forKey: ObjectIdentifier(operation)) }?()
    }
    func capturedCompletion(_ operation: CKFetchRecordZoneChangesOperation) -> (@Sendable () -> Void)? {
        lock.withLock { completions[ObjectIdentifier(operation)] }
    }
    static func makeToken() -> CKServerChangeToken {
        let archive = NSKeyedArchiver(requiringSecureCoding: true)
        archive.finishEncoding()
        let decoder = try! NSKeyedUnarchiver(forReadingFrom: archive.encodedData)
        decoder.decodingFailurePolicy = .setErrorAndReturn
        return CKServerChangeToken(coder: decoder)!
    }
}

@Suite(.serialized) @MainActor struct CloudBootstrapPageDriverTests {
    // Break caught: a completed SDK operation retains the collector/account
    // through its still-configured callback gate after the real native drain.
    @Test(arguments: [false, true])
    func retainedCompletedOperationReleasesConsumerButLateCallbackStillRevokes(cancelled: Bool) async throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let operations = BootstrapControlledOperations()
        let driver = CloudBootstrapPageDriver(scope: f.scope, schedule: operations.schedule)
        let consumerRoot = f.root.appendingPathComponent("consumer")
        let account = f.account.identity
        var consumer: SyncAccountStorage? = SyncAccountStorage(baseURL: consumerRoot)
        let paths = try consumer!.openForVerifiedAccount(identity: f.account.identity, validateAccount: {})
        weak let observed = consumer
        var run: Task<CloudBootstrapPageResult, any Error>? = Task { [captured = consumer!] in
            try await driver.fetchPage(zoneID: f.scope.zoneID, previousToken: nil) { _ in
                try captured.withRecoveryOwnership(paths: paths, account: account, maximumBytes: 100_000_000) { try $0.validate() }
            }
        }
        let op = await operations.next()
        consumer = nil
        if cancelled { run?.cancel() }
        #expect(observed != nil) // Accepted native work still owns its consumer.
        BootstrapControlledOperations.emitSuccessfulEmptyZone(op)
        operations.completeSuccessfully(op)
        let result = await run!.result
        if cancelled { if case .success = result { Issue.record("cancelled operation returned success") } }
        else { _ = try result.get() }
        run = nil
        #expect(observed == nil)
        let next = SyncAccountStorage(baseURL: consumerRoot)
        _ = try next.openExistingAccount(identity: f.account.identity, validateAccount: {})
        try next.close()
        if !cancelled { try f.scope.requireCurrent() }
        // Deliberately keep the actual native operation and its configured
        // callbacks alive. Late callbacks still revoke without using consumer.
        op.recordWithIDWasDeletedBlock?(.init(recordName: "late", zoneID: f.scope.zoneID), "project")
        #expect(throws: (any Error).self) { try f.scope.requireCurrent() }
        await driver.cancelAndWait()
    }

    @Test func successWaitsForOperationCompletion() async throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let operations = BootstrapControlledOperations()
        let driver = CloudBootstrapPageDriver(scope: f.scope, schedule: operations.schedule)
        let task = Task { defer { operations.markCompleted() }; return try await driver.fetchPage(zoneID: f.scope.zoneID, previousToken: nil) { _ in } }
        let op = await operations.next()
        #expect(op.fetchAllChanges == false)
        #expect(op.recordZoneIDs == [f.scope.zoneID])
        #expect(op.configurationsByRecordZoneID?[f.scope.zoneID]?.previousServerChangeToken == nil)
        BootstrapControlledOperations.zoneSuccess(op)
        await Task.yield()
        #expect(!operations.readerCompleted)
        op.fetchRecordZoneChangesResultBlock?(.success(()))
        await Task.yield()
        #expect(!operations.readerCompleted)
        operations.completeSuccessfully(op)
        #expect(try await task.value.moreComing == false)
    }
    @Test(arguments: ["zone", "result", "wrongZone", "wrongTokenZone", "recordError", "duplicateZone", "duplicateResult", "lateRecord", "tokenExpired", "operationError"])
    func incompleteOrPoisonedOperationRejects(mode: String) async throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let operations = BootstrapControlledOperations()
        let driver = CloudBootstrapPageDriver(scope: f.scope, schedule: operations.schedule)
        let task = Task { try await driver.fetchPage(zoneID: f.scope.zoneID, previousToken: nil) { _ in } }
        let op = await operations.next()
        if mode == "wrongTokenZone" { op.recordZoneChangeTokensUpdatedBlock?(.init(zoneName: "wrong"), nil, nil) }
        if mode == "recordError" { op.recordWasChangedBlock?(.init(recordName: "bad", zoneID: f.scope.zoneID), .failure(CKError(.networkFailure))) }
        if mode != "zone" {
            if mode == "tokenExpired" { op.recordZoneFetchResultBlock?(f.scope.zoneID, .failure(CKError(.changeTokenExpired))) }
            else { BootstrapControlledOperations.zoneSuccess(op, zone: mode == "wrongZone" ? .init(zoneName: "wrong") : nil) }
        }
        if mode == "duplicateZone" { BootstrapControlledOperations.zoneSuccess(op) }
        if mode != "result" { op.fetchRecordZoneChangesResultBlock?(mode == "operationError" ? .failure(CKError(.networkFailure)) : .success(())) }
        if mode == "duplicateResult" { op.fetchRecordZoneChangesResultBlock?(.success(())) }
        if mode == "lateRecord" { op.recordWithIDWasDeletedBlock?(.init(recordName: "late", zoneID: f.scope.zoneID), "project") }
        operations.completeSuccessfully(op)
        await #expect(throws: (any Error).self) { try await task.value }
    }
    @Test func cancellationCancelsNativeOperationButJoinsCompletion() async throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let operations = BootstrapControlledOperations()
        let driver = CloudBootstrapPageDriver(scope: f.scope, schedule: operations.schedule)
        let task = Task { defer { operations.markCompleted() }; return try await driver.fetchPage(zoneID: f.scope.zoneID, previousToken: nil) { _ in } }
        let op = await operations.next()
        task.cancel()
        await Task.yield()
        #expect(op.isCancelled)
        #expect(!operations.readerCompleted)
        operations.completeSuccessfully(op)
        await #expect(throws: (any Error).self) { try await task.value }
        await driver.cancelAndWait()
    }
}
