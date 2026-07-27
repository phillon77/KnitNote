import Foundation
import Testing
@testable import KnitNoteCore

@Test func activeTrialExpiresAtExactBoundary() {
    let expiry = Date(timeIntervalSince1970: 700)
    let snapshot = EntitlementSnapshot.trial(
        startedAt: Date(timeIntervalSince1970: 100),
        expiresAt: expiry
    )

    #expect(snapshot.state(at: expiry.addingTimeInterval(-0.001)) == .trialActive(expiresAt: expiry))
    #expect(snapshot.state(at: expiry) == .trialExpired)
}

@Test func permanentAndLegacyNeverExpire() {
    #expect(EntitlementSnapshot.permanentlyUnlocked.state(at: .distantFuture) == .permanentlyUnlocked)
    #expect(EntitlementSnapshot.legacyPaidOwner.state(at: .distantFuture) == .legacyPaidOwner)
}
