import CloudKit
import Foundation
import Darwin

struct CloudAccountBinding: Equatable, Sendable {
    let identity: SyncAccountIdentity
    let containerIdentifier: String
    let userRecordName: String
    init(containerIdentifier: String, userRecordName: String) throws {
        identity = try SyncAccountIdentity(containerIdentifier: containerIdentifier, userRecordName: userRecordName)
        self.containerIdentifier = containerIdentifier; self.userRecordName = userRecordName
    }
}

enum CloudAccountTransitionPhase: Equatable { case stopping, frozen, sealed, cleaned, opening, fetching, ready, blocked }

struct CloudAccountDomainInstallation {
    let recordProvider: any SyncRecordProvider
    let fetchedBatchCommitter: any SyncFetchedBatchCommitting
}

/// Plan 4 integration gate. Implementations must stop all UI mutation publication,
/// hide old records, and freeze canonical/journal writers until installation and
/// the committed first fetch permit resumption. Installation must validate/load
/// the current account's canonical data and supply its real durable committer.
@MainActor protocol CloudAccountDomainLifecycle: AnyObject {
    func stopPublishingAndHide() throws
    func freeze(account: CloudAccountBinding, paths: SyncAccountStorage.Paths, journal: FileSyncMutationJournal) async throws
    func discardClosedAccount() throws
    func install(account: CloudAccountBinding, paths: SyncAccountStorage.Paths, journal: FileSyncMutationJournal) async throws -> CloudAccountDomainInstallation
    func resumePublishing() throws
}

@MainActor final class CloudAccountTransitionCoordinator {
    enum Failure: Error { case transitionInProgress, wrongAccount, invalidRecovery }
    private(set) var phase: CloudAccountTransitionPhase = .blocked
    private(set) var completed = false
    var currentTransport: CKSyncEngineTransport? { session?.transport }
    var currentJournal: FileSyncMutationJournal? { session?.journal }
    private let baseURL: URL
    private let keychain: any SyncRecoveryVaultKeychain
    private let zoneID: CKRecordZone.ID
    private let lifecycle: any CloudAccountDomainLifecycle
    private let engineFactory: CKSyncEngineTransport.EngineFactory
    private let maximumRecoveryBytes: Int
    private let recoverySynchronize: @Sendable (Int32) throws -> Void
    private var session: Session?
    private var transitioning = false

    init(baseURL: URL, keychain: any SyncRecoveryVaultKeychain, zoneID: CKRecordZone.ID,
         lifecycle: any CloudAccountDomainLifecycle,
         maximumRecoveryBytes: Int = 100_000_000,
         recoverySynchronize: @escaping @Sendable (Int32) throws -> Void = { guard fsync($0) == 0 else { throw SyncAccountRecoveryTransaction.Error.unavailable } },
         engineFactory: @escaping CKSyncEngineTransport.EngineFactory) {
        self.baseURL = baseURL; self.keychain = keychain; self.zoneID = zoneID
        self.lifecycle = lifecycle; self.engineFactory = engineFactory
        self.maximumRecoveryBytes = maximumRecoveryBytes
        self.recoverySynchronize = recoverySynchronize
    }

    /// A failed operation keeps its storage owner and source/cipher available.
    /// A process restart can reenter with the account whose selected intent was
    /// interrupted, or with from:nil to resume opening that original account.
    func transition(from old: CloudAccountBinding?, to new: CloudAccountBinding?, now: Date) async throws {
        guard !transitioning else { throw Failure.transitionInProgress }
        guard session == nil || session?.account == old else { throw Failure.wrongAccount }
        transitioning = true; completed = false; phase = .stopping
        defer { transitioning = false }
        do {
            // Immediate epoch invalidation/detachment happens before freeze can
            // suspend. Cancellation need not finish to make callbacks stale.
            if let transport = session?.transport { _ = await transport.invalidateForAccountTransition() }
            session?.sync?.stopForAccountTransition()
            try lifecycle.stopPublishingAndHide()
            try Task.checkCancellation()
            if let old {
                if session == nil { session = try open(old) }
                guard let source = session, source.account == old else { throw Failure.wrongAccount }
                try await lifecycle.freeze(account: old, paths: source.paths, journal: source.journal)
                phase = .frozen
                try Task.checkCancellation()
                if let transport = source.transport { try await transport.validateRecoveryBinding(account: old, paths: source.paths) }
                if let selected = try source.transaction.lifecycleSnapshot(now: now) {
                    guard selected.phase == .sealed || selected.phase == .cleanupStarted || selected.phase == .cleanupComplete else {
                        // Restore must finish and be consumed in the original
                        // account before a later sign-out can capture new data.
                        throw Failure.invalidRecovery
                    }
                    phase = .sealed
                    _ = try source.transaction.recoverInterruptedTransition(now: now)
                } else {
                    let prepared = try source.transaction.prepare(now: now)
                    let sealed = try source.transaction.seal(prepared, now: now)
                    phase = .sealed
                    try Task.checkCancellation()
                    try source.transaction.cleanup(sealed)
                }
                phase = .cleaned
                if let transport = source.transport {
                    try await transport.retireAfterSealedCleanup(transaction: source.transaction, account: old, paths: source.paths, now: now)
                }
                try source.storage.close()
                session = nil
                try lifecycle.discardClosedAccount()
            }
            try Task.checkCancellation()
            guard let new else { completed = true; return }
            phase = .opening
            let destination = try open(new)
            session = destination
            try await lifecycle.freeze(account: new, paths: destination.paths, journal: destination.journal)
            try Task.checkCancellation()
            if let selected = try destination.transaction.lifecycleSnapshot(now: now) {
                if selected.phase == .sealed || selected.phase == .cleanupStarted {
                    _ = try destination.transaction.recoverInterruptedTransition(now: now)
                }
                try destination.transaction.restore(vaultID: selected.receipt.vaultID, now: now)
                guard try destination.transaction.consumeRestoredSelection(vaultID: selected.receipt.vaultID, now: now) else {
                    throw Failure.invalidRecovery
                }
            } else {
                try destination.transaction.synchronizeSelectionAbsence(now: now)
            }
            // Only after restore/verified consumption (or synchronized fresh
            // absence) may domain initialization or normal asset stores write.
            let installation = try await lifecycle.install(account: new, paths: destination.paths, journal: destination.journal)
            try Task.checkCancellation()
            let assets = try CloudAssetStagingService(rootURL: destination.paths.staging.appendingPathComponent("cloud-assets"), accountIdentifier: new.userRecordName)
            let state = FileCloudSyncEngineStateStore(url: destination.paths.engineState.appendingPathComponent("engine.json"))
            let fields = FileCloudRecordSystemFieldsStore(url: destination.paths.engineState.appendingPathComponent("system-fields.json"), zoneID: zoneID)
            let transport = CKSyncEngineTransport(zoneID: zoneID, stateStore: state, systemFieldsStore: fields,
                initialAccountIdentifier: new.userRecordName, assetStaging: assets, requiresInitialFetchReceipt: true, engineFactory: engineFactory)
            destination.transport = transport
            try await transport.validateRecoveryBinding(account: new, paths: destination.paths)
            let sync = KnitNoteCloudSyncCoordinator(transport: transport, journal: destination.journal,
                mergeEngine: SyncMergeEngine(), recordProvider: installation.recordProvider,
                fetchedBatchCommitter: installation.fetchedBatchCommitter, screenshotMode: false)
            destination.sync = sync
            sync.accountChangeHandler = { [weak self] _, current in
                guard let self else { return }
                Task { @MainActor in
                    do {
                        let next = try current.map { try CloudAccountBinding(containerIdentifier: new.containerIdentifier, userRecordName: $0) }
                        try await self.transition(from: new, to: next, now: .now)
                    } catch { self.phase = .blocked; self.completed = false }
                }
            }
            phase = .fetching
            try await sync.startForAccountTransition { [weak self, weak destination] receipt in
                guard let self, let destination, self.session === destination,
                      receipt.epoch.accountIdentifier == new.userRecordName else { throw Failure.wrongAccount }
                try Task.checkCancellation()
                try receipt.epoch.requireCurrent()
                try self.lifecycle.resumePublishing()
                self.phase = .ready
            }
            try Task.checkCancellation()
            completed = true
        } catch {
            phase = .blocked; completed = false
            try? lifecycle.stopPublishingAndHide()
            session?.sync?.stopForAccountTransition()
            if let transport = session?.transport { _ = await transport.invalidateForAccountTransition() }
            throw error
        }
    }

    private func open(_ account: CloudAccountBinding) throws -> Session {
        let storage = SyncAccountStorage(baseURL: baseURL)
        let paths = try storage.open(identity: account.identity)
        let journal = FileSyncMutationJournal(url: paths.journal.appendingPathComponent("pending.json"))
        let vault = SyncRecoveryVault(directory: paths.vault, keychain: keychain)
        return Session(account: account, storage: storage, paths: paths, journal: journal,
            transaction: SyncAccountRecoveryTransaction(storage: storage, paths: paths, account: account.identity,
                vault: vault, journal: journal, maximumBytes: maximumRecoveryBytes, synchronize: recoverySynchronize))
    }

    private final class Session {
        let account: CloudAccountBinding
        let storage: SyncAccountStorage
        let paths: SyncAccountStorage.Paths
        let journal: FileSyncMutationJournal
        let transaction: SyncAccountRecoveryTransaction
        var transport: CKSyncEngineTransport?
        var sync: KnitNoteCloudSyncCoordinator?
        init(account: CloudAccountBinding, storage: SyncAccountStorage, paths: SyncAccountStorage.Paths,
             journal: FileSyncMutationJournal, transaction: SyncAccountRecoveryTransaction) {
            self.account = account; self.storage = storage; self.paths = paths
            self.journal = journal; self.transaction = transaction
        }
    }
}
