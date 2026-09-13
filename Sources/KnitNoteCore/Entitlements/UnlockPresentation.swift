import Foundation

/// Presentation only: never starts a trial or changes stored qualifications.
public struct AccessStatusPresentation: Equatable, Sendable {
    public let statusKey: String
    public let canPurchase: Bool
    public let showsVerificationWarning: Bool
    public let expiresAt: Date?
    public let remainingDays: Int?

    public init(snapshot: EntitlementSnapshot?, verificationUnavailable: Bool, now: Date) {
        showsVerificationWarning = verificationUnavailable
        expiresAt = snapshot.flatMap { UnlockPresentation.activeTrialExpiry(snapshot: $0, now: now) }
        remainingDays = expiresAt.map { UnlockPresentation.remainingDays(now: now, expiresAt: $0) }
        guard let snapshot else {
            statusKey = verificationUnavailable ? "access.unavailable" : "access.checking"
            canPurchase = false
            return
        }
        switch snapshot.state(at: now) {
        case .permanentlyUnlocked:
            statusKey = "access.lifetime"
            canPurchase = false
        case .legacyPaidOwner:
            statusKey = "access.legacy"
            canPurchase = false
        case .trialNotStarted:
            statusKey = "access.notStarted"
            canPurchase = !verificationUnavailable
        case .trialActive:
            statusKey = "access.trial"
            canPurchase = !verificationUnavailable
        case .trialExpired:
            statusKey = "access.expired"
            canPurchase = !verificationUnavailable
        }
    }
}

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
