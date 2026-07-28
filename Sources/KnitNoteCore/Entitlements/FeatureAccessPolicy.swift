import Foundation

public enum FeatureMutation: String, CaseIterable, Codable, Sendable {
    case createProject
    case editProject
    case deleteProject
    case completeProject
    case resumeProject
    case changeCounter
    case editNote
    case editJournal
    case importPattern
    case editPattern
    case linkPattern
    case recordPatternBrowsing
    case editPatternReadingState
    case createYarn
    case editYarn
    case deleteYarn
    case linkYarn
    case scanYarnLabel
    case restoreBackup
}

public enum FeatureAccessDecision: Equatable, Sendable {
    case allow
    case startTrial
    case requiresUnlock
}

public enum FeatureAccessPolicy {
    public static func decision(
        for mutation: FeatureMutation,
        snapshot: EntitlementSnapshot,
        now: Date
    ) -> FeatureAccessDecision {
        switch snapshot.state(at: now) {
        case .trialNotStarted:
            mutation == .restoreBackup || mutation == .recordPatternBrowsing
                ? .allow
                : .startTrial
        case .trialActive, .permanentlyUnlocked, .legacyPaidOwner:
            .allow
        case .trialExpired:
            .requiresUnlock
        }
    }
}
