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
    var localAccessReady = false
    let runtimeAssets: CloudAssetStagingService?
    init(recordProvider: any SyncRecordProvider, fetchedBatchCommitter: any SyncFetchedBatchCommitting,
        localAccessReady: Bool = false, runtimeAssets: CloudAssetStagingService? = nil) {
        self.recordProvider = recordProvider; self.fetchedBatchCommitter = fetchedBatchCommitter
        self.localAccessReady = localAccessReady; self.runtimeAssets = runtimeAssets
    }
}

/// Stops publication and drains the old domain before recovery. A concrete
/// activated domain may resume local access before fetch; older adapters keep
/// their first-fetch gate. Neither path bypasses the transport receipt gate.
@MainActor protocol CloudAccountDomainLifecycle: AnyObject {
    func stopPublishingAndHide() throws
    func freeze(account: CloudAccountBinding, paths: SyncAccountStorage.Paths, journal: FileSyncMutationJournal) async throws
    func discardClosedAccount() throws
    func captureTransitionValidation() -> () throws -> Void
    func recoverBootstrap(context: AppAccountDomainContext) throws
    func install(context: AppAccountDomainContext, runtime: AppAccountDomainRuntime) async throws -> CloudAccountDomainInstallation
    func resumePublishing() throws
}

@MainActor final class CloudAccountTransitionCoordinator {
    enum Failure: Error, Equatable { case transitionInProgress, wrongAccount, invalidRecovery, bootstrapRequired }
    private(set) var phase: CloudAccountTransitionPhase = .blocked
    private(set) var completed = false
    private(set) var localAccessReady = false
    private(set) var requiresBootstrap = false
    var cloudStatus: CloudSyncStatusSnapshot? { session?.sync?.status }
    var accountInvalidatedHandler: (() -> Void)?
    var statusDidChangeHandler: (() -> Void)?
    var currentTransport: CKSyncEngineTransport? { session?.transport }
    var currentJournal: FileSyncMutationJournal? { session?.journal }
    /// Storage ownership only; this is never evidence of current identity.
    var retainedAccount: CloudAccountBinding? { session?.account }

    func reconcileConfirmedAccount(_ account: CloudAccountBinding?, now: Date) async throws {
        try await performTransition(from: retainedAccount, to: account, now: now,
            reusingRetainedAccount: account != nil && account == retainedAccount)
    }
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
        try await performTransition(from: old, to: new, now: now, reusingRetainedAccount: false)
    }

    private func performTransition(from old: CloudAccountBinding?, to new: CloudAccountBinding?, now: Date,
                                   reusingRetainedAccount: Bool) async throws {
        guard !transitioning else { throw Failure.transitionInProgress }
        guard session == nil || session?.account == old else { throw Failure.wrongAccount }
        transitioning = true; completed = false; localAccessReady = false; phase = .stopping
        requiresBootstrap = false
        defer { transitioning = false; statusDidChangeHandler?() }
        do {
            try lifecycle.stopPublishingAndHide()
            let validateTransition = lifecycle.captureTransitionValidation()
            // Revoke before cancellation suspends. Driver cancellation and the
            // actual sync startup/event tasks must finish before any freeze.
            if let source = session {
                invalidateTransport(source)
                source.sync?.stopForAccountTransition()
                await source.transportTeardown?.value
                await source.sync?.waitForStoppedOperations()
            }
            try Task.checkCancellation()
            if let old, !reusingRetainedAccount {
                if session == nil { session = try open(old) }
                guard let source = session, source.account == old else { throw Failure.wrongAccount }
                try await lifecycle.freeze(account: old, paths: source.paths, journal: source.journal)
                try source.storage.validateRuntimeJournalNamespace(paths: source.paths, account: old.identity, validateBootstrap: false)
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
            try validateTransition()
            phase = .opening
            let destination: Session
            if reusingRetainedAccount, let retained = session { destination = retained }
            else { destination = try open(new, validateConfirmedAccount: validateTransition); session = destination }
            try await openDestination(destination, now: now, validateTransition: validateTransition)
        } catch {
            if case let CloudSyncIssueError.issue(issue) = error, issue.preservesLocalAccess,
               localAccessReady, let session, session.isCurrent, session.establishedLocalAccess {
                do { try session.validateOwnership?(); return }
                catch { /* Authority failure still takes the blocking path. */ }
            }
            phase = .blocked; completed = false
            requiresBootstrap = (error as? Failure) == .bootstrapRequired
            localAccessReady = false
            session?.isCurrent = false
            try? lifecycle.stopPublishingAndHide()
            if let session {
                invalidate(session)
                await session.transportTeardown?.value
                await session.sync?.waitForStoppedOperations()
            }
            if let session {
                // Cleanup must join rejected candidates even if the initiating
                // task was cancelled. A failed drain remains retained by owner.
                await Task { @MainActor [lifecycle] in
                    try? await lifecycle.freeze(account: session.account, paths: session.paths, journal: session.journal)
                }.value
            }
            throw error
        }
    }

    /// Reuse the same validation/restore/bootstrap/install path for fresh opens
    /// and retained-account revalidation. No seal or competing storage lock.
    private func openDestination(_ destination: Session, now: Date,
                                 validateTransition: @escaping () throws -> Void) async throws {
        let new = destination.account
        let runtimeGeneration = UUID()
        destination.runtimeGeneration = runtimeGeneration
        destination.isCurrent = true
        destination.establishedLocalAccess = false
        destination.transport = nil; destination.sync = nil; destination.transportTeardown = nil
        try await lifecycle.freeze(account: new, paths: destination.paths, journal: destination.journal)
        try destination.storage.validateRuntimeJournalNamespace(paths: destination.paths, account: new.identity, validateBootstrap: false)
        let validateRuntimeGeneration: () throws -> Void = { [weak self, weak destination] in
            guard let self, let destination, self.session === destination, destination.runtimeGeneration == runtimeGeneration, destination.isCurrent else {
                throw Failure.wrongAccount
            }
            try validateTransition()
        }
        let context = AppAccountDomainContext(account: new, paths: destination.paths, journal: destination.journal,
            storage: destination.storage,
            validateOwnership: { [weak self, weak destination] in
                try validateRuntimeGeneration()
                guard let self, let destination else { throw Failure.wrongAccount }
                try destination.storage.withRecoveryOwnership(paths: destination.paths, account: new.identity,
                    maximumBytes: self.maximumRecoveryBytes) { try $0.validate() }
            })
        destination.validateOwnership = context.validateOwnership
        try context.validateOwnership()
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
        let routingContext = SyncBootstrapContext(accountIDHash: new.identity.accountIDHash, epoch: runtimeGeneration, freezeID: UUID())
        let routing = try SyncBootstrapOwnedTransaction(storage: destination.storage, paths: destination.paths,
            account: new.identity, context: routingContext, validateContext: { value in
                guard value == routingContext else { throw SyncBootstrapError.contextChanged }
                try validateRuntimeGeneration()
            })
        switch try routing.selectedRecoveryFormat() {
        case .owned:
            // The native initial-recovery issuer and ordinary canonical reopen
            // have distinct authority. A format query alone admits neither.
            let hasWorkingSet = try destination.storage.withRecoveryOwnership(paths: destination.paths,
                account: new.identity, maximumBytes: maximumRecoveryBytes) { access in
                let entries = try access.entries()
                guard !entries.contains(where: { !$0.relativePath.contains("/") && $0.relativePath != "working-set"
                    && OwnedBootstrapCodec.alias($0.relativePath) == OwnedBootstrapCodec.alias("working-set") }) else {
                    throw SyncBootstrapError.unsafePath
                }
                guard let live = entries.first(where: { $0.relativePath == "working-set" }) else { return false }
                guard live.isDirectory else { throw SyncBootstrapError.unsafePath }
                return true
            }
            // Verified open already admitted the native missing-live placement.
            // Complete its real recovery before asking the canonical root to open.
            if !hasWorkingSet { try lifecycle.recoverBootstrap(context: context) }
            let canonical = try SyncCanonicalCheckpointStore.loadIfPresent(liveRoot: destination.paths.workingSet,
                account: new.identity, validateOwnership: context.validateOwnership)
            if canonical == nil {
                if hasWorkingSet { try lifecycle.recoverBootstrap(context: context) }
            }
            else {
                try SyncBootstrapOwnedTerminalEvidence.validateRuntimeAdmission(storage: destination.storage,
                    paths: destination.paths, account: new.identity, validateContext: validateRuntimeGeneration)
            }
        case .none, .legacy:
            do {
                try destination.storage.validateRuntimeJournalNamespace(paths: destination.paths,
                    account: new.identity, validateBootstrap: true)
            } catch SyncBootstrapError.invalidPhase {
                try lifecycle.recoverBootstrap(context: context)
                try destination.storage.validateRuntimeJournalNamespace(paths: destination.paths,
                    account: new.identity, validateBootstrap: true)
            }
        }
        // Only after restore/verified consumption (or synchronized fresh
        // absence) may domain initialization or normal asset stores write.
        let hasCanonical = try SyncCanonicalCheckpointStore.loadIfPresent(liveRoot: destination.paths.workingSet,
            account: new.identity, validateOwnership: context.validateOwnership) != nil
        let assetRoot = destination.paths.staging.appendingPathComponent("cloud-assets")
        let assets = try hasCanonical
            ? CloudAssetStagingService(rootURL: assetRoot, accountIdentifier: new.userRecordName)
            : CloudAssetStagingService.makeForBootstrap(rootURL: assetRoot, accountIdentifier: new.userRecordName,
                maximumAssetBytes: maximumRecoveryBytes)
        let state = FileCloudSyncEngineStateStore(url: destination.paths.engineState.appendingPathComponent("engine.json"))
        let fields = FileCloudRecordSystemFieldsStore(url: destination.paths.engineState.appendingPathComponent("system-fields.json"), zoneID: zoneID)
        let incoming = FileCloudIncomingBatchStore(url: state.relatedURL(pathExtension: "incoming-batches"))
        let runtime = AppAccountDomainRuntime(assets: assets, incoming: incoming, zoneID: zoneID)
        let installation = try await lifecycle.install(context: context, runtime: runtime)
        destination.establishedLocalAccess = installation.localAccessReady
        try Task.checkCancellation()
        try context.validateOwnership()
        let transport = CKSyncEngineTransport(zoneID: zoneID, stateStore: state, incomingBatchStore: incoming, systemFieldsStore: fields,
            initialAccountIdentifier: new.userRecordName, assetStaging: installation.runtimeAssets ?? assets,
            requiresInitialFetchReceipt: true, containerIdentifier: new.containerIdentifier, engineFactory: engineFactory)
        destination.transport = transport
        try await transport.validateRecoveryBinding(account: new, paths: destination.paths)
        let sync = KnitNoteCloudSyncCoordinator(transport: transport, journal: destination.journal,
            mergeEngine: SyncMergeEngine(), recordProvider: installation.recordProvider,
            fetchedBatchCommitter: installation.fetchedBatchCommitter, screenshotMode: false)
        destination.sync = sync
        sync.accountChangeHandler = { [weak self, weak destination] _, _ in
            guard let self, let destination, self.session === destination, destination.runtimeGeneration == runtimeGeneration else { return }
            self.invalidate(destination)
            self.accountInvalidatedHandler?()
        }
        sync.failureHandler = { [weak self, weak destination] issue in
            guard let self, let destination, self.session === destination, destination.runtimeGeneration == runtimeGeneration else { return }
            if !issue.preservesLocalAccess { self.invalidate(destination) }
            else {
                do { try context.validateOwnership(); self.completed = false }
                catch { self.invalidate(destination) }
            }
        }
        sync.transitionCompletionHandler = { [weak self, weak destination] in
            guard let self, let destination, self.session === destination, destination.runtimeGeneration == runtimeGeneration, destination.isCurrent else { return }
            do { try context.validateOwnership(); self.completed = true }
            catch { self.invalidate(destination) }
        }
        if installation.localAccessReady {
            try lifecycle.resumePublishing()
            try context.validateOwnership()
            localAccessReady = true
            statusDidChangeHandler?()
            try context.validateOwnership()
        }
        phase = .fetching
        try await sync.startForAccountTransition { [weak self, weak destination] receipt in
            guard let self, let destination, self.session === destination, destination.runtimeGeneration == runtimeGeneration,
                  receipt.epoch.accountIdentifier == new.userRecordName else { throw Failure.wrongAccount }
            try Task.checkCancellation()
            try receipt.epoch.requireCurrent()
            try context.validateOwnership()
            if !self.localAccessReady { try self.lifecycle.resumePublishing(); self.localAccessReady = true }
            self.phase = .ready
            self.statusDidChangeHandler?()
            try context.validateOwnership()
        }
        try Task.checkCancellation()
        try context.validateOwnership()
        completed = true
    }

    func retrySync() async {
        defer { statusDidChangeHandler?() }
        guard !transitioning, let session else { return }
        guard session.isCurrent else { await session.transportTeardown?.value; return }
        do { try session.validateOwnership?() }
        catch { invalidate(session); await session.transportTeardown?.value; return }
        await session.sync?.syncNow()
        await session.transportTeardown?.value
    }

    private func invalidate(_ destination: Session) {
        destination.isCurrent = false
        localAccessReady = false; completed = false; phase = .blocked
        try? lifecycle.stopPublishingAndHide()
        invalidateTransport(destination)
        destination.sync?.stopForAccountTransition()
        statusDidChangeHandler?()
    }

    /// Revoke runtime authority without sealing, cleaning or releasing storage.
    func stopForAccountTransition() {
        if let session { invalidate(session) }
    }

    /// The caller first joins its retained transaction pump; this joins any
    /// remaining driver cancellation and sync startup/event handling.
    func waitForStoppedOperations() async {
        await session?.transportTeardown?.value
        await session?.sync?.waitForStoppedOperations()
    }

    private func invalidateTransport(_ destination: Session) {
        guard destination.transportTeardown == nil, let transport = destination.transport else { return }
        // The retained session owns the join; this task captures only transport,
        // not coordinator/session, and survives cancellation of its caller.
        destination.transportTeardown = Task {
            let cancellation = await transport.invalidateForAccountTransition()
            await cancellation?.value
        }
    }

    private func open(_ account: CloudAccountBinding, validateConfirmedAccount: (() throws -> Void)? = nil) throws -> Session {
        let storage = SyncAccountStorage(baseURL: baseURL)
        let paths: SyncAccountStorage.Paths
        if let validateConfirmedAccount {
            paths = try storage.openForVerifiedAccount(identity: account.identity, validateAccount: validateConfirmedAccount)
        } else { paths = try storage.open(identity: account.identity) }
        let journal = FileSyncMutationJournal(url: paths.mutationJournalURL)
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
        var runtimeGeneration = UUID()
        var transport: CKSyncEngineTransport?
        var sync: KnitNoteCloudSyncCoordinator?
        var transportTeardown: Task<Void, Never>?
        var isCurrent = true
        var establishedLocalAccess = false
        var validateOwnership: (() throws -> Void)?
        init(account: CloudAccountBinding, storage: SyncAccountStorage, paths: SyncAccountStorage.Paths,
             journal: FileSyncMutationJournal, transaction: SyncAccountRecoveryTransaction) {
            self.account = account; self.storage = storage; self.paths = paths
            self.journal = journal; self.transaction = transaction
        }
    }
}
