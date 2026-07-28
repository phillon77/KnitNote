import SwiftUI

enum AdjustmentStepToken: Equatable {
    case edge(Int)
    case work(Int)
    case increaseOne
    case decreaseOne
}

enum AdjustmentStepText {
    static func token(for step: EvenStitchStep) -> AdjustmentStepToken {
        switch step {
        case .edge(let count): .edge(count)
        case .knit(let count): .work(count)
        case .increaseOne: .increaseOne
        case .decreaseOne: .decreaseOne
        }
    }
}

struct OneRowShareSnapshot: Equatable {
    let current: Int
    let target: Int
    let reservesEdgeStitches: Bool
    let result: EvenStitchAdjustmentResult
}

struct OneRowAdjustmentView: View {
    private typealias IntegerInput = EvenStitchAdjustmentInputParseResult

    @ObservedObject var preferences: CalculatorPreferencesStore
    @EnvironmentObject private var ratingCoordinator: RatingRequestCoordinator
    let onShareSnapshotChange: (OneRowShareSnapshot?) -> Void
    @Environment(\.locale) private var locale
    @State private var lastCountedSnapshot: OneRowShareSnapshot?
    @State private var hadValidResult = false

    init(
        preferences: CalculatorPreferencesStore,
        onShareSnapshotChange: @escaping (OneRowShareSnapshot?) -> Void = { _ in }
    ) {
        self.preferences = preferences
        self.onShareSnapshotChange = onShareSnapshotChange
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        CalculatorField(
                            title: "calculator.adjustment.current",
                            text: fieldBinding(\.currentStitches),
                            kind: .integer,
                            validationKey: fieldNeedsValidation(currentInput)
                                ? "calculator.adjustment.validation.positiveInteger"
                                : nil
                        )
                        CalculatorField(
                            title: "calculator.adjustment.target",
                            text: fieldBinding(\.targetStitches),
                            kind: .integer,
                            validationKey: fieldNeedsValidation(targetInput)
                                ? "calculator.adjustment.validation.positiveInteger"
                                : nil
                        )
                        Toggle(
                            "calculator.adjustment.reservesEdgeStitches",
                            isOn: fieldBinding(\.reservesEdgeStitches)
                        )
                        .accessibilityHint(Text("calculator.adjustment.reservesEdgeStitches.hint"))
                    }
                    .padding(.top, 4)
                } label: {
                    Text("calculator.adjustment.input.title")
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
            guard let newValue else { return }
            hadValidResult = true
            guard newValue != lastCountedSnapshot else { return }
            lastCountedSnapshot = newValue
            preferences.recordValidCalculation()
        }
        .onDisappear {
            guard hadValidResult else { return }
            ratingCoordinator.considerRequest()
        }
    }

    private var inputWasStarted: Bool {
        [preferences.oneRow.currentStitches, preferences.oneRow.targetStitches]
            .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var currentInput: IntegerInput {
        EvenStitchAdjustmentInputParser.parse(preferences.oneRow.currentStitches, locale: locale)
    }

    private var targetInput: IntegerInput {
        EvenStitchAdjustmentInputParser.parse(preferences.oneRow.targetStitches, locale: locale)
    }

    private var calculation: Result<EvenStitchAdjustmentResult, EvenStitchAdjustmentFailure>? {
        if case .exceedsSupportedLimit = currentInput { return .failure(.exceedsSupportedLimit) }
        if case .exceedsSupportedLimit = targetInput { return .failure(.exceedsSupportedLimit) }
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
                        reservesEdgeStitches: preferences.oneRow.reservesEdgeStitches
                    )
                )
            )
        } catch let failure as EvenStitchAdjustmentFailure {
            return .failure(failure)
        } catch {
            return .failure(.invalidCounts)
        }
    }

    private var shareSnapshot: OneRowShareSnapshot? {
        guard case .valid(let current) = currentInput,
              case .valid(let target) = targetInput,
              case .success(let result) = calculation else {
            return nil
        }
        return OneRowShareSnapshot(
            current: current,
            target: target,
            reservesEdgeStitches: preferences.oneRow.reservesEdgeStitches,
            result: result
        )
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

    private func successfulResultView(_ result: EvenStitchAdjustmentResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            resultSummaryView(result)

            if let shareSnapshot {
                CalculatorResultActions(
                    text: CalculatorShareText.oneRow(shareSnapshot, locale: locale),
                    onSuccessfulAction: {}
                )
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func resultSummaryView(_ result: EvenStitchAdjustmentResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: summaryText(result))
                .font(.title3.weight(.semibold))

            Text(
                result.edgeStitches > 0
                    ? "calculator.adjustment.edgeSummary.reserved"
                    : "calculator.adjustment.edgeSummary.notReserved"
            )
            .foregroundStyle(.secondary)

            if !result.steps.isEmpty {
                DisclosureGroup("calculator.adjustment.steps.show") {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(result.steps.indices, id: \.self) { index in
                            Text(verbatim: stepText(result.steps[index]))
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: accessibilitySummary(result)))
    }

    private func failureView(_ failure: EvenStitchAdjustmentFailure) -> some View {
        Text(failureKey(failure))
            .foregroundStyle(.red)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(failureKey(failure)))
    }

    private func fieldBinding(_ keyPath: WritableKeyPath<OneRowAdjustmentDraft, String>) -> Binding<String> {
        Binding(
            get: { preferences.oneRow[keyPath: keyPath] },
            set: { preferences.oneRow[keyPath: keyPath] = $0 }
        )
    }

    private func fieldBinding(_ keyPath: WritableKeyPath<OneRowAdjustmentDraft, Bool>) -> Binding<Bool> {
        Binding(
            get: { preferences.oneRow[keyPath: keyPath] },
            set: { preferences.oneRow[keyPath: keyPath] = $0 }
        )
    }

    private func fieldNeedsValidation(_ input: IntegerInput) -> Bool {
        guard inputWasStarted else { return false }
        return switch input {
        case .empty, .invalid: true
        case .valid, .exceedsSupportedLimit: false
        }
    }

    private func summaryText(_ result: EvenStitchAdjustmentResult) -> String {
        let key: String
        switch result.operation {
        case .unchanged:
            key = "calculator.adjustment.summary.unchanged"
            return String(localized: String.LocalizationValue(key), locale: locale)
        case .increase:
            key = result.adjustmentCount == 1
                ? "calculator.adjustment.summary.increase.singular"
                : "calculator.adjustment.summary.increase.format"
        case .decrease:
            key = result.adjustmentCount == 1
                ? "calculator.adjustment.summary.decrease.singular"
                : "calculator.adjustment.summary.decrease.format"
        }
        return formattedText(key, result.adjustmentCount)
    }

    private func accessibilitySummary(_ result: EvenStitchAdjustmentResult) -> String {
        let edgeKey = result.edgeStitches > 0
            ? "calculator.adjustment.edgeSummary.reserved"
            : "calculator.adjustment.edgeSummary.notReserved"
        let edgeSummary = String(localized: String.LocalizationValue(edgeKey), locale: locale)
        let format = String(
            localized: "calculator.adjustment.accessibility.summary.edge.format",
            locale: locale
        )
        return String.localizedStringWithFormat(format, summaryText(result), edgeSummary)
    }

    private func stepText(_ step: EvenStitchStep) -> String {
        switch AdjustmentStepText.token(for: step) {
        case .edge(let count):
            formattedText("calculator.adjustment.step.edge.format", count)
        case .work(1):
            String(localized: "calculator.adjustment.step.work.singular", locale: locale)
        case .work(let count):
            formattedText("calculator.adjustment.step.work.format", count)
        case .increaseOne:
            String(localized: "calculator.adjustment.step.increaseOne", locale: locale)
        case .decreaseOne:
            String(localized: "calculator.adjustment.step.decreaseOne", locale: locale)
        }
    }

    private func failureKey(_ failure: EvenStitchAdjustmentFailure) -> LocalizedStringKey {
        switch failure {
        case .invalidCounts: "calculator.adjustment.failure.invalidCounts"
        case .exceedsSupportedLimit: "calculator.adjustment.failure.exceedsSupportedLimit"
        case .cannotPreserveEdges: "calculator.adjustment.failure.cannotPreserveEdges"
        case .requiresMultipleRows: "calculator.adjustment.failure.requiresMultipleRows"
        }
    }

    private func formattedText(_ key: String, _ value: Int) -> String {
        let format = String(localized: String.LocalizationValue(key), locale: locale)
        return String.localizedStringWithFormat(format, value)
    }
}
