import StoreKit

struct TransactionUpdateListener: Sendable {
    let consume: @Sendable (
        @escaping @Sendable () async -> Void
    ) async -> Void

    static let storeKit = TransactionUpdateListener { onVerifiedTransaction in
        for await verification in Transaction.updates {
            guard case let .verified(transaction) = verification else { continue }
            await transaction.finish()
            await onVerifiedTransaction()
        }
    }
}

struct StoreKitEntitlementSource {
    enum LifetimeQualification {
        case none
        case entitled
        case unavailable
    }

    let lifetimeQualification: () async -> LifetimeQualification
    let legacyQualification: () async -> PurchaseQualification
}

@MainActor
final class StoreKitPurchaseService: PurchaseService {
    static let lifetimeProductIdentifier = "com.phillon.KnitNote.lifetimeUnlock"
    private static let legacyPaidMaximumVersion = "1.2.0"

    let entitlementUpdates: AsyncStream<Void>
    private(set) var localizedLifetimePrice: String?
    private var lifetimeProduct: Product?
    private var transactionUpdatesTask: Task<Void, Never>?
    private let entitlementUpdatesContinuation: AsyncStream<Void>.Continuation
    private let entitlementSource: StoreKitEntitlementSource

    init(
        transactionUpdateListener: TransactionUpdateListener = .storeKit,
        entitlementSource: StoreKitEntitlementSource? = nil
    ) {
        let updates = AsyncStream<Void>.makeStream()
        entitlementUpdates = updates.stream
        entitlementUpdatesContinuation = updates.continuation
        self.entitlementSource = entitlementSource ?? .init(
            lifetimeQualification: Self.lifetimeEntitlementQualification,
            legacyQualification: Self.legacyPaidQualification
        )
        transactionUpdatesTask = Task {
            await transactionUpdateListener.consume {
                updates.continuation.yield()
            }
        }
    }

    deinit {
        transactionUpdatesTask?.cancel()
        entitlementUpdatesContinuation.finish()
    }

    func prepare() async {
        do {
            let products = try await Product.products(for: [Self.lifetimeProductIdentifier])
            lifetimeProduct = products.first(where: { $0.id == Self.lifetimeProductIdentifier })
            localizedLifetimePrice = lifetimeProduct?.displayPrice
        } catch {
            lifetimeProduct = nil
            localizedLifetimePrice = nil
        }
    }

    func currentQualification() async -> PurchaseQualification {
        switch await entitlementSource.lifetimeQualification() {
        case .entitled:
            return .lifetime
        case .unavailable:
            return .unavailable
        case .none:
            return await entitlementSource.legacyQualification()
        }
    }

    func purchaseLifetime() async throws -> PurchaseOutcome {
        if lifetimeProduct == nil {
            await prepare()
        }
        guard let lifetimeProduct else {
            throw PurchaseServiceError.lifetimeProductUnavailable
        }

        switch try await lifetimeProduct.purchase() {
        case let .success(verification):
            guard case let .verified(transaction) = verification,
                  transaction.productID == Self.lifetimeProductIdentifier,
                  transaction.productType == .nonConsumable
            else {
                throw PurchaseServiceError.unverifiedLifetimeTransaction
            }
            await transaction.finish()
            return .purchased
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    func restore() async throws -> PurchaseQualification {
        try await AppStore.sync()
        return await currentQualification()
    }

    private static func lifetimeEntitlementQualification() async
        -> StoreKitEntitlementSource.LifetimeQualification {
        for await verification in Transaction.currentEntitlements {
            switch verification {
            case let .verified(transaction)
                where transaction.productID == Self.lifetimeProductIdentifier
                    && transaction.productType == .nonConsumable:
                return .entitled
            case let .unverified(transaction, _)
                where transaction.productID == Self.lifetimeProductIdentifier
                    && transaction.productType == .nonConsumable:
                return .unavailable
            default:
                continue
            }
        }
        return .none
    }

    private static func legacyPaidQualification() async -> PurchaseQualification {
        do {
            let verification = try await AppTransaction.shared
            guard case let .verified(appTransaction) = verification else {
                return .unavailable
            }
            return LegacyPaidVersionPolicy(
                maximumPaidVersion: Self.legacyPaidMaximumVersion
            ).qualifies(originalAppVersion: appTransaction.originalAppVersion)
                ? .legacyPaidOwner
                : .none
        } catch {
            return .unavailable
        }
    }

}
