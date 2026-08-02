import Foundation

public enum PatternPDFScalePolicy: Sendable {
    public static let defaultRatio = 1.0

    public static func normalizedRatio(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : defaultRatio
    }

    public static func ratio(currentScale: Double, fitWidthScale: Double) -> Double {
        guard currentScale.isFinite, currentScale > 0,
              fitWidthScale.isFinite, fitWidthScale > 0 else { return defaultRatio }
        return normalizedRatio(currentScale / fitWidthScale)
    }

    public static func absoluteScale(
        ratio: Double,
        fitWidthScale: Double,
        allowed: ClosedRange<Double>
    ) -> Double {
        let cleanFit = fitWidthScale.isFinite && fitWidthScale > 0 ? fitWidthScale : defaultRatio
        let lower = allowed.lowerBound.isFinite && allowed.lowerBound > 0 ? allowed.lowerBound : cleanFit
        let upper = allowed.upperBound.isFinite && allowed.upperBound >= lower ? allowed.upperBound : max(lower, cleanFit)
        let candidate = normalizedRatio(ratio) * cleanFit
        return min(upper, max(lower, candidate.isFinite && candidate > 0 ? candidate : cleanFit))
    }
}
