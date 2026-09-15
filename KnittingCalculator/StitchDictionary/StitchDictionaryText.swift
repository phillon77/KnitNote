import Foundation

enum StitchDictionaryText {
    static func format(_ key: String, locale: Locale, _ arguments: CVarArg...) -> String {
        String(format: CalculatorLocalization.string(key, locale: locale), locale: locale, arguments: arguments)
    }
}
