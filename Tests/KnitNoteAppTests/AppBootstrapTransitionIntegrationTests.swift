import CloudKit
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import KnitNote

@Suite(.serialized) @MainActor struct AppBootstrapTransitionIntegrationTests {
    // Breaks caught: publication/ordinary ACK before full reader authority;
    // cancellation mistaken for native completion; rollback discarding input;
    // committed recovery bootstrapping twice instead of adopting its own output.
    @Test(arguments: ["last-page", "accepted-asset", "completed-lease", "before-preparing",
        "after-preparing", "installed", "committed-before-publish"], ["cancel", "account", "io"])
    func interruptionPreservesAuthorityAndSameRootRestart(cut: String, fault: String) async throws {
        let probe = AccountLifecycleBootstrapProbe()
        let f = try AccountLifecycleFixture(phase: "archive", bootstrap: probe)
        var keep = true
        defer { if !keep { f.remove() } else { print("APP-MATRIX retainedRoot=\(f.root.path)") } }
        do {
            let accountRoot = f.root.appendingPathComponent(f.a.identity.accountIDHash)
            let live = accountRoot.appendingPathComponent("working-set")
            let originalPending = try BootstrapMatrixEvidence.seedPending(f)
            let initial = try BootstrapMatrixEvidence.files(live)
            let media = try BootstrapMatrixMedia(root: f.root.appendingPathComponent("remote"), zone: f.zone)
            @MainActor func firstSegment() async throws -> (BootstrapManifestV3?, URL, BootstrapMatrixRetiredOwners) {
                var reached = false, returned = false
                var cutFiles: [String: Data] = [:]
                var run: Task<Void, any Error>!
                func interrupt() throws {
                    reached = true
                    cutFiles = try BootstrapMatrixEvidence.files(accountRoot)
                    #expect(f.owner.visibleSession == nil && f.engineCalls.value == 0)
                    #expect(f.recording.committer == nil && !f.coordinator.completed)
                    if fault == "io" { throw POSIXError(.EIO) }
                    if fault == "cancel" { run.cancel() }
                    else { _ = f.lifecycle.beginTransition() }
                }
                probe.boundaryAction = { point in
                    if !reached, try BootstrapMatrixEvidence.matches(cut, point, root: accountRoot) { try interrupt() }
                }
                if cut == "completed-lease" {
                    // The captured App ownership callback runs at bridge.validate
                    // after await reader.read() returns its actual private lease.
                    // Native scheduler completion alone cannot invoke this callback.
                    f.recording.validationAction = {
                        if !reached, probe.completedOperations == 2, probe.boundaries.isEmpty { try interrupt() }
                    }
                }
                _ = f.lifecycle.beginTransition()
                run = f.operation { defer { returned = true }; try await f.coordinator.reconcileConfirmedAccount(f.a, now: f.now) }
                try await f.waitUntil { probe.fetchCalls.value == 1 || returned }
                try #require(!returned)
                var first: CKFetchRecordZoneChangesOperation! = await probe.next()
                BootstrapControlledOperations.emitSuccessfulEmptyZone(first, moreComing: true); probe.complete(first)
                try await f.waitUntil { probe.fetchCalls.value == 2 || returned }
                try #require(!returned)
                var last: CKFetchRecordZoneChangesOperation! = await probe.next()
                for record in media.cloud { last.recordWasChangedBlock?(record.recordID, .success(record)) }
                let downloadedURL = try probe.bridge?.runtimeAssets.installedDownload(version: media.version)
                let installed = try #require(downloadedURL)
                #expect(try Data(contentsOf: installed) == media.bytes)
                #expect(try BootstrapMatrixEvidence.files(live) == initial)
                #expect(try probe.context?.journal.recoverySnapshot().mutations == originalPending)
                if cut == "last-page" || cut == "accepted-asset" {
                    if cut == "last-page" { BootstrapControlledOperations.zoneSuccess(last) }
                    do { try interrupt() } catch {
                        last.fetchRecordZoneChangesResultBlock?(.failure(error))
                    }
                    if fault != "io" {
                        try await f.waitUntil { last.isCancelled }
                        #expect(!returned && probe.completedOperations == 1)
                        #expect(try BootstrapMatrixEvidence.files(accountRoot) == cutFiles)
                        BootstrapControlledOperations.emitSuccessfulEmptyZone(last)
                    }
                    probe.complete(last)
                } else {
                    BootstrapControlledOperations.emitSuccessfulEmptyZone(last); probe.complete(last)
                }
                await #expect(throws: (any Error).self) { try await run.value }
                let retired = BootstrapMatrixRetiredOwners(storage: probe.context?.storage, operation: last)
                first = nil; last = nil
                #expect(reached && returned && probe.completedOperations == 2)
                #expect(f.owner.visibleSession == nil && f.engineCalls.value == 0 && !f.coordinator.completed)
                #expect(await f.driver.sendCallCount() == 0)
                #expect(try Data(contentsOf: media.source) == media.bytes)
                #expect(try Data(contentsOf: installed) == media.bytes)
                let selected = try BootstrapMatrixEvidence.manifestIfPresent(accountRoot)
                if cut == "committed-before-publish" { guard case .committed? = selected?.body else { throw BootstrapMatrixFailure.wrongPhase } }
                else { if case .committed? = selected?.body { Issue.record("unintended committed output") } }
                if ["last-page", "accepted-asset", "completed-lease", "before-preparing"].contains(cut) {
                    #expect(selected == nil)
                    #expect(try BootstrapMatrixEvidence.files(live) == initial)
                    #expect(try BootstrapMatrixEvidence.control(accountRoot) == BootstrapMatrixEvidence.controlBytes(cutFiles))
                }
                f.recording.validationAction = nil; probe.boundaryAction = nil
                await f.stop(); f.coordinator = nil
                run = nil
                return (selected, installed, retired)
            }
            let (selected, installed, retired) = try await firstSegment()
            // A completed CKOperation may remain retained by the SDK. Its
            // native callbacks must release account data at completion anyway.
            #expect(retired.storage == nil)
            // Drop test observations carrying the native storage owner before
            // constructing a separate coordinator at the identical account root.
            let beforeReopen = try BootstrapMatrixEvidence.files(accountRoot)
            let nextProbe = AccountLifecycleBootstrapProbe(completeImmediately: true)
            let next = try AccountLifecycleFixture(phase: "existing", bootstrap: nextProbe, existingRoot: f.root)
            #expect(try BootstrapMatrixEvidence.files(accountRoot) == beforeReopen)
            _ = next.lifecycle.beginTransition()
            try await next.coordinator.reconcileConfirmedAccount(next.a, now: next.now)
            #expect(next.coordinator.completed && next.owner.visibleSession != nil)
            #expect(nextProbe.calls == (cut == "committed-before-publish" ? 0 : 1))
            #expect(next.engineCalls.value == 1)
            let afterPending = try next.coordinator.currentJournal?.recoverySnapshot().mutations
            #expect(afterPending?.prefix(originalPending.count).map(\.mutationID) == originalPending.map(\.mutationID))
            #expect(afterPending?.prefix(originalPending.count).map(\.savedRecordVersion) == originalPending.map(\.savedRecordVersion))
            #expect(next.owner.visibleSession?.store.projects.contains { $0.name == "A" } == true)
            if cut == "committed-before-publish" {
                #expect(try BootstrapMatrixEvidence.manifestIfPresent(accountRoot)?.id == selected?.id)
                #expect(next.owner.visibleSession?.store.projects.contains { $0.name == "Remote matrix photo" } == true)
            }
            #expect(try Data(contentsOf: installed) == media.bytes)
            await next.stop(); next.coordinator = nil
            next.defaults.removePersistentDomain(forName: next.suite)
            keep = false
            print("APP-MATRIX cut=\(cut) fault=\(fault) nativeCompletion=2 engineBeforeRestart=0 sameRoot=yes")
        } catch {
            await f.stop(); f.coordinator = nil
            throw error
        }
    }

    @Test(arguments: ["cancel", "account", "io"])
    func ordinaryFirstFetchKeepsActualLocalAuthorityButCannotAckOrSend(fault: String) async throws {
        let probe = AccountLifecycleBootstrapProbe(completeImmediately: true)
        try await withAccountLifecycleFixture(phase: "archive", bootstrap: probe) { f in
            @MainActor func firstSegment() async throws -> BootstrapMatrixRetiredOwners {
                await f.driver.suspendNextFetch()
                _ = f.lifecycle.beginTransition()
                let run = f.operation { try await f.coordinator.reconcileConfirmedAccount(f.a, now: f.now) }
                try await f.waitForFetch(run)
                let visible = try #require(f.owner.visibleSession), context = try #require(f.recording.context)
                let before = try BootstrapMatrixEvidence.files(context.paths.workingSet)
                #expect(f.coordinator.localAccessReady && !f.coordinator.completed)
                #expect(probe.calls == 1 && f.engineCalls.value == 1)
                #expect(f.recording.committer?.acknowledged.isEmpty == true)
                let transport = try #require(f.coordinator.currentTransport)
                if fault == "io" {
                    f.recording.committer?.commitOverride = { _, _ in throw POSIXError(.EIO) }
                } else {
                    if fault == "cancel" { run.cancel() }
                    _ = f.lifecycle.beginTransition()
                    f.coordinator.stopForAccountTransition()
                }
                await f.driver.resumeFetch()
                _ = await run.result
                #expect(!f.coordinator.completed && f.recording.committer?.acknowledged.isEmpty == true)
                #expect(await f.driver.sendCallCount() == 0)
                #expect(try Data(contentsOf: context.paths.workingSet.appendingPathComponent("projects-v1.json")) == before["projects-v1.json"])
                await #expect(throws: (any Error).self) { try await transport.sendNow() }
                if fault != "io" { #expect(f.owner.visibleSession == nil && visible.store.isSessionWriteRevoked) }
                f.recording.committer?.commitOverride = nil
                let retired = BootstrapMatrixRetiredOwners(storage: context.storage, operation: nil)
                await f.stop(); f.coordinator = nil
                return retired
            }
            let retired = try await firstSegment()
            #expect(retired.storage == nil)
            let nextProbe = AccountLifecycleBootstrapProbe(completeImmediately: true)
            let next = try AccountLifecycleFixture(phase: "existing", bootstrap: nextProbe, existingRoot: f.root)
            do {
                _ = next.lifecycle.beginTransition()
                try await next.coordinator.reconcileConfirmedAccount(next.a, now: next.now)
                #expect(next.coordinator.completed && nextProbe.calls == 0 && next.engineCalls.value == 1)
                #expect(next.owner.visibleSession?.store.projects.first?.name == "A")
                await next.stop(); next.coordinator = nil
                next.defaults.removePersistentDomain(forName: next.suite)
            } catch { await next.stop(); next.coordinator = nil; throw error }
        }
    }

    #if os(macOS)
    // No compiler is launched by this test. Each child uses this exact built
    // test bundle, exits from the real owned transaction, and reopens its root.
    @Test(.enabled(if: Bundle.main.executableURL?.lastPathComponent == "swiftpm-testing-helper"),
        arguments: ["after-preparing", "committed-before-publish"])
    func builtChildExitRecoversBeforeOrdinaryJournalAndDoesNotBootstrapTwice(cut: String) async throws {
        guard ProcessInfo.processInfo.environment["KNITNOTE_APP_BOOTSTRAP_CHILD"] == nil else { return }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("app-bootstrap-crash-" + UUID().uuidString)
        let child = Process(), executable = try #require(Bundle.main.executableURL)
        try #require(executable.lastPathComponent == "swiftpm-testing-helper")
        child.executableURL = executable
        var arguments: [String] = [], skip = false
        for argument in CommandLine.arguments.dropFirst() {
            if skip { skip = false; continue }
            if argument == "--filter" { skip = true; continue }
            arguments.append(argument)
        }
        child.arguments = arguments + ["--filter", "AppBootstrapTransitionIntegrationTests/bootstrapCrashWorker"]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "KNITNOTE_RUN_CLOUDKIT_INTEGRATION")
        environment["KNITNOTE_APP_BOOTSTRAP_CHILD"] = cut
        environment["KNITNOTE_APP_BOOTSTRAP_ROOT"] = root.path
        child.environment = environment
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("app-bootstrap-child-" + cut + "-" + UUID().uuidString + ".log")
        try #require(FileManager.default.createFile(atPath: log.path, contents: nil))
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        child.standardOutput = output; child.standardError = output
        print("APP-CHILD cut=\(cut) root=\(root.path) log=\(log.path)")
        try child.run()
        let deadline = Date().addingTimeInterval(60)
        while child.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        if child.isRunning {
            child.terminate()
            let grace = Date().addingTimeInterval(2)
            while child.isRunning && Date() < grace { try await Task.sleep(for: .milliseconds(20)) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
            Issue.record("child deadline exceeded; retained root \(root.path); incomplete \(cut)")
            return
        }
        child.waitUntilExit()
        try #require(child.terminationReason == .exit && child.terminationStatus == 86)
        let account = try CloudAccountBinding(containerIdentifier: "test.container", userRecordName: "A")
        let accountRoot = root.appendingPathComponent(account.identity.accountIDHash)
        let initial = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: root.appendingPathComponent("before.json")))
        let atExit = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: root.appendingPathComponent("cut.json")))
        try #require(try BootstrapMatrixEvidence.files(accountRoot) == atExit)
        let selected = try #require(try BootstrapMatrixEvidence.manifestIfPresent(accountRoot))
        if cut == "after-preparing" {
            guard case .preparing = selected.body else { throw BootstrapMatrixFailure.wrongPhase }
            try #require(try BootstrapMatrixEvidence.files(accountRoot.appendingPathComponent("working-set")) == initial)
        } else {
            guard case .committed = selected.body else { throw BootstrapMatrixFailure.wrongPhase }
            try #require(atExit["working-set/SyncMetadata/canonical.json"] == nil)
        }
        let probe = AccountLifecycleBootstrapProbe(completeImmediately: true)
        let reopened = try AccountLifecycleFixture(phase: "existing", bootstrap: probe, existingRoot: root)
        do {
            try #require(try BootstrapMatrixEvidence.files(accountRoot) == atExit)
            _ = reopened.lifecycle.beginTransition()
            // Production lifecycle recovery runs before the factory or ordinary
            // journal. The test never calls pending() on crash evidence first.
            try await reopened.coordinator.reconcileConfirmedAccount(reopened.a, now: reopened.now)
            try #require(reopened.coordinator.completed && reopened.owner.visibleSession != nil)
            try #require(probe.calls == (cut == "after-preparing" ? 1 : 0))
            try #require(reopened.engineCalls.value == 1)
            let nowSelected = try #require(try BootstrapMatrixEvidence.manifestIfPresent(accountRoot))
            if cut == "committed-before-publish" {
                try #require(nowSelected.id == selected.id)
                try #require(reopened.owner.visibleSession?.store.projects.contains { $0.name == "Remote matrix photo" } == true)
            } else { try #require(nowSelected.id != selected.id && nowSelected.historyHead != nil) }
            let pending = try #require(reopened.coordinator.currentJournal).recoverySnapshot().mutations
            let originalPending = try JSONDecoder().decode([SyncMutation].self, from: Data(contentsOf: root.appendingPathComponent("pending.json")))
            try #require(Array(pending.prefix(originalPending.count)).map(\.mutationID) == originalPending.map(\.mutationID))
            try #require(Array(pending.prefix(originalPending.count)).map(\.savedRecordVersion) == originalPending.map(\.savedRecordVersion))
            let originalArchive = try #require(initial["projects-v1.json"])
            let files = try BootstrapMatrixEvidence.files(accountRoot)
            try #require(files.contains { $0.key.hasSuffix("/Original/projects-v1.json") && $0.value == originalArchive })
            let retainedAssets = atExit.filter { $0.key.hasPrefix("staging/") && $0.key.hasSuffix(".asset") }
            try #require(!retainedAssets.isEmpty && retainedAssets.allSatisfy { files[$0.key] == $0.value })
            // Evolve actual daily canonical, stop, then use a separate fixture
            // and coordinator at this root. Runtime admission must avoid reader.
            let project = try #require(reopened.owner.visibleSession?.store.projects.first { $0.name == "A" })
            try reopened.rename(try #require(reopened.owner.visibleSession).store, id: project.id, name: "Daily after crash")
            let daily = try BootstrapMatrixEvidence.files(accountRoot.appendingPathComponent("working-set"))
            await reopened.stop(); reopened.coordinator = nil
            let dailyProbe = AccountLifecycleBootstrapProbe(completeImmediately: true)
            let dailyOpen = try AccountLifecycleFixture(phase: "existing", bootstrap: dailyProbe, existingRoot: root)
            do {
                _ = dailyOpen.lifecycle.beginTransition()
                try await dailyOpen.coordinator.reconcileConfirmedAccount(dailyOpen.a, now: dailyOpen.now)
                try #require(dailyOpen.coordinator.completed && dailyProbe.calls == 0)
                try #require(dailyOpen.owner.visibleSession?.store.projects.contains { $0.name == "Daily after crash" } == true)
                try #require(try Data(contentsOf: accountRoot.appendingPathComponent("working-set/projects-v1.json")) == daily["projects-v1.json"])
                await dailyOpen.stop(); dailyOpen.coordinator = nil
                dailyOpen.defaults.removePersistentDomain(forName: dailyOpen.suite)
            } catch { await dailyOpen.stop(); dailyOpen.coordinator = nil; throw error }
            reopened.remove()
            print("APP-CHILD cut=\(cut) exit=86 recoveryBeforeJournal=yes sameRoot=yes dailyReopenReader=0")
        } catch {
            await reopened.stop(); reopened.coordinator = nil
            print("APP-CHILD retainedFailureRoot=\(root.path) log=\(log.path)")
            throw error
        }
    }

    @Test func bootstrapCrashWorker() async throws {
        guard let cut = ProcessInfo.processInfo.environment["KNITNOTE_APP_BOOTSTRAP_CHILD"],
              let path = ProcessInfo.processInfo.environment["KNITNOTE_APP_BOOTSTRAP_ROOT"] else { return }
        let root = URL(fileURLWithPath: path)
        guard root.lastPathComponent.hasPrefix("app-bootstrap-crash-"),
              !FileManager.default.fileExists(atPath: root.path) else { throw BootstrapMatrixFailure.unsafeRoot }
        let probe = AccountLifecycleBootstrapProbe()
        let f = try AccountLifecycleFixture(phase: "archive", bootstrap: probe, existingRoot: root)
        let accountRoot = root.appendingPathComponent(f.a.identity.accountIDHash)
        let pending = try BootstrapMatrixEvidence.seedPending(f)
        try JSONEncoder().encode(pending).write(to: root.appendingPathComponent("pending.json"))
        try JSONEncoder().encode(BootstrapMatrixEvidence.files(accountRoot.appendingPathComponent("working-set")))
            .write(to: root.appendingPathComponent("before.json"))
        let media = try BootstrapMatrixMedia(root: root.appendingPathComponent("remote"), zone: f.zone)
        probe.boundaryAction = { point in
            if try BootstrapMatrixEvidence.matches(cut, point, root: accountRoot) {
                try #require(f.owner.visibleSession == nil && f.engineCalls.value == 0 && f.recording.committer == nil)
                try JSONEncoder().encode(BootstrapMatrixEvidence.files(accountRoot)).write(to: root.appendingPathComponent("cut.json"))
                FileHandle.standardError.write(Data("APP-CHILD reached=\(cut) nativeCompleted=\(probe.completedOperations) ordinaryEngine=0\n".utf8))
                _exit(86)
            }
        }
        _ = f.lifecycle.beginTransition()
        let run = f.operation { try await f.coordinator.reconcileConfirmedAccount(f.a, now: f.now) }
        try await f.waitUntil { probe.fetchCalls.value == 1 }
        let op = await probe.next()
        for record in media.cloud { op.recordWasChangedBlock?(record.recordID, .success(record)) }
        BootstrapControlledOperations.emitSuccessfulEmptyZone(op); probe.complete(op)
        try await run.value
        throw BootstrapMatrixFailure.wrongPhase
    }
    #endif

    @Test(arguments: CloudAssetPublicationBoundary.allCases)
    func representativeDownloadCrashPrefixesFitActualNativeInventoryAndEnvelope(cut: CloudAssetPublicationBoundary) throws {
        let f = try CloudBootstrapFixture(withArchive: true)
        var success = false
        defer { if success { f.remove() } else { print("APP-CAP retainedRoot=\(f.root.path)"); try? f.storage.close() } }
        let bytes = Data(repeating: 255, count: 1_048_576), source = try f.source(bytes)
        let record = try f.attachment(bytes: bytes), version = try #require(record.payload.attachment)
        let original = try SyncAttachmentSource(fileURL: source, contentSHA256: version.contentSHA256, byteCount: version.byteCount)
        let pending = try f.pending(record, source: original)
        let cold = try CloudAssetStagingService.makeForBootstrap(rootURL: f.assetRoot,
            accountIdentifier: f.account.userRecordName, maximumAssetBytes: 100_000_000)
        let plan = try cold.planBootstrapDownload(version: version, sourceURL: source, accountRoot: f.paths.accountRoot)
        let cap = 8_000_000
        try SyncBootstrapDownloadBudget.requireFits(storage: f.storage, paths: f.paths, account: f.account.identity,
            footprint: plan.footprint, maximumBytes: cap)
        let sourceBefore = try BootstrapMatrixEvidence.files(f.paths.workingSet)
        let download = try CloudBootstrapDownloadStore(storage: f.storage, paths: f.paths, scope: f.scope, maximumBytes: cap,
            publicationFault: { if $0 == cut { throw POSIXError(.EIO) } })
        #expect(throws: POSIXError.self) { _ = try download.accept(version: version, sourceURL: source) }
        let crash = try BootstrapMatrixEvidence.files(f.paths.staging)
        let inventory = try SyncAccountRecoveryInventory.capture(storage: f.storage, paths: f.paths, account: f.account.identity,
            journal: .init(url: f.paths.mutationJournalURL), archiveURL: f.paths.workingSet.appendingPathComponent("projects-v1.json"))
        let nativeInventory = try inventory.encoded()
        let projected = try inventory.projectedEncodedByteCount(entries: inventory.entries, packetByteCount: inventory.packet.encoded().count,
            deletionFiles: inventory.deletionFiles, sourceAuthority: inventory.sourceAuthority, bootstrapEvidence: inventory.bootstrapEvidence)
        try #require(projected == nativeInventory.count)
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: AccountLifecycleKeys())
        let recovery = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account.identity,
            vault: vault, journal: .init(url: f.paths.mutationJournalURL), maximumBytes: cap)
        let now = Date(), receipt = try recovery.seal(recovery.prepare(now: now), now: now)
        let envelope = try vault.synchronizedRecoveryPayload(receipt.vaultID, account: f.account.identity, now: now)
        let object = try #require(JSONSerialization.jsonObject(with: envelope) as? [String: Any])
        let encoded = try #require(object["inventory"] as? String)
        try #require(Data(base64Encoded: encoded) == nativeInventory && envelope.count <= cap)
        try #require(try BootstrapMatrixEvidence.files(f.paths.staging) == crash)
        try #require(try BootstrapMatrixEvidence.files(f.paths.workingSet) == sourceBefore)
        try #require(try FileSyncMutationJournal(url: f.paths.mutationJournalURL).recoverySnapshot().mutations == [pending])
        try #require(try Data(contentsOf: source) == bytes)
        print("APP-CAP cut=\(cut) mediaBytes=1048576 pending=1 inventory=\(nativeInventory.count) envelope=\(envelope.count) admitted=8000000 crashBytes=\(crash.values.reduce(0) { $0 + $1.count }) retained=yes")
        success = true
    }
}

private enum BootstrapMatrixFailure: Error { case wrongPhase, unsafeRoot }

private final class BootstrapMatrixRetiredOwners {
    weak var storage: SyncAccountStorage?
    let operation: CKFetchRecordZoneChangesOperation?
    init(storage: SyncAccountStorage?, operation: CKFetchRecordZoneChangesOperation?) {
        self.storage = storage; self.operation = operation
    }
}

@MainActor private struct BootstrapMatrixMedia {
    let cloud: [CKRecord]
    let version: SyncAttachmentVersion
    let source: URL
    let bytes: Data
    init(root: URL, zone: CKRecordZone.ID) throws {
        var project = try StoredProject(name: "Remote matrix photo")
        project.setPhotoFilename(try ProjectPhotoFileService(directory: root.appendingPathComponent("ProjectPhotos"))
            .save(data: CloudBootstrapFixture.jpeg(), projectID: project.id))
        let export = try ProjectArchiveSyncMapper.export(archive: .init(version: ProjectArchive.currentVersion, projects: [project]),
            liveRoot: root, deviceID: "remote-matrix-device")
        let attachment = try #require(export.records.first { $0.payload.attachment != nil })
        version = try #require(attachment.payload.attachment)
        source = try #require(export.attachments[attachment.id.uuid]).fileURL
        bytes = try Data(contentsOf: source)
        cloud = try export.records.map { record in
            let value = try CloudRecordCodec().encode(record, zoneID: zone)
            if let source = export.attachments[record.id.uuid] { value["asset"] = CKAsset(fileURL: source.fileURL) }
            return value
        }
    }
}

private enum BootstrapMatrixEvidence {
    @MainActor static func seedPending(_ f: AccountLifecycleFixture) throws -> [SyncMutation] {
        let storage = SyncAccountStorage(baseURL: f.root), paths = try storage.open(identity: f.a.identity)
        defer { try? storage.close() }
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: paths.workingSet.appendingPathComponent("projects-v1.json")))
        let local = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: paths.workingSet, deviceID: "lifecycle-bootstrap-device")
        let journal = FileSyncMutationJournal(url: paths.mutationJournalURL)
        try journal.enqueue(local.records.map { try SyncMutation.save(recordVersion: .init(record: $0), mutationID: UUID()) })
        return try journal.recoverySnapshot().mutations
    }
    static func files(_ root: URL) throws -> [String: Data] {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [:] }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            let url = url.standardizedFileURL
            guard url.path.hasPrefix(root.path + "/") else { throw BootstrapMatrixFailure.unsafeRoot }
            var info = stat(); guard lstat(url.path, &info) == 0 else { throw POSIXError(.EIO) }
            if info.st_mode & S_IFMT == S_IFREG { result[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url) }
        }
        return result
    }
    static func manifestIfPresent(_ root: URL) throws -> BootstrapManifestV3? {
        let entries = try files(root)
        guard let bytes = entries.first(where: { $0.key.hasSuffix("/active.json") && $0.key.hasPrefix(".KnitNote-SyncBootstrap/") })?.value else { return nil }
        return try BootstrapManifestV3.decodeEnvelope(bytes)
    }
    static func matches(_ cut: String, _ point: SyncBootstrapOwnedBoundary, root: URL) throws -> Bool {
        switch cut {
        case "before-preparing": return point == .beforePreparingPublication
        case "after-preparing": return point == .afterPreparingPublication
        case "installed": return point == .afterInstalled
        case "committed-before-publish":
            guard point == .selector(.afterSelectedSynchronize) else { return false }
            if case .committed? = try manifestIfPresent(root)?.body { return true }; return false
        default: return false
        }
    }
    static func control(_ root: URL) throws -> [String: Data] { controlBytes(try files(root)) }
    static func controlBytes(_ files: [String: Data]) -> [String: Data] { files.filter { $0.key.hasPrefix(".sealed-recovery-v1/") } }
}
