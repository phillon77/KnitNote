import Foundation

/// App publication is a separate authority from the engine's committed fetch.
@MainActor final class AppAccountDomainLifecycle: CloudAccountDomainLifecycle {
    private let owner: AppSessionOwner
    private let factory: AppAccountDomainFactory
    private var generation: UUID?
    private var transitionOpen = false
    private var freezeID: UUID?
    private var bootstrap: SyncCanonicalBootstrapHandoff?
    private var installed: AppAccountInstalledDomain?
    private var rejected: [AppSessionResources] = []
    private var validateInstalled: (() throws -> Void)?

    init(owner: AppSessionOwner, factory: AppAccountDomainFactory) {
        self.owner = owner; self.factory = factory
    }

    /// Call synchronously at the identity boundary, before starting async work.
    @discardableResult func beginTransition() -> UUID {
        let next = owner.beginTransition()
        generation = next; transitionOpen = true; freezeID = nil; bootstrap = nil
        rejectUnpublished()
        return next
    }

    func stopPublishingAndHide() throws {
        if !transitionOpen { _ = beginTransition() }
        else { rejectUnpublished() }
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
        try await owner.waitForRetiredSessions()
        while let candidate = rejected.first {
            try await candidate.waitForStoppedOperations()
            rejected.removeAll { $0 === candidate }
        }
        try Task.checkCancellation()
        guard paths.accountRoot.lastPathComponent == account.identity.accountIDHash,
              journal.recoveryLocation.standardizedFileURL == paths.mutationJournalURL.standardizedFileURL else {
            throw CloudAccountTransitionCoordinator.Failure.wrongAccount
        }
        freezeID = UUID()
    }

    func recoverBootstrap(context: AppAccountDomainContext) throws {
        try context.validateOwnership()
        guard let freezeID, let generation else { throw SyncBootstrapError.contextChanged }
        let captured = SyncBootstrapContext(accountIDHash: context.account.identity.accountIDHash, epoch: generation, freezeID: freezeID)
        let tx = try SyncBootstrapTransaction(liveRoot: context.paths.workingSet, context: captured,
            validateContext: { [weak self] value in
                guard let self, self.freezeID == freezeID, self.generation == generation, value == captured else {
                    throw SyncBootstrapError.contextChanged
                }
                try context.validateOwnership()
            })
        bootstrap = try tx.recoverUnderCurrentContext()
    }

    func install(context: AppAccountDomainContext, runtime: AppAccountDomainRuntime) async throws -> CloudAccountDomainInstallation {
        try context.validateOwnership()
        // Namespace validation/recovery preceded this read-only check. Only the
        // factory with an existing canonical or actual handoff may create stores.
        if try SyncCanonicalCheckpointStore.loadIfPresent(liveRoot: context.paths.workingSet,
            account: context.account.identity, validateOwnership: context.validateOwnership) != nil { bootstrap = nil }
        else {
            if bootstrap == nil { try recoverBootstrap(context: context) }
            guard bootstrap != nil else { throw CloudAccountTransitionCoordinator.Failure.bootstrapRequired }
        }
        let result = try factory.install(context: context, runtime: runtime, bootstrap: bootstrap)
        installed = result
        validateInstalled = context.validateOwnership
        do { try Task.checkCancellation(); try context.validateOwnership() }
        catch { rejectUnpublished(); throw error }
        return .init(recordProvider: result.recordProvider, fetchedBatchCommitter: result.fetchedBatchCommitter, localAccessReady: true)
    }

    func resumePublishing() throws {
        guard let installed, let generation, let validateInstalled else { throw SyncPublicationError.pendingRepair }
        do {
            try validateInstalled()
            try owner.publishPreparedSession(installed.resources, for: generation)
            try validateInstalled()
        } catch { rejectUnpublished(); throw error }
        self.installed = nil; self.validateInstalled = nil
        bootstrap = nil; freezeID = nil; transitionOpen = false
    }

    func discardClosedAccount() throws {
        guard installed == nil, rejected.isEmpty, owner.visibleSession == nil else {
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
}
