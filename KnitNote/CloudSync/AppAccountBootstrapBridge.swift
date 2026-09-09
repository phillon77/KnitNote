import Foundation

@MainActor final class AppAccountBootstrapBridge {
    private let context: AppAccountDomainContext
    private let scope: CloudBootstrapSessionScope
    private let reader: CloudBootstrapSnapshotReader
    private let source: SyncBootstrapSourceAccess
    private let deviceID: String
    private let boundary: (SyncBootstrapOwnedBoundary) throws -> Void
    private var used = false
    private var installing = false
    private var stopped = false
    private var drain: Task<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var runtimeAssets: CloudAssetStagingService { reader.runtimeAssets }

    convenience init(context: AppAccountDomainContext, scope: CloudBootstrapSessionScope,
        reader: CloudBootstrapSnapshotReader, source: SyncBootstrapSourceAccess, deviceID: String) {
        self.init(context: context, scope: scope, reader: reader, source: source, deviceID: deviceID, boundary: { _ in })
    }
    init(context: AppAccountDomainContext, scope: CloudBootstrapSessionScope,
        reader: CloudBootstrapSnapshotReader, source: SyncBootstrapSourceAccess, deviceID: String,
        boundary: @escaping (SyncBootstrapOwnedBoundary) throws -> Void) {
        self.context = context; self.scope = scope; self.reader = reader; self.source = source
        self.deviceID = deviceID; self.boundary = boundary
    }

    func install() async throws -> SyncCanonicalBootstrapHandoff {
        guard !used, !stopped else { throw SyncBootstrapError.invalidPhase }
        used = true; installing = true
        defer { installing = false; let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() } }
        return try await withTaskCancellationHandler {
            do {
                let storage = try validate()
                let tx = try SyncBootstrapOwnedTransaction(storage: storage, paths: context.paths,
                    account: context.account.identity, context: scope.context,
                    validateContext: { [scope] value in
                        guard value == scope.context else { throw SyncBootstrapError.contextChanged }
                        try scope.requireCurrent()
                    }, boundary: { [scope, boundary] point in
                        try scope.requireCurrent()
                        try boundary(point)
                        try scope.requireCurrent()
                    })
                let recovered = try scope.withCurrent {
                    try AppBootstrapRecovery.recover(context: context, captured: scope.context, transaction: tx,
                        validateNative: { [scope] in try scope.requireCurrent() })
                }
                _ = try validate()
                if let recovered { try recovered.revalidate(); return recovered }
                // Reject corrupt/unresolved input before network admission, then
                // recapture actual source and Watch metadata after the full read.
                _ = try source.capture(deviceID: deviceID)
                let lease = try await reader.read()
                _ = try validate()
                let input = try source.capture(deviceID: deviceID)
                _ = try validate()
                let result = try lease.withSnapshot(context: scope.context, counterContext: input.counterReminderContext) { remote in
                    let prepared = try tx.prepare(.init(local: input.local, sourceArchive: input.archive,
                        remote: remote, pending: input.pending, counterReminderContext: input.counterReminderContext))
                    try tx.install(prepared)
                    _ = try tx.commit(prepared)
                    guard let handoff = try tx.recover() else { throw SyncBootstrapError.invalidPhase }
                    return handoff
                }
                _ = try validate()
                lease.consume()
                return result
            } catch {
                stop()
                await drain?.value
                throw error
            }
        } onCancel: { [scope] in scope.invalidate() }
    }

    private func validate() throws -> SyncAccountStorage {
        try Task.checkCancellation(); try scope.requireCurrent(); try context.validateOwnership()
        guard !stopped, let storage = context.storage, scope.account == context.account,
              scope.context.accountIDHash == context.account.identity.accountIDHash,
              context.journal.recoveryLocation == context.paths.mutationJournalURL, !deviceID.isEmpty else {
            throw CloudAccountTransitionCoordinator.Failure.wrongAccount
        }
        try source.requireBinding(storage: storage, paths: context.paths, account: context.account.identity)
        try reader.requireBinding(storage: storage, paths: context.paths, scope: scope)
        return storage
    }

    func stop() {
        scope.invalidate(); stopped = true
        if drain == nil { drain = Task { [reader] in await reader.cancelAndWait() } }
    }

    func waitUntilStopped() async {
        if let drain { await drain.value }
        if installing { await withCheckedContinuation { waiters.append($0) } }
    }
}

/// Shares verified native format routing. App ownership callbacks reacquire the
/// storage owner, so only validateNative may run inside native transactions.
@MainActor enum AppBootstrapRecovery {
    static func recover(context: AppAccountDomainContext, captured: SyncBootstrapContext,
        transaction: SyncBootstrapOwnedTransaction, validateNative: @escaping () throws -> Void) throws -> SyncCanonicalBootstrapHandoff? {
        try validateNative(); try context.validateOwnership()
        guard let storage = context.storage, captured.accountIDHash == context.account.identity.accountIDHash,
              context.journal.recoveryLocation == context.paths.mutationJournalURL else {
            throw CloudAccountTransitionCoordinator.Failure.wrongAccount
        }
        let recovered: SyncCanonicalBootstrapHandoff?
        switch try transaction.selectedRecoveryFormat() {
        case .none: recovered = nil
        case .owned: recovered = try transaction.recover()
        case .legacy:
            let legacy = try SyncBootstrapTransaction(liveRoot: context.paths.workingSet, context: captured,
                validateContext: { value in
                    guard value == captured else { throw SyncBootstrapError.contextChanged }
                    try validateNative(); try context.validateOwnership()
                })
            recovered = try legacy.recoverUnderCurrentContext()
            try validateNative(); try context.validateOwnership()
            if recovered == nil { _ = try transaction.recover() }
            else {
                // Actual committed legacy, including missing-archive v2, uses
                // native inventory validation, never rollback control reissue.
                _ = try SyncAccountRecoveryInventory.capture(storage: storage, paths: context.paths,
                    account: context.account.identity, journal: context.journal,
                    archiveURL: context.paths.workingSet.appendingPathComponent("projects-v1.json"))
            }
        }
        try validateNative(); try context.validateOwnership()
        return recovered
    }
}
