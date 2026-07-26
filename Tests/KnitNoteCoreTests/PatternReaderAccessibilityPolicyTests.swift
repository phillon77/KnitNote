import Testing
@testable import KnitNoteCore

@Suite struct PatternReaderAccessibilityPolicyTests {
    @Test func activeCountersExposeBothCustomVoiceOverActions() {
        #expect(PatternReaderCounterAccessibilityPolicy.canExposeIncrementAction(isEnabled: true))
        #expect(PatternReaderCounterAccessibilityPolicy.canExposeManageAction(isEnabled: true))
    }

    @Test func disabledCountersExposeNoCustomVoiceOverActions() {
        #expect(!PatternReaderCounterAccessibilityPolicy.canExposeIncrementAction(isEnabled: false))
        #expect(!PatternReaderCounterAccessibilityPolicy.canExposeManageAction(isEnabled: false))
    }
}
