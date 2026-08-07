import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct KnittingTerminologyContractTests {
    @Test func terminologyContainsEveryVersion141LanguageAndUniqueKey() throws {
        let table = try TerminologyTable.load(from: terminologyURL)

        #expect(table.headers == [
            "key", "catalogKeys", "en", "zh-Hant", "zh-Hans", "de", "fr", "ja",
            "nb", "sv", "fi", "da", "ko", "el",
        ])
        #expect(Set(table.rows.map(\.key)).count == table.rows.count)
        #expect(table.rows.allSatisfy { row in
            table.headers.dropFirst().allSatisfy { !(row[$0] ?? "").isEmpty }
        })
    }

    @Test func terminologyRowsGovernApprovedRuntimeCatalogKeyFamilies() throws {
        let table = try TerminologyTable.load(from: terminologyURL)
        let catalog = try RuntimeCatalog.load(from: catalogURL)
        let languages = table.headers.filter { $0 != "key" && $0 != "catalogKeys" }

        for row in table.rows {
            let keySpecs = row.catalogKeys
            #expect(!keySpecs.isEmpty, "\(row.key) must explicitly define its governed catalog keys")
            let englishTerms = (row["en"] ?? "")
                .split(separator: "|")
                .map(String.init)
            if keySpecs == ["-"] {
                #expect(
                    catalog.keys(containingEnglishTerms: englishTerms).isEmpty,
                    "\(row.key) may use '-' only while its English term is absent from the runtime catalog"
                )
                continue
            }
            let governedKeys = catalog.governedKeys(
                for: keySpecs,
                containingEnglishTerms: englishTerms
            )
            #expect(!governedKeys.isEmpty, "\(row.key) must govern at least one runtime catalog key")

            for key in governedKeys {
                let values = try #require(catalog.allValues[key], "missing governed catalog key \(key)")
                for language in languages {
                    let actualValues = try #require(values[language], "\(key) is missing \(language)")
                    #expect(!actualValues.isEmpty, "\(key) is empty for \(language)")
                    let approved = (row[language] ?? "")
                        .split(separator: "|")
                        .map(String.init)
                    for actual in actualValues {
                        #expect(
                            approved.contains { matchesApprovedTerm($0, in: actual) },
                            "\(key) \(language) value '\(actual)' is outside \(row.key)'s approved term family \(approved)"
                        )
                    }
                }
            }
        }
    }

    @Test func terminologyRowsGovernBroadRuntimeSemanticScopes() throws {
        let table = try TerminologyTable.load(from: terminologyURL)
        let catalog = try RuntimeCatalog.load(from: catalogURL)
        let minimumCoverage = [
            "pattern": 45,
            "stitch": 42,
            "row": 30,
            "gauge": 2,
            "increase": 12,
            "decrease": 12,
            "knittingNeedle": 4,
            "crochetHook": 4,
            "yarn": 31,
            "swatch": 4,
            "counter": 9,
            "highlight": 4,
        ]

        for row in table.rows where row.catalogKeys != ["-"] {
            let englishTerms = (row["en"] ?? "")
                .split(separator: "|")
                .map(String.init)
            let governed = catalog.governedKeys(
                for: row.catalogKeys,
                containingEnglishTerms: englishTerms
            )

            #expect(
                governed.count >= minimumCoverage[row.key, default: 1],
                "\(row.key) governs only \(governed.count) runtime keys; its semantic scope was narrowed"
            )
        }
    }

    @Test func finalReviewTerminologyDefectsStayCorrected() throws {
        let table = try TerminologyTable.load(from: terminologyURL)
        let catalog = try RuntimeCatalog.load(from: catalogURL)

        #expect(table["round"]?["nb"] == "Omgang")
        #expect(catalog["journal.add.title", "sv"] == "Nytt dagboksinlägg")
        #expect(catalog["unlock.trial.active.many.format", "da"] == "%lld dage tilbage i prøveperioden")
        #expect(catalog["common.save", "ko"] == "저장")
        #expect(catalog["settings.storage", "ko"] == "저장 공간")
        #expect(catalog["nav.patterns", "da"] == "Opskrifter")
        #expect(catalog["project.tool.type.knittingNeedles", "ko"] == "대바늘")
        #expect(catalog["yarn.recommendedNeedleMM", "ko"] == "대바늘")
    }

    private var terminologyURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "AppStore/Localization/KnittingTerminology.csv")
    }

    private var catalogURL: URL {
        terminologyURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "KnitNote/Localization/Localizable.xcstrings")
    }
}

private struct TerminologyTable {
    struct Row {
        let values: [String: String]

        var key: String { values["key", default: ""] }
        var catalogKeys: [String] {
            values["catalogKeys", default: ""]
                .split(separator: ";")
                .map(String.init)
        }

        subscript(language: String) -> String? {
            values[language]
        }
    }

    let headers: [String]
    let rows: [Row]

    subscript(key: String) -> Row? {
        rows.first { $0.key == key }
    }

    static func load(from url: URL) throws -> Self {
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard let headerLine = lines.first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let headers = headerLine.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let rows = try lines.dropFirst().map { line in
            let values = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard values.count == headers.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return Row(values: Dictionary(uniqueKeysWithValues: zip(headers, values)))
        }
        return Self(headers: headers, rows: rows)
    }
}

private struct RuntimeCatalog {
    let values: [String: [String: String]]
    let allValues: [String: [String: [String]]]

    subscript(key: String, language: String) -> String? {
        values[key]?[language]
    }

    static func load(from url: URL) throws -> Self {
        let data = try Data(contentsOf: url)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        var values: [String: [String: String]] = [:]
        var allValues: [String: [String: [String]]] = [:]
        for (key, rawEntry) in strings {
            let entry = try #require(rawEntry as? [String: Any])
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            values[key] = try Dictionary(uniqueKeysWithValues: localizations.compactMap { language, rawLocalization in
                let localization = try #require(rawLocalization as? [String: Any])
                guard let unit = localization["stringUnit"] as? [String: Any],
                      let value = unit["value"] as? String
                else {
                    return nil
                }
                return (language, value)
            })
            allValues[key] = try Dictionary(
                uniqueKeysWithValues: localizations.compactMap { language, rawLocalization in
                    let localization = try #require(rawLocalization as? [String: Any])
                    let strings = localizedStrings(in: localization)
                    return strings.isEmpty ? nil : (language, strings)
                }
            )
        }
        return Self(values: values, allValues: allValues)
    }

    func keys(containingEnglishTerms terms: [String], prefix: String? = nil) -> [String] {
        allValues.compactMap { key, values in
            guard prefix.map(key.hasPrefix) ?? true,
                  values["en", default: []].contains(where: { value in
                      terms.contains { matchesApprovedTerm($0, in: value) }
                  })
            else {
                return nil
            }
            return key
        }.sorted()
    }

    func governedKeys(
        for specs: [String],
        containingEnglishTerms terms: [String]
    ) -> [String] {
        Set(specs.flatMap { spec -> [String] in
            if spec == "*" {
                return keys(containingEnglishTerms: terms)
            }
            if spec.hasSuffix(".*") {
                return keys(
                    containingEnglishTerms: terms,
                    prefix: String(spec.dropLast())
                )
            }
            return [spec]
        }).sorted()
    }

    private static func localizedStrings(in value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            var strings: [String] = []
            if let unit = dictionary["stringUnit"] as? [String: Any],
               let string = unit["value"] as? String {
                strings.append(string)
            }
            for (key, nested) in dictionary where key != "stringUnit" {
                strings.append(contentsOf: localizedStrings(in: nested))
            }
            return strings
        }
        if let array = value as? [Any] {
            return array.flatMap(localizedStrings)
        }
        return []
    }
}

private func matchesApprovedTerm(_ approved: String, in value: String) -> Bool {
    let term = approved.hasSuffix("*") ? String(approved.dropLast()) : approved
    return value.range(
        of: term,
        options: [.caseInsensitive, .diacriticInsensitive]
    ) != nil
}
