import Foundation

public enum EntitlementState: Equatable, Sendable {
    case trialNotStarted
    case trialActive(expiresAt: Date)
    case trialExpired
    case permanentlyUnlocked
    case legacyPaidOwner
}

public enum EntitlementSnapshot: Equatable, Codable, Sendable {
    case trialNotStarted
    case trial(startedAt: Date, expiresAt: Date)
    case permanentlyUnlocked
    case legacyPaidOwner

    public func state(at now: Date) -> EntitlementState {
        switch self {
        case .trialNotStarted:
            .trialNotStarted
        case let .trial(_, expiresAt):
            now < expiresAt ? .trialActive(expiresAt: expiresAt) : .trialExpired
        case .permanentlyUnlocked:
            .permanentlyUnlocked
        case .legacyPaidOwner:
            .legacyPaidOwner
        }
    }
}
