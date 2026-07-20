import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct EvenStitchAdjustmentCalculatorTests {
    @Test func evenlyIncreasesWithReservedEdges() throws {
        let result = try EvenStitchAdjustmentCalculator.calculate(
            .init(current: 80, target: 92, reservesEdgeStitches: true)
        )

        #expect(result.operation == .increase)
        #expect(result.adjustmentCount == 12)
        #expect(result.edgeStitches == 1)
        #expect(result.plainSegments == Array(repeating: 6, count: 13))
        #expect(result.steps.first == .edge(1))
        #expect(result.steps.last == .edge(1))
        #expect(result.steps.filter { $0 == .increaseOne }.count == 12)
        #expect(result.steps == [
            .edge(1), .knit(6), .increaseOne, .knit(6), .increaseOne,
            .knit(6), .increaseOne, .knit(6), .increaseOne, .knit(6),
            .increaseOne, .knit(6), .increaseOne, .knit(6), .increaseOne,
            .knit(6), .increaseOne, .knit(6), .increaseOne, .knit(6),
            .increaseOne, .knit(6), .increaseOne, .knit(6), .increaseOne,
            .knit(6), .edge(1)
        ])
        #expect(consumedStitches(in: result.steps) == 80)
        #expect(producedStitches(in: result.steps) == 92)
    }

    @Test func evenlyDecreasesAndConservesStitches() throws {
        let result = try EvenStitchAdjustmentCalculator.calculate(
            .init(current: 80, target: 68, reservesEdgeStitches: true)
        )

        #expect(result.operation == .decrease)
        #expect(result.adjustmentCount == 12)
        #expect(Set(result.plainSegments).isSubset(of: [4, 5]))
        let consumed = result.plainSegments.reduce(0, +) + 24 + 2
        #expect(consumed == 80)
        #expect(result.steps.filter { $0 == .decreaseOne }.count == 12)
        #expect(result.steps == [
            .edge(1), .knit(4), .decreaseOne, .knit(4), .decreaseOne,
            .knit(4), .decreaseOne, .knit(5), .decreaseOne, .knit(4),
            .decreaseOne, .knit(4), .decreaseOne, .knit(4), .decreaseOne,
            .knit(4), .decreaseOne, .knit(4), .decreaseOne, .knit(5),
            .decreaseOne, .knit(4), .decreaseOne, .knit(4), .decreaseOne,
            .knit(4), .edge(1)
        ])
        #expect(consumedStitches(in: result.steps) == 80)
        #expect(producedStitches(in: result.steps) == 68)
    }

    @Test func unchangedAndImpossibleCasesAreExplicit() throws {
        let unchanged = try EvenStitchAdjustmentCalculator.calculate(
            .init(current: 40, target: 40, reservesEdgeStitches: true)
        )
        #expect(unchanged.operation == .unchanged)
        #expect(unchanged.adjustmentCount == 0)
        #expect(unchanged.steps.isEmpty)

        #expect(throws: EvenStitchAdjustmentFailure.requiresMultipleRows) {
            try EvenStitchAdjustmentCalculator.calculate(
                .init(current: 6, target: 12, reservesEdgeStitches: true)
            )
        }
        #expect(throws: EvenStitchAdjustmentFailure.cannotPreserveEdges) {
            try EvenStitchAdjustmentCalculator.calculate(
                .init(current: 4, target: 1, reservesEdgeStitches: true)
            )
        }
    }

    @Test func unchangedSingleStitchCannotReserveBothEdges() {
        #expect(throws: EvenStitchAdjustmentFailure.cannotPreserveEdges) {
            try EvenStitchAdjustmentCalculator.calculate(
                .init(current: 1, target: 1, reservesEdgeStitches: true)
            )
        }
    }

    @Test func unchangedTwoStitchesCanReserveBothEdges() throws {
        let result = try EvenStitchAdjustmentCalculator.calculate(
            .init(current: 2, target: 2, reservesEdgeStitches: true)
        )

        #expect(result.operation == .unchanged)
        #expect(result.edgeStitches == 1)
        #expect(result.plainSegments.isEmpty)
        #expect(result.steps.isEmpty)
    }

    @Test func unchangedSingleStitchIsValidWhenEdgesAreNotReserved() throws {
        let result = try EvenStitchAdjustmentCalculator.calculate(
            .init(current: 1, target: 1, reservesEdgeStitches: false)
        )

        #expect(result.operation == .unchanged)
        #expect(result.edgeStitches == 0)
        #expect(result.plainSegments.isEmpty)
        #expect(result.steps.isEmpty)
    }

    @Test func unevenSegmentsAreBalancedAndSpread() throws {
        let result = try EvenStitchAdjustmentCalculator.calculate(
            .init(current: 21, target: 24, reservesEdgeStitches: true)
        )
        let repeated = try EvenStitchAdjustmentCalculator.calculate(
            .init(current: 21, target: 24, reservesEdgeStitches: true)
        )

        #expect(result.plainSegments == [5, 5, 4, 5])
        #expect(result.plainSegments.max()! - result.plainSegments.min()! <= 1)
        #expect(result.plainSegments.reduce(0, +) == 19)
        #expect(result.plainSegments != result.plainSegments.sorted())
        #expect(result.plainSegments != result.plainSegments.sorted(by: >))
        #expect(repeated == result)
    }

    @Test func nonDivisibleDecreaseBalancesSegmentsAndPreservesOrder() throws {
        let result = try EvenStitchAdjustmentCalculator.calculate(
            .init(current: 23, target: 19, reservesEdgeStitches: true)
        )

        #expect(result.plainSegments == [3, 2, 3, 2, 3])
        #expect(result.steps == [
            .edge(1), .knit(3), .decreaseOne, .knit(2), .decreaseOne,
            .knit(3), .decreaseOne, .knit(2), .decreaseOne, .knit(3), .edge(1)
        ])
        #expect(consumedStitches(in: result.steps) == 23)
        #expect(producedStitches(in: result.steps) == 19)
    }

    @Test func decreaseAllowsZeroLengthPlainSegmentsWithoutKnitZeroSteps() throws {
        let result = try EvenStitchAdjustmentCalculator.calculate(
            .init(current: 4, target: 2, reservesEdgeStitches: false)
        )

        #expect(result.plainSegments == [0, 0, 0])
        #expect(result.steps == [.decreaseOne, .decreaseOne])
        #expect(!result.steps.contains(.knit(0)))
        #expect(consumedStitches(in: result.steps) == 4)
        #expect(producedStitches(in: result.steps) == 2)
    }

    @Test func preservesEdgesFailureBeforeMultipleRowsAndInvalidCounts() {
        #expect(throws: EvenStitchAdjustmentFailure.cannotPreserveEdges) {
            try EvenStitchAdjustmentCalculator.calculate(
                .init(current: 1, target: 100, reservesEdgeStitches: true)
            )
        }
        #expect(throws: EvenStitchAdjustmentFailure.invalidCounts) {
            try EvenStitchAdjustmentCalculator.calculate(
                .init(current: 0, target: 3, reservesEdgeStitches: true)
            )
        }
    }

    @Test func rejectsCountsAboveTheSupportedLimitBeforeArithmetic() throws {
        #expect(EvenStitchAdjustmentCalculator.maximumSupportedStitches == 100_000)
        #expect(throws: EvenStitchAdjustmentFailure.exceedsSupportedLimit) {
            try EvenStitchAdjustmentCalculator.calculate(
                .init(current: .max, target: .max, reservesEdgeStitches: false)
            )
        }
        #expect(throws: EvenStitchAdjustmentFailure.exceedsSupportedLimit) {
            try EvenStitchAdjustmentCalculator.calculate(
                .init(current: 1, target: .max, reservesEdgeStitches: false)
            )
        }
        #expect(throws: EvenStitchAdjustmentFailure.exceedsSupportedLimit) {
            try EvenStitchAdjustmentCalculator.calculate(
                .init(current: .max, target: 1, reservesEdgeStitches: false)
            )
        }
        #expect(throws: EvenStitchAdjustmentFailure.exceedsSupportedLimit) {
            try EvenStitchAdjustmentCalculator.calculate(
                .init(current: 100_001, target: 100_000, reservesEdgeStitches: false)
            )
        }
        #expect(throws: EvenStitchAdjustmentFailure.exceedsSupportedLimit) {
            try EvenStitchAdjustmentCalculator.calculate(
                .init(current: 100_000, target: 100_001, reservesEdgeStitches: false)
            )
        }

        let boundary = try EvenStitchAdjustmentCalculator.calculate(
            .init(current: 100_000, target: 99_999, reservesEdgeStitches: true)
        )
        #expect(boundary.operation == .decrease)
        #expect(consumedStitches(in: boundary.steps) == 100_000)
        #expect(producedStitches(in: boundary.steps) == 99_999)
    }

    @Test func fieldValidationWaitsUntilAGroupStarts() {
        #expect(!EvenStitchAdjustmentCalculator.fieldNeedsValidation(nil, groupStarted: false))
        #expect(!EvenStitchAdjustmentCalculator.fieldNeedsValidation(0, groupStarted: false))
        #expect(EvenStitchAdjustmentCalculator.fieldNeedsValidation(nil, groupStarted: true))
        #expect(EvenStitchAdjustmentCalculator.fieldNeedsValidation(0, groupStarted: true))
        #expect(EvenStitchAdjustmentCalculator.fieldNeedsValidation(-1, groupStarted: true))
        #expect(!EvenStitchAdjustmentCalculator.fieldNeedsValidation(1, groupStarted: true))
    }

    @Test func parserAcceptsBoundedWholeNumbersWithoutFloatingPoint() {
        #expect(
            EvenStitchAdjustmentInputParser.parse("100000", locale: Locale(identifier: "en_US"))
                == .valid(100_000)
        )
        #expect(
            EvenStitchAdjustmentInputParser.parse("100001", locale: Locale(identifier: "en_US"))
                == .exceedsSupportedLimit
        )
        #expect(
            EvenStitchAdjustmentInputParser.parse(
                "999999999999999999999999999999999999999999999999999999",
                locale: Locale(identifier: "en_US")
            ) == .exceedsSupportedLimit
        )
    }

    @Test func parserRejectsFractionsAndTrailingTextExactlyForTheLocale() {
        let english = Locale(identifier: "en_US")
        let german = Locale(identifier: "de_DE")

        #expect(EvenStitchAdjustmentInputParser.parse("1.5", locale: english) == .invalid)
        #expect(
            EvenStitchAdjustmentInputParser.parse("1.00000000000000001", locale: english)
                == .invalid
        )
        #expect(EvenStitchAdjustmentInputParser.parse("1,5", locale: german) == .invalid)
        #expect(EvenStitchAdjustmentInputParser.parse("123trailing", locale: english) == .invalid)
    }

    @Test func parserRejectsUnicodeWholeNumberSymbolsThatAreNotDecimalDigits() {
        let locale = Locale(identifier: "en_US")

        for text in ["Ⅻ", "²", "ↈ", "京"] {
            #expect(EvenStitchAdjustmentInputParser.parse(text, locale: locale) == .invalid)
        }
    }

    @Test func parserClassifiesEmptyZeroAndNegativeInputsAsNonValid() {
        let locale = Locale(identifier: "en_US")

        #expect(EvenStitchAdjustmentInputParser.parse("", locale: locale) == .empty)
        #expect(EvenStitchAdjustmentInputParser.parse("0", locale: locale) == .invalid)
        #expect(EvenStitchAdjustmentInputParser.parse("-1", locale: locale) == .invalid)
    }

    private func consumedStitches(in steps: [EvenStitchStep]) -> Int {
        steps.reduce(into: 0) { total, step in
            switch step {
            case let .edge(count), let .knit(count): total += count
            case .increaseOne: break
            case .decreaseOne: total += 2
            }
        }
    }

    private func producedStitches(in steps: [EvenStitchStep]) -> Int {
        steps.reduce(into: 0) { total, step in
            switch step {
            case let .edge(count), let .knit(count): total += count
            case .increaseOne, .decreaseOne: total += 1
            }
        }
    }
}
