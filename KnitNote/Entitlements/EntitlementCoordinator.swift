import Foundation
import SwiftUI

@MainActor
final class EntitlementCoordinator: ObservableObject {
    private enum PreparationResult: Sendable {
        case prepared(EntitlementSnapshot)
        case unavailable
        case failed
    }

    private struct PreparationFlight {
        let id: UUID
        let generation: UInt64
        let task: Task<PreparationResult, Never>
    }

    @Published private(set) var snapshot: EntitlementSnapshot
    @Published private(set) var unlockRequest: FeatureMutation?

    var localizedLifetimePrice: String? {
        purchaseService?.localizedLifetimePrice
    }

    var verifiedSnapshot: EntitlementSnapshot? {
        isPrepared ? snapshot : nil
    }

    var allowsWrites: Bool {
        guard isPrepared else { return false }
        switch snapshot.state(at: now()) {
        case .trialExpired:
            return false
        case .trialNotStarted, .trialActive, .permanentlyUnlocked, .legacyPaidOwner:
            return true
        }
    }

    var allowsAutomaticReaderPersistence: Bool {
        guard isPrepared else { return false }
        switch snapshot.state(at: now()) {
        case .trialExpired:
            return false
        case .trialNotStarted, .trialActive, .permanentlyUnlocked, .legacyPaidOwner:
            return true
        }
    }

    private let purchaseService: (any PurchaseService)?
    private let trialStore: (any TrialStore)?
    private let resolver: EntitlementResolver
    private let now: () -> Date
    private let onSnapshotChange: (EntitlementSnapshot, Date) -> Void
    private var isPrepared: Bool
    private var preparationGeneration: UInt64 = 0
    private var preparationFlight: PreparationFlight?
    private var entitlementUpdatesTask: Task<Void, Never>?

    init(
        purchaseService: any PurchaseService,
        trialStore: any TrialStore,
        resolver: EntitlementResolver = EntitlementResolver(),
        now: @escaping () -> Date = Date.init,
        onSnapshotChange: @escaping (EntitlementSnapshot, Date) -> Void = { _, _ in }
    ) {
        snapshot = .trialNotStarted
        self.purchaseService = purchaseService
        self.trialStore = trialStore
        self.resolver = resolver
        self.now = now
        self.onSnapshotChange = onSnapshotChange
        isPrepared = false
        entitlementUpdatesTask = nil
        let updates = purchaseService.entitlementUpdates
        entitlementUpdatesTask = Task { [weak self] in
            for await _ in updates {
                guard !Task.isCancelled else { return }
                await self?.refreshEntitlement()
            }
        }
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
        onSnapshotChange = { _, _ in }
        isPrepared = true
        entitlementUpdatesTask = nil
    }

    deinit {
        entitlementUpdatesTask?.cancel()
    }

    static func configured(
        screenshotMode: Bool,
        purchaseServiceFactory: () -> any PurchaseService = {
            StoreKitPurchaseService()
        },
        trialStoreFactory: () -> any TrialStore = {
            KeychainTrialStore()
        },
        onSnapshotChange: @escaping (EntitlementSnapshot, Date) -> Void = { _, _ in }
    ) -> EntitlementCoordinator {
        if screenshotMode {
            return EntitlementCoordinator(verifiedSnapshot: .legacyPaidOwner)
        }
        return EntitlementCoordinator(
            purchaseService: purchaseServiceFactory(),
            trialStore: trialStoreFactory(),
            onSnapshotChange: onSnapshotChange
        )
    }

    func prepare() async {
        guard let purchaseService, let trialStore else {
            return
        }

        let flight: PreparationFlight
        if let existing = preparationFlight {
            flight = existing
        } else {
            let newFlight = PreparationFlight(
                id: UUID(),
                generation: preparationGeneration,
                task: Task { @MainActor [resolver, now] in
                    await purchaseService.prepare()
                    let purchase = await purchaseService.currentQualification()
                    if let verifiedPurchase = purchase.entitlementSnapshot {
                        return .prepared(verifiedPurchase)
                    }
                    if purchase == .unavailable {
                        return .unavailable
                    }

                    do {
                        let trial = try trialStore.load()
                        return .prepared(resolver.resolve(
                            purchase: purchase,
                            trial: trial,
                            now: now()
                        ))
                    } catch {
                        return .failed
                    }
                }
            )
            preparationFlight = newFlight
            flight = newFlight
        }

        await finishPreparation(flight)
    }

    func ensurePrepared() async -> Bool {
        if isPrepared {
            return true
        }
        await prepare()
        return isPrepared
    }

    func refreshEntitlement() async {
        let generation = preparationGeneration
        if let existing = preparationFlight {
            await finishPreparation(existing)
        }
        guard preparationGeneration == generation else { return }
        await prepare()
    }

    private func finishPreparation(_ flight: PreparationFlight) async {
        let result = await flight.task.value
        guard preparationGeneration == flight.generation,
              preparationFlight?.id == flight.id else {
            return
        }
        preparationFlight = nil

        switch result {
        case let .prepared(preparedSnapshot):
            publishSnapshot(preparedSnapshot)
        case .unavailable:
            if !isPrepared
                || (snapshot != .permanentlyUnlocked && snapshot != .legacyPaidOwner) {
                isPrepared = false
            }
        case .failed:
            isPrepared = false
        }
    }

    func purchaseLifetime() async throws -> PurchaseOutcome {
        guard let purchaseService else {
            throw PurchaseServiceError.lifetimeProductUnavailable
        }

        let outcome = try await purchaseService.purchaseLifetime()
        if outcome == .purchased {
            await refreshEntitlement()
        }
        return outcome
    }

    func restorePurchases() async throws -> PurchaseQualification {
        guard let purchaseService else {
            return .legacyPaidOwner
        }

        let qualification = try await purchaseService.restore()
        invalidatePreparationFlights()
        try applyRestoredQualification(qualification)
        return qualification
    }

    private func applyRestoredQualification(
        _ qualification: PurchaseQualification
    ) throws {
        if let restoredSnapshot = qualification.entitlementSnapshot {
            publishSnapshot(restoredSnapshot)
            return
        }

        switch qualification {
        case .none:
            guard let trialStore else {
                isPrepared = false
                return
            }
            do {
                let trial = try trialStore.load()
                publishSnapshot(resolver.resolve(
                    purchase: .none,
                    trial: trial,
                    now: now()
                ))
            } catch {
                isPrepared = false
                throw error
            }
        case .unavailable:
            if !isPrepared
                || (snapshot != .permanentlyUnlocked && snapshot != .legacyPaidOwner) {
                isPrepared = false
            }
        case .lifetime, .legacyPaidOwner:
            preconditionFailure("Handled by entitlementSnapshot")
        }
    }

    func dismissUnlock() {
        unlockRequest = nil
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
            return .startTrial
        }
    }

    func commitSuccessfulMutation(_ mutation: FeatureMutation) -> FeatureAccessDecision {
        guard isPrepared else {
            unlockRequest = mutation
            return .requiresUnlock
        }

        switch FeatureAccessPolicy.decision(
            for: mutation,
            snapshot: snapshot,
            now: now()
        ) {
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
        invalidatePreparationFlights()
        do {
            let trial = try trialStore.startIfNeeded(now: now())
            publishSnapshot(.trial(
                startedAt: trial.startedAt,
                expiresAt: trial.expiresAt
            ))
            return .allow
        } catch {
            isPrepared = false
            unlockRequest = mutation
            return .requiresUnlock
        }
    }

    private func invalidatePreparationFlights() {
        preparationGeneration &+= 1
        preparationFlight = nil
    }

    private func publishSnapshot(_ newSnapshot: EntitlementSnapshot) {
        let generatedAt = now()
        isPrepared = true
        snapshot = newSnapshot
        unlockRequest = nil
        onSnapshotChange(newSnapshot, generatedAt)
    }
}
