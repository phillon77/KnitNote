import CloudKit
import CryptoKit
import Foundation
import Testing
@testable import KnitNote

@MainActor @Suite struct RemoteBatchCommitterIntegrationTests {
    enum Fault: Error { case injected }

    @Test func legacyFinishedProofMigratesToEnvelopeWithoutConsumingUnresolvedCapacity() throws {
        let f = try AdapterFixture(); defer { f.remove() }
        let url = f.root.appendingPathComponent("incoming.json")
        let incoming = FileCloudIncomingBatchStore(url: url, maximumBatchCount: 1)
        let g = try incoming.beginGeneration(accountIdentifier: "adapter-user", zoneID: f.zone, persistedEngineState: nil).generation
        let first = try f.batch()
        let envelope = try #require(try incoming.record(records: first.records, deletedRecordIDs: [], accountIdentifier: "adapter-user", zoneID: f.zone, generation: g).deliveredEnvelope)
        let identity = try f.batch(id: envelope.batchID).identity
        try incoming.acknowledge(envelope.batchID, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
        // Reproduce the prior format's atomic finish result exactly: a finished
        // standalone proof and its still-replayable envelope, without a marker.
        var old = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var proofs = try #require(old["acknowledgementProofs"] as? [[String: Any]])
        proofs[0]["receiptRetired"] = true
        old["acknowledgementProofs"] = proofs
        var corruptedOld = old
        var corruptedProofs = proofs
        var wrongScope = try #require(corruptedProofs[0]["scope"] as? [String: Any])
        wrongScope["zoneName"] = "wrong-zone"
        corruptedProofs[0]["scope"] = wrongScope
        corruptedOld["acknowledgementProofs"] = corruptedProofs
        let corruptedBytes = try JSONSerialization.data(withJSONObject: corruptedOld)
        try corruptedBytes.write(to: url)
        #expect(throws: CloudIncomingBatchStoreError.corrupt) {
            try incoming.beginGeneration(accountIdentifier: "adapter-user", zoneID: f.zone, persistedEngineState: nil)
        }
        #expect(try Data(contentsOf: url) == corruptedBytes)
        try JSONSerialization.data(withJSONObject: old).write(to: url)
        let restarted = try incoming.beginGeneration(accountIdentifier: "adapter-user", zoneID: f.zone, persistedEngineState: nil)
        #expect(restarted.batches.first?.retiredAcknowledgement == identity)
        #expect(restarted.batches.first?.awaitingSourceRedelivery == true)
        #expect(try incoming.acknowledgementSnapshot(accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account).requiringRetirement.isEmpty)
        try incoming.verifyAcknowledgement(identity, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
        var second = first.records[0]
        second.entityRevision += 1
        let next = try #require(try incoming.record(records: [second], deletedRecordIDs: [], accountIdentifier: "adapter-user", zoneID: f.zone, generation: restarted.generation).deliveredEnvelope)
        try incoming.acknowledge(next.batchID, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
        #expect(try incoming.acknowledgementSnapshot(accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account).requiringRetirement.map(\.batchID) == [next.batchID])
        // The cap remains one for unresolved proofs even while finished source
        // evidence is embedded in A. A third legitimate spillover cannot ACK.
        second.entityRevision += 1
        let third = try #require(try incoming.record(records: [second], deletedRecordIDs: [], accountIdentifier: "adapter-user", zoneID: f.zone, generation: restarted.generation).deliveredEnvelope)
        #expect(throws: CloudIncomingBatchStoreError.capacityExceeded) {
            try incoming.acknowledge(third.batchID, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
        }
    }

    @Test func retiredEnvelopeMarkerCannotBypassContentValidationOrByteCapacity() throws {
        let f = try AdapterFixture(); defer { f.remove() }
        let url = f.root.appendingPathComponent("incoming.json")
        let incoming = FileCloudIncomingBatchStore(url: url)
        let g = try incoming.beginGeneration(accountIdentifier: "adapter-user", zoneID: f.zone, persistedEngineState: nil).generation
        let envelope = try #require(try incoming.record(records: f.batch().records, deletedRecordIDs: [], accountIdentifier: "adapter-user", zoneID: f.zone, generation: g).deliveredEnvelope)
        let identity = try f.batch(id: envelope.batchID).identity
        try incoming.acknowledge(envelope.batchID, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
        try incoming.finishAcknowledgement(identity, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
        let restarted = try incoming.beginGeneration(accountIdentifier: "adapter-user", zoneID: f.zone, persistedEngineState: nil)
        let before = try Data(contentsOf: url)
        let constrained = FileCloudIncomingBatchStore(url: url, maximumEncodedBytes: before.count + 128)
        var changed = try f.batch().records[0]
        changed.entityRevision += 1
        #expect(throws: CloudIncomingBatchStoreError.capacityExceeded) {
            try constrained.record(records: [changed], deletedRecordIDs: [], accountIdentifier: "adapter-user", zoneID: f.zone, generation: restarted.generation)
        }
        #expect(try Data(contentsOf: url) == before)
        var corrupt = try #require(try JSONSerialization.jsonObject(with: before) as? [String: Any])
        var batches = try #require(corrupt["batches"] as? [[String: Any]])
        batches[0]["records"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([changed]))
        corrupt["batches"] = batches
        let corruptBytes = try JSONSerialization.data(withJSONObject: corrupt)
        try corruptBytes.write(to: url)
        #expect(throws: CloudIncomingBatchStoreError.corrupt) {
            try incoming.beginGeneration(accountIdentifier: "adapter-user", zoneID: f.zone, persistedEngineState: nil)
        }
        #expect(try Data(contentsOf: url) == corruptBytes)
    }

    @Test func boundTransportSpilloverAcknowledgesBeforeCoveringStateCanRetireOldEnvelope() async throws {
        let f = try AdapterFixture(); defer { f.remove() }
        let incoming = FileCloudIncomingBatchStore(url: f.root.appendingPathComponent("incoming.json"), maximumBatchCount: 1)
        let g = try incoming.beginGeneration(accountIdentifier: "adapter-user", zoneID: f.zone, persistedEngineState: nil).generation
        let first = try f.batch()
        let envelope = try #require(try incoming.record(records: first.records, deletedRecordIDs: [], accountIdentifier: "adapter-user", zoneID: f.zone, generation: g).deliveredEnvelope)
        let batch = try f.batch(id: envelope.batchID)
        let adapter = f.adapter { try incoming.verifyAcknowledgement($0, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account) }
        try await adapter.commitFetchedBatch(batch: batch, accountEpoch: f.epoch())
        try incoming.acknowledge(envelope.batchID, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
        try await adapter.didAcknowledgeFetchedBatch(batch: batch.identity, accountEpoch: f.epoch())
        try incoming.finishAcknowledgement(batch.identity, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
        let second = try #require(try f.checkpoints.load()?.records.first { $0.id.kind == .project && $0.id.uuid != f.projectID })
        let cloudRecords = try (batch.records + [second]).map { try CloudRecordCodec().encode($0, zoneID: f.zone) }
        let state = try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: Data(#"{"data":"BA=="}"#.utf8))
        let stateStore = FileCloudSyncEngineStateStore(url: f.root.appendingPathComponent("engine.json"))
        let driver = TestSyncEngineDriver()
        let transport = CKSyncEngineTransport(zoneID: f.zone, stateStore: stateStore, incomingBatchStore: incoming,
            initialAccountIdentifier: "adapter-user", containerIdentifier: "test.container", engineFactory: { _, _ in driver })
        await driver.setFetchAction {
            await transport.receiveFetchedChanges(records: cloudRecords, deletedRecordIDs: [])
            await transport.receiveStateUpdate(state)
        }
        let coordinator = KnitNoteCloudSyncCoordinator(transport: transport, journal: f.journal, mergeEngine: SyncMergeEngine(),
            recordProvider: AdapterRecordProvider(), fetchedBatchCommitter: adapter, screenshotMode: false)
        await coordinator.start()
        await drain { coordinator.status.phase == .needsAttention || ((try? stateStore.load()) != nil && (try? f.checkpoints.load()?.remoteBatchReceipts.isEmpty) == true) }
        #expect(coordinator.status.phase != .needsAttention)
        #expect(try stateStore.load().map { try JSONEncoder().encode($0) } == JSONEncoder().encode(state))
        #expect(try f.checkpoints.load()?.remoteBatchReceipts.isEmpty == true)
        #expect(try incoming.sourceObservationSnapshot(accountIdentifier: "adapter-user", zoneID: f.zone, generation: g + 1).batches.isEmpty)
    }

    @Test func finishedStartupEvidenceDoesNotQueueRetirementAfterConcurrentSourceStateAdvance() async throws {
        let f = try AdapterFixture(); defer { f.remove() }
        let incoming = FileCloudIncomingBatchStore(url: f.root.appendingPathComponent("incoming.json"))
        let g = try incoming.beginGeneration(accountIdentifier: "adapter-user", zoneID: f.zone, persistedEngineState: nil).generation
        let envelope = try #require(try incoming.record(records: f.batch().records, deletedRecordIDs: [], accountIdentifier: "adapter-user", zoneID: f.zone, generation: g).deliveredEnvelope)
        let batch = try f.batch(id: envelope.batchID)
        let adapter = f.adapter { try incoming.verifyAcknowledgement($0, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account) }
        try await adapter.commitFetchedBatch(batch: batch, accountEpoch: f.epoch())
        try incoming.acknowledge(envelope.batchID, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
        try await adapter.didAcknowledgeFetchedBatch(batch: batch.identity, accountEpoch: f.epoch())
        try incoming.finishAcknowledgement(batch.identity, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
        let checkpoint = try f.checkpoints.load()
        let driver = TestSyncEngineDriver()
        await driver.suspendNextPendingDatabaseRead()
        let stateStore = FileCloudSyncEngineStateStore(url: f.root.appendingPathComponent("engine.json"))
        let transport = CKSyncEngineTransport(zoneID: f.zone, stateStore: stateStore, incomingBatchStore: incoming,
            initialAccountIdentifier: "adapter-user", containerIdentifier: "test.container", engineFactory: { _, _ in driver })
        let coordinator = KnitNoteCloudSyncCoordinator(transport: transport, journal: f.journal, mergeEngine: SyncMergeEngine(),
            recordProvider: AdapterRecordProvider(), fetchedBatchCommitter: adapter, screenshotMode: false)
        let start = Task { await coordinator.start() }
        await driver.waitUntilPendingDatabaseReadSuspended()
        // Startup has captured evidence, but has not enqueued reconciliation.
        // Actual source observation and covering state now delete finished A.
        await transport.receiveFetchedChanges(records: try batch.records.map { try CloudRecordCodec().encode($0, zoneID: f.zone) }, deletedRecordIDs: [])
        let state = try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: Data(#"{"data":"BA=="}"#.utf8))
        await transport.receiveStateUpdate(state)
        #expect(try incoming.sourceObservationSnapshot(accountIdentifier: "adapter-user", zoneID: f.zone, generation: g + 1).batches.isEmpty)
        await driver.resumePendingDatabaseRead()
        await start.value
        await transport.receiveZoneReady(f.zone)
        await drain { coordinator.status.lastCompleteSuccess != nil || coordinator.status.phase == .needsAttention }
        #expect(coordinator.status.issue == nil)
        #expect(coordinator.status.lastCompleteSuccess != nil)
        #expect(try f.checkpoints.load() == checkpoint)
        #expect(try f.journal.pending().isEmpty)
    }

    @Test func stalePreparationRetriesOnlyThreeTimes() async throws {
        var armed = false
        var attempts = 0
        let f = try AdapterFixture(ownership: {
            if armed { attempts += 1; throw SyncBootstrapError.sourceChanged }
        }); defer { f.remove() }
        let batch = try f.batch()
        armed = true
        await #expect(throws: SyncBootstrapError.sourceChanged) {
            try await f.adapter { _ in }.commitFetchedBatch(batch: batch, accountEpoch: f.epoch())
        }
        #expect(attempts == 3)
        armed = false
        #expect(f.store.project(id: f.projectID)?.name == "First")
        #expect(try f.journal.pending().isEmpty)
    }

    @Test func wrongContainerAndMissingCanonicalAuthorityNeverAcknowledge() async throws {
        let f = try AdapterFixture(); defer { f.remove() }
        let batch = try f.batch()
        let wrong = CloudSyncAccountEpoch(accountIdentifier: "adapter-user", zoneID: f.zone, generation: 1, containerIdentifier: "wrong.container")
        await #expect(throws: SyncRemoteBatchError.missingAuthority) {
            try await f.adapter { _ in }.commitFetchedBatch(batch: batch, accountEpoch: wrong)
        }
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("Live/SyncMetadata/canonical.json"))
        let transport = AdapterTransport()
        let coordinator = f.coordinator(adapter: f.adapter { _ in throw Fault.injected }, transport: transport)
        await coordinator.start()
        transport.emit(.fetched(batchID: batch.identity.batchID, accountEpoch: f.epoch(), records: batch.records, deleted: []))
        await drain { coordinator.status.phase == .needsAttention }
        #expect(coordinator.status.issue == .durableCommit)
        #expect(transport.acknowledged.isEmpty)
        #expect(f.store.project(id: f.projectID)?.name == "First")
    }

    @Test func stagedStateRepairAndResetRetainUnretiredProofs() throws {
        let f = try AdapterFixture(); defer { f.remove() }
        let incoming = FileCloudIncomingBatchStore(url: f.root.appendingPathComponent("incoming.json"))
        let g = try incoming.beginGeneration(accountIdentifier: "adapter-user", zoneID: f.zone, persistedEngineState: nil).generation
        let envelope = try #require(try incoming.record(records: f.batch().records, deletedRecordIDs: [], accountIdentifier: "adapter-user", zoneID: f.zone, generation: g).deliveredEnvelope)
        let identity = try f.batch(id: envelope.batchID).identity
        try incoming.acknowledge(envelope.batchID, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
        try incoming.stageStateCommit(engineState: Data([7]), coveredBatchIDs: [envelope.batchID])
        #expect(try incoming.beginGeneration(accountIdentifier: "adapter-user", zoneID: f.zone, persistedEngineState: Data([7])).batches.isEmpty)
        try incoming.verifyAcknowledgement(identity, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
        try incoming.retireAllAfterEngineStateReset()
        try incoming.verifyAcknowledgement(identity, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
        try incoming.finishAcknowledgement(identity, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
        #expect(try incoming.acknowledgements(accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account).isEmpty)
    }

    @Test func emptyIncomingFileIsCorruptRatherThanFreshAuthority() throws {
        let f = try AdapterFixture(); defer { f.remove() }
        let url = f.root.appendingPathComponent("incoming.json")
        try Data().write(to: url)
        #expect(throws: CloudIncomingBatchStoreError.corrupt) {
            try FileCloudIncomingBatchStore(url: url).beginGeneration(accountIdentifier: "adapter-user", zoneID: f.zone, persistedEngineState: nil)
        }
        #expect(try Data(contentsOf: url).isEmpty)
    }

    @Test func domainNotificationRunsAfterEpochLeaseIsReleased() async throws {
        let f = try AdapterFixture(); defer { f.remove() }
        let epoch = f.epoch()
        f.store.onRemoteDomainCommitted = { _ in
            let completed = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { epoch.invalidate(); completed.signal() }
            #expect(completed.wait(timeout: .now() + 0.5) == .success)
        }
        try await f.adapter { _ in }.commitFetchedBatch(batch: f.batch(), accountEpoch: epoch)
    }

    @Test func proofCapacityFailurePreservesUnacknowledgedEnvelope() throws {
        let f = try AdapterFixture(); defer { f.remove() }
        let incoming = FileCloudIncomingBatchStore(url: f.root.appendingPathComponent("incoming.json"), maximumBatchCount: 1)
        let g = try incoming.beginGeneration(accountIdentifier: "adapter-user", zoneID: f.zone, persistedEngineState: nil).generation
        func record() throws -> SyncRemoteBatchIdentity {
            let envelope = try #require(try incoming.record(records: f.batch().records, deletedRecordIDs: [], accountIdentifier: "adapter-user", zoneID: f.zone, generation: g).deliveredEnvelope)
            return try f.batch(id: envelope.batchID).identity
        }
        let first = try record()
        try incoming.acknowledge(first.batchID, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
        try incoming.stageStateCommit(engineState: Data([1]), coveredBatchIDs: [first.batchID])
        try incoming.completeStateCommit(engineState: Data([1]))
        let second = try record()
        #expect(throws: CloudIncomingBatchStoreError.capacityExceeded) {
            try incoming.acknowledge(second.batchID, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
        }
        #expect(throws: CloudSyncTransportError.unknownFetchedBatch) {
            try incoming.verifyAcknowledgement(second, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
        }
        try incoming.finishAcknowledgement(first, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
        try incoming.acknowledge(second.batchID, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
    }

    @Test func legacyAcknowledgedEnvelopeRequiresFreshCommitAndWrongContentFailsClosed() throws {
        let f = try AdapterFixture(); defer { f.remove() }
        let url = f.root.appendingPathComponent("incoming.json")
        let incoming = FileCloudIncomingBatchStore(url: url)
        let g = try incoming.beginGeneration(accountIdentifier: "adapter-user", zoneID: f.zone, persistedEngineState: nil).generation
        let envelope = try #require(try incoming.record(records: f.batch().records, deletedRecordIDs: [], accountIdentifier: "adapter-user", zoneID: f.zone, generation: g).deliveredEnvelope)
        let identity = try f.batch(id: envelope.batchID).identity
        // The old writer stores only acknowledged=true, with no compact proof.
        try incoming.acknowledge(envelope.batchID, accountIdentifier: "adapter-user", zoneID: f.zone)
        #expect(throws: CloudSyncTransportError.unknownFetchedBatch) {
            try incoming.verifyAcknowledgement(identity, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
        }
        let restarted = try incoming.beginGeneration(accountIdentifier: "adapter-user", zoneID: f.zone, persistedEngineState: nil)
        #expect(restarted.batches.first?.acknowledged == false)
        try incoming.acknowledge(envelope.batchID, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
        var changed = try f.batch().records[0]
        changed.entityRevision += 1
        let distinct = try #require(try incoming.record(records: [changed], deletedRecordIDs: [], accountIdentifier: "adapter-user", zoneID: f.zone, generation: restarted.generation).deliveredEnvelope)
        #expect(distinct.batchID != envelope.batchID)
        try incoming.verifyAcknowledgement(identity, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
        #expect(throws: CloudIncomingBatchStoreError.corrupt) {
            try incoming.verifyAcknowledgement(identity, accountIdentifier: "wrong-user", zoneID: f.zone, account: f.account)
        }
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var batches = try #require(object["batches"] as? [[String: Any]])
        batches[0]["records"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([changed]))
        object["batches"] = batches
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(throws: CloudIncomingBatchStoreError.corrupt) {
            try incoming.verifyAcknowledgement(identity, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
        }
    }

    @Test func independentIncomingInstancesSerializeReadModifyWrite() async throws {
        let f = try AdapterFixture(); defer { f.remove() }
        let url = f.root.appendingPathComponent("incoming.json")
        let zone = f.zone
        let incoming = FileCloudIncomingBatchStore(url: url)
        let generation = try incoming.beginGeneration(accountIdentifier: "adapter-user", zoneID: zone, persistedEngineState: nil).generation
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    _ = try FileCloudIncomingBatchStore(url: url).record(records: [], deletedRecordIDs: [], accountIdentifier: "adapter-user", zoneID: zone, generation: generation)
                }
            }
            try await group.waitForAll()
        }
        #expect(try incoming.beginGeneration(accountIdentifier: "adapter-user", zoneID: zone, persistedEngineState: nil).batches.count == 40)
    }

    @Test func actualTransportReconcilesCrashAfterCoreRetirementBeforeFinish() async throws {
        let f = try AdapterFixture(); defer { f.remove() }
        let incoming = FileCloudIncomingBatchStore(url: f.root.appendingPathComponent("incoming.json"))
        let g = try incoming.beginGeneration(accountIdentifier: "adapter-user", zoneID: f.zone, persistedEngineState: nil).generation
        let envelope = try #require(try incoming.record(records: f.batch().records, deletedRecordIDs: [], accountIdentifier: "adapter-user", zoneID: f.zone, generation: g).deliveredEnvelope)
        let batch = try f.batch(id: envelope.batchID)
        let adapter = f.adapter { try incoming.verifyAcknowledgement($0, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account) }
        try await adapter.commitFetchedBatch(batch: batch, accountEpoch: f.epoch())
        try incoming.acknowledge(envelope.batchID, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
        try await adapter.didAcknowledgeFetchedBatch(batch: batch.identity, accountEpoch: f.epoch())
        let before = try f.checkpoints.load()
        let transport = CKSyncEngineTransport(zoneID: f.zone, stateStore: .init(url: f.root.appendingPathComponent("engine.json")),
            incomingBatchStore: incoming, initialAccountIdentifier: "adapter-user", containerIdentifier: "test.container", engineFactory: { _, _ in TestSyncEngineDriver() })
        let coordinator = KnitNoteCloudSyncCoordinator(transport: transport, journal: f.journal, mergeEngine: SyncMergeEngine(),
            recordProvider: AdapterRecordProvider(), fetchedBatchCommitter: adapter, screenshotMode: false)
        await coordinator.start()
        await drain {
            (try? incoming.acknowledgementSnapshot(accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account).requiringRetirement.isEmpty) == true
        }
        #expect(try f.checkpoints.load() == before)
        #expect(try f.journal.pending().isEmpty)
        // Reset cannot create proof, but it can remove an envelope whose proof
        // has now completed Core retirement. A retained false marker would leak.
        try incoming.retireAllAfterEngineStateReset()
        #expect(try incoming.acknowledgements(accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account).isEmpty)
    }

    @Test func realConflictCommitsRawServerAndPreservesVersionedFIFO() async throws {
        let f = try AdapterFixture(); defer { f.remove() }
        try f.store.updateProject(id: f.projectID, name: "Local", toolType: nil, toolSize: nil, toolNotes: nil, photoChange: .unchanged)
        let pending = try f.journal.pendingVersioned()
        let head = try #require(pending.first)
        let input = try SyncConflictInput(accountIDHash: f.account.accountIDHash, failedAttemptID: UUID(),
            failedMutation: head.mutation, failedVersion: head.token, serverRecord: f.batch().records[0],
            expectedRecordQueue: pending.map(\.mutation), expectedVersions: pending.map(\.token))
        let result = try await f.adapter { _ in }.commitServerRecordChanged(input: input, accountEpoch: f.epoch())
        guard case .committed = result else { Issue.record("real adapter must commit"); return }
        #expect(f.store.project(id: f.projectID)?.name == "Remote")
        #expect(try f.journal.pendingVersioned().map { $0.token.journalRevision } == [1])
        #expect(try f.journal.pending().map(\.identity) == pending.map { $0.mutation.identity })
    }

    @Test func acknowledgementProofOutlivesEngineStateAndRetiresInBothOrders() throws {
        for finishBeforeState in [false, true] {
            let f = try AdapterFixture(); defer { f.remove() }
            let incoming = FileCloudIncomingBatchStore(url: f.root.appendingPathComponent("incoming.json"))
            let generation = try incoming.beginGeneration(accountIdentifier: "adapter-user", zoneID: f.zone, persistedEngineState: nil).generation
            let record = try f.batch().records[0]
            let envelope = try #require(try incoming.record(records: [record], deletedRecordIDs: [], accountIdentifier: "adapter-user", zoneID: f.zone, generation: generation).deliveredEnvelope)
            let identity = try f.batch(id: envelope.batchID).identity
            try incoming.acknowledge(envelope.batchID, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
            try incoming.verifyAcknowledgement(identity, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
            if finishBeforeState { try incoming.finishAcknowledgement(identity, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account) }
            let restarted = try incoming.beginGeneration(accountIdentifier: "adapter-user", zoneID: f.zone, persistedEngineState: nil)
            #expect(restarted.batches.first?.acknowledged == true)
            #expect(restarted.batches.first?.awaitingSourceRedelivery == true)
            try incoming.stageStateCommit(engineState: Data("state".utf8), coveredBatchIDs: [envelope.batchID])
            try incoming.completeStateCommit(engineState: Data("state".utf8))
            if !finishBeforeState {
                try incoming.verifyAcknowledgement(identity, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
                try incoming.finishAcknowledgement(identity, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
            }
            #expect(try incoming.acknowledgements(accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account).isEmpty)
        }
    }

    @Test func resetAbsenceCannotManufactureAcknowledgement() throws {
        let f = try AdapterFixture(); defer { f.remove() }
        let incoming = FileCloudIncomingBatchStore(url: f.root.appendingPathComponent("incoming.json"))
        let generation = try incoming.beginGeneration(accountIdentifier: "adapter-user", zoneID: f.zone, persistedEngineState: nil).generation
        let envelope = try #require(try incoming.record(records: f.batch().records, deletedRecordIDs: [], accountIdentifier: "adapter-user", zoneID: f.zone, generation: generation).deliveredEnvelope)
        let identity = try f.batch(id: envelope.batchID).identity
        try incoming.retireAllAfterEngineStateReset()
        #expect(throws: CloudSyncTransportError.unknownFetchedBatch) {
            try incoming.verifyAcknowledgement(identity, accountIdentifier: "adapter-user", zoneID: f.zone, account: f.account)
        }
    }

    @Test func realAdapterCommitsPartialStoreBeforeTransportAcknowledgement() async throws {
        let f = try AdapterFixture(); defer { f.remove() }
        let batch = try f.batch()
        let before = try #require(try f.checkpoints.load())
        let transport = AdapterTransport()
        transport.beforeAck = { #expect(f.store.project(id: f.projectID)?.name == "Remote") }
        let adapter = f.adapter { _ in guard transport.acknowledged.contains(batch.identity.batchID) else { throw Fault.injected } }
        let coordinator = f.coordinator(adapter: adapter, transport: transport)
        await coordinator.start()
        transport.emit(.fetched(batchID: batch.identity.batchID, accountEpoch: f.epoch(), records: batch.records, deleted: []))
        await drain { transport.finished.contains(batch.identity.batchID) }
        #expect(transport.acknowledged == [batch.identity.batchID])
        #expect(try f.checkpoints.load()?.remoteBatchReceipts.isEmpty == true)
        #expect(try f.checkpoints.load()?.records.filter { $0.id != batch.records[0].id } == before.records.filter { $0.id != batch.records[0].id })
        #expect(try f.journal.pending().isEmpty)
    }

    @Test func durableFailureLeavesIncomingUnacknowledged() async throws {
        var armed = false
        let f = try AdapterFixture { if armed && $0 == .afterIntent { throw Fault.injected } }; defer { f.remove() }
        let batch = try f.batch()
        armed = true
        let transport = AdapterTransport()
        let coordinator = f.coordinator(adapter: f.adapter { _ in throw Fault.injected }, transport: transport)
        await coordinator.start()
        transport.emit(.fetched(batchID: batch.identity.batchID, accountEpoch: f.epoch(), records: batch.records, deleted: []))
        await drain { coordinator.status.phase == .needsAttention }
        #expect(transport.acknowledged.isEmpty)
        #expect(coordinator.status.issue == .durableCommit)
    }

    @Test func retryAfterFailedAckPreservesExactPendingFIFO() async throws {
        let f = try AdapterFixture(); defer { f.remove() }
        let batch = try f.batch()
        let transport = AdapterTransport()
        transport.failAck = true
        let adapter = f.adapter { _ in guard !transport.failAck else { throw Fault.injected } }
        let coordinator = f.coordinator(adapter: adapter, transport: transport)
        await coordinator.start()
        let event = CloudSyncEvent.fetched(batchID: batch.identity.batchID, accountEpoch: f.epoch(), records: batch.records, deleted: [])
        transport.emit(event)
        await drain { coordinator.status.phase == .needsAttention }
        #expect(try f.checkpoints.load()?.remoteBatchReceipts.count == 1)
        try f.store.updateProject(id: f.projectID, name: "Later local edit", toolType: nil, toolSize: nil, toolNotes: nil, photoChange: .unchanged)
        let pending = try f.journal.pending()
        transport.failAck = false
        transport.emit(event)
        await drain { transport.finished.contains(batch.identity.batchID) }
        #expect(f.store.project(id: f.projectID)?.name == "Later local edit")
        #expect(try f.journal.pending() == pending)
        #expect(try f.checkpoints.load()?.remoteBatchReceipts.isEmpty == true)
    }

    @Test func saturatedReceiptsNeedAcknowledgedRetirementBeforeDuplicateACKPreservesLocalFIFO() async throws {
        let f = try AdapterFixture(); defer { f.remove() }
        let predecessor = try #require(try f.checkpoints.load())
        let saturatedReceipts = (0..<4_096).map { index in
            SyncRemoteBatchReceipt(
                identity: .init(
                    accountIDHash: predecessor.accountIDHash,
                    batchID: UUID(uuidString: String(
                        format: "70000000-0000-4000-8000-%012x",
                        index
                    ))!,
                    contentSHA256: Data(SHA256.hash(data: Data("saturated-\(index)".utf8)))
                ),
                commitID: predecessor.commitID,
                domainChanged: false
            )
        }
        let saturated = try SyncCanonicalCheckpoint(
            accountIDHash: predecessor.accountIDHash,
            commitID: predecessor.commitID,
            archiveSHA256: predecessor.archiveSHA256,
            records: predecessor.records,
            legacyRecordIDsToDelete: predecessor.legacyRecordIDsToDelete,
            remoteBatchReceipts: saturatedReceipts
        )
        try f.checkpoints.install(
            saturated,
            replacing: Data(SHA256.hash(data: predecessor.encoded()))
        )
        let store = try f.freshStore()
        let transport = AdapterTransport()
        let adapter = f.adapter(store: store) { identity in
            guard transport.acknowledged.contains(identity.batchID) else { throw Fault.injected }
        }
        let batch = try f.batch()
        let originalArchive = try Data(contentsOf: f.archiveURL)

        await #expect(throws: SyncRemoteBatchError.receiptCapacity) {
            try await adapter.commitFetchedBatch(batch: batch, accountEpoch: f.epoch())
        }
        #expect(try f.checkpoints.load() == saturated)
        #expect(try Data(contentsOf: f.archiveURL) == originalArchive)
        #expect(try f.journal.pending().isEmpty)
        #expect(store.project(id: f.projectID)?.name == "First")

        let retired = saturatedReceipts[0]
        transport.acknowledged = [retired.identity.batchID]
        try await adapter.didAcknowledgeFetchedBatch(
            batch: retired.identity,
            accountEpoch: f.epoch()
        )
        let remaining = Array(saturatedReceipts.dropFirst())
        let afterRetirement = try #require(try f.checkpoints.load())
        let expectedAfterRetirement = try SyncCanonicalCheckpoint(
            accountIDHash: saturated.accountIDHash,
            commitID: afterRetirement.commitID,
            archiveSHA256: saturated.archiveSHA256,
            records: saturated.records,
            legacyRecordIDsToDelete: saturated.legacyRecordIDsToDelete,
            remoteBatchReceipts: remaining
        )
        #expect(afterRetirement.commitID != saturated.commitID)
        #expect(afterRetirement == expectedAfterRetirement)

        transport.acknowledged.removeAll()
        transport.failAck = true
        let coordinator = f.coordinator(
            store: store,
            adapter: adapter,
            transport: transport
        )
        await coordinator.start()
        let event = CloudSyncEvent.fetched(
            batchID: batch.identity.batchID,
            accountEpoch: f.epoch(),
            records: batch.records,
            deleted: []
        )
        transport.emit(event)
        await drain { coordinator.status.phase == .needsAttention }
        let afterFailedACK = try #require(try f.checkpoints.load())
        let expectedBatchReceipt = SyncRemoteBatchReceipt(
            identity: batch.identity,
            commitID: afterFailedACK.commitID,
            domainChanged: true
        )
        let expectedRemoteRecords = afterRetirement.records.map { current in
            batch.records.first { $0.id == current.id } ?? current
        }
        let expectedAfterFailedACK = try SyncCanonicalCheckpoint(
            accountIDHash: afterRetirement.accountIDHash,
            commitID: afterFailedACK.commitID,
            archiveSHA256: Data(SHA256.hash(data: Data(contentsOf: f.archiveURL))),
            records: expectedRemoteRecords,
            legacyRecordIDsToDelete: afterRetirement.legacyRecordIDsToDelete,
            remoteBatchReceipts: remaining + [expectedBatchReceipt]
        )
        #expect(afterFailedACK == expectedAfterFailedACK)
        #expect(transport.acknowledged.isEmpty)
        #expect(store.project(id: f.projectID)?.name == "Remote")

        try store.updateProject(
            id: f.projectID,
            name: "Later local edit",
            toolType: nil,
            toolSize: nil,
            toolNotes: nil,
            photoChange: .unchanged
        )
        let exactPending = try f.journal.pending()
        #expect(exactPending.count == 1)
        let localSave = try #require(exactPending.first)
        #expect(localSave.recordID == .init(kind: .project, uuid: f.projectID))
        #expect(localSave.intent == .save)
        #expect(localSave.attachmentSource == nil)
        let afterLocalEdit = try #require(try f.checkpoints.load())
        let expectedLocalRecord = try #require(afterLocalEdit.records.first {
            $0.id == .init(kind: .project, uuid: f.projectID)
        })
        #expect(localSave.savedRecordVersion == (try SyncRecordVersion(record: expectedLocalRecord)))
        let exactArchive = try Data(contentsOf: f.archiveURL)

        transport.failAck = false
        transport.emit(event)
        await drain { transport.finished.contains(batch.identity.batchID) }
        let afterDuplicate = try #require(try f.checkpoints.load())
        let expectedAfterDuplicate = try SyncCanonicalCheckpoint(
            accountIDHash: afterLocalEdit.accountIDHash,
            commitID: afterDuplicate.commitID,
            archiveSHA256: afterLocalEdit.archiveSHA256,
            records: afterLocalEdit.records,
            legacyRecordIDsToDelete: afterLocalEdit.legacyRecordIDsToDelete,
            remoteBatchReceipts: remaining
        )
        #expect(store.project(id: f.projectID)?.name == "Later local edit")
        #expect(afterDuplicate.commitID != afterLocalEdit.commitID)
        #expect(afterDuplicate == expectedAfterDuplicate)
        #expect(try f.journal.pending() == exactPending)
        #expect(try Data(contentsOf: f.archiveURL) == exactArchive)
        #expect(transport.acknowledged == [batch.identity.batchID])
        #expect(transport.finished == [batch.identity.batchID])
    }

    @Test func epochInvalidatedAfterAttachmentAwaitPreventsStoreWrite() async throws {
        let f = try AdapterFixture(); defer { f.remove() }
        let batch = try f.batch()
        let before = try f.checkpoints.load()
        let epoch = f.epoch()
        let adapter = JSONProjectStoreRemoteBatchCommitter(store: f.store, expectedAccount: f.account,
            attachmentSources: { _ in await Task.yield(); epoch.invalidate(); return [:] }, verifyAcknowledgement: { _ in })
        await #expect(throws: CloudSyncAccountEpochError.stale) { try await adapter.commitFetchedBatch(batch: batch, accountEpoch: epoch) }
        #expect(try f.checkpoints.load() == before)
        #expect(try f.journal.pending().isEmpty)
    }

    private func drain(_ condition: () -> Bool) async {
        for _ in 0..<1000 { if condition() { return }; try? await Task.sleep(for: .milliseconds(2)) }
        #expect(condition())
    }

    @Test func retirementRetryStillRequiresDurableAcknowledgement() throws {
        let f = try AdapterFixture(); defer { f.remove() }
        let batch = try f.batch()
        _ = try f.store.commitRemoteBatch(f.store.prepareRemoteBatch(batch, attachmentSources: [:]))
        try f.store.retireRemoteBatchReceipt(batch.identity) {}
        #expect(throws: Fault.injected) {
            try f.store.retireRemoteBatchReceipt(batch.identity) { throw Fault.injected }
        }
        try f.store.retireRemoteBatchReceipt(batch.identity) {}
        #expect(try f.checkpoints.load()?.remoteBatchReceipts.isEmpty == true)
    }
}

@MainActor struct AdapterFixture {
    let root: URL
    let account: SyncAccountIdentity
    let store: JSONProjectStore
    let journal: FileSyncMutationJournal
    let checkpoints: SyncCanonicalCheckpointStore
    let projectID: UUID
    let zone = CKRecordZone.ID(zoneName: "adapter-zone", ownerName: CKCurrentUserDefaultName)
    var archiveURL: URL { root.appendingPathComponent("Live/projects-v1.json") }
    init(boundary: @escaping (SyncCanonicalPublicationBoundary) throws -> Void = { _ in },
        ownership: @escaping () throws -> Void = {}) throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("adapter-" + UUID().uuidString)
        let live = root.appendingPathComponent("Live")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        let projects = [try StoredProject(name: "First"), try StoredProject(name: "Unrelated")]
        projectID = projects[0].id
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: projects)
        let archiveURL = live.appendingPathComponent("projects-v1.json")
        try JSONEncoder().encode(archive).write(to: archiveURL)
        account = try SyncAccountIdentity(containerIdentifier: "test.container", userRecordName: "adapter-user")
        let context = SyncBootstrapContext(accountIDHash: account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let bootstrap = try SyncBootstrapTransaction(liveRoot: live, context: context, validateContext: {
            guard $0 == context else { throw SyncBootstrapError.contextChanged }
        })
        let prepared = try bootstrap.prepare(local: ProjectArchiveSyncMapper.export(archive: archive, liveRoot: live, deviceID: "local"),
            sourceArchive: archive, remote: .init(context: context, records: [], attachments: [:], isComplete: true))
        try bootstrap.install(prepared)
        _ = try bootstrap.commit(prepared)
        journal = FileSyncMutationJournal(url: live.appendingPathComponent("SyncMetadata/pending.json"))
        checkpoints = try SyncCanonicalCheckpointStore(liveRoot: live, account: account, validateOwnership: ownership)
        store = JSONProjectStore(url: archiveURL,
            backupService: KnitNoteBackupService(liveRoot: live, workRoot: root.appendingPathComponent("Backup")),
            syncCanonicalPublicationBoundary: boundary, syncMutationSink: JournalSyncMutationSink(journal: journal))
        try store.activateSyncCanonicalState(checkpointStore: checkpoints, bootstrap: bootstrap.canonicalHandoff(prepared), attachmentSources: [:])
        try journal.acknowledge(Set(journal.pending().map(\.identity)))
    }
    func batch(id: UUID = UUID()) throws -> SyncRemoteBatch {
        var record = try #require(try checkpoints.load()?.records.first { $0.id == .init(kind: .project, uuid: projectID) })
        let stamp = SyncMutationStamp(logicalRevision: 1000, modifiedAt: Date(timeIntervalSince1970: 2_000_000_000), deviceID: "remote")
        record.payload.fields["name"] = .init(value: .string("Remote"), stamp: stamp)
        return try SyncRemoteBatch(accountIDHash: account.accountIDHash, batchID: id, records: [record], deletedRecordIDs: [])
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func epoch() -> CloudSyncAccountEpoch {
        .init(accountIdentifier: "adapter-user", zoneID: zone, generation: 1, containerIdentifier: "test.container")
    }
    func adapter(verify: @escaping (SyncRemoteBatchIdentity) throws -> Void) -> JSONProjectStoreRemoteBatchCommitter {
        adapter(store: store, verify: verify)
    }
    func adapter(store: JSONProjectStore,
        verify: @escaping (SyncRemoteBatchIdentity) throws -> Void) -> JSONProjectStoreRemoteBatchCommitter {
        .init(store: store, expectedAccount: account, attachmentSources: { _ in [:] }, verifyAcknowledgement: verify)
    }
    func coordinator(adapter: JSONProjectStoreRemoteBatchCommitter, transport: AdapterTransport) -> KnitNoteCloudSyncCoordinator {
        coordinator(store: store, adapter: adapter, transport: transport)
    }
    func coordinator(store: JSONProjectStore, adapter: JSONProjectStoreRemoteBatchCommitter,
        transport: AdapterTransport) -> KnitNoteCloudSyncCoordinator {
        .init(transport: transport, journal: journal, mergeEngine: SyncMergeEngine(),
            recordProvider: AdapterRecordProvider(), fetchedBatchCommitter: adapter, screenshotMode: false)
    }
    func freshStore() throws -> JSONProjectStore {
        let value = JSONProjectStore(
            url: archiveURL,
            backupService: KnitNoteBackupService(
                liveRoot: root.appendingPathComponent("Live"),
                workRoot: root.appendingPathComponent("Backup-Fresh")
            ),
            syncMutationSink: JournalSyncMutationSink(journal: journal)
        )
        try value.activateSyncCanonicalState(
            checkpointStore: checkpoints,
            bootstrap: nil,
            attachmentSources: [:]
        )
        return value
    }
}

struct AdapterRecordProvider: SyncRecordProvider {
    func record(for id: SyncEntityID) throws -> SyncRecord? { nil }
}

@MainActor final class AdapterTransport: CloudSyncTransport {
    nonisolated let events: AsyncStream<CloudSyncEvent>
    private let continuation: AsyncStream<CloudSyncEvent>.Continuation
    var acknowledged: [UUID] = []
    var finished: [UUID] = []
    var failAck = false
    var beforeAck: () -> Void = {}
    init() { (events, continuation) = AsyncStream.makeStream() }
    func emit(_ event: CloudSyncEvent) { continuation.yield(event) }
    func start() async throws {}
    func schedule(_ mutations: [SyncVersionedMutation]) async throws {}
    func finishMutationReplay(completionID: UUID?) async throws {}
    func acknowledgeFetchedBatch(_ batchID: UUID) async throws {
        beforeAck()
        if failAck { throw RemoteBatchCommitterIntegrationTests.Fault.injected }
        acknowledged.append(batchID)
    }
    func verifyFetchedBatchAcknowledgement(_ batchID: UUID) async throws {
        guard acknowledged.contains(batchID) else { throw RemoteBatchCommitterIntegrationTests.Fault.injected }
    }
    func finishFetchedBatchAcknowledgement(_ identity: SyncRemoteBatchIdentity) async throws { finished.append(identity.batchID) }
    func resolveFailedMutation(_ resolution: SyncConflictResolution, accountEpoch: CloudSyncAccountEpoch, expectedQueue: [SyncVersionedMutation]) async throws -> CloudConflictHandoffResult { throw CloudSyncTransportError.invalidReplacement }
    func verifySentMutation(_ token: SyncMutationVersionToken, attemptID: UUID, accountEpoch: CloudSyncAccountEpoch) async throws { throw CloudSyncTransportError.staleOperation }
    func acknowledgeSentMutation(_ token: SyncMutationVersionToken, attemptID: UUID) async throws { throw CloudSyncTransportError.staleOperation }
    func fetchNow(completionID: UUID?) async throws {}
    func sendNow(completionID: UUID?) async throws {}
}
