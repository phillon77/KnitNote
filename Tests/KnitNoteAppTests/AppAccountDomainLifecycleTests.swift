import CloudKit
import Combine
import Foundation
import Testing
@testable import KnitNote

@MainActor @Suite struct AppAccountDomainLifecycleTests {
    // Skipping bootstrap or constructing ordinary assets early publishes/writes
    // before the full actual zone proof, which these held callbacks expose.
    @Test(arguments: ["absent", "new"])
    func freshBootstrapWaitsForFullReaderBeforeFactoryAndOrdinaryReceipt(phase: String) async throws {
        let bootstrap = AccountLifecycleBootstrapProbe()
        try await withAccountLifecycleFixture(phase: phase, bootstrap: bootstrap) { f in
            await f.driver.suspendNextFetch()
            _ = f.lifecycle.beginTransition()
            var failure: (any Error)?
            let run = f.operation {
                do { try await f.coordinator.transition(from: nil, to: f.a, now: f.now) }
                catch { failure = error }
            }
            try await f.waitUntil { bootstrap.fetchCalls.value == 1 || failure != nil }
            #expect(failure == nil)
            try #require(bootstrap.fetchCalls.value == 1)
            let op = await bootstrap.next()
            let context = try #require(bootstrap.context)
            #expect(f.owner.visibleSession == nil && f.engineCalls.value == 0)
            #expect(!FileManager.default.fileExists(atPath: context.paths.staging.appendingPathComponent("cloud-assets").path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: context.paths.engineState.path).isEmpty)
            #expect(try context.journal.recoverySnapshot().mutations.isEmpty)
            BootstrapControlledOperations.emitSuccessfulEmptyZone(op)
            bootstrap.complete(op)
            do { try await f.waitForFetch(run) }
            catch {
                if let failure { throw failure }; throw error
            }
            #expect(f.owner.visibleSession != nil && f.engineCalls.value == 1)
            #expect(f.owner.visibleSession?.store.projects.isEmpty == true)
            #expect(f.coordinator.localAccessReady && !f.coordinator.completed)
            let transport = try #require(f.coordinator.currentTransport)
            await transport.receiveZoneReady(f.zone)
            await #expect(throws: (any Error).self) { try await transport.sendNow() }
            #expect(await f.driver.sendCallCount() == 0)
            await f.driver.resumeFetch()
            try await run.value
            #expect(failure == nil && f.coordinator.completed)
        }
    }
    // A missing actual destination owner makes native bootstrap recovery unsafe.
    @Test func destinationContextCarriesItsActualStorageOwner() async throws {
        try await withAccountLifecycleFixture { f in
            _ = f.lifecycle.beginTransition()
            try await f.coordinator.reconcileConfirmedAccount(f.a, now: f.now)
            let context = try #require(f.recording.context)
            let storage = try #require(context.storage)
            try storage.withRecoveryOwnership(paths: context.paths, account: f.a.identity,
                maximumBytes: 100_000_000) { try $0.validate() }
        }
    }

    @Test func missingZoneCannotPublishOrCreateOrdinaryStateAndExplicitRetryUsesNewBridge() async throws {
        let bootstrap = AccountLifecycleBootstrapProbe()
        try await withAccountLifecycleFixture(phase: "absent", bootstrap: bootstrap) { f in
            _ = f.lifecycle.beginTransition()
            let run = f.operation { try await f.coordinator.reconcileConfirmedAccount(f.a, now: f.now) }
            try await f.waitUntil { bootstrap.fetchCalls.value == 1 }
            let op = await bootstrap.next(), context = try #require(bootstrap.context)
            op.recordZoneFetchResultBlock?(f.zone, .failure(CKError(.zoneNotFound)))
            op.fetchRecordZoneChangesResultBlock?(.success(()))
            bootstrap.complete(op)
            await #expect(throws: (any Error).self) { try await run.value }
            #expect(f.owner.visibleSession == nil && !f.coordinator.localAccessReady && !f.coordinator.completed)
            #expect(f.engineCalls.value == 0 && bootstrap.calls == 1)
            #expect(try FileManager.default.contentsOfDirectory(atPath: context.paths.engineState.path).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: context.paths.staging.appendingPathComponent("cloud-assets").path))
            #expect(await f.driver.pendingDatabaseChanges().isEmpty)
            await f.coordinator.retrySync()
            #expect(bootstrap.calls == 1 && f.engineCalls.value == 0)
            _ = f.lifecycle.beginTransition()
            let retry = f.operation { try await f.coordinator.reconcileConfirmedAccount(f.a, now: f.now) }
            try await f.waitUntil { bootstrap.fetchCalls.value == 2 }
            let next = await bootstrap.next()
            BootstrapControlledOperations.emitSuccessfulEmptyZone(next); bootstrap.complete(next)
            try await retry.value
            #expect(f.owner.visibleSession != nil && f.coordinator.completed)
            #expect(bootstrap.calls == 2 && f.engineCalls.value == 1)
        }
    }

    @Test(arguments: ["committed", "v2", "owned", "ownedFresh"])
    func verifiedCommittedRecoveryAndLaterCanonicalOpenNeverConstructReader(phase: String) async throws {
        let bootstrap = AccountLifecycleBootstrapProbe(completeImmediately: true)
        try await withAccountLifecycleFixture(phase: phase == "owned" ? "archive" : phase == "ownedFresh" ? "absent" : phase, bootstrap: bootstrap) { f in
            if phase.hasPrefix("owned") { try await f.seedOwnedBootstrap() }
            _ = f.lifecycle.beginTransition()
            try await f.coordinator.reconcileConfirmedAccount(f.a, now: f.now)
            #expect(f.owner.visibleSession != nil && f.coordinator.completed)
            #expect(bootstrap.calls == 0 && bootstrap.fetchCalls.value == 0)
            let checkpoint = try #require(f.recording.context).paths.workingSet.appendingPathComponent("SyncMetadata/canonical.json")
            #expect(FileManager.default.fileExists(atPath: checkpoint.path))
            if phase == "owned" {
                try f.rename(try #require(f.owner.visibleSession).store, id: f.aID, name: "Advanced daily canonical")
                let transport = try #require(f.coordinator.currentTransport)
                let journal = try #require(f.coordinator.currentJournal)
                let record = try #require(try journal.pending().last { $0.recordID == .init(kind: .project, uuid: f.aID) }?.savedRecordVersion?.record)
                let cloud = [try CloudRecordCodec().encode(record, zoneID: f.zone)]
                await f.driver.setFetchAction { await transport.receiveFetchedChanges(records: cloud, deletedRecordIDs: []) }
                await f.coordinator.retrySync()
                try await f.waitUntil { ((f.recording.committer?.acknowledged.count ?? 0) >= 2 && f.coordinator.completed) || !f.coordinator.localAccessReady }
                #expect(f.coordinator.completed && (f.recording.committer?.acknowledged.count ?? 0) >= 2)
                await f.driver.setFetchAction {}
                let context = try #require(f.recording.context), storage = try #require(context.storage)
                let captured = SyncBootstrapContext(accountIDHash: f.a.identity.accountIDHash, epoch: UUID(), freezeID: UUID())
                let strict = try SyncBootstrapOwnedTransaction(storage: storage, paths: context.paths, account: f.a.identity,
                    context: captured, validateContext: { guard $0 == captured else { throw SyncBootstrapError.contextChanged } })
                #expect(throws: (any Error).self) { _ = try strict.recover() }
            }
            _ = f.lifecycle.beginTransition()
            try await f.coordinator.reconcileConfirmedAccount(f.a, now: f.now)
            #expect(f.owner.visibleSession != nil && f.coordinator.completed)
            #expect(bootstrap.calls == 0 && bootstrap.fetchCalls.value == 0 && f.engineCalls.value == 2)
            if phase == "owned" { #expect(f.owner.visibleSession?.store.projects.first?.name == "Advanced daily canonical") }
        }
    }

    @Test(arguments: ["selector", "history", "original", "receipt", "bootstrapCheckpoint", "control", "canonical", "archive", "asset", "root"])
    func ownedCanonicalReopenRejectsChangedRetainedAuthority(mode: String) async throws {
        let bootstrap = AccountLifecycleBootstrapProbe(completeImmediately: true)
        try await withAccountLifecycleFixture(phase: "archive", bootstrap: bootstrap) { f in
            if mode == "asset" {
                let live = f.root.appendingPathComponent(f.a.identity.accountIDHash + "/working-set")
                var project = try StoredProject(id: f.aID, name: "A")
                project.setPhotoFilename(try ProjectPhotoFileService(directory: live.appendingPathComponent("ProjectPhotos"))
                    .save(data: CloudBootstrapFixture.jpeg(), projectID: f.aID))
                try JSONEncoder().encode(ProjectArchive(version: ProjectArchive.currentVersion, projects: [project]))
                    .write(to: live.appendingPathComponent("projects-v1.json"))
            }
            try await f.seedOwnedBootstrap(withHistory: true)
            _ = f.lifecycle.beginTransition()
            try await f.coordinator.reconcileConfirmedAccount(f.a, now: f.now)
            let context = try #require(f.recording.context), storage = try #require(context.storage)
            let entries = try storage.withRecoveryOwnership(paths: context.paths, account: f.a.identity,
                maximumBytes: 100_000_000) { try $0.entries() }
            let selected: URL
            switch mode {
            case "selector": selected = context.paths.accountRoot.appendingPathComponent(try #require(entries.first { $0.relativePath.hasSuffix("/active.json") }).relativePath)
            case "history": selected = context.paths.accountRoot.appendingPathComponent(try #require(entries.first { !$0.isDirectory && $0.relativePath.contains("/History/") }).relativePath)
            case "original": selected = context.paths.accountRoot.appendingPathComponent(try #require(entries.first { !$0.isDirectory && $0.relativePath.contains("/Original/") }).relativePath)
            case "receipt": selected = context.paths.workingSet.appendingPathComponent("SyncMetadata/bootstrap-receipt.json")
            case "bootstrapCheckpoint": selected = context.paths.workingSet.appendingPathComponent("SyncMetadata/bootstrap-canonical.json")
            case "canonical": selected = context.paths.workingSet.appendingPathComponent("SyncMetadata/canonical.json")
            case "archive": selected = context.paths.workingSet.appendingPathComponent("projects-v1.json")
            case "asset": selected = context.paths.accountRoot.appendingPathComponent(try #require(entries.first { !$0.isDirectory && $0.relativePath.contains("/Attachments/") }).relativePath)
            case "root": selected = context.paths.workingSet
            default: selected = context.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
            }
            if mode == "root" {
                let replacement = f.root.appendingPathComponent("replacement-working-set")
                try FileManager.default.copyItem(at: selected, to: replacement)
                try FileManager.default.removeItem(at: selected)
                try FileManager.default.moveItem(at: replacement, to: selected)
            } else { try Data("corrupt retained authority".utf8).write(to: selected) }
            _ = f.lifecycle.beginTransition()
            await #expect(throws: (any Error).self) { try await f.coordinator.reconcileConfirmedAccount(f.a, now: f.now) }
            #expect(f.owner.visibleSession == nil && !f.coordinator.localAccessReady && !f.coordinator.completed)
            #expect(bootstrap.calls == 0 && f.engineCalls.value == 1)
        }
    }

    @Test(arguments: ["prepared", "installed"])
    func nativeLegacyRollbackThenActualReaderInstallsSource(phase: String) async throws {
        let bootstrap = AccountLifecycleBootstrapProbe(completeImmediately: true)
        try await withAccountLifecycleFixture(phase: phase, bootstrap: bootstrap) { f in
            _ = f.lifecycle.beginTransition()
            try await f.coordinator.reconcileConfirmedAccount(f.a, now: f.now)
            #expect(f.owner.visibleSession?.store.projects.first?.id == f.aID)
            #expect(bootstrap.fetchCalls.value == 1 && f.engineCalls.value == 1)
            #expect(f.coordinator.completed)
        }
    }

    @Test func nativeMissingWorkingSetRecoveryPrecedesCanonicalProbeAndReader() async throws {
        let bootstrap = AccountLifecycleBootstrapProbe(completeImmediately: true)
        try await withAccountLifecycleFixture(phase: "archive", bootstrap: bootstrap) { f in
            let live = f.root.appendingPathComponent(f.a.identity.accountIDHash + "/working-set")
            let original = try Data(contentsOf: live.appendingPathComponent("projects-v1.json"))
            try await f.seedOwnedBootstrap(interruption: .afterLiveMove)
            #expect(!FileManager.default.fileExists(atPath: live.path))
            _ = f.lifecycle.beginTransition()
            try await f.coordinator.reconcileConfirmedAccount(f.a, now: f.now)
            #expect(f.owner.visibleSession?.store.projects.first?.name == "A")
            #expect(bootstrap.calls == 1 && bootstrap.fetchCalls.value == 1 && f.engineCalls.value == 1)
            #expect(f.coordinator.completed)
            let context = try #require(bootstrap.context), storage = try #require(context.storage)
            let entries = try storage.withRecoveryOwnership(paths: context.paths, account: f.a.identity,
                maximumBytes: 100_000_000) { try $0.entries() }
            let retained = try #require(entries.first { $0.relativePath.hasSuffix("/Original/projects-v1.json") })
            #expect(try Data(contentsOf: context.paths.accountRoot.appendingPathComponent(retained.relativePath)) == original)
        }
    }

    @Test func corruptCanonicalProbePropagatesBeforeAnyNewBridgeOrEngine() async throws {
        let bootstrap = AccountLifecycleBootstrapProbe(completeImmediately: true)
        try await withAccountLifecycleFixture(bootstrap: bootstrap) { f in
            _ = f.lifecycle.beginTransition()
            try await f.coordinator.reconcileConfirmedAccount(f.a, now: f.now)
            let context = try #require(f.recording.context)
            let canonical = context.paths.workingSet.appendingPathComponent("SyncMetadata/canonical.json")
            let corrupt = Data("invalid canonical proof".utf8)
            try corrupt.write(to: canonical)
            _ = f.lifecycle.beginTransition()
            await #expect(throws: (any Error).self) { try await f.coordinator.reconcileConfirmedAccount(f.a, now: f.now) }
            #expect(f.owner.visibleSession == nil && !f.coordinator.requiresBootstrap)
            #expect(bootstrap.calls == 0 && f.engineCalls.value == 1)
            #expect(try Data(contentsOf: canonical) == corrupt)
        }
    }

    @Test(arguments: [2, 3])
    func staleConfirmedGenerationCannotFinishNewDestinationOpen(revokeOnValidation: Int) async throws {
        let bootstrap = AccountLifecycleBootstrapProbe(completeImmediately: true)
        try await withAccountLifecycleFixture(phase: "new", bootstrap: bootstrap) { f in
            var validations = 0
            f.recording.validationAction = {
                validations += 1
                if validations == revokeOnValidation { _ = f.lifecycle.beginTransition() }
            }
            _ = f.lifecycle.beginTransition()
            await #expect(throws: (any Error).self) { try await f.coordinator.reconcileConfirmedAccount(f.a, now: f.now) }
            #expect(f.owner.visibleSession == nil && f.engineCalls.value == 0 && bootstrap.calls == 0)
            #expect(f.coordinator.retainedAccount == nil)
            let root = f.root.appendingPathComponent(f.a.identity.accountIDHash)
            #expect(FileManager.default.fileExists(atPath: root.path) == (revokeOnValidation == 3))
        }
    }

    @Test func malformedExistingNamespaceCannotBeScaffoldedAsFreshAbsence() async throws {
        let bootstrap = AccountLifecycleBootstrapProbe(completeImmediately: true)
        try await withAccountLifecycleFixture(phase: "new", bootstrap: bootstrap) { f in
            let root = f.root.appendingPathComponent(f.a.identity.accountIDHash)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let evidence = root.appendingPathComponent("unknown-original"), bytes = Data("retain malformed source".utf8)
            try bytes.write(to: evidence)
            _ = f.lifecycle.beginTransition()
            await #expect(throws: (any Error).self) { try await f.coordinator.reconcileConfirmedAccount(f.a, now: f.now) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["unknown-original"])
            #expect(try Data(contentsOf: evidence) == bytes)
            #expect(f.owner.visibleSession == nil && f.engineCalls.value == 0 && bootstrap.calls == 0)
        }
    }

    @Test func bootstrapDownloadedPhotoUsesSelectedRuntimeThenOrdinaryCommitAndAck() async throws {
        let bootstrap = AccountLifecycleBootstrapProbe()
        try await withAccountLifecycleFixture(phase: "absent", bootstrap: bootstrap) { f in
            let remote = f.root.appendingPathComponent("remote-photo-fixture")
            var project = try StoredProject(name: "Remote photo")
            project.setPhotoFilename(try ProjectPhotoFileService(directory: remote.appendingPathComponent("ProjectPhotos"))
                .save(data: CloudBootstrapFixture.jpeg(), projectID: project.id))
            let exported = try ProjectArchiveSyncMapper.export(archive: .init(version: ProjectArchive.currentVersion,
                projects: [project]), liveRoot: remote, deviceID: "remote-photo-device")
            let attachment = try #require(exported.records.first { $0.payload.attachment != nil })
            let version = try #require(attachment.payload.attachment), source = try #require(exported.attachments[attachment.id.uuid])
            let bytes = try Data(contentsOf: source.fileURL)
            let cloud = try exported.records.map { record in
                let value = try CloudRecordCodec().encode(record, zoneID: f.zone)
                if let file = exported.attachments[record.id.uuid] { value["asset"] = CKAsset(fileURL: file.fileURL) }
                return value
            }
            await f.driver.suspendNextFetch()
            _ = f.lifecycle.beginTransition()
            let run = f.operation { try await f.coordinator.reconcileConfirmedAccount(f.a, now: f.now) }
            try await f.waitUntil { bootstrap.fetchCalls.value == 1 }
            let op = await bootstrap.next()
            for record in cloud { op.recordWasChangedBlock?(record.recordID, .success(record)) }
            #expect(f.owner.visibleSession == nil && f.engineCalls.value == 0)
            BootstrapControlledOperations.emitSuccessfulEmptyZone(op); bootstrap.complete(op)
            try await f.waitForFetch(run)
            let selected = try #require(f.recording.selectedAssets), preliminary = try #require(f.recording.runtime).assets
            #expect(selected === bootstrap.bridge?.runtimeAssets && selected !== preliminary)
            #expect(try Data(contentsOf: selected.installedDownload(version: version)) == bytes)
            let visible = try #require(f.owner.visibleSession)
            #expect(visible.store.projects.first?.photoFilename == project.photoFilename)
            #expect(f.coordinator.localAccessReady && !f.coordinator.completed && f.engineCalls.value == 1)
            let transport = try #require(f.coordinator.currentTransport)
            let gate = AccountLifecycleAttachmentGate()
            f.suspendAttachmentResolution(with: gate)
            await f.driver.setFetchAction { await transport.receiveFetchedChanges(records: cloud, deletedRecordIDs: []) }
            await f.driver.resumeFetch()
            try await f.waitUntil { gate.entered }
            #expect(f.recording.committer?.acknowledged.isEmpty == true && !f.coordinator.completed)
            await #expect(throws: (any Error).self) { try await transport.sendNow() }
            #expect(await f.driver.sendCallCount() == 0)
            gate.release()
            try await run.value
            #expect(f.coordinator.completed && f.owner.visibleSession === visible)
            #expect(f.recording.committer?.acknowledged.isEmpty == false)
            #expect(try Data(contentsOf: selected.installedDownload(version: version)) == bytes)
            #expect(bootstrap.calls == 1 && f.engineCalls.value == 1)
        }
    }
    @Test(arguments: [false, true])
    func activeEventResolutionJoinsBeforeSameAccountReopenOrLogout(logout: Bool) async throws {
        try await withAccountLifecycleFixture { f in
            _ = f.lifecycle.beginTransition()
            try await f.coordinator.reconcileConfirmedAccount(f.a, now: f.now)
            let old = try #require(f.owner.visibleSession).store
            try f.rename(old, id: f.aID, name: "Before held resolution")
            let journal = f.coordinator.currentJournal
            let exact = try journal?.pending()
            let gate = AccountLifecycleAttachmentGate()
            f.suspendAttachmentResolution(with: gate)
            await f.coordinator.currentTransport?.receiveFetchedChanges(records: [], deletedRecordIDs: [])
            try await f.waitUntil { gate.entered }
            let freezeCount = f.recording.freezeCount
            _ = f.lifecycle.beginTransition()
            var returned = false
            let next = f.operation {
                try await f.coordinator.reconcileConfirmedAccount(logout ? nil : f.a, now: f.now)
                returned = true
            }
            await f.driver.waitUntilCancelled()
            for _ in 0..<20 { await Task.yield() }
            #expect(!returned && gate.completed == 0)
            #expect(f.recording.freezeCount == freezeCount)
            #expect(f.owner.visibleSession == nil && old.isSessionWriteRevoked)
            #expect(f.coordinator.currentJournal === journal)
            #expect(try journal?.pending() == exact)
            gate.release()
            try await next.value
            #expect(returned && gate.completed >= 1)
            if logout { #expect(f.coordinator.retainedAccount == nil) }
            else {
                #expect(f.coordinator.currentJournal === journal)
                #expect(f.owner.visibleSession?.store.projects.first?.name == "Before held resolution")
                #expect(f.coordinator.completed)
            }
        }
    }

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
    @Test(arguments: [CKError.Code.networkFailure, .quotaExceeded], [false, true])
    func localEditingSurvivesFailureAndRetryUsesActualReceipt(code: CKError.Code, bootstrapEnabled: Bool) async throws {
        let bootstrap = bootstrapEnabled ? AccountLifecycleBootstrapProbe(completeImmediately: true) : nil
        try await withAccountLifecycleFixture(phase: bootstrapEnabled ? "archive" : "committed", bootstrap: bootstrap) { f in
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
        #expect(f.engineCalls.value == 1)
        if let bootstrap { #expect(bootstrap.calls == 1 && bootstrap.fetchCalls.value == 1) }
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
        weak let retiredStorage = f.recording.context?.storage
        await f.stop()
        #expect(retiredStorage != nil) // The stopped coordinator still owns its session.
        weak let released = f.coordinator
        f.coordinator = nil
        #expect(released == nil && retiredStorage == nil)
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
    let engineCalls = AccountLifecycleCounter()
    let bootstrapProbe: AccountLifecycleBootstrapProbe?
    let suite = "AccountLifecycle.\(UUID())"
    let defaults: UserDefaults
    let aID: UUID
    let bID: UUID
    let lifecycle: AppAccountDomainLifecycle
    let recording: AccountLifecycleRecording
    var coordinator: CloudAccountTransitionCoordinator!
    var operations: [Task<Void, any Error>] = []
    var drains: [AccountLifecycleDrain] = []
    var attachmentGates: [AccountLifecycleAttachmentGate] = []
    init(phase: String = "committed", bootstrap: AccountLifecycleBootstrapProbe? = nil,
        existingRoot: URL? = nil) throws {
        bootstrapProbe = bootstrap
        let rootURL = existingRoot ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("AccountLifecycle-\(UUID())")
        root = rootURL
        defaults = try #require(UserDefaults(suiteName: suite))
        if phase == "existing" {
            _ = try #require(existingRoot)
            // Reopen observes the actual prior process bytes. No storage open,
            // journal load, account seed or handoff construction happens here.
            func projectID(_ account: CloudAccountBinding) throws -> UUID {
                let url = rootURL.appendingPathComponent(account.identity.accountIDHash + "/working-set/projects-v1.json")
                return try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: url)).projects.first?.id ?? UUID()
            }
            aID = try projectID(a); bID = try projectID(b)
        } else {
            aID = try Self.seed(root: root, account: a, name: "A", phase: phase)
            bID = try Self.seed(root: root, account: b, name: "B")
        }
        let makeBootstrap: (@MainActor (AppAccountDomainContext, SyncBootstrapContext, CKRecordZone.ID) throws -> AppAccountBootstrapBridge)?
        if let bootstrap { makeBootstrap = { context, frozen, zone in try bootstrap.make(context, frozen, zone) } }
        else { makeBootstrap = nil }
        lifecycle = AppAccountDomainLifecycle(owner: owner, factory: .init(entitlement: .configured(screenshotMode: true), backupHistory: BackupHistory(defaults: defaults)), bootstrapFactory: makeBootstrap)
        recording = AccountLifecycleRecording(lifecycle)
        coordinator = CloudAccountTransitionCoordinator(baseURL: root, keychain: keys, zoneID: zone, lifecycle: recording,
            engineFactory: { [driver, engineCalls] _, _ in engineCalls.increment(); return driver })
    }
    static func seed(root: URL, account: CloudAccountBinding, name: String, phase: String = "committed") throws -> UUID {
        let storage = SyncAccountStorage(baseURL: root)
        if phase == "new" { return UUID() }
        let paths = try phase == "absent" ? storage.openForVerifiedAccount(identity: account.identity, validateAccount: {}) : storage.open(identity: account.identity)
        defer { try? storage.close() }
        let project = try StoredProject(name: name)
        if phase == "absent" { return project.id }
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [project])
        try JSONEncoder().encode(archive).write(to: paths.workingSet.appendingPathComponent("projects-v1.json"))
        if phase == "archive" { return project.id }
        let local = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: paths.workingSet, deviceID: "lifecycle-test-device")
        let context = SyncBootstrapContext(accountIDHash: account.identity.accountIDHash, epoch: UUID(), freezeID: UUID())
        let tx = try SyncBootstrapTransaction(liveRoot: paths.workingSet, context: context, validateContext: { guard $0 == context else { throw SyncBootstrapError.contextChanged } })
        let prepared: SyncBootstrapPreparation
        if phase == "v2" {
            try FileManager.default.removeItem(at: paths.workingSet.appendingPathComponent("projects-v1.json"))
            prepared = try tx.prepareReconstruction(remote: .init(context: context, records: [], attachments: [:], isComplete: true),
                pendingSnapshot: .init(mutations: [], sourceTreeFingerprint: tx.sourceFingerprint()))
        } else { prepared = try tx.prepare(local: local, sourceArchive: archive, remote: .init(context: context, records: [], attachments: [:], isComplete: true)) }
        if phase == "installed" || phase == "committed" || phase == "v2" { try tx.install(prepared) }
        if phase == "committed" || phase == "v2" { _ = try tx.commit(prepared) }
        return project.id
    }
    func seedOwnedBootstrap(withHistory: Bool = false, interruption: SyncBootstrapOwnedBoundary? = nil) async throws {
        let storage = SyncAccountStorage(baseURL: root), paths = try storage.open(identity: a.identity)
        defer { try? storage.close() }
        let context = AppAccountDomainContext(account: a, paths: paths, journal: .init(url: paths.mutationJournalURL), storage: storage,
            validateOwnership: { try storage.withRecoveryOwnership(paths: paths, account: self.a.identity, maximumBytes: 100_000_000) { try $0.validate() } })
        let probe = AccountLifecycleBootstrapProbe(completeImmediately: true)
        if withHistory {
            probe.boundaryAction = { if $0 == .beforeTransactionRootCreation { throw AccountLifecycleError.timeout } }
            let interrupted = try probe.make(context, .init(accountIDHash: a.identity.accountIDHash, epoch: UUID(), freezeID: UUID()), zone)
            await #expect(throws: (any Error).self) { _ = try await interrupted.install() }
            probe.boundaryAction = nil
        }
        let bridge = try probe.make(context, .init(accountIDHash: a.identity.accountIDHash, epoch: UUID(), freezeID: UUID()), zone)
        if let interruption {
            // An ordinary install error rolls back synchronously. Interrupt its
            // actual rollback intent too, preserving the genuine missing root.
            probe.boundaryAction = { if $0 == interruption || $0 == .afterRollbackIntent { throw AccountLifecycleError.timeout } }
            await #expect(throws: (any Error).self) { _ = try await bridge.install() }
            return
        }
        _ = try await bridge.install()
        bridge.stop(); await bridge.waitUntilStopped()
    }
    func rename(_ store: JSONProjectStore, id: UUID, name: String) throws {
        try store.updateProject(id: id, name: name, toolType: nil, toolSize: nil, toolNotes: nil, photoChange: .unchanged)
    }
    func suspendAttachmentResolution(with gate: AccountLifecycleAttachmentGate) {
        attachmentGates.append(gate)
        let resolve: (SyncRemoteBatch, CloudSyncAccountEpoch) async throws -> Void = { [weak self] batch, epoch in
            let f = try #require(self)
            let store = try #require(f.owner.visibleSession).store
            let context = try #require(f.recording.context)
            let runtime = try #require(f.recording.runtime)
            let assets = f.recording.selectedAssets ?? runtime.assets
            let resolver = AppAccountAttachmentResolver(account: context.account.identity,
                installedDownload: { try assets.installedDownload(version: $0) },
                validateOwnership: context.validateOwnership)
            let actual = JSONProjectStoreRemoteBatchCommitter(store: store, expectedAccount: context.account.identity,
                attachmentSources: { batch in
                    await gate.resolve()
                    return try resolver.fetched(batch: batch)
                }, verifyAcknowledgement: { identity in
                    try runtime.incoming.verifyAcknowledgement(identity, accountIdentifier: context.account.userRecordName,
                        zoneID: runtime.zoneID, account: context.account.identity)
                })
            defer { gate.completed += 1 }
            try await actual.commitFetchedBatch(batch: batch, accountEpoch: epoch)
        }
        recording.commitOverride = resolve
        recording.committer?.commitOverride = resolve
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
        bootstrapProbe?.finish()
        let visible = owner.visibleSession
        _ = lifecycle.beginTransition()
        visible?.stopForSessionTransition()
        for drain in drains { drain.release() }
        for gate in attachmentGates { gate.release() }
        await driver.resumeFetch()
        await driver.resumeCancellation()
        await driver.setFetchAction {}
        coordinator?.stopForAccountTransition()
        if let transport = coordinator?.currentTransport { let cancellation = await transport.invalidateForAccountTransition(); await cancellation?.value }
        for operation in operations { _ = await operation.result }
        await coordinator?.waitForStoppedOperations()
        try? await waitUntil { attachmentGates.allSatisfy { $0.completed >= $0.enteredCount } }
        operations.removeAll()
        try? await owner.waitForRetiredSessions()
        try? await visible?.waitForStoppedOperations()
        try? await lifecycle.waitForStoppedOperations()
        // Observations now include the actual native storage owner. Release
        // fixture-only copies after the real drain so coordinator ARC can close.
        recording.context = nil; recording.runtime = nil; recording.selectedAssets = nil
        recording.committer = nil
        bootstrapProbe?.context = nil; bootstrapProbe?.bridge = nil; bootstrapProbe?.scope = nil
    }
    func operation(_ body: @escaping @MainActor () async throws -> Void) -> Task<Void, any Error> {
        let task = Task { try await body() }; operations.append(task); return task
    }
    func remove() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
}
@MainActor func withAccountLifecycleFixture(phase: String = "committed", bootstrap: AccountLifecycleBootstrapProbe? = nil,
    _ body: (AccountLifecycleFixture) async throws -> Void) async throws {
    let f = try AccountLifecycleFixture(phase: phase, bootstrap: bootstrap)
    let result: Result<Void, any Error>
    do { result = .success(try await body(f)) } catch { result = .failure(error) }
    await Task { @MainActor in await f.stop() }.value
    f.coordinator = nil
    f.remove()
    try result.get()
}
private enum AccountLifecycleError: Error { case timeout }
final class AccountLifecycleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
@MainActor final class AccountLifecycleBootstrapProbe {
    let operations = BootstrapControlledOperations()
    let fetchCalls = AccountLifecycleCounter()
    let completeImmediately: Bool
    init(completeImmediately: Bool = false) { self.completeImmediately = completeImmediately }
    var calls = 0
    var context: AppAccountDomainContext?
    var scope: CloudBootstrapSessionScope?
    var bridge: AppAccountBootstrapBridge?
    var scheduled: [CKFetchRecordZoneChangesOperation] = []
    var boundaries: [SyncBootstrapOwnedBoundary] = []
    var boundaryAction: ((SyncBootstrapOwnedBoundary) throws -> Void)?
    var publicationFault: @Sendable (CloudAssetPublicationBoundary) throws -> Void = { _ in }
    var completedOperations = 0
    func next() async -> CKFetchRecordZoneChangesOperation {
        let op = await operations.next(); scheduled.append(op); return op
    }
    func complete(_ op: CKFetchRecordZoneChangesOperation) {
        scheduled.removeAll { $0 === op }
        operations.completeSuccessfully(op)
        completedOperations += 1
    }
    func make(_ context: AppAccountDomainContext, _ frozen: SyncBootstrapContext, _ zone: CKRecordZone.ID) throws -> AppAccountBootstrapBridge {
        calls += 1; self.context = context
        let storage = try #require(context.storage)
        let scope = CloudBootstrapSessionScope(account: context.account, zoneID: zone, context: frozen)
        self.scope = scope
        let downloads = try CloudBootstrapDownloadStore(storage: storage, paths: context.paths, scope: scope,
            maximumBytes: 100_000_000, publicationFault: publicationFault)
        let driver = CloudBootstrapPageDriver(scope: scope, schedule: { [operations, fetchCalls, completeImmediately] op, done in
            fetchCalls.increment()
            if completeImmediately { BootstrapControlledOperations.emitSuccessfulEmptyZone(op); done() }
            else { operations.schedule(op, completion: done) }
        })
        let bridge = AppAccountBootstrapBridge(context: context, scope: scope,
            reader: .init(scope: scope, driver: driver, downloads: downloads),
            source: .init(storage: storage, paths: context.paths, account: context.account.identity, maximumBytes: 100_000_000),
            deviceID: "lifecycle-bootstrap-device", boundary: { [weak self] in self?.boundaries.append($0); try self?.boundaryAction?($0) })
        self.bridge = bridge
        return bridge
    }
    func finish() { bridge?.stop(); for op in scheduled { operations.completeSuccessfully(op) }; scheduled.removeAll() }
}
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
    var selectedAssets: CloudAssetStagingService?
    var committer: AccountLifecycleCommitter?
    var freezeCount = 0
    var installationCount = 0
    var commitOverride: ((SyncRemoteBatch, CloudSyncAccountEpoch) async throws -> Void)?
    var validationAction: (() throws -> Void)?
    init(_ concrete: AppAccountDomainLifecycle) { self.concrete = concrete }
    func stopPublishingAndHide() throws { try concrete.stopPublishingAndHide() }
    func captureTransitionValidation() -> () throws -> Void {
        let validate = concrete.captureTransitionValidation()
        return { [weak self] in try self?.validationAction?(); try validate() }
    }
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
        selectedAssets = result.runtimeAssets
        let observed = AccountLifecycleCommitter(result.fetchedBatchCommitter)
        observed.commitOverride = commitOverride
        committer = observed
        return .init(recordProvider: result.recordProvider, fetchedBatchCommitter: observed,
            localAccessReady: result.localAccessReady, runtimeAssets: result.runtimeAssets)
    }
    func resumePublishing() throws { try concrete.resumePublishing() }
}

@MainActor final class AccountLifecycleCommitter: SyncFetchedBatchCommitting {
    let actual: any SyncFetchedBatchCommitting
    var epoch: CloudSyncAccountEpoch?
    var acknowledged: [SyncRemoteBatchIdentity] = []
    var commitOverride: ((SyncRemoteBatch, CloudSyncAccountEpoch) async throws -> Void)?
    init(_ actual: any SyncFetchedBatchCommitting) { self.actual = actual }
    func commitFetchedBatch(batch: SyncRemoteBatch, accountEpoch: CloudSyncAccountEpoch) async throws {
        if let commitOverride { try await commitOverride(batch, accountEpoch) }
        else { try await actual.commitFetchedBatch(batch: batch, accountEpoch: accountEpoch) }
        epoch = accountEpoch
    }
    func didAcknowledgeFetchedBatch(batch: SyncRemoteBatchIdentity, accountEpoch: CloudSyncAccountEpoch) async throws {
        try await actual.didAcknowledgeFetchedBatch(batch: batch, accountEpoch: accountEpoch)
        acknowledged.append(batch)
    }
    func commitServerRecordChanged(input: SyncConflictInput, accountEpoch: CloudSyncAccountEpoch) async throws -> SyncConflictCommitResult {
        try await actual.commitServerRecordChanged(input: input, accountEpoch: accountEpoch)
    }
}

@MainActor final class AccountLifecycleAttachmentGate {
    var entered = false
    var enteredCount = 0
    var completed = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func resolve() async {
        entered = true
        enteredCount += 1
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() {
        released = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
