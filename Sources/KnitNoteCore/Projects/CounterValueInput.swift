import Foundation

public enum CounterValueInputError: Error, Equatable, Sendable {
    case empty
    case invalidWholeNumber
    case negative
    case overflow
}

public enum CounterValueInput {
    public static func parse(_ text: String) throws -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CounterValueInputError.empty }
        guard !trimmed.hasPrefix("-") else { throw CounterValueInputError.negative }
        guard trimmed.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw CounterValueInputError.invalidWholeNumber
        }
        guard let value = Int(trimmed) else { throw CounterValueInputError.overflow }
        return value
    }
}
