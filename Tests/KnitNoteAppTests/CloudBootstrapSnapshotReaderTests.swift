import CloudKit
import Darwin
import Foundation
import Testing
@testable import KnitNote

@Suite(.serialized) @MainActor struct CloudBootstrapSnapshotReaderTests {
    @Test(arguments: ["emptyLocal", "staleLocal", "emptyPending", "stalePending"])
    func readerDefersCombinedCounterValidationUntilLocalAndPendingArePresent(mode: String) async throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let operations = BootstrapControlledOperations(), reader = try reader(f, operations)
        let command = WatchCounterCommand(id: UUID(), projectID: f.projectID, counterID: UUID(), operation: .increment, createdAt: Date(timeIntervalSince1970: 1))
        let prepared = PreparedWatchCommand(command: command, expectedCounterRevision: 4, expectedCounterValue: 9)
        let current = ProjectCounter(id: command.counterID, defaultOrdinal: 1, value: 10, mutationRevision: 5)
        let localCounter = counterRecord(current, projectID: f.projectID, processed: [command.id])
        let staleCounter = counterRecord(.init(id: command.counterID, defaultOrdinal: 1, value: 9, mutationRevision: 4), projectID: f.projectID)
        let remote = mode.hasPrefix("stale") ? [staleCounter] : []
        let local = mode.hasSuffix("Local") ? [localCounter] : []
        let pending = mode.hasSuffix("Pending") ? [try SyncMutation.save(recordVersion: .init(record: localCounter), mutationID: UUID())] : []
        var ledger = ProcessedWatchCommandLedger()
        ledger.record(command.id, preparedCommand: prepared, effectProof: .init(counter: current), at: Date(timeIntervalSince1970: 2))
        let context = SyncCounterReminderMergeContext(processedLedger: ledger)
        // Establish that this exact combined input is accepted by native merge.
        #expect(try SyncMergeEngine().merge(local: local, remote: remote, pendingLocalMutations: pending,
            counterReminderContext: context).records.count == 1)
        let task = Task { try await reader.read() }, op = await operations.next()
        for record in remote { try emit(record, into: op, zone: f.scope.zoneID) }
        BootstrapControlledOperations.emitSuccessfulEmptyZone(op); operations.completeSuccessfully(op)
        let lease = try await task.value
        _ = try lease.withSnapshot(context: f.context, counterContext: context) { snapshot in
            #expect(snapshot.records == remote)
            let combined = try SyncMergeEngine().merge(local: local, remote: snapshot.records,
                pendingLocalMutations: pending, counterReminderContext: context)
            if case let .projectCounter(state)? = combined.records.first?.payload.atomicDomain?.value { #expect(state.counter.value == 10) }
            else { Issue.record("Expected combined counter") }
        }
    }

    @Test func missingCounterStillRejectsAtCombinedValidation() async throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let operations = BootstrapControlledOperations(), reader = try reader(f, operations)
        let task = Task { try await reader.read() }, op = await operations.next()
        BootstrapControlledOperations.emitSuccessfulEmptyZone(op); operations.completeSuccessfully(op)
        let lease = try await task.value
        let command = WatchCounterCommand(id: UUID(), projectID: f.projectID, counterID: UUID(), operation: .increment, createdAt: Date(timeIntervalSince1970: 1))
        let prepared = PreparedWatchCommand(command: command, expectedCounterRevision: 4, expectedCounterValue: 9)
        var ledger = ProcessedWatchCommandLedger()
        ledger.record(command.id, preparedCommand: prepared, at: Date(timeIntervalSince1970: 2))
        let context = SyncCounterReminderMergeContext(processedLedger: ledger)
        _ = try lease.withSnapshot(context: f.context, counterContext: context) { snapshot in
            #expect(throws: SyncMergeError.processedWatchCommandWouldRegress(command.id)) {
                try SyncMergeEngine().merge(local: [SyncRecord](), remote: snapshot.records,
                    pendingLocalMutations: [], counterReminderContext: context)
            }
        }
    }

    @Test(arguments: ["valid", "relationship", "schema", "oversize"])
    func remoteLegacyReminderWaitsForCounterPresentOnlyLocally(mode: String) async throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let counterID = UUID(), counter = counterRecord(.init(id: UUID(), defaultOrdinal: 1), projectID: f.projectID)
        let localCounter = counterRecord(.init(id: counterID, defaultOrdinal: 1), projectID: f.projectID)
        let reminder = try #require(KnittingReminder(id: UUID(), counterID: counterID,
            draft: .oneTime(kind: .cable, target: 4, text: nil), createdAt: Date(timeIntervalSince1970: 1)))
        let stamp = SyncMutationStamp(logicalRevision: reminder.mutationRevision, modifiedAt: Date(timeIntervalSince1970: 2), deviceID: "legacy")
        let legacy = SyncRecord(schemaVersion: 1, id: .init(kind: .knittingReminder, uuid: reminder.id), createdAt: reminder.createdAt,
            entityRevision: reminder.mutationRevision, payload: .init(fields: [:], atomicDomain: .init(value: .knittingReminder(reminder), stamp: stamp)),
            relationships: [.init(role: "project", target: .init(kind: .project, uuid: f.projectID)), .init(role: "counter", target: localCounter.id)], deletedAt: .init(value: nil, stamp: stamp))
        let operations = BootstrapControlledOperations(), reader = try reader(f, operations)
        let before = try f.entries()
        let task = Task { try await reader.read() }, op = await operations.next()
        let wire = try legacyWire(legacy, zone: f.scope.zoneID)
        #expect(throws: SyncRecordValidationError.illegalAtomicDomain(legacy.id)) { try CloudRecordCodec().decode(wire) }
        #expect(throws: (any Error).self) { try CloudRecordCodec().encode(legacy, zoneID: f.scope.zoneID) }
        if mode == "relationship" { wire["relationshipUUIDs"] = [f.projectID.uuidString.lowercased(), UUID().uuidString.lowercased()] as NSArray }
        if mode == "schema" { wire["schemaVersion"] = 2 as NSNumber }
        if mode == "oversize" { wire["futureOptionalField"] = Data(repeating: 0, count: 256 * 1024) as NSData }
        op.recordWasChangedBlock?(wire.recordID, .success(wire))
        BootstrapControlledOperations.emitSuccessfulEmptyZone(op); operations.completeSuccessfully(op)
        if mode != "valid" {
            await #expect(throws: (any Error).self) { try await task.value }
            #expect(try f.entries() == before)
            return
        }
        try (await task.value).withSnapshot(context: f.context, counterContext: .init()) { snapshot in
            #expect(snapshot.records == [legacy])
            let combined = try SyncMergeEngine().merge(local: [localCounter], remote: snapshot.records, pendingLocal: [])
            if case let .projectCounter(state)? = combined.records.first?.payload.atomicDomain?.value { #expect(state.reminders.map(\.id) == [reminder.id]) }
            else { Issue.record("Expected migrated counter") }
            #expect(throws: SyncRecordValidationError.illegalAtomicDomain(legacy.id)) {
                try SyncMergeEngine().merge(local: [counter], remote: snapshot.records, pendingLocal: [])
            }
        }
    }

    @Test func physicalDeletionRemovesOnlyRemoteSegmentAndPreservesLocalPending() async throws {
        let f = try CloudBootstrapFixture(withArchive: true); defer { f.remove() }
        let record = project(f.projectID, revision: 2, name: "remote")
        let journal = FileSyncMutationJournal(url: f.paths.mutationJournalURL)
        let mutation = try SyncMutation.save(recordVersion: .init(record: project(f.projectID, revision: 3, name: "pending")), mutationID: UUID())
        try journal.enqueue([mutation])
        let operations = BootstrapControlledOperations(), reader = try reader(f, operations)
        let before = try f.entries(), task = Task { try await reader.read() }, op = await operations.next()
        try emit(record, into: op, zone: f.scope.zoneID)
        op.recordWithIDWasDeletedBlock?(try CloudRecordCodec().encode(record, zoneID: f.scope.zoneID).recordID, "project")
        BootstrapControlledOperations.emitSuccessfulEmptyZone(op); operations.completeSuccessfully(op)
        try (await task.value).withSnapshot(context: f.context, counterContext: .init()) { #expect($0.records.isEmpty) }
        #expect(try journal.recoverySnapshot().mutations == [mutation])
        #expect(try f.entries() == before)
    }

    @Test(arguments: [false, true]) func validatesAttachmentBranchEvenWhenPhysicallyDeleted(removeBranch: Bool) async throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let operations = BootstrapControlledOperations(), reader = try reader(f, operations)
        let bytes = try CloudBootstrapFixture.jpeg(), first = try f.attachment(bytes: bytes)
        let second = try f.attachment(bytes: bytes, replaces: first.id.uuid)
        let task = Task { try await reader.read() }, op = await operations.next()
        let invalid = try CloudRecordCodec().encode(first, zoneID: f.scope.zoneID)
        invalid["asset"] = CKAsset(fileURL: try f.source(Data(repeating: 0, count: bytes.count)))
        op.recordWasChangedBlock?(invalid.recordID, .success(invalid))
        if removeBranch { op.recordWithIDWasDeletedBlock?(invalid.recordID, "attachment") }
        let valid = try CloudRecordCodec().encode(second, zoneID: f.scope.zoneID)
        valid["asset"] = CKAsset(fileURL: try f.source(bytes))
        op.recordWasChangedBlock?(valid.recordID, .success(valid))
        BootstrapControlledOperations.emitSuccessfulEmptyZone(op); operations.completeSuccessfully(op)
        await #expect(throws: (any Error).self) { try await task.value }
    }

    @Test func metadataArithmeticAdmitsExactLimitRejectsOverflowWithoutChangingBudget() throws {
        var budget = CloudBootstrapMetadataBudget()
        try budget.retain(encodedBytes: 16 * 1024 * 1024 - 1)
        try budget.retain(encodedBytes: 1)
        #expect(throws: (any Error).self) { try budget.retain(encodedBytes: 1) }
        #expect(throws: (any Error).self) { try budget.retain(encodedBytes: Int.max) }
        #expect(throws: (any Error).self) { try budget.retain(encodedBytes: -1) }
        #expect(budget.used == 16 * 1024 * 1024)
    }

    @Test(arguments: [false, true]) func pageLimitRequiresTerminalByPage128(tooMany: Bool) async throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let operations = BootstrapControlledOperations(), reader = try reader(f, operations)
        let task = Task { try await reader.read() }
        for index in 1...128 {
            let op = await operations.next()
            BootstrapControlledOperations.emitSuccessfulEmptyZone(op, moreComing: index < 128 || tooMany)
            operations.completeSuccessfully(op)
        }
        if tooMany { await #expect(throws: (any Error).self) { try await task.value } }
        else { try (await task.value).withSnapshot(context: f.context, counterContext: .init()) { #expect($0.isComplete) } }
    }

    @Test func actualMetadataAccumulationRejectsBeforeRetainingWholeScan() async throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let operations = BootstrapControlledOperations(), reader = try reader(f, operations)
        let before = try f.entries(), task = Task { try await reader.read() }, op = await operations.next()
        let record = project(f.projectID, revision: 1, name: String(repeating: "a", count: 32_000))
        // One callback is valid; the total scan exceeds 16 MiB even though all
        // callbacks have one ID, so counting only the unique map is insufficient.
        for _ in 0..<300 { try emit(record, into: op, zone: f.scope.zoneID) }
        BootstrapControlledOperations.emitSuccessfulEmptyZone(op); operations.completeSuccessfully(op)
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(try f.entries() == before)
    }

    @Test func partialSecondPageNeverIssuesLeaseOrChangesSources() async throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let operations = BootstrapControlledOperations(), reader = try reader(f, operations)
        let before = try f.entries(), task = Task { try await reader.read() }
        let first = await operations.next()
        try emit(project(f.projectID, revision: 1, name: "first"), into: first, zone: f.scope.zoneID)
        BootstrapControlledOperations.emitSuccessfulEmptyZone(first, moreComing: true); operations.completeSuccessfully(first)
        let last = await operations.next()
        last.recordZoneFetchResultBlock?(f.scope.zoneID, .failure(CKError(.changeTokenExpired)))
        last.fetchRecordZoneChangesResultBlock?(.failure(CKError(.partialFailure))); operations.completeSuccessfully(last)
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(try f.entries() == before)
    }

    @Test(arguments: ["late", "consumeInside", "invalidateInside", "context", "cancel", "duplicateCompletion"])
    func leaseRejectsRevocationAndWrongContext(mode: String) async throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let operations = BootstrapControlledOperations(), reader = try reader(f, operations)
        let task = Task { try await reader.read() }, op = await operations.next()
        await #expect(throws: (any Error).self) { try await reader.read() }
        let nativeCompletion = try #require(operations.capturedCompletion(op))
        BootstrapControlledOperations.emitSuccessfulEmptyZone(op); operations.completeSuccessfully(op)
        let lease = try await task.value
        if mode == "late" { op.recordWithIDWasDeletedBlock?(.init(recordName: "late", zoneID: f.scope.zoneID), "project") }
        if mode == "cancel" { await reader.cancelAndWait() }
        if mode == "duplicateCompletion" { nativeCompletion() }
        let context = mode == "context" ? SyncBootstrapContext(accountIDHash: f.context.accountIDHash, epoch: UUID(), freezeID: f.context.freezeID) : f.context
        #expect(throws: (any Error).self) {
            try lease.withSnapshot(context: context, counterContext: .init()) { _ in
                if mode == "consumeInside" { lease.consume() }
                if mode == "invalidateInside" { f.scope.invalidate() }
            }
        }
    }

    @Test func cancellationDuringAcceptedDownloadRevokesImmediatelyAndDrainsCompletion() async throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let operations = BootstrapControlledOperations(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let downloads = try CloudBootstrapDownloadStore(storage: f.storage, paths: f.paths, scope: f.scope, maximumBytes: 100_000_000,
            beforeBoundary: { if $0 == .afterInputRead { entered.signal(); _ = release.wait(timeout: .now() + 5) } })
        let reader = CloudBootstrapSnapshotReader(scope: f.scope, driver: CloudBootstrapPageDriver(scope: f.scope, schedule: operations.schedule), downloads: downloads)
        let bytes = try CloudBootstrapFixture.jpeg(), record = try f.attachment(bytes: bytes)
        let cloud = try CloudRecordCodec().encode(record, zoneID: f.scope.zoneID)
        cloud["asset"] = CKAsset(fileURL: try f.source(bytes))
        let before = try f.entries()
        let task = Task { defer { operations.markCompleted() }; return try await reader.read() }, op = await operations.next()
        let callback = Task.detached { op.recordWasChangedBlock?(cloud.recordID, .success(cloud)) }
        let didEnter = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 3) == .success) }
        }
        #expect(didEnter)
        task.cancel()
        #expect(throws: (any Error).self) { try f.scope.requireCurrent() }
        #expect(op.isCancelled)
        #expect(!operations.readerCompleted)
        release.signal(); await callback.value
        #expect(!operations.readerCompleted)
        operations.completeSuccessfully(op)
        await #expect(throws: (any Error).self) { try await task.value }
        await reader.cancelAndWait()
        #expect(try f.entries() == before)
    }
    @Test func completeEmptyZoneIssuesRevocableLeaseWithoutWrites() async throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let operations = BootstrapControlledOperations()
        let downloads = try CloudBootstrapDownloadStore(storage: f.storage, paths: f.paths, scope: f.scope, maximumBytes: 100_000_000)
        let reader = CloudBootstrapSnapshotReader(scope: f.scope, driver: CloudBootstrapPageDriver(scope: f.scope, schedule: operations.schedule), downloads: downloads)
        let before = try f.entries()
        let task = Task { defer { operations.markCompleted() }; return try await reader.read() }
        let op = await operations.next()
        BootstrapControlledOperations.emitSuccessfulEmptyZone(op)
        await Task.yield()
        #expect(!operations.readerCompleted)
        operations.completeSuccessfully(op)
        let lease = try await task.value
        try lease.withSnapshot(context: f.context, counterContext: .init()) { snapshot in
            #expect(snapshot.records.isEmpty && snapshot.isComplete)
            #expect(snapshot.attachments.isEmpty)
        }
        #expect(reader.runtimeAssets === downloads.runtimeAssets)
        #expect(try f.entries() == before)
        f.scope.invalidate()
        #expect(throws: (any Error).self) { try lease.withSnapshot(context: f.context, counterContext: .init()) { _ in () } }
        await #expect(throws: (any Error).self) { try await reader.read() }
    }

    @Test(arguments: [false, true]) func orderedVersionsDeleteAndRecreate(recreate: Bool) async throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let operations = BootstrapControlledOperations(), reader = try reader(f, operations)
        let task = Task { try await reader.read() }
        let first = await operations.next(), token = BootstrapControlledOperations.makeToken()
        let newer = project(f.projectID, revision: 9, name: "newer")
        let older = project(f.projectID, revision: 1, name: "older")
        try emit(newer, into: first, zone: f.scope.zoneID)
        BootstrapControlledOperations.zoneSuccess(first, moreComing: true, token: token)
        first.fetchRecordZoneChangesResultBlock?(.success(())); operations.completeSuccessfully(first)
        let second = await operations.next()
        #expect(second.configurationsByRecordZoneID?[f.scope.zoneID]?.previousServerChangeToken === token)
        try emit(older, into: second, zone: f.scope.zoneID)
        if recreate {
            let id = try CloudRecordCodec().encode(newer, zoneID: f.scope.zoneID).recordID
            second.recordWithIDWasDeletedBlock?(id, "project")
            try emit(older, into: second, zone: f.scope.zoneID)
        }
        BootstrapControlledOperations.emitSuccessfulEmptyZone(second); operations.completeSuccessfully(second)
        let lease = try await task.value
        try lease.withSnapshot(context: f.context, counterContext: .init()) {
            #expect($0.records.count == 1)
            #expect($0.records.first?.payload.fields["name"]?.value == .string(recreate ? "older" : "newer"))
        }
        lease.consume()
        #expect(throws: (any Error).self) { try lease.withSnapshot(context: f.context, counterContext: .init()) { _ in () } }
    }

    @Test(arguments: ["partial", "unknown", "wrongOwner", "badDeleteType", "badDeleteID", "conflictingFields"])
    func failedCollectionCannotIssueUsableSnapshot(mode: String) async throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let operations = BootstrapControlledOperations(), reader = try reader(f, operations)
        let before = try f.entries(), task = Task { try await reader.read() }
        let op = await operations.next()
        let record = project(f.projectID, revision: 1, name: "first")
        try emit(record, into: op, zone: f.scope.zoneID)
        switch mode {
        case "partial": op.fetchRecordZoneChangesResultBlock?(.failure(CKError(.networkFailure)))
        case "unknown":
            let cloud = CKRecord(recordType: "future", recordID: .init(recordName: "unknown", zoneID: f.scope.zoneID))
            op.recordWasChangedBlock?(cloud.recordID, .success(cloud))
        case "wrongOwner": try emit(record, into: op, zone: .init(zoneName: f.scope.zoneID.zoneName, ownerName: "other"))
        case "badDeleteType": op.recordWithIDWasDeletedBlock?(try CloudRecordCodec().encode(record, zoneID: f.scope.zoneID).recordID, "unknown")
        case "badDeleteID": op.recordWithIDWasDeletedBlock?(.init(recordName: "invalid", zoneID: f.scope.zoneID), "project")
        default: try emit(project(f.projectID, revision: 1, name: "conflicting"), into: op, zone: f.scope.zoneID)
        }
        if mode != "partial" { BootstrapControlledOperations.emitSuccessfulEmptyZone(op) }
        operations.completeSuccessfully(op)
        if mode == "conflictingFields" {
            let lease = try await task.value
            #expect(throws: (any Error).self) { try lease.withSnapshot(context: f.context, counterContext: .init()) { _ in () } }
        } else { await #expect(throws: (any Error).self) { try await task.value } }
        #expect(try f.entries() == before)
    }

    @Test(arguments: ["missing", "hash", "size", "replacement", "immutable", "valid"])
    func validatesEveryAttachmentObservationAndSource(mode: String) async throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let operations = BootstrapControlledOperations(), reader = try reader(f, operations)
        let bytes = try CloudBootstrapFixture.jpeg()
        let record = try f.attachment(bytes: bytes)
        let task = Task { try await reader.read() }, op = await operations.next()
        let cloud = try CloudRecordCodec().encode(record, zoneID: f.scope.zoneID)
        if mode != "missing" { cloud["asset"] = CKAsset(fileURL: try f.source(mode == "hash" ? Data(repeating: 0, count: bytes.count) : mode == "size" ? Data([0]) : bytes)) }
        op.recordWasChangedBlock?(cloud.recordID, .success(cloud))
        if mode == "immutable" {
            let other = try CloudRecordCodec().encode(record, zoneID: f.scope.zoneID)
            other["createdAt"] = Date(timeIntervalSince1970: 11) as NSDate
            other["asset"] = cloud["asset"]
            op.recordWasChangedBlock?(other.recordID, .success(other))
        }
        BootstrapControlledOperations.emitSuccessfulEmptyZone(op); operations.completeSuccessfully(op)
        if ["missing", "hash", "size", "immutable"].contains(mode) {
            await #expect(throws: (any Error).self) { try await task.value }
        } else {
            let lease = try await task.value
            if mode == "replacement" {
                let path = try reader.runtimeAssets.existingBootstrapDownload(version: #require(record.payload.attachment)).0.fileURL
                let copy = f.root.appendingPathComponent("replaced")
                #expect(copyfile(path.path, copy.path, nil, copyfile_flags_t(COPYFILE_ALL)) == 0)
                #expect(rename(copy.path, path.path) == 0)
                #expect(throws: (any Error).self) { try lease.withSnapshot(context: f.context, counterContext: .init()) { _ in () } }
            } else {
                try lease.withSnapshot(context: f.context, counterContext: .init()) {
                    #expect($0.attachments[record.id.uuid]?.byteCount == Int64(bytes.count))
                }
            }
        }
    }

    private func reader(_ f: CloudBootstrapFixture, _ operations: BootstrapControlledOperations) throws -> CloudBootstrapSnapshotReader {
        .init(scope: f.scope, driver: CloudBootstrapPageDriver(scope: f.scope, schedule: operations.schedule),
            downloads: try .init(storage: f.storage, paths: f.paths, scope: f.scope, maximumBytes: 100_000_000))
    }
    private func project(_ id: UUID, revision: UInt64, name: String) -> SyncRecord {
        let stamp = SyncMutationStamp(logicalRevision: revision, modifiedAt: Date(timeIntervalSince1970: Double(revision)), deviceID: "test")
        return .init(schemaVersion: 1, id: .init(kind: .project, uuid: id), createdAt: Date(timeIntervalSince1970: 1), entityRevision: revision,
            payload: .init(fields: ["name": .init(value: .string(name), stamp: stamp)]), relationships: [], deletedAt: .init(value: nil, stamp: stamp))
    }
    private func counterRecord(_ counter: ProjectCounter, projectID: UUID, processed: Set<UUID> = []) -> SyncRecord {
        let stamp = SyncMutationStamp(logicalRevision: counter.mutationRevision,
            modifiedAt: Date(timeIntervalSince1970: Double(counter.mutationRevision)), deviceID: "counter")
        let state = SyncCounterReminderState(counter: counter, reminders: [], preparedCommand: nil, processedCommandIDs: processed, occurrence: nil)
        return .init(schemaVersion: 1, id: .init(kind: .projectCounter, uuid: counter.id), createdAt: Date(timeIntervalSince1970: 0),
            entityRevision: counter.mutationRevision, payload: .init(fields: [:], atomicDomain: .init(value: .projectCounter(state), stamp: stamp)),
            relationships: [.init(role: "project", target: .init(kind: .project, uuid: projectID))], deletedAt: .init(value: nil, stamp: stamp))
    }
    private func legacyWire(_ record: SyncRecord, zone: CKRecordZone.ID) throws -> CKRecord {
        let encoder = SyncRecordVersion.deterministicEncoder(allowingLegacyStandaloneReminder: true)
        let cloud = CKRecord(recordType: "knittingReminder", recordID: .init(recordName: "knittingReminder-" + record.id.uuid.uuidString.lowercased(), zoneID: zone))
        cloud["schemaVersion"] = 1 as NSNumber
        cloud["entityID"] = record.id.uuid.uuidString.lowercased() as NSString
        cloud["createdAt"] = record.createdAt as NSDate
        cloud["entityRevision"] = String(record.entityRevision) as NSString
        cloud["deletedStamp"] = try encoder.encode(record.deletedAt.stamp) as NSData
        cloud["fields"] = try encoder.encode(record.payload.fields) as NSData
        cloud["atomicDomain"] = try encoder.encode(record.payload.atomicDomain) as NSData
        cloud["relationshipRoles"] = record.relationships.map(\.role) as NSArray
        cloud["relationshipKinds"] = record.relationships.map { $0.target.kind.rawValue } as NSArray
        cloud["relationshipUUIDs"] = record.relationships.map { $0.target.uuid.uuidString.lowercased() } as NSArray
        if let deletedAt = record.deletedAt.value { cloud["deletedAt"] = deletedAt as NSDate }
        return cloud
    }
    private func emit(_ record: SyncRecord, into op: CKFetchRecordZoneChangesOperation, zone: CKRecordZone.ID) throws {
        let cloud = try CloudRecordCodec().encode(record, zoneID: zone)
        op.recordWasChangedBlock?(cloud.recordID, .success(cloud))
    }
}
