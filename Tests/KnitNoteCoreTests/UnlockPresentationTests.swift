import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct UnlockPresentationTests {
    @Test func trialPillUsesCalendarSafeRemainingDays() {
        let expiry = Date(timeIntervalSince1970: 200_000)

        #expect(
            UnlockPresentation.remainingDays(
                now: expiry.addingTimeInterval(-86_400),
                expiresAt: expiry
            ) == 1
        )
        #expect(
            UnlockPresentation.remainingDays(
                now: expiry.addingTimeInterval(-1),
                expiresAt: expiry
            ) == 1
        )
    }

    @Test func trialPillRoundsPartialDaysUpAndNeverShowsZero() {
        let expiry = Date(timeIntervalSince1970: 300_000)

        #expect(
            UnlockPresentation.remainingDays(
                now: expiry.addingTimeInterval(-86_401),
                expiresAt: expiry
            ) == 2
        )
        #expect(
            UnlockPresentation.remainingDays(
                now: expiry,
                expiresAt: expiry
            ) == 1
        )
    }

    @Test func expiredCopyPromisesDataRetention() {
        #expect(
            UnlockPresentation.expiredMessageKey
                == "unlock.expired.dataRetained"
        )
    }

    @Test func activeTrialBoundaryEndsExactlyAtExpiry() {
        let expiry = Date(timeIntervalSince1970: 400_000)
        let snapshot = EntitlementSnapshot.trial(
            startedAt: expiry.addingTimeInterval(-1_000),
            expiresAt: expiry
        )

        #expect(
            UnlockPresentation.activeTrialExpiry(
                snapshot: snapshot,
                now: expiry.addingTimeInterval(-0.001)
            ) == expiry
        )
        #expect(
            UnlockPresentation.activeTrialExpiry(
                snapshot: snapshot,
                now: expiry
            ) == nil
        )
    }

    @Test func verifiedQualificationDismissesAnOpenUnlockSheet() {
        let now = Date(timeIntervalSince1970: 500_000)

        #expect(
            UnlockPresentation.shouldDismissUnlock(
                snapshot: .permanentlyUnlocked,
                now: now
            )
        )
        #expect(
            UnlockPresentation.shouldDismissUnlock(
                snapshot: .legacyPaidOwner,
                now: now
            )
        )
        #expect(
            !UnlockPresentation.shouldDismissUnlock(
                snapshot: .trialNotStarted,
                now: now
            )
        )
    }
}
