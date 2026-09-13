import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct AccessStatusPresentationTests {
    private let now = Date(timeIntervalSince1970: 100_000)

    @Test func unverifiedStateNeverOffersPurchase() {
        let value = AccessStatusPresentation(snapshot: nil, verificationUnavailable: false, now: now)
        #expect(value.statusKey == "access.checking")
        #expect(!value.canPurchase)
    }

    @Test func offlineDoesNotEraseCachedPermanentQualification() {
        for snapshot in [EntitlementSnapshot.permanentlyUnlocked, .legacyPaidOwner] {
            let value = AccessStatusPresentation(snapshot: snapshot, verificationUnavailable: true, now: now)
            #expect(!value.canPurchase)
            #expect(value.showsVerificationWarning)
            #expect(value.statusKey == (snapshot == .permanentlyUnlocked ? "access.lifetime" : "access.legacy"))
        }
    }

    @Test func unavailableWithoutQualificationDoesNotClaimTrial() {
        let value = AccessStatusPresentation(snapshot: nil, verificationUnavailable: true, now: now)
        #expect(value.statusKey == "access.unavailable")
        #expect(!value.canPurchase)
    }

    @Test func offlineTrialSnapshotCannotOfferPotentialDuplicatePurchase() {
        for snapshot in [EntitlementSnapshot.trialNotStarted,
                         .trial(startedAt: now.addingTimeInterval(-100), expiresAt: now.addingTimeInterval(100)),
                         .trial(startedAt: now.addingTimeInterval(-100), expiresAt: now)] {
            let value = AccessStatusPresentation(snapshot: snapshot, verificationUnavailable: true, now: now)
            #expect(!value.canPurchase)
            #expect(value.showsVerificationWarning)
        }
    }

    @Test func trialExpiresAtExactBoundary() {
        let snapshot = EntitlementSnapshot.trial(startedAt: now.addingTimeInterval(-100), expiresAt: now)
        let active = AccessStatusPresentation(snapshot: snapshot, verificationUnavailable: false, now: now.addingTimeInterval(-1))
        #expect(active.statusKey == "access.trial")
        #expect(active.remainingDays == 1)
        #expect(active.expiresAt == now)
        #expect(active.canPurchase)
        let expired = AccessStatusPresentation(snapshot: snapshot, verificationUnavailable: false, now: now)
        #expect(expired.statusKey == "access.expired")
        #expect(expired.remainingDays == nil)
        #expect(expired.canPurchase)
    }

    @Test func unstartedTrialIsNotStartedByPresentation() {
        let value = AccessStatusPresentation(snapshot: .trialNotStarted, verificationUnavailable: false, now: now)
        #expect(value.statusKey == "access.notStarted")
        #expect(value.expiresAt == nil)
        #expect(value.canPurchase)
    }
}
