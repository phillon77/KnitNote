import Foundation
import Testing
@testable import ShortRowKit

struct ShortRowCalculatorTests {
    @Test func sixRowShoulderNeverTurnsAtZeroStitches() throws {
        let plan = try ShortRowCalculator.calculate(stitches: 24, rowsPer10cm: 30, heightCM: 2)
        #expect(plan.shapingRows == 6)
        #expect(plan.actualHeightCM == 2)
        #expect(plan.segments == [6, 6, 6, 6])
        #expect(plan.pairs.map(\.workedStitches) == [18, 12, 6])
        #expect(plan.pairs.map(\.unworkedStitches) == [6, 12, 18])
        // Independently simulate the stated out-and-back rows, indexed from neck edge.
        var heights = Array(repeating: 0, count: 24)
        for pair in plan.pairs {
            for stitch in 0..<pair.workedStitches { heights[stitch] += 2 }
        }
        #expect(heights == Array(repeating: 6, count: 6) + Array(repeating: 4, count: 6)
            + Array(repeating: 2, count: 6) + Array(repeating: 0, count: 6))
    }

    @Test func remainderKeepsEverySegmentAndTurnUsable() throws {
        let plan = try ShortRowCalculator.calculate(stitches: 25, rowsPer10cm: 30, heightCM: 2)
        #expect(plan.segments.reduce(0, +) == 25)
        #expect(plan.segments.sorted() == [6, 6, 6, 7])
        #expect(plan.pairs.count == 3)
        #expect(plan.pairs.allSatisfy { $0.workedStitches > 0 && $0.unworkedStitches > 0 })
    }

    @Test func roundsToNearestPairAndReportsActualHeight() throws {
        let tie = try ShortRowCalculator.calculate(stitches: 24, rowsPer10cm: 25, heightCM: 2)
        #expect(tie.shapingRows == 6)
        #expect(abs(tie.actualHeightCM - 2.4) < 0.000001)
        let down = try ShortRowCalculator.calculate(stitches: 24, rowsPer10cm: 24, heightCM: 2)
        #expect(down.shapingRows == 4)
        #expect(abs(down.actualHeightCM - 5.0 / 3.0) < 0.000001)
    }

    @Test func insufficientWidthAndTinyHeightHaveSpecificFailures() {
        #expect(throws: ShortRowFailure.insufficientStitches) {
            try ShortRowCalculator.calculate(stitches: 3, rowsPer10cm: 30, heightCM: 2)
        }
        #expect(throws: ShortRowFailure.heightTooSmall) {
            try ShortRowCalculator.calculate(stitches: 24, rowsPer10cm: 30, heightCM: 0.1)
        }
        #expect(throws: ShortRowFailure.tooManyRows) {
            try ShortRowCalculator.calculate(stitches: 1000, rowsPer10cm: 1000, heightCM: 100)
        }
    }

    @Test func rejectsNonfiniteNonpositiveAndUnsafeValues() {
        for value in [0.0, -1, .nan, .infinity, -.infinity] {
            #expect(throws: ShortRowFailure.invalidInput) {
                try ShortRowCalculator.calculate(stitches: 24, rowsPer10cm: value, heightCM: 2)
            }
            #expect(throws: ShortRowFailure.invalidInput) {
                try ShortRowCalculator.calculate(stitches: 24, rowsPer10cm: 30, heightCM: value)
            }
        }
        for stitches in [0, -1, 10_001, Int.max] {
            #expect(throws: ShortRowFailure.invalidInput) {
                try ShortRowCalculator.calculate(stitches: stitches, rowsPer10cm: 30, heightCM: 2)
            }
        }
    }

    @Test func smallestAndLargestSupportedSchedules() throws {
        let small = try ShortRowCalculator.calculate(stitches: 2, rowsPer10cm: 20, heightCM: 1)
        #expect(small.pairs.map(\.workedStitches) == [1])
        let large = try ShortRowCalculator.calculate(stitches: 10_000, rowsPer10cm: 100, heightCM: 20)
        #expect(large.shapingRows == 200)
        #expect(large.segments.reduce(0, +) == 10_000)
        #expect(large.pairs.count == 100)
        #expect(large.pairs.last!.workedStitches > 0)
    }

    @Test func strictLocalizedInputRejectsPartialAndGroupedNumbers() {
        #expect(ShortRowInput.decimal(" 2.5 ", locale: Locale(identifier: "en")) == 2.5)
        #expect(ShortRowInput.decimal("2,5", locale: Locale(identifier: "fr")) == 2.5)
        #expect(ShortRowInput.decimal("２.５", locale: Locale(identifier: "zh-Hant")) == 2.5)
        for text in ["", "2abc", "1,000", "2..5", "NaN", "∞", "1e5", "-2", "½", "²"] {
            #expect(ShortRowInput.decimal(text, locale: Locale(identifier: "en")) == nil)
        }
        #expect(ShortRowInput.stitches("24") == 24)
        #expect(ShortRowInput.stitches("２４") == 24)
        for text in ["2.5", "24.0", "0", "-2", "10001", String(repeating: "9", count: 1000)] {
            #expect(ShortRowInput.stitches(text) == nil)
        }
    }
}
