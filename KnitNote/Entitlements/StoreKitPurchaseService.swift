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

@MainActor
final class StoreKitPurchaseService: PurchaseService {
    static let lifetimeProductIdentifier = "com.phillon.KnitNote.lifetimeUnlock"
    private static let legacyPaidMaximumVersion = "1.2.0"

    let entitlementUpdates: AsyncStream<Void>
    private(set) var localizedLifetimePrice: String?
    private var lifetimeProduct: Product?
    private var transactionUpdatesTask: Task<Void, Never>?
    private let entitlementUpdatesContinuation: AsyncStream<Void>.Continuation

    init(transactionUpdateListener: TransactionUpdateListener = .storeKit) {
        let updates = AsyncStream<Void>.makeStream()
        entitlementUpdates = updates.stream
        entitlementUpdatesContinuation = updates.continuation
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
        if await hasVerifiedLifetimeEntitlement() {
            return .lifetime
        }
        return await legacyPaidQualification()
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

    private func hasVerifiedLifetimeEntitlement() async -> Bool {
        for await verification in Transaction.currentEntitlements {
            guard case let .verified(transaction) = verification,
                  transaction.productID == Self.lifetimeProductIdentifier,
                  transaction.productType == .nonConsumable
            else { continue }
            return true
        }
        return false
    }

    private func legacyPaidQualification() async -> PurchaseQualification {
        guard let verification = try? await AppTransaction.shared,
              case let .verified(appTransaction) = verification,
              LegacyPaidVersionPolicy(
                maximumPaidVersion: Self.legacyPaidMaximumVersion
              ).qualifies(originalAppVersion: appTransaction.originalAppVersion)
        else { return .none }
        return .legacyPaidOwner
    }

}
