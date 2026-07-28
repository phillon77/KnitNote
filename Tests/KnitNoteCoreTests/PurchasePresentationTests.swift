import Testing
@testable import KnitNoteCore

@Suite struct PurchasePresentationTests {
    @Test func qualificationProjectsVerifiedLifetimeAndLegacyOwnershipIntoEntitlements() {
        #expect(PurchaseQualification.none.entitlementSnapshot == nil)
        #expect(PurchaseQualification.lifetime.entitlementSnapshot == .permanentlyUnlocked)
        #expect(PurchaseQualification.legacyPaidOwner.entitlementSnapshot == .legacyPaidOwner)
    }
}
