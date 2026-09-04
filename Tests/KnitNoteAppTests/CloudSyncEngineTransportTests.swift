import CloudKit
import Foundation
import Testing
@testable import KnitNote

@Suite struct CloudSyncEngineTransportTests {
    @Test func stateWriteIsAtomicAndSynchronizesFileAndParentDirectory() throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let first = try stateSerialization(base64: "AQ==")
        let second = try stateSerialization(base64: "Ag==")
        try fixture.store.save(first)
        let firstBytes = try Data(contentsOf: fixture.url)
        var boundaries: [SyncDurableFileWriteBoundary] = []
        let interrupted = FileCloudSyncEngineStateStore(
            url: fixture.url,
            beforeWriteBoundary: { boundary in
                boundaries.append(boundary)
                if boundary == .beforeRename { throw TestInterruption() }
            }
        )

        #expect(throws: TestInterruption.self) {
            try interrupted.save(second)
        }
        #expect(try Data(contentsOf: fixture.url) == firstBytes)
        #expect(boundaries == [.beforeFileSync, .beforeRename])

        boundaries.removeAll()
        let completed = FileCloudSyncEngineStateStore(
            url: fixture.url,
            beforeWriteBoundary: { boundaries.append($0) }
        )
        try completed.save(second)
        let loadedBytes = try encodedState(completed.load())
        let expectedBytes = try encodedState(second)
        #expect(boundaries == [.beforeFileSync, .beforeRename, .beforeDirectorySync])
        #expect(loadedBytes == expectedBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            .filter { $0.hasSuffix(".tmp") }.isEmpty)
    }

    @Test func malformedAndUnsafeStateFilesFailClosed() throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        try Data("not a CKSyncEngine state".utf8).write(to: fixture.url)

        #expect(throws: CloudSyncEngineStateStoreError.corrupt) {
            _ = try fixture.store.load()
        }

        try FileManager.default.removeItem(at: fixture.url)
        let target = fixture.root.appendingPathComponent("target")
        try Data(#"{"data":"AQ=="}"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.url, withDestinationURL: target)
        #expect(throws: CloudSyncEngineStateStoreError.unsafeFile) {
            _ = try fixture.store.load()
        }
    }

    @Test func stateSaveRejectsSymlinkInsteadOfReplacingIt() throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let target = fixture.root.appendingPathComponent("target")
        let original = Data("unrelated data".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.url, withDestinationURL: target)

        #expect(throws: CloudSyncEngineStateStoreError.unsafeFile) {
            try fixture.store.save(try stateSerialization(base64: "AQ=="))
        }
        #expect(try Data(contentsOf: target) == original)
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: fixture.url.path)
        #expect(destination == target.path)
    }

    @Test func fetchedChangesPreserveTheirCallbackOrder() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let driver = TestSyncEngineDriver()
        let zoneID = testZoneID()
        let transport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            engineFactory: { _, _ in driver }
        )
        var iterator = transport.events.makeAsyncIterator()
        try await transport.start()
        let records = try [
            testRecord(uuid: "00000000-0000-0000-0000-000000000002", revision: 2),
            testRecord(uuid: "00000000-0000-0000-0000-000000000001", revision: 1),
        ]
        let cloudRecords = try records.map { try CloudRecordCodec().encode($0, zoneID: zoneID) }
        let deleted = [
            cloudRecordID(kind: .yarn, uuid: "00000000-0000-0000-0000-000000000004", zoneID: zoneID),
            cloudRecordID(kind: .project, uuid: "00000000-0000-0000-0000-000000000003", zoneID: zoneID),
        ]

        await transport.receiveFetchedChanges(records: cloudRecords, deletedRecordIDs: deleted)

        guard case let .fetched(receivedRecords, receivedDeleted)? = await iterator.next() else {
            Issue.record("Expected fetched event")
            return
        }
        #expect(receivedRecords.map(\.id) == records.map(\.id))
        #expect(receivedDeleted == [
            .init(kind: .yarn, uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!),
            .init(kind: .project, uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!),
        ])
    }

    @Test func accountChangeClearsOnlyEngineStateAndLeavesMutationJournal() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        try fixture.store.save(try stateSerialization(base64: "AQ=="))
        let journalURL = fixture.root.appendingPathComponent("mutation-journal")
        let journal = FileSyncMutationJournal(url: journalURL)
        let mutation = SyncMutation.delete(
            .init(kind: .project, uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!),
            mutationID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        )
        try journal.enqueue(mutation)
        let transport = CKSyncEngineTransport(
            zoneID: testZoneID(),
            stateStore: fixture.store,
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        var iterator = transport.events.makeAsyncIterator()
        try await transport.start()

        await transport.receiveAccountChange(previous: "old-user", current: "new-user")

        guard case let .accountChanged(previous, current)? = await iterator.next() else {
            Issue.record("Expected account change event")
            return
        }
        #expect(previous == "old-user")
        #expect(current == "new-user")
        #expect(try fixture.store.load() == nil)
        #expect(try journal.pending() == [mutation])
    }

    @Test func queuesSameRecordMutationsOneAtATimeAndEmitsMatchingIdentities() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let driver = TestSyncEngineDriver()
        let zoneID = testZoneID()
        let transport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            engineFactory: { _, _ in driver }
        )
        var iterator = transport.events.makeAsyncIterator()
        try await transport.start()
        let firstID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let record = try testRecord(uuid: "00000000-0000-0000-0000-000000000010", revision: 1)
        let save = try SyncMutation.save(recordVersion: SyncRecordVersion(record: record), mutationID: firstID)
        let delete = SyncMutation.delete(record.id, mutationID: secondID)
        try await transport.schedule([save, delete])
        let recordID = cloudRecordID(kind: .project, uuid: record.id.uuid.uuidString, zoneID: zoneID)

        #expect(await driver.pendingChanges() == [.saveRecord(recordID)])
        await driver.complete(.saveRecord(recordID))
        await transport.receiveSentChanges(savedRecordIDs: [recordID], deletedRecordIDs: [])
        guard case let .sent(sentRecordID, sentMutationID)? = await iterator.next() else {
            Issue.record("Expected first sent event")
            return
        }
        #expect(sentRecordID == record.id)
        #expect(sentMutationID == firstID)
        #expect(await driver.pendingChanges() == [.deleteRecord(recordID)])

        await driver.complete(.deleteRecord(recordID))
        await transport.receiveSentChanges(savedRecordIDs: [], deletedRecordIDs: [recordID])
        guard case let .sent(deletedRecordID, deletedMutationID)? = await iterator.next() else {
            Issue.record("Expected second sent event")
            return
        }
        #expect(deletedRecordID == record.id)
        #expect(deletedMutationID == secondID)
        #expect(await driver.pendingChanges().isEmpty)
    }

    @Test func restartReschedulingBindsToExistingEnginePendingChangeWithoutDuplicatingIt() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let record = try testRecord(uuid: "00000000-0000-0000-0000-000000000010", revision: 1)
        let recordID = cloudRecordID(kind: .project, uuid: record.id.uuid.uuidString, zoneID: zoneID)
        let driver = TestSyncEngineDriver(initialPending: [.saveRecord(recordID)])
        let transport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            engineFactory: { _, _ in driver }
        )
        try await transport.start()
        let mutation = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: record),
            mutationID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        )

        try await transport.schedule([mutation, mutation])

        #expect(await driver.pendingChanges() == [.saveRecord(recordID)])
        #expect(await driver.addCallCount() == 0)
    }

    @Test func changeBatchFiltersScopeAndCapsRequestsAt250() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let driver = TestSyncEngineDriver()
        let transport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            engineFactory: { _, _ in driver }
        )
        try await transport.start()
        let ids = (0..<251).map { index in
            CKRecord.ID(recordName: "project-\(String(format: "%012d", index))", zoneID: zoneID)
        }
        let changes = ids.map(CKSyncEngine.PendingRecordZoneChange.deleteRecord)

        let allBatch = await transport.recordZoneChangeBatch(
            pendingChanges: changes,
            scope: .all
        )
        #expect(allBatch?.recordIDsToDelete.count == 250)
        #expect(allBatch?.recordIDsToDelete == Array(ids.prefix(250)))

        let scopedIDs = [ids[250], ids[3], ids[200]]
        let scopedBatch = await transport.recordZoneChangeBatch(
            pendingChanges: changes,
            scope: .recordIDs(scopedIDs)
        )
        #expect(scopedBatch?.recordIDsToDelete == [ids[3], ids[200], ids[250]])
    }

    @Test func mapsCloudKitFailuresWithoutStartingCompetingRetries() throws {
        let retry = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 12.5])
        #expect(CloudSyncFailure.map(retry, codec: CloudRecordCodec()) == .retryable(
            code: CKError.Code.requestRateLimited.rawValue,
            retryAfterSeconds: 12.5
        ))
        #expect(CloudSyncFailure.map(CKError(.quotaExceeded), codec: CloudRecordCodec()) == .quotaExceeded)
        #expect(CloudSyncFailure.map(CKError(.invalidArguments), codec: CloudRecordCodec()) == .invalidArguments)

        let server = try CloudRecordCodec().encode(
            testRecord(uuid: "00000000-0000-0000-0000-000000000010", revision: 2),
            zoneID: testZoneID()
        )
        let conflict = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])
        guard case let .serverRecordChanged(recordID, serverRecord) =
                CloudSyncFailure.map(conflict, codec: CloudRecordCodec()) else {
            Issue.record("Expected server-record-changed failure")
            return
        }
        #expect(recordID == serverRecord?.id)
        #expect(serverRecord?.entityRevision == 2)
    }
}

private actor TestSyncEngineDriver: CKSyncEngineDriving {
    nonisolated let cloudKitEngineIdentifier: ObjectIdentifier? = nil
    private var pending: [CKSyncEngine.PendingRecordZoneChange]
    private var additions = 0

    init(initialPending: [CKSyncEngine.PendingRecordZoneChange] = []) {
        pending = initialPending
    }

    func pendingChanges() -> [CKSyncEngine.PendingRecordZoneChange] { pending }

    func add(_ changes: [CKSyncEngine.PendingRecordZoneChange]) {
        additions += 1
        for change in changes where !pending.contains(change) { pending.append(change) }
    }

    func remove(_ changes: [CKSyncEngine.PendingRecordZoneChange]) {
        pending.removeAll { changes.contains($0) }
    }

    func complete(_ change: CKSyncEngine.PendingRecordZoneChange) {
        pending.removeAll { $0 == change }
    }

    func addCallCount() -> Int { additions }

    func fetchChanges(_ options: CKSyncEngine.FetchChangesOptions) async throws {}
    func sendChanges(_ options: CKSyncEngine.SendChangesOptions) async throws {}
    func cancelOperations() async {}
}

private struct StateStoreFixture {
    let root: URL
    let url: URL
    let store: FileCloudSyncEngineStateStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        url = root.appendingPathComponent("engine-state.json")
        store = FileCloudSyncEngineStateStore(url: url)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private struct TestInterruption: Error {}

private func stateSerialization(base64: String) throws -> CKSyncEngine.State.Serialization {
    try JSONDecoder().decode(
        CKSyncEngine.State.Serialization.self,
        from: Data(#"{"data":"\#(base64)"}"#.utf8)
    )
}

private func encodedState(_ state: CKSyncEngine.State.Serialization?) throws -> Data? {
    try state.map { try JSONEncoder().encode($0) }
}

private func testZoneID() -> CKRecordZone.ID {
    CKRecordZone.ID(zoneName: "KnitNoteSync", ownerName: CKCurrentUserDefaultName)
}

private func cloudRecordID(kind: SyncEntityKind, uuid: String, zoneID: CKRecordZone.ID) -> CKRecord.ID {
    CKRecord.ID(recordName: "\(kind.rawValue)-\(uuid.lowercased())", zoneID: zoneID)
}

private func testRecord(uuid: String, revision: UInt64) throws -> SyncRecord {
    let stamp = SyncMutationStamp(
        logicalRevision: revision,
        modifiedAt: Date(timeIntervalSince1970: TimeInterval(revision)),
        deviceID: "device-a"
    )
    return try SyncRecordValidator().validate(SyncRecord(
        schemaVersion: 1,
        id: .init(kind: .project, uuid: UUID(uuidString: uuid)!),
        createdAt: Date(timeIntervalSince1970: 0),
        entityRevision: revision,
        payload: .init(fields: ["title": .init(value: .string("revision-\(revision)"), stamp: stamp)]),
        relationships: [],
        deletedAt: .init(value: nil, stamp: stamp)
    ))
}
