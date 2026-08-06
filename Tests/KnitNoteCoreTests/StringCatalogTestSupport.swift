import Foundation

enum StringCatalogContractError: Error, Equatable {
    case missingLanguage(key: String, language: String)
    case emptyValue(key: String, language: String)
    case formatMismatch(key: String, language: String)
    case staleValue(key: String, language: String)
}

func assertCompleteCatalog(
    at url: URL,
    requiredLanguages: [String]
) throws {
    let data = try Data(contentsOf: url)
    let catalog = try JSONSerialization.jsonObject(with: data)
    guard let root = catalog as? [String: Any],
          let strings = root["strings"] as? [String: Any]
    else {
        throw CocoaError(.fileReadCorruptFile)
    }

    let sourceLanguage = root["sourceLanguage"] as? String
    for key in strings.keys.sorted() {
        guard let entry = strings[key] as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let localizations = entry["localizations"] as? [String: Any] ?? [:]
        let englishUnits = try catalogUnits(
            key: key,
            language: "en",
            sourceLanguage: sourceLanguage,
            localizations: localizations
        )
        try validateCatalogUnits(englishUnits, key: key, language: "en")
        let englishTokenSignatures = Set(englishUnits.map { formatTokens(in: $0.value) })

        for language in requiredLanguages {
            let units = try catalogUnits(
                key: key,
                language: language,
                sourceLanguage: sourceLanguage,
                localizations: localizations
            )
            try validateCatalogUnits(units, key: key, language: language)

            guard language == "en"
                    || units.allSatisfy({ englishTokenSignatures.contains(formatTokens(in: $0.value)) })
            else {
                throw StringCatalogContractError.formatMismatch(key: key, language: language)
            }
        }
    }
}

private struct CatalogStringUnit {
    let state: String?
    let value: String
}

private func catalogUnits(
    key: String,
    language: String,
    sourceLanguage: String?,
    localizations: [String: Any]
) throws -> [CatalogStringUnit] {
    if let localization = localizations[language] as? [String: Any] {
        let units = collectStringUnits(in: localization)
        guard !units.isEmpty else {
            throw StringCatalogContractError.missingLanguage(key: key, language: language)
        }
        return units
    }

    if language == "en", sourceLanguage == "en" {
        return [CatalogStringUnit(state: nil, value: key)]
    }

    throw StringCatalogContractError.missingLanguage(key: key, language: language)
}

private func collectStringUnits(in node: Any) -> [CatalogStringUnit] {
    if let dictionary = node as? [String: Any] {
        var units: [CatalogStringUnit] = []
        if let stringUnit = dictionary["stringUnit"] as? [String: Any],
           let value = stringUnit["value"] as? String {
            units.append(CatalogStringUnit(state: stringUnit["state"] as? String, value: value))
        }
        for key in dictionary.keys.sorted() where key != "stringUnit" {
            if let child = dictionary[key] {
                units.append(contentsOf: collectStringUnits(in: child))
            }
        }
        return units
    }

    if let array = node as? [Any] {
        return array.flatMap(collectStringUnits(in:))
    }

    return []
}

private func validateCatalogUnits(
    _ units: [CatalogStringUnit],
    key: String,
    language: String
) throws {
    for unit in units {
        let value = unit.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            throw StringCatalogContractError.emptyValue(key: key, language: language)
        }
        if unit.state == "stale" || (key.contains(".") && value == key) {
            throw StringCatalogContractError.staleValue(key: key, language: language)
        }
    }
}

private func formatTokens(in value: String) -> [String] {
    let expression = try! NSRegularExpression(pattern: #"%([0-9]+\$)?(lld|ld|d|@|f)"#)
    let range = NSRange(value.startIndex..., in: value)
    return expression.matches(in: value, range: range).compactMap { match in
        Range(match.range, in: value).map { String(value[$0]) }
    }
}
