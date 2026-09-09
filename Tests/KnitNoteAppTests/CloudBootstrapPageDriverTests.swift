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
        lock.withLock { completions[ObjectIdentifier(operation)] }?()
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
