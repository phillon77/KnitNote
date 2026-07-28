import Foundation
import Testing

@Suite struct KnittingCalculatorLocalizationContractTests {
    @Test func calculatorCatalogCoversCurrentGaugeAndAdjustmentScreens() throws {
        let data = try Data(contentsOf: repositoryRoot.appending(path: catalogPath))
        let catalog = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let entries = try #require(catalog["strings"] as? [String: [String: Any]])

        for key in currentScreenKeys {
            let entry = try #require(entries[key], "Missing catalog entry: \(key)")
            let localizations = try #require(
                entry["localizations"] as? [String: Any],
                "Missing localizations: \(key)"
            )
            for locale in ["en", "zh-Hant"] {
                let localization = try #require(
                    localizations[locale] as? [String: Any],
                    "Missing \(locale): \(key)"
                )
                let stringUnit = try #require(localization["stringUnit"] as? [String: Any])
                let value = try #require(stringUnit["value"] as? String)
                #expect(!value.isEmpty, "Empty \(locale): \(key)")
            }
        }
    }

    private let catalogPath = "KnittingCalculator/Localization/Localizable.xcstrings"

    private let currentScreenKeys = [
        "calculator.gauge.title",
        "calculator.gauge.unit",
        "calculator.gauge.unit.centimeters",
        "calculator.gauge.unit.inches",
        "calculator.gauge.stitches",
        "calculator.gauge.rows.optional",
        "calculator.gauge.sampleWidth",
        "calculator.gauge.sampleStitches",
        "calculator.gauge.targetWidth",
        "calculator.gauge.sampleHeight",
        "calculator.gauge.sampleRows",
        "calculator.gauge.targetHeight",
        "calculator.gauge.invalidPositive",
        "calculator.gauge.density",
        "calculator.gauge.exact",
        "calculator.gauge.recommended",
        "calculator.gauge.patternCaution",
        "calculator.gauge.result",
        "calculator.adjustment.title",
        "calculator.adjustment.mode",
        "calculator.adjustment.mode.oneRow",
        "calculator.adjustment.mode.acrossRows",
        "calculator.adjustment.input.title",
        "calculator.adjustment.current",
        "calculator.adjustment.target",
        "calculator.adjustment.validation.positiveInteger",
        "calculator.adjustment.reservesEdgeStitches",
        "calculator.adjustment.reservesEdgeStitches.hint",
        "calculator.adjustment.summary.unchanged",
        "calculator.adjustment.summary.increase.singular",
        "calculator.adjustment.summary.increase.format",
        "calculator.adjustment.summary.decrease.singular",
        "calculator.adjustment.summary.decrease.format",
        "calculator.adjustment.edgeSummary.reserved",
        "calculator.adjustment.edgeSummary.notReserved",
        "calculator.adjustment.steps.show",
        "calculator.adjustment.step.edge.format",
        "calculator.adjustment.step.work.singular",
        "calculator.adjustment.step.work.format",
        "calculator.adjustment.step.increaseOne",
        "calculator.adjustment.step.decreaseOne",
        "calculator.adjustment.accessibility.summary.edge.format",
        "calculator.adjustment.failure.invalidCounts",
        "calculator.adjustment.failure.exceedsSupportedLimit",
        "calculator.adjustment.failure.cannotPreserveEdges",
        "calculator.adjustment.failure.requiresMultipleRows",
        "calculator.adjustment.rows.input.title",
        "calculator.adjustment.rows.operation",
        "calculator.adjustment.rows.operation.increase",
        "calculator.adjustment.rows.operation.decrease",
        "calculator.adjustment.rows.totalRows",
        "calculator.adjustment.rows.totalStitches",
        "calculator.adjustment.rows.style",
        "calculator.adjustment.rows.style.singleSide",
        "calculator.adjustment.rows.style.bothSides",
        "calculator.adjustment.rows.eventCount",
        "calculator.adjustment.rows.stitchesPerEvent",
        "calculator.adjustment.rows.interval",
        "calculator.adjustment.rows.interval.exact.format",
        "calculator.adjustment.rows.interval.range.format",
        "calculator.adjustment.rows.details.show",
        "calculator.adjustment.rows.detail.format",
        "calculator.adjustment.rows.summary.increase.singleSide.exact.format",
        "calculator.adjustment.rows.summary.increase.singleSide.range.format",
        "calculator.adjustment.rows.summary.increase.bothSides.exact.format",
        "calculator.adjustment.rows.summary.increase.bothSides.range.format",
        "calculator.adjustment.rows.summary.decrease.singleSide.exact.format",
        "calculator.adjustment.rows.summary.decrease.singleSide.range.format",
        "calculator.adjustment.rows.summary.decrease.bothSides.exact.format",
        "calculator.adjustment.rows.summary.decrease.bothSides.range.format",
        "calculator.adjustment.rows.accessibility.summary.format",
        "calculator.adjustment.rows.failure.invalidCounts",
        "calculator.adjustment.rows.failure.exceedsSupportedLimit",
        "calculator.adjustment.rows.failure.symmetricRequiresEvenStitches",
        "calculator.adjustment.rows.failure.insufficientRows",
    ]

    private var repositoryRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
