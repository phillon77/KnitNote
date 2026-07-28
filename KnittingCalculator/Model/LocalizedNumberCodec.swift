import Foundation

struct LocalizedNumberCodec {
    let locale: Locale

    func parseDecimal(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.isLenient = false
        let decimal = formatter.decimalSeparator ?? "."
        let alternate = decimal == "." ? "," : "."
        let localized = trimmed.replacingOccurrences(of: alternate, with: decimal)
        guard let value = formatter.number(from: localized)?.doubleValue,
              value.isFinite,
              value > 0 else { return nil }
        return value
    }

    func parsePositiveInteger(_ text: String) -> Int? {
        guard let value = parseDecimal(text),
              value.rounded(.towardZero) == value,
              value <= Double(Int.max) else { return nil }
        return Int(value)
    }

    func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 4
        return formatter.string(from: NSNumber(value: value)) ?? ""
    }
}
