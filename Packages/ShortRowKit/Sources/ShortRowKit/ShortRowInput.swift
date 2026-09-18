import Foundation

/// Whole-string parsing. Grouping, exponents and trailing text are intentionally unsupported.
public enum ShortRowInput {
    public static func decimal(_ text: String, locale: Locale) -> Double? {
        let separator = locale.decimalSeparator ?? "."
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 32 else { return nil }
        let parts = trimmed.components(separatedBy: separator)
        guard parts.count <= 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        var normalized: [String] = []
        for part in parts {
            guard let digits = decimalDigits(part) else { return nil }
            normalized.append(digits)
        }
        guard let value = Double(normalized.joined(separator: ".")), value.isFinite, value > 0 else { return nil }
        return value
    }

    public static func stitches(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 5, let digits = decimalDigits(trimmed),
              let value = Int(digits), (2...10_000).contains(value) else { return nil }
        return value
    }

    private static func decimalDigits(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        var result = ""
        for character in text {
            guard character.unicodeScalars.count == 1,
                  let scalar = character.unicodeScalars.first,
                  scalar.properties.generalCategory == .decimalNumber,
                  let digit = character.wholeNumberValue else { return nil }
            result.append(String(digit))
        }
        return result
    }
}
