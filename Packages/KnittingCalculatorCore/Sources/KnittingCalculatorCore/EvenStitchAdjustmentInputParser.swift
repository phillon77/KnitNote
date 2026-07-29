import Foundation

public enum EvenStitchAdjustmentInputParseResult: Equatable, Sendable {
    case empty
    case invalid
    case valid(Int)
    case exceedsSupportedLimit
}

public enum EvenStitchAdjustmentInputParser {
    public static func parse(
        _ text: String,
        locale: Locale
    ) -> EvenStitchAdjustmentInputParseResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        let decimalSeparator = locale.decimalSeparator ?? "."
        guard !trimmed.contains(decimalSeparator) else { return .invalid }

        let maximum = EvenStitchAdjustmentCalculator.maximumSupportedStitches
        var value = 0
        for character in trimmed {
            guard character.unicodeScalars.count == 1,
                  let scalar = character.unicodeScalars.first,
                  scalar.properties.generalCategory == .decimalNumber,
                  let digit = character.wholeNumberValue,
                  (0...9).contains(digit) else {
                return .invalid
            }
            guard value < maximum / 10 ||
                    (value == maximum / 10 && digit <= maximum % 10) else {
                return .exceedsSupportedLimit
            }
            value = value * 10 + digit
        }

        return value > 0 ? .valid(value) : .invalid
    }
}
