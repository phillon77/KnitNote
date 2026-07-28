import SwiftUI

struct RowIntervalShareSnapshot: Equatable {
    let input: RowIntervalAdjustmentInput
    let result: RowIntervalAdjustmentResult
}

struct RowIntervalAdjustmentView: View {
    private typealias IntegerInput = EvenStitchAdjustmentInputParseResult

    @ObservedObject var preferences: CalculatorPreferencesStore
    let onShareSnapshotChange: (RowIntervalShareSnapshot?) -> Void
    @Environment(\.locale) private var locale
    @State private var lastCountedSnapshot: RowIntervalShareSnapshot?

    init(
        preferences: CalculatorPreferencesStore,
        onShareSnapshotChange: @escaping (RowIntervalShareSnapshot?) -> Void = { _ in }
    ) {
        self.preferences = preferences
        self.onShareSnapshotChange = onShareSnapshotChange
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Picker(
                            "calculator.adjustment.rows.operation",
                            selection: fieldBinding(\.operation)
                        ) {
                            Text("calculator.adjustment.rows.operation.increase")
                                .tag(RowIntervalAdjustmentOperation.increase)
                            Text("calculator.adjustment.rows.operation.decrease")
                                .tag(RowIntervalAdjustmentOperation.decrease)
                        }
                        .pickerStyle(.segmented)

                        CalculatorField(
                            title: "calculator.adjustment.rows.totalRows",
                            text: fieldBinding(\.totalRows),
                            kind: .integer,
                            validationKey: fieldNeedsValidation(totalRowsInput)
                                ? "calculator.adjustment.validation.positiveInteger"
                                : nil
                        )
                        CalculatorField(
                            title: "calculator.adjustment.rows.totalStitches",
                            text: fieldBinding(\.totalStitches),
                            kind: .integer,
                            validationKey: fieldNeedsValidation(totalStitchesInput)
                                ? "calculator.adjustment.validation.positiveInteger"
                                : nil
                        )

                        stylePicker
                    }
                    .padding(.top, 4)
                } label: {
                    Text("calculator.adjustment.rows.input.title")
                        .font(.headline)
                }

                resultView
            }
            .padding()
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear {
            onShareSnapshotChange(shareSnapshot)
        }
        .onChange(of: shareSnapshot) { _, newValue in
            onShareSnapshotChange(newValue)
            guard let newValue, newValue != lastCountedSnapshot else { return }
            lastCountedSnapshot = newValue
            preferences.recordValidCalculation()
        }
    }

    private var inputWasStarted: Bool {
        [preferences.rowInterval.totalRows, preferences.rowInterval.totalStitches]
            .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var totalRowsInput: IntegerInput {
        EvenStitchAdjustmentInputParser.parse(preferences.rowInterval.totalRows, locale: locale)
    }

    private var totalStitchesInput: IntegerInput {
        EvenStitchAdjustmentInputParser.parse(preferences.rowInterval.totalStitches, locale: locale)
    }

    private var input: RowIntervalAdjustmentInput? {
        guard case .valid(let totalRows) = totalRowsInput,
              case .valid(let totalStitches) = totalStitchesInput else {
            return nil
        }
        return RowIntervalAdjustmentInput(
            totalRows: totalRows,
            totalStitches: totalStitches,
            operation: preferences.rowInterval.operation,
            style: preferences.rowInterval.style
        )
    }

    private var calculation: Result<RowIntervalAdjustmentResult, RowIntervalAdjustmentFailure>? {
        if case .exceedsSupportedLimit = totalRowsInput { return .failure(.exceedsSupportedLimit) }
        if case .exceedsSupportedLimit = totalStitchesInput { return .failure(.exceedsSupportedLimit) }
        guard let input else { return nil }

        do {
            return .success(try RowIntervalAdjustmentCalculator.calculate(input))
        } catch let failure as RowIntervalAdjustmentFailure {
            return .failure(failure)
        } catch {
            return .failure(.invalidCounts)
        }
    }

    private var shareSnapshot: RowIntervalShareSnapshot? {
        guard let input, case .success(let result) = calculation else { return nil }
        return RowIntervalShareSnapshot(input: input, result: result)
    }

    @ViewBuilder
    private var stylePicker: some View {
        ViewThatFits(in: .horizontal) {
            Picker("calculator.adjustment.rows.style", selection: fieldBinding(\.style)) {
                Text("calculator.adjustment.rows.style.singleSide")
                    .tag(RowIntervalAdjustmentStyle.singleSide)
                Text("calculator.adjustment.rows.style.bothSides")
                    .tag(RowIntervalAdjustmentStyle.bothSides)
            }
            .pickerStyle(.segmented)

            Picker("calculator.adjustment.rows.style", selection: fieldBinding(\.style)) {
                Text("calculator.adjustment.rows.style.singleSide")
                    .tag(RowIntervalAdjustmentStyle.singleSide)
                Text("calculator.adjustment.rows.style.bothSides")
                    .tag(RowIntervalAdjustmentStyle.bothSides)
            }
            .pickerStyle(.menu)
        }
        .accessibilityLabel(Text("calculator.adjustment.rows.style"))
    }

    @ViewBuilder
    private var resultView: some View {
        if let calculation {
            switch calculation {
            case .success(let result):
                successfulResultView(result)
            case .failure(let failure):
                failureView(failure)
            }
        }
    }

    private func successfulResultView(_ result: RowIntervalAdjustmentResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: summaryText(result))
                .font(.title3.weight(.semibold))

            LabeledContent(
                "calculator.adjustment.rows.eventCount",
                value: String(result.eventCount)
            )
            LabeledContent(
                "calculator.adjustment.rows.stitchesPerEvent",
                value: String(result.stitchesPerEvent)
            )
            LabeledContent(
                "calculator.adjustment.rows.interval",
                value: intervalText(result)
            )

            DisclosureGroup("calculator.adjustment.rows.details.show") {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(result.adjustmentRows.indices, id: \.self) { index in
                        Text(verbatim: adjustmentRowText(result.adjustmentRows[index]))
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: accessibilitySummary(result)))
    }

    private func failureView(_ failure: RowIntervalAdjustmentFailure) -> some View {
        Text(failureKey(failure))
            .foregroundStyle(.red)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(failureKey(failure)))
    }

    private func fieldBinding(_ keyPath: WritableKeyPath<RowIntervalAdjustmentDraft, String>) -> Binding<String> {
        Binding(
            get: { preferences.rowInterval[keyPath: keyPath] },
            set: { preferences.rowInterval[keyPath: keyPath] = $0 }
        )
    }

    private func fieldBinding(
        _ keyPath: WritableKeyPath<RowIntervalAdjustmentDraft, RowIntervalAdjustmentOperation>
    ) -> Binding<RowIntervalAdjustmentOperation> {
        Binding(
            get: { preferences.rowInterval[keyPath: keyPath] },
            set: { preferences.rowInterval[keyPath: keyPath] = $0 }
        )
    }

    private func fieldBinding(
        _ keyPath: WritableKeyPath<RowIntervalAdjustmentDraft, RowIntervalAdjustmentStyle>
    ) -> Binding<RowIntervalAdjustmentStyle> {
        Binding(
            get: { preferences.rowInterval[keyPath: keyPath] },
            set: { preferences.rowInterval[keyPath: keyPath] = $0 }
        )
    }

    private func fieldNeedsValidation(_ input: IntegerInput) -> Bool {
        guard inputWasStarted else { return false }
        return switch input {
        case .empty, .invalid: true
        case .valid, .exceedsSupportedLimit: false
        }
    }

    private func summaryText(_ result: RowIntervalAdjustmentResult) -> String {
        let exact = result.minimumInterval == result.maximumInterval
        let key: String
        switch (result.operation, result.style, exact) {
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
        return String.localizedStringWithFormat(format, intervalText(result), result.eventCount)
    }

    private func intervalText(_ result: RowIntervalAdjustmentResult) -> String {
        if result.minimumInterval == result.maximumInterval {
            return formattedText(
                "calculator.adjustment.rows.interval.exact.format",
                result.minimumInterval
            )
        }
        let format = String(
            localized: "calculator.adjustment.rows.interval.range.format",
            locale: locale
        )
        return String.localizedStringWithFormat(format, result.minimumInterval, result.maximumInterval)
    }

    private func adjustmentRowText(_ row: Int) -> String {
        formattedText("calculator.adjustment.rows.detail.format", row)
    }

    private func accessibilitySummary(_ result: RowIntervalAdjustmentResult) -> String {
        let format = String(
            localized: "calculator.adjustment.rows.accessibility.summary.format",
            locale: locale
        )
        return String.localizedStringWithFormat(
            format,
            summaryText(result),
            result.eventCount,
            result.stitchesPerEvent,
            intervalText(result)
        )
    }

    private func failureKey(_ failure: RowIntervalAdjustmentFailure) -> LocalizedStringKey {
        switch failure {
        case .invalidCounts: "calculator.adjustment.rows.failure.invalidCounts"
        case .exceedsSupportedLimit: "calculator.adjustment.rows.failure.exceedsSupportedLimit"
        case .symmetricRequiresEvenStitches:
            "calculator.adjustment.rows.failure.symmetricRequiresEvenStitches"
        case .insufficientRows: "calculator.adjustment.rows.failure.insufficientRows"
        }
    }

    private func formattedText(_ key: String, _ value: Int) -> String {
        let format = String(localized: String.LocalizationValue(key), locale: locale)
        return String.localizedStringWithFormat(format, value)
    }
}
