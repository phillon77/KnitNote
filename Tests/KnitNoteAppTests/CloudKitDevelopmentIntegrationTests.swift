import CloudKit
import Foundation
import Security
import Testing
@testable import KnitNote

private enum CloudKitDevelopmentGateError: Error, Equatable {
    case productionEnvironmentRefused
}

private enum CloudKitDevelopmentGate {
    static let runVariable = "KNITNOTE_RUN_CLOUDKIT_INTEGRATION"
    static let environmentVariable = "KNITNOTE_CLOUDKIT_ENVIRONMENT"

    static func evaluate(
        environment: [String: String],
        containerIdentifier: String?,
        availability: @escaping @Sendable (String) async throws -> Bool
    ) async throws -> Bool {
        guard environment[runVariable] == "1" else { return false }

        let marker = environment[environmentVariable]?.lowercased()
        guard marker != "production" else {
            throw CloudKitDevelopmentGateError.productionEnvironmentRefused
        }
        guard marker == "development",
              let containerIdentifier,
              !containerIdentifier.isEmpty else {
            return false
        }
        return try await availability(containerIdentifier)
    }

    static func configuredContainerIdentifier() -> String? {
        Bundle.main.object(forInfoDictionaryKey: "KnitNoteCloudKitContainerIdentifier") as? String
    }

    static func liveDevelopmentContainerIsAvailable() async throws -> Bool {
        try await evaluate(
            environment: ProcessInfo.processInfo.environment,
            containerIdentifier: configuredContainerIdentifier()
        ) { identifier in
            guard let signedEnvironment = signedEntitlement(
                "com.apple.developer.icloud-container-environment"
            ) as? String else {
                return false
            }
            guard signedEnvironment.lowercased() != "production" else {
                throw CloudKitDevelopmentGateError.productionEnvironmentRefused
            }
            guard signedEnvironment.lowercased() == "development",
                  let signedContainers = signedEntitlement(
                      "com.apple.developer.icloud-container-identifiers"
                  ) as? [String],
                  signedContainers.contains(identifier) else {
                return false
            }

            let container = CKContainer(identifier: identifier)
            do {
                return try await container.accountStatus() == .available
            } catch {
                return false
            }
        }
    }

    private static func signedEntitlement(_ key: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
    }
}

@MainActor private enum CloudKitDevelopmentProbe {
    static func run(
        zoneID: CKRecordZone.ID,
        createZone: () async throws -> Void,
        exerciseRecord: () async throws -> Void,
        deleteZone: (CKRecordZone.ID) async throws -> Void
    ) async throws {
        do {
            try await createZone()
            try await exerciseRecord()
        } catch {
            _ = try? await deleteZone(zoneID)
            throw error
        }
        try await deleteZone(zoneID)
    }
}

@Suite @MainActor struct CloudKitDevelopmentIntegrationTests {
    private enum ProbeError: Error, Equatable { case create, record, cleanup }

    @Test @MainActor func offlineComposedPlan2RoundtripRestartsDurableAttachmentState() async throws {
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        try await runComposedPlan2Roundtrip(root: fixture.root, zoneID: uniqueProbeZoneID()) { record in
            let fetched = try CloudRecordCodec().encode(CloudRecordCodec().decode(record), zoneID: record.recordID.zoneID)
            if let source = (record["asset"] as? CKAsset)?.fileURL {
                let downloaded = fixture.root.appendingPathComponent("downloaded.asset")
                try FileManager.default.copyItem(at: source, to: downloaded)
                fetched["asset"] = CKAsset(fileURL: downloaded)
            }
            return fetched
        }
    }

    @Test func successfulProbeCleansUpTheExactZoneOnce() async throws {
        let chosen = uniqueProbeZoneID()
        let recorder = ProbeCleanupRecorder()

        try await CloudKitDevelopmentProbe.run(
            zoneID: chosen,
            createZone: {},
            exerciseRecord: {},
            deleteZone: { await recorder.append($0) }
        )

        #expect(await recorder.values == [chosen])
    }

    @Test func recordFailureCleansUpOnceAndPreservesThePrimaryFailure() async {
        let chosen = uniqueProbeZoneID()
        let recorder = ProbeCleanupRecorder()
        do {
            try await CloudKitDevelopmentProbe.run(
                zoneID: chosen,
                createZone: {},
                exerciseRecord: { throw ProbeError.record },
                deleteZone: { await recorder.append($0) }
            )
            Issue.record("Expected record failure")
        } catch {
            #expect(error as? ProbeError == .record)
        }
        #expect(await recorder.values == [chosen])
    }

    @Test func cleanupFailureAfterSuccessfulRecordIsReportedWithoutRetry() async {
        let chosen = uniqueProbeZoneID()
        let recorder = ProbeCleanupRecorder()
        do {
            try await CloudKitDevelopmentProbe.run(
                zoneID: chosen,
                createZone: {},
                exerciseRecord: {},
                deleteZone: {
                    await recorder.append($0)
                    throw ProbeError.cleanup
                }
            )
            Issue.record("Expected cleanup failure")
        } catch {
            #expect(error as? ProbeError == .cleanup)
        }
        #expect(await recorder.values == [chosen])
    }

    @Test func recordFailureRemainsPrimaryWhenExactCleanupAlsoFails() async {
        let chosen = uniqueProbeZoneID()
        let recorder = ProbeCleanupRecorder()
        do {
            try await CloudKitDevelopmentProbe.run(
                zoneID: chosen,
                createZone: {},
                exerciseRecord: { throw ProbeError.record },
                deleteZone: {
                    await recorder.append($0)
                    throw ProbeError.cleanup
                }
            )
            Issue.record("Expected record failure")
        } catch {
            #expect(error as? ProbeError == .record)
        }
        #expect(await recorder.values == [chosen])
    }

    @Test func ambiguousCreateFailureStillDeletesOnlyTheExactChosenZone() async {
        let chosen = CKRecordZone.ID(
            zoneName: "KnitNoteDevelopmentIntegration-\(UUID().uuidString)",
            ownerName: CKCurrentUserDefaultName
        )
        let defaultZone = CKRecordZone.default().zoneID
        let recorder = ProbeCleanupRecorder()

        do {
            try await CloudKitDevelopmentProbe.run(
                zoneID: chosen,
                createZone: {
                    throw CKError(.networkFailure)
                },
                exerciseRecord: {
                    Issue.record("record work must not run after ambiguous create failure")
                },
                deleteZone: { zoneID in
                    await recorder.append(zoneID)
                }
            )
            Issue.record("Expected the ambiguous create failure")
        } catch {
            #expect((error as? CKError)?.code == .networkFailure)
        }

        let deleted = await recorder.values
        #expect(deleted == [chosen])
        #expect(!deleted.contains(defaultZone))
    }

    @Test func productionMarkerIsRejectedBeforeContainerAccess() async {
        do {
            _ = try await CloudKitDevelopmentGate.evaluate(
                environment: [
                    CloudKitDevelopmentGate.runVariable: "1",
                    CloudKitDevelopmentGate.environmentVariable: "Production",
                ],
                containerIdentifier: "iCloud.example.invalid"
            ) { _ in
                Issue.record("The production refusal must happen before CKContainer access")
                return true
            }
            Issue.record("Expected the production environment marker to be refused")
        } catch {
            #expect(error as? CloudKitDevelopmentGateError == .productionEnvironmentRefused)
        }
    }

    @Test func missingOptInSkipsBeforeContainerAccess() async throws {
        let enabled = try await CloudKitDevelopmentGate.evaluate(
            environment: [:],
            containerIdentifier: "iCloud.example.invalid"
        ) { _ in
            Issue.record("The default-off gate must not access CKContainer")
            return true
        }

        #expect(!enabled)
    }

    @Test(
        .enabled("NOT RUN unless explicitly opted into an available Development container") {
            try await CloudKitDevelopmentGate.liveDevelopmentContainerIsAvailable()
        }
    )
    @MainActor func createsFetchesUpdatesAndDeletesUniqueDevelopmentZone() async throws {
        // Recheck the environment before constructing CKContainer in the test body.
        let environment = ProcessInfo.processInfo.environment
        guard environment[CloudKitDevelopmentGate.environmentVariable]?.lowercased() != "production" else {
            throw CloudKitDevelopmentGateError.productionEnvironmentRefused
        }
        let identifier = try #require(CloudKitDevelopmentGate.configuredContainerIdentifier())
        guard try await CloudKitDevelopmentGate.liveDevelopmentContainerIsAvailable() else { return }
        let container = CKContainer(identifier: identifier)
        let database = container.privateCloudDatabase
        let fixture = try StateStoreFixture()
        defer { fixture.remove() }
        let suffix = UUID().uuidString.lowercased()
        let zoneID = CKRecordZone.ID(
            zoneName: "KnitNoteDevelopmentIntegration-\(suffix)",
            ownerName: CKCurrentUserDefaultName
        )
        try await CloudKitDevelopmentProbe.run(
            zoneID: zoneID,
            createZone: {
                _ = try await database.save(CKRecordZone(zoneID: zoneID))
            },
            exerciseRecord: {
                try await runLiveComposedPlan2Roundtrip(root: fixture.root, zoneID: zoneID, container: container)
            },
            deleteZone: { exactZoneID in
                _ = try await database.deleteRecordZone(withID: exactZoneID)
            }
        )
    }
}

/// Offline composition uses deterministic callbacks at the engine boundary.
/// The separately gated live path below uses real CKSyncEngine delegate events.
@MainActor private func runComposedPlan2Roundtrip(
    root: URL, zoneID: CKRecordZone.ID,
    exchange: @Sendable (CKRecord) async throws -> CKRecord
) async throws {
    let stagingRoot = root.appendingPathComponent("staging")
    let staging = try CloudAssetStagingService(rootURL: stagingRoot, accountIdentifier: "probe-account")
    let mutation = try integrationAttachment(root: root)
    let version = try #require(mutation.savedRecordVersion?.record.payload.attachment)
    let journalURL = root.appendingPathComponent("journal")
    let journal = FileSyncMutationJournal(url: journalURL)
    try journal.enqueue(mutation)
    let stateStore = FileCloudSyncEngineStateStore(url: root.appendingPathComponent("engine"))
    let driver = TestSyncEngineDriver()
    let transport = CKSyncEngineTransport(zoneID: zoneID, stateStore: stateStore,
        initialAccountIdentifier: "probe-account", assetStaging: staging, engineFactory: { _, _ in driver })
    let domainURL = root.appendingPathComponent("committed-records.json")
    let committer = ProbeDurableCommitter(url: domainURL, staging: staging)
    let coordinator = KnitNoteCloudSyncCoordinator(transport: transport, journal: journal,
        mergeEngine: SyncMergeEngine(), recordProvider: committer, fetchedBatchCommitter: committer, screenshotMode: false)
    await coordinator.start()
    for _ in 0..<100 { await Task.yield() }
    try await transport.finishMutationReplay()
    await transport.receiveZoneReady(zoneID)
    let pending = await driver.pendingChanges()
    let first = try #require(await transport.recordZoneChangeBatch(pendingChanges: pending, scope: .all)?.recordsToSave.first)
    let firstAsset = try #require(first["asset"] as? CKAsset)
    let stagedURL = try #require(firstAsset.fileURL)
    await transport.receiveFailedSave(first, error: CKError(.networkFailure))
    let retry = try #require(await transport.recordZoneChangeBatch(pendingChanges: pending, scope: .all)?.recordsToSave.first)
    let retryAsset = try #require(retry["asset"] as? CKAsset)
    #expect(firstAsset !== retryAsset)
    #expect(retryAsset.fileURL == stagedURL)
    let fetched = try await exchange(retry)
    await transport.receiveSentChanges(savedRecords: [retry], deletedRecordIDs: [])
    for _ in 0..<2_000 {
        if try journal.pending().isEmpty && !FileManager.default.fileExists(atPath: stagedURL.path) { break }
        await Task.yield()
    }
    #expect(try FileSyncMutationJournal(url: journalURL).pending().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: stagedURL.path))
    await transport.receiveFetchedChanges(records: [fetched], deletedRecordIDs: [])
    for _ in 0..<2_000 {
        if FileManager.default.fileExists(atPath: domainURL.path) { break }
        await Task.yield()
    }
    let committed = try JSONDecoder().decode([SyncRecord].self, from: Data(contentsOf: domainURL))
    #expect(committed.contains { $0.payload.attachment == version })
    let restartedStaging = try CloudAssetStagingService(rootURL: stagingRoot, accountIdentifier: "probe-account")
    let installed = try restartedStaging.installedDownload(version: version)
    #expect(try Data(contentsOf: installed) == Data("Plan2 immutable attachment bytes".utf8))
    let restartedTransport = CKSyncEngineTransport(zoneID: zoneID, stateStore: stateStore,
        initialAccountIdentifier: "probe-account", assetStaging: restartedStaging,
        engineFactory: { _, _ in TestSyncEngineDriver() })
    try await restartedTransport.start()
    #expect(try FileSyncMutationJournal(url: journalURL).pending().isEmpty)
}

private final class ProbeDurableCommitter: SyncFetchedBatchCommitting, SyncRecordProvider, @unchecked Sendable {
    let url: URL
    let staging: CloudAssetStagingService
    let initialRecords: [SyncRecord]
    init(url: URL, staging: CloudAssetStagingService, initialRecords: [SyncRecord] = []) {
        self.url = url; self.staging = staging; self.initialRecords = initialRecords
    }
    func record(for id: SyncEntityID) throws -> SyncRecord? { initialRecords.first { $0.id == id } }
    func commitFetchedBatch(batchID: UUID, accountEpoch: CloudSyncAccountEpoch,
        mergeResult: SyncMergeResult, deletedRecordIDs: [SyncEntityID]) async throws {
        try accountEpoch.withCurrent {
            for record in mergeResult.records {
                if let version = record.payload.attachment { _ = try staging.installedDownload(version: version) }
            }
            try SyncDurableFile.write(JSONEncoder().encode(mergeResult.records), to: url)
        }
    }
    func commitServerRecordChanged(failedMutation: SyncMutation, accountEpoch: CloudSyncAccountEpoch,
        expectedRecordQueue: [SyncMutationIdentity], mergeResult: SyncMergeResult) async throws -> SyncFailedMutationCommitResult {
        throw CloudSyncTransportError.invalidReplacement
    }
}

@MainActor private func runLiveComposedPlan2Roundtrip(root: URL, zoneID: CKRecordZone.ID, container: CKContainer) async throws {
    let account = try await container.userRecordID().recordName
    let staging = try CloudAssetStagingService(rootURL: root.appendingPathComponent("assets"), accountIdentifier: account)
    let mutation = try integrationAttachment(root: root)
    let version = try #require(mutation.savedRecordVersion?.record.payload.attachment)
    let journalURL = root.appendingPathComponent("journal")
    let journal = FileSyncMutationJournal(url: journalURL)
    try journal.enqueue(mutation)
    let stateStore = FileCloudSyncEngineStateStore(url: root.appendingPathComponent("engine"))
    let fields = FileCloudRecordSystemFieldsStore(url: root.appendingPathComponent("system-fields"), zoneID: zoneID)
    let drivers = ProbeLiveDrivers()
    let database = container.privateCloudDatabase
    let factory: CKSyncEngineTransport.EngineFactory = { state, delegate in
        var config = CKSyncEngine.Configuration(database: database, stateSerialization: state, delegate: delegate)
        // Explicit requests make the unique-zone test bounded and prevent
        // background work from escaping cleanup. Delegate events remain real.
        config.automaticallySync = false
        let driver = LiveCKSyncEngineDriver(engine: CKSyncEngine(config))
        drivers.append(driver)
        return driver
    }
    let transport = CKSyncEngineTransport(zoneID: zoneID, stateStore: stateStore, systemFieldsStore: fields,
        initialAccountIdentifier: account, assetStaging: staging, engineFactory: factory)
    let domainURL = root.appendingPathComponent("committed-records.json")
    let committer = ProbeDurableCommitter(url: domainURL, staging: staging, initialRecords: [mutation.savedRecordVersion!.record])
    let coordinator = KnitNoteCloudSyncCoordinator(transport: transport, journal: journal, mergeEngine: SyncMergeEngine(),
        recordProvider: committer, fetchedBatchCommitter: committer, screenshotMode: false)
    do {
        await coordinator.start()
        try await transport.finishMutationReplay()
        try await waitForLiveProbe { try journal.pending().isEmpty }
        try await transport.fetchNow()
        try await waitForLiveProbe { FileManager.default.fileExists(atPath: domainURL.path) }
        #expect(try staging.installedDownload(version: version).isFileURL)
        #expect(try Data(contentsOf: staging.installedDownload(version: version)) == Data("Plan2 immutable attachment bytes".utf8))
        #expect(try stateStore.load() != nil)
        await drivers.cancelAll()
        let restartedJournal = FileSyncMutationJournal(url: journalURL)
        #expect(try restartedJournal.pending().isEmpty)
        let restarted = CKSyncEngineTransport(zoneID: zoneID, stateStore: stateStore, systemFieldsStore: fields,
            initialAccountIdentifier: account, assetStaging: staging, engineFactory: factory)
        let restartedCoordinator = KnitNoteCloudSyncCoordinator(transport: restarted, journal: restartedJournal,
            mergeEngine: SyncMergeEngine(), recordProvider: committer, fetchedBatchCommitter: committer, screenshotMode: false)
        await restartedCoordinator.start()
        try await restarted.fetchNow()
        #expect(try Data(contentsOf: staging.installedDownload(version: version)) == Data("Plan2 immutable attachment bytes".utf8))
        await drivers.cancelAll()
    } catch {
        await drivers.cancelAll()
        throw error
    }
}

@MainActor private func waitForLiveProbe(_ condition: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(90)
    while try !condition() {
        guard ContinuousClock.now < deadline else { throw CKError(.networkFailure) }
        try await Task.sleep(for: .milliseconds(100))
    }
}

private final class ProbeLiveDrivers: @unchecked Sendable {
    private let lock = NSLock()
    private var drivers: [LiveCKSyncEngineDriver] = []
    func append(_ driver: LiveCKSyncEngineDriver) { lock.withLock { drivers.append(driver) } }
    func cancelAll() async {
        let snapshot = lock.withLock { drivers }
        for driver in snapshot { await driver.cancelOperations() }
    }
}

private func uniqueProbeZoneID() -> CKRecordZone.ID {
    CKRecordZone.ID(
        zoneName: "KnitNoteDevelopmentIntegration-\(UUID().uuidString)",
        ownerName: CKCurrentUserDefaultName
    )
}

private actor ProbeCleanupRecorder {
    private(set) var values: [CKRecordZone.ID] = []

    func append(_ value: CKRecordZone.ID) {
        values.append(value)
    }
}
