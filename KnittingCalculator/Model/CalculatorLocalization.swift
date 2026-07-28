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

    static func formatted(
        _ key: String,
        _ arguments: CVarArg...,
        locale: Locale
    ) -> String {
        String(format: string(key, locale: locale), locale: locale, arguments: arguments)
    }

    private static func localizationIdentifiers(for locale: Locale) -> [String] {
        let languageCode = locale.language.languageCode?.identifier ?? "en"
        let scriptCode = locale.language.script?.identifier
        let regionCode = locale.region?.identifier
        var candidates = [locale.identifier.replacingOccurrences(of: "_", with: "-")]

        if let scriptCode, let regionCode {
            candidates.append(languageCode + "-" + scriptCode + "-" + regionCode)
        }
        if let scriptCode {
            candidates.append(languageCode + "-" + scriptCode)
        }
        if languageCode == "zh", ["TW", "HK", "MO"].contains(regionCode) {
            candidates.append("zh-Hant")
        }
        candidates.append(languageCode)
        return candidates.reduce(into: []) { identifiers, candidate in
            if !identifiers.contains(candidate) {
                identifiers.append(candidate)
            }
        }
    }
}
