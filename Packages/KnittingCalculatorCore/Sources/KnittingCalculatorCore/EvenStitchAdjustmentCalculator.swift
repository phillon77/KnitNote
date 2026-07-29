public struct EvenStitchAdjustmentInput: Equatable, Sendable {
    public let current: Int
    public let target: Int
    public let reservesEdgeStitches: Bool

    public init(current: Int, target: Int, reservesEdgeStitches: Bool) {
        self.current = current
        self.target = target
        self.reservesEdgeStitches = reservesEdgeStitches
    }
}

public enum EvenStitchOperation: Equatable, Sendable {
    case increase
    case decrease
    case unchanged
}

public enum EvenStitchStep: Equatable, Sendable {
    case edge(Int)
    case knit(Int)
    case increaseOne
    case decreaseOne
}

public enum EvenStitchAdjustmentFailure: Error, Equatable, Sendable {
    case invalidCounts
    case exceedsSupportedLimit
    case cannotPreserveEdges
    case requiresMultipleRows
}

public struct EvenStitchAdjustmentResult: Equatable, Sendable {
    public let operation: EvenStitchOperation
    public let adjustmentCount: Int
    public let edgeStitches: Int
    public let plainSegments: [Int]
    public let steps: [EvenStitchStep]
}

public enum EvenStitchAdjustmentCalculator {
    public static let maximumSupportedStitches = 100_000

    public static func fieldNeedsValidation(
        _ value: Int?,
        groupStarted: Bool
    ) -> Bool {
        guard groupStarted else { return false }
        guard let value else { return true }
        return value <= 0
    }

    public static func calculate(
        _ input: EvenStitchAdjustmentInput
    ) throws -> EvenStitchAdjustmentResult {
        guard input.current > 0, input.target > 0 else {
            throw EvenStitchAdjustmentFailure.invalidCounts
        }
        guard input.current <= maximumSupportedStitches,
              input.target <= maximumSupportedStitches else {
            throw EvenStitchAdjustmentFailure.exceedsSupportedLimit
        }
        if input.reservesEdgeStitches, (input.current < 2 || input.target < 2) {
            throw EvenStitchAdjustmentFailure.cannotPreserveEdges
        }

        let edgeStitches = input.reservesEdgeStitches ? 1 : 0
        if input.current == input.target {
            return EvenStitchAdjustmentResult(
                operation: .unchanged,
                adjustmentCount: 0,
                edgeStitches: edgeStitches,
                plainSegments: [],
                steps: []
            )
        }

        let working = input.reservesEdgeStitches ? input.current - 2 : input.current
        if input.target > input.current {
            let adjustments = input.target - input.current
            let gapCount = adjustments + 1
            guard working >= gapCount else {
                throw EvenStitchAdjustmentFailure.requiresMultipleRows
            }

            let plainSegments = balancedSegments(total: working, count: gapCount)
            return EvenStitchAdjustmentResult(
                operation: .increase,
                adjustmentCount: adjustments,
                edgeStitches: edgeStitches,
                plainSegments: plainSegments,
                steps: makeSteps(
                    plainSegments: plainSegments,
                    adjustment: .increaseOne,
                    edgeStitches: edgeStitches
                )
            )
        }

        let adjustments = input.current - input.target
        guard adjustments <= working / 2 else {
            throw EvenStitchAdjustmentFailure.requiresMultipleRows
        }
        let plainStitches = working - (adjustments * 2)
        let gapCount = adjustments + 1
        let plainSegments = balancedSegments(total: plainStitches, count: gapCount)
        return EvenStitchAdjustmentResult(
            operation: .decrease,
            adjustmentCount: adjustments,
            edgeStitches: edgeStitches,
            plainSegments: plainSegments,
            steps: makeSteps(
                plainSegments: plainSegments,
                adjustment: .decreaseOne,
                edgeStitches: edgeStitches
            )
        )
    }

    private static func balancedSegments(total: Int, count: Int) -> [Int] {
        let base = total / count
        let remainder = total % count
        var accumulatedRemainder = count / 2

        return (0..<count).map { _ in
            let threshold = count - remainder
            if accumulatedRemainder >= threshold {
                accumulatedRemainder -= threshold
                return base + 1
            }

            accumulatedRemainder += remainder
            return base
        }
    }

    private static func makeSteps(
        plainSegments: [Int],
        adjustment: EvenStitchStep,
        edgeStitches: Int
    ) -> [EvenStitchStep] {
        var steps: [EvenStitchStep] = []
        if edgeStitches > 0 {
            steps.append(.edge(edgeStitches))
        }

        for index in plainSegments.indices {
            let segment = plainSegments[index]
            if segment > 0 {
                steps.append(.knit(segment))
            }
            if index < plainSegments.index(before: plainSegments.endIndex) {
                steps.append(adjustment)
            }
        }

        if edgeStitches > 0 {
            steps.append(.edge(edgeStitches))
        }
        return steps
    }
}
