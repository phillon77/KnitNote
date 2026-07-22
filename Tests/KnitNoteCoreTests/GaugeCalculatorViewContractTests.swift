import Foundation
import Testing

@Suite("Gauge calculator view contracts")
struct GaugeCalculatorViewContractTests {
    @Test func gaugeCalculatorViewUsesCoreAndKeepsRowsOptional() throws {
        let source = try appSource("KnitNote/Calculators/GaugeCalculatorView.swift")

        #expect(source.contains("GaugeCalculator.calculate"))
        #expect(source.contains("GaugeCalculator.convertLength"))
        #expect(source.contains("rowsWereStarted"))
        #expect(source.contains("WatercolorCard"))
        #expect(source.contains("keyboardType(.decimalPad)"))
        #expect(source.contains("frame(maxWidth: 620)"))
    }

    @Test func settingsOpensGaugeDirectlyAndProjectOpensCalculatorMenu() throws {
        let settings = try appSource("KnitNote/Settings/SettingsView.swift")
        let project = try appSource("KnitNote/Projects/ProjectDetailView.swift")
        let menu = try appSource("KnitNote/Calculators/KnittingCalculatorsView.swift")

        #expect(settings.contains("NavigationLink"))
        #expect(settings.contains("GaugeCalculatorView()"))
        #expect(menu.contains("GaugeCalculatorView()"))
        #expect(project.contains("KnittingCalculatorsView()"))
        #expect(!project.contains("GaugeCalculatorView()"))
        #expect(settings.contains("calculator.tools.title"))
        #expect(project.contains("calculator.tools.title"))
    }

    @Test func projectPlacesCalculatorMenuBetweenCountersAndJournal() throws {
        let project = try appSource("KnitNote/Projects/ProjectDetailView.swift")
        let counters = try #require(project.range(of: "CounterSelectorGrid("))
        let calculators = try #require(project.range(of: "KnittingCalculatorsView()"))
        let journal = try #require(project.range(of: "ProjectJournalSection("))

        #expect(counters.lowerBound < calculators.lowerBound)
        #expect(calculators.lowerBound < journal.lowerBound)
    }

    @Test func gaugeResultsShowDensityExactAndRecommendation() throws {
        let source = try appSource("KnitNote/Calculators/GaugeCalculatorView.swift")

        #expect(source.contains("Text(\"calculator.gauge.density\")"))
        #expect(source.contains("Text(\"calculator.gauge.exact\")"))
        #expect(source.contains("formattedNumber(result.density)"))
        #expect(source.contains("formattedNumber(result.exactCount)"))
        #expect(source.contains("String.localizedStringWithFormat"))
        #expect(source.contains("String(localized: \"calculator.gauge.recommendation.format\", locale: locale)"))
        #expect(source.contains("String(localized: \"calculator.gauge.stitches.recommendation.format\", locale: locale)"))
        #expect(source.contains("String(localized: \"calculator.gauge.rows.recommendation.format\", locale: locale)"))
        #expect(source.contains("calculator.gauge.stitches.density.centimeters.format"))
        #expect(source.contains("calculator.gauge.stitches.density.inches.format"))
        #expect(source.contains("calculator.gauge.rows.density.centimeters.format"))
        #expect(source.contains("calculator.gauge.rows.density.inches.format"))
        #expect(source.contains("Text(verbatim:"))
        #expect(!source.contains("Text(\"calculator.gauge.recommendation \\("))
        #expect(!source.contains("Text(\"calculator.gauge.stitches.recommendation \\("))
        #expect(!source.contains("Text(\"calculator.gauge.rows.recommendation \\("))
    }

    @Test func everyGaugeFieldWiresStartedGroupValidationBesideTheField() throws {
        let source = try appSource("KnitNote/Calculators/GaugeCalculatorView.swift")

        #expect(source.contains(
            "decimalField(sampleLengthTitle, text: sampleLength, groupStarted: wasStarted)"
        ))
        #expect(source.contains(
            "decimalField(countTitle, text: count, groupStarted: wasStarted)"
        ))
        #expect(source.contains(
            "decimalField(targetLengthTitle, text: targetLength, groupStarted: wasStarted)"
        ))
        #expect(source.contains("GaugeCalculator.fieldNeedsValidation("))
        #expect(source.contains("parseNumber(text)"))
        #expect(source.contains("Text(\"calculator.validation.positive\")"))
        #expect(!source.contains("calculator.gauge.validation"))
        #expect(!source.contains("else if wasStarted"))
    }
}

private func appSource(_ relativePath: String) throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: repositoryRoot.appendingPathComponent(relativePath),
        encoding: .utf8
    )
}
