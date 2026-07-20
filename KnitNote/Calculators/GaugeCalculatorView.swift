import Foundation
import SwiftUI

struct GaugeCalculatorView: View {
    private enum GaugeRecommendation {
        case stitches
        case rows
    }

    @Environment(\.locale) private var locale

    @State private var unit: GaugeLengthUnit = .centimeters
    @State private var sampleWidth = ""
    @State private var sampleStitches = ""
    @State private var targetWidth = ""
    @State private var sampleHeight = ""
    @State private var sampleRows = ""
    @State private var targetHeight = ""

    private var stitchResult: GaugeResult? {
        makeResult(length: sampleWidth, count: sampleStitches, target: targetWidth)
    }

    private var rowsWereStarted: Bool {
        [sampleHeight, sampleRows, targetHeight].contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var rowResult: GaugeResult? {
        makeResult(length: sampleHeight, count: sampleRows, target: targetHeight)
    }

    private var stitchesWereStarted: Bool {
        [sampleWidth, sampleStitches, targetWidth].contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Picker("calculator.gauge.unit", selection: $unit) {
                    Text("calculator.gauge.unit.centimeters").tag(GaugeLengthUnit.centimeters)
                    Text("calculator.gauge.unit.inches").tag(GaugeLengthUnit.inches)
                }
                .pickerStyle(.segmented)

                gaugeCard(
                    title: "calculator.gauge.stitches",
                    sampleLengthTitle: "calculator.gauge.sampleWidth",
                    countTitle: "calculator.gauge.sampleStitches",
                    targetLengthTitle: "calculator.gauge.targetWidth",
                    sampleLength: $sampleWidth,
                    count: $sampleStitches,
                    targetLength: $targetWidth,
                    result: stitchResult,
                    wasStarted: stitchesWereStarted,
                    recommendation: .stitches
                )

                gaugeCard(
                    title: "calculator.gauge.rows.optional",
                    sampleLengthTitle: "calculator.gauge.sampleHeight",
                    countTitle: "calculator.gauge.sampleRows",
                    targetLengthTitle: "calculator.gauge.targetHeight",
                    sampleLength: $sampleHeight,
                    count: $sampleRows,
                    targetLength: $targetHeight,
                    result: rowResult,
                    wasStarted: rowsWereStarted,
                    recommendation: .rows
                )
            }
            .frame(maxWidth: 620)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .background(WatercolorBackground())
        .navigationTitle("calculator.gauge.title")
        .onChange(of: unit) { oldUnit, newUnit in
            convertDimensions(from: oldUnit, to: newUnit)
        }
    }

    private func makeResult(length: String, count: String, target: String) -> GaugeResult? {
        guard let sampleLength = parseNumber(length),
              let sampleCount = parseNumber(count),
              let targetLength = parseNumber(target) else {
            return nil
        }

        return GaugeCalculator.calculate(
            GaugeInput(
                sampleLength: sampleLength,
                sampleCount: sampleCount,
                targetLength: targetLength
            )
        )
    }

    private func convertDimensions(from oldUnit: GaugeLengthUnit, to newUnit: GaugeLengthUnit) {
        sampleWidth = convertedLengthString(sampleWidth, from: oldUnit, to: newUnit)
        targetWidth = convertedLengthString(targetWidth, from: oldUnit, to: newUnit)
        sampleHeight = convertedLengthString(sampleHeight, from: oldUnit, to: newUnit)
        targetHeight = convertedLengthString(targetHeight, from: oldUnit, to: newUnit)
    }

    private func convertedLengthString(
        _ text: String,
        from oldUnit: GaugeLengthUnit,
        to newUnit: GaugeLengthUnit
    ) -> String {
        guard let length = parseNumber(text) else { return text }
        return formattedNumber(GaugeCalculator.convertLength(length, from: oldUnit, to: newUnit))
    }

    private func parseNumber(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.isLenient = false

        let decimalSeparator = formatter.decimalSeparator ?? "."
        let alternateDecimalSeparator = decimalSeparator == "." ? "," : "."
        let localizedNumber = trimmed.replacingOccurrences(
            of: alternateDecimalSeparator,
            with: decimalSeparator
        )
        guard let number = formatter.number(from: localizedNumber) else { return nil }

        return number.doubleValue.isFinite ? number.doubleValue : nil
    }

    private func formattedNumber(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 4
        return formatter.string(from: NSNumber(value: value)) ?? ""
    }

    private func fieldNeedsValidation(_ text: String, groupStarted: Bool) -> Bool {
        GaugeCalculator.fieldNeedsValidation(
            parseNumber(text),
            groupStarted: groupStarted
        )
    }

    private func recommendationText(_ result: GaugeResult) -> String {
        let format = String(localized: "calculator.gauge.recommendation.format", locale: locale)
        return String.localizedStringWithFormat(format, result.recommendedCount)
    }

    private func recommendationAccessibilityText(
        _ result: GaugeResult,
        recommendation: GaugeRecommendation
    ) -> String {
        let format = switch recommendation {
        case .stitches:
            String(localized: "calculator.gauge.stitches.recommendation.format", locale: locale)
        case .rows:
            String(localized: "calculator.gauge.rows.recommendation.format", locale: locale)
        }
        return String.localizedStringWithFormat(format, result.recommendedCount)
    }

    private func densityText(
        _ result: GaugeResult,
        recommendation: GaugeRecommendation
    ) -> String {
        let format = switch (recommendation, unit) {
        case (.stitches, .centimeters):
            String(
                localized: "calculator.gauge.stitches.density.centimeters.format",
                locale: locale
            )
        case (.stitches, .inches):
            String(
                localized: "calculator.gauge.stitches.density.inches.format",
                locale: locale
            )
        case (.rows, .centimeters):
            String(
                localized: "calculator.gauge.rows.density.centimeters.format",
                locale: locale
            )
        case (.rows, .inches):
            String(
                localized: "calculator.gauge.rows.density.inches.format",
                locale: locale
            )
        }
        return String.localizedStringWithFormat(format, formattedNumber(result.density))
    }

    private func gaugeCard(
        title: LocalizedStringKey,
        sampleLengthTitle: LocalizedStringKey,
        countTitle: LocalizedStringKey,
        targetLengthTitle: LocalizedStringKey,
        sampleLength: Binding<String>,
        count: Binding<String>,
        targetLength: Binding<String>,
        result: GaugeResult?,
        wasStarted: Bool,
        recommendation: GaugeRecommendation
    ) -> some View {
        WatercolorCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.headline)

                decimalField(sampleLengthTitle, text: sampleLength, groupStarted: wasStarted)
                decimalField(countTitle, text: count, groupStarted: wasStarted)
                decimalField(targetLengthTitle, text: targetLength, groupStarted: wasStarted)

                resultView(
                    result,
                    recommendation: recommendation
                )
            }
        }
    }

    @ViewBuilder
    private func decimalField(
        _ title: LocalizedStringKey,
        text: Binding<String>,
        groupStarted: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
#if os(iOS)
            TextField(title, text: text)
                .keyboardType(.decimalPad)
#else
            TextField(title, text: text)
#endif
            if fieldNeedsValidation(text.wrappedValue, groupStarted: groupStarted) {
                Text("calculator.validation.positive")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func resultView(
        _ result: GaugeResult?,
        recommendation: GaugeRecommendation
    ) -> some View {
        if let result {
            let recommendationText = recommendationText(result)
            let accessibilityText = recommendationAccessibilityText(
                result,
                recommendation: recommendation
            )
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: recommendationText)
                    .font(.title3.weight(.semibold))
                    .accessibilityLabel(Text(verbatim: accessibilityText))

                VStack(alignment: .leading, spacing: 2) {
                    Text("calculator.gauge.density")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: densityText(result, recommendation: recommendation))
                        .monospacedDigit()
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("calculator.gauge.exact")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formattedNumber(result.exactCount))
                        .monospacedDigit()
                }
            }
        }
    }
}
