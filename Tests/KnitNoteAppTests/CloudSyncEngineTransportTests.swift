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
        let boundaries = LockedBoundaryRecorder()
        let interrupted = FileCloudSyncEngineStateStore(
            url: fixture.url,
            beforeWriteBoundary: { boundary in
                boundaries.record(boundary)
                if boundary == .beforeRename { throw TestInterruption() }
            }
        )

        #expect(throws: TestInterruption.self) {
            try interrupted.save(second)
        }
        #expect(try Data(contentsOf: fixture.url) == firstBytes)
        #expect(boundaries.values == [.beforeFileSync, .beforeRename])

        boundaries.removeAll()
        let completed = FileCloudSyncEngineStateStore(
            url: fixture.url,
            beforeWriteBoundary: { boundaries.record($0) }
        )
        try completed.save(second)
        let loadedBytes = try encodedState(completed.load())
        let expectedBytes = try encodedState(second)
        #expect(boundaries.values == [.beforeFileSync, .beforeRename, .beforeDirectorySync])
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

    @Test func stateSaveRejectsDestinationSymlinkInsertedAtRenameBoundary() throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        try fixture.store.save(try stateSerialization(base64: "AQ=="))
        let target = fixture.root.appendingPathComponent("decoy")
        let decoyBytes = Data("must remain unchanged".utf8)
        try decoyBytes.write(to: target)
        let racedStore = FileCloudSyncEngineStateStore(
            url: fixture.url,
            beforeWriteBoundary: { boundary in
                guard boundary == .beforeRename else { return }
                try FileManager.default.removeItem(at: fixture.url)
                try FileManager.default.createSymbolicLink(
                    at: fixture.url,
                    withDestinationURL: target
                )
            }
        )

        #expect(throws: CloudSyncEngineStateStoreError.unsafeFile) {
            try racedStore.save(try stateSerialization(base64: "Ag=="))
        }
        #expect(try Data(contentsOf: target) == decoyBytes)
    }

    @Test func stateSaveUsesHeldParentDescriptorAcrossPathSwap() throws {
        let fixture = try StateStoreFixture()
        let movedRoot = fixture.root.appendingPathExtension("held")
        let decoyRoot = fixture.root.appendingPathExtension("decoy")
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: movedRoot)
            try? FileManager.default.removeItem(at: decoyRoot)
        }
        let racedStore = FileCloudSyncEngineStateStore(
            url: fixture.url,
            beforeWriteBoundary: { boundary in
                guard boundary == .beforeRename else { return }
                try FileManager.default.moveItem(at: fixture.root, to: movedRoot)
                try FileManager.default.createDirectory(
                    at: decoyRoot,
                    withIntermediateDirectories: true
                )
                try FileManager.default.createSymbolicLink(
                    at: fixture.root,
                    withDestinationURL: decoyRoot
                )
            }
        )

        try racedStore.save(try stateSerialization(base64: "AQ=="))

        let heldFile = movedRoot.appendingPathComponent(fixture.url.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: heldFile.path))
        #expect(!FileManager.default.fileExists(
            atPath: decoyRoot.appendingPathComponent(fixture.url.lastPathComponent).path
        ))
    }

    @Test func systemFieldsPersistPerAccountAndZoneAndRebuildLaterSave() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let systemStore = FileCloudRecordSystemFieldsStore(
            url: fixture.root.appendingPathComponent("system-fields.json"),
            zoneID: zoneID
        )
        let fetchedDomain = try testRecord(
            uuid: "00000000-0000-0000-0000-000000000040",
            revision: 1
        )
        let fetchedCloud = try CloudRecordCodec().encode(fetchedDomain, zoneID: zoneID)
        fetchedCloud.parent = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "system-parent", zoneID: zoneID),
            action: .none
        )
        let driver = TestSyncEngineDriver()
        let transport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            systemFieldsStore: systemStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in driver }
        )
        try await transport.start()
        await transport.receiveFetchedChanges(records: [fetchedCloud], deletedRecordIDs: [])
        let nextDomain = try testRecord(
            uuid: fetchedDomain.id.uuid.uuidString,
            revision: 2
        )
        let nextMutation = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: nextDomain),
            mutationID: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
        )
        try await transport.schedule([nextMutation])
        try await transport.finishMutationReplay()
        await transport.receiveZoneReady(zoneID)

        let rebuilt = try #require(await transport.recordZoneChangeBatch(
            pendingChanges: [.saveRecord(fetchedCloud.recordID)],
            scope: .all
        )?.recordsToSave.first)

        #expect(rebuilt.parent?.recordID == fetchedCloud.parent?.recordID)
        let loaded = try systemStore.load(
            recordID: fetchedCloud.recordID,
            accountIdentifier: "account-a"
        )
        let stored = try #require(loaded)
        #expect(stored.parent?.recordID == fetchedCloud.parent?.recordID)
        #expect(try systemStore.load(
            recordID: fetchedCloud.recordID,
            accountIdentifier: "account-b"
        ) == nil)
    }

    @Test func systemFieldsTransportRejectsBlankAccountBeforeEngineActivation() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let creations = LockedCounter()
        let transport = CKSyncEngineTransport(
            zoneID: testZoneID(),
            stateStore: fixture.store,
            systemFieldsStore: FileCloudRecordSystemFieldsStore(
                url: fixture.root.appendingPathComponent("system-fields.json"),
                zoneID: testZoneID()
            ),
            initialAccountIdentifier: " \n ",
            engineFactory: { _, _ in
                creations.increment()
                return TestSyncEngineDriver()
            }
        )

        await #expect(throws: CloudSyncTransportError.missingAccountIdentity) {
            try await transport.start()
        }
        #expect(creations.value == 0)
    }

    @Test func sentConflictAndDeleteCallbacksDurablyAdvanceSystemFields() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let accountIdentifier = "account-a"
        let systemStore = FileCloudRecordSystemFieldsStore(
            url: fixture.root.appendingPathComponent("system-fields.json"),
            zoneID: zoneID
        )
        let driver = TestSyncEngineDriver()
        let transport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            systemFieldsStore: systemStore,
            initialAccountIdentifier: accountIdentifier,
            engineFactory: { _, _ in driver }
        )
        try await transport.start()
        let first = try testSaveMutation(revision: 1, mutationSuffix: 41)
        try await transport.schedule([first])
        try await transport.finishMutationReplay()
        await transport.receiveZoneReady(zoneID)
        let recordID = cloudRecordID(
            kind: first.recordID.kind,
            uuid: first.recordID.uuid.uuidString,
            zoneID: zoneID
        )
        let outgoing = try #require(await transport.recordZoneChangeBatch(
            pendingChanges: [.saveRecord(recordID)],
            scope: .all
        )?.recordsToSave.first)
        let saved = CKRecord(recordType: outgoing.recordType, recordID: recordID)
        saved.parent = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "saved-parent", zoneID: zoneID),
            action: .none
        )
        saved["syncMutationID"] = outgoing["syncMutationID"]
        saved["syncAttemptID"] = outgoing["syncAttemptID"]

        await driver.complete(.saveRecord(recordID))
        await transport.receiveSentChanges(savedRecords: [saved], deletedRecordIDs: [])
        #expect(try systemStore.load(
            recordID: recordID,
            accountIdentifier: accountIdentifier
        )?.parent?.recordID == saved.parent?.recordID)

        let second = try testSaveMutation(revision: 2, mutationSuffix: 42)
        try await transport.schedule([second])
        let rebuilt = try #require(await transport.recordZoneChangeBatch(
            pendingChanges: [.saveRecord(recordID)],
            scope: .all
        )?.recordsToSave.first)
        #expect(rebuilt.parent?.recordID == saved.parent?.recordID)

        let server = CKRecord(recordType: rebuilt.recordType, recordID: recordID)
        server.parent = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "conflict-parent", zoneID: zoneID),
            action: .none
        )
        let conflict = CKError(
            .serverRecordChanged,
            userInfo: [CKRecordChangedErrorServerRecordKey: server]
        )
        await transport.receiveFailedSave(rebuilt, error: conflict)
        #expect(try systemStore.load(
            recordID: recordID,
            accountIdentifier: accountIdentifier
        )?.parent?.recordID == server.parent?.recordID)

        let deletion = SyncMutation.delete(
            first.recordID,
            mutationID: UUID(uuidString: "50000000-0000-0000-0000-000000000043")!
        )
        try await transport.resolveFailedMutation(second.mutationID, replacement: deletion)
        let deleteBatch = try #require(await transport.recordZoneChangeBatch(
            pendingChanges: [.deleteRecord(recordID)],
            scope: .all
        ))
        #expect(deleteBatch.recordIDsToDelete == [recordID])
        await driver.complete(.deleteRecord(recordID))
        await transport.receiveSentChanges(savedRecords: [], deletedRecordIDs: [recordID])
        #expect(try systemStore.load(
            recordID: recordID,
            accountIdentifier: accountIdentifier
        ) == nil)
    }

    @Test func systemFieldsStoreRejectsDestinationSymlinks() throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let url = fixture.root.appendingPathComponent("system-fields.json")
        let target = fixture.root.appendingPathComponent("unrelated")
        let original = Data("must remain unchanged".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let store = FileCloudRecordSystemFieldsStore(url: url, zoneID: zoneID)
        let cloudRecord = try CloudRecordCodec().encode(
            testRecord(uuid: "00000000-0000-0000-0000-000000000041", revision: 1),
            zoneID: zoneID
        )

        #expect(throws: CloudRecordSystemFieldsStoreError.unsafeFile) {
            try store.save(cloudRecord, accountIdentifier: "account-a")
        }
        #expect(try Data(contentsOf: target) == original)
    }

    @Test func fetchedDeletionRemovesDurableSystemFieldsBeforeDelivery() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let accountIdentifier = "account-a"
        let systemStore = FileCloudRecordSystemFieldsStore(
            url: fixture.root.appendingPathComponent("system-fields.json"),
            zoneID: zoneID
        )
        let record = try CloudRecordCodec().encode(
            testRecord(uuid: "00000000-0000-0000-0000-000000000042", revision: 1),
            zoneID: zoneID
        )
        try systemStore.save(record, accountIdentifier: accountIdentifier)
        let transport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            systemFieldsStore: systemStore,
            initialAccountIdentifier: accountIdentifier,
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        var iterator = transport.events.makeAsyncIterator()
        try await transport.start()

        await transport.receiveFetchedChanges(records: [], deletedRecordIDs: [record.recordID])

        guard case let .fetched(_, _, deleted)? = await iterator.next() else {
            Issue.record("Expected fetched deletion")
            return
        }
        #expect(deleted == [CKSyncEngineTransport.entityID(for: record.recordID)!])
        #expect(try systemStore.load(
            recordID: record.recordID,
            accountIdentifier: accountIdentifier
        ) == nil)
    }

    @Test func fetchedSaveStoreFailureEmitsNoAcknowledgeableBatchAndBlocksState() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let systemFieldsURL = fixture.root.appendingPathComponent("system-fields.json")
        let decoy = fixture.root.appendingPathComponent("decoy")
        try Data("unrelated".utf8).write(to: decoy)
        try FileManager.default.createSymbolicLink(
            at: systemFieldsURL,
            withDestinationURL: decoy
        )
        let transport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            systemFieldsStore: FileCloudRecordSystemFieldsStore(
                url: systemFieldsURL,
                zoneID: zoneID
            ),
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        var iterator = transport.events.makeAsyncIterator()
        try await transport.start()
        let record = try CloudRecordCodec().encode(
            testRecord(uuid: "00000000-0000-0000-0000-000000000043", revision: 1),
            zoneID: zoneID
        )

        await transport.receiveFetchedChanges(records: [record], deletedRecordIDs: [])

        guard case .failed(.statePersistence)? = await iterator.next() else {
            Issue.record("Expected system-field durability failure")
            return
        }
        await transport.receiveZoneReady(zoneID)
        guard case .zoneReady? = await iterator.next() else {
            Issue.record("A failed fetched save must not emit an acknowledgeable batch")
            return
        }
        await transport.receiveStateUpdate(try stateSerialization(base64: "AQ=="))
        #expect(try fixture.store.load() == nil)
    }

    @Test func fetchedDeleteStoreFailureEmitsNoAcknowledgeableBatchAndBlocksState() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let systemFieldsURL = fixture.root.appendingPathComponent("system-fields.json")
        let systemStore = FileCloudRecordSystemFieldsStore(
            url: systemFieldsURL,
            zoneID: zoneID
        )
        let record = try CloudRecordCodec().encode(
            testRecord(uuid: "00000000-0000-0000-0000-000000000044", revision: 1),
            zoneID: zoneID
        )
        try systemStore.save(record, accountIdentifier: "account-a")
        let decoy = fixture.root.appendingPathComponent("decoy-system-fields.json")
        try FileManager.default.moveItem(at: systemFieldsURL, to: decoy)
        try FileManager.default.createSymbolicLink(
            at: systemFieldsURL,
            withDestinationURL: decoy
        )
        let transport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            systemFieldsStore: systemStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        var iterator = transport.events.makeAsyncIterator()
        try await transport.start()

        await transport.receiveFetchedChanges(records: [], deletedRecordIDs: [record.recordID])

        guard case .failed(.statePersistence)? = await iterator.next() else {
            Issue.record("Expected system-field deletion durability failure")
            return
        }
        await transport.receiveZoneReady(zoneID)
        guard case .zoneReady? = await iterator.next() else {
            Issue.record("A failed fetched deletion must not emit an acknowledgeable batch")
            return
        }
        await transport.receiveStateUpdate(try stateSerialization(base64: "Ag=="))
        #expect(try fixture.store.load() == nil)
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

        guard case let .fetched(_, receivedRecords, receivedDeleted)? = await iterator.next() else {
            Issue.record("Expected fetched event")
            return
        }
        #expect(receivedRecords.map(\.id) == records.map(\.id))
        #expect(receivedDeleted == [
            .init(kind: .yarn, uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!),
            .init(kind: .project, uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!),
        ])
    }

    @Test func stateUpdateWaitsForExplicitFetchedBatchAcknowledgement() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let transport = CKSyncEngineTransport(
            zoneID: testZoneID(),
            stateStore: fixture.store,
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        var iterator = transport.events.makeAsyncIterator()
        try await transport.start()
        await transport.receiveFetchedChanges(records: [], deletedRecordIDs: [])
        guard case let .fetched(batchID, _, _)? = await iterator.next() else {
            Issue.record("Expected identified fetched batch")
            return
        }
        let serialization = try stateSerialization(base64: "AQ==")

        await transport.receiveStateUpdate(serialization)

        #expect(try fixture.store.load() == nil)
        try await transport.acknowledgeFetchedBatch(batchID)
        #expect(try encodedState(fixture.store.load()) == encodedState(serialization))
    }

    @Test func stateUpdateRemainsBehindOldestFetchedBatchWhenAcknowledgedOutOfOrder() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let transport = CKSyncEngineTransport(
            zoneID: testZoneID(),
            stateStore: fixture.store,
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        var iterator = transport.events.makeAsyncIterator()
        try await transport.start()
        await transport.receiveFetchedChanges(records: [], deletedRecordIDs: [])
        guard case let .fetched(firstBatchID, _, _)? = await iterator.next() else {
            Issue.record("Expected first identified fetched batch")
            return
        }
        let firstState = try stateSerialization(base64: "AQ==")
        await transport.receiveStateUpdate(firstState)
        await transport.receiveFetchedChanges(records: [], deletedRecordIDs: [])
        guard case let .fetched(secondBatchID, _, _)? = await iterator.next() else {
            Issue.record("Expected second identified fetched batch")
            return
        }
        let secondState = try stateSerialization(base64: "Ag==")
        await transport.receiveStateUpdate(secondState)

        try await transport.acknowledgeFetchedBatch(secondBatchID)
        #expect(try fixture.store.load() == nil)
        try await transport.acknowledgeFetchedBatch(firstBatchID)
        #expect(try encodedState(fixture.store.load()) == encodedState(secondState))
    }

    @Test func streamTerminationCancelsEngineWithoutPersistingHeldFetchedState() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let driver = TestSyncEngineDriver()
        let transport = CKSyncEngineTransport(
            zoneID: testZoneID(),
            stateStore: fixture.store,
            engineFactory: { _, _ in driver }
        )
        let consumer = Task {
            for await _ in transport.events {}
        }
        try await transport.start()
        await transport.receiveFetchedChanges(records: [], deletedRecordIDs: [])
        await transport.receiveStateUpdate(try stateSerialization(base64: "AQ=="))

        consumer.cancel()
        await driver.waitUntilCancelled()

        #expect(try fixture.store.load() == nil)
    }

    @Test func terminatedStreamCannotRestartOrScheduleWhileCleanupIsSuspended() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let driver = TestSyncEngineDriver()
        let transport = CKSyncEngineTransport(
            zoneID: testZoneID(),
            stateStore: fixture.store,
            engineFactory: { _, _ in driver }
        )
        let consumer = Task {
            for await _ in transport.events {}
        }
        try await transport.start()
        await driver.suspendNextCancellation()

        consumer.cancel()
        await driver.waitUntilCancellationSuspended()

        await #expect(throws: CloudSyncTransportError.terminated) {
            try await transport.start()
        }
        let mutation = SyncMutation.delete(
            .init(
                kind: .project,
                uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000052")!
            ),
            mutationID: UUID(uuidString: "60000000-0000-0000-0000-000000000003")!
        )
        await #expect(throws: CloudSyncTransportError.terminated) {
            try await transport.schedule([mutation])
        }

        await driver.resumeCancellation()
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

    @Test func accountChangeDetachesEngineBeforeSuspendedCancellationCompletes() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let driver = TestSyncEngineDriver()
        await driver.suspendNextCancellation()
        let transport = CKSyncEngineTransport(
            zoneID: testZoneID(),
            stateStore: fixture.store,
            engineFactory: { _, _ in driver }
        )
        try await transport.start()
        let reset = Task {
            await transport.receiveAccountChange(previous: "account-a", current: "account-b")
        }
        await driver.waitUntilCancellationSuspended()
        let mutation = SyncMutation.delete(
            .init(
                kind: .project,
                uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000050")!
            ),
            mutationID: UUID(uuidString: "60000000-0000-0000-0000-000000000001")!
        )

        await #expect(throws: CloudSyncTransportError.notStarted) {
            try await transport.schedule([mutation])
        }
        await driver.resumeCancellation()
        await reset.value
        #expect(await driver.pendingChanges().isEmpty)
    }

    @Test func scheduleSuspendedOnOldEngineCannotResumeAfterAccountGenerationChanges() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let driver = TestSyncEngineDriver()
        let transport = CKSyncEngineTransport(
            zoneID: testZoneID(),
            stateStore: fixture.store,
            engineFactory: { _, _ in driver }
        )
        try await transport.start()
        await driver.suspendNextPendingRead()
        let mutation = SyncMutation.delete(
            .init(
                kind: .project,
                uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000051")!
            ),
            mutationID: UUID(uuidString: "60000000-0000-0000-0000-000000000002")!
        )
        let scheduling = Task { try await transport.schedule([mutation]) }
        await driver.waitUntilPendingReadSuspended()

        await transport.receiveAccountChange(previous: "account-a", current: "account-b")
        await driver.resumePendingRead()

        await #expect(throws: CloudSyncTransportError.staleOperation) {
            try await scheduling.value
        }
        #expect(await driver.pendingChanges().isEmpty)
    }

    @Test func failedAccountStateClearBlocksRestartEvenAfterPathIsRepaired() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        try fixture.store.save(try stateSerialization(base64: "AQ=="))
        try FileManager.default.removeItem(at: fixture.url)
        let target = fixture.root.appendingPathComponent("unsafe-target")
        try Data("unsafe".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.url, withDestinationURL: target)
        let transport = CKSyncEngineTransport(
            zoneID: testZoneID(),
            stateStore: fixture.store,
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )

        await transport.receiveAccountChange(previous: "account-a", current: "account-b")
        try FileManager.default.removeItem(at: fixture.url)

        await #expect(throws: CloudSyncTransportError.accountResetIncomplete) {
            try await transport.start()
        }
    }

    @Test func batchSuspendedDuringRecordMaterializationReturnsNilAfterAccountReset() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let driver = TestSyncEngineDriver()
        let materializer = SuspendingRecordMaterializer(zoneID: testZoneID())
        let transport = CKSyncEngineTransport(
            zoneID: testZoneID(),
            stateStore: fixture.store,
            recordMaterializer: { mutation, baseRecord in
                try await materializer.materialize(mutation, baseRecord: baseRecord)
            },
            engineFactory: { _, _ in driver }
        )
        try await transport.start()
        let mutation = try testSaveMutation(revision: 1, mutationSuffix: 31)
        try await transport.schedule([mutation])
        try await transport.finishMutationReplay()
        await transport.receiveZoneReady(testZoneID())
        await materializer.suspendNextMaterialization()
        let recordID = cloudRecordID(
            kind: mutation.recordID.kind,
            uuid: mutation.recordID.uuid.uuidString,
            zoneID: testZoneID()
        )
        let batching = Task {
            await transport.recordZoneChangeBatch(
                pendingChanges: [.saveRecord(recordID)],
                scope: .all
            )
        }
        await materializer.waitUntilSuspended()

        await transport.receiveAccountChange(previous: "account-a", current: "account-b")
        await materializer.resume()

        #expect(await batching.value == nil)
    }

    @Test func batchSuspendedDuringMaterializationReturnsNilAfterZoneDeletion() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let driver = TestSyncEngineDriver()
        let materializer = SuspendingRecordMaterializer(zoneID: testZoneID())
        let transport = CKSyncEngineTransport(
            zoneID: testZoneID(),
            stateStore: fixture.store,
            recordMaterializer: { mutation, baseRecord in
                try await materializer.materialize(mutation, baseRecord: baseRecord)
            },
            engineFactory: { _, _ in driver }
        )
        try await transport.start()
        let mutation = try testSaveMutation(revision: 1, mutationSuffix: 32)
        try await transport.schedule([mutation])
        try await transport.finishMutationReplay()
        await transport.receiveZoneReady(testZoneID())
        await materializer.suspendNextMaterialization()
        let recordID = cloudRecordID(
            kind: mutation.recordID.kind,
            uuid: mutation.recordID.uuid.uuidString,
            zoneID: testZoneID()
        )
        let batching = Task {
            await transport.recordZoneChangeBatch(
                pendingChanges: [.saveRecord(recordID)],
                scope: .all
            )
        }
        await materializer.waitUntilSuspended()

        await transport.receiveDeletedZones([testZoneID()])
        await materializer.resume()

        #expect(await batching.value == nil)
    }

    @Test func olderSuspendedBatchCannotOverwriteNewerActiveAttempt() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let driver = TestSyncEngineDriver()
        let materializer = SuspendingRecordMaterializer(zoneID: testZoneID())
        let transport = CKSyncEngineTransport(
            zoneID: testZoneID(),
            stateStore: fixture.store,
            recordMaterializer: { mutation, baseRecord in
                try await materializer.materialize(mutation, baseRecord: baseRecord)
            },
            engineFactory: { _, _ in driver }
        )
        try await transport.start()
        let mutation = try testSaveMutation(revision: 1, mutationSuffix: 33)
        try await transport.schedule([mutation])
        try await transport.finishMutationReplay()
        await transport.receiveZoneReady(testZoneID())
        await materializer.suspendNextMaterialization()
        let recordID = cloudRecordID(
            kind: mutation.recordID.kind,
            uuid: mutation.recordID.uuid.uuidString,
            zoneID: testZoneID()
        )
        let olderBatch = Task {
            await transport.recordZoneChangeBatch(
                pendingChanges: [.saveRecord(recordID)],
                scope: .all
            )
        }
        await materializer.waitUntilSuspended()

        let newerBatch = await transport.recordZoneChangeBatch(
            pendingChanges: [.saveRecord(recordID)],
            scope: .all
        )
        #expect(newerBatch?.recordsToSave.count == 1)
        await materializer.resume()

        #expect(await olderBatch.value == nil)
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
        try await transport.finishMutationReplay()
        await transport.receiveZoneReady(zoneID)
        _ = await iterator.next()

        #expect(await driver.pendingChanges() == [.saveRecord(recordID)])
        let savedRecord = try #require(await transport.recordZoneChangeBatch(
            pendingChanges: await driver.pendingChanges(),
            scope: .all
        )?.recordsToSave.first)
        await driver.complete(.saveRecord(recordID))
        await transport.receiveSentChanges(savedRecords: [savedRecord], deletedRecordIDs: [])
        guard case let .sent(sentRecordID, sentMutationID)? = await iterator.next() else {
            Issue.record("Expected first sent event")
            return
        }
        #expect(sentRecordID == record.id)
        #expect(sentMutationID == firstID)
        #expect(await driver.pendingChanges() == [.deleteRecord(recordID)])

        _ = await transport.recordZoneChangeBatch(
            pendingChanges: await driver.pendingChanges(),
            scope: .all
        )
        await driver.complete(.deleteRecord(recordID))
        await transport.receiveSentChanges(savedRecords: [], deletedRecordIDs: [recordID])
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

    @Test func restoredOrphanDeleteCannotBatchUntilJournalReplayBindsItAndZoneIsReady() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let entityID = SyncEntityID(
            kind: .project,
            uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        )
        let recordID = cloudRecordID(kind: entityID.kind, uuid: entityID.uuid.uuidString, zoneID: zoneID)
        let restored = CKSyncEngine.PendingRecordZoneChange.deleteRecord(recordID)
        let driver = TestSyncEngineDriver(initialPending: [restored])
        let transport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            engineFactory: { _, _ in driver }
        )
        try await transport.start()

        #expect(await transport.recordZoneChangeBatch(pendingChanges: [restored], scope: .all) == nil)
        try await transport.schedule([.delete(
            entityID,
            mutationID: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        )])
        #expect(await transport.recordZoneChangeBatch(pendingChanges: [restored], scope: .all) == nil)

        try await transport.finishMutationReplay()
        #expect(await transport.recordZoneChangeBatch(pendingChanges: [restored], scope: .all) == nil)
        await transport.receiveZoneReady(zoneID)
        let batch = await transport.recordZoneChangeBatch(pendingChanges: [restored], scope: .all)
        #expect(batch?.recordIDsToDelete == [recordID])
    }

    @Test func finishingJournalReplayTriggersOneConfiguredZoneSend() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let foreignZone = CKRecordZone.ID(
            zoneName: "Foreign",
            ownerName: CKCurrentUserDefaultName
        )
        let entityID = SyncEntityID(
            kind: .project,
            uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        )
        let recordID = cloudRecordID(
            kind: entityID.kind,
            uuid: entityID.uuid.uuidString,
            zoneID: zoneID
        )
        let driver = TestSyncEngineDriver(initialPending: [.deleteRecord(recordID)])
        let transport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            engineFactory: { _, _ in driver }
        )
        try await transport.start()
        try await transport.schedule([.delete(
            entityID,
            mutationID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        )])

        try await transport.finishMutationReplay()

        #expect(await driver.sendCallCount() == 1)
        #expect(await driver.lastSendScopeContains(zoneID))
        #expect(!(await driver.lastSendScopeContains(foreignZone)))
    }

    @Test func startBootstrapsOnlyConfiguredZoneAndPublishesZoneLifecycle() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let driver = TestSyncEngineDriver()
        let zoneID = testZoneID()
        let foreignZone = CKRecordZone.ID(
            zoneName: "Foreign",
            ownerName: CKCurrentUserDefaultName
        )
        let transport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            engineFactory: { _, _ in driver }
        )
        var iterator = transport.events.makeAsyncIterator()

        try await transport.start()

        #expect(await driver.pendingDatabaseChanges() == [.saveZone(CKRecordZone(zoneID: zoneID))])
        let options = await transport.configuredFetchOptions(from: .init(scope: .all))
        #expect(options.scope.contains(zoneID))
        #expect(!options.scope.contains(foreignZone))

        await transport.receiveZoneReady(zoneID)
        guard case .zoneReady? = await iterator.next() else {
            Issue.record("Expected configured-zone ready event")
            return
        }
        #expect(await driver.sendCallCount() == 1)
        await transport.receiveZoneReady(zoneID)
        #expect(await driver.sendCallCount() == 1)
        await transport.receiveDeletedZones([foreignZone, zoneID])
        guard case .zoneDeleted? = await iterator.next() else {
            Issue.record("Expected configured-zone deleted event")
            return
        }
    }

    @Test func zoneDeletionClearsBasesRequeuesZoneAndKeepsRecordsGated() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let accountIdentifier = "account-a"
        let systemStore = FileCloudRecordSystemFieldsStore(
            url: fixture.root.appendingPathComponent("system-fields.json"),
            zoneID: zoneID
        )
        let driver = TestSyncEngineDriver()
        let transport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            systemFieldsStore: systemStore,
            initialAccountIdentifier: accountIdentifier,
            engineFactory: { _, _ in driver }
        )
        try await transport.start()
        let zoneSave = CKSyncEngine.PendingDatabaseChange.saveZone(CKRecordZone(zoneID: zoneID))
        await driver.completeDatabaseChange(zoneSave)
        await transport.receiveZoneReady(zoneID)
        let mutation = try testSaveMutation(revision: 1, mutationSuffix: 61)
        let savedVersion = try #require(mutation.savedRecordVersion)
        let record = try CloudRecordCodec().encode(
            savedVersion.record,
            zoneID: zoneID
        )
        try systemStore.save(record, accountIdentifier: accountIdentifier)
        try await transport.schedule([mutation])
        try await transport.finishMutationReplay()
        let sendsBeforeDeletion = await driver.sendCallCount()

        await transport.receiveDeletedZones([zoneID])

        #expect(try systemStore.load(
            recordID: record.recordID,
            accountIdentifier: accountIdentifier
        ) == nil)
        #expect(await driver.pendingDatabaseChanges() == [zoneSave])
        #expect(await driver.sendCallCount() == sendsBeforeDeletion + 1)
        #expect(await transport.recordZoneChangeBatch(
            pendingChanges: [.saveRecord(record.recordID)],
            scope: .all
        ) == nil)
    }

    @Test func deleteCycleGateReopeningKicksExactlyOneScopedSend() async throws {
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
        let save = try testSaveMutation(revision: 1, mutationSuffix: 62)
        let deletion = SyncMutation.delete(
            save.recordID,
            mutationID: UUID(uuidString: "40000000-0000-0000-0000-000000000063")!
        )
        try await transport.schedule([save, deletion])
        try await transport.finishMutationReplay()
        await transport.receiveZoneReady(zoneID)
        let recordID = cloudRecordID(
            kind: save.recordID.kind,
            uuid: save.recordID.uuid.uuidString,
            zoneID: zoneID
        )
        let savedRecord = try #require(await transport.recordZoneChangeBatch(
            pendingChanges: [.saveRecord(recordID)],
            scope: .all
        )?.recordsToSave.first)
        await driver.complete(.saveRecord(recordID))
        await transport.receiveSentChanges(savedRecords: [savedRecord], deletedRecordIDs: [])
        _ = await transport.recordZoneChangeBatch(
            pendingChanges: [.deleteRecord(recordID)],
            scope: .all
        )
        await driver.complete(.deleteRecord(recordID))
        await transport.receiveSentChanges(savedRecords: [], deletedRecordIDs: [recordID])
        let sendsBeforeReopening = await driver.sendCallCount()

        await transport.receiveSendCycleCompleted()

        #expect(await driver.sendCallCount() == sendsBeforeReopening + 1)
        await transport.receiveSendCycleCompleted()
        #expect(await driver.sendCallCount() == sendsBeforeReopening + 1)
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
            cloudRecordID(
                kind: .project,
                uuid: String(format: "00000000-0000-0000-0000-%012d", index),
                zoneID: zoneID
            )
        }
        let changes = ids.map(CKSyncEngine.PendingRecordZoneChange.deleteRecord)
        let mutations = ids.enumerated().map { index, recordID in
            SyncMutation.delete(
                CKSyncEngineTransport.entityID(for: recordID)!,
                mutationID: UUID(uuidString: String(
                    format: "30000000-0000-0000-0000-%012d",
                    index
                ))!
            )
        }
        try await transport.schedule(mutations)
        try await transport.finishMutationReplay()
        await transport.receiveZoneReady(zoneID)

        let allBatch = await transport.recordZoneChangeBatch(
            pendingChanges: changes,
            scope: .all
        )
        #expect(allBatch?.recordIDsToDelete.count == 250)
        #expect(allBatch?.recordIDsToDelete == Array(ids.prefix(250)))

        let scopedFixture = try StateStoreFixture()
        defer { scopedFixture.remove() }
        let scopedDriver = TestSyncEngineDriver()
        let scopedTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: scopedFixture.store,
            engineFactory: { _, _ in scopedDriver }
        )
        try await scopedTransport.start()
        try await scopedTransport.schedule(mutations)
        try await scopedTransport.finishMutationReplay()
        await scopedTransport.receiveZoneReady(zoneID)
        let scopedIDs = [ids[250], ids[3], ids[200]]
        let scopedBatch = await scopedTransport.recordZoneChangeBatch(
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
        let temporarilyUnavailable = CKError(.accountTemporarilyUnavailable)
        #expect(CloudSyncFailure.map(temporarilyUnavailable, codec: CloudRecordCodec()) == .retryable(
            code: CKError.Code.accountTemporarilyUnavailable.rawValue,
            retryAfterSeconds: nil
        ))
    }

    @Test func duplicateSavedRecordCallbackCannotAcknowledgeSameIntentSuccessor() async throws {
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
        let first = try testSaveMutation(revision: 1, mutationSuffix: 1)
        let second = try testSaveMutation(revision: 2, mutationSuffix: 2)
        let third = SyncMutation.delete(
            first.recordID,
            mutationID: UUID(uuidString: "40000000-0000-0000-0000-000000000003")!
        )
        try await transport.schedule([first, second, third])
        try await transport.finishMutationReplay()
        await transport.receiveZoneReady(zoneID)
        _ = await iterator.next()
        let recordID = cloudRecordID(
            kind: first.recordID.kind,
            uuid: first.recordID.uuid.uuidString,
            zoneID: zoneID
        )

        let firstBatch = await transport.recordZoneChangeBatch(
            pendingChanges: [.saveRecord(recordID)],
            scope: .all
        )!
        let firstReturnedRecord = try #require(firstBatch.recordsToSave.first)
        #expect(firstReturnedRecord["syncMutationID"] as? String == first.mutationID.uuidString.lowercased())
        await driver.complete(.saveRecord(recordID))
        await transport.receiveSentChanges(savedRecords: [firstReturnedRecord], deletedRecordIDs: [])
        guard case let .sent(_, firstID)? = await iterator.next() else {
            Issue.record("Expected first send acknowledgement")
            return
        }
        #expect(firstID == first.mutationID)

        let secondBatch = await transport.recordZoneChangeBatch(
            pendingChanges: await driver.pendingChanges(),
            scope: .all
        )!
        let secondReturnedRecord = try #require(secondBatch.recordsToSave.first)
        await transport.receiveSentChanges(savedRecords: [firstReturnedRecord], deletedRecordIDs: [])

        #expect(await driver.pendingChanges() == [.saveRecord(recordID)])
        await driver.complete(.saveRecord(recordID))
        await transport.receiveSentChanges(savedRecords: [secondReturnedRecord], deletedRecordIDs: [])
        guard case let .sent(_, secondID)? = await iterator.next() else {
            Issue.record("Expected second send acknowledgement")
            return
        }
        #expect(secondID == second.mutationID)
        #expect(await driver.pendingChanges() == [.deleteRecord(recordID)])
    }

    @Test func duplicateSaveAndDeleteCallbacksCannotConsumeSaveDeleteSaveSuccessors() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let driver = TestSyncEngineDriver()
        let zoneID = testZoneID()
        let transport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            engineFactory: { _, _ in driver }
        )
        try await transport.start()
        let first = try testSaveMutation(revision: 1, mutationSuffix: 11)
        let deletion = SyncMutation.delete(
            first.recordID,
            mutationID: UUID(uuidString: "40000000-0000-0000-0000-000000000012")!
        )
        let third = try testSaveMutation(revision: 3, mutationSuffix: 13)
        try await transport.schedule([first, deletion, third])
        try await transport.finishMutationReplay()
        await transport.receiveZoneReady(zoneID)
        let recordID = cloudRecordID(
            kind: first.recordID.kind,
            uuid: first.recordID.uuid.uuidString,
            zoneID: zoneID
        )

        let firstRecord = try #require(await transport.recordZoneChangeBatch(
            pendingChanges: [.saveRecord(recordID)],
            scope: .all
        )?.recordsToSave.first)
        await driver.complete(.saveRecord(recordID))
        await transport.receiveSentChanges(savedRecords: [firstRecord], deletedRecordIDs: [])
        _ = await transport.recordZoneChangeBatch(
            pendingChanges: await driver.pendingChanges(),
            scope: .all
        )
        await driver.complete(.deleteRecord(recordID))
        await transport.receiveSentChanges(savedRecords: [], deletedRecordIDs: [recordID])

        await transport.receiveSentChanges(savedRecords: [], deletedRecordIDs: [recordID])
        await transport.receiveSentChanges(savedRecords: [firstRecord], deletedRecordIDs: [])
        #expect(await driver.pendingChanges() == [.saveRecord(recordID)])
    }

    @Test func nonretryableFailedHeadRequiresIdentifiedResolutionWhileTransientFailureRemainsPending() async throws {
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
        let first = try testSaveMutation(revision: 1, mutationSuffix: 21)
        try await transport.schedule([first])
        try await transport.finishMutationReplay()
        await transport.receiveZoneReady(zoneID)
        _ = await iterator.next()
        let recordID = cloudRecordID(
            kind: first.recordID.kind,
            uuid: first.recordID.uuid.uuidString,
            zoneID: zoneID
        )
        let firstRecord = try #require(await transport.recordZoneChangeBatch(
            pendingChanges: [.saveRecord(recordID)],
            scope: .all
        )?.recordsToSave.first)

        await transport.receiveFailedSave(firstRecord, error: CKError(.invalidArguments))
        guard case let .mutationFailed(_, failedID, .invalidArguments)? = await iterator.next() else {
            Issue.record("Expected identified permanent head failure")
            return
        }
        #expect(failedID == first.mutationID)
        #expect(await transport.recordZoneChangeBatch(
            pendingChanges: [.saveRecord(recordID)],
            scope: .all
        ) == nil)

        let replacement = try testSaveMutation(revision: 2, mutationSuffix: 22)
        let sendsBeforeResolution = await driver.sendCallCount()
        try await transport.resolveFailedMutation(first.mutationID, replacement: replacement)
        #expect(await driver.sendCallCount() == sendsBeforeResolution + 1)
        let replacementRecord = try #require(await transport.recordZoneChangeBatch(
            pendingChanges: [.saveRecord(recordID)],
            scope: .all
        )?.recordsToSave.first)
        #expect(replacementRecord["syncMutationID"] as? String == replacement.mutationID.uuidString.lowercased())

        await transport.receiveFailedSave(
            replacementRecord,
            error: CKError(.accountTemporarilyUnavailable)
        )
        guard case let .failed(.retryable(code, _))? = await iterator.next() else {
            Issue.record("Expected retryable transport failure")
            return
        }
        #expect(code == CKError.Code.accountTemporarilyUnavailable.rawValue)
        #expect(await transport.recordZoneChangeBatch(
            pendingChanges: [.saveRecord(recordID)],
            scope: .all
        ) != nil)
    }

    @Test func retiringFailedHeadRemovesItsEnginePendingChange() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let driver = TestSyncEngineDriver()
        let zoneID = testZoneID()
        let transport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            engineFactory: { _, _ in driver }
        )
        try await transport.start()
        let mutation = try testSaveMutation(revision: 1, mutationSuffix: 51)
        try await transport.schedule([mutation])
        try await transport.finishMutationReplay()
        await transport.receiveZoneReady(zoneID)
        let recordID = cloudRecordID(
            kind: mutation.recordID.kind,
            uuid: mutation.recordID.uuid.uuidString,
            zoneID: zoneID
        )
        let outgoing = try #require(await transport.recordZoneChangeBatch(
            pendingChanges: [.saveRecord(recordID)],
            scope: .all
        )?.recordsToSave.first)
        await transport.receiveFailedSave(outgoing, error: CKError(.invalidArguments))

        try await transport.resolveFailedMutation(mutation.mutationID, replacement: nil)

        #expect(await driver.pendingChanges().isEmpty)
    }
}

private actor TestSyncEngineDriver: CKSyncEngineDriving {
    nonisolated let cloudKitEngineIdentifier: ObjectIdentifier? = nil
    private var pending: [CKSyncEngine.PendingRecordZoneChange]
    private var additions = 0
    private var databasePending: [CKSyncEngine.PendingDatabaseChange] = []
    private var cancellationCount = 0
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldSuspendPendingRead = false
    private var pendingReadEnteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingReadResume: CheckedContinuation<Void, Never>?
    private var shouldSuspendCancellation = false
    private var cancellationEnteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationResume: CheckedContinuation<Void, Never>?
    private var sendScopes: [CKSyncEngine.SendChangesOptions.Scope] = []

    init(initialPending: [CKSyncEngine.PendingRecordZoneChange] = []) {
        pending = initialPending
    }

    func pendingChanges() async -> [CKSyncEngine.PendingRecordZoneChange] {
        if shouldSuspendPendingRead {
            shouldSuspendPendingRead = false
            let waiters = pendingReadEnteredWaiters
            pendingReadEnteredWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { pendingReadResume = $0 }
        }
        return pending
    }

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

    func pendingDatabaseChanges() -> [CKSyncEngine.PendingDatabaseChange] { databasePending }

    func addDatabaseChanges(_ changes: [CKSyncEngine.PendingDatabaseChange]) {
        for change in changes where !databasePending.contains(change) {
            databasePending.append(change)
        }
    }

    func removeDatabaseChanges(_ changes: [CKSyncEngine.PendingDatabaseChange]) {
        databasePending.removeAll { changes.contains($0) }
    }

    func completeDatabaseChange(_ change: CKSyncEngine.PendingDatabaseChange) {
        databasePending.removeAll { $0 == change }
    }

    func fetchChanges(_ options: CKSyncEngine.FetchChangesOptions) async throws {}
    func sendChanges(_ options: CKSyncEngine.SendChangesOptions) async throws {
        sendScopes.append(options.scope)
    }
    func sendCallCount() -> Int { sendScopes.count }
    func lastSendScopeContains(_ zoneID: CKRecordZone.ID) -> Bool {
        sendScopes.last?.contains(CKRecord.ID(recordName: "scope-probe", zoneID: zoneID)) ?? false
    }
    func cancelOperations() async {
        if shouldSuspendCancellation {
            shouldSuspendCancellation = false
            let enteredWaiters = cancellationEnteredWaiters
            cancellationEnteredWaiters.removeAll()
            for waiter in enteredWaiters { waiter.resume() }
            await withCheckedContinuation { cancellationResume = $0 }
        }
        cancellationCount += 1
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilCancelled() async {
        guard cancellationCount == 0 else { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    func suspendNextPendingRead() { shouldSuspendPendingRead = true }

    func waitUntilPendingReadSuspended() async {
        guard shouldSuspendPendingRead || pendingReadResume == nil else { return }
        await withCheckedContinuation { pendingReadEnteredWaiters.append($0) }
    }

    func resumePendingRead() {
        pendingReadResume?.resume()
        pendingReadResume = nil
    }

    func suspendNextCancellation() { shouldSuspendCancellation = true }

    func waitUntilCancellationSuspended() async {
        guard shouldSuspendCancellation || cancellationResume == nil else { return }
        await withCheckedContinuation { cancellationEnteredWaiters.append($0) }
    }

    func resumeCancellation() {
        cancellationResume?.resume()
        cancellationResume = nil
    }
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

private final class LockedBoundaryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SyncDurableFileWriteBoundary] = []

    var values: [SyncDurableFileWriteBoundary] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ boundary: SyncDurableFileWriteBoundary) {
        lock.lock()
        storage.append(boundary)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private actor SuspendingRecordMaterializer {
    private let zoneID: CKRecordZone.ID
    private var shouldSuspend = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    init(zoneID: CKRecordZone.ID) {
        self.zoneID = zoneID
    }

    func suspendNextMaterialization() { shouldSuspend = true }

    func materialize(_ mutation: SyncMutation, baseRecord: CKRecord?) async throws -> CKRecord {
        if shouldSuspend {
            shouldSuspend = false
            let waiters = enteredWaiters
            enteredWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { resumeContinuation = $0 }
        }
        guard case let .save(save) = mutation else {
            throw CloudSyncTransportError.invalidReplacement
        }
        return try CloudRecordCodec().encode(save.recordVersion.record, zoneID: zoneID)
    }

    func waitUntilSuspended() async {
        guard shouldSuspend || resumeContinuation == nil else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

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

private func testSaveMutation(revision: UInt64, mutationSuffix: Int) throws -> SyncMutation {
    try SyncMutation.save(
        recordVersion: SyncRecordVersion(record: testRecord(
            uuid: "00000000-0000-0000-0000-000000000030",
            revision: revision
        )),
        mutationID: UUID(uuidString: String(
            format: "40000000-0000-0000-0000-%012d",
            mutationSuffix
        ))!
    )
}
