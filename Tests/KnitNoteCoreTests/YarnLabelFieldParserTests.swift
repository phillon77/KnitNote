import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct YarnLabelFieldParserTests {
    private let parser = YarnLabelFieldParser()

    @Test func parsesEnglishMetricLabel() throws {
        let needleRange = try YarnMetricRange(lower: 3.5, upper: 4)
        let hookRange = try YarnMetricRange(lower: 4, upper: 4)
        let result = parser.parse(observations("""
        DROPS BELLE
        Colour 12
        Dye lot 991
        50 g / 120 m
        53% Cotton 33% Viscose 14% Linen
        Needles 3.5–4 mm
        Hook 4 mm
        """))

        #expect(result.best(.brand)?.text == "DROPS")
        #expect(result.best(.series)?.text == "BELLE")
        #expect(result.best(.colorCode)?.text == "12")
        #expect(result.best(.dyeLot)?.text == "991")
        #expect(result.best(.ballWeightGrams)?.decimalValue == 50)
        #expect(result.best(.lengthMeters)?.decimalValue == 120)
        #expect(result.best(.fiberContent)?.text == "53% Cotton 33% Viscose 14% Linen")
        #expect(result.best(.recommendedNeedleMM)?.metricRangeValue == needleRange)
        #expect(result.best(.recommendedHookMM)?.metricRangeValue == hookRange)
    }

    @Test func conflictingSidesRequireConfirmation() {
        let result = parser.parse([
            .init(text: "Color 12", confidence: 0.95, sourceImageIndex: 0),
            .init(text: "Color 13", confidence: 0.96, sourceImageIndex: 1),
        ])

        #expect(result.candidates(for: .colorCode).map(\.text) == ["13", "12"])
        #expect(result.fieldsRequiringConfirmation.contains(.colorCode))
    }

    @Test func parsesTraditionalChineseAndDecimalComma() throws {
        let needleRange = try YarnMetricRange(lower: 3.5, upper: 4)
        let hookRange = try YarnMetricRange(lower: 4.5, upper: 4.5)
        let result = parser.parse(observations("""
        色名 霧藍
        色號 B12
        染缸號 778
        棒針 3,5-4 mm
        鉤針 4,5 mm
        """))

        #expect(result.best(.color)?.text == "霧藍")
        #expect(result.best(.colorCode)?.text == "B12")
        #expect(result.best(.dyeLot)?.text == "778")
        #expect(result.best(.recommendedNeedleMM)?.metricRangeValue == needleRange)
        #expect(result.best(.recommendedHookMM)?.metricRangeValue == hookRange)
    }

    @Test func convertsExplicitImperialUnitsToMetric() {
        let result = parser.parse(observations("1.75 oz / 131 yds"))

        #expect(result.best(.ballWeightGrams)?.decimalValue == Decimal(string: "49.6"))
        #expect(result.best(.lengthMeters)?.decimalValue == Decimal(string: "119.8"))
    }

    @Test func invalidOrUnrelatedObservationsAreIgnored() {
        let result = parser.parse([
            .init(text: "", confidence: 0.99, sourceImageIndex: 0),
            .init(text: "Order 84921", confidence: 0.99, sourceImageIndex: 0),
            .init(text: "Color 88", confidence: 0.99, sourceImageIndex: 2),
            .init(text: "Dye lot 77", confidence: -1, sourceImageIndex: 0),
        ])

        #expect(result.allCandidates.isEmpty)
        #expect(result.fieldsRequiringConfirmation.isEmpty)
    }

    @Test func duplicateNormalizedCandidatesCollapseToOne() {
        let result = parser.parse([
            .init(text: "Colour 12", confidence: 0.90, sourceImageIndex: 0),
            .init(text: "COLOR: 12", confidence: 0.98, sourceImageIndex: 1),
        ])

        #expect(result.candidates(for: .colorCode).count == 1)
        #expect(!result.fieldsRequiringConfirmation.contains(.colorCode))
        #expect(result.best(.colorCode)?.confidence == 0.98)
    }

    @Test func lowConfidenceCandidateRequiresConfirmation() {
        let result = parser.parse([
            .init(text: "Dye lot 778", confidence: 0.62, sourceImageIndex: 0),
        ])

        #expect(result.best(.dyeLot)?.text == "778")
        #expect(result.fieldsRequiringConfirmation.contains(.dyeLot))
    }

    private func observations(_ text: String) -> [YarnLabelObservation] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map {
            YarnLabelObservation(text: String($0), confidence: 0.95, sourceImageIndex: 0)
        }
    }
}
