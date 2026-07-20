import Testing
@testable import KnitNoteCore

@Suite struct RowIntervalAdjustmentCalculatorTests {
    @Test func schedulesTenSingleSideDecreasesAcrossTwentyRows() throws {
        let result = try RowIntervalAdjustmentCalculator.calculate(.init(
            totalRows: 20,
            totalStitches: 10,
            operation: .decrease,
            style: .singleSide
        ))
        #expect(result.eventCount == 10)
        #expect(result.stitchesPerEvent == 1)
        #expect(result.adjustmentRows == [2, 4, 6, 8, 10, 12, 14, 16, 18, 20])
        #expect(result.minimumInterval == 2)
        #expect(result.maximumInterval == 2)
    }

    @Test func schedulesTenSymmetricDecreasesAcrossTwentyRows() throws {
        let result = try RowIntervalAdjustmentCalculator.calculate(.init(
            totalRows: 20,
            totalStitches: 10,
            operation: .decrease,
            style: .bothSides
        ))
        #expect(result.eventCount == 5)
        #expect(result.stitchesPerEvent == 2)
        #expect(result.adjustmentRows == [4, 8, 12, 16, 20])
    }

    @Test func spreadsRemaindersAndEndsOnTheFinalRow() throws {
        let result = try RowIntervalAdjustmentCalculator.calculate(.init(
            totalRows: 20, totalStitches: 6, operation: .increase, style: .singleSide
        ))
        #expect(result.adjustmentRows == [4, 7, 10, 14, 17, 20])
        #expect(result.minimumInterval == 3)
        #expect(result.maximumInterval == 4)
        #expect(result.adjustmentRows.last == 20)
    }

    @Test func increaseAndDecreaseShareOnlyTheSchedule() throws {
        let increase = try RowIntervalAdjustmentCalculator.calculate(.init(
            totalRows: 13, totalStitches: 4, operation: .increase, style: .singleSide
        ))
        let decrease = try RowIntervalAdjustmentCalculator.calculate(.init(
            totalRows: 13, totalStitches: 4, operation: .decrease, style: .singleSide
        ))
        #expect(increase.adjustmentRows == decrease.adjustmentRows)
        #expect(increase.operation == .increase)
        #expect(decrease.operation == .decrease)
    }

    @Test func rejectsInvalidUnsafeOddAndOvercrowdedInputs() {
        #expect(throws: RowIntervalAdjustmentFailure.invalidCounts) {
            try RowIntervalAdjustmentCalculator.calculate(.init(
                totalRows: 0, totalStitches: 1, operation: .decrease, style: .singleSide
            ))
        }
        #expect(throws: RowIntervalAdjustmentFailure.invalidCounts) {
            try RowIntervalAdjustmentCalculator.calculate(.init(
                totalRows: 1, totalStitches: 0, operation: .decrease, style: .singleSide
            ))
        }
        #expect(throws: RowIntervalAdjustmentFailure.invalidCounts) {
            try RowIntervalAdjustmentCalculator.calculate(.init(
                totalRows: -1, totalStitches: 1, operation: .decrease, style: .singleSide
            ))
        }
        #expect(throws: RowIntervalAdjustmentFailure.exceedsSupportedLimit) {
            try RowIntervalAdjustmentCalculator.calculate(.init(
                totalRows: .max, totalStitches: .max, operation: .decrease, style: .singleSide
            ))
        }
        #expect(throws: RowIntervalAdjustmentFailure.symmetricRequiresEvenStitches) {
            try RowIntervalAdjustmentCalculator.calculate(.init(
                totalRows: 20, totalStitches: 9, operation: .decrease, style: .bothSides
            ))
        }
        #expect(throws: RowIntervalAdjustmentFailure.insufficientRows) {
            try RowIntervalAdjustmentCalculator.calculate(.init(
                totalRows: 5, totalStitches: 6, operation: .increase, style: .singleSide
            ))
        }
    }

    @Test func acceptsTheMaximumSupportedRowsAndStitchesWithoutOverflow() throws {
        let result = try RowIntervalAdjustmentCalculator.calculate(.init(
            totalRows: 100_000,
            totalStitches: 100_000,
            operation: .increase,
            style: .singleSide
        ))

        #expect(result.eventCount == 100_000)
        #expect(result.adjustmentRows.count == 100_000)
        #expect(result.adjustmentRows.last == 100_000)
        #expect(result.minimumInterval == 1)
        #expect(result.maximumInterval == 1)
    }

    @Test func rejectsRowsAboveTheMaximumIndependently() {
        #expect(throws: RowIntervalAdjustmentFailure.exceedsSupportedLimit) {
            try RowIntervalAdjustmentCalculator.calculate(.init(
                totalRows: 100_001,
                totalStitches: 1,
                operation: .decrease,
                style: .singleSide
            ))
        }
    }

    @Test func rejectsStitchesAboveTheMaximumIndependently() {
        #expect(throws: RowIntervalAdjustmentFailure.exceedsSupportedLimit) {
            try RowIntervalAdjustmentCalculator.calculate(.init(
                totalRows: 100_000,
                totalStitches: 100_001,
                operation: .decrease,
                style: .singleSide
            ))
        }
    }

    @Test func reportsOddSymmetricStitchesBeforeInsufficientRows() {
        #expect(throws: RowIntervalAdjustmentFailure.symmetricRequiresEvenStitches) {
            try RowIntervalAdjustmentCalculator.calculate(.init(
                totalRows: 1,
                totalStitches: 5,
                operation: .decrease,
                style: .bothSides
            ))
        }
    }

    @Test func schedulesAreUniqueIncreasingBalancedAndFinishOnTheFinalRow() throws {
        for totalRows in 1...25 {
            for eventCount in 1...totalRows {
                for style in [RowIntervalAdjustmentStyle.singleSide, .bothSides] {
                    let stitchesPerEvent = style == .singleSide ? 1 : 2
                    let result = try RowIntervalAdjustmentCalculator.calculate(.init(
                        totalRows: totalRows,
                        totalStitches: eventCount * stitchesPerEvent,
                        operation: .increase,
                        style: style
                    ))

                    #expect(result.eventCount == eventCount)
                    #expect(result.adjustmentRows.count == eventCount)
                    #expect(result.adjustmentRows.allSatisfy { (1...totalRows).contains($0) })
                    #expect(result.adjustmentRows.last == totalRows)
                    #expect(
                        zip(result.adjustmentRows, result.adjustmentRows.dropFirst())
                            .allSatisfy { previous, current in previous < current }
                    )
                    #expect(result.maximumInterval - result.minimumInterval <= 1)
                }
            }
        }
    }
}
