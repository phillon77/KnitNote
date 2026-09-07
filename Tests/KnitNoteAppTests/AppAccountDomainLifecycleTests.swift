import CloudKit
import Combine
import Foundation
import Testing
@testable import KnitNote

@MainActor @Suite struct AppAccountDomainLifecycleTests {
    @Test func retainedAccountReconcileReusesJournalAndRevalidatesCanonical() async throws {
        try await withAccountLifecycleFixture { f in
            _ = f.lifecycle.beginTransition()
            try await f.coordinator.reconcileConfirmedAccount(f.a, now: f.now)
            let store = try #require(f.owner.visibleSession).store
            try f.rename(store, id: f.aID, name: "Retained advanced")
            let journal = f.coordinator.currentJournal
            let exact = try journal?.pending()
            _ = f.lifecycle.beginTransition()
            try await f.coordinator.reconcileConfirmedAccount(f.a, now: f.now)
            #expect(f.coordinator.currentJournal === journal)
            #expect(try journal?.pending() == exact)
            #expect(f.owner.visibleSession?.store.projects.first?.name == "Retained advanced")
        }
    }

    @Test func sameAccountReconcileAfterFailedSealRetainsExactOwnerAndPending() async throws {
        try await withAccountLifecycleFixture { f in
            _ = f.lifecycle.beginTransition()
            try await f.coordinator.reconcileConfirmedAccount(f.a, now: f.now)
            try f.rename(try #require(f.owner.visibleSession).store, id: f.aID, name: "Source survived")
            let journal = f.coordinator.currentJournal
            let exact = try journal?.pending()
            f.keys.failInsert = true
            _ = f.lifecycle.beginTransition()
            await #expect(throws: (any Error).self) {
                try await f.coordinator.reconcileConfirmedAccount(f.b, now: f.now)
            }
            #expect(f.coordinator.retainedAccount == f.a && f.owner.visibleSession == nil)
            _ = f.lifecycle.beginTransition()
            try await f.coordinator.reconcileConfirmedAccount(f.a, now: f.now)
            #expect(f.coordinator.currentJournal === journal)
            #expect(try journal?.pending() == exact)
            #expect(f.owner.visibleSession?.store.projects.first?.name == "Source survived")
            #expect(f.coordinator.completed)
        }
    }

    // Removing early local publication or dropping the receipt callback on failure
    // must fail: daily edits survive, but sends require the later real fetch.
    @Test(arguments: [CKError.Code.networkFailure, .quotaExceeded])
    func localEditingSurvivesFailureAndRetryUsesActualReceipt(code: CKError.Code) async throws {
        try await withAccountLifecycleFixture { f in
        await f.driver.suspendNextFetch()
        await f.driver.failNextFetch(with: code)
        let generation = f.lifecycle.beginTransition()
        let run = f.operation { try await f.coordinator.transition(from: nil, to: f.a, now: f.now) }
        try await f.waitForFetch(run)
        let visible = try #require(f.owner.visibleSession)
        let context = try #require(f.recording.context)
        let runtime = try #require(f.recording.runtime)
        #expect(context.journal === f.coordinator.currentJournal)
        #expect(context.journal.recoveryLocation == context.paths.mutationJournalURL)
        #expect(runtime.incoming.recoveryURL == context.paths.engineState.appendingPathComponent("engine.json.incoming-batches"))
        try await #require(f.coordinator.currentTransport).validateRecoveryBinding(account: f.a, paths: context.paths)
        #expect(visible.store.projects.map(\.id) == [f.aID])
        #expect(f.coordinator.localAccessReady && !f.coordinator.completed)
        await f.driver.resumeFetch()
        try await run.value
        try f.rename(visible.store, id: f.aID, name: "Offline")
        let exact = try #require(f.coordinator.currentJournal).pending()
        #expect(!exact.isEmpty)
        #expect(f.owner.generation == generation)
        #expect(f.owner.visibleSession === visible)
        #expect(f.coordinator.localAccessReady && !f.coordinator.completed)
        let transport = try #require(f.coordinator.currentTransport)
        await transport.receiveZoneReady(f.zone)
        await #expect(throws: (any Error).self) { try await transport.sendNow() }
        #expect(await f.driver.sendCallCount() == 0)
        await f.driver.suspendNextFetch()
        let retry = f.operation { await f.coordinator.retrySync() }
        try await f.waitForSuspendedFetch()
        await f.coordinator.retrySync()
        #expect(await f.driver.sendCallCount() == 0)
        await f.driver.resumeFetch()
        try await retry.value
        try await f.waitUntil { f.coordinator.completed }
        #expect(f.coordinator.currentTransport === transport)
        #expect(await f.driver.sendCallCount() > 0)
        #expect(try f.coordinator.currentJournal?.pending() == exact)
        }
    }

    @Test func roundTripRestoresExactPendingButRequiresRemoteBootstrapAfterCleanup() async throws {
        try await withAccountLifecycleFixture { f in
        _ = f.lifecycle.beginTransition()
        try await f.coordinator.transition(from: nil, to: f.a, now: f.now)
        let old = try #require(f.owner.visibleSession).store
        try f.rename(old, id: f.aID, name: "Advanced A")
        let pending = try f.coordinator.currentJournal?.pending()
        let edit = { try f.rename(old, id: f.aID, name: "Late A") }
        let generation = f.lifecycle.beginTransition()
        #expect(f.owner.visibleSession == nil && old.isSessionWriteRevoked)
        #expect(throws: (any Error).self) { try edit() }
        try await f.coordinator.transition(from: f.a, to: f.b, now: f.now)
        #expect(f.owner.generation == generation)
        #expect(f.owner.visibleSession?.store.projects.map(\.id) == [f.bID])
        _ = f.lifecycle.beginTransition()
        await #expect(throws: CloudAccountTransitionCoordinator.Failure.bootstrapRequired) {
            try await f.coordinator.transition(from: f.b, to: f.a, now: f.now)
        }
        #expect(f.owner.visibleSession == nil && !f.coordinator.localAccessReady)
        #expect(f.coordinator.requiresBootstrap)
        #expect(try f.coordinator.currentJournal?.pending() == pending)
        let journal = f.coordinator.currentJournal
        await f.coordinator.retrySync()
        #expect(f.coordinator.currentJournal === journal)
        #expect(try f.coordinator.currentJournal?.pending() == pending)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(f.a.identity.accountIDHash + "/working-set/projects-v1.json").path))
        }
    }

    @Test func sameAccountReopenUsesAdvancedCanonicalWithoutStaleBootstrap() async throws {
        try await withAccountLifecycleFixture { f in
        _ = f.lifecycle.beginTransition()
        try await f.coordinator.transition(from: nil, to: f.a, now: f.now)
        let store = try #require(f.owner.visibleSession).store
        try f.rename(store, id: f.aID, name: "Daily advanced")
        let pending = try f.coordinator.currentJournal?.pending()
        await f.stop()
        weak let released = f.coordinator
        f.coordinator = nil
        #expect(released == nil)
        f.coordinator = CloudAccountTransitionCoordinator(baseURL: f.root, keychain: f.keys, zoneID: f.zone,
            lifecycle: f.lifecycle, engineFactory: { [driver = f.driver] _, _ in driver })
        _ = f.lifecycle.beginTransition()
        await f.driver.failNextFetch(with: .networkUnavailable)
        try await f.coordinator.transition(from: nil, to: f.a, now: f.now)
        #expect(f.owner.visibleSession?.store.projects.first?.name == "Daily advanced")
        #expect(f.coordinator.localAccessReady && !f.coordinator.completed)
        #expect(try f.coordinator.currentJournal?.pending() == pending)
        #expect(throws: (any Error).self) { try f.rename(store, id: f.aID, name: "Released old closure") }
        }
    }

    @Test func signoutKeepsSourceSealedAndLateAccountSignalDoesNotStartTransition() async throws {
        try await withAccountLifecycleFixture { f in
        _ = f.lifecycle.beginTransition()
        try await f.coordinator.transition(from: nil, to: f.a, now: f.now)
        let old = try #require(f.owner.visibleSession).store
        let transport = try #require(f.coordinator.currentTransport)
        var signals = 0
        f.coordinator.accountInvalidatedHandler = { signals += 1 }
        await transport.receiveAccountChange(previous: "A", current: "unverified-string")
        try await f.waitUntil { signals == 1 }
        #expect(f.owner.visibleSession == nil && old.isSessionWriteRevoked)
        #expect(f.coordinator.currentTransport === transport)
        #expect(!f.coordinator.localAccessReady && !f.coordinator.completed)
        _ = f.lifecycle.beginTransition()
        try await f.coordinator.transition(from: f.a, to: nil, now: f.now)
        #expect(f.owner.visibleSession == nil && f.coordinator.completed)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(f.a.identity.accountIDHash + "/working-set/projects-v1.json").path))
        }
    }

    @Test func authenticationAmbiguityAfterLocalReadyRevokesWithoutLogoutOrCleanup() async throws {
        try await withAccountLifecycleFixture { f in
        _ = f.lifecycle.beginTransition()
        await f.driver.failNextFetch(with: .networkFailure)
        try await f.coordinator.transition(from: nil, to: f.a, now: f.now)
        let store = try #require(f.owner.visibleSession).store
        let pending = try f.coordinator.currentJournal?.pending()
        await f.driver.failNextFetch(with: .notAuthenticated)
        await f.coordinator.retrySync()
        try await f.waitUntil { !f.coordinator.localAccessReady }
        #expect(f.owner.visibleSession == nil && store.isSessionWriteRevoked)
        #expect(try f.coordinator.currentJournal?.pending() == pending)
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(f.a.identity.accountIDHash + "/working-set/projects-v1.json").path))
        }
    }

    // Missing transport invalidation leaves the real committed epoch and queued
    // automatic callback alive; dropping its join permits teardown to escape.
    @Test(arguments: ["initial", "ready", "retry", "account"])
    func blockingFailureRevokesTransportAndJoinsCancellation(stage: String) async throws {
        try await withAccountLifecycleFixture { f in
            _ = f.lifecycle.beginTransition()
            if stage == "retry" { await f.driver.failNextFetch(with: .networkFailure) }
            if stage == "initial" { await f.driver.failNextFetch(with: .notAuthenticated) }
            if stage != "initial" {
                try await f.coordinator.transition(from: nil, to: f.a, now: f.now)
                if stage == "retry" { await f.coordinator.retrySync() }
                try await f.waitUntil { f.coordinator.completed && f.coordinator.cloudStatus?.phase != .syncing }
                try #require(f.recording.committer?.epoch).requireCurrent()
            }
            let epoch = f.recording.committer?.epoch
            let store = f.owner.visibleSession?.store
            let transport = f.coordinator.currentTransport
            var sentRecords: [CKRecord] = []
            var pendingChanges: [CKSyncEngine.PendingRecordZoneChange] = []
            if let store, let transport {
                try f.rename(store, id: f.aID, name: "Pending before blocked")
                try await transport.schedule(try #require(f.coordinator.currentJournal).pendingVersioned())
                await transport.receiveZoneReady(f.zone)
                pendingChanges = await f.driver.pendingChanges()
                let batch = try #require(await transport.recordZoneChangeBatch(pendingChanges: pendingChanges, scope: .all))
                sentRecords = batch.recordsToSave
                #expect(!sentRecords.isEmpty)
            }
            let freezeCount = f.recording.freezeCount
            await f.driver.suspendNextCancellation()
            var returned = false
            let run = f.operation {
                if stage == "initial" {
                    await #expect(throws: (any Error).self) { try await f.coordinator.transition(from: nil, to: f.a, now: f.now) }
                } else if stage == "account", let transport {
                    await transport.receiveAccountChange(previous: "A", current: "unverified")
                } else {
                    await f.driver.failNextFetch(with: .notAuthenticated)
                    await f.coordinator.retrySync()
                }
                returned = true
            }
            try await f.waitUntil { f.recording.context != nil && f.coordinator.phase == .blocked && !f.coordinator.localAccessReady }
            #expect(f.owner.visibleSession == nil)
            #expect(store == nil || store?.isSessionWriteRevoked == true)
            for _ in 0..<3_000 {
                if await f.driver.isCancellationSuspended() { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(await f.driver.isCancellationSuspended())
            let active = try #require(f.coordinator.currentTransport)
            await #expect(throws: (any Error).self) { try await active.sendNow() }
            if let epoch { #expect(throws: CloudSyncAccountEpochError.stale) { try epoch.requireCurrent() } }
            #expect(await active.recordZoneChangeBatch(pendingChanges: pendingChanges, scope: .all) == nil)
            let fields = try #require(f.recording.context).paths.engineState.appendingPathComponent("system-fields.json")
            let before = try? Data(contentsOf: fields)
            await active.receiveSentChanges(savedRecords: sentRecords, deletedRecordIDs: [])
            #expect((try? Data(contentsOf: fields)) == before)
            #expect(!returned)
            #expect(f.recording.freezeCount == freezeCount + (stage == "initial" ? 1 : 0))
            let journal = f.coordinator.currentJournal
            let exact = try journal?.pending()
            var switched = false
            var next: Task<Void, any Error>?
            var blockedRetryReturned = false
            var blockedRetry: Task<Void, any Error>?
            if stage == "account" {
                blockedRetry = f.operation { await f.coordinator.retrySync(); blockedRetryReturned = true }
                for _ in 0..<20 { _ = await f.driver.isCancellationSuspended() }
                #expect(!blockedRetryReturned)
                _ = f.lifecycle.beginTransition()
                next = f.operation {
                    try await f.coordinator.transition(from: f.a, to: nil, now: f.now)
                    switched = true
                }
                // Actor round-trips let the new transition reach its join.
                for _ in 0..<20 { _ = await f.driver.isCancellationSuspended() }
                #expect(!switched && f.recording.freezeCount == freezeCount)
                #expect(try journal?.pending() == exact)
            }
            await f.driver.resumeCancellation()
            try await run.value
            try await blockedRetry?.value
            try await next?.value
            #expect(returned)
            #expect(await f.driver.completedCancellationCount() == 1)
        }
    }

    @Test func reentrantPublicationRevocationNeverLeavesCandidateVisible() async throws {
        try await withAccountLifecycleFixture { f in
        _ = f.lifecycle.beginTransition()
        var rejected: AppSessionResources?
        let observer = f.owner.$visibleSession.sink { candidate in
            guard let candidate else { return }
            rejected = candidate
            _ = f.lifecycle.beginTransition()
        }
        await #expect(throws: (any Error).self) { try await f.coordinator.transition(from: nil, to: f.a, now: f.now) }
        #expect(f.owner.visibleSession == nil && !f.coordinator.localAccessReady)
        #expect(rejected?.isStopped == true)
        #expect(await f.driver.sendCallCount() == 0)
        observer.cancel()
        }
    }

    @Test func revocationDuringFetchRejectsLateReceiptAndKeepsPending() async throws {
        try await withAccountLifecycleFixture { f in
            _ = f.lifecycle.beginTransition()
            await f.driver.suspendNextFetch()
            let run = f.operation { try await f.coordinator.transition(from: nil, to: f.a, now: f.now) }
            try await f.waitForFetch(run)
            let store = try #require(f.owner.visibleSession).store
            let retainedContext = try #require(f.recording.context)
            let exact = try f.coordinator.currentJournal?.pending()
            _ = f.lifecycle.beginTransition()
            #expect(f.owner.visibleSession == nil && store.isSessionWriteRevoked)
            #expect(throws: (any Error).self) { try retainedContext.validateOwnership() }
            await f.driver.resumeFetch()
            await #expect(throws: (any Error).self) { try await run.value }
            #expect(f.owner.visibleSession == nil && !f.coordinator.localAccessReady)
            #expect(try f.coordinator.currentJournal?.pending() == exact)
            #expect(await f.driver.sendCallCount() == 0)
        }
    }

    @Test func realProducerDrainPrecedesNamespaceInventoryAndInstallation() async throws {
        try await withAccountLifecycleFixture { f in
            let probe = AccountLifecycleDrain()
            f.drains.append(probe)
            let old = JSONProjectStore(url: f.root.appendingPathComponent("legacy.json"))
            let resources = try AppSessionResources(store: old, makeProducers: { _ in [probe] })
            try f.owner.publishPreparedSession(resources, for: f.owner.generation)
            let stray = f.root.appendingPathComponent(f.a.identity.accountIDHash + "/journal/unfinished-producer")
            try Data("retired producer will settle this".utf8).write(to: stray)
            let generation = f.lifecycle.beginTransition()
            let run = f.operation { try await f.coordinator.transition(from: nil, to: f.a, now: f.now) }
            try await f.waitUntil { probe.entered }
            #expect(f.owner.generation == generation && old.isSessionWriteRevoked)
            #expect(f.owner.visibleSession == nil && !f.coordinator.localAccessReady)
            #expect(await f.driver.sendCallCount() == 0)
            try FileManager.default.removeItem(at: stray)
            probe.release()
            try await run.value
            #expect(f.owner.visibleSession?.store.projects.map(\.id) == [f.aID])
        }
    }

    @Test func nonterminalBootstrapRollsBackBeforeAnyCheckpointDirectoryCreation() async throws {
        try await withAccountLifecycleFixture(phase: "prepared") { f in
            let live = f.root.appendingPathComponent(f.a.identity.accountIDHash + "/working-set")
            let archive = try Data(contentsOf: live.appendingPathComponent("projects-v1.json"))
            _ = f.lifecycle.beginTransition()
            await #expect(throws: CloudAccountTransitionCoordinator.Failure.bootstrapRequired) {
                try await f.coordinator.transition(from: nil, to: f.a, now: f.now)
            }
            #expect(f.coordinator.requiresBootstrap && f.owner.visibleSession == nil)
            #expect(try Data(contentsOf: live.appendingPathComponent("projects-v1.json")) == archive)
            #expect(!FileManager.default.fileExists(atPath: live.appendingPathComponent("SyncMetadata").path))
        }
    }

    @Test(arguments: [false, true])
    func fetchedPhotoRuntimeAuthorityRequiresMatchingProjectProjection(includesProjection: Bool) async throws {
        try await withAccountLifecycleFixture { f in
            _ = f.lifecycle.beginTransition()
            await f.driver.suspendNextFetch()
            let run = f.operation { try await f.coordinator.transition(from: nil, to: f.a, now: f.now) }
            try await f.waitForFetch(run)
            let store = try #require(f.owner.visibleSession).store
            var project = try #require(store.projects.first)
            let remote = f.root.appendingPathComponent("remote-photo-fixture")
            let photos = ProjectPhotoFileService(directory: remote.appendingPathComponent("ProjectPhotos"))
            let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
            project.setPhotoFilename(try photos.save(data: png, projectID: project.id))
            let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [project])
            let exported = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: remote, deviceID: "zz-actual-remote-photo")
            let attachment = try #require(exported.records.first { $0.id.kind == .attachment })
            let version = try #require(attachment.payload.attachment)
            let source = try #require(exported.attachments[attachment.id.uuid])
            let cloud = try (includesProjection ? exported.records : [attachment]).map { record in
                let value = try CloudRecordCodec().encode(record, zoneID: f.zone)
                if let bytes = exported.attachments[record.id.uuid] { value["asset"] = CKAsset(fileURL: bytes.fileURL) }
                return value
            }
            let transport = try #require(f.coordinator.currentTransport)
            let runtime = try #require(f.recording.runtime)
            await f.driver.setFetchAction { await transport.receiveFetchedChanges(records: cloud, deletedRecordIDs: []) }
            await f.driver.resumeFetch()
            if includesProjection {
                try await run.value
                #expect(f.coordinator.completed && f.coordinator.localAccessReady)
                #expect(store.projects.first?.photoFilename == project.photoFilename)
            } else {
                await #expect(throws: (any Error).self) { try await run.value }
                #expect(!f.coordinator.completed && !f.coordinator.localAccessReady)
                #expect(f.owner.visibleSession == nil && store.isSessionWriteRevoked)
                #expect(store.projects.first?.photoFilename == nil)
                #expect(await f.driver.sendCallCount() == 0)
            }
            let download = try runtime.assets.installedDownload(version: version)
            #expect(try Data(contentsOf: download) == Data(contentsOf: source.fileURL))
            await f.driver.setFetchAction {}
        }
    }

    @Test(arguments: ["seal", "canonical"])
    func authorityFailureNeverPublishesOrDeletesSource(cut: String) async throws {
        try await withAccountLifecycleFixture { f in
            _ = f.lifecycle.beginTransition()
            try await f.coordinator.transition(from: nil, to: f.a, now: f.now)
            let store = try #require(f.owner.visibleSession).store
            try f.rename(store, id: f.aID, name: "Keep me")
            let pending = try f.coordinator.currentJournal?.pending()
            if cut == "seal" {
                f.keys.failInsert = true
                _ = f.lifecycle.beginTransition()
                await #expect(throws: (any Error).self) { try await f.coordinator.transition(from: f.a, to: nil, now: f.now) }
            } else {
                await f.stop(); f.coordinator = nil
                let canonical = f.root.appendingPathComponent(f.a.identity.accountIDHash + "/working-set/SyncMetadata/canonical.json")
                try Data("corrupt authority".utf8).write(to: canonical)
                f.coordinator = CloudAccountTransitionCoordinator(baseURL: f.root, keychain: f.keys, zoneID: f.zone,
                    lifecycle: f.lifecycle, engineFactory: { [driver = f.driver] _, _ in driver })
                _ = f.lifecycle.beginTransition()
                await #expect(throws: (any Error).self) { try await f.coordinator.transition(from: nil, to: f.a, now: f.now) }
            }
            #expect(f.owner.visibleSession == nil && store.isSessionWriteRevoked)
            #expect(!f.coordinator.localAccessReady && !f.coordinator.requiresBootstrap)
            #expect(try f.coordinator.currentJournal?.pending() == pending)
            #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(f.a.identity.accountIDHash + "/working-set/projects-v1.json").path))
        }
    }
}

@MainActor final class AccountLifecycleFixture {
    let root: URL
    let a = try! CloudAccountBinding(containerIdentifier: "test.container", userRecordName: "A")
    let b = try! CloudAccountBinding(containerIdentifier: "test.container", userRecordName: "B")
    let now = Date.now
    let zone = CKRecordZone.ID(zoneName: "AccountLifecycle")
    let owner = AppSessionOwner()
    let driver = TestSyncEngineDriver()
    let keys = AccountLifecycleKeys()
    let suite = "AccountLifecycle.\(UUID())"
    let defaults: UserDefaults
    let aID: UUID
    let bID: UUID
    let lifecycle: AppAccountDomainLifecycle
    let recording: AccountLifecycleRecording
    var coordinator: CloudAccountTransitionCoordinator!
    var operations: [Task<Void, any Error>] = []
    var drains: [AccountLifecycleDrain] = []
    init(phase: String = "committed") throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("AccountLifecycle-\(UUID())")
        defaults = try #require(UserDefaults(suiteName: suite))
        aID = try Self.seed(root: root, account: a, name: "A", phase: phase)
        bID = try Self.seed(root: root, account: b, name: "B")
        lifecycle = AppAccountDomainLifecycle(owner: owner, factory: .init(entitlement: .configured(screenshotMode: true), backupHistory: BackupHistory(defaults: defaults)))
        recording = AccountLifecycleRecording(lifecycle)
        coordinator = CloudAccountTransitionCoordinator(baseURL: root, keychain: keys, zoneID: zone, lifecycle: recording, engineFactory: { [driver] _, _ in driver })
    }
    static func seed(root: URL, account: CloudAccountBinding, name: String, phase: String = "committed") throws -> UUID {
        let storage = SyncAccountStorage(baseURL: root)
        let paths = try storage.open(identity: account.identity)
        defer { try? storage.close() }
        let project = try StoredProject(name: name)
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [project])
        try JSONEncoder().encode(archive).write(to: paths.workingSet.appendingPathComponent("projects-v1.json"))
        let local = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: paths.workingSet, deviceID: "lifecycle-test-device")
        let context = SyncBootstrapContext(accountIDHash: account.identity.accountIDHash, epoch: UUID(), freezeID: UUID())
        let tx = try SyncBootstrapTransaction(liveRoot: paths.workingSet, context: context, validateContext: { guard $0 == context else { throw SyncBootstrapError.contextChanged } })
        let prepared = try tx.prepare(local: local, sourceArchive: archive, remote: .init(context: context, records: [], attachments: [:], isComplete: true))
        if phase == "committed" { try tx.install(prepared); _ = try tx.commit(prepared) }
        return project.id
    }
    func rename(_ store: JSONProjectStore, id: UUID, name: String) throws {
        try store.updateProject(id: id, name: name, toolType: nil, toolSize: nil, toolNotes: nil, photoChange: .unchanged)
    }
    func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<3_000 { if predicate() { return }; try await Task.sleep(for: .milliseconds(1)) }
        throw AccountLifecycleError.timeout
    }
    func waitForSuspendedFetch() async throws {
        for _ in 0..<3_000 { if await driver.isFetchSuspended() { return }; try await Task.sleep(for: .milliseconds(1)) }
        throw AccountLifecycleError.timeout
    }
    func waitForFetch(_ task: Task<Void, any Error>) async throws {
        do { try await waitForSuspendedFetch() }
        catch { task.cancel(); await driver.resumeFetch(); _ = try? await task.value; throw error }
    }
    func stop() async {
        let visible = owner.visibleSession
        _ = lifecycle.beginTransition()
        visible?.stopForSessionTransition()
        for drain in drains { drain.release() }
        await driver.resumeFetch()
        await driver.resumeCancellation()
        await driver.setFetchAction {}
        if let transport = coordinator?.currentTransport { let cancellation = await transport.invalidateForAccountTransition(); await cancellation?.value }
        for operation in operations { _ = await operation.result }
        operations.removeAll()
        try? await owner.waitForRetiredSessions()
        try? await visible?.waitForStoppedOperations()
    }
    func operation(_ body: @escaping @MainActor () async throws -> Void) -> Task<Void, any Error> {
        let task = Task { try await body() }; operations.append(task); return task
    }
    func remove() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
}
@MainActor func withAccountLifecycleFixture(phase: String = "committed", _ body: (AccountLifecycleFixture) async throws -> Void) async throws {
    let f = try AccountLifecycleFixture(phase: phase)
    let result: Result<Void, any Error>
    do { result = .success(try await body(f)) } catch { result = .failure(error) }
    await Task { @MainActor in await f.stop() }.value
    f.coordinator = nil
    f.remove()
    try result.get()
}
private enum AccountLifecycleError: Error { case timeout }
final class AccountLifecycleKeys: SyncRecoveryVaultKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: Data] = [:]
    var failInsert = false
    func insert(_ key: Data, for id: UUID) throws { lock.lock(); defer { lock.unlock() }; if failInsert { throw AccountLifecycleError.timeout }; values[id] = key }
    func key(for id: UUID) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[id] }
    func remove(for id: UUID) throws { lock.lock(); defer { lock.unlock() }; values[id] = nil }
}
@MainActor final class AccountLifecycleDrain: AppSessionProducer {
    var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func stopForSessionTransition() {}
    func waitForStoppedOperations() async throws {
        entered = true
        if !released { await withCheckedContinuation { waiter = $0 } }
        try Task.checkCancellation()
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
@MainActor final class AccountLifecycleRecording: CloudAccountDomainLifecycle {
    let concrete: AppAccountDomainLifecycle
    var context: AppAccountDomainContext?
    var runtime: AppAccountDomainRuntime?
    var committer: AccountLifecycleCommitter?
    var freezeCount = 0
    var installationCount = 0
    init(_ concrete: AppAccountDomainLifecycle) { self.concrete = concrete }
    func stopPublishingAndHide() throws { try concrete.stopPublishingAndHide() }
    func captureTransitionValidation() -> () throws -> Void { concrete.captureTransitionValidation() }
    func freeze(account: CloudAccountBinding, paths: SyncAccountStorage.Paths, journal: FileSyncMutationJournal) async throws {
        freezeCount += 1
        try await concrete.freeze(account: account, paths: paths, journal: journal)
    }
    func discardClosedAccount() throws { try concrete.discardClosedAccount() }
    func recoverBootstrap(context: AppAccountDomainContext) throws { try concrete.recoverBootstrap(context: context) }
    func install(context: AppAccountDomainContext, runtime: AppAccountDomainRuntime) async throws -> CloudAccountDomainInstallation {
        installationCount += 1
        self.context = context; self.runtime = runtime
        let result = try await concrete.install(context: context, runtime: runtime)
        let observed = AccountLifecycleCommitter(result.fetchedBatchCommitter)
        committer = observed
        return .init(recordProvider: result.recordProvider, fetchedBatchCommitter: observed, localAccessReady: result.localAccessReady)
    }
    func resumePublishing() throws { try concrete.resumePublishing() }
}

@MainActor final class AccountLifecycleCommitter: SyncFetchedBatchCommitting {
    let actual: any SyncFetchedBatchCommitting
    var epoch: CloudSyncAccountEpoch?
    init(_ actual: any SyncFetchedBatchCommitting) { self.actual = actual }
    func commitFetchedBatch(batch: SyncRemoteBatch, accountEpoch: CloudSyncAccountEpoch) async throws {
        try await actual.commitFetchedBatch(batch: batch, accountEpoch: accountEpoch)
        epoch = accountEpoch
    }
    func didAcknowledgeFetchedBatch(batch: SyncRemoteBatchIdentity, accountEpoch: CloudSyncAccountEpoch) async throws {
        try await actual.didAcknowledgeFetchedBatch(batch: batch, accountEpoch: accountEpoch)
    }
    func commitServerRecordChanged(input: SyncConflictInput, accountEpoch: CloudSyncAccountEpoch) async throws -> SyncConflictCommitResult {
        try await actual.commitServerRecordChanged(input: input, accountEpoch: accountEpoch)
    }
}
