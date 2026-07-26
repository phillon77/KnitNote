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

    @Test func disabledCountersUseAReadOnlyHintInsteadOfMutationInstructions() {
        #expect(PatternReaderCounterAccessibilityPolicy.accessibilityHintKey(isEnabled: true) == "counter.accessibility.tapHoldHint")
        #expect(PatternReaderCounterAccessibilityPolicy.accessibilityHintKey(isEnabled: false) == "counter.accessibility.readOnlyHint")
    }
}
