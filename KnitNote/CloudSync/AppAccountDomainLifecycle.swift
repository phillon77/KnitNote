import CloudKit
import Foundation

/// App publication is a separate authority from the engine's committed fetch.
@MainActor final class AppAccountDomainLifecycle: CloudAccountDomainLifecycle {
    private let owner: AppSessionOwner
    private let factory: AppAccountDomainFactory
    private let bootstrapFactory: (@MainActor (AppAccountDomainContext, SyncBootstrapContext, CKRecordZone.ID) throws -> AppAccountBootstrapBridge)?
    private var generation: UUID?
    private var transitionOpen = false
    private var freezeID: UUID?
    private var bootstrap: SyncCanonicalBootstrapHandoff?
    private var installed: AppAccountInstalledDomain?
    private var rejected: [AppSessionResources] = []
    private var validateInstalled: (() throws -> Void)?
    private var activeBridge: AppAccountBootstrapBridge?
    private var retiredBridges: [AppAccountBootstrapBridge] = []
    private var installing = false

    init(owner: AppSessionOwner, factory: AppAccountDomainFactory,
         bootstrapFactory: (@MainActor (AppAccountDomainContext, SyncBootstrapContext, CKRecordZone.ID) throws -> AppAccountBootstrapBridge)? = nil) {
        self.owner = owner; self.factory = factory
        self.bootstrapFactory = bootstrapFactory
    }

    /// Call synchronously at the identity boundary, before starting async work.
    @discardableResult func beginTransition() -> UUID {
        retireBridge()
        let next = owner.beginTransition()
        // A synchronous visibility observer may already have begun a newer
        // lifecycle transition. Do not replace its token with this outer one.
        guard owner.generation == next else { return next }
        generation = next; transitionOpen = true; freezeID = nil; bootstrap = nil
        rejectUnpublished()
        return next
    }

    func stopPublishingAndHide() throws {
        if !transitionOpen { _ = beginTransition() }
        else { retireBridge(); rejectUnpublished() }
    }

    func captureTransitionValidation() -> () throws -> Void {
        let requested = generation
        return { [weak owner] in
            guard let owner, let requested, owner.generation == requested else {
                throw AppSessionOwner.Failure.staleGeneration
            }
        }
    }

    func freeze(account: CloudAccountBinding, paths: SyncAccountStorage.Paths, journal: FileSyncMutationJournal) async throws {
        let requested = generation
        try await waitForStoppedOperations()
        guard requested == generation else { throw SyncBootstrapError.contextChanged }
        guard paths.accountRoot.lastPathComponent == account.identity.accountIDHash,
              journal.recoveryLocation.standardizedFileURL == paths.mutationJournalURL.standardizedFileURL else {
            throw CloudAccountTransitionCoordinator.Failure.wrongAccount
        }
        freezeID = UUID()
    }

    /// Joins resources even when identity is unknown and no storage was opened.
    /// Failure keeps each owner/candidate retained for a subsequent drain.
    func waitForStoppedOperations() async throws {
        while let bridge = retiredBridges.first {
            await bridge.waitUntilStopped()
            retiredBridges.removeAll { $0 === bridge }
        }
        try await owner.waitForRetiredSessions()
        while let candidate = rejected.first {
            try await candidate.waitForStoppedOperations()
            rejected.removeAll { $0 === candidate }
        }
        try Task.checkCancellation()
    }

    func recoverBootstrap(context: AppAccountDomainContext) throws {
        try context.validateOwnership()
        let (captured, validateNative) = try bootstrapContext(context)
        guard let storage = context.storage else { throw CloudAccountTransitionCoordinator.Failure.wrongAccount }
        let tx = try SyncBootstrapOwnedTransaction(storage: storage, paths: context.paths,
            account: context.account.identity, context: captured,
            validateContext: { value in
                guard value == captured else { throw SyncBootstrapError.contextChanged }
                try validateNative()
            })
        bootstrap = try AppBootstrapRecovery.recover(context: context, captured: captured,
            transaction: tx, validateNative: validateNative)
    }

    func install(context: AppAccountDomainContext, runtime: AppAccountDomainRuntime) async throws -> CloudAccountDomainInstallation {
        guard !installing else { throw CloudAccountTransitionCoordinator.Failure.transitionInProgress }
        installing = true
        defer { installing = false }
        try context.validateOwnership()
        let (captured, validateNative) = try bootstrapContext(context)
        var selectedRuntime = runtime
        // Namespace validation/recovery preceded this read-only check. Only the
        // factory with an existing canonical or actual handoff may create stores.
        if try SyncCanonicalCheckpointStore.loadIfPresent(liveRoot: context.paths.workingSet,
            account: context.account.identity, validateOwnership: context.validateOwnership) != nil { bootstrap = nil }
        else {
            if bootstrap == nil { try recoverBootstrap(context: context) }
            if bootstrap == nil {
                guard let bootstrapFactory else { throw CloudAccountTransitionCoordinator.Failure.bootstrapRequired }
                let bridge = try bootstrapFactory(context, captured, runtime.zoneID)
                activeBridge = bridge
                do {
                    let handoff = try await bridge.install()
                    try Task.checkCancellation(); try validateNative(); try context.validateOwnership()
                    guard activeBridge === bridge else { throw SyncBootstrapError.contextChanged }
                    bootstrap = handoff
                    selectedRuntime = .init(assets: bridge.runtimeAssets, incoming: runtime.incoming, zoneID: runtime.zoneID)
                } catch {
                    bridge.stop()
                    if activeBridge === bridge { retireBridge() }
                    throw error
                }
            }
        }
        try validateNative(); try context.validateOwnership()
        let result = try factory.install(context: context, runtime: selectedRuntime, bootstrap: bootstrap)
        installed = result
        validateInstalled = context.validateOwnership
        do { try Task.checkCancellation(); try context.validateOwnership() }
        catch { rejectUnpublished(); throw error }
        return .init(recordProvider: result.recordProvider, fetchedBatchCommitter: result.fetchedBatchCommitter,
            localAccessReady: true, runtimeAssets: selectedRuntime.assets)
    }

    func resumePublishing() throws {
        guard let installed, let generation, let validateInstalled else { throw SyncPublicationError.pendingRepair }
        do {
            try validateInstalled()
            try owner.publishPreparedSession(installed.resources, for: generation)
            try validateInstalled()
        } catch { rejectUnpublished(); throw error }
        self.installed = nil; self.validateInstalled = nil
        bootstrap = nil; transitionOpen = false
    }

    func discardClosedAccount() throws {
        guard installed == nil, rejected.isEmpty, activeBridge == nil, retiredBridges.isEmpty, owner.visibleSession == nil else {
            throw AppSessionOwner.Failure.retiredWorkPending
        }
        bootstrap = nil; freezeID = nil; validateInstalled = nil
    }

    private func rejectUnpublished() {
        if let installed {
            installed.resources.stopForSessionTransition()
            rejected.append(installed.resources)
        }
        installed = nil; validateInstalled = nil
    }

    private func retireBridge() {
        if let activeBridge {
            activeBridge.stop()
            retiredBridges.append(activeBridge)
            self.activeBridge = nil
        }
    }

    private func bootstrapContext(_ context: AppAccountDomainContext) throws -> (SyncBootstrapContext, () throws -> Void) {
        guard let freezeID, let generation else { throw SyncBootstrapError.contextChanged }
        let captured = SyncBootstrapContext(accountIDHash: context.account.identity.accountIDHash, epoch: generation, freezeID: freezeID)
        let validate: () throws -> Void = { [weak self] in
            guard let self, self.freezeID == freezeID, self.generation == generation,
                  self.owner.generation == generation else { throw SyncBootstrapError.contextChanged }
        }
        try validate()
        return (captured, validate)
    }
}
