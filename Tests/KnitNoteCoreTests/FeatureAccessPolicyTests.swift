import Foundation
import Testing
@testable import KnitNoteCore

private let policyNow = Date(timeIntervalSince1970: 1_000)

@Test(arguments: FeatureMutation.allCases)
func expiredTrialRejectsEveryMutation(_ mutation: FeatureMutation) {
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

@Test func firstMeaningfulActionsStartTrial() {
    #expect(FeatureAccessPolicy.decision(
        for: .createProject,
        snapshot: .trialNotStarted,
        now: policyNow
    ) == .startTrial)
    #expect(FeatureAccessPolicy.decision(
        for: .importPattern,
        snapshot: .trialNotStarted,
        now: policyNow
    ) == .startTrial)
}

@Test(arguments: FeatureMutation.allCases.filter {
    $0 != .createProject && $0 != .importPattern
})
func otherMutationsDoNotStartTrial(_ mutation: FeatureMutation) {
    #expect(FeatureAccessPolicy.decision(
        for: mutation,
        snapshot: .trialNotStarted,
        now: policyNow
    ) == .allow)
}
