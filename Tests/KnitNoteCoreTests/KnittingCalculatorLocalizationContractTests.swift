import Foundation
import Testing

@Suite struct KnittingCalculatorLocalizationContractTests {
    @Test func everyFreeAppStringHasEnglishAndTraditionalChinese() throws {
        let entries = try stringEntries(at: catalogPath)
        for (key, entry) in entries {
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for locale in ["en", "zh-Hant"] {
                let localized = try #require(localizations[locale])
                let values = leafValues(in: localized)
                #expect(!values.isEmpty, "Missing \(locale): \(key)")
                #expect(values.allSatisfy { !$0.isEmpty }, "Empty \(locale): \(key)")
            }
            let english = leafValues(in: try #require(localizations["en"]))
            let chinese = leafValues(in: try #require(localizations["zh-Hant"]))
            #expect(
                english.flatMap(formatTokens).sorted()
                    == chinese.flatMap(formatTokens).sorted(),
                "Format mismatch: \(key)"
            )
        }
    }

    @Test func allFreeAppLocalizationReferencesResolveInBothSupportedLanguages() throws {
        let entries = try stringEntries(at: catalogPath)
        for key in currentScreenKeys {
            let entry = try #require(entries[key], "Missing catalog entry: \(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for locale in ["en", "zh-Hant"] {
                #expect(
                    !leafValues(in: try #require(localizations[locale])).isEmpty,
                    "Missing \(locale): \(key)"
                )
            }
        }
    }

    @Test func displayNameIsLocalized() throws {
        let entries = try stringEntries(
            at: "KnittingCalculator/Localization/InfoPlist.xcstrings"
        )
        let entry = try #require(entries["CFBundleDisplayName"])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        #expect(leafValues(in: try #require(localizations["en"])) == ["Knitting Calculator"])
        #expect(leafValues(in: try #require(localizations["zh-Hant"])) == ["編織計算器"])
    }

    @Test func calculatorScreensKeepAccessibleErrorOrderAndAdaptiveLayoutContracts() throws {
        let gauge = try freeAppSource("Gauge/GaugeCalculatorScreen.swift")
        let oneRow = try freeAppSource("Adjustment/OneRowAdjustmentView.swift")
        let rows = try freeAppSource("Adjustment/RowIntervalAdjustmentView.swift")
        let modePicker = try freeAppSource("Adjustment/AdjustmentCalculatorScreen.swift")
        let field = try freeAppSource("Components/CalculatorField.swift")
        let actions = try freeAppSource("Components/CalculatorResultActions.swift")

        #expect(gauge.contains("frame(maxWidth: 680, alignment: .leading)"))
        #expect(oneRow.contains("Label(failureKey(failure), systemImage: \"exclamationmark.triangle.fill\")"))
        #expect(rows.contains("Label(failureKey(failure), systemImage: \"exclamationmark.triangle.fill\")"))
        #expect(field.contains("Label(validationKey, systemImage: \"exclamationmark.triangle.fill\")"))
        #expect(modePicker.contains("accessibilityValue"))
        #expect(actions.components(separatedBy: "minWidth: 44").count - 1 == 2)

        for source in [gauge, oneRow, rows, modePicker, field, actions] {
            #expect(!source.contains(".dynamicTypeSize("))
        }
    }

    private let catalogPath = "KnittingCalculator/Localization/Localizable.xcstrings"

    private let currentScreenKeys = [
        "app.title",
        "app.home.title",
        "app.settings.title",
        "calculator.home.gauge.description",
        "calculator.home.adjustment.description",
        "calculator.promotion.description",
        "calculator.promotion.product.relationship",
        "calculator.promotion.action",
        "calculator.promotion.action.accessibility",
        "calculator.promotion.action.hint",
        "calculator.settings.unit.section",
        "calculator.settings.data.section",
        "calculator.settings.reset",
        "calculator.settings.reset.hint",
        "calculator.settings.reset.confirmation.title",
        "calculator.settings.reset.confirmation.message",
        "calculator.settings.reset.cancel",
        "calculator.settings.knitnote.section",
        "calculator.settings.support.section",
        "calculator.settings.feedback",
        "calculator.settings.privacy",
        "calculator.settings.about.section",
        "calculator.settings.version",
        "calculator.help.title",
        "calculator.help.gauge",
        "calculator.help.adjustment",
        "calculator.help.dismiss",
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
        "calculator.adjustment.rows.interval.summary.exact.format",
        "calculator.adjustment.rows.interval.summary.range.format",
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
        "calculator.resultActions.copy",
        "calculator.resultActions.copy.accessibility",
        "calculator.resultActions.share",
        "calculator.resultActions.share.accessibility",
        "calculator.share.attribution",
        "calculator.share.gauge.title",
        "calculator.share.gauge.input.format",
        "calculator.share.gauge.result.format",
        "calculator.share.gauge.rows.input.format",
        "calculator.share.gauge.rows.result.format",
        "calculator.share.oneRow.title",
        "calculator.share.oneRow.input.format",
        "calculator.share.oneRow.edges.reserved",
        "calculator.share.oneRow.edges.notReserved",
        "calculator.share.oneRow.steps.format",
        "calculator.share.steps.separator",
        "calculator.share.rowInterval.title",
        "calculator.share.rowInterval.operation.increase",
        "calculator.share.rowInterval.operation.decrease",
        "calculator.share.rowInterval.style.singleSide",
        "calculator.share.rowInterval.style.bothSides",
        "calculator.share.rowInterval.input.format",
        "calculator.share.rowInterval.result.format",
        "calculator.share.rowInterval.rows.format",
        "calculator.share.rows.separator",
    ]

    private var repositoryRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func stringEntries(at relativePath: String) throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: repositoryRoot.appending(path: relativePath))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["strings"] as? [String: [String: Any]])
    }

    private func leafValues(in value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            let direct = dictionary["value"] as? String
            return (direct.map { [$0] } ?? [])
                + dictionary.flatMap { key, child in
                    key == "value" ? [] : leafValues(in: child)
                }
        }
        if let array = value as? [Any] {
            return array.flatMap(leafValues)
        }
        return []
    }

    private func formatTokens(in value: String) -> [String] {
        let expression = try! NSRegularExpression(
            pattern: #"%(\d+\$)?[-+ #0]*(\d+|\*)?(\.\d+)?(hh|h|ll|l|L|z|t|j)?[@diuoxXfFeEgGaAcCsSp]"#
        )
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }
    }

    private func freeAppSource(_ path: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appending(path: "KnittingCalculator/" + path),
            encoding: .utf8
        )
    }
}
