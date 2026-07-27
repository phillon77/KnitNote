import Foundation

@MainActor
protocol PurchaseService: AnyObject {
    var localizedLifetimePrice: String? { get }
    func prepare() async
    func currentQualification() async -> PurchaseQualification
    func purchaseLifetime() async throws -> PurchaseOutcome
    func restore() async throws -> PurchaseQualification
}

enum PurchaseServiceError: Error, Equatable {
    case lifetimeProductUnavailable
    case unverifiedLifetimeTransaction
}
