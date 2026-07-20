public enum GaugeLengthUnit: String, CaseIterable, Sendable {
    case centimeters
    case inches
}

public struct GaugeInput: Equatable, Sendable {
    public let sampleLength: Double
    public let sampleCount: Double
    public let targetLength: Double

    public init(sampleLength: Double, sampleCount: Double, targetLength: Double) {
        self.sampleLength = sampleLength
        self.sampleCount = sampleCount
        self.targetLength = targetLength
    }
}

public struct GaugeResult: Equatable, Sendable {
    public let density: Double
    public let exactCount: Double
    public let recommendedCount: Int
}

public enum GaugeCalculator {
    public static func fieldNeedsValidation(
        _ value: Double?,
        groupStarted: Bool
    ) -> Bool {
        guard groupStarted else { return false }
        guard let value else { return true }
        return !value.isFinite || value <= 0
    }

    public static func calculate(_ input: GaugeInput) -> GaugeResult? {
        let values = [input.sampleLength, input.sampleCount, input.targetLength]
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }

        let density = input.sampleCount / input.sampleLength
        let exact = density * input.targetLength
        guard exact.isFinite else { return nil }

        let rounded = exact.rounded(.toNearestOrAwayFromZero)
        guard rounded >= Double(Int.min), rounded < Double(Int.max) else { return nil }

        return GaugeResult(
            density: density,
            exactCount: exact,
            recommendedCount: Int(rounded)
        )
    }

    public static func convertLength(
        _ value: Double,
        from: GaugeLengthUnit,
        to: GaugeLengthUnit
    ) -> Double {
        guard from != to else { return value }
        return from == .centimeters ? value / 2.54 : value * 2.54
    }
}
