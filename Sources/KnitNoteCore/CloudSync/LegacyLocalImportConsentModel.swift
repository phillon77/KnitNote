import Foundation

struct LegacyLocalImportObservation: Equatable {
    var source: LegacyLocalImportSource
    var sourceDigest: Data
    var backupDigest: Data
    var accountDigest: Data
    var sourceSession: UUID
    var targetSession: UUID
    var preparation: UUID

    var canPresent: Bool {
        LegacyLocalImportPolicy.decision(for: source) == .requiresConfirmation
            && sourceDigest.count == 32 && backupDigest.count == 32
            && accountDigest.count == 32
    }
}

@MainActor final class LegacyLocalImportConsentModel {
    enum State: Equatable { case idle, awaitingConfirmation, confirmedIntentOnly, invalidated }

    final class Proposal { fileprivate init() {} }

    private(set) var state: State = .idle
    private var pending: (proposal: Proposal, observation: LegacyLocalImportObservation)?

    func present(_ observation: LegacyLocalImportObservation) -> Proposal? {
        invalidate()
        guard observation.canPresent else { return nil }
        let proposal = Proposal()
        pending = (proposal, observation)
        state = .awaitingConfirmation
        return proposal
    }

    func confirm(_ proposal: Proposal, current: LegacyLocalImportObservation) -> Bool {
        guard let pending, pending.proposal === proposal else { return false }
        guard pending.observation == current, current.canPresent else {
            invalidate()
            return false
        }
        self.pending = nil
        state = .confirmedIntentOnly
        return true
    }

    func invalidate() {
        pending = nil
        state = .invalidated
    }
}
