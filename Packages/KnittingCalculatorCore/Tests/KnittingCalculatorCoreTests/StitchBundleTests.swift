import Foundation
import Testing
@testable import KnittingCalculatorCore

struct StitchBundleTests {
    @Test func bundledDictionaryIsUsable() throws {
        let catalog = try StitchCatalog.bundled()
        #expect(catalog.entries.count == 15)
        let knit = try #require(catalog.entry(id: "knit"))
        #expect(knit.sourceIDs.contains("gosyo-knit"))
        #expect(knit.sourceIDs.contains("vogue-knit-video"))
        #expect(StitchSearch.results(query: "p3", category: nil, in: catalog).first == StitchSearchResult(entryID: "purl", repetitions: 3))
        let diagrams = try StitchDiagram.loadBundled()
        for entry in catalog.entries {
            for symbol in entry.symbols {
                #expect(diagrams.contains { $0.id == symbol.diagramID })
            }
        }
    }
}
