import CloudKit
import Foundation

enum CloudBootstrapDownloadBoundary: Sendable {
    case afterBudgetAdmission, afterInputRead, insideAssetLock
}

final class CloudBootstrapSessionScope: @unchecked Sendable {
    let account: CloudAccountBinding
    let zoneID: CKRecordZone.ID
    let context: SyncBootstrapContext
    private let work = NSRecursiveLock()
    private let latch = NSLock()
    private var current = true
    init(account: CloudAccountBinding, zoneID: CKRecordZone.ID, context: SyncBootstrapContext) {
        self.account = account; self.zoneID = zoneID; self.context = context
    }
    func invalidate() { latch.withLock { current = false } }
    func requireCurrent() throws {
        guard latch.withLock({ current }), context.accountIDHash == account.identity.accountIDHash else {
            throw SyncBootstrapError.contextChanged
        }
    }
    func withCurrent<T>(_ body: () throws -> T) throws -> T {
        work.lock(); defer { work.unlock() }
        try requireCurrent()
        let value = try body()
        try requireCurrent()
        return value
    }
}

final class CloudBootstrapDownloadStore: @unchecked Sendable {
    let runtimeAssets: CloudAssetStagingService
    private let storage: SyncAccountStorage
    private let paths: SyncAccountStorage.Paths
    private let scope: CloudBootstrapSessionScope
    private let maximumBytes: Int
    private let beforeBoundary: @Sendable (CloudBootstrapDownloadBoundary) throws -> Void
    private let publicationFault: @Sendable (CloudAssetPublicationBoundary) throws -> Void
    // Protected by scope.withCurrent; never a durable source authority.
    private var issued: [UUID: (SyncAttachmentSource, SyncRegularFileIdentity)] = [:]
    init(storage: SyncAccountStorage, paths: SyncAccountStorage.Paths, scope: CloudBootstrapSessionScope, maximumBytes: Int,
        beforeBoundary: @escaping @Sendable (CloudBootstrapDownloadBoundary) throws -> Void = { _ in },
        publicationFault: @escaping @Sendable (CloudAssetPublicationBoundary) throws -> Void = { _ in }) throws {
        guard (0...100_000_000).contains(maximumBytes) else { throw CloudAssetStagingError.tooLarge }
        try scope.requireCurrent()
        self.storage = storage; self.paths = paths; self.scope = scope; self.maximumBytes = maximumBytes
        self.beforeBoundary = beforeBoundary; self.publicationFault = publicationFault
        runtimeAssets = try .makeForBootstrap(rootURL: paths.staging.appendingPathComponent("cloud-assets"),
            accountIdentifier: scope.account.userRecordName, maximumAssetBytes: maximumBytes)
    }
    func accept(version: SyncAttachmentVersion, sourceURL: URL) throws -> SyncAttachmentSource {
        try scope.withCurrent {
            try storage.withRecoveryOwnership(paths: paths, account: scope.account.identity, maximumBytes: maximumBytes) { access in
                let observer = SyncAccountRecoveryControlFile(synchronize: { _ in })
                let control = try observer.observe(access: access)
                let inventory = try SyncAccountRecoveryInventory.capture(access: access, paths: paths,
                    account: scope.account.identity, journal: FileSyncMutationJournal(url: paths.mutationJournalURL),
                    archiveURL: paths.workingSet.appendingPathComponent("projects-v1.json"), control: control,
                    maximumBytes: maximumBytes)
                let plan = try runtimeAssets.planBootstrapDownload(version: version, sourceURL: sourceURL, accountRoot: paths.accountRoot)
                try SyncBootstrapDownloadBudget.requireFits(access: access, paths: paths, account: scope.account.identity,
                    footprint: plan.footprint, maximumBytes: maximumBytes)
                try beforeBoundary(.afterBudgetAdmission)
                try scope.requireCurrent()
                try runtimeAssets.readBootstrapInput(plan)
                try beforeBoundary(.afterInputRead)
                try scope.requireCurrent()
                try access.validate()
                guard try access.entries() == inventory.entries, try observer.observe(access: access) == control else {
                    throw SyncBootstrapError.sourceChanged
                }
                try runtimeAssets.revalidateBootstrapInput(plan)
                try SyncBootstrapDownloadBudget.requireFits(access: access, paths: paths, account: scope.account.identity,
                    footprint: plan.footprint, maximumBytes: maximumBytes)
                if let prior = issued[version.versionID] {
                    let existing = try runtimeAssets.existingBootstrapDownload(version: version)
                    guard existing.0 == prior.0, existing.1 == prior.1 else { throw SyncBootstrapError.sourceChanged }
                }
                let result = try runtimeAssets.publishBootstrapDownload(plan, requireCurrent: scope.requireCurrent,
                    insideAssetLock: { try beforeBoundary(.insideAssetLock) }, publicationFault: publicationFault)
                try access.validate()
                guard try observer.observe(access: access) == control else { throw SyncBootstrapError.sourceChanged }
                let after = try access.entries()
                guard inventory.entries.allSatisfy(after.contains) else { throw SyncBootstrapError.sourceChanged }
                try SyncBootstrapDownloadBudget.requireFits(access: access, paths: paths, account: scope.account.identity,
                    footprint: .init(directoryPaths: [], files: [:]), maximumBytes: maximumBytes)
                issued[version.versionID] = result
                return result.0
            }
        }
    }
    func requireBinding(storage: SyncAccountStorage, paths: SyncAccountStorage.Paths, scope: CloudBootstrapSessionScope) throws {
        guard self.storage === storage, self.paths == paths, self.scope === scope else { throw SyncBootstrapError.contextChanged }
        try scope.requireCurrent()
    }
    func revalidate(version: SyncAttachmentVersion, source: SyncAttachmentSource) throws {
        try scope.withCurrent {
            guard let prior = issued[version.versionID], prior.0 == source else { throw SyncBootstrapError.sourceChanged }
            try storage.withRecoveryOwnership(paths: paths, account: scope.account.identity, maximumBytes: maximumBytes) { access in
                let current = try runtimeAssets.existingBootstrapDownload(version: version)
                guard current.0 == source, current.1 == prior.1 else { throw SyncBootstrapError.sourceChanged }
                try access.validate()
            }
        }
    }
}
