import Foundation

enum CalculatorLocalization {
    static func string(_ key: String, locale: Locale) -> String {
        for identifier in localizationIdentifiers(for: locale) {
            guard let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                continue
            }

            let value = bundle.localizedString(forKey: key, value: key, table: "Localizable")
            if value != key {
                return value
            }
        }

        return Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
    }

    private static func localizationIdentifiers(for locale: Locale) -> [String] {
        let languageCode = locale.language.languageCode?.identifier ?? "en"
        let candidates = [
            locale.identifier.replacingOccurrences(of: "_", with: "-"),
            languageCode,
        ]
        return candidates.reduce(into: []) { identifiers, candidate in
            if !identifiers.contains(candidate) {
                identifiers.append(candidate)
            }
        }
    }
}
