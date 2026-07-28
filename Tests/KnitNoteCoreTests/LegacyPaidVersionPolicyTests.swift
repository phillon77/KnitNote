import Testing
@testable import KnitNoteCore

@Suite struct LegacyPaidVersionPolicyTests {
    @Test(arguments: ["1.0", "1.1.9", "1.2.0", "1.2", "1.2.0.0"])
    func paidVersionsAreGrandfathered(_ version: String) {
        #expect(LegacyPaidVersionPolicy(maximumPaidVersion: "1.2.0").qualifies(originalAppVersion: version))
    }

    @Test(arguments: ["1.2.0.1", "1.2.1", "1.3", "2.0"])
    func freeVersionsAreNotGrandfathered(_ version: String) {
        #expect(!LegacyPaidVersionPolicy(maximumPaidVersion: "1.2.0").qualifies(originalAppVersion: version))
    }

    @Test(arguments: ["", ".", "1.", ".1", "1..2", "1.a", "-1", "1.-2", "+1", " 1.2"])
    func malformedOrNegativeVersionsAreNotGrandfathered(_ version: String) {
        #expect(!LegacyPaidVersionPolicy(maximumPaidVersion: "1.2.0").qualifies(originalAppVersion: version))
    }
}
