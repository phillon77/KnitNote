import SwiftUI

public struct ShortRowCalculatorView: View {
    @Environment(\.locale) private var locale
    @FocusState private var inputFocused: Bool
    @State private var gauge = ""
    @State private var height = ""
    @State private var stitches = ""
    @State private var startsOnRightSide = true

    public init() {}

    private var outcome: Result<ShortRowPlan, ShortRowFailure>? {
        guard let rows = ShortRowInput.decimal(gauge, locale: locale),
              let heightCM = ShortRowInput.decimal(height, locale: locale),
              let count = ShortRowInput.stitches(stitches) else { return nil }
        do {
            return .success(try ShortRowCalculator.calculate(stitches: count, rowsPer10cm: rows, heightCM: heightCM))
        } catch let failure as ShortRowFailure {
            return .failure(failure)
        } catch {
            return .failure(.invalidInput)
        }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(t("subtitle")).foregroundStyle(.secondary)
                card {
                    Text(t("inputs")).font(.headline)
                    input("gauge", text: $gauge, integer: false)
                    input("height", text: $height, integer: false)
                    input("stitches", text: $stitches, integer: true)
                    Button(t("sample")) {
                        gauge = "30"
                        height = "2"
                        stitches = "24"
                        inputFocused = false
                    }
                    .accessibilityIdentifier("shortRows.sample")
                    Text(t("sample.note")).font(.caption).foregroundStyle(.secondary)
                    Text(t("firstFace")).font(.subheadline.weight(.medium))
                    Picker(t("firstFace"), selection: $startsOnRightSide) {
                        Text(t("rightSide")).tag(true)
                        Text(t("wrongSide")).tag(false)
                    }
                    .pickerStyle(.menu)
                }
                if let outcome {
                    switch outcome {
                    case .success(let plan):
                        result(plan)
                    case .failure(let failure):
                        Label(t(failureKey(failure)), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("shortRows.error")
                    }
                } else {
                    Text(t("empty")).foregroundStyle(.secondary)
                }
                card {
                    Text(t("setup.title")).font(.headline)
                    Text(t("setup"))
                    Text(t("technique")).font(.callout).foregroundStyle(.secondary)
                    Link(t("tutorial"), destination: URL(string: "https://www.purlsoho.com/create/short-rows-wrap-turn/")!)
                }
            }
            .frame(maxWidth: 620)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
#if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(t("done")) { inputFocused = false }
            }
        }
#endif
        .background(Color.accentColor.opacity(0.035))
        .navigationTitle(t("title"))
        .accessibilityIdentifier("shortRows.screen")
    }

    private func input(_ key: String, text: Binding<String>, integer: Bool) -> some View {
        let invalid = !text.wrappedValue.isEmpty && (integer
            ? ShortRowInput.stitches(text.wrappedValue) == nil
            : ShortRowInput.decimal(text.wrappedValue, locale: locale) == nil)
        return VStack(alignment: .leading, spacing: 6) {
            Text(t(key)).font(.subheadline.weight(.medium))
            TextField(t(key), text: text)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
#if os(iOS)
                .keyboardType(integer ? .numberPad : .decimalPad)
#endif
                .frame(minHeight: 44)
                .accessibilityLabel(t(key))
                .accessibilityIdentifier("shortRows.\(key)")
            if invalid {
                Text(t(integer ? "validation.stitches" : "validation.decimal"))
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func result(_ plan: ShortRowPlan) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            card {
                Text(t("result")).font(.headline)
                Text(f("summary", plan.shapingRows, plan.pairs.count)).font(.title3.bold())
                Text(f("actual", number(plan.actualHeightCM))).font(.headline)
                if let target = ShortRowInput.decimal(height, locale: locale) {
                    Text(f("target", number(target))).foregroundStyle(.secondary)
                }
                Text(t("rounding")).font(.callout).foregroundStyle(.secondary)
                Text(f("distribution", plan.segments.map { String($0) }.joined(separator: " · ")))
                Text(t("reserve")).font(.caption).foregroundStyle(.secondary)
                ShortRowDiagram(plan: plan, locale: locale)
            }
            card {
                Text(t("steps")).font(.headline)
                // The setup remains visible with the instructions, before the first row.
                Text(t("setup")).font(.callout).foregroundStyle(.secondary)
                ForEach(plan.pairs.indices, id: \.self) { index in
                    let pair = plan.pairs[index]
                    VStack(alignment: .leading, spacing: 8) {
                        Text(f(startsOnRightSide ? "out.knit" : "out.purl",
                               index * 2 + 1, pair.workedStitches, pair.unworkedStitches))
                        Text(f(startsOnRightSide ? "back.purl" : "back.knit",
                               index * 2 + 2, pair.workedStitches))
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                }
                Text(f(startsOnRightSide ? "finish.knit" : "finish.purl", plan.shapingRows + 1, plan.stitches))
                    .fontWeight(.medium)
            }
        }
        .accessibilityIdentifier("shortRows.result")
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.background, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.primary.opacity(0.08)))
    }

    private func t(_ key: String) -> String { ShortRowStrings.text(key, locale: locale) }
    private func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: locale, arguments: args)
    }
    private func number(_ value: Double) -> String {
        value.formatted(.number.locale(locale).precision(.fractionLength(0...3)))
    }
    private func failureKey(_ failure: ShortRowFailure) -> String {
        switch failure {
        case .invalidInput: "failure.invalidInput"
        case .heightTooSmall: "failure.heightTooSmall"
        case .tooManyRows: "failure.tooManyRows"
        case .insufficientStitches: "failure.insufficientStitches"
        }
    }
}
