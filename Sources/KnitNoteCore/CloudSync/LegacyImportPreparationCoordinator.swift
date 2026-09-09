import Foundation

// Caller session observations only: this context does not authenticate an account.
struct LegacyImportPreparationContext: Equatable, Sendable {
    var sourceSession: UUID
    var targetSession: UUID
    var accountDigest: Data
    var source: LegacyLocalImportSource

    fileprivate var canPrepare: Bool {
        accountDigest.count == 32
            && LegacyLocalImportPolicy.decision(for: source) == .requiresConfirmation
    }
}

/// Isolated preparation and intent confirmation; never installs or issues source authority.
/// The owner must invalidate on every source/session/account change, including A -> B -> A.
@MainActor final class LegacyImportPreparationCoordinator {
    private struct Worker {
        let id: UUID
        let task: Task<LegacyImportBackupObservation, Error>
    }

    private struct Pending {
        let proposal: LegacyLocalImportConsentModel.Proposal
        let context: LegacyImportPreparationContext
        let prepared: LegacyImportBackupObservation
        let preparationID: UUID
    }

    private let service: KnitNoteBackupService
    private let consent = LegacyLocalImportConsentModel()
    private var generation = UUID()
    private var activeContext: LegacyImportPreparationContext?
    private var pending: Pending?
    private var worker: Worker?
    // Successful packages survive invalidation, cancellation and subsequent attempts.
    // No cleanup ownership is granted by this coordinator.
    private var retainedPreparations: [URL: LegacyImportBackupObservation] = [:]

    init(service: KnitNoteBackupService) { self.service = service }

    func prepare(context: LegacyImportPreparationContext) async throws
        -> LegacyLocalImportConsentModel.Proposal {
        guard worker == nil else { throw KnitNoteBackupError.operationInProgress }
        invalidate()
        guard context.canPrepare else { throw KnitNoteBackupError.accessDenied }
        try Task.checkCancellation()
        activeContext = context
        let expectedGeneration = generation
        let preparationID = UUID()
        let service = service
        let appVersion = AppVersionInfo.current()?.version ?? "unknown"
        let operation = Worker(id: UUID(), task: Task.detached {
            try service.prepareLegacyImportBackup(appVersion: appVersion)
        })
        worker = operation

        let result = await operation.task.result
        finish(operation, result: result)
        do {
            let prepared = try result.get()
            guard generation == expectedGeneration, activeContext == context,
                  context.canPrepare, !Task.isCancelled else {
                throw CancellationError()
            }
            guard let proposal = consent.present(makeObservation(
                prepared: prepared, context: context, preparationID: preparationID
            )) else {
                throw KnitNoteBackupError.accessDenied
            }
            pending = Pending(proposal: proposal, context: context, prepared: prepared,
                preparationID: preparationID)
            return proposal
        } catch {
            invalidate(ifCurrent: expectedGeneration)
            throw error
        }
    }

    func confirm(
        _ proposal: LegacyLocalImportConsentModel.Proposal,
        context: LegacyImportPreparationContext
    ) async throws -> Bool {
        // A foreign or stale proposal must not disturb a newer pending owner.
        guard let pending, pending.proposal === proposal else { return false }
        guard worker == nil else { throw KnitNoteBackupError.operationInProgress }
        let expectedGeneration = generation
        let expectedContext = pending.context
        guard context == expectedContext, activeContext == expectedContext,
              context.canPrepare, !Task.isCancelled else {
            invalidate(ifCurrent: expectedGeneration)
            return false
        }
        let service = service
        let prepared = pending.prepared
        let operation = Worker(id: UUID(), task: Task.detached {
            try service.revalidateLegacyImportBackup(prepared)
            return prepared
        })
        worker = operation

        let result = await operation.task.result
        finish(operation, result: result)
        // Native failures revoke this generation before being returned to the caller.
        do { _ = try result.get() }
        catch {
            invalidate(ifCurrent: expectedGeneration)
            throw error
        }
        guard generation == expectedGeneration, activeContext == expectedContext,
              context == expectedContext, !Task.isCancelled else {
            invalidate(ifCurrent: expectedGeneration)
            return false
        }
        let confirmed = consent.confirm(proposal, current: makeObservation(
            prepared: prepared, context: context, preparationID: pending.preparationID
        ))
        self.pending = nil
        return confirmed
    }

    /// Synchronously revokes intent while preserving the only native worker drain handle.
    func invalidate() {
        generation = UUID()
        activeContext = nil
        pending = nil
        consent.invalidate()
    }

    /// Revokes and drains the current operation. The owner may prepare again after draining.
    /// Synchronous native I/O runs to completion; caller cancellation never abandons it.
    func stopAndDrain() async {
        invalidate()
        guard let operation = worker else { return }
        let result = await operation.task.result
        finish(operation, result: result)
    }

    private func finish(
        _ operation: Worker, result: Result<LegacyImportBackupObservation, Error>
    ) {
        // Either the initiating call or a drainer may resume first. Complete bookkeeping
        // exactly once before admitting another worker; late callers cannot clear it.
        guard worker?.id == operation.id else { return }
        if case let .success(prepared) = result {
            retainedPreparations[prepared.packageURL] = prepared
        }
        worker = nil
    }

    private func invalidate(ifCurrent expectedGeneration: UUID) {
        guard generation == expectedGeneration else { return }
        invalidate()
    }

    private func makeObservation(
        prepared: LegacyImportBackupObservation,
        context: LegacyImportPreparationContext,
        preparationID: UUID
    ) -> LegacyLocalImportObservation {
        LegacyLocalImportObservation(
            source: context.source,
            sourceDigest: prepared.source.contentDigest,
            backupDigest: prepared.contentDigest,
            accountDigest: context.accountDigest,
            sourceSession: context.sourceSession,
            targetSession: context.targetSession,
            preparation: preparationID
        )
    }
}
