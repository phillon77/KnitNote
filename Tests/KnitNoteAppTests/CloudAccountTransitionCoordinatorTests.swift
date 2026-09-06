import CloudKit
import Foundation
import Darwin
import Security
import Testing
@testable import KnitNote

@Suite @MainActor struct CloudAccountTransitionCoordinatorTests {
    @Test func bootstrappedAccountUsesActualRuntimeJournalAndRestoresExactPendingSources() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try CloudAccountBinding(containerIdentifier: "test", userRecordName: "bootstrap-runtime")
        let storage = SyncAccountStorage(baseURL: root), keys = TransitionMemoryKeys()
        let paths = try storage.open(identity: account.identity)
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [try StoredProject(name: "Bootstrap runtime")])
        try JSONEncoder().encode(archive).write(to: paths.workingSet.appendingPathComponent("projects-v1.json"))
        let context = SyncBootstrapContext(accountIDHash: account.identity.accountIDHash, epoch: UUID(), freezeID: UUID())
        let bootstrap = try SyncBootstrapTransaction(liveRoot: paths.workingSet, context: context,
            validateContext: { _ in })
        let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: paths.workingSet, deviceID: "fixture")
        let prepared = try bootstrap.prepare(local: package, sourceArchive: archive,
            remote: .init(context: context, records: [], attachments: [:], isComplete: true))
        try bootstrap.install(prepared); _ = try bootstrap.commit(prepared)
        let journal = FileSyncMutationJournal(url: paths.mutationJournalURL)
        try journal.enqueue(integrationAttachment(root: paths.staging))
        let pending = try journal.pending()
        let originalSource = try #require(pending.compactMap(\.attachmentSource).first)
        let originalBytes = try Data(contentsOf: originalSource.fileURL)
        try storage.close()
        let driver = TestSyncEngineDriver(), domain = TransitionDomainFixture()
        let runtime = CloudAccountTransitionCoordinator(baseURL: root, keychain: keys, zoneID: testZoneID(),
            lifecycle: domain, engineFactory: { _, _ in driver })
        try await runtime.transition(from: account, to: nil, now: .now)
        #expect(runtime.completed && runtime.phase == .cleaned)
        #expect(!FileManager.default.fileExists(atPath: originalSource.fileURL.path))
        await driver.suspendNextFetch()
        let restore = Task { try await runtime.transition(from: nil, to: account, now: .now) }
        try await waitForFetch(runtime, driver: driver, task: restore)
        #expect(try runtime.currentJournal?.pending() == pending)
        #expect(try Data(contentsOf: originalSource.fileURL) == originalBytes)
        #expect(await driver.sendCallCount() == 0)
        await driver.resumeFetch(); try await restore.value
        #expect(runtime.completed && runtime.phase == .ready)
        #expect(domain.committedAccounts == [account.identity])
    }

    @Test(arguments: ["pending.json.segment", ".pending.json.attachments/immutable", "noncanonical-bootstrap", "working-set-journal-without-manifest"])
    func oldJournalAuthorityRefusesRuntimeWithoutRelocation(layout: String) async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try CloudAccountBinding(containerIdentifier: "test", userRecordName: "old-layout")
        let storage = SyncAccountStorage(baseURL: root)
        let paths = try storage.open(identity: account.identity)
        let archiveURL = paths.workingSet.appendingPathComponent("projects-v1.json")
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [try StoredProject(name: "Preserve original")])
        try JSONEncoder().encode(archive).write(to: archiveURL)
        let protectedURL: URL
        if layout == "noncanonical-bootstrap" {
            let context = SyncBootstrapContext(accountIDHash: account.identity.accountIDHash, epoch: UUID(), freezeID: UUID())
            let bootstrap = try SyncBootstrapTransaction(liveRoot: paths.workingSet, context: context,
                journalRelativePath: "SyncMetadata/bootstrap-journal", validateContext: { _ in })
            let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: paths.workingSet, deviceID: "old")
            let prepared = try bootstrap.prepare(local: package, sourceArchive: archive,
                remote: .init(context: context, records: [], attachments: [:], isComplete: true))
            try bootstrap.install(prepared); _ = try bootstrap.commit(prepared)
            protectedURL = paths.workingSet.appendingPathComponent("SyncMetadata/bootstrap-journal.segment")
        } else if layout == "working-set-journal-without-manifest" {
            let old = paths.workingSet.appendingPathComponent("SyncMetadata/bootstrap-journal")
            try FileSyncMutationJournal(url: old).enqueue(.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID()))
            protectedURL = old.appendingPathExtension("segment")
        } else {
            protectedURL = paths.journal.appendingPathComponent(layout)
            try FileManager.default.createDirectory(at: protectedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("original immutable journal authority".utf8).write(to: protectedURL)
        }
        let protectedBytes = try Data(contentsOf: protectedURL), archiveBytes = try Data(contentsOf: archiveURL)
        try storage.close()
        let driver = TestSyncEngineDriver()
        let runtime = CloudAccountTransitionCoordinator(baseURL: root, keychain: TransitionMemoryKeys(), zoneID: testZoneID(),
            lifecycle: TransitionDomainFixture(), engineFactory: { _, _ in driver })
        await #expect(throws: (any Error).self) { try await runtime.transition(from: nil, to: account, now: .now) }
        #expect(runtime.phase == .blocked && !runtime.completed)
        #expect(try Data(contentsOf: protectedURL) == protectedBytes)
        #expect(try Data(contentsOf: archiveURL) == archiveBytes)
        #expect(!FileManager.default.fileExists(atPath: paths.mutationJournalURL.appendingPathExtension("segment").path))
        #expect(await driver.sendCallCount() == 0)
    }

    @Test func sendFailureAfterFirstCommitCannotReportCompletedTransition() async throws {
        let seed = try TransitionSeed(); defer { seed.remove() }
        let driver = TestSyncEngineDriver()
        await driver.setSendAction { throw CKError(.networkUnavailable) }
        let runtime = CloudAccountTransitionCoordinator(baseURL: seed.root, keychain: seed.keys, zoneID: testZoneID(),
            lifecycle: TransitionDomainFixture(), engineFactory: { _, _ in driver })
        await #expect(throws: (any Error).self) {
            try await runtime.transition(from: seed.account, to: CloudAccountBinding(containerIdentifier: "test", userRecordName: "B"), now: .now)
        }
        #expect(runtime.phase == .blocked && !runtime.completed)
        #expect(try FileManager.default.contentsOfDirectory(at: seed.vaultURL, includingPropertiesForKeys: nil).contains { $0.pathExtension == "vault" })
    }
    @Test func successfulEmptyFetchCannotSendWhileItsRealCommitIsSuspended() async throws {
        let seed = try TransitionSeed(); defer { seed.remove() }
        let latch = TransitionCommitLatch()
        let domain = TransitionDomainFixture(); domain.commitLatch = latch
        let driver = TestSyncEngineDriver()
        let runtime = CloudAccountTransitionCoordinator(baseURL: seed.root, keychain: seed.keys, zoneID: testZoneID(), lifecycle: domain, engineFactory: { _, _ in driver })
        let b = try CloudAccountBinding(containerIdentifier: "test", userRecordName: "B")
        let run = Task { try await runtime.transition(from: seed.account, to: b, now: .now) }
        for _ in 0..<3_000 {
            if await latch.entered { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await latch.entered)
        let transport = try #require(runtime.currentTransport)
        await transport.receiveZoneReady(testZoneID())
        await #expect(throws: (any Error).self) { try await transport.finishMutationReplay() }
        await #expect(throws: (any Error).self) { try await transport.sendNow() }
        #expect(runtime.phase == .fetching && !runtime.completed)
        #expect(domain.committedAccounts.isEmpty)
        #expect(await driver.sendCallCount() == 0)
        await latch.release()
        try await run.value
        #expect(runtime.phase == .ready && runtime.completed)
        #expect(domain.committedAccounts == [b.identity])
        #expect(await driver.sendCallCount() > 0)
    }
    @Test func restartAfterSelectedCleanupFailureFinishesCleanupThenRestoresOriginalJournal() async throws {
        let seed = try TransitionSeed(); defer { seed.remove() }
        var interrupted: CloudAccountTransitionCoordinator? = CloudAccountTransitionCoordinator(baseURL: seed.root, keychain: seed.keys,
            zoneID: testZoneID(), lifecycle: TransitionDomainFixture(), recoverySynchronize: { fd in
                var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                if fcntl(fd, F_GETPATH, &path) == 0, String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).hasSuffix("intent-next.json") { throw TransitionTestError.unexpected }
                guard fsync(fd) == 0 else { throw TransitionTestError.unexpected }
            }, engineFactory: { _, _ in TestSyncEngineDriver() })
        await #expect(throws: (any Error).self) { try await interrupted!.transition(from: seed.account, to: nil, now: .now) }
        interrupted = nil
        var cleanup: CloudAccountTransitionCoordinator? = CloudAccountTransitionCoordinator(baseURL: seed.root, keychain: seed.keys,
            zoneID: testZoneID(), lifecycle: TransitionDomainFixture(), engineFactory: { _, _ in TestSyncEngineDriver() })
        try await cleanup!.transition(from: seed.account, to: nil, now: .now)
        #expect(cleanup!.completed && cleanup!.phase == .cleaned)
        #expect(!FileManager.default.fileExists(atPath: seed.archiveURL.path))
        cleanup = nil
        let driver = TestSyncEngineDriver()
        let restored = CloudAccountTransitionCoordinator(baseURL: seed.root, keychain: seed.keys, zoneID: testZoneID(),
            lifecycle: TransitionDomainFixture(), engineFactory: { _, _ in driver })
        try await restored.transition(from: nil, to: seed.account, now: .now)
        #expect(restored.phase == .ready && restored.completed)
        #expect(try restored.currentJournal?.pending() == [seed.mutation])
    }
    @Test(arguments: ["freeze", "seal", "oversize", "missing-key", "wrong-key", "expired", "cleanup"])
    func failuresKeepRecoverableSourceAndNeverComplete(_ cut: String) async throws {
        let seed = try TransitionSeed()
        defer { seed.remove() }
        let domain = TransitionDomainFixture()
        domain.failFreeze = cut == "freeze"
        seed.keys.failInsert = cut == "seal"
        if ["missing-key", "wrong-key", "expired"].contains(cut) {
            let storage = SyncAccountStorage(baseURL: seed.root)
            let paths = try storage.open(identity: seed.account.identity)
            let tx = SyncAccountRecoveryTransaction(storage: storage, paths: paths, account: seed.account.identity,
                vault: SyncRecoveryVault(directory: paths.vault, keychain: seed.keys),
                journal: FileSyncMutationJournal(url: seed.journalURL))
            let date = cut == "expired" ? Date.now.addingTimeInterval(-2_592_001) : .now
            let selected = try tx.seal(tx.prepare(now: date), now: date)
            if cut == "missing-key" { try seed.keys.remove(for: selected.vaultID) }
            if cut == "wrong-key" { try seed.keys.insert(Data(repeating: 9, count: 32), for: selected.vaultID) }
            try storage.close()
        }
        let driver = TestSyncEngineDriver()
        let runtime = CloudAccountTransitionCoordinator(baseURL: seed.root, keychain: seed.keys, zoneID: testZoneID(), lifecycle: domain,
            maximumRecoveryBytes: cut == "oversize" ? 1 : 100_000_000,
            recoverySynchronize: { fd in
                var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                if cut == "cleanup", fcntl(fd, F_GETPATH, &path) == 0,
                   String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).hasSuffix("intent-next.json") { throw TransitionTestError.unexpected }
                guard fsync(fd) == 0 else { throw TransitionTestError.unexpected }
            }, engineFactory: { _, _ in driver })
        await #expect(throws: (any Error).self) { try await runtime.transition(from: seed.account, to: nil, now: .now) }
        #expect(runtime.phase == .blocked)
        #expect(!runtime.completed)
        #expect(try Data(contentsOf: seed.archiveURL) == Data("canonical A".utf8))
        #expect(try FileSyncMutationJournal(url: seed.journalURL).pending() == [seed.mutation])
        #expect(await driver.sendCallCount() == 0)
    }

    @Test func cancellationWhileFetchingPreservesSealedSourceAndBlocksLateCallbacks() async throws {
        let seed = try TransitionSeed(); defer { seed.remove() }
        let driver = TestSyncEngineDriver(); await driver.suspendNextFetch()
        let runtime = CloudAccountTransitionCoordinator(baseURL: seed.root, keychain: seed.keys, zoneID: testZoneID(),
            lifecycle: TransitionDomainFixture(), engineFactory: { _, _ in driver })
        let b = try CloudAccountBinding(containerIdentifier: "test", userRecordName: "B")
        let run = Task { try await runtime.transition(from: seed.account, to: b, now: .now) }
        try await waitForFetch(runtime, driver: driver, task: run)
        let transport = try #require(runtime.currentTransport)
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        await driver.resumeFetch()
        await transport.receiveFetchedChanges(records: [], deletedRecordIDs: [])
        #expect(runtime.phase == .blocked && !runtime.completed)
        #expect(await driver.sendCallCount() == 0)
        #expect(try FileManager.default.contentsOfDirectory(at: seed.vaultURL, includingPropertiesForKeys: nil).contains { $0.pathExtension == "vault" })
        #expect(!FileManager.default.fileExists(atPath: seed.archiveURL.path))
    }

    @Test func realEmptyFetchWaitsForDurableCommitAndCommitFailureKeepsSourceSealed() async throws {
        let seed = try TransitionSeed(); defer { seed.remove() }
        let domain = TransitionDomainFixture(); domain.failCommit = true
        let driver = TestSyncEngineDriver()
        let runtime = CloudAccountTransitionCoordinator(baseURL: seed.root, keychain: seed.keys, zoneID: testZoneID(), lifecycle: domain, engineFactory: { _, _ in driver })
        await #expect(throws: (any Error).self) {
            try await runtime.transition(from: seed.account, to: CloudAccountBinding(containerIdentifier: "test", userRecordName: "B"), now: .now)
        }
        #expect(runtime.phase == .blocked && !runtime.completed)
        #expect(await driver.sendCallCount() == 0)
        #expect(domain.committedAccounts.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(at: seed.vaultURL, includingPropertiesForKeys: nil).contains { $0.pathExtension == "vault" })
    }
    @Test func canonicalOwnedTemporaryAssetRootCanOpen() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SyncAccountStorage(baseURL: root)
        let paths = try storage.open(identity: SyncAccountIdentity(containerIdentifier: "test", userRecordName: "test"))
        _ = try CloudAssetStagingService(rootURL: paths.staging.appendingPathComponent("cloud-assets"), accountIdentifier: "test")
    }
    @Test func roundTripRestoresOnlyOriginalMutationAndBlocksSendUntilCommittedFetch() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = TransitionMemoryKeys()
        let a = try CloudAccountBinding(containerIdentifier: "test", userRecordName: "A")
        let b = try CloudAccountBinding(containerIdentifier: "test", userRecordName: "B")
        let storage = SyncAccountStorage(baseURL: root)
        let paths = try storage.open(identity: a.identity)
        let journal = FileSyncMutationJournal(url: paths.mutationJournalURL)
        let attachment = try integrationAttachment(root: paths.staging)
        try journal.enqueue(attachment)
        let exact = try journal.pending()
        let originalURL = try #require(exact.first?.attachmentSource?.fileURL)
        try Data("archive A".utf8).write(to: paths.workingSet.appendingPathComponent("projects-v1.json"))
        try storage.close()
        let driver = TestSyncEngineDriver()
        await driver.suspendNextFetch()
        let domain = TransitionDomainFixture()
        let runtime = CloudAccountTransitionCoordinator(baseURL: root, keychain: keys,
            zoneID: testZoneID(), lifecycle: domain, engineFactory: { _, _ in driver })
        let first = Task { try await runtime.transition(from: a, to: b, now: .now) }
        try await waitForFetch(runtime, driver: driver, task: first)
        #expect(runtime.phase == .fetching)
        #expect(await driver.sendCallCount() == 0)
        #expect(!FileManager.default.fileExists(atPath: originalURL.path))
        let bTransport = try #require(runtime.currentTransport)
        await #expect(throws: (any Error).self) { try await bTransport.finishMutationReplay() }
        await driver.resumeFetch()
        try await first.value
        #expect(runtime.phase == .ready)
        #expect(try runtime.currentJournal?.pending().isEmpty == true)
        #expect(domain.committedAccounts == [b.identity])
        let bState = root.appendingPathComponent(b.identity.accountIDHash).appendingPathComponent("engine-state/engine.json")
        let serialization = try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: Data(#"{"data":"AQ=="}"#.utf8))
        await bTransport.receiveStateUpdate(serialization)
        #expect(FileManager.default.fileExists(atPath: bState.path))
        #expect(FileManager.default.fileExists(atPath: bState.appendingPathExtension("incoming-batches").path))
        await driver.suspendNextFetch()
        let second = Task { try await runtime.transition(from: b, to: a, now: .now) }
        try await waitForFetch(runtime, driver: driver, task: second)
        #expect(try runtime.currentJournal?.pending() == exact)
        #expect(try Data(contentsOf: originalURL) == Data("Plan2 immutable attachment bytes".utf8))
        _ = try #require(runtime.currentTransport)
        await bTransport.receiveFetchedChanges(records: [], deletedRecordIDs: [])
        await bTransport.receiveStateUpdate(serialization)
        #expect(!FileManager.default.fileExists(atPath: bState.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(b.identity.accountIDHash).appendingPathComponent("engine-state/engine.json.incoming-batches").path))
        await driver.resumeFetch()
        try await second.value
        #expect(runtime.phase == .ready)
        #expect(domain.committedAccounts == [b.identity, a.identity])
    }
    @Test func keychainUsesInsertOnlyDeviceLocalKeysAndPreservesSecurityErrors() throws {
        let calls = RecoverySecurityFixture()
        let keychain = CloudRecoveryVaultKeychain(calls: calls)
        let id = UUID(), key = Data(repeating: 7, count: 32)
        try keychain.insert(key, for: id)
        #expect(try keychain.key(for: id) == key)
        #expect(calls.inserted?[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(calls.inserted?[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(throws: (any Error).self) { try keychain.insert(key, for: id) }
        calls.status = errSecInteractionNotAllowed
        #expect(throws: (any Error).self) { try keychain.key(for: id) }
        #expect(throws: (any Error).self) { try keychain.remove(for: id) }
        calls.status = errSecSuccess
        try keychain.remove(for: id)
        #expect(try keychain.key(for: id) == nil)
    }
}

private final class TransitionMemoryKeys: SyncRecoveryVaultKeychain, @unchecked Sendable {
    let lock = NSLock()
    var keys: [UUID: Data] = [:]
    var failInsert = false
    func insert(_ key: Data, for id: UUID) throws { lock.lock(); defer { lock.unlock() }; if failInsert { throw TransitionTestError.unexpected }; keys[id] = key }
    func key(for id: UUID) throws -> Data? { lock.lock(); defer { lock.unlock() }; return keys[id] }
    func remove(for id: UUID) throws { lock.lock(); defer { lock.unlock() }; keys[id] = nil }
}

@MainActor private final class TransitionDomainFixture: CloudAccountDomainLifecycle {
    var committedAccounts: [SyncAccountIdentity] = []
    var failFreeze = false
    var failCommit = false
    var commitLatch: TransitionCommitLatch?
    func stopPublishingAndHide() throws {}
    func freeze(account: CloudAccountBinding, paths: SyncAccountStorage.Paths, journal: FileSyncMutationJournal) async throws {
        if failFreeze { throw TransitionTestError.unexpected }
    }
    func discardClosedAccount() throws {}
    func install(account: CloudAccountBinding, paths: SyncAccountStorage.Paths, journal: FileSyncMutationJournal) async throws -> CloudAccountDomainInstallation {
        let archive = paths.workingSet.appendingPathComponent("projects-v1.json")
        try Data("installed canonical".utf8).write(to: archive)
        return .init(recordProvider: TransitionRecordProvider(journal: journal), fetchedBatchCommitter: TransitionDurableCommitter(url: archive, fail: failCommit, latch: commitLatch) { [weak self] in self?.committedAccounts.append(account.identity) })
    }
    func resumePublishing() throws {}
}

private struct TransitionRecordProvider: SyncRecordProvider {
    let journal: FileSyncMutationJournal
    func record(for id: SyncEntityID) throws -> SyncRecord? {
        try journal.pending().last(where: { $0.recordID == id })?.savedRecordVersion?.record
    }
}

private struct TransitionDurableCommitter: SyncFetchedBatchCommitting {
    let url: URL
    let fail: Bool
    let latch: TransitionCommitLatch?
    let committed: @MainActor @Sendable () -> Void
    func commitFetchedBatch(batch: SyncRemoteBatch, accountEpoch: CloudSyncAccountEpoch) async throws {
        if fail { throw TransitionTestError.unexpected }
        await latch?.wait()
        let bytes = try JSONEncoder().encode(TransitionCommittedPayload(batchID: batch.identity.batchID, records: batch.records, deleted: batch.deletedRecordIDs))
        try accountEpoch.withCurrent { try DescriptorRelativeAtomicFile(url: url).write(bytes) }
        await committed()
    }
    func didAcknowledgeFetchedBatch(batch: SyncRemoteBatchIdentity, accountEpoch: CloudSyncAccountEpoch) async throws { try accountEpoch.requireCurrent() }
    func commitServerRecordChanged(input: SyncConflictInput, accountEpoch: CloudSyncAccountEpoch) async throws -> SyncConflictCommitResult { throw TransitionTestError.unexpected }
}

private struct TransitionCommittedPayload: Codable {
    let batchID: UUID
    let records: [SyncRecord]
    let deleted: [SyncEntityID]
}

private actor TransitionCommitLatch {
    private(set) var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { waiter = $0 } }
    func release() { waiter?.resume(); waiter = nil }
}

private struct TransitionSeed {
    let root: URL
    let account = try! CloudAccountBinding(containerIdentifier: "test", userRecordName: "A")
    let keys = TransitionMemoryKeys()
    let mutation = SyncMutation.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID())
    let journalURL: URL
    let archiveURL: URL
    let vaultURL: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = SyncAccountStorage(baseURL: root)
        let paths = try storage.open(identity: account.identity)
        journalURL = paths.mutationJournalURL
        archiveURL = paths.workingSet.appendingPathComponent("projects-v1.json")
        vaultURL = paths.vault
        try Data("canonical A".utf8).write(to: archiveURL)
        try FileSyncMutationJournal(url: journalURL).enqueue(mutation)
        try storage.close()
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
private enum TransitionTestError: Error { case unexpected }

@MainActor private func waitForFetch(_ runtime: CloudAccountTransitionCoordinator, driver: TestSyncEngineDriver, task: Task<Void, any Error>) async throws {
    for _ in 0..<3_000 {
        try await Task.sleep(for: .milliseconds(1))
        if await driver.isFetchSuspended() { return }
        if runtime.phase == .blocked {
            do { try await task.value } catch {
                Issue.record("Transition failed before fetch: \(String(reflecting: type(of: error))) \(error)")
                throw error
            }
            throw TransitionTestError.unexpected
        }
    }
    task.cancel()
    throw TransitionTestError.unexpected
}

private final class RecoverySecurityFixture: CloudRecoverySecurityCalls, @unchecked Sendable {
    var inserted: [String: Any]?
    var status = errSecSuccess
    var values: [String: Data] = [:]
    func add(_ query: [String: Any]) -> OSStatus {
        guard status == errSecSuccess else { return status }
        let id = query[kSecAttrAccount as String] as! String
        guard values[id] == nil else { return errSecDuplicateItem }
        inserted = query; values[id] = query[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        guard status == errSecSuccess else { return (status, nil) }
        let value = values[query[kSecAttrAccount as String] as! String]
        return (value == nil ? errSecItemNotFound : errSecSuccess, value)
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        guard status == errSecSuccess else { return status }
        return values.removeValue(forKey: query[kSecAttrAccount as String] as! String) == nil ? errSecItemNotFound : errSecSuccess
    }
}
