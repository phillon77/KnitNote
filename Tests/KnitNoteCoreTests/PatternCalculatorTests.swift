import Testing
@testable import KnitNoteCore

@Suite struct PatternCalculatorTests {
    @Test func onlyAnActualPendingOperationReceivesTheSelectionHighlight() {
        #expect(!PatternCalculatorButtonHighlight.isActive(buttonOperation: nil, pendingOperation: nil))
        #expect(!PatternCalculatorButtonHighlight.isActive(buttonOperation: .add, pendingOperation: nil))
        #expect(!PatternCalculatorButtonHighlight.isActive(buttonOperation: nil, pendingOperation: .add))
        #expect(PatternCalculatorButtonHighlight.isActive(buttonOperation: .add, pendingOperation: .add))
        #expect(!PatternCalculatorButtonHighlight.isActive(buttonOperation: .subtract, pendingOperation: .add))
    }

    @Test func addsSubtractsMultipliesAndDividesDecimals() {
        #expect(result(of: [.digit(1), .digit(2), .operation(.add), .digit(3), .equals]) == "15")
        #expect(result(of: [.digit(9), .operation(.subtract), .digit(4), .equals]) == "5")
        #expect(result(of: [.digit(6), .operation(.multiply), .digit(7), .equals]) == "42")
        #expect(result(of: [.digit(7), .decimal, .digit(5), .operation(.divide), .digit(3), .equals]) == "2.5")
    }

    @Test func percentAndSignOperateOnTheDisplayedValue() {
        #expect(result(of: [.digit(2), .digit(5), .percent]) == "0.25")
        #expect(result(of: [.digit(8), .toggleSign]) == "-8")
        #expect(result(of: [.digit(8), .toggleSign, .toggleSign]) == "8")
    }

    @Test func repeatedDecimalAndExcessDigitsAreIgnored() {
        var state = PatternCalculatorState()
        state.press(.digit(1))
        state.press(.decimal)
        state.press(.decimal)
        for _ in 0..<(PatternCalculatorState.maximumEntryDigits + 4) {
            state.press(.digit(2))
        }
        #expect(state.canonicalDisplay == "1." + String(repeating: "2", count: PatternCalculatorState.maximumEntryDigits - 1))
    }

    @Test func theLastConsecutiveOperatorWins() {
        #expect(result(of: [
            .digit(8), .operation(.add), .operation(.multiply), .digit(3), .equals,
        ]) == "24")
    }

    @Test func divideByZeroEntersErrorAndDigitOrClearRecovers() {
        var state = PatternCalculatorState()
        [.digit(8), .operation(.divide), .digit(0), .equals].forEach { state.press($0) }
        #expect(state.display == .error(.invalidResult))

        state.press(.digit(4))
        #expect(state.canonicalDisplay == "4")
        state.press(.clear)
        #expect(state == PatternCalculatorState())
    }

    @Test func clearResetsEveryPendingValue() {
        var state = PatternCalculatorState()
        [.digit(9), .operation(.add), .digit(2), .clear, .digit(3), .equals].forEach { state.press($0) }
        #expect(state == stateAfter([.digit(3), .equals]))
    }

    @Test func preservesLeadingZeroAndZeroDecimalEntry() {
        #expect(result(of: [.digit(0), .digit(0), .digit(7)]) == "7")
        #expect(result(of: [.decimal]) == "0.")
        #expect(result(of: [.decimal, .digit(5)]) == "0.5")
    }

    @Test func normalizesNegativeZero() {
        #expect(result(of: [.toggleSign]) == "0")
        #expect(result(of: [.digit(0), .toggleSign]) == "0")
        #expect(result(of: [.digit(5), .operation(.subtract), .digit(5), .equals, .toggleSign]) == "0")
    }

    @Test func percentAppliesAfterACompletedResult() {
        #expect(result(of: [.digit(1), .digit(0), .operation(.add), .digit(1), .digit(0), .equals, .percent]) == "0.2")
    }

    @Test func percentPreservesAnEnteredRightOperandForPendingArithmetic() {
        #expect(result(of: [
            .digit(5), .digit(0), .operation(.add), .digit(1), .digit(0), .percent, .equals,
        ]) == "50.1")
    }

    @Test func equalsWithoutACompletePendingOperationKeepsTheDisplay() {
        #expect(result(of: [.digit(4), .equals]) == "4")
        #expect(result(of: [.digit(4), .operation(.add), .equals]) == "4")
    }

    @Test func rejectsInvalidDigitsAndNonFiniteOrOverflowResults() {
        var state = PatternCalculatorState()
        state.press(.digit(12))
        state.press(.digit(-1))
        #expect(state.canonicalDisplay == "0")

        let largest = Array(repeating: PatternCalculatorKey.digit(9), count: PatternCalculatorState.maximumEntryDigits)
        largest.forEach { state.press($0) }
        state.press(.operation(.multiply))
        for _ in 0..<20 {
            largest.forEach { state.press($0) }
            state.press(.operation(.multiply))
            if case .error = state.display { break }
        }
        #expect(state.display == .error(.invalidResult))
    }

    @Test func roundsArithmeticToAtMostTwelveFractionDigits() {
        #expect(result(of: [.digit(1), .operation(.divide), .digit(3), .equals]) == "0.333333333333")
    }

    @Test func chainedArithmeticUsesTheDisplayedRoundedResult() {
        #expect(result(of: [
            .digit(1), .operation(.divide), .digit(3), .operation(.multiply), .digit(3), .equals,
        ]) == "0.999999999999")
    }

    @Test func clearRecoversDirectlyFromErrorWhileOtherKeysKeepTheError() {
        var state = stateAfter([.digit(8), .operation(.divide), .digit(0), .equals])
        #expect(state.display == .error(.invalidResult))

        state.press(.decimal)
        #expect(state.display == .error(.invalidResult))

        state.press(.clear)
        #expect(state == PatternCalculatorState())
    }

    private func result(of keys: [PatternCalculatorKey]) -> String {
        stateAfter(keys).canonicalDisplay
    }

    private func stateAfter(_ keys: [PatternCalculatorKey]) -> PatternCalculatorState {
        var state = PatternCalculatorState()
        keys.forEach { state.press($0) }
        return state
    }
}
