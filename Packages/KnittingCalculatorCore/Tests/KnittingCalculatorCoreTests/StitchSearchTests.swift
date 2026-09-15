import Foundation
import Testing
@testable import KnittingCalculatorCore

struct StitchSearchTests {
    private func fixture() throws -> StitchCatalog {
        func entry(_ id: String, _ alias: String, _ order: Int, _ category: StitchCategory = .basic,
                   _ english: String? = nil) -> StitchEntry {
            StitchEntry(id: id, category: category, order: order,
                        names: ["zh-Hant": "繁體-" + id, "zh-Hans": "简体-" + id,
                                "en": english ?? id, "ja": "日本語-" + id, "ko": "한국어-" + id],
                        aliases: [alias, alias], titleKey: "title", summaryKey: "summary",
                        steps: [StitchStep(textKey: "step", diagramID: "diagram", accessibilityKey: "access")],
                        consumes: 1, produces: 1, noteKeys: [], relatedIDs: [], sourceIDs: [], symbols: [])
        }
        let catalog = StitchCatalog(schemaVersion: 1, sources: [], entries: [
            entry("contains", "zz knit zz", 0), entry("prefix", "knitting", 9),
            entry("knit", "k", 5), entry("purl", "p", 6), entry("k2tog", "k2tog", 1, .decrease),
            entry("slip-purlwise", "sl1", 3), entry("slip-knitwise", "sl1", 3)
        ])
        // Decode also checks intrinsic catalog validity, keeping this fixture honest.
        return try StitchCatalog.decode(JSONEncoder().encode(catalog))
    }

    @Test(arguments: ["k1", "K 1", "ｋ１", " k\t1\n"])
    func recognizesSingleKnit(_ query: String) throws {
        #expect(StitchSearch.results(query: query, category: nil, in: try fixture()) ==
                [StitchSearchResult(entryID: "knit", repetitions: 1)])
    }

    @Test func recognizesPurlAndMaximumCount() throws {
        #expect(StitchSearch.results(query: "p3", category: nil, in: try fixture()) ==
                [StitchSearchResult(entryID: "purl", repetitions: 3)])
        #expect(StitchSearch.results(query: "k\(Int.max)", category: nil, in: try fixture()).first?.repetitions == Int.max)
    }

    @Test(arguments: ["k0", "k-1", "k1.5", "k1 p2", "k1suffix", "k١", String(repeating: "9", count: 1000).appending("k"), "k" + String(repeating: "9", count: 1000), "no-match"])
    func rejectsInvalidCountAndUnknownText(_ query: String) throws {
        #expect(StitchSearch.results(query: query, category: nil, in: try fixture()).isEmpty)
    }

    @Test func preservesWholeAbbreviationAndAmbiguity() throws {
        #expect(StitchSearch.results(query: "K2TOG", category: nil, in: try fixture()) ==
                [StitchSearchResult(entryID: "k2tog", repetitions: nil)])
        #expect(StitchSearch.results(query: "sl1", category: nil, in: try fixture()) ==
                [StitchSearchResult(entryID: "slip-knitwise", repetitions: nil),
                 StitchSearchResult(entryID: "slip-purlwise", repetitions: nil)])
    }

    @Test(arguments: ["繁體-knit", "简体-knit", "knit", "日本語-knit", "한국어-knit"])
    func searchesEveryLanguage(_ query: String) throws {
        #expect(StitchSearch.results(query: query, category: nil, in: try fixture()).first?.entryID == "knit")
    }

    @Test func ranksDeduplicatesAndFilters() throws {
        #expect(StitchSearch.results(query: "knit", category: nil, in: try fixture()).map(\.entryID) ==
                ["knit", "prefix", "contains", "slip-knitwise"])
        #expect(StitchSearch.results(query: "k1", category: .decrease, in: try fixture()).isEmpty)
        #expect(StitchSearch.results(query: "k2tog", category: .decrease, in: try fixture()).count == 1)
        #expect(StitchSearch.results(query: " \n", category: .decrease, in: try fixture()).map(\.entryID) == ["k2tog"])
        #expect(StitchSearch.results(query: "", category: nil, in: try fixture()).map(\.entryID) ==
                ["contains", "k2tog", "slip-knitwise", "slip-purlwise", "knit", "purl", "prefix"])
    }

    @Test func normalizesCompatibilityAndCase() {
        #expect(StitchSearch.normalize("  Ｋ２ＴＯＧ\n") == "k2tog")
        #expect(StitchSearch.normalize("e\u{301}") == StitchSearch.normalize("é"))
    }

    @Test func completeCountShapedNameWins() throws {
        let original = try fixture()
        let sample = try #require(original.entry(id: "purl"))
        let entry = StitchEntry(id: sample.id, category: sample.category, order: sample.order,
                                names: sample.names, aliases: ["k12"], titleKey: sample.titleKey,
                                summaryKey: sample.summaryKey, steps: sample.steps, consumes: sample.consumes,
                                produces: sample.produces, noteKeys: [], relatedIDs: [], sourceIDs: [], symbols: [])
        let catalog = try StitchCatalog.decode(JSONEncoder().encode(
            StitchCatalog(schemaVersion: 1, sources: [], entries: original.entries.filter { $0.id != "purl" } + [entry])))
        #expect(StitchSearch.results(query: "k12", category: nil, in: catalog) ==
                [StitchSearchResult(entryID: "purl", repetitions: nil)])
    }
}
