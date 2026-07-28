import Foundation

public enum UnlockPresentation {
    public static let expiredMessageKey = "unlock.expired.dataRetained"

    public static func remainingDays(now: Date, expiresAt: Date) -> Int {
        max(
            1,
            Int(ceil(expiresAt.timeIntervalSince(now) / 86_400))
        )
    }

    public static func activeTrialExpiry(
        snapshot: EntitlementSnapshot,
        now: Date
    ) -> Date? {
        guard case let .trialActive(expiresAt) = snapshot.state(at: now) else {
            return nil
        }
        return expiresAt
    }

    public static func shouldDismissUnlock(
        snapshot: EntitlementSnapshot,
        now: Date
    ) -> Bool {
        switch snapshot.state(at: now) {
        case .permanentlyUnlocked, .legacyPaidOwner:
            true
        case .trialNotStarted, .trialActive, .trialExpired:
            false
        }
    }
}
