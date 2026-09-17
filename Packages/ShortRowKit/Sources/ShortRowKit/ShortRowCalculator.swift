import Foundation

public enum ShortRowFailure: Error, Equatable, Sendable {
    case invalidInput
    case heightTooSmall
    case tooManyRows
    case insufficientStitches
}

public struct ShortRowPair: Equatable, Sendable {
    public let workedStitches: Int
    public let unworkedStitches: Int
}

public struct ShortRowPlan: Equatable, Sendable {
    public let stitches: Int
    public let shapingRows: Int
    public let actualHeightCM: Double
    /// Segment widths from armhole to neck, including the final worked neck segment.
    public let segments: [Int]
    public let pairs: [ShortRowPair]
}

public enum ShortRowCalculator {
    public static func calculate(stitches: Int, rowsPer10cm: Double, heightCM: Double) throws -> ShortRowPlan {
        guard (2...10_000).contains(stitches), rowsPer10cm.isFinite, heightCM.isFinite,
              rowsPer10cm > 0, heightCM > 0 else { throw ShortRowFailure.invalidInput }
        let pairsValue = (heightCM * (rowsPer10cm / 10) / 2).rounded(.toNearestOrAwayFromZero)
        guard pairsValue.isFinite, pairsValue <= 100 else { throw ShortRowFailure.tooManyRows }
        guard pairsValue >= 1 else { throw ShortRowFailure.heightTooSmall }
        let count = Int(pairsValue)
        let segmentCount = count + 1
        guard stitches >= segmentCount else { throw ShortRowFailure.insufficientStitches }
        // Cumulative integer division spreads the remainder without losing any stitches.
        let segments = (0..<segmentCount).map {
            (($0 + 1) * stitches / segmentCount) - ($0 * stitches / segmentCount)
        }
        var unworked = 0
        let pairs = segments.dropLast().map { width -> ShortRowPair in
            unworked += width
            return ShortRowPair(workedStitches: stitches - unworked, unworkedStitches: unworked)
        }
        let actualHeight = Double(count * 2) / (rowsPer10cm / 10)
        guard actualHeight.isFinite else { throw ShortRowFailure.invalidInput }
        return ShortRowPlan(stitches: stitches, shapingRows: count * 2,
                            actualHeightCM: actualHeight, segments: segments, pairs: pairs)
    }
}
