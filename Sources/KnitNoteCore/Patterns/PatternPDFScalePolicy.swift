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

public struct PatternPDFScaleCaptureGate: Sendable {
    private struct PendingObservation: Sendable {
        let revision: UInt64
        let context: UInt64
        let currentScale: Double
        let fitWidthScale: Double
    }

    private var nextRevision: UInt64 = 0
    private var pendingObservation: PendingObservation?

    public init() {}

    @discardableResult
    public mutating func observe(
        currentScale: Double,
        fitWidthScale: Double,
        context: UInt64
    ) -> UInt64? {
        guard currentScale.isFinite, currentScale > 0,
              fitWidthScale.isFinite, fitWidthScale > 0 else { return nil }
        nextRevision &+= 1
        pendingObservation = PendingObservation(
            revision: nextRevision,
            context: context,
            currentScale: currentScale,
            fitWidthScale: fitWidthScale
        )
        return nextRevision
    }

    public mutating func settle(revision: UInt64, context: UInt64) -> Double? {
        guard let pendingObservation,
              pendingObservation.revision == revision,
              pendingObservation.context == context else { return nil }
        self.pendingObservation = nil
        return PatternPDFScalePolicy.ratio(
            currentScale: pendingObservation.currentScale,
            fitWidthScale: pendingObservation.fitWidthScale
        )
    }

    public mutating func flush(context: UInt64) -> Double? {
        guard let pendingObservation else { return nil }
        self.pendingObservation = nil
        guard pendingObservation.context == context else { return nil }
        return PatternPDFScalePolicy.ratio(
            currentScale: pendingObservation.currentScale,
            fitWidthScale: pendingObservation.fitWidthScale
        )
    }

    public mutating func invalidate() {
        nextRevision &+= 1
        pendingObservation = nil
    }
}
