import Foundation
import Testing
@testable import KnitNoteCore

@Test func lifetimePurchaseWinsOverAnExpiredTrial() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let expired = TrialRecord(startedAt: now.addingTimeInterval(-TrialRecord.duration - 1))

    #expect(
        EntitlementResolver().resolve(
            purchase: .lifetime,
            trial: expired,
            now: now
        ) == .permanentlyUnlocked
    )
}

@Test func existingExpiredTrialRemainsExpiredWhenThereIsNoPurchase() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let expired = TrialRecord(startedAt: now.addingTimeInterval(-TrialRecord.duration - 1))
    let snapshot = EntitlementResolver().resolve(
        purchase: .none,
        trial: expired,
        now: now
    )

    #expect(snapshot.state(at: now) == .trialExpired)
    #expect(
        FeatureAccessPolicy.decision(
            for: .restoreBackup,
            snapshot: snapshot,
            now: now
        ) == .requiresUnlock
    )
}

@Test func noPurchaseAndNoTrialResolvesToNotStarted() {
    #expect(
        EntitlementResolver().resolve(
            purchase: .none,
            trial: nil,
            now: Date(timeIntervalSince1970: 2_000_000)
        ) == .trialNotStarted
    )
}
