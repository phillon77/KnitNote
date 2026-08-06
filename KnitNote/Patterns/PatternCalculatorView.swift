import SwiftUI

struct PatternCalculatorView: View {
    @Environment(\.locale) private var locale
    @Binding var state: PatternCalculatorState

#if os(macOS)
    @FocusState private var hasKeyboardFocus: Bool
#endif

    private var rows: [[PatternCalculatorButton]] {
        [
            [
                .utility("AC", .clear, "patterns.calculator.clear"),
                .utility("±", .toggleSign, "patterns.calculator.toggleSign"),
                .utility("%", .percent, "patterns.calculator.percent"),
                .operation("÷", .divide, "patterns.calculator.divide"),
            ],
            [
                .digit(7),
                .digit(8),
                .digit(9),
                .operation("×", .multiply, "patterns.calculator.multiply"),
            ],
            [
                .digit(4),
                .digit(5),
                .digit(6),
                .operation("−", .subtract, "patterns.calculator.subtract"),
            ],
            [
                .digit(1),
                .digit(2),
                .digit(3),
                .operation("+", .add, "patterns.calculator.add"),
            ],
            [
                .digit(0, columnSpan: 2),
                .utility(decimalSeparator, .decimal, LocalizedStringKey(decimalSeparator)),
                .operation("=", nil, "patterns.calculator.equals", key: .equals),
            ],
        ]
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(displayText)
                .font(.system(size: 42, weight: .medium, design: .rounded))
                .foregroundStyle(WatercolorTheme.ink)
                .minimumScaleFactor(0.45)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 54, alignment: .trailing)
                .accessibilityLabel(Text("patterns.calculator.result"))
                .accessibilityValue(Text(displayText))

            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(row) { button in
                            Button {
                                let key = button.key
                                state.press(key)
                            } label: {
                                Text(button.label)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(WatercolorTheme.ink)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .background(button.background(isPending: button.isPending(for: state.pendingOperationForDisplay)))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(
                                        button.isPending(for: state.pendingOperationForDisplay) ? WatercolorTheme.actionBerry : .clear,
                                        lineWidth: button.isPending(for: state.pendingOperationForDisplay) ? 3 : 0
                                    )
                            }
                            .gridCellColumns(button.columnSpan)
                            .accessibilityLabel(Text(button.accessibilityKey))
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(idealWidth: 320, maxWidth: 360)
        .background(WatercolorBackground())
#if os(macOS)
        .focusable()
        .focused($hasKeyboardFocus)
        .onAppear { hasKeyboardFocus = true }
        .onKeyPress(phases: .down) { press in
            if press.key == .return {
                state.press(.equals)
                return .handled
            }
            if press.key == .escape || press.key == .delete {
                state.press(.clear)
                return .handled
            }
            guard let character = press.characters.first,
                  let key = calculatorKey(for: character) else {
                return .ignored
            }
            state.press(key)
            return .handled
        }
#endif
    }

    private var decimalSeparator: String {
        locale.decimalSeparator ?? "."
    }

    private var displayText: String {
        switch state.display {
        case let .number(canonical):
            let separator = locale.decimalSeparator ?? "."
            return canonical.replacingOccurrences(of: ".", with: separator)
        case .error:
            return LocaleAwareText.string("patterns.calculator.error", locale: locale)
        }
    }
}

private enum PatternCalculatorButtonRole {
    case digit
    case utility
    case operation
}

private struct PatternCalculatorButton: Identifiable {
    let label: String
    let key: PatternCalculatorKey
    let role: PatternCalculatorButtonRole
    let accessibilityKey: LocalizedStringKey
    let columnSpan: Int

    var id: String { label }

    var operation: PatternCalculatorOperation? {
        guard role == .operation,
              case let .operation(operation) = key else {
            return nil
        }
        return operation
    }

    func isPending(for pendingOperation: PatternCalculatorOperation?) -> Bool {
        PatternCalculatorButtonHighlight.isActive(
            buttonOperation: operation,
            pendingOperation: pendingOperation
        )
    }

    static func digit(_ value: Int, columnSpan: Int = 1) -> Self {
        .init(
            label: String(value),
            key: .digit(value),
            role: .digit,
            accessibilityKey: LocalizedStringKey(String(value)),
            columnSpan: columnSpan
        )
    }

    static func utility(
        _ label: String,
        _ key: PatternCalculatorKey,
        _ accessibilityKey: LocalizedStringKey
    ) -> Self {
        .init(
            label: label,
            key: key,
            role: .utility,
            accessibilityKey: accessibilityKey,
            columnSpan: 1
        )
    }

    static func operation(
        _ label: String,
        _ operation: PatternCalculatorOperation?,
        _ accessibilityKey: LocalizedStringKey,
        key: PatternCalculatorKey? = nil
    ) -> Self {
        .init(
            label: label,
            key: key ?? .operation(operation!),
            role: .operation,
            accessibilityKey: accessibilityKey,
            columnSpan: 1
        )
    }

    func background(isPending: Bool) -> Color {
        switch role {
        case .operation:
            WatercolorTheme.actionBerry.opacity(isPending ? 0.34 : 0.18)
        case .digit, .utility:
            WatercolorTheme.softWhite.opacity(0.88)
        }
    }
}

#if os(macOS)
private func calculatorKey(for character: Character) -> PatternCalculatorKey? {
    if let digit = character.wholeNumberValue { return .digit(digit) }
    switch character {
    case ".", ",": return .decimal
    case "+": return .operation(.add)
    case "-": return .operation(.subtract)
    case "*", "×": return .operation(.multiply)
    case "/", "÷": return .operation(.divide)
    case "%": return .percent
    case "=": return .equals
    default: return nil
    }
}
#endif
