import KnittingCalculatorCore
import SwiftUI

struct GaugeShareSnapshot: Equatable {
    struct Rows: Equatable {
        let sampleLength: Double
        let sampleCount: Double
        let targetLength: Double
        let result: GaugeResult
    }

    let unit: GaugeLengthUnit
    let sampleLength: Double
    let sampleCount: Double
    let targetLength: Double
    let result: GaugeResult
    let rows: Rows?
}

enum GaugeDraftConverter {
    static func convert(
        _ draft: inout GaugeDraft,
        to newUnit: GaugeLengthUnit,
        codec: LocalizedNumberCodec
    ) {
        let oldUnit = draft.unit
        guard oldUnit != newUnit else { return }

        for keyPath in [
            \GaugeDraft.sampleWidth,
            \GaugeDraft.targetWidth,
            \GaugeDraft.sampleHeight,
            \GaugeDraft.targetHeight,
        ] {
            if let value = codec.parseDecimal(draft[keyPath: keyPath]) {
                draft[keyPath: keyPath] = codec.format(
                    GaugeCalculator.convertLength(value, from: oldUnit, to: newUnit)
                )
            }
        }
        draft.unit = newUnit
    }
}

struct GaugeCalculatorScreen: View {
    @EnvironmentObject private var preferences: CalculatorPreferencesStore
    @EnvironmentObject private var ratingCoordinator: RatingRequestCoordinator
    @EnvironmentObject private var ratingRequestContext: RatingRequestContext
    let onShareSnapshotChange: (GaugeShareSnapshot?) -> Void
    @Environment(\.locale) private var locale
    @State private var lastCountedSnapshot: GaugeShareSnapshot?
    @State private var hadValidResult = false
    @State private var showsHelp = false

    init(
        onShareSnapshotChange: @escaping (GaugeShareSnapshot?) -> Void = { _ in }
    ) {
        self.onShareSnapshotChange = onShareSnapshotChange
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("calculator.gauge.unit", selection: unitBinding) {
                    Text("calculator.gauge.unit.centimeters").tag(GaugeLengthUnit.centimeters)
                    Text("calculator.gauge.unit.inches").tag(GaugeLengthUnit.inches)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(Text("calculator.gauge.unit"))
                .accessibilityValue(
                    Text(
                        preferences.gauge.unit == .centimeters
                            ? "calculator.gauge.unit.centimeters"
                            : "calculator.gauge.unit.inches"
                    )
                )

                gaugeCard(
                    title: "calculator.gauge.stitches",
                    fields: [
                        ("calculator.gauge.sampleWidth", fieldBinding(\.sampleWidth), .decimal, stitchesWereStarted && GaugeCalculator.fieldNeedsValidation(stitchesInput?.sampleLength, groupStarted: true)),
                        ("calculator.gauge.sampleStitches", fieldBinding(\.sampleStitches), .integer, stitchesWereStarted && GaugeCalculator.fieldNeedsValidation(stitchesInput?.sampleCount, groupStarted: true)),
                        ("calculator.gauge.targetWidth", fieldBinding(\.targetWidth), .decimal, stitchesWereStarted && GaugeCalculator.fieldNeedsValidation(stitchesInput?.targetLength, groupStarted: true)),
                    ],
                    result: stitchesResult,
                    showsResultActions: true
                )

                gaugeCard(
                    title: "calculator.gauge.rows.optional",
                    fields: [
                        ("calculator.gauge.sampleHeight", fieldBinding(\.sampleHeight), .decimal, rowsWereStarted && GaugeCalculator.fieldNeedsValidation(rowsInput?.sampleLength, groupStarted: true)),
                        ("calculator.gauge.sampleRows", fieldBinding(\.sampleRows), .integer, rowsWereStarted && GaugeCalculator.fieldNeedsValidation(rowsInput?.sampleCount, groupStarted: true)),
                        ("calculator.gauge.targetHeight", fieldBinding(\.targetHeight), .decimal, rowsWereStarted && GaugeCalculator.fieldNeedsValidation(rowsInput?.targetLength, groupStarted: true)),
                    ],
                    result: rowsResult
                )
            }
            .padding()
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle("calculator.gauge.title")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsHelp = true
                } label: {
                    Label("calculator.help.title", systemImage: "questionmark.circle")
                }
                .accessibilityLabel(Text("calculator.help.title"))
            }
        }
        .sheet(isPresented: $showsHelp) {
            CalculatorHelpSheet(tool: .gauge)
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
            ratingRequestContext.considerRequest(using: ratingCoordinator)
        }
    }

    private var codec: LocalizedNumberCodec {
        LocalizedNumberCodec(locale: locale)
    }

    private var unitBinding: Binding<GaugeLengthUnit> {
        Binding(
            get: { preferences.gauge.unit },
            set: { newUnit in
                var draft = preferences.gauge
                GaugeDraftConverter.convert(&draft, to: newUnit, codec: codec)
                preferences.gauge = draft
            }
        )
    }

    private func fieldBinding(_ keyPath: WritableKeyPath<GaugeDraft, String>) -> Binding<String> {
        Binding(
            get: { preferences.gauge[keyPath: keyPath] },
            set: { newValue in preferences.gauge[keyPath: keyPath] = newValue }
        )
    }

    private var stitchesWereStarted: Bool {
        [preferences.gauge.sampleWidth, preferences.gauge.sampleStitches, preferences.gauge.targetWidth]
            .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var rowsWereStarted: Bool {
        [preferences.gauge.sampleHeight, preferences.gauge.sampleRows, preferences.gauge.targetHeight]
            .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var stitchesInput: GaugeInput? {
        guard let sampleLength = codec.parseDecimal(preferences.gauge.sampleWidth),
              let sampleCount = codec.parseDecimal(preferences.gauge.sampleStitches),
              let targetLength = codec.parseDecimal(preferences.gauge.targetWidth) else {
            return nil
        }
        return GaugeInput(
            sampleLength: sampleLength,
            sampleCount: sampleCount,
            targetLength: targetLength
        )
    }

    private var rowsInput: GaugeInput? {
        guard let sampleLength = codec.parseDecimal(preferences.gauge.sampleHeight),
              let sampleCount = codec.parseDecimal(preferences.gauge.sampleRows),
              let targetLength = codec.parseDecimal(preferences.gauge.targetHeight) else {
            return nil
        }
        return GaugeInput(
            sampleLength: sampleLength,
            sampleCount: sampleCount,
            targetLength: targetLength
        )
    }

    private var stitchesResult: GaugeResult? {
        stitchesInput.flatMap(GaugeCalculator.calculate)
    }

    private var rowsResult: GaugeResult? {
        rowsInput.flatMap(GaugeCalculator.calculate)
    }

    private var shareSnapshot: GaugeShareSnapshot? {
        guard let stitchesInput, let result = stitchesResult else { return nil }
        let rows: GaugeShareSnapshot.Rows?
        if let rowsInput, let rowsResult {
            rows = GaugeShareSnapshot.Rows(
                sampleLength: rowsInput.sampleLength,
                sampleCount: rowsInput.sampleCount,
                targetLength: rowsInput.targetLength,
                result: rowsResult
            )
        } else {
            rows = nil
        }
        return GaugeShareSnapshot(
            unit: preferences.gauge.unit,
            sampleLength: stitchesInput.sampleLength,
            sampleCount: stitchesInput.sampleCount,
            targetLength: stitchesInput.targetLength,
            result: result,
            rows: rows
        )
    }

    private func gaugeCard(
        title: LocalizedStringKey,
        fields: [(LocalizedStringKey, Binding<String>, CalculatorField.InputKind, Bool)],
        result: GaugeResult?,
        showsResultActions: Bool = false
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    CalculatorField(
                        title: field.0,
                        text: field.1,
                        kind: field.2,
                        validationKey: field.3 ? "calculator.gauge.invalidPositive" : nil
                    )
                }

                if let result {
                    resultView(result)
                    if showsResultActions, let shareSnapshot {
                        CalculatorResultActions(
                            text: CalculatorShareText.gauge(shareSnapshot, locale: locale),
                            onSuccessfulAction: {}
                        )
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Text(title)
                .font(.headline)
        }
    }

    private func resultView(_ result: GaugeResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("calculator.gauge.density", value: codec.format(result.density))
            LabeledContent("calculator.gauge.exact", value: codec.format(result.exactCount))
            LabeledContent("calculator.gauge.recommended", value: String(result.recommendedCount))
            Text("calculator.gauge.patternCaution")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("calculator.gauge.result"))
    }
}
