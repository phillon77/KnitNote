import Foundation
import Testing
@testable import KnitNoteCore

struct StitchCatalogTests {
    private func fixture(_ mutate: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        let url = try #require(StitchDictionaryResources.url(named: "stitch-dictionary-v1"))
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        mutate(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }
    private func entryMutation(_ mutate: (inout [String: Any]) -> Void) throws -> Data {
        try fixture { object in
            var entries = object["entries"] as! [[String: Any]]
            mutate(&entries[0])
            object["entries"] = entries
        }
    }
    @Test func rejectsUnknownSchema() throws {
        #expect(throws: StitchCatalogError.unsupportedVersion(99)) {
            try StitchCatalog.decode(fixture { $0["schemaVersion"] = 99 })
        }
    }
    @Test func containsVerifiedSampleAndUsesID() throws {
        let catalog = try StitchCatalog.bundled()
        #expect(catalog.entry(id: "knit") != nil)
        #expect(catalog.entry(id: "Knit") == nil)
        let diagrams = try StitchDiagram.loadBundled()
        try catalog.validate(diagramIDs: Set(diagrams.map(\.id)), localizedKeys: keys(catalog))
    }
    @Test(arguments: ["entry", "source", "symbol"])
    func rejectsDuplicateIDs(kind: String) throws {
        let data = try fixture { object in
            if kind == "symbol" {
                var entries = object["entries"] as! [[String: Any]]
                let symbols = entries[0]["symbols"] as! [[String: Any]]
                entries[0]["symbols"] = symbols + symbols
                object["entries"] = entries
            } else {
                let key = kind == "entry" ? "entries" : "sources"
                let values = object[key] as! [[String: Any]]
                object[key] = values + [values[0]]
            }
        }
        let duplicate = kind == "entry" ? "knit" : kind == "source" ? "cyc-abbreviations" : "knit.symbol.jp.rs"
        #expect(throws: StitchCatalogError.duplicateID(duplicate)) { try StitchCatalog.decode(data) }
    }
    @Test(arguments: ["steps", "zh-Hant", "zh-Hans", "en", "ja", "ko", "consumes", "produces", "condition", "title", "summary", "stepText", "accessibility", "tradition", "note"])
    func rejectsInvalidEntry(field: String) throws {
        let data = try entryMutation { entry in
            switch field {
            case "steps": entry["steps"] = []
            case "zh-Hant", "zh-Hans", "en", "ja", "ko":
                var names = entry["names"] as! [String: String]; names[field] = "  "; entry["names"] = names
            case "consumes", "produces": entry[field] = -1
            case "title", "summary": entry[field + "Key"] = ""
            case "note": entry["noteKeys"] = [""]
            case "stepText", "accessibility":
                var steps = entry["steps"] as! [[String: Any]]
                steps[0][field == "stepText" ? "textKey" : "accessibilityKey"] = ""
                entry["steps"] = steps
            default:
                var symbols = entry["symbols"] as! [[String: Any]]
                symbols[0][field == "condition" ? "conditionKey" : "traditionKey"] = "  "
                entry["symbols"] = symbols
            }
        }
        #expect(throws: StitchCatalogError.invalidEntry("knit")) { try StitchCatalog.decode(data) }
    }
    @Test(arguments: ["related", "source", "symbolSource"])
    func rejectsUnknownCatalogReference(kind: String) throws {
        let data = try entryMutation { entry in
            if kind == "symbolSource" {
                var symbols = entry["symbols"] as! [[String: Any]]
                symbols[0]["sourceIDs"] = ["unknown"]; entry["symbols"] = symbols
            } else { entry[kind == "related" ? "relatedIDs" : "sourceIDs"] = ["unknown"] }
        }
        #expect(throws: StitchCatalogError.missingReference("unknown")) { try StitchCatalog.decode(data) }
    }
    @Test(arguments: ["url", "dateFormat", "impossibleDate"])
    func rejectsInvalidSource(field: String) throws {
        let data = try fixture { object in
            var sources = object["sources"] as! [[String: Any]]
            if field == "url" { sources[0]["url"] = "http://example.com" }
            else { sources[0]["checkedOn"] = field == "dateFormat" ? "2026-9-15" : "2026-02-30" }
            object["sources"] = sources
        }
        #expect(throws: StitchCatalogError.invalidEntry("cyc-abbreviations")) { try StitchCatalog.decode(data) }
    }
    @Test(arguments: ["step", "symbol"])
    func rejectsMissingDiagram(kind: String) throws {
        let data = try entryMutation { entry in
            let field = kind == "step" ? "steps" : "symbols"
            var records = entry[field] as! [[String: Any]]
            records[0]["diagramID"] = "unknown"
            entry[field] = records
        }
        let catalog = try StitchCatalog.decode(data)
        #expect(throws: StitchCatalogError.missingReference("unknown")) {
            try catalog.validate(diagramIDs: Set(StitchDiagram.loadBundled().map(\.id)), localizedKeys: keys(catalog))
        }
    }
    @Test(arguments: ["stitchDictionary.knit.title", "stitchDictionary.knit.summary", "stitchDictionary.knit.step.1", "stitchDictionary.knit.accessibility.1", "stitchDictionary.knit.note.englishMethod", "stitchDictionary.symbol.japanese", "stitchDictionary.symbol.rightSide"])
    func rejectsMissingLocalization(key: String) throws {
        let catalog = try StitchCatalog.decode(fixture())
        #expect(throws: StitchCatalogError.missingReference(key)) {
            try catalog.validate(diagramIDs: Set(StitchDiagram.loadBundled().map(\.id)), localizedKeys: keys(catalog).subtracting([key]))
        }
    }
    @Test func propagatesMalformedJSON() {
        #expect(throws: DecodingError.self) { try StitchCatalog.decode(Data("{".utf8)) }
    }
    @Test func bundledEntriesHaveExplicitReviewedNotation() throws {
        let catalog = try StitchCatalog.bundled()
        let entries = catalog.entries
        let expected = ["k", "p", "sl1k", "sl1p", "yo", "kfb", "m1l", "m1r", "k2tog", "ssk", "skp", "p2tog", "cdd", "1/1 LC", "1/1 RC"]
        #expect(entries.count == expected.count)
        for (entry, notation) in zip(entries, expected) {
            #expect(entry.displayNotation == notation)
        }
    }
    @Test(arguments: ["", "   ", "unrecorded"])
    func rejectsInvalidDisplayNotation(notation: String) throws {
        #expect(throws: StitchCatalogError.invalidEntry("knit")) {
            try StitchCatalog.decode(entryMutation { $0["displayNotation"] = notation })
        }
    }
    @Test func displayNotationIsOptionalAndAcceptsRecordedCaseVariant() throws {
        let legacy = try StitchCatalog.decode(entryMutation { $0.removeValue(forKey: "displayNotation") })
        #expect(legacy.entry(id: "knit")?.displayNotation == nil)
        let variant = try StitchCatalog.decode(entryMutation { $0["displayNotation"] = "K" })
        #expect(variant.entry(id: "knit")?.displayNotation == "K")
    }
    private func keys(_ catalog: StitchCatalog) -> Set<String> {
        Set(catalog.entries.flatMap { entry in
            [entry.titleKey, entry.summaryKey] + entry.noteKeys
            + entry.steps.flatMap { [$0.textKey, $0.accessibilityKey] }
            + entry.symbols.flatMap { [$0.traditionKey, $0.conditionKey] }
        })
    }
}
