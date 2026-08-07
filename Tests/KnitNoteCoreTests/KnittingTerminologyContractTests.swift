import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct KnittingTerminologyContractTests {
    @Test func terminologyContainsEveryVersion141LanguageAndUniqueKey() throws {
        let table = try TerminologyTable.load(from: terminologyURL)

        #expect(table.headers == [
            "key", "en", "zh-Hant", "zh-Hans", "de", "fr", "ja",
            "nb", "sv", "fi", "da", "ko", "el",
        ])
        #expect(Set(table.rows.map(\.key)).count == table.rows.count)
        #expect(table.rows.allSatisfy { row in
            table.headers.dropFirst().allSatisfy { !(row[$0] ?? "").isEmpty }
        })
    }

    private var terminologyURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "AppStore/Localization/KnittingTerminology.csv")
    }
}

private struct TerminologyTable {
    struct Row {
        let values: [String: String]

        var key: String { values["key", default: ""] }

        subscript(language: String) -> String? {
            values[language]
        }
    }

    let headers: [String]
    let rows: [Row]

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
