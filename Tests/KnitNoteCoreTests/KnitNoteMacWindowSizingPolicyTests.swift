import Testing
@testable import KnitNoteCore

@Suite struct KnitNoteMacWindowSizingPolicyTests {
    @Test func approvedDefaultAndMinimumWindowSizesRemainUsable() {
        #expect(KnitNoteMacWindowSizingPolicy.defaultWidth == 1100)
        #expect(KnitNoteMacWindowSizingPolicy.defaultHeight == 760)
        #expect(KnitNoteMacWindowSizingPolicy.minimumWidth == 850)
        #expect(KnitNoteMacWindowSizingPolicy.minimumHeight == 600)
        #expect(
            KnitNoteMacWindowSizingPolicy.defaultWidth
                >= KnitNoteMacWindowSizingPolicy.minimumWidth
        )
        #expect(
            KnitNoteMacWindowSizingPolicy.defaultHeight
                >= KnitNoteMacWindowSizingPolicy.minimumHeight
        )
    }
}
