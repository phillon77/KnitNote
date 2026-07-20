import Foundation
import SwiftUI

struct EvenStitchAdjustmentCalculatorView: View {
    private typealias IntegerInput = EvenStitchAdjustmentInputParseResult

    private enum DistributionMode: String, CaseIterable, Identifiable {
        case oneRow
        case acrossRows

        var id: Self { self }
    }

    @Environment(\.locale) private var locale

    @State private var distributionMode = DistributionMode.oneRow
    @State private var currentStitches = ""
    @State private var targetStitches = ""
    @State private var reservesEdgeStitches = true

    private var inputWasStarted: Bool {
        [currentStitches, targetStitches].contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var currentInput: IntegerInput {
        parseInteger(currentStitches)
    }

    private var targetInput: IntegerInput {
        parseInteger(targetStitches)
    }

    private var result: Result<EvenStitchAdjustmentResult, EvenStitchAdjustmentFailure>? {
        if case .exceedsSupportedLimit = currentInput {
            return .failure(.exceedsSupportedLimit)
        }
        if case .exceedsSupportedLimit = targetInput {
            return .failure(.exceedsSupportedLimit)
        }
        guard case .valid(let current) = currentInput,
              case .valid(let target) = targetInput else {
            return nil
        }

        do {
            return .success(
                try EvenStitchAdjustmentCalculator.calculate(
                    .init(
                        current: current,
                        target: target,
                        reservesEdgeStitches: reservesEdgeStitches
                    )
                )
            )
        } catch let failure as EvenStitchAdjustmentFailure {
            return .failure(failure)
        } catch {
            return .failure(.invalidCounts)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Picker("calculator.adjustment.title", selection: $distributionMode) {
                    Text("calculator.adjustment.mode.oneRow")
                        .tag(DistributionMode.oneRow)
                    Text("calculator.adjustment.mode.acrossRows")
                        .tag(DistributionMode.acrossRows)
                }
                .pickerStyle(.segmented)

                switch distributionMode {
                case .oneRow:
                    WatercolorCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("calculator.adjustment.input.title")
                                .font(.headline)

                            integerField(
                                "calculator.adjustment.current",
                                text: $currentStitches
                            )
                            integerField(
                                "calculator.adjustment.target",
                                text: $targetStitches
                            )

                            Toggle(
                                "calculator.adjustment.reservesEdgeStitches",
                                isOn: $reservesEdgeStitches
                            )
                        }
                    }

                    resultView
                case .acrossRows:
                    RowIntervalAdjustmentView()
                }
            }
            .frame(maxWidth: 620)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .background(WatercolorBackground())
        .navigationTitle("calculator.adjustment.title")
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

    private func successfulResultView(_ adjustment: EvenStitchAdjustmentResult) -> some View {
        let summary = summaryText(adjustment)
        let accessibilitySummary = accessibilitySummary(adjustment)
        return WatercolorCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: summary)
                        .font(.title3.weight(.semibold))

                    if let interval = intervalText(adjustment) {
                        Text(verbatim: interval)
                            .foregroundStyle(.secondary)
                    }

                    if adjustment.edgeStitches > 0 {
                        Text("calculator.adjustment.edgeSummary")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: accessibilitySummary))

                if !adjustment.steps.isEmpty {
                    DisclosureGroup("calculator.adjustment.steps.show") {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(adjustment.steps.indices, id: \.self) { index in
                                Text(verbatim: stepText(adjustment.steps[index]))
                            }
                        }
                        .padding(.top, 6)
                    }
                }
            }
        }
    }

    private func failureView(_ failure: EvenStitchAdjustmentFailure) -> some View {
        WatercolorCard {
            Text(verbatim: failureText(failure))
                .foregroundStyle(.red)
                .accessibilityLabel(Text(verbatim: failureText(failure)))
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

    private func summaryText(_ result: EvenStitchAdjustmentResult) -> String {
        let format: String
        switch result.operation {
        case .unchanged:
            return String(localized: "calculator.adjustment.summary.unchanged", locale: locale)
        case .increase:
            if result.adjustmentCount == 1 {
                return String(
                    localized: "calculator.adjustment.summary.increase.singular",
                    locale: locale
                )
            }
            format = String(
                localized: "calculator.adjustment.summary.increase.format",
                locale: locale
            )
        case .decrease:
            if result.adjustmentCount == 1 {
                return String(
                    localized: "calculator.adjustment.summary.decrease.singular",
                    locale: locale
                )
            }
            format = String(
                localized: "calculator.adjustment.summary.decrease.format",
                locale: locale
            )
        }
        return String.localizedStringWithFormat(format, result.adjustmentCount)
    }

    private func intervalText(_ result: EvenStitchAdjustmentResult) -> String? {
        guard let minimum = result.plainSegments.min(),
              let maximum = result.plainSegments.max() else {
            return nil
        }

        if result.operation == .unchanged {
            return nil
        }

        if minimum == maximum {
            if minimum == 0 {
                guard result.operation == .decrease else { return nil }
                return String(
                    localized: "calculator.adjustment.interval.decrease.adjacent",
                    locale: locale
                )
            }

            if minimum == 1 {
                let key = result.operation == .increase
                    ? "calculator.adjustment.interval.increase.singular"
                    : "calculator.adjustment.interval.decrease.singular"
                return String(localized: String.LocalizationValue(key), locale: locale)
            }

            let key = result.operation == .increase
                ? "calculator.adjustment.interval.increase.single.format"
                : "calculator.adjustment.interval.decrease.single.format"
            return formattedText(key, minimum)
        }

        let format: String
        switch result.operation {
        case .increase:
            format = String(
                localized: "calculator.adjustment.interval.increase.format",
                locale: locale
            )
        case .decrease:
            format = String(
                localized: "calculator.adjustment.interval.decrease.format",
                locale: locale
            )
        case .unchanged:
            return nil
        }
        let range = intervalRangeText(minimum: minimum, maximum: maximum)
        return String.localizedStringWithFormat(format, range)
    }

    private func intervalRangeText(minimum: Int, maximum: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false

        let minimumText = formatter.string(from: NSNumber(value: minimum)) ?? ""
        let maximumText = formatter.string(from: NSNumber(value: maximum)) ?? ""
        let format = String(
            localized: "calculator.adjustment.interval.range.format",
            locale: locale
        )
        return String.localizedStringWithFormat(format, minimumText, maximumText)
    }

    private func accessibilitySummary(_ result: EvenStitchAdjustmentResult) -> String {
        let summary = summaryText(result)
        let interval = intervalText(result)
        let edgeSummary = result.edgeStitches > 0
            ? String(localized: "calculator.adjustment.edgeSummary", locale: locale)
            : nil

        switch (interval, edgeSummary) {
        case let (.some(interval), .some(edgeSummary)):
            let format = String(
                localized: "calculator.adjustment.accessibility.summary.full.format",
                locale: locale
            )
            return String.localizedStringWithFormat(format, summary, interval, edgeSummary)
        case let (.some(interval), .none):
            let format = String(
                localized: "calculator.adjustment.accessibility.summary.interval.format",
                locale: locale
            )
            return String.localizedStringWithFormat(format, summary, interval)
        case let (.none, .some(edgeSummary)):
            let format = String(
                localized: "calculator.adjustment.accessibility.summary.edge.format",
                locale: locale
            )
            return String.localizedStringWithFormat(format, summary, edgeSummary)
        case (.none, .none):
            return summary
        }
    }

    private func stepText(_ step: EvenStitchStep) -> String {
        switch step {
        case .edge(let count):
            return formattedText("calculator.adjustment.step.edge.format", count)
        case .knit(1):
            return String(localized: "calculator.adjustment.step.knit.singular", locale: locale)
        case .knit(let count):
            return formattedText("calculator.adjustment.step.knit.format", count)
        case .increaseOne:
            return String(localized: "calculator.adjustment.step.increaseOne", locale: locale)
        case .decreaseOne:
            return String(localized: "calculator.adjustment.step.decreaseOne", locale: locale)
        }
    }

    private func failureText(_ failure: EvenStitchAdjustmentFailure) -> String {
        switch failure {
        case .invalidCounts:
            return String(
                localized: "calculator.adjustment.failure.invalidCounts",
                locale: locale
            )
        case .exceedsSupportedLimit:
            return formattedText(
                "calculator.adjustment.failure.exceedsSupportedLimit.format",
                EvenStitchAdjustmentCalculator.maximumSupportedStitches
            )
        case .cannotPreserveEdges:
            return String(
                localized: "calculator.adjustment.failure.cannotPreserveEdges",
                locale: locale
            )
        case .requiresMultipleRows:
            return String(
                localized: "calculator.adjustment.failure.requiresMultipleRows",
                locale: locale
            )
        }
    }

    private func formattedText(_ key: String, _ value: Int) -> String {
        let format = String(localized: String.LocalizationValue(key), locale: locale)
        return String.localizedStringWithFormat(format, value)
    }
}
