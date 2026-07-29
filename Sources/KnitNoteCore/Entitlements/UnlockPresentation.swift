import Foundation

public enum UnlockRestorePresentation: Equatable, Sendable {
    case close
    case restoreNotFound
    case retry
}

public struct UnlockPresentationOrchestrator: Equatable, Sendable {
    public private(set) var isCreateProjectSheetPresented = false
    private var isExplicitlyRequested = false

    public init() {}

    public mutating func createProjectSheetDidPresent() {
        isCreateProjectSheetPresented = true
    }

    public mutating func createProjectSheetDidDismiss() {
        isCreateProjectSheetPresented = false
    }

    public mutating func receiveCoordinatorRequest(
        _ request: FeatureMutation?
    ) {
        guard shouldPresentImmediately(request) else { return }
        isExplicitlyRequested = true
    }

    public mutating func requestExplicitly() {
        isExplicitlyRequested = true
    }

    public mutating func dismiss() {
        isExplicitlyRequested = false
    }

    public func isPresented(
        coordinatorRequest: FeatureMutation?
    ) -> Bool {
        isExplicitlyRequested
            || shouldPresentImmediately(coordinatorRequest)
    }

    private func shouldPresentImmediately(
        _ request: FeatureMutation?
    ) -> Bool {
        guard let request else { return false }
        return request != .createProject
            || !isCreateProjectSheetPresented
    }
}

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

    public static func restorePresentation(
        for qualification: PurchaseQualification
    ) -> UnlockRestorePresentation {
        switch qualification {
        case .none:
            .restoreNotFound
        case .unavailable:
            .retry
        case .lifetime, .legacyPaidOwner:
            .close
        }
    }
}
