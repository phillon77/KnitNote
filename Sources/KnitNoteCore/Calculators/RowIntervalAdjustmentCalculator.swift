public enum RowIntervalAdjustmentOperation: Equatable, Sendable {
    case increase
    case decrease
}

public enum RowIntervalAdjustmentStyle: Equatable, Sendable {
    case singleSide
    case bothSides
}

public struct RowIntervalAdjustmentInput: Equatable, Sendable {
    public let totalRows: Int
    public let totalStitches: Int
    public let operation: RowIntervalAdjustmentOperation
    public let style: RowIntervalAdjustmentStyle

    public init(
        totalRows: Int,
        totalStitches: Int,
        operation: RowIntervalAdjustmentOperation,
        style: RowIntervalAdjustmentStyle
    ) {
        self.totalRows = totalRows
        self.totalStitches = totalStitches
        self.operation = operation
        self.style = style
    }
}

public enum RowIntervalAdjustmentFailure: Error, Equatable, Sendable {
    case invalidCounts
    case exceedsSupportedLimit
    case symmetricRequiresEvenStitches
    case insufficientRows
}

public struct RowIntervalAdjustmentResult: Equatable, Sendable {
    public let operation: RowIntervalAdjustmentOperation
    public let style: RowIntervalAdjustmentStyle
    public let totalRows: Int
    public let totalStitches: Int
    public let eventCount: Int
    public let stitchesPerEvent: Int
    public let adjustmentRows: [Int]
    public let minimumInterval: Int
    public let maximumInterval: Int
}

public enum RowIntervalAdjustmentCalculator {
    public static let maximumSupportedValue = 100_000

    public static func calculate(
        _ input: RowIntervalAdjustmentInput
    ) throws -> RowIntervalAdjustmentResult {
        guard input.totalRows > 0, input.totalStitches > 0 else {
            throw RowIntervalAdjustmentFailure.invalidCounts
        }
        guard input.totalRows <= maximumSupportedValue,
              input.totalStitches <= maximumSupportedValue else {
            throw RowIntervalAdjustmentFailure.exceedsSupportedLimit
        }
        if input.style == .bothSides, !input.totalStitches.isMultiple(of: 2) {
            throw RowIntervalAdjustmentFailure.symmetricRequiresEvenStitches
        }

        let stitchesPerEvent = input.style == .bothSides ? 2 : 1
        let eventCount = input.totalStitches / stitchesPerEvent
        guard eventCount <= input.totalRows else {
            throw RowIntervalAdjustmentFailure.insufficientRows
        }

        let rows = (1...eventCount).map { event in
            let product = event * input.totalRows
            return product / eventCount + (product.isMultiple(of: eventCount) ? 0 : 1)
        }
        let intervals = zip([0] + rows, rows).map { previous, current in
            current - previous
        }

        return RowIntervalAdjustmentResult(
            operation: input.operation,
            style: input.style,
            totalRows: input.totalRows,
            totalStitches: input.totalStitches,
            eventCount: eventCount,
            stitchesPerEvent: stitchesPerEvent,
            adjustmentRows: rows,
            minimumInterval: intervals.min()!,
            maximumInterval: intervals.max()!
        )
    }
}
