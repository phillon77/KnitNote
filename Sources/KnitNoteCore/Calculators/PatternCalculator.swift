import Foundation

public enum PatternCalculatorOperation: Equatable, Sendable {
    case add, subtract, multiply, divide
}

public enum PatternCalculatorError: Equatable, Sendable {
    case invalidResult
}

public enum PatternCalculatorKey: Equatable, Sendable {
    case digit(Int)
    case decimal
    case operation(PatternCalculatorOperation)
    case equals
    case clear
    case toggleSign
    case percent
}

public enum PatternCalculatorDisplay: Equatable, Sendable {
    case number(String)
    case error(PatternCalculatorError)
}

public struct PatternCalculatorState: Equatable, Sendable {
    public static let maximumEntryDigits = 12
    public static let maximumFractionDigits = 12

    public private(set) var canonicalDisplay = "0"
    public private(set) var display: PatternCalculatorDisplay = .number("0")
    public var pendingOperationForDisplay: PatternCalculatorOperation? { pendingOperation }

    private var accumulator: Decimal?
    private var pendingOperation: PatternCalculatorOperation?
    private var isStartingNewEntry = false

    public init() {}

    public mutating func press(_ key: PatternCalculatorKey) {
        if case .error = display {
            switch key {
            case .clear:
                self = .init()
            case let .digit(digit):
                self = .init()
                inputDigit(digit)
            default:
                return
            }
            return
        }

        switch key {
        case let .digit(digit):
            inputDigit(digit)
        case .decimal:
            inputDecimal()
        case let .operation(operation):
            select(operation)
        case .equals:
            evaluate()
        case .clear:
            self = .init()
        case .toggleSign:
            toggleSign()
        case .percent:
            applyPercent()
        }
    }

    private mutating func inputDigit(_ digit: Int) {
        guard (0 ... 9).contains(digit) else { return }

        if isStartingNewEntry {
            canonicalDisplay = String(digit)
            display = .number(canonicalDisplay)
            isStartingNewEntry = false
            return
        }

        if canonicalDisplay == "0" {
            canonicalDisplay = String(digit)
            display = .number(canonicalDisplay)
            return
        }

        guard entryDigitCount < Self.maximumEntryDigits else { return }
        canonicalDisplay.append(String(digit))
        display = .number(canonicalDisplay)
    }

    private mutating func inputDecimal() {
        if isStartingNewEntry {
            canonicalDisplay = "0."
            display = .number(canonicalDisplay)
            isStartingNewEntry = false
            return
        }

        guard !canonicalDisplay.contains(".") else { return }
        canonicalDisplay.append(".")
        display = .number(canonicalDisplay)
    }

    private mutating func select(_ operation: PatternCalculatorOperation) {
        guard let value = currentValue() else {
            fail()
            return
        }

        guard let accumulator, let pendingOperation else {
            self.accumulator = value
            self.pendingOperation = operation
            isStartingNewEntry = true
            return
        }

        guard !isStartingNewEntry else {
            self.pendingOperation = operation
            return
        }

        guard let result = applying(pendingOperation, to: accumulator, and: value), replaceDisplay(with: result), let displayedResult = currentValue() else {
            fail()
            return
        }

        self.accumulator = displayedResult
        self.pendingOperation = operation
        isStartingNewEntry = true
    }

    private mutating func evaluate() {
        guard let accumulator, let pendingOperation, !isStartingNewEntry else { return }
        guard let value = currentValue(), let result = applying(pendingOperation, to: accumulator, and: value), replaceDisplay(with: result) else {
            fail()
            return
        }

        self.accumulator = nil
        self.pendingOperation = nil
        isStartingNewEntry = true
    }

    private mutating func toggleSign() {
        guard let value = currentValue() else {
            fail()
            return
        }
        guard replaceDisplay(with: -value) else {
            fail()
            return
        }
    }

    private mutating func applyPercent() {
        guard let value = currentValue() else {
            fail()
            return
        }
        guard replaceDisplay(with: value / 100) else {
            fail()
            return
        }
        isStartingNewEntry = true
    }

    private mutating func fail() {
        accumulator = nil
        pendingOperation = nil
        isStartingNewEntry = false
        display = .error(.invalidResult)
    }

    @discardableResult
    private mutating func replaceDisplay(with value: Decimal) -> Bool {
        guard !isInvalid(value) else { return false }

        var source = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, Self.maximumFractionDigits, .plain)
        guard !isInvalid(rounded) else { return false }

        if rounded == .zero {
            canonicalDisplay = "0"
        } else {
            let text = NSDecimalNumber(decimal: rounded).stringValue
            guard text != NSDecimalNumber.notANumber.stringValue else { return false }
            canonicalDisplay = text
        }
        display = .number(canonicalDisplay)
        return true
    }

    private func currentValue() -> Decimal? {
        Decimal(string: canonicalDisplay, locale: Locale(identifier: "en_US_POSIX"))
    }

    private var entryDigitCount: Int {
        canonicalDisplay.reduce(into: 0) { count, character in
            if character.isNumber { count += 1 }
        }
    }

    private func applying(
        _ operation: PatternCalculatorOperation,
        to left: Decimal,
        and right: Decimal
    ) -> Decimal? {
        switch operation {
        case .add:
            return left + right
        case .subtract:
            return left - right
        case .multiply:
            return left * right
        case .divide:
            guard right != .zero else { return nil }
            return left / right
        }
    }

    private func isInvalid(_ value: Decimal) -> Bool {
        NSDecimalNumber(decimal: value) == .notANumber
    }
}
