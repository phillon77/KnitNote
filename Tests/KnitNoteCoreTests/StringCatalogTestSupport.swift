import Foundation

enum StringCatalogContractError: Error, Equatable {
    case missingLanguage(key: String, language: String)
    case emptyValue(key: String, language: String)
    case formatMismatch(key: String, language: String, path: String)
    case missingVariationPath(key: String, language: String, path: String)
    case staleValue(key: String, language: String)
    case nonTranslatedValue(key: String, language: String, path: String, state: String?)
    case oracleMismatch(catalog: String)
    case oracleSourceCommitMismatch(expected: String, actual: String?)
}

func assertCatalogMatchesOracle(
    at url: URL,
    oracleAt oracleURL: URL,
    catalogName: String,
    expectedSourceCommit: String,
    permittedAdditionalKeys: Set<String> = []
) throws {
    let oracleData = try Data(contentsOf: oracleURL)
    let oracleObject = try JSONSerialization.jsonObject(with: oracleData)
    guard let oracle = oracleObject as? [String: Any],
          let sourceCommit = oracle["sourceCommit"] as? String
    else {
        throw CocoaError(.fileReadCorruptFile)
    }
    guard sourceCommit == expectedSourceCommit else {
        throw StringCatalogContractError.oracleSourceCommitMismatch(
            expected: expectedSourceCommit,
            actual: sourceCommit
        )
    }
    guard let catalogs = oracle["catalogs"] as? [String: Any],
          let expected = catalogs[catalogName] as? [String: Any]
    else {
        throw CocoaError(.fileReadCorruptFile)
    }

    let catalogData = try Data(contentsOf: url)
    let catalogObject = try JSONSerialization.jsonObject(with: catalogData)
    guard let root = catalogObject as? [String: Any] else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let actual = try catalogOracleSnapshot(from: root)
    guard catalogSnapshot(
        actual,
        matchesHistoricalOracle: expected,
        permittedAdditionalKeys: permittedAdditionalKeys
    ) else {
        throw StringCatalogContractError.oracleMismatch(catalog: catalogName)
    }
}

private func catalogSnapshot(
    _ actual: [String: Any],
    matchesHistoricalOracle expected: [String: Any],
    permittedAdditionalKeys: Set<String>
) -> Bool {
    guard let actualRoot = actual["rootMetadata"] as? [String: Any],
          let expectedRoot = expected["rootMetadata"] as? [String: Any],
          (actualRoot as NSDictionary).isEqual(to: expectedRoot),
          let actualEntries = actual["entries"] as? [String: Any],
          let expectedEntries = expected["entries"] as? [String: Any]
    else {
        return false
    }

    let expectedKeys = Set(expectedEntries.keys)
    guard Set(actualEntries.keys) == expectedKeys.union(permittedAdditionalKeys) else {
        return false
    }

    return expectedKeys.allSatisfy { key in
        guard let actualEntry = actualEntries[key] as? [String: Any],
              let expectedEntry = expectedEntries[key] as? [String: Any]
        else {
            return false
        }
        return (actualEntry as NSDictionary).isEqual(to: expectedEntry)
    }
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
        let usesPluralVariations = localizations.values
            .flatMap { collectStringUnits(in: $0) }
            .contains { $0.path.hasPrefix("variations.plural.") }
        let englishUnits = try catalogUnits(
            key: key,
            language: "en",
            sourceLanguage: sourceLanguage,
            localizations: localizations
        )
        try validateRequiredVariationPaths(
            in: englishUnits,
            key: key,
            language: "en",
            usesPluralVariations: usesPluralVariations
        )
        try validateCatalogUnits(englishUnits, key: key, language: "en")
        let englishTokenSignatures = Dictionary(
            uniqueKeysWithValues: englishUnits.map { ($0.path, formatSignature(in: $0.value)) }
        )

        for language in requiredLanguages {
            let units = try catalogUnits(
                key: key,
                language: language,
                sourceLanguage: sourceLanguage,
                localizations: localizations
            )
            try validateRequiredVariationPaths(
                in: units,
                key: key,
                language: language,
                usesPluralVariations: usesPluralVariations
            )
            try validateCatalogUnits(
                units,
                key: key,
                language: language,
                requiresTranslatedState: language != sourceLanguage
            )

            guard language != "en" else { continue }
            for unit in units where englishTokenSignatures[unit.path] != formatSignature(in: unit.value) {
                throw StringCatalogContractError.formatMismatch(
                    key: key,
                    language: language,
                    path: unit.path
                )
            }
        }
    }
}

private func validateRequiredVariationPaths(
    in units: [CatalogStringUnit],
    key: String,
    language: String,
    usesPluralVariations: Bool
) throws {
    let requiredPaths: [String]
    if usesPluralVariations {
        switch language {
        case "en", "de", "fr":
            requiredPaths = ["variations.plural.one", "variations.plural.other"]
        case "zh-Hant", "zh-Hans", "ja":
            requiredPaths = ["variations.plural.other"]
        default:
            requiredPaths = []
        }
    } else {
        requiredPaths = ["<direct>"]
    }

    let actualPaths = Set(units.map(\.path))
    if let missingPath = requiredPaths.first(where: { !actualPaths.contains($0) }) {
        throw StringCatalogContractError.missingVariationPath(
            key: key,
            language: language,
            path: missingPath
        )
    }
}

private struct CatalogStringUnit {
    let path: String
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
        return [CatalogStringUnit(path: "<direct>", state: nil, value: key)]
    }

    throw StringCatalogContractError.missingLanguage(key: key, language: language)
}

private func collectStringUnits(
    in node: Any,
    path: [String] = []
) -> [CatalogStringUnit] {
    if let dictionary = node as? [String: Any] {
        var units: [CatalogStringUnit] = []
        if let stringUnit = dictionary["stringUnit"] as? [String: Any],
           let value = stringUnit["value"] as? String {
            units.append(CatalogStringUnit(
                path: path.isEmpty ? "<direct>" : path.joined(separator: "."),
                state: stringUnit["state"] as? String,
                value: value
            ))
        }
        for key in dictionary.keys.sorted() where key != "stringUnit" {
            if let child = dictionary[key] {
                units.append(contentsOf: collectStringUnits(in: child, path: path + [key]))
            }
        }
        return units
    }

    if let array = node as? [Any] {
        return array.enumerated().flatMap { index, child in
            collectStringUnits(in: child, path: path + [String(index)])
        }
    }

    return []
}

private func validateCatalogUnits(
    _ units: [CatalogStringUnit],
    key: String,
    language: String,
    requiresTranslatedState: Bool = false
) throws {
    for unit in units {
        let value = unit.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            throw StringCatalogContractError.emptyValue(key: key, language: language)
        }
        if unit.state == "stale" || (key.contains(".") && value == key) {
            throw StringCatalogContractError.staleValue(key: key, language: language)
        }
        if requiresTranslatedState, unit.state != "translated" {
            throw StringCatalogContractError.nonTranslatedValue(
                key: key,
                language: language,
                path: unit.path,
                state: unit.state
            )
        }
    }
}

private func catalogOracleSnapshot(from root: [String: Any]) throws -> [String: Any] {
    guard let strings = root["strings"] as? [String: Any] else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let sourceLanguage = root["sourceLanguage"] as? String
    var rootMetadata = root
    rootMetadata.removeValue(forKey: "strings")
    var entries: [String: Any] = [:]

    for key in strings.keys.sorted() {
        guard let entry = strings[key] as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var sourceMetadata = entry
        sourceMetadata.removeValue(forKey: "localizations")
        let localizations = entry["localizations"] as? [String: Any] ?? [:]
        let englishUnits = try catalogUnits(
            key: key,
            language: "en",
            sourceLanguage: sourceLanguage,
            localizations: localizations
        )
        let effectiveEnglish: [[String: Any]] = englishUnits.map { unit in
            [
                "path": unit.path == "<direct>" ? [] : unit.path.split(separator: ".").map(String.init),
                "state": unit.state ?? NSNull(),
                "value": unit.value,
            ]
        }
        entries[key] = [
            "sourceMetadata": sourceMetadata,
            "effectiveEnglish": effectiveEnglish,
        ]
    }

    return [
        "rootMetadata": rootMetadata,
        "entries": entries,
    ]
}

private struct FormatArgument: Hashable {
    let position: Int
    let type: String
}

private func formatSignature(in value: String) -> [FormatArgument] {
    let expression = try! NSRegularExpression(pattern: #"%([0-9]+\$)?(lld|ld|d|@|f)"#)
    let range = NSRange(value.startIndex..., in: value)
    var nextImplicitPosition = 1
    let arguments: [FormatArgument] = expression.matches(in: value, range: range).compactMap { match in
        guard let typeRange = Range(match.range(at: 2), in: value) else {
            return nil
        }
        let position: Int
        if let positionRange = Range(match.range(at: 1), in: value) {
            position = Int(value[positionRange].dropLast())!
        } else {
            position = nextImplicitPosition
            nextImplicitPosition += 1
        }
        return FormatArgument(position: position, type: String(value[typeRange]))
    }
    return arguments.sorted {
        ($0.position, $0.type) < ($1.position, $1.type)
    }
}
