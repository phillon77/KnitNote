import Foundation
import Testing

@Suite struct KnittingCalculatorViewContractTests {
    @Test func gaugeScreenShowsExactRecommendationAndOptionalRows() throws {
        let source = try freeAppSource("Gauge/GaugeCalculatorScreen.swift")
        #expect(source.contains("GaugeCalculator.calculate"))
        #expect(source.contains("result.exactCount"))
        #expect(source.contains("result.recommendedCount"))
        #expect(source.contains("rowsWereStarted"))
        #expect(source.contains("GaugeCalculator.convertLength"))
        #expect(source.contains("calculator.gauge.patternCaution"))
        #expect(source.contains("accessibilityElement(children: .combine)"))
    }

    @Test func gaugeScreenExposesItsCurrentSnapshotToAConsumer() throws {
        let source = try freeAppSource("Gauge/GaugeCalculatorScreen.swift")
        #expect(source.contains("onShareSnapshotChange"))
        #expect(source.contains("onShareSnapshotChange(shareSnapshot)"))
        #expect(source.contains("onShareSnapshotChange(newValue)"))
    }

    private func freeAppSource(_ path: String) throws -> String {
        try String(
            contentsOf: URL(filePath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "KnittingCalculator/" + path),
            encoding: .utf8
        )
    }
}
