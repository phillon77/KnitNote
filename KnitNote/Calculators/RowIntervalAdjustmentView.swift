import Foundation
import SwiftUI

struct RowIntervalAdjustmentView: View {
    private typealias IntegerInput = EvenStitchAdjustmentInputParseResult

    @Environment(\.locale) private var locale

    @State private var totalRows = ""
    @State private var totalStitches = ""
    @State private var operation = RowIntervalAdjustmentOperation.decrease
    @State private var style = RowIntervalAdjustmentStyle.singleSide

    private var inputWasStarted: Bool {
        [totalRows, totalStitches].contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var totalRowsInput: IntegerInput {
        parseInteger(totalRows)
    }

    private var totalStitchesInput: IntegerInput {
        parseInteger(totalStitches)
    }

    private var result: Result<RowIntervalAdjustmentResult, RowIntervalAdjustmentFailure>? {
        if case .exceedsSupportedLimit = totalRowsInput {
            return .failure(.exceedsSupportedLimit)
        }
        if case .exceedsSupportedLimit = totalStitchesInput {
            return .failure(.exceedsSupportedLimit)
        }
        guard case .valid(let rows) = totalRowsInput,
              case .valid(let stitches) = totalStitchesInput else {
            return nil
        }

        do {
            return .success(
                try RowIntervalAdjustmentCalculator.calculate(
                    .init(
                        totalRows: rows,
                        totalStitches: stitches,
                        operation: operation,
                        style: style
                    )
                )
            )
        } catch let failure as RowIntervalAdjustmentFailure {
            return .failure(failure)
        } catch {
            return .failure(.invalidCounts)
        }
    }

    var body: some View {
        WatercolorCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("calculator.adjustment.rows.input.title")
                    .font(.headline)

                Picker("calculator.adjustment.rows.operation", selection: $operation) {
                    Text("calculator.adjustment.rows.operation.increase")
                        .tag(RowIntervalAdjustmentOperation.increase)
                    Text("calculator.adjustment.rows.operation.decrease")
                        .tag(RowIntervalAdjustmentOperation.decrease)
                }
                .pickerStyle(.segmented)

                integerField(
                    "calculator.adjustment.rows.totalRows",
                    text: $totalRows
                )
                integerField(
                    "calculator.adjustment.rows.totalStitches",
                    text: $totalStitches
                )

                Picker("calculator.adjustment.rows.style", selection: $style) {
                    Text("calculator.adjustment.rows.style.singleSide")
                        .tag(RowIntervalAdjustmentStyle.singleSide)
                    Text("calculator.adjustment.rows.style.bothSides")
                        .tag(RowIntervalAdjustmentStyle.bothSides)
                }
                .pickerStyle(.menu)
            }
        }

        resultView
    }

    @ViewBuilder
    private func integerField(
        _ title: LocalizedStringKey,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
#if os(iOS)
            TextField(title, text: text)
                .keyboardType(.numberPad)
#else
            TextField(title, text: text)
#endif

            if fieldNeedsValidation(text.wrappedValue) {
                Text("calculator.adjustment.validation.positiveInteger")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var resultView: some View {
        if let result {
            switch result {
            case .success(let adjustment):
                successfulResultView(adjustment)
            case .failure(let failure):
                failureView(failure)
            }
        }
    }

    private func successfulResultView(_ adjustment: RowIntervalAdjustmentResult) -> some View {
        let summary = summaryText(adjustment)

        return WatercolorCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: summary)
                    .font(.title3.weight(.semibold))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: summary))

                DisclosureGroup("calculator.adjustment.rows.details.show") {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(adjustment.adjustmentRows.indices, id: \.self) { index in
                            Text(verbatim: detailText(adjustment.adjustmentRows[index]))
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    private func failureView(_ failure: RowIntervalAdjustmentFailure) -> some View {
        let message = failureText(failure)

        return WatercolorCard {
            Text(verbatim: message)
                .foregroundStyle(.red)
                .accessibilityLabel(Text(verbatim: message))
        }
    }

    private func parseInteger(_ text: String) -> IntegerInput {
        EvenStitchAdjustmentInputParser.parse(text, locale: locale)
    }

    private func fieldNeedsValidation(_ text: String) -> Bool {
        guard inputWasStarted else { return false }
        switch parseInteger(text) {
        case .empty, .invalid:
            return true
        case .valid, .exceedsSupportedLimit:
            return false
        }
    }

    private func summaryText(_ result: RowIntervalAdjustmentResult) -> String {
        let interval = intervalText(result)
        let key: String

        switch (result.operation, result.style, result.minimumInterval == result.maximumInterval) {
        case (.increase, .singleSide, true):
            key = "calculator.adjustment.rows.summary.increase.singleSide.exact.format"
        case (.increase, .singleSide, false):
            key = "calculator.adjustment.rows.summary.increase.singleSide.range.format"
        case (.increase, .bothSides, true):
            key = "calculator.adjustment.rows.summary.increase.bothSides.exact.format"
        case (.increase, .bothSides, false):
            key = "calculator.adjustment.rows.summary.increase.bothSides.range.format"
        case (.decrease, .singleSide, true):
            key = "calculator.adjustment.rows.summary.decrease.singleSide.exact.format"
        case (.decrease, .singleSide, false):
            key = "calculator.adjustment.rows.summary.decrease.singleSide.range.format"
        case (.decrease, .bothSides, true):
            key = "calculator.adjustment.rows.summary.decrease.bothSides.exact.format"
        case (.decrease, .bothSides, false):
            key = "calculator.adjustment.rows.summary.decrease.bothSides.range.format"
        }

        let format = String(localized: String.LocalizationValue(key), locale: locale)
        return String.localizedStringWithFormat(format, interval, result.eventCount)
    }

    private func intervalText(_ result: RowIntervalAdjustmentResult) -> String {
        if result.minimumInterval == 1,
           result.maximumInterval == 1 {
            return String(
                localized: "calculator.adjustment.rows.interval.everyRow",
                locale: locale
            )
        }

        if result.minimumInterval == result.maximumInterval {
            return formattedText(
                "calculator.adjustment.rows.interval.exact.format",
                result.minimumInterval
            )
        }

        let range = intervalRangeText(
            minimum: result.minimumInterval,
            maximum: result.maximumInterval
        )
        let format = String(
            localized: "calculator.adjustment.rows.interval.range.format",
            locale: locale
        )
        return String.localizedStringWithFormat(format, range)
    }

    private func intervalRangeText(minimum: Int, maximum: Int) -> String {
        let format = String(
            localized: "calculator.adjustment.rows.range.format",
            locale: locale
        )
        return String.localizedStringWithFormat(format, minimum, maximum)
    }

    private func detailText(_ row: Int) -> String {
        formattedText("calculator.adjustment.rows.detail.format", row)
    }

    private func failureText(_ failure: RowIntervalAdjustmentFailure) -> String {
        switch failure {
        case .invalidCounts:
            return String(
                localized: "calculator.adjustment.validation.positiveInteger",
                locale: locale
            )
        case .exceedsSupportedLimit:
            return formattedText(
                "calculator.adjustment.rows.failure.exceedsSupportedLimit.format",
                RowIntervalAdjustmentCalculator.maximumSupportedValue
            )
        case .symmetricRequiresEvenStitches:
            return String(
                localized: "calculator.adjustment.rows.failure.symmetricEven",
                locale: locale
            )
        case .insufficientRows:
            return String(
                localized: "calculator.adjustment.rows.failure.insufficientRows",
                locale: locale
            )
        }
    }

    private func formattedText(_ key: String, _ value: Int) -> String {
        let format = String(localized: String.LocalizationValue(key), locale: locale)
        return String.localizedStringWithFormat(format, value)
    }
}
