import CloudKit
import CryptoKit
import Foundation
import Testing
@testable import KnitNote

@Suite struct CloudSyncEngineTransportTests {
    // Current-fetch observation must retain the existing exact ACK authority
    // across deduplication; an invented empty envelope is not that authority.
    @Test(arguments: [false, true])
    func receiptForAcknowledgedRedeliveryUsesOriginalBatch(populated: Bool) async throws {
        try await withReceiptRedeliveryFixture(populated: populated, acknowledged: true) { f in
            let request = UUID()
            try await f.reopened.fetchNow(completionID: request)
            let receipt = try await f.reopened.committedFetchReceipt(requestID: request)
            #expect(receipt.batchIDs == [f.batchID])
            try receipt.epoch.requireCurrent()
            let cancelled = await f.reopened.invalidateForAccountTransition()
            await cancelled?.value
            #expect(throws: CloudSyncAccountEpochError.stale) { try receipt.epoch.requireCurrent() }
        }
    }

    @Test func receiptForUnacknowledgedRedeliveryWaitsForActualAcknowledgement() async throws {
        try await withReceiptRedeliveryFixture(populated: true, acknowledged: false) { f in
            let request = UUID()
            try await f.reopened.fetchNow(completionID: request)
            await #expect(throws: CloudSyncTransportError.unknownFetchedBatch) {
                try await f.reopened.committedFetchReceipt(requestID: request)
            }
            try await f.reopened.acknowledgeFetchedBatch(f.batchID)
            let receipt = try await f.reopened.committedFetchReceipt(requestID: request)
            #expect(receipt.batchIDs == [f.batchID])
        }
    }

    @Test func acknowledgedPartialRedeliveryCannotAuthorizeReceipt() async throws {
        try await withReceiptRedeliveryFixture(populated: true, acknowledged: true) { f in
            await f.driver.setFetchAction {
                await f.reopened.receiveFetchedChanges(records: Array(f.cloud.prefix(1)), deletedRecordIDs: [])
            }
            let request = UUID()
            try await f.reopened.fetchNow(completionID: request)
            await #expect(throws: CloudSyncTransportError.unknownFetchedBatch) {
                try await f.reopened.committedFetchReceipt(requestID: request)
            }
        }
    }

    @Test func fetchFrontierAccountsForAcknowledgedHistoryOnlyAfterCompleteObservation() async throws {
        try await withReceiptRedeliveryFixture(populated: true, acknowledged: true) { f in
            let advanced = try testRecord(uuid: "00000000-0000-0000-0000-000000000010", revision: 2)
            let advancedCloud = try CloudRecordCodec().encode(advanced, zoneID: testZoneID())
            await f.driver.setFetchAction {
                await f.reopened.receiveFetchedChanges(records: [advancedCloud, f.cloud[1]], deletedRecordIDs: [])
            }
            var events = f.reopened.events.makeAsyncIterator()
            let request = UUID()
            try await f.reopened.fetchNow(completionID: request)
            guard case let .fetched(newID, _, _, _)? = await events.next() else { throw TestInterruption() }
            await #expect(throws: CloudSyncTransportError.unknownFetchedBatch) {
                try await f.reopened.committedFetchReceipt(requestID: request)
            }
            try await f.reopened.acknowledgeFetchedBatch(newID)
            let receipt = try await f.reopened.committedFetchReceipt(requestID: request)
            #expect(receipt.batchIDs == [f.batchID, newID])
        }
    }

    @Test(arguments: ["account", "zone", "corrupt"])
    func invalidRedeliveryAcknowledgementCannotAuthorizeReceipt(cut: String) async throws {
        try await withReceiptRedeliveryFixture(populated: true, acknowledged: true) { f in
            let incomingURL = f.fixture.url.appendingPathExtension("incoming-batches")
            var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: incomingURL)) as? [String: Any])
            var batches = try #require(document["batches"] as? [[String: Any]])
            var acknowledgement = try #require(batches[0]["retiredAcknowledgement"] as? [String: Any])
            if cut == "account" { acknowledgement["accountIDHash"] = String(repeating: "0", count: 64) }
            if cut == "corrupt" { acknowledgement["contentSHA256"] = "corrupt" }
            if cut == "zone" { batches[0]["zoneName"] = "ForeignZone" }
            batches[0]["retiredAcknowledgement"] = acknowledgement
            document["batches"] = batches
            try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: incomingURL)
            let request = UUID()
            _ = try? await f.reopened.fetchNow(completionID: request)
            await #expect(throws: (any Error).self) {
                try await f.reopened.committedFetchReceipt(requestID: request)
            }
        }
    }

    @Test func restartRejectsIncomingAttachmentWhoseVerifiedInstalledBytesWereLost() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let mutation = try integrationAttachment(root: fixture.root)
        let version = try #require(mutation.savedRecordVersion?.record.payload.attachment)
        let staging = try CloudAssetStagingService(rootURL: fixture.root.appendingPathComponent("assets"), accountIdentifier: "account")
        let transport = CKSyncEngineTransport(zoneID: testZoneID(), stateStore: fixture.store,
            initialAccountIdentifier: "account", assetStaging: staging, engineFactory: { _, _ in TestSyncEngineDriver() })
        try await transport.start()
        let record = try CloudRecordCodec().encode(mutation.savedRecordVersion!.record, zoneID: testZoneID())
        record["asset"] = CKAsset(fileURL: mutation.attachmentSource!.fileURL)
        await transport.receiveFetchedChanges(records: [record], deletedRecordIDs: [])
        let installed = try staging.installedDownload(version: version)
        try FileManager.default.removeItem(at: installed)
        let restarted = CKSyncEngineTransport(zoneID: testZoneID(), stateStore: fixture.store,
            initialAccountIdentifier: "account", assetStaging: staging, engineFactory: { _, _ in TestSyncEngineDriver() })
        do { try await restarted.start(); Issue.record("missing installed bytes must block replay") }
        catch { /* fail closed before any fetched event or receipt */ }
    }

    @Test func attachmentSuccessAndRestartRetainReferencesWithoutExactDurableAcknowledgement() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let mutation = try integrationAttachment(root: fixture.root)
        let next = try SyncMutation.save(recordVersion: mutation.savedRecordVersion!, attachmentSource: mutation.attachmentSource, mutationID: UUID())
        let version = try #require(mutation.savedRecordVersion?.record.payload.attachment)
        let stagingRoot = fixture.root.appendingPathComponent("assets")
        let staging = try CloudAssetStagingService(rootURL: stagingRoot, accountIdentifier: "account")
        let transport = CKSyncEngineTransport(zoneID: testZoneID(), stateStore: fixture.store,
            initialAccountIdentifier: "account", assetStaging: staging, engineFactory: { _, _ in TestSyncEngineDriver() })
        try await transport.start()
        try await transport.scheduleIssued([mutation, next])
        try await transport.finishMutationReplay()
        await transport.receiveZoneReady(testZoneID())
        let cloud = try CloudRecordCodec().encode(mutation.savedRecordVersion!.record, zoneID: testZoneID())
        let outgoing = try #require(await transport.recordZoneChangeBatch(pendingChanges: [.saveRecord(cloud.recordID)], scope: .all)?.recordsToSave.first)
        let url = try #require((outgoing["asset"] as? CKAsset)?.fileURL)
        await transport.receiveSentChanges(savedRecords: [outgoing], deletedRecordIDs: [])
        #expect(FileManager.default.fileExists(atPath: url.path))
        let nextRecord = try #require(await transport.recordZoneChangeBatch(pendingChanges: [.saveRecord(cloud.recordID)], scope: .all)?.recordsToSave.first)
        let nextURL = try #require((nextRecord["asset"] as? CKAsset)?.fileURL)
        #expect(nextURL != url)
        // A journal snapshot cannot prove that an absent staging reference was
        // acknowledged: it may belong to concurrent, not-yet-replayed work.
        let restartedStaging = try CloudAssetStagingService(rootURL: stagingRoot, accountIdentifier: "account")
        let restarted = CKSyncEngineTransport(zoneID: testZoneID(), stateStore: fixture.store,
            initialAccountIdentifier: "account", assetStaging: restartedStaging, engineFactory: { _, _ in TestSyncEngineDriver() })
        try await restarted.start()
        try await restarted.scheduleIssued([next])
        try await restarted.finishMutationReplay()
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try restartedStaging.assetForUpload(versionID: version.versionID, mutationID: next.mutationID).fileURL == nextURL)
        await restarted.receiveAccountChange(previous: "account", current: "different-account")
        do { try await restarted.start(); Issue.record("old-account staging must not rebind") }
        catch { #expect(error as? CloudSyncTransportError == .accountResetIncomplete) }
        #expect(FileManager.default.fileExists(atPath: nextURL.path))
    }

    @Test func corruptAttachmentBytesCannotReachIncomingReceipt() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let mutation = try integrationAttachment(root: fixture.root)
        let staging = try CloudAssetStagingService(rootURL: fixture.root.appendingPathComponent("assets"), accountIdentifier: "account")
        let transport = CKSyncEngineTransport(zoneID: testZoneID(), stateStore: fixture.store,
            initialAccountIdentifier: "account", assetStaging: staging, engineFactory: { _, _ in TestSyncEngineDriver() })
        try await transport.start()
        let record = try CloudRecordCodec().encode(mutation.savedRecordVersion!.record, zoneID: testZoneID())
        let badURL = fixture.root.appendingPathComponent("bad")
        try Data("wrong bytes".utf8).write(to: badURL)
        record["asset"] = CKAsset(fileURL: badURL)
        await transport.receiveFetchedChanges(records: [record], deletedRecordIDs: [])
        let incoming = FileCloudIncomingBatchStore(url: fixture.store.relatedURL(pathExtension: "incoming-batches"))
        #expect(try incoming.beginGeneration(accountIdentifier: "account", zoneID: testZoneID(), persistedEngineState: nil).batches.isEmpty)
    }

    @Test func requestLevelLimitExceededRetriesReducedBatchesAndStopsAtSingleRecord() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let driver = TestSyncEngineDriver()
        let transport = CKSyncEngineTransport(zoneID: testZoneID(), stateStore: fixture.store,
            engineFactory: { _, _ in driver })
        try await transport.start()
        let mutations = try (1...4).map { index in
            try SyncMutation.save(recordVersion: SyncRecordVersion(record: testRecord(
                uuid: String(format: "00000000-0000-0000-0000-%012d", index), revision: 1)), mutationID: UUID())
        }
        try await transport.scheduleIssued(mutations)
        try await transport.finishMutationReplay()
        await transport.receiveZoneReady(testZoneID())
        let observation = RequestLimitObservation()
        await driver.setSendAction {
            while let batch = await transport.recordZoneChangeBatch(pendingChanges: driver.pendingChanges(), scope: .all) {
                await observation.append(batch.recordsToSave.count)
                if batch.recordsToSave.count > 2 { throw CKError(.limitExceeded) }
                await transport.receiveSentChanges(savedRecords: batch.recordsToSave, deletedRecordIDs: [])
            }
        }
        try await transport.sendNow()
        #expect(await observation.sizes == [4, 2, 2])
        // A one-record failure is terminal and keeps that mutation pending.
        let single = try testSaveMutation(revision: 1, mutationSuffix: 111)
        try await transport.scheduleIssued([single])
        await driver.setSendAction {
            if let batch = await transport.recordZoneChangeBatch(pendingChanges: driver.pendingChanges(), scope: .all) {
                await observation.append(batch.recordsToSave.count)
                throw CKError(.limitExceeded)
            }
        }
        do { try await transport.sendNow(); Issue.record("single record limit must surface") }
        catch { #expect(error as? CloudSyncFailure == .limitExceeded) }
        #expect(await observation.sizes == [4, 2, 2, 1])
        #expect(await transport.recordZoneChangeBatch(pendingChanges: driver.pendingChanges(), scope: .all) == nil)
    }

    @Test func defaultTransportRefusesMetadataOnlyAttachmentSaveAndFetch() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let mutation = try integrationAttachment(root: fixture.root)
        let transport = CKSyncEngineTransport(zoneID: testZoneID(), stateStore: fixture.store,
            engineFactory: { _, _ in TestSyncEngineDriver() })
        var events = transport.events.makeAsyncIterator()
        try await transport.start()
        try await transport.scheduleIssued([mutation])
        try await transport.finishMutationReplay()
        await transport.receiveZoneReady(testZoneID())
        _ = await events.next()
        let record = try CloudRecordCodec().encode(mutation.savedRecordVersion!.record, zoneID: testZoneID())
        let batch = await transport.recordZoneChangeBatch(pendingChanges: [.saveRecord(record.recordID)], scope: .all)
        #expect(batch?.recordsToSave.isEmpty ?? true)
        await transport.receiveFetchedChanges(records: [record], deletedRecordIDs: [])
        // No receipt may exist for bytes never installed.
        let replay = try FileCloudIncomingBatchStore(url: fixture.store.relatedURL(pathExtension: "incoming-batches"))
            .beginGeneration(accountIdentifier: "", zoneID: testZoneID(), persistedEngineState: nil)
        #expect(replay.batches.isEmpty)
    }

    @Test func limitExceededSplitsPendingBatchWithoutLosingStableMutations() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let transport = CKSyncEngineTransport(zoneID: testZoneID(), stateStore: fixture.store,
            engineFactory: { _, _ in TestSyncEngineDriver() })
        try await transport.start()
        let mutations = try (1...4).map { index in
            try SyncMutation.save(recordVersion: SyncRecordVersion(record: testRecord(
                uuid: String(format: "00000000-0000-0000-0000-%012d", index), revision: 1)), mutationID: UUID())
        }
        let changes = try mutations.map { mutation in
            CKSyncEngine.PendingRecordZoneChange.saveRecord(try CloudRecordCodec().encode(mutation.savedRecordVersion!.record, zoneID: testZoneID()).recordID)
        }
        try await transport.scheduleIssued(mutations)
        try await transport.finishMutationReplay()
        await transport.receiveZoneReady(testZoneID())
        let large = try #require(await transport.recordZoneChangeBatch(pendingChanges: changes, scope: .all))
        for record in large.recordsToSave { await transport.receiveFailedSave(record, error: CKError(.limitExceeded)) }
        let reduced = try #require(await transport.recordZoneChangeBatch(pendingChanges: changes, scope: .all))
        #expect(reduced.recordsToSave.count == 2)
        await transport.receiveSentChanges(savedRecords: reduced.recordsToSave, deletedRecordIDs: [])
        let tail = try #require(await transport.recordZoneChangeBatch(pendingChanges: changes, scope: .all))
        #expect(tail.recordsToSave.count == 2)
        #expect(Set((reduced.recordsToSave + tail.recordsToSave).compactMap { $0["syncMutationID"] as? String }) == Set(mutations.map { $0.mutationID.uuidString.lowercased() }))
    }

    @Test func explicitFetchCompletionFollowsBatchesDeliveredDuringThatFetch() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let driver = TestSyncEngineDriver()
        let transport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            engineFactory: { _, _ in driver }
        )
        var iterator = transport.events.makeAsyncIterator()
        try await transport.start()
        let requestID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let cloudRecord = try CloudRecordCodec().encode(
            testRecord(uuid: "00000000-0000-0000-0000-000000000001", revision: 1),
            zoneID: zoneID
        )
        await driver.suspendNextFetch()

        let fetch = Task { try await transport.fetchNow(completionID: requestID) }
        await driver.waitUntilFetchSuspended()
        await transport.receiveFetchedChanges(records: [cloudRecord], deletedRecordIDs: [])
        await driver.resumeFetch()
        try await fetch.value

        guard case .fetched? = await iterator.next() else {
            Issue.record("Expected fetched batch before request completion")
            return
        }
        guard case .fetchRequestCompleted(requestID)? = await iterator.next() else {
            Issue.record("Expected matching fetch request completion")
            return
        }
    }

    @Test func explicitSendCompletionCarriesTheMatchingRequestIdentity() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let transport = CKSyncEngineTransport(
            zoneID: testZoneID(),
            stateStore: fixture.store,
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        var iterator = transport.events.makeAsyncIterator()
        try await transport.start()
        let requestID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!

        try await transport.finishMutationReplay(completionID: requestID)

        guard case .sendRequestCompleted(requestID)? = await iterator.next() else {
            Issue.record("Expected matching send request completion")
            return
        }
    }

    @Test func permanentFailureWithoutRawServerCannotReplaceOrAcknowledgeHead() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let driver = TestSyncEngineDriver()
        let transport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            engineFactory: { _, _ in driver }
        )
        var iterator = transport.events.makeAsyncIterator()
        try await transport.start()
        let first = try testSaveMutation(revision: 1, mutationSuffix: 70)
        try await transport.scheduleIssued([first])
        try await transport.finishMutationReplay()
        await transport.receiveZoneReady(zoneID)
        _ = await iterator.next()
        let recordID = cloudRecordID(
            kind: first.recordID.kind,
            uuid: first.recordID.uuid.uuidString,
            zoneID: zoneID
        )
        let outgoing = try #require(await transport.recordZoneChangeBatch(
            pendingChanges: [.saveRecord(recordID)],
            scope: .all
        )?.recordsToSave.first)
        await transport.receiveFailedSave(outgoing, error: CKError(.invalidArguments))
        _ = await iterator.next()
        // An invalid-arguments event has no raw server authority and cannot be rebased.
        await transport.receiveSentChanges(savedRecords: [outgoing], deletedRecordIDs: [])
        #expect(await transport.recordZoneChangeBatch(pendingChanges: [.saveRecord(recordID)], scope: .all) == nil)
        #expect(await driver.pendingChanges() == [.saveRecord(recordID)])
    }

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
        try await transport.scheduleIssued([nextMutation])
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
        try await transport.scheduleIssued([first])
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
        try await transport.scheduleIssued([second])
        let rebuilt = try #require(await transport.recordZoneChangeBatch(
            pendingChanges: [.saveRecord(recordID)],
            scope: .all
        )?.recordsToSave.first)
        #expect(rebuilt.parent?.recordID == saved.parent?.recordID)

        let server = try CloudRecordCodec().encode(second.savedRecordVersion!.record, zoneID: zoneID)
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

        #expect(await transport.recordZoneChangeBatch(pendingChanges: [.saveRecord(recordID)], scope: .all) == nil)
        // A restart must obtain fresh server authority. Explicit new delete fixtures
        // exercise scoped system-field cleanup without manufacturing a conflict handoff.
        let deletion = SyncMutation.delete(first.recordID, mutationID: UUID())
        let restarted = CKSyncEngineTransport(zoneID: zoneID, stateStore: fixture.store,
            systemFieldsStore: systemStore, initialAccountIdentifier: accountIdentifier, engineFactory: { _, _ in driver })
        try await restarted.start()
        try await restarted.scheduleIssued([deletion])
        try await restarted.finishMutationReplay()
        await restarted.receiveZoneReady(zoneID)
        let deleteBatch = try #require(await restarted.recordZoneChangeBatch(pendingChanges: [.deleteRecord(recordID)], scope: .all))
        #expect(deleteBatch.recordIDsToDelete == [recordID])
        await driver.complete(.deleteRecord(recordID))
        await restarted.receiveSentChanges(savedRecords: [], deletedRecordIDs: [recordID])
        #expect(try systemStore.load(recordID: recordID, accountIdentifier: accountIdentifier) == nil)
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

        guard case let .fetched(_, _, _, deleted)? = await iterator.next() else {
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

        guard case let .fetched(_, _, receivedRecords, receivedDeleted)? = await iterator.next() else {
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
        guard case let .fetched(batchID, _, _, _)? = await iterator.next() else {
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
        guard case let .fetched(firstBatchID, _, _, _)? = await iterator.next() else {
            Issue.record("Expected first identified fetched batch")
            return
        }
        let firstState = try stateSerialization(base64: "AQ==")
        await transport.receiveStateUpdate(firstState)
        await transport.receiveFetchedChanges(records: [], deletedRecordIDs: [])
        guard case let .fetched(secondBatchID, _, _, _)? = await iterator.next() else {
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

    @Test func incrementalStateCommitDoesNotRetainCoverageForAnEvictedReceipt() async throws {
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
        guard case let .fetched(firstBatchID, _, _, _)? = await iterator.next() else {
            Issue.record("Expected first fetched batch")
            return
        }
        let firstState = try stateSerialization(base64: "AQ==")
        await transport.receiveStateUpdate(firstState)
        await transport.receiveFetchedChanges(records: [], deletedRecordIDs: [])
        guard case let .fetched(secondBatchID, _, _, _)? = await iterator.next() else {
            Issue.record("Expected second fetched batch")
            return
        }
        let secondState = try stateSerialization(base64: "Ag==")
        await transport.receiveStateUpdate(secondState)

        try await transport.acknowledgeFetchedBatch(firstBatchID)
        #expect(try encodedState(fixture.store.load()) == encodedState(firstState))
        try await transport.acknowledgeFetchedBatch(secondBatchID)
        #expect(try encodedState(fixture.store.load()) == encodedState(secondState))
    }

    @Test func sustainedStateUpdatesCoalesceBehindOneUnacknowledgedBatch() async throws {
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
        guard case let .fetched(batchID, _, _, _)? = await iterator.next() else {
            Issue.record("Expected fetched batch")
            return
        }
        var latestState = try stateSerialization(base64: "AA==")
        for value in 1...2_000 {
            latestState = try stateSerialization(
                base64: Data(String(value).utf8).base64EncodedString()
            )
            await transport.receiveStateUpdate(latestState)
        }

        #expect(await transport.pendingStateUpdateCountForTesting() == 1)
        #expect(try fixture.store.load() == nil)
        try await transport.acknowledgeFetchedBatch(batchID)
        #expect(try encodedState(fixture.store.load()) == encodedState(latestState))
    }

    @Test func incomingAdmissionReservesBytesForWorstCaseRestartReset() throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let records = try (200...263).map { value in
            try testRecord(
                uuid: String(format: "00000000-0000-0000-0000-%012d", value),
                revision: UInt64(value)
            )
        }
        let calibrationURL = fixture.root.appendingPathComponent("calibration-incoming.json")
        let calibrationStore = FileCloudIncomingBatchStore(
            url: calibrationURL,
            maximumBatchCount: 1,
            maximumEncodedBytes: 8 * 1_024 * 1_024
        )
        let calibrationGeneration = try calibrationStore.beginGeneration(
            accountIdentifier: "account-a",
            zoneID: zoneID,
            persistedEngineState: nil
        ).generation
        _ = try calibrationStore.record(
            records: records,
            deletedRecordIDs: [],
            accountIdentifier: "account-a",
            zoneID: zoneID,
            generation: calibrationGeneration
        )
        let admittedSize = try Data(contentsOf: calibrationURL).count
        _ = try calibrationStore.beginGeneration(
            accountIdentifier: "account-a",
            zoneID: zoneID,
            persistedEngineState: nil
        )
        let restartedSize = try Data(contentsOf: calibrationURL).count
        #expect(restartedSize > admittedSize)

        let constrainedStore = FileCloudIncomingBatchStore(
            url: fixture.root.appendingPathComponent("constrained-incoming.json"),
            maximumBatchCount: 1,
            maximumEncodedBytes: admittedSize
        )
        let constrainedGeneration = try constrainedStore.beginGeneration(
            accountIdentifier: "account-a",
            zoneID: zoneID,
            persistedEngineState: nil
        ).generation
        #expect(throws: CloudIncomingBatchStoreError.capacityExceeded) {
            _ = try constrainedStore.record(
                records: records,
                deletedRecordIDs: [],
                accountIdentifier: "account-a",
                zoneID: zoneID,
                generation: constrainedGeneration
            )
        }
    }

    @Test func freshTransportReplaysDurableFetchedBatchWithStableIdentityBeforeAcknowledgement() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let incomingStore = FileCloudIncomingBatchStore(
            url: fixture.root.appendingPathComponent("incoming-batches.json")
        )
        let record = try testRecord(
            uuid: "00000000-0000-0000-0000-000000000045",
            revision: 1
        )
        let cloudRecord = try CloudRecordCodec().encode(record, zoneID: zoneID)
        let firstTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        var firstEvents = firstTransport.events.makeAsyncIterator()
        try await firstTransport.start()

        await firstTransport.receiveFetchedChanges(records: [cloudRecord], deletedRecordIDs: [])

        guard case let .fetched(firstBatchID, _, firstRecords, _)? = await firstEvents.next() else {
            Issue.record("Expected first durable fetched batch")
            return
        }
        #expect(firstRecords == [record])

        // Simulate a process ending after its domain committer returned but
        // before the transport acknowledgement reached durable bookkeeping.
        let restartedTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        var restartedEvents = restartedTransport.events.makeAsyncIterator()
        try await restartedTransport.start()

        guard case let .fetched(replayedBatchID, _, replayedRecords, _)? = await restartedEvents.next() else {
            Issue.record("Expected durable fetched batch replay after restart")
            return
        }
        #expect(replayedBatchID == firstBatchID)
        #expect(replayedRecords == [record])
        try await restartedTransport.acknowledgeFetchedBatch(replayedBatchID)
    }

    @Test func freshTransportRedeliversOverflowedBatchWithoutManualCallbackReinjection() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let incomingStore = FileCloudIncomingBatchStore(
            url: fixture.root.appendingPathComponent("incoming-batches.json"),
            maximumBatchCount: 2
        )
        let records = try (53...55).map { suffix in
            try testRecord(
                uuid: String(format: "00000000-0000-0000-0000-%012d", suffix),
                revision: UInt64(suffix)
            )
        }
        let cloudRecords = try records.map { try CloudRecordCodec().encode($0, zoneID: zoneID) }
        let firstTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        var firstEvents = firstTransport.events.makeAsyncIterator()
        try await firstTransport.start()
        for cloudRecord in cloudRecords.prefix(2) {
            await firstTransport.receiveFetchedChanges(
                records: [cloudRecord],
                deletedRecordIDs: []
            )
            guard case let .fetched(batchID, _, _, _)? = await firstEvents.next() else {
                Issue.record("Expected durable fetched batch before saturation")
                return
            }
            try await firstTransport.acknowledgeFetchedBatch(batchID)
        }

        await firstTransport.receiveFetchedChanges(
            records: [cloudRecords[2]],
            deletedRecordIDs: []
        )

        guard case .failed(.incomingBackpressure)? = await firstEvents.next() else {
            Issue.record("Expected bounded spool backpressure")
            return
        }
        await firstTransport.receiveStateUpdate(try stateSerialization(base64: "Aw=="))
        try #require(fixture.store.load() == nil)

        let restartedDriver = TestSyncEngineDriver()
        let restartedTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in restartedDriver }
        )
        var restartedEvents = restartedTransport.events.makeAsyncIterator()
        try await restartedTransport.start()
        for expectedRecord in records.prefix(2) {
            guard case let .fetched(batchID, _, replayedRecords, _)? = await restartedEvents.next() else {
                Issue.record("Expected durable fetched batch replay after restart")
                return
            }
            #expect(replayedRecords == [expectedRecord])
            try await restartedTransport.acknowledgeFetchedBatch(batchID)
        }
        let firstState = try stateSerialization(base64: "AQ==")
        let secondState = try stateSerialization(base64: "Ag==")
        let finalState = try stateSerialization(base64: "Aw==")
        await restartedDriver.setFetchAction { [weak restartedTransport] in
            guard let restartedTransport else { return }
            await restartedTransport.receiveFetchedChanges(
                records: [cloudRecords[0]],
                deletedRecordIDs: []
            )
            await restartedTransport.receiveStateUpdate(firstState)
            await restartedTransport.receiveFetchedChanges(
                records: [cloudRecords[1]],
                deletedRecordIDs: []
            )
            await restartedTransport.receiveStateUpdate(secondState)
            await restartedTransport.receiveFetchedChanges(
                records: [cloudRecords[2]],
                deletedRecordIDs: []
            )
            await restartedTransport.receiveStateUpdate(finalState)
        }

        try await restartedTransport.fetchNow()

        guard case let .fetched(redeliveredBatchID, _, redeliveredRecords, _)? = await restartedEvents.next() else {
            Issue.record("Expected source replay to free capacity and deliver overflowed batch")
            return
        }
        #expect(redeliveredRecords == [records[2]])
        try await restartedTransport.acknowledgeFetchedBatch(redeliveredBatchID)
        guard case .stateUpdated? = await restartedEvents.next() else {
            Issue.record("Expected overflowed batch acknowledgement to release its held state")
            return
        }
        #expect(
            try encodedState(fixture.store.load())
                == encodedState(finalState)
        )
    }

    @Test(arguments: FreshReplayShape.allCases)
    func freshRestartReconcilesOverflowIndependentOfSourceBatchShape(
        _ shape: FreshReplayShape
    ) async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let records = try (58...60).map { suffix in
            try testRecord(
                uuid: String(format: "00000000-0000-0000-0000-%012d", suffix),
                revision: UInt64(suffix)
            )
        }
        let cloudRecords = try records.map { try CloudRecordCodec().encode($0, zoneID: zoneID) }
        let incomingStore = FileCloudIncomingBatchStore(
            url: fixture.root.appendingPathComponent("incoming-batches.json"),
            maximumBatchCount: shape.durableCallbacks.count
        )
        let firstTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        var firstEvents = firstTransport.events.makeAsyncIterator()
        try await firstTransport.start()
        for callback in shape.durableCallbacks {
            await firstTransport.receiveFetchedChanges(
                records: callback.map { cloudRecords[$0] },
                deletedRecordIDs: []
            )
            guard case let .fetched(batchID, _, _, _)? = await firstEvents.next() else {
                Issue.record("Expected durable fetched batch before saturation")
                return
            }
            try await firstTransport.acknowledgeFetchedBatch(batchID)
        }
        await firstTransport.receiveFetchedChanges(
            records: [cloudRecords[2]],
            deletedRecordIDs: []
        )
        guard case .failed(.incomingBackpressure)? = await firstEvents.next() else {
            Issue.record("Expected bounded spool backpressure")
            return
        }

        let restartedDriver = TestSyncEngineDriver()
        let restartedTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in restartedDriver }
        )
        var restartedEvents = restartedTransport.events.makeAsyncIterator()
        try await restartedTransport.start()
        for _ in shape.durableCallbacks {
            guard case let .fetched(batchID, _, _, _)? = await restartedEvents.next() else {
                Issue.record("Expected durable replay after restart")
                return
            }
            try await restartedTransport.acknowledgeFetchedBatch(batchID)
        }
        let callbackStates = [
            try stateSerialization(base64: "AQ=="),
            try stateSerialization(base64: "Ag=="),
        ]
        let finalState = try stateSerialization(base64: "Aw==")
        await restartedDriver.setFetchAction { [weak restartedTransport] in
            guard let restartedTransport else { return }
            for (index, callback) in shape.sourceCallbacks.enumerated() {
                await restartedTransport.receiveFetchedChanges(
                    records: callback.map { cloudRecords[$0] },
                    deletedRecordIDs: []
                )
                await restartedTransport.receiveStateUpdate(callbackStates[index])
            }
            await restartedTransport.receiveFetchedChanges(
                records: [cloudRecords[2]],
                deletedRecordIDs: []
            )
            await restartedTransport.receiveStateUpdate(finalState)
        }

        try await restartedTransport.fetchNow()

        guard case let .fetched(batchID, _, fetchedRecords, _)? = await restartedEvents.next() else {
            Issue.record("Expected shape-independent recovery to release overflow capacity")
            return
        }
        #expect(fetchedRecords == [records[2]])
        try await restartedTransport.acknowledgeFetchedBatch(batchID)
        guard case .stateUpdated? = await restartedEvents.next() else {
            Issue.record("Expected overflowed callback state after acknowledgement")
            return
        }
        #expect(try encodedState(fixture.store.load()) == encodedState(finalState))
    }

    @Test func freshRestartAcceptsReplayAndDistinctOverflowInOneCombinedCallback() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let incomingStore = FileCloudIncomingBatchStore(
            url: fixture.root.appendingPathComponent("incoming-batches.json"),
            maximumBatchCount: 1
        )
        let records = try (63...64).map { suffix in
            try testRecord(
                uuid: String(format: "00000000-0000-0000-0000-%012d", suffix),
                revision: UInt64(suffix)
            )
        }
        let cloudRecords = try records.map { try CloudRecordCodec().encode($0, zoneID: zoneID) }
        let firstTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        var firstEvents = firstTransport.events.makeAsyncIterator()
        try await firstTransport.start()
        await firstTransport.receiveFetchedChanges(records: [cloudRecords[0]], deletedRecordIDs: [])
        guard case let .fetched(firstBatchID, _, _, _)? = await firstEvents.next() else {
            Issue.record("Expected durable fetched batch")
            return
        }
        try await firstTransport.acknowledgeFetchedBatch(firstBatchID)
        await firstTransport.receiveFetchedChanges(records: [cloudRecords[1]], deletedRecordIDs: [])
        guard case .failed(.incomingBackpressure)? = await firstEvents.next() else {
            Issue.record("Expected initial overflow backpressure")
            return
        }

        let driver = TestSyncEngineDriver()
        let restartedTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in driver }
        )
        var restartedEvents = restartedTransport.events.makeAsyncIterator()
        try await restartedTransport.start()
        guard case let .fetched(replayedBatchID, _, _, _)? = await restartedEvents.next() else {
            Issue.record("Expected durable replay")
            return
        }
        try await restartedTransport.acknowledgeFetchedBatch(replayedBatchID)
        let finalState = try stateSerialization(base64: "BA==")
        await driver.setFetchAction { [weak restartedTransport] in
            guard let restartedTransport else { return }
            await restartedTransport.receiveFetchedChanges(
                records: cloudRecords,
                deletedRecordIDs: []
            )
            await restartedTransport.receiveStateUpdate(finalState)
        }

        try await restartedTransport.fetchNow()

        guard case let .fetched(batchID, _, fetchedRecords, _)? = await restartedEvents.next() else {
            Issue.record("Expected distinct overflow work from combined callback")
            return
        }
        #expect(fetchedRecords == [records[1]])
        try await restartedTransport.acknowledgeFetchedBatch(batchID)
        guard case .stateUpdated? = await restartedEvents.next() else {
            Issue.record("Expected combined callback state after acknowledgement")
            return
        }
        #expect(try encodedState(fixture.store.load()) == encodedState(finalState))
    }

    @Test func newerSameEntitySourceCoversStaleReceiptAndRemainsDistinctWork() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let incomingStore = FileCloudIncomingBatchStore(
            url: fixture.root.appendingPathComponent("incoming-batches.json"),
            maximumBatchCount: 1
        )
        let oldRecord = try testRecord(
            uuid: "00000000-0000-0000-0000-000000000065",
            revision: 65
        )
        let newerRecord = try testRecord(
            uuid: oldRecord.id.uuid.uuidString,
            revision: 66
        )
        let unrelatedOverflow = try testRecord(
            uuid: "00000000-0000-0000-0000-000000000067",
            revision: 67
        )
        let firstTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        var firstEvents = firstTransport.events.makeAsyncIterator()
        try await firstTransport.start()
        await firstTransport.receiveFetchedChanges(
            records: [try CloudRecordCodec().encode(oldRecord, zoneID: zoneID)],
            deletedRecordIDs: []
        )
        guard case let .fetched(oldBatchID, _, _, _)? = await firstEvents.next() else {
            Issue.record("Expected old durable batch")
            return
        }
        try await firstTransport.acknowledgeFetchedBatch(oldBatchID)
        await firstTransport.receiveFetchedChanges(
            records: [try CloudRecordCodec().encode(unrelatedOverflow, zoneID: zoneID)],
            deletedRecordIDs: []
        )
        guard case .failed(.incomingBackpressure)? = await firstEvents.next() else {
            Issue.record("Expected initial overflow backpressure")
            return
        }

        let driver = TestSyncEngineDriver()
        let restartedTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in driver }
        )
        var restartedEvents = restartedTransport.events.makeAsyncIterator()
        try await restartedTransport.start()
        guard case let .fetched(replayedBatchID, _, _, _)? = await restartedEvents.next() else {
            Issue.record("Expected stale receipt replay")
            return
        }
        try await restartedTransport.acknowledgeFetchedBatch(replayedBatchID)
        let state = try stateSerialization(base64: "BQ==")
        let newerCloudRecord = try CloudRecordCodec().encode(newerRecord, zoneID: zoneID)
        await driver.setFetchAction { [weak restartedTransport] in
            guard let restartedTransport else { return }
            await restartedTransport.receiveFetchedChanges(
                records: [newerCloudRecord],
                deletedRecordIDs: []
            )
            await restartedTransport.receiveStateUpdate(state)
        }

        try await restartedTransport.fetchNow()

        guard case let .fetched(batchID, _, fetchedRecords, _)? = await restartedEvents.next() else {
            Issue.record("Expected superseding payload as distinct work")
            return
        }
        #expect(fetchedRecords == [newerRecord])
        try await restartedTransport.acknowledgeFetchedBatch(batchID)
        guard case .stateUpdated? = await restartedEvents.next() else {
            Issue.record("Expected superseding state after acknowledgement")
            return
        }
        #expect(try encodedState(fixture.store.load()) == encodedState(state))
    }

    @Test func olderSameEntitySourceDoesNotCoverLaterDurableReceipt() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let incomingStore = FileCloudIncomingBatchStore(
            url: fixture.root.appendingPathComponent("incoming-batches.json"),
            maximumBatchCount: 2
        )
        let older = try testRecord(
            uuid: "00000000-0000-0000-0000-000000000068",
            revision: 68
        )
        let newer = try testRecord(uuid: older.id.uuid.uuidString, revision: 69)
        let cloudRecords = try [older, newer].map {
            try CloudRecordCodec().encode($0, zoneID: zoneID)
        }
        let firstTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        var firstEvents = firstTransport.events.makeAsyncIterator()
        try await firstTransport.start()
        for cloudRecord in cloudRecords {
            await firstTransport.receiveFetchedChanges(
                records: [cloudRecord],
                deletedRecordIDs: []
            )
            guard case let .fetched(batchID, _, _, _)? = await firstEvents.next() else {
                Issue.record("Expected ordered durable same-entity receipt")
                return
            }
            try await firstTransport.acknowledgeFetchedBatch(batchID)
        }

        let driver = TestSyncEngineDriver()
        let restartedTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in driver }
        )
        var restartedEvents = restartedTransport.events.makeAsyncIterator()
        try await restartedTransport.start()
        for _ in cloudRecords {
            guard case let .fetched(batchID, _, _, _)? = await restartedEvents.next() else {
                Issue.record("Expected ordered durable replay")
                return
            }
            try await restartedTransport.acknowledgeFetchedBatch(batchID)
        }
        let olderState = try stateSerialization(base64: "Bg==")
        let newerState = try stateSerialization(base64: "Bw==")
        await driver.setFetchAction { [weak restartedTransport] in
            guard let restartedTransport else { return }
            await restartedTransport.receiveFetchedChanges(
                records: [cloudRecords[0]],
                deletedRecordIDs: []
            )
            await restartedTransport.receiveStateUpdate(olderState)
            await restartedTransport.receiveFetchedChanges(
                records: [cloudRecords[1]],
                deletedRecordIDs: []
            )
            await restartedTransport.receiveStateUpdate(newerState)
        }

        try await restartedTransport.fetchNow()

        var sourceBatchIDs: [UUID] = []
        for expected in [older, newer] {
            guard case let .fetched(batchID, _, records, _)? = await restartedEvents.next() else {
                Issue.record("Expected ordered source occurrence as distinct work")
                return
            }
            #expect(records == [expected])
            sourceBatchIDs.append(batchID)
        }
        for batchID in sourceBatchIDs {
            try await restartedTransport.acknowledgeFetchedBatch(batchID)
        }
        guard case .stateUpdated? = await restartedEvents.next() else {
            Issue.record("Expected the later ordered source frontier to commit")
            return
        }
        #expect(try encodedState(fixture.store.load()) == encodedState(newerState))
    }

    @Test func divergentSameRevisionSourceCoversDurableReceiptAsDistinctWork() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let incomingStore = FileCloudIncomingBatchStore(
            url: fixture.root.appendingPathComponent("incoming-batches.json"),
            maximumBatchCount: 1
        )
        let durable = try testRecord(
            uuid: "00000000-0000-0000-0000-000000000076",
            revision: 76
        )
        let divergentStamp = SyncMutationStamp(
            logicalRevision: 76,
            modifiedAt: Date(timeIntervalSince1970: 77),
            deviceID: "device-b"
        )
        let divergent = try SyncRecordValidator().validate(SyncRecord(
            schemaVersion: durable.schemaVersion,
            id: durable.id,
            createdAt: durable.createdAt,
            entityRevision: durable.entityRevision,
            payload: .init(fields: [
                "title": .init(value: .string("divergent-76"), stamp: divergentStamp),
            ]),
            relationships: durable.relationships,
            deletedAt: .init(value: nil, stamp: divergentStamp)
        ))
        let codec = CloudRecordCodec()
        let firstTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        var firstEvents = firstTransport.events.makeAsyncIterator()
        try await firstTransport.start()
        await firstTransport.receiveFetchedChanges(
            records: [try codec.encode(durable, zoneID: zoneID)],
            deletedRecordIDs: []
        )
        guard case let .fetched(durableBatchID, _, _, _)? = await firstEvents.next() else {
            Issue.record("Expected durable same-revision receipt")
            return
        }
        try await firstTransport.acknowledgeFetchedBatch(durableBatchID)

        let driver = TestSyncEngineDriver()
        let restartedTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in driver }
        )
        var restartedEvents = restartedTransport.events.makeAsyncIterator()
        try await restartedTransport.start()
        guard case let .fetched(replayedBatchID, _, _, _)? = await restartedEvents.next() else {
            Issue.record("Expected durable same-revision replay")
            return
        }
        try await restartedTransport.acknowledgeFetchedBatch(replayedBatchID)
        let state = try stateSerialization(base64: "Cw==")
        let divergentCloudRecord = try codec.encode(divergent, zoneID: zoneID)
        await driver.setFetchAction { [weak restartedTransport] in
            guard let restartedTransport else { return }
            await restartedTransport.receiveFetchedChanges(
                records: [divergentCloudRecord],
                deletedRecordIDs: []
            )
            await restartedTransport.receiveStateUpdate(state)
        }

        try await restartedTransport.fetchNow()

        guard case let .fetched(batchID, _, records, _)? = await restartedEvents.next() else {
            Issue.record("Expected divergent same-revision source work")
            return
        }
        #expect(records == [divergent])
        try await restartedTransport.acknowledgeFetchedBatch(batchID)
        guard case .stateUpdated? = await restartedEvents.next() else {
            Issue.record("Expected same-revision replacement frontier")
            return
        }
        #expect(try encodedState(fixture.store.load()) == encodedState(state))
    }

    @Test func sourceDeletionCoversDurableSaveButRemainsDistinctWork() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let incomingStore = FileCloudIncomingBatchStore(
            url: fixture.root.appendingPathComponent("incoming-batches.json"),
            maximumBatchCount: 1
        )
        let durable = try testRecord(
            uuid: "00000000-0000-0000-0000-000000000077",
            revision: 77
        )
        let codec = CloudRecordCodec()
        let cloudRecord = try codec.encode(durable, zoneID: zoneID)
        let firstTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        var firstEvents = firstTransport.events.makeAsyncIterator()
        try await firstTransport.start()
        await firstTransport.receiveFetchedChanges(records: [cloudRecord], deletedRecordIDs: [])
        guard case let .fetched(durableBatchID, _, _, _)? = await firstEvents.next() else {
            Issue.record("Expected durable save receipt")
            return
        }
        try await firstTransport.acknowledgeFetchedBatch(durableBatchID)

        let driver = TestSyncEngineDriver()
        let restartedTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in driver }
        )
        var restartedEvents = restartedTransport.events.makeAsyncIterator()
        try await restartedTransport.start()
        guard case let .fetched(replayedBatchID, _, _, _)? = await restartedEvents.next() else {
            Issue.record("Expected durable save replay")
            return
        }
        try await restartedTransport.acknowledgeFetchedBatch(replayedBatchID)
        let state = try stateSerialization(base64: "DA==")
        await driver.setFetchAction { [weak restartedTransport] in
            guard let restartedTransport else { return }
            await restartedTransport.receiveFetchedChanges(
                records: [],
                deletedRecordIDs: [cloudRecord.recordID]
            )
            await restartedTransport.receiveStateUpdate(state)
        }

        try await restartedTransport.fetchNow()

        guard case let .fetched(batchID, _, records, deleted)? = await restartedEvents.next() else {
            Issue.record("Expected source deletion as distinct work")
            return
        }
        #expect(records.isEmpty)
        #expect(deleted == [durable.id])
        try await restartedTransport.acknowledgeFetchedBatch(batchID)
        guard case .stateUpdated? = await restartedEvents.next() else {
            Issue.record("Expected deletion frontier after acknowledgement")
            return
        }
        #expect(try encodedState(fixture.store.load()) == encodedState(state))
    }

    @Test func olderEqualRevisionOccurrenceWaitsForLaterDivergentOccurrenceInFetch() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let incomingStore = FileCloudIncomingBatchStore(
            url: fixture.root.appendingPathComponent("incoming-batches.json"),
            maximumBatchCount: 2
        )
        let first = try testRecord(
            uuid: "00000000-0000-0000-0000-000000000078",
            revision: 78
        )
        let laterStamp = SyncMutationStamp(
            logicalRevision: 78,
            modifiedAt: Date(timeIntervalSince1970: 79),
            deviceID: "device-b"
        )
        let later = try SyncRecordValidator().validate(SyncRecord(
            schemaVersion: first.schemaVersion,
            id: first.id,
            createdAt: first.createdAt,
            entityRevision: first.entityRevision,
            payload: .init(fields: [
                "title": .init(value: .string("later-divergent-78"), stamp: laterStamp),
            ]),
            relationships: first.relationships,
            deletedAt: .init(value: nil, stamp: laterStamp)
        ))
        let codec = CloudRecordCodec()
        let cloudRecords = try [first, later].map { try codec.encode($0, zoneID: zoneID) }
        let firstTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        var firstEvents = firstTransport.events.makeAsyncIterator()
        try await firstTransport.start()
        for cloudRecord in cloudRecords {
            await firstTransport.receiveFetchedChanges(records: [cloudRecord], deletedRecordIDs: [])
            guard case let .fetched(batchID, _, _, _)? = await firstEvents.next() else {
                Issue.record("Expected equal-revision durable occurrence")
                return
            }
            try await firstTransport.acknowledgeFetchedBatch(batchID)
        }

        let driver = TestSyncEngineDriver()
        let restartedTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in driver }
        )
        var restartedEvents = restartedTransport.events.makeAsyncIterator()
        try await restartedTransport.start()
        for _ in cloudRecords {
            guard case let .fetched(batchID, _, _, _)? = await restartedEvents.next() else {
                Issue.record("Expected equal-revision durable replay")
                return
            }
            try await restartedTransport.acknowledgeFetchedBatch(batchID)
        }
        let firstState = try stateSerialization(base64: "DQ==")
        let finalState = try stateSerialization(base64: "Dg==")
        await driver.setFetchAction { [weak restartedTransport] in
            guard let restartedTransport else { return }
            await restartedTransport.receiveFetchedChanges(
                records: [cloudRecords[0]],
                deletedRecordIDs: []
            )
            await restartedTransport.receiveStateUpdate(firstState)
            await restartedTransport.receiveFetchedChanges(
                records: [cloudRecords[1]],
                deletedRecordIDs: []
            )
            await restartedTransport.receiveStateUpdate(finalState)
        }

        try await restartedTransport.fetchNow()

        var sourceBatchIDs: [UUID] = []
        for expected in [first, later] {
            guard case let .fetched(batchID, _, records, _)? = await restartedEvents.next() else {
                Issue.record("Expected equal-revision source occurrence as distinct work")
                return
            }
            #expect(records == [expected])
            sourceBatchIDs.append(batchID)
        }
        for batchID in sourceBatchIDs {
            try await restartedTransport.acknowledgeFetchedBatch(batchID)
        }
        guard case .stateUpdated? = await restartedEvents.next() else {
            Issue.record("Expected final equal-revision frontier")
            return
        }
        #expect(try encodedState(fixture.store.load()) == encodedState(finalState))
    }

    @Test func restoredSourceRecordCoversDurableDeletionAtSuccessfulFetchFrontier() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let incomingStore = FileCloudIncomingBatchStore(
            url: fixture.root.appendingPathComponent("incoming-batches.json"),
            maximumBatchCount: 1
        )
        let restored = try testRecord(
            uuid: "00000000-0000-0000-0000-000000000079",
            revision: 79
        )
        let codec = CloudRecordCodec()
        let restoredCloudRecord = try codec.encode(restored, zoneID: zoneID)
        let firstTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        var firstEvents = firstTransport.events.makeAsyncIterator()
        try await firstTransport.start()
        await firstTransport.receiveFetchedChanges(
            records: [],
            deletedRecordIDs: [restoredCloudRecord.recordID]
        )
        guard case let .fetched(durableBatchID, _, _, _)? = await firstEvents.next() else {
            Issue.record("Expected durable deletion receipt")
            return
        }
        try await firstTransport.acknowledgeFetchedBatch(durableBatchID)

        let driver = TestSyncEngineDriver()
        let restartedTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in driver }
        )
        var restartedEvents = restartedTransport.events.makeAsyncIterator()
        try await restartedTransport.start()
        guard case let .fetched(replayedBatchID, _, _, _)? = await restartedEvents.next() else {
            Issue.record("Expected durable deletion replay")
            return
        }
        try await restartedTransport.acknowledgeFetchedBatch(replayedBatchID)
        let state = try stateSerialization(base64: "Dw==")
        await driver.setFetchAction { [weak restartedTransport] in
            guard let restartedTransport else { return }
            await restartedTransport.receiveFetchedChanges(
                records: [restoredCloudRecord],
                deletedRecordIDs: []
            )
            await restartedTransport.receiveStateUpdate(state)
        }

        try await restartedTransport.fetchNow()

        guard case let .fetched(batchID, _, records, deleted)? = await restartedEvents.next() else {
            Issue.record("Expected restored record as distinct work")
            return
        }
        #expect(records == [restored])
        #expect(deleted.isEmpty)
        try await restartedTransport.acknowledgeFetchedBatch(batchID)
        guard case .stateUpdated? = await restartedEvents.next() else {
            Issue.record("Expected restored-record frontier")
            return
        }
        #expect(try encodedState(fixture.store.load()) == encodedState(state))
    }

    @Test func failedFetchCannotRetireExactlyMatchedRecoveryReceiptOrPersistItsState() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let incomingURL = fixture.root.appendingPathComponent("incoming-batches.json")
        let incomingStore = FileCloudIncomingBatchStore(
            url: incomingURL,
            maximumBatchCount: 1
        )
        let record = try testRecord(
            uuid: "00000000-0000-0000-0000-000000000080",
            revision: 80
        )
        let cloudRecord = try CloudRecordCodec().encode(record, zoneID: zoneID)
        let firstTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        var firstEvents = firstTransport.events.makeAsyncIterator()
        try await firstTransport.start()
        await firstTransport.receiveFetchedChanges(records: [cloudRecord], deletedRecordIDs: [])
        guard case let .fetched(firstBatchID, _, _, _)? = await firstEvents.next() else {
            Issue.record("Expected durable receipt before failed restart fetch")
            return
        }
        try await firstTransport.acknowledgeFetchedBatch(firstBatchID)

        let driver = TestSyncEngineDriver()
        let restartedTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in driver }
        )
        var restartedEvents = restartedTransport.events.makeAsyncIterator()
        try await restartedTransport.start()
        guard case let .fetched(replayedBatchID, _, _, _)? = await restartedEvents.next() else {
            Issue.record("Expected durable replay before failed fetch")
            return
        }
        try await restartedTransport.acknowledgeFetchedBatch(replayedBatchID)
        let rejectedState = try stateSerialization(base64: "EA==")
        await driver.setFetchAction { [weak restartedTransport] in
            guard let restartedTransport else { return }
            await restartedTransport.receiveFetchedChanges(
                records: [cloudRecord],
                deletedRecordIDs: []
            )
            await restartedTransport.receiveStateUpdate(rejectedState)
        }
        await driver.failNextFetch(with: .networkFailure)

        await #expect(throws: CloudSyncFailure.self) {
            try await restartedTransport.fetchNow()
        }
        let postFailureState = try stateSerialization(base64: "EQ==")
        await restartedTransport.receiveStateUpdate(postFailureState)

        let spool = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: incomingURL)) as? [String: Any]
        )
        #expect((spool["batches"] as? [[String: Any]])?.count == 1)
        guard try fixture.store.load() == nil else {
            Issue.record("A post-failure state must not advance past the restored receipt")
            return
        }

        let recoveryDriver = TestSyncEngineDriver()
        let recoveryTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in recoveryDriver }
        )
        var recoveryEvents = recoveryTransport.events.makeAsyncIterator()
        try await recoveryTransport.start()
        guard case let .fetched(recoveryBatchID, _, recoveryRecords, _)?
                = await recoveryEvents.next() else {
            Issue.record("Expected the restored receipt to replay from disk")
            return
        }
        #expect(recoveryBatchID == replayedBatchID)
        #expect(recoveryRecords == [record])
        try await recoveryTransport.acknowledgeFetchedBatch(recoveryBatchID)

        let recoveredState = try stateSerialization(base64: "Eg==")
        await recoveryDriver.setFetchAction { [weak recoveryTransport] in
            guard let recoveryTransport else { return }
            await recoveryTransport.receiveFetchedChanges(
                records: [cloudRecord],
                deletedRecordIDs: []
            )
            await recoveryTransport.receiveStateUpdate(recoveredState)
        }

        try await recoveryTransport.fetchNow()

        guard case .stateUpdated? = await recoveryEvents.next() else {
            Issue.record("Expected successful source recovery to install its state")
            return
        }
        #expect(try encodedState(fixture.store.load()) == encodedState(recoveredState))
        let recoveredSpool = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: incomingURL)) as? [String: Any]
        )
        #expect((recoveredSpool["batches"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test func failedFetchPreservesPriorSuccessfulCoverageWaitingForAcknowledgement() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let incomingStore = FileCloudIncomingBatchStore(
            url: fixture.root.appendingPathComponent("incoming-batches.json"),
            maximumBatchCount: 2
        )
        let first = try testRecord(
            uuid: "00000000-0000-0000-0000-000000000082",
            revision: 82
        )
        let second = try testRecord(
            uuid: "00000000-0000-0000-0000-000000000083",
            revision: 83
        )
        let firstReplacement = try testRecord(
            uuid: first.id.uuid.uuidString,
            revision: 84
        )
        let codec = CloudRecordCodec()
        let firstCloudRecord = try codec.encode(first, zoneID: zoneID)
        let secondCloudRecord = try codec.encode(second, zoneID: zoneID)
        let replacementCloudRecord = try codec.encode(firstReplacement, zoneID: zoneID)
        let firstTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        var firstEvents = firstTransport.events.makeAsyncIterator()
        try await firstTransport.start()
        for cloudRecord in [firstCloudRecord, secondCloudRecord] {
            await firstTransport.receiveFetchedChanges(records: [cloudRecord], deletedRecordIDs: [])
            guard case let .fetched(batchID, _, _, _)? = await firstEvents.next() else {
                Issue.record("Expected durable receipt before restart")
                return
            }
            try await firstTransport.acknowledgeFetchedBatch(batchID)
        }

        let driver = TestSyncEngineDriver()
        let restartedTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in driver }
        )
        var restartedEvents = restartedTransport.events.makeAsyncIterator()
        try await restartedTransport.start()
        for _ in 0..<2 {
            guard case let .fetched(batchID, _, _, _)? = await restartedEvents.next() else {
                Issue.record("Expected durable replay")
                return
            }
            try await restartedTransport.acknowledgeFetchedBatch(batchID)
        }
        let successfulState = try stateSerialization(base64: "Ew==")
        await driver.setFetchAction { [weak restartedTransport] in
            guard let restartedTransport else { return }
            await restartedTransport.receiveFetchedChanges(
                records: [replacementCloudRecord],
                deletedRecordIDs: []
            )
            await restartedTransport.receiveStateUpdate(successfulState)
        }
        try await restartedTransport.fetchNow()
        guard case let .fetched(replacementBatchID, _, records, _)? = await restartedEvents.next() else {
            Issue.record("Expected replacement work waiting for domain acknowledgement")
            return
        }
        #expect(records == [firstReplacement])

        let failedState = try stateSerialization(base64: "FA==")
        await driver.setFetchAction { [weak restartedTransport] in
            guard let restartedTransport else { return }
            await restartedTransport.receiveFetchedChanges(
                records: [secondCloudRecord],
                deletedRecordIDs: []
            )
            await restartedTransport.receiveStateUpdate(failedState)
        }
        await driver.failNextFetch(with: .networkFailure)
        await #expect(throws: CloudSyncFailure.self) {
            try await restartedTransport.fetchNow()
        }

        try await restartedTransport.acknowledgeFetchedBatch(replacementBatchID)
        #expect(try encodedState(fixture.store.load()) == encodedState(successfulState))
    }

    @Test func sourceDeletionAfterDurableDeleteRestoreHistoryIsDeliveredDistinctly() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let incomingStore = FileCloudIncomingBatchStore(
            url: fixture.root.appendingPathComponent("incoming-batches.json"),
            maximumBatchCount: 2
        )
        let restored = try testRecord(
            uuid: "00000000-0000-0000-0000-000000000081",
            revision: 81
        )
        let restoredCloudRecord = try CloudRecordCodec().encode(restored, zoneID: zoneID)
        let firstTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        var firstEvents = firstTransport.events.makeAsyncIterator()
        try await firstTransport.start()
        await firstTransport.receiveFetchedChanges(
            records: [],
            deletedRecordIDs: [restoredCloudRecord.recordID]
        )
        await firstTransport.receiveFetchedChanges(
            records: [restoredCloudRecord],
            deletedRecordIDs: []
        )
        for _ in 0..<2 {
            guard case let .fetched(batchID, _, _, _)? = await firstEvents.next() else {
                Issue.record("Expected durable delete/restore history")
                return
            }
            try await firstTransport.acknowledgeFetchedBatch(batchID)
        }

        let driver = TestSyncEngineDriver()
        let restartedTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in driver }
        )
        var restartedEvents = restartedTransport.events.makeAsyncIterator()
        try await restartedTransport.start()
        for _ in 0..<2 {
            guard case let .fetched(batchID, _, _, _)? = await restartedEvents.next() else {
                Issue.record("Expected durable delete/restore replay")
                return
            }
            try await restartedTransport.acknowledgeFetchedBatch(batchID)
        }
        let state = try stateSerialization(base64: "Eg==")
        await driver.setFetchAction { [weak restartedTransport] in
            guard let restartedTransport else { return }
            await restartedTransport.receiveFetchedChanges(
                records: [],
                deletedRecordIDs: [restoredCloudRecord.recordID]
            )
            await restartedTransport.receiveStateUpdate(state)
        }

        try await restartedTransport.fetchNow()

        guard try fixture.store.load() == nil else {
            Issue.record("Deletion state must wait for distinct domain acknowledgement")
            return
        }
        guard case let .fetched(batchID, _, records, deleted)? = await restartedEvents.next() else {
            Issue.record("Expected final source deletion as distinct work")
            return
        }
        #expect(records.isEmpty)
        #expect(deleted == [restored.id])
        try await restartedTransport.acknowledgeFetchedBatch(batchID)
        guard case .stateUpdated? = await restartedEvents.next() else {
            Issue.record("Expected final deletion frontier")
            return
        }
        #expect(try encodedState(fixture.store.load()) == encodedState(state))
    }

    @Test func repeatedMixedSplitCallbacksRemainDurableWithinByteBound() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let incomingStore = FileCloudIncomingBatchStore(
            url: fixture.root.appendingPathComponent("incoming-batches.json"),
            maximumBatchCount: 1
        )
        let durable = try (70...72).map { suffix in
            try testRecord(
                uuid: String(format: "00000000-0000-0000-0000-%012d", suffix),
                revision: UInt64(suffix)
            )
        }
        let distinct = try (73...75).map { suffix in
            try testRecord(
                uuid: String(format: "00000000-0000-0000-0000-%012d", suffix),
                revision: UInt64(suffix)
            )
        }
        let codec = CloudRecordCodec()
        let durableCloudRecords = try durable.map { try codec.encode($0, zoneID: zoneID) }
        let distinctCloudRecords = try distinct.map { try codec.encode($0, zoneID: zoneID) }
        let firstTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        var firstEvents = firstTransport.events.makeAsyncIterator()
        try await firstTransport.start()
        await firstTransport.receiveFetchedChanges(
            records: durableCloudRecords,
            deletedRecordIDs: []
        )
        guard case let .fetched(firstBatchID, _, _, _)? = await firstEvents.next() else {
            Issue.record("Expected durable aggregate before restart")
            return
        }
        try await firstTransport.acknowledgeFetchedBatch(firstBatchID)

        let driver = TestSyncEngineDriver()
        let restartedTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in driver }
        )
        var restartedEvents = restartedTransport.events.makeAsyncIterator()
        try await restartedTransport.start()
        guard case let .fetched(replayedBatchID, _, _, _)? = await restartedEvents.next() else {
            Issue.record("Expected durable aggregate replay")
            return
        }
        try await restartedTransport.acknowledgeFetchedBatch(replayedBatchID)
        let states = try ["CA==", "CQ==", "Cg=="].map(stateSerialization(base64:))
        await driver.setFetchAction { [weak restartedTransport] in
            guard let restartedTransport else { return }
            for index in durableCloudRecords.indices {
                await restartedTransport.receiveFetchedChanges(
                    records: [durableCloudRecords[index], distinctCloudRecords[index]],
                    deletedRecordIDs: []
                )
                await restartedTransport.receiveStateUpdate(states[index])
            }
        }

        try await restartedTransport.fetchNow()

        var deliveredBatchIDs: [UUID] = []
        for expectedRecord in distinct {
            guard case let .fetched(batchID, _, records, _)? = await restartedEvents.next() else {
                Issue.record("Expected every distinct split-callback record")
                return
            }
            #expect(records == [expectedRecord])
            deliveredBatchIDs.append(batchID)
        }
        for batchID in deliveredBatchIDs {
            try await restartedTransport.acknowledgeFetchedBatch(batchID)
        }
        guard case .stateUpdated? = await restartedEvents.next() else {
            Issue.record("Expected final split-callback frontier after all acknowledgements")
            return
        }
        #expect(try encodedState(fixture.store.load()) == encodedState(states[2]))
    }

    @Test func accountSwitchPreservesSaturatedOldSpoolAndBlocksForeignReplay() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let incomingStore = FileCloudIncomingBatchStore(
            url: fixture.root.appendingPathComponent("incoming-batches.json"),
            maximumBatchCount: 1
        )
        let oldRecord = try testRecord(
            uuid: "00000000-0000-0000-0000-000000000056",
            revision: 56
        )
        let oldTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        try await oldTransport.start()
        await oldTransport.receiveFetchedChanges(
            records: [try CloudRecordCodec().encode(oldRecord, zoneID: zoneID)],
            deletedRecordIDs: []
        )
        let before = try Data(contentsOf: incomingStore.recoveryURL)
        await oldTransport.receiveAccountChange(previous: "account-a", current: "account-b")
        let newTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-b",
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        await #expect(throws: CloudSyncTransportError.accountResetIncomplete) {
            try await newTransport.start()
        }
        await newTransport.receiveFetchedChanges(records: [], deletedRecordIDs: [])
        #expect(try Data(contentsOf: incomingStore.recoveryURL) == before)
        #expect(try fixture.store.loadAccountOwner() == "account-a")
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

        let invalidation = await transport.invalidateForAccountTransition()
        let repeated = await transport.invalidateForAccountTransition()
        #expect(invalidation != nil && repeated != nil)

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
            try await transport.scheduleIssued([mutation])
        }

        await driver.resumeCancellation()
        await invalidation?.value
        await repeated?.value
        #expect(await driver.completedCancellationCount() == 1)
    }

    @Test func accountChangePreservesDurableStateUntilSealedCleanupAndBlocksRestart() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        try fixture.store.save(try stateSerialization(base64: "AQ=="))
        try fixture.store.bindAccountOwner("old-user")
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
            initialAccountIdentifier: "old-user",
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
        #expect(try fixture.store.load() != nil)
        #expect(try journal.pending() == [mutation])
        await #expect(throws: CloudSyncTransportError.accountResetIncomplete) {
            try await transport.start()
        }
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
            try await transport.scheduleIssued([mutation])
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
        let scheduling = Task { try await transport.scheduleIssued([mutation]) }
        await driver.waitUntilPendingReadSuspended()

        await transport.receiveAccountChange(previous: "account-a", current: "account-b")
        await driver.resumePendingRead()

        await #expect(throws: CloudSyncTransportError.staleOperation) {
            try await scheduling.value
        }
        #expect(await driver.pendingChanges().isEmpty)
    }

    @Test func accountSwitchPreservesOldStateAcrossReconstructionAndSameAccountReopen() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let persistedOldState = try stateSerialization(base64: "AQ==")
        let encodedOldState = try encodedState(persistedOldState)
        let persistedOldStateBytes = try #require(encodedOldState)
        let incomingURL = fixture.root.appendingPathComponent("incoming-batches.json")
        let incomingStore = FileCloudIncomingBatchStore(
            url: incomingURL,
            maximumBatchCount: 1
        )
        let oldRecord = try testRecord(
            uuid: "00000000-0000-0000-0000-000000000061",
            revision: 61
        )
        let oldCloudRecord = try CloudRecordCodec().encode(oldRecord, zoneID: zoneID)
        let oldTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        var oldEvents = oldTransport.events.makeAsyncIterator()
        try await oldTransport.start()
        await oldTransport.receiveStateUpdate(persistedOldState)
        guard case .stateUpdated? = await oldEvents.next() else {
            Issue.record("Expected old-account engine state to persist")
            return
        }
        await oldTransport.receiveFetchedChanges(
            records: [oldCloudRecord],
            deletedRecordIDs: []
        )
        guard case let .fetched(oldBatchID, _, _, _)? = await oldEvents.next() else {
            Issue.record("Expected old-account recovery batch")
            return
        }
        try await oldTransport.acknowledgeFetchedBatch(oldBatchID)

        try FileManager.default.removeItem(at: fixture.url)
        let target = fixture.root.appendingPathComponent("unsafe-target")
        try Data("unsafe".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.url, withDestinationURL: target)

        await oldTransport.receiveAccountChange(previous: "account-a", current: "account-b")

        let failedResetSpool = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: incomingURL)) as? [String: Any]
        )
        #expect((failedResetSpool["batches"] as? [[String: Any]])?.count == 1)

        let crossAccountSerialization = LockedCounter()
        let newTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-b",
            engineFactory: { serialization, _ in
                if serialization != nil { crossAccountSerialization.increment() }
                return TestSyncEngineDriver()
            }
        )

        await #expect(throws: CloudSyncTransportError.accountResetIncomplete) {
            try await newTransport.start()
        }
        #expect(crossAccountSerialization.value == 0)

        try FileManager.default.removeItem(at: fixture.url)
        try persistedOldStateBytes.write(to: fixture.url)
        await #expect(throws: CloudSyncTransportError.accountResetIncomplete) { try await newTransport.start() }
        #expect(crossAccountSerialization.value == 0)
        #expect(try Data(contentsOf: fixture.url) == persistedOldStateBytes)
        let returningDriver = TestSyncEngineDriver()
        let returningSerialization = LockedCounter()
        let returningTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { serialization, _ in
                if serialization != nil { returningSerialization.increment() }
                return returningDriver
            }
        )
        var returningEvents = returningTransport.events.makeAsyncIterator()
        try await returningTransport.start()
        await returningDriver.setFetchAction { [weak returningTransport] in
            guard let returningTransport else { return }
            await returningTransport.receiveFetchedChanges(
                records: [oldCloudRecord],
                deletedRecordIDs: []
            )
        }
        try await returningTransport.fetchNow()
        guard case let .fetched(_, epoch, records, _)? = await returningEvents.next() else {
            Issue.record("Expected original account to replay its preserved incoming data")
            return
        }
        #expect(returningSerialization.value == 1)
        #expect(epoch.accountIdentifier == "account-a")
        #expect(records == [oldRecord])
    }

    @Test func coldLaunchAccountMismatchPreservesOwnedStateAndForeignSpool() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let incomingStore = FileCloudIncomingBatchStore(
            url: fixture.root.appendingPathComponent("incoming-batches.json"),
            maximumBatchCount: 1
        )
        let oldTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        var oldEvents = oldTransport.events.makeAsyncIterator()
        try await oldTransport.start()
        await oldTransport.receiveStateUpdate(try stateSerialization(base64: "Bg=="))
        guard case .stateUpdated? = await oldEvents.next() else {
            Issue.record("Expected old-account state persistence")
            return
        }
        let oldRecord = try testRecord(
            uuid: "00000000-0000-0000-0000-000000000068",
            revision: 68
        )
        await oldTransport.receiveFetchedChanges(
            records: [try CloudRecordCodec().encode(oldRecord, zoneID: zoneID)],
            deletedRecordIDs: []
        )
        guard case let .fetched(oldBatchID, _, _, _)? = await oldEvents.next() else {
            Issue.record("Expected old-account spool batch")
            return
        }
        try await oldTransport.acknowledgeFetchedBatch(oldBatchID)

        let crossAccountSerialization = LockedCounter()
        let newTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-b",
            engineFactory: { serialization, _ in
                if serialization != nil { crossAccountSerialization.increment() }
                return TestSyncEngineDriver()
            }
        )
        let before = try Data(contentsOf: incomingStore.recoveryURL)
        await #expect(throws: CloudSyncTransportError.accountResetIncomplete) { try await newTransport.start() }
        #expect(crossAccountSerialization.value == 0)
        #expect(try Data(contentsOf: incomingStore.recoveryURL) == before)
        #expect(try fixture.store.load() != nil)
        #expect(try fixture.store.loadAccountOwner() == "account-a")
    }

    @Test func resetMarkerCreationFailureCannotLoseAccountMismatchAcrossReconstruction() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let zoneID = testZoneID()
        let incomingStore = FileCloudIncomingBatchStore(
            url: fixture.root.appendingPathComponent("incoming-batches.json")
        )
        let oldTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-a",
            engineFactory: { _, _ in TestSyncEngineDriver() }
        )
        var oldEvents = oldTransport.events.makeAsyncIterator()
        try await oldTransport.start()
        await oldTransport.receiveStateUpdate(try stateSerialization(base64: "Bw=="))
        guard case .stateUpdated? = await oldEvents.next() else {
            Issue.record("Expected owned old-account state")
            return
        }
        let resetMarkerURL = fixture.store.relatedURL(pathExtension: "account-reset")
        let markerTarget = fixture.root.appendingPathComponent("unsafe-reset-marker-target")
        try Data("unsafe".utf8).write(to: markerTarget)
        try FileManager.default.createSymbolicLink(
            at: resetMarkerURL,
            withDestinationURL: markerTarget
        )

        await oldTransport.receiveAccountChange(previous: "account-a", current: "account-b")

        let crossAccountSerialization = LockedCounter()
        let newTransport = CKSyncEngineTransport(
            zoneID: zoneID,
            stateStore: fixture.store,
            incomingBatchStore: incomingStore,
            initialAccountIdentifier: "account-b",
            engineFactory: { serialization, _ in
                if serialization != nil { crossAccountSerialization.increment() }
                return TestSyncEngineDriver()
            }
        )
        await #expect(throws: CloudSyncTransportError.accountResetIncomplete) {
            try await newTransport.start()
        }
        #expect(crossAccountSerialization.value == 0)

        try FileManager.default.removeItem(at: resetMarkerURL)
        await #expect(throws: CloudSyncTransportError.accountResetIncomplete) { try await newTransport.start() }
        #expect(crossAccountSerialization.value == 0)
        #expect(try fixture.store.load() != nil)
        #expect(try fixture.store.loadAccountOwner() == "account-a")
    }

    @Test(arguments: ["newerRevision", "accountReset", "zoneReset", "current"])
    func suspendedThrowingMaterializerCannotPoisonInvalidatedContext(invalidation: String) async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let driver = TestSyncEngineDriver()
        let materializer = SuspendingRecordMaterializer(zoneID: testZoneID())
        let transport = CKSyncEngineTransport(
            zoneID: testZoneID(), stateStore: fixture.store,
            recordMaterializer: { mutation, baseRecord in
                try await materializer.materialize(mutation, baseRecord: baseRecord)
            }, engineFactory: { _, _ in driver }
        )
        var events = transport.events.makeAsyncIterator()
        try await transport.start()
        let mutation = try testSaveMutation(revision: 1, mutationSuffix: 34)
        try await transport.scheduleIssued([mutation])
        try await transport.finishMutationReplay()
        await transport.receiveZoneReady(testZoneID())
        guard case .zoneReady? = await events.next() else { Issue.record("Expected ready"); return }
        let recordID = cloudRecordID(kind: mutation.recordID.kind,
            uuid: mutation.recordID.uuid.uuidString, zoneID: testZoneID())
        await materializer.suspendNextMaterialization(throwOnResume: true)
        let batching = Task {
            await transport.recordZoneChangeBatch(pendingChanges: [.saveRecord(recordID)], scope: .all)
        }
        await materializer.waitUntilSuspended()
        if invalidation == "newerRevision" {
            let replacement = try testSaveMutation(revision: 2, mutationSuffix: 34)
            try await transport.schedule([SyncVersionedMutation(mutation: replacement, journalRevision: 1)])
        } else if invalidation == "accountReset" {
            await transport.receiveAccountChange(previous: "account-a", current: "account-b")
            guard case .accountChanged? = await events.next() else { Issue.record("Expected account reset"); return }
        } else if invalidation == "zoneReset" {
            await transport.receiveDeletedZones([testZoneID()])
            guard case .zoneDeleted? = await events.next() else { Issue.record("Expected zone reset"); return }
        }
        await materializer.resume()
        _ = await batching.value
        if invalidation == "current" {
            guard case .failed(.invalidRecord(recordID: mutation.recordID))? = await events.next() else {
                Issue.record("Current materialization failure must retain invalid-record classification"); return
            }
            #expect(await transport.recordZoneChangeBatch(pendingChanges: [.saveRecord(recordID)], scope: .all) == nil)
        } else if invalidation != "accountReset" {
            if invalidation == "zoneReset" { await transport.receiveZoneReady(testZoneID()) }
            let retry = await transport.recordZoneChangeBatch(pendingChanges: [.saveRecord(recordID)], scope: .all)
            #expect(retry?.recordsToSave.count == 1)
            if invalidation == "newerRevision", let record = retry?.recordsToSave.first {
                #expect(try CloudRecordCodec().decode(record).entityRevision == 2)
            }
            if invalidation == "zoneReset" {
                guard case .zoneReady? = await events.next() else { Issue.record("Obsolete failure preceded zone readiness"); return }
            }
        }
        // A synchronously enqueued sentinel makes absence of obsolete failures observable,
        // without a sleep or a read that can wait for an event which never arrives.
        await transport.receiveAccountChange(previous: "sentinel", current: nil)
        guard case .accountChanged(previous: "sentinel", current: nil)? = await events.next() else {
            Issue.record("Obsolete materialization failure was published after invalidation"); return
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
        try await transport.scheduleIssued([mutation])
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
        try await transport.scheduleIssued([mutation])
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
        try await transport.scheduleIssued([mutation])
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
        try await transport.scheduleIssued([save, delete])
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
        guard case let .sent(sentRecordID, _, _)? = await iterator.next() else {
            Issue.record("Expected first sent event")
            return
        }
        #expect(sentRecordID.identity.recordID == record.id)
        #expect(sentRecordID.identity.mutationID == firstID)
        #expect(await driver.pendingChanges() == [.deleteRecord(recordID)])

        _ = await transport.recordZoneChangeBatch(
            pendingChanges: await driver.pendingChanges(),
            scope: .all
        )
        await driver.complete(.deleteRecord(recordID))
        await transport.receiveSentChanges(savedRecords: [], deletedRecordIDs: [recordID])
        guard case let .sent(deletedRecordID, _, _)? = await iterator.next() else {
            Issue.record("Expected second sent event")
            return
        }
        #expect(deletedRecordID.identity.recordID == record.id)
        #expect(deletedRecordID.identity.mutationID == secondID)
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

        try await transport.scheduleIssued([mutation, mutation])

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
        try await transport.scheduleIssued([.delete(
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
        try await transport.scheduleIssued([.delete(
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
        try await transport.scheduleIssued([mutation])
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

    @Test func zoneReadyInterleavedDuringResetCannotBypassRecovery() async throws {
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
        let zoneSave = CKSyncEngine.PendingDatabaseChange.saveZone(CKRecordZone(zoneID: zoneID))
        await driver.completeDatabaseChange(zoneSave)
        await transport.receiveZoneReady(zoneID)
        let mutation = try testSaveMutation(revision: 1, mutationSuffix: 64)
        try await transport.scheduleIssued([mutation])
        try await transport.finishMutationReplay()
        let recordID = cloudRecordID(
            kind: mutation.recordID.kind,
            uuid: mutation.recordID.uuid.uuidString,
            zoneID: zoneID
        )
        let sendsBeforeReset = await driver.sendCallCount()
        await driver.suspendNextPendingDatabaseRead()

        let deletion = Task { await transport.receiveDeletedZones([zoneID]) }
        await driver.waitUntilPendingDatabaseReadSuspended()
        await transport.receiveZoneReady(zoneID)

        #expect(await driver.sendCallCount() == sendsBeforeReset)
        #expect(await transport.recordZoneChangeBatch(
            pendingChanges: [.saveRecord(recordID)],
            scope: .all
        ) == nil)

        await driver.resumePendingDatabaseRead()
        await deletion.value

        #expect(await driver.pendingDatabaseChanges() == [zoneSave])
        #expect(await driver.sendCallCount() == sendsBeforeReset + 1)
        #expect(await driver.lastSendScopeContains(zoneID))
        #expect(await transport.recordZoneChangeBatch(
            pendingChanges: [.saveRecord(recordID)],
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
        try await transport.scheduleIssued([save, deletion])
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
        try await transport.scheduleIssued(mutations)
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
        try await scopedTransport.scheduleIssued(mutations)
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
        try await transport.scheduleIssued([first, second, third])
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
        guard case let .sent(firstToken, _, _)? = await iterator.next() else {
            Issue.record("Expected first send acknowledgement")
            return
        }
        #expect(firstToken.identity.mutationID == first.mutationID)

        let secondBatch = await transport.recordZoneChangeBatch(
            pendingChanges: await driver.pendingChanges(),
            scope: .all
        )!
        let secondReturnedRecord = try #require(secondBatch.recordsToSave.first)
        await transport.receiveSentChanges(savedRecords: [firstReturnedRecord], deletedRecordIDs: [])

        #expect(await driver.pendingChanges() == [.saveRecord(recordID)])
        await driver.complete(.saveRecord(recordID))
        await transport.receiveSentChanges(savedRecords: [secondReturnedRecord], deletedRecordIDs: [])
        guard case let .sent(secondToken, _, _)? = await iterator.next() else {
            Issue.record("Expected second send acknowledgement")
            return
        }
        #expect(secondToken.identity.mutationID == second.mutationID)
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
        try await transport.scheduleIssued([first, deletion, third])
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
        try await transport.scheduleIssued([first])
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
        guard case let  .mutationFailed(_, failedID, .invalidArguments, _, _, _)? = await iterator.next() else {
            Issue.record("Expected identified permanent head failure")
            return
        }
        #expect(failedID == first.mutationID)
        #expect(await transport.recordZoneChangeBatch(
            pendingChanges: [.saveRecord(recordID)],
            scope: .all
        ) == nil)

        await transport.receiveSentChanges(savedRecords: [firstRecord], deletedRecordIDs: [])
        #expect(await transport.recordZoneChangeBatch(pendingChanges: [.saveRecord(recordID)], scope: .all) == nil)
        #expect(await driver.pendingChanges() == [.saveRecord(recordID)])
    }

    @Test func failedHeadCannotBeRetiredByUnverifiedSuccess() async throws {
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
        try await transport.scheduleIssued([mutation])
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

        await transport.receiveSentChanges(savedRecords: [outgoing], deletedRecordIDs: [])
        #expect(await driver.pendingChanges() == [.saveRecord(recordID)])
        #expect(await transport.recordZoneChangeBatch(pendingChanges: [.saveRecord(recordID)], scope: .all) == nil)
    }
}

actor TestSyncEngineDriver: CKSyncEngineDriving {
    nonisolated let cloudKitEngineIdentifier: ObjectIdentifier? = nil
    private var pending: [CKSyncEngine.PendingRecordZoneChange]
    private var additions = 0
    private var databasePending: [CKSyncEngine.PendingDatabaseChange] = []
    private var cancellationCount = 0
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldSuspendPendingRead = false
    private var pendingReadEnteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingReadResume: CheckedContinuation<Void, Never>?
    private var shouldSuspendPendingDatabaseRead = false
    private var pendingDatabaseReadEnteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingDatabaseReadResume: CheckedContinuation<Void, Never>?
    private var shouldSuspendCancellation = false
    private var cancellationEnteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationResume: CheckedContinuation<Void, Never>?
    private var sendScopes: [CKSyncEngine.SendChangesOptions.Scope] = []
    private var shouldSuspendFetch = false
    private var fetchEnteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var fetchResume: CheckedContinuation<Void, Never>?
    private var fetchAction: (@Sendable () async -> Void)?
    private var fetchErrorCode: CKError.Code?
    private var sendAction: (@Sendable () async throws -> Void)?
    func setSendAction(_ action: @escaping @Sendable () async throws -> Void) { sendAction = action }

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

    func pendingDatabaseChanges() async -> [CKSyncEngine.PendingDatabaseChange] {
        if shouldSuspendPendingDatabaseRead {
            shouldSuspendPendingDatabaseRead = false
            let waiters = pendingDatabaseReadEnteredWaiters
            pendingDatabaseReadEnteredWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { pendingDatabaseReadResume = $0 }
        }
        return databasePending
    }

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

    func fetchChanges(_ options: CKSyncEngine.FetchChangesOptions) async throws {
        if shouldSuspendFetch {
            shouldSuspendFetch = false
            let waiters = fetchEnteredWaiters
            fetchEnteredWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { fetchResume = $0 }
        }
        await fetchAction?()
        if let fetchErrorCode {
            self.fetchErrorCode = nil
            throw CKError(fetchErrorCode)
        }
    }
    func sendChanges(_ options: CKSyncEngine.SendChangesOptions) async throws {
        sendScopes.append(options.scope)
        try await sendAction?()
    }
    func sendCallCount() -> Int { sendScopes.count }
    func lastSendScopeContains(_ zoneID: CKRecordZone.ID) -> Bool {
        sendScopes.last?.contains(CKRecord.ID(recordName: "scope-probe", zoneID: zoneID)) ?? false
    }
    func suspendNextFetch() { shouldSuspendFetch = true }
    func isFetchSuspended() -> Bool { fetchResume != nil }
    func setFetchAction(_ action: @escaping @Sendable () async -> Void) {
        fetchAction = action
    }
    func failNextFetch(with code: CKError.Code) { fetchErrorCode = code }
    func waitUntilFetchSuspended() async {
        guard shouldSuspendFetch || fetchResume == nil else { return }
        await withCheckedContinuation { fetchEnteredWaiters.append($0) }
    }
    func resumeFetch() {
        fetchResume?.resume()
        fetchResume = nil
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

    func suspendNextPendingDatabaseRead() { shouldSuspendPendingDatabaseRead = true }

    func waitUntilPendingDatabaseReadSuspended() async {
        guard shouldSuspendPendingDatabaseRead || pendingDatabaseReadResume == nil else { return }
        await withCheckedContinuation { pendingDatabaseReadEnteredWaiters.append($0) }
    }

    func resumePendingDatabaseRead() {
        pendingDatabaseReadResume?.resume()
        pendingDatabaseReadResume = nil
    }

    func suspendNextCancellation() { shouldSuspendCancellation = true }
    func isCancellationSuspended() -> Bool { cancellationResume != nil }
    func completedCancellationCount() -> Int { cancellationCount }

    func waitUntilCancellationSuspended() async {
        guard shouldSuspendCancellation || cancellationResume == nil else { return }
        await withCheckedContinuation { cancellationEnteredWaiters.append($0) }
    }

    func resumeCancellation() {
        shouldSuspendCancellation = false
        cancellationResume?.resume()
        cancellationResume = nil
    }
}

func integrationAttachment(root: URL) throws -> SyncMutation {
    let bytes = Data("Plan2 immutable attachment bytes".utf8)
    let sourceURL = root.appendingPathComponent("source.jpg")
    try bytes.write(to: sourceURL)
    let owner = SyncEntityID(kind: .project, uuid: UUID())
    let version = try SyncAttachmentVersion.issuing(slot: .init(owner: owner, role: "photo", slotID: "primary"),
        contentSHA256: Data(SHA256.hash(data: bytes)), byteCount: Int64(bytes.count), mediaType: "image/jpeg", displayFilename: "photo.jpg")
    let record = SyncRecord(schemaVersion: 1, id: .init(kind: .attachment, uuid: version.versionID),
        createdAt: Date(timeIntervalSince1970: 1), entityRevision: 1,
        payload: .init(fields: [:], attachment: version), relationships: [.init(role: "owner", target: owner)],
        deletedAt: .init(value: nil, stamp: .init(logicalRevision: 1, modifiedAt: Date(timeIntervalSince1970: 1), deviceID: "integration")))
    return try .save(recordVersion: SyncRecordVersion(record: record), attachmentSource: SyncAttachmentSource(
        fileURL: sourceURL, contentSHA256: version.contentSHA256, byteCount: version.byteCount), mutationID: UUID())
}

private actor RequestLimitObservation {
    private(set) var sizes: [Int] = []
    func append(_ size: Int) { sizes.append(size) }
}

private struct ReceiptRedeliveryFixture: Sendable {
    let fixture: StateStoreFixture
    let reopened: CKSyncEngineTransport
    let driver: TestSyncEngineDriver
    let batchID: UUID
    let cloud: [CKRecord]
}

private func withReceiptRedeliveryFixture(populated: Bool, acknowledged: Bool,
    _ body: (ReceiptRedeliveryFixture) async throws -> Void) async throws {
    let fixture = try StateStoreFixture()
    let original = CKSyncEngineTransport(zoneID: testZoneID(), stateStore: fixture.store,
        initialAccountIdentifier: "receipt-account", requiresInitialFetchReceipt: true,
        containerIdentifier: "receipt.container", engineFactory: { _, _ in TestSyncEngineDriver() })
    let driver = TestSyncEngineDriver()
    let reopened = CKSyncEngineTransport(zoneID: testZoneID(), stateStore: fixture.store,
        initialAccountIdentifier: "receipt-account", requiresInitialFetchReceipt: true,
        containerIdentifier: "receipt.container", engineFactory: { _, _ in driver })
    let result: Result<Void, any Error>
    do {
        let records = try populated ? [
            testRecord(uuid: "00000000-0000-0000-0000-000000000010", revision: 1),
            testRecord(uuid: "00000000-0000-0000-0000-000000000011", revision: 1)
        ] : []
        let cloud = try records.map { try CloudRecordCodec().encode($0, zoneID: testZoneID()) }
        var events = original.events.makeAsyncIterator()
        try await original.start()
        await original.receiveFetchedChanges(records: cloud, deletedRecordIDs: [])
        guard case let .fetched(batchID, epoch, _, _)? = await events.next() else {
            throw TestInterruption()
        }
        if acknowledged {
            let batch = try SyncRemoteBatch(accountIDHash: epoch.verifiedAccountIdentity().accountIDHash,
                batchID: batchID, records: records, deletedRecordIDs: [])
            try await original.acknowledgeFetchedBatch(batchID)
            try await original.verifyFetchedBatchAcknowledgement(batchID)
            try await original.finishFetchedBatchAcknowledgement(batch.identity)
        }
        let cancellation = await original.invalidateForAccountTransition(); await cancellation?.value
        try await reopened.start()
        if populated { await driver.setFetchAction { await reopened.receiveFetchedChanges(records: cloud, deletedRecordIDs: []) } }
        result = .success(try await body(.init(fixture: fixture, reopened: reopened, driver: driver, batchID: batchID, cloud: cloud)))
    } catch { result = .failure(error) }
    await driver.setFetchAction {}
    let originalStop = await original.invalidateForAccountTransition(); await originalStop?.value
    let reopenedStop = await reopened.invalidateForAccountTransition(); await reopenedStop?.value
    fixture.remove()
    try result.get()
}

struct StateStoreFixture: Sendable {
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

enum FreshReplayShape: CaseIterable, Sendable {
    case combined
    case split
    case reordered

    var durableCallbacks: [[Int]] {
        switch self {
        case .combined:
            [[0], [1]]
        case .split, .reordered:
            [[0, 1]]
        }
    }

    var sourceCallbacks: [[Int]] {
        switch self {
        case .combined:
            [[0, 1]]
        case .split:
            [[0], [1]]
        case .reordered:
            [[1, 0]]
        }
    }
}

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
    private var throwOnResume = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    init(zoneID: CKRecordZone.ID) {
        self.zoneID = zoneID
    }

    func suspendNextMaterialization(throwOnResume: Bool = false) {
        shouldSuspend = true
        self.throwOnResume = throwOnResume
    }

    func materialize(_ mutation: SyncMutation, baseRecord: CKRecord?) async throws -> CKRecord {
        if shouldSuspend {
            shouldSuspend = false
            let shouldThrow = throwOnResume
            let waiters = enteredWaiters
            enteredWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { resumeContinuation = $0 }
            if shouldThrow { throw CloudSyncTransportError.invalidReplacement }
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

func testZoneID() -> CKRecordZone.ID {
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

// Explicit original-issue convenience for standalone transport fixtures only.
extension CKSyncEngineTransport {
    func scheduleIssued(_ mutations: [SyncMutation]) async throws {
        try await schedule(mutations.map { try SyncVersionedMutation(mutation: $0, journalRevision: 0) })
    }
}
