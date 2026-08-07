import Foundation
import Testing
@testable import KnitNoteCore

private let policyNow = Date(timeIntervalSince1970: 1_000)

@Test(arguments: FeatureMutation.allCases.filter {
    $0 != .deleteProject && $0 != .resumeProject
})
func expiredTrialRejectsEveryNonDeletionMutation(_ mutation: FeatureMutation) {
    #expect(FeatureAccessPolicy.decision(
        for: mutation,
        snapshot: .trial(
            startedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 700)
        ),
        now: policyNow
    ) == .requiresUnlock)
}

@Test(arguments: FeatureMutation.allCases)
func activeTrialAllowsEveryMutation(_ mutation: FeatureMutation) {
    #expect(FeatureAccessPolicy.decision(
        for: mutation,
        snapshot: .trial(
            startedAt: Date(timeIntervalSince1970: 900),
            expiresAt: Date(timeIntervalSince1970: 1_100)
        ),
        now: policyNow
    ) == .allow)
}

@Test(arguments: FeatureMutation.allCases)
func permanentUnlockAllowsEveryMutation(_ mutation: FeatureMutation) {
    #expect(FeatureAccessPolicy.decision(
        for: mutation,
        snapshot: .permanentlyUnlocked,
        now: policyNow
    ) == .allow)
}

@Test(arguments: FeatureMutation.allCases)
func legacyPaidOwnerAllowsEveryMutation(_ mutation: FeatureMutation) {
    #expect(FeatureAccessPolicy.decision(
        for: mutation,
        snapshot: .legacyPaidOwner,
        now: policyNow
    ) == .allow)
}

@Test(arguments: FeatureMutation.allCases.filter {
    $0 != .deleteProject
        && $0 != .resumeProject
        && $0 != .restoreBackup
        && $0 != .recordPatternBrowsing
})
func trialNotStartedStartsForEveryUserAuthoredMutation(_ mutation: FeatureMutation) {
    #expect(FeatureAccessPolicy.decision(
        for: mutation,
        snapshot: .trialNotStarted,
        now: policyNow
    ) == .startTrial)
}

@Test(arguments: [
    EntitlementSnapshot.trialNotStarted,
    .trial(
        startedAt: Date(timeIntervalSince1970: 100),
        expiresAt: Date(timeIntervalSince1970: 700)
    ),
])
func projectDeletionNeverRequiresStartingATrialOrPurchasing(
    _ snapshot: EntitlementSnapshot
) {
    #expect(FeatureAccessPolicy.decision(
        for: .deleteProject,
        snapshot: snapshot,
        now: policyNow
    ) == .allow)
}

@Test(arguments: [
    EntitlementSnapshot.trialNotStarted,
    .trial(
        startedAt: Date(timeIntervalSince1970: 100),
        expiresAt: Date(timeIntervalSince1970: 700)
    ),
])
func projectResumeNeverRequiresStartingATrialOrPurchasing(
    _ snapshot: EntitlementSnapshot
) {
    #expect(FeatureAccessPolicy.decision(
        for: .resumeProject,
        snapshot: snapshot,
        now: policyNow
    ) == .allow)
}

@Test func trialNotStartedAllowsBackupRestore() {
    #expect(FeatureAccessPolicy.decision(
        for: .restoreBackup,
        snapshot: .trialNotStarted,
        now: policyNow
    ) == .allow)
}

@Test func trialNotStartedAllowsAutomaticPatternBrowsingHousekeeping() {
    #expect(FeatureAccessPolicy.decision(
        for: .recordPatternBrowsing,
        snapshot: .trialNotStarted,
        now: policyNow
    ) == .allow)
}

@Test(arguments: [FeatureMutation.importPattern, .editJournal])
func exactSevenDayBoundaryRejectsAsyncMutationEntry(_ mutation: FeatureMutation) {
    let trial = TrialRecord(startedAt: Date(timeIntervalSince1970: 40_000))

    #expect(FeatureAccessPolicy.decision(
        for: mutation,
        snapshot: .trial(startedAt: trial.startedAt, expiresAt: trial.expiresAt),
        now: trial.expiresAt
    ) == .requiresUnlock)
}
