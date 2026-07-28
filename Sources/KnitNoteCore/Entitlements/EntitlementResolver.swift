import Foundation

public struct EntitlementResolver: Sendable {
    public init() {}

    public func resolve(
        purchase: PurchaseQualification,
        trial: TrialRecord?,
        now: Date
    ) -> EntitlementSnapshot {
        if let purchased = purchase.entitlementSnapshot {
            return purchased
        }
        guard let trial else { return .trialNotStarted }
        return .trial(startedAt: trial.startedAt, expiresAt: trial.expiresAt)
    }
}
