import Foundation
import KnittingCalculatorCore

enum CalculatorProductLinks {
    static let freeApp = URL(
        string: "https://phillon77.github.io/KnitNote/knitting-calculator.html"
    )!
}

enum CalculatorShareText {
    static func gauge(_ snapshot: GaugeShareSnapshot, locale: Locale) -> String {
        let unit = unitName(snapshot.unit, locale: locale)
        var lines = [
            localized("calculator.share.gauge.title", locale: locale),
            formatted(
                "calculator.share.gauge.input.format",
                snapshot.sampleLength,
                unit,
                snapshot.sampleCount,
                snapshot.targetLength,
                unit,
                locale: locale
            ),
            gaugeResultLine(snapshot.result, unit: unit, locale: locale),
        ]

        if let rows = snapshot.rows {
            lines.append(
                formatted(
                    "calculator.share.gauge.rows.input.format",
                    rows.sampleLength,
                    unit,
                    rows.sampleCount,
                    rows.targetLength,
                    unit,
                    locale: locale
                )
            )
            lines.append(gaugeRowsResultLine(rows.result, unit: unit, locale: locale))
        }

        lines += footer(locale: locale)
        return lines.joined(separator: "\n")
    }

    static func oneRow(_ snapshot: OneRowShareSnapshot, locale: Locale) -> String {
        let summary = oneRowSummary(snapshot.result, locale: locale)
        let edgeChoice = localized(
            snapshot.reservesEdgeStitches
                ? "calculator.share.oneRow.edges.reserved"
                : "calculator.share.oneRow.edges.notReserved",
            locale: locale
        )
        let steps = snapshot.result.steps.map { step in
            oneRowStep(step, locale: locale)
        }.joined(separator: localized("calculator.share.steps.separator", locale: locale))

        var lines = [
            localized("calculator.share.oneRow.title", locale: locale),
            formatted(
                "calculator.share.oneRow.input.format",
                snapshot.current,
                snapshot.target,
                locale: locale
            ),
            summary,
            edgeChoice,
        ]
        if !steps.isEmpty {
            lines.append(
                formatted("calculator.share.oneRow.steps.format", steps, locale: locale)
            )
        }
        lines += footer(locale: locale)
        return lines.joined(separator: "\n")
    }

    static func rowInterval(_ snapshot: RowIntervalShareSnapshot, locale: Locale) -> String {
        let input = snapshot.input
        let result = snapshot.result
        let operation = localized(
            result.operation == .increase
                ? "calculator.share.rowInterval.operation.increase"
                : "calculator.share.rowInterval.operation.decrease",
            locale: locale
        )
        let style = localized(
            result.style == .singleSide
                ? "calculator.share.rowInterval.style.singleSide"
                : "calculator.share.rowInterval.style.bothSides",
            locale: locale
        )
        let interval = rowInterval(result, locale: locale)
        let rows = result.adjustmentRows.map(String.init).joined(
            separator: localized("calculator.share.rows.separator", locale: locale)
        )

        var lines = [
            localized("calculator.share.rowInterval.title", locale: locale),
            formatted(
                "calculator.share.rowInterval.input.format",
                operation,
                style,
                input.totalRows,
                input.totalStitches,
                locale: locale
            ),
            formatted(
                "calculator.share.rowInterval.result.format",
                result.eventCount,
                result.stitchesPerEvent,
                interval,
                locale: locale
            ),
            formatted("calculator.share.rowInterval.rows.format", rows, locale: locale),
        ]
        lines += footer(locale: locale)
        return lines.joined(separator: "\n")
    }

    private static func gaugeResultLine(
        _ result: GaugeResult,
        unit: String,
        locale: Locale
    ) -> String {
        formatted(
            "calculator.share.gauge.result.format",
            result.density,
            unit,
            result.exactCount,
            result.recommendedCount,
            locale: locale
        )
    }

    private static func gaugeRowsResultLine(
        _ result: GaugeResult,
        unit: String,
        locale: Locale
    ) -> String {
        formatted(
            "calculator.share.gauge.rows.result.format",
            result.density,
            unit,
            result.exactCount,
            result.recommendedCount,
            locale: locale
        )
    }

    private static func oneRowSummary(
        _ result: EvenStitchAdjustmentResult,
        locale: Locale
    ) -> String {
        switch result.operation {
        case .unchanged:
            return localized("calculator.adjustment.summary.unchanged", locale: locale)
        case .increase:
            return result.adjustmentCount == 1
                ? localized("calculator.adjustment.summary.increase.singular", locale: locale)
                : formatted(
                    "calculator.adjustment.summary.increase.format",
                    result.adjustmentCount,
                    locale: locale
                )
        case .decrease:
            return result.adjustmentCount == 1
                ? localized("calculator.adjustment.summary.decrease.singular", locale: locale)
                : formatted(
                    "calculator.adjustment.summary.decrease.format",
                    result.adjustmentCount,
                    locale: locale
                )
        }
    }

    private static func oneRowStep(_ step: EvenStitchStep, locale: Locale) -> String {
        switch AdjustmentStepText.token(for: step) {
        case .edge(let count):
            return formatted("calculator.adjustment.step.edge.format", count, locale: locale)
        case .work(1):
            return localized("calculator.adjustment.step.work.singular", locale: locale)
        case .work(let count):
            return formatted("calculator.adjustment.step.work.format", count, locale: locale)
        case .increaseOne:
            return localized("calculator.adjustment.step.increaseOne", locale: locale)
        case .decreaseOne:
            return localized("calculator.adjustment.step.decreaseOne", locale: locale)
        }
    }

    private static func rowInterval(_ result: RowIntervalAdjustmentResult, locale: Locale) -> String {
        if result.minimumInterval == result.maximumInterval {
            return formatted(
                "calculator.adjustment.rows.interval.exact.format",
                result.minimumInterval,
                locale: locale
            )
        }
        return formatted(
            "calculator.adjustment.rows.interval.range.format",
            result.minimumInterval,
            result.maximumInterval,
            locale: locale
        )
    }

    private static func unitName(_ unit: GaugeLengthUnit, locale: Locale) -> String {
        localized(
            unit == .centimeters
                ? "calculator.gauge.unit.centimeters"
                : "calculator.gauge.unit.inches",
            locale: locale
        )
    }

    private static func footer(locale: Locale) -> [String] {
        [
            localized("calculator.share.attribution", locale: locale),
            CalculatorProductLinks.freeApp.absoluteString,
        ]
    }

    private static func localized(_ key: String, locale: Locale) -> String {
        CalculatorLocalization.string(key, locale: locale)
    }

    private static func formatted(_ key: String, _ value: CVarArg, locale: Locale) -> String {
        let format = localized(key, locale: locale)
        return String.localizedStringWithFormat(format, value)
    }

    private static func formatted(
        _ key: String,
        _ first: CVarArg,
        _ second: CVarArg,
        locale: Locale
    ) -> String {
        let format = localized(key, locale: locale)
        return String.localizedStringWithFormat(format, first, second)
    }

    private static func formatted(
        _ key: String,
        _ first: CVarArg,
        _ second: CVarArg,
        _ third: CVarArg,
        locale: Locale
    ) -> String {
        let format = localized(key, locale: locale)
        return String.localizedStringWithFormat(format, first, second, third)
    }

    private static func formatted(
        _ key: String,
        _ first: CVarArg,
        _ second: CVarArg,
        _ third: CVarArg,
        _ fourth: CVarArg,
        locale: Locale
    ) -> String {
        let format = localized(key, locale: locale)
        return String.localizedStringWithFormat(format, first, second, third, fourth)
    }

    private static func formatted(
        _ key: String,
        _ first: CVarArg,
        _ second: CVarArg,
        _ third: CVarArg,
        _ fourth: CVarArg,
        _ fifth: CVarArg,
        locale: Locale
    ) -> String {
        let format = localized(key, locale: locale)
        return String.localizedStringWithFormat(format, first, second, third, fourth, fifth)
    }
}
