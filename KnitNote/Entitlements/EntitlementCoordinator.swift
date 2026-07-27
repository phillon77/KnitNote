import Foundation
import SwiftUI

@MainActor
final class EntitlementCoordinator: ObservableObject {
    @Published private(set) var snapshot: EntitlementSnapshot
    @Published private(set) var unlockRequest: FeatureMutation?

    private let purchaseService: (any PurchaseService)?
    private let trialStore: (any TrialStore)?
    private let resolver: EntitlementResolver
    private let now: () -> Date
    private var isPrepared: Bool

    init(
        purchaseService: any PurchaseService,
        trialStore: any TrialStore,
        resolver: EntitlementResolver = EntitlementResolver(),
        now: @escaping () -> Date = Date.init
    ) {
        snapshot = .trialNotStarted
        self.purchaseService = purchaseService
        self.trialStore = trialStore
        self.resolver = resolver
        self.now = now
        isPrepared = false
    }

    private init(
        verifiedSnapshot: EntitlementSnapshot,
        now: @escaping () -> Date = Date.init
    ) {
        snapshot = verifiedSnapshot
        purchaseService = nil
        trialStore = nil
        resolver = EntitlementResolver()
        self.now = now
        isPrepared = true
    }

    static func configured(
        screenshotMode: Bool,
        purchaseServiceFactory: () -> any PurchaseService = {
            StoreKitPurchaseService()
        },
        trialStoreFactory: () -> any TrialStore = {
            KeychainTrialStore()
        }
    ) -> EntitlementCoordinator {
        if screenshotMode {
            return EntitlementCoordinator(verifiedSnapshot: .legacyPaidOwner)
        }
        return EntitlementCoordinator(
            purchaseService: purchaseServiceFactory(),
            trialStore: trialStoreFactory()
        )
    }

    func prepare() async {
        guard let purchaseService, let trialStore else {
            return
        }

        await purchaseService.prepare()
        let purchase = await purchaseService.currentQualification()
        if let verifiedPurchase = purchase.entitlementSnapshot {
            snapshot = verifiedPurchase
            unlockRequest = nil
            isPrepared = true
            return
        }

        do {
            let trial = try trialStore.load()
            snapshot = resolver.resolve(
                purchase: purchase,
                trial: trial,
                now: now()
            )
            unlockRequest = nil
            isPrepared = true
        } catch {
            isPrepared = false
        }
    }

    func authorize(_ mutation: FeatureMutation) -> FeatureAccessDecision {
        guard isPrepared else {
            unlockRequest = mutation
            return .requiresUnlock
        }

        let decision = FeatureAccessPolicy.decision(
            for: mutation,
            snapshot: snapshot,
            now: now()
        )
        switch decision {
        case .allow:
            return .allow
        case .requiresUnlock:
            unlockRequest = mutation
            return .requiresUnlock
        case .startTrial:
            return startTrial(for: mutation)
        }
    }

    private func startTrial(for mutation: FeatureMutation) -> FeatureAccessDecision {
        guard let trialStore else {
            unlockRequest = mutation
            return .requiresUnlock
        }
        do {
            let trial = try trialStore.startIfNeeded(now: now())
            snapshot = .trial(
                startedAt: trial.startedAt,
                expiresAt: trial.expiresAt
            )
            unlockRequest = nil
            return .allow
        } catch {
            unlockRequest = mutation
            return .requiresUnlock
        }
    }
}
