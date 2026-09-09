// Observation-only policy. Never grants source access or installation authority.
enum LegacyLocalImportSource: CaseIterable, Sendable {
    case availableLocalHistoryUnknown, provenNeverBound, currentAccount
    case foreignAccount, accountUnknown, unverifiedRecovery
    case invalidContent, unresolvedWatchState
}

enum LegacyLocalImportDecision: Equatable, Sendable {
    case requiresConfirmation, useExistingSourceFlow, useExistingAccountRecovery, blocked
}

enum LegacyLocalImportPolicy {
    static func decision(for source: LegacyLocalImportSource) -> LegacyLocalImportDecision {
        switch source {
        case .availableLocalHistoryUnknown: .requiresConfirmation
        case .provenNeverBound: .useExistingSourceFlow
        case .currentAccount: .useExistingAccountRecovery
        case .foreignAccount, .accountUnknown, .unverifiedRecovery,
             .invalidContent, .unresolvedWatchState: .blocked
        }
    }
}
