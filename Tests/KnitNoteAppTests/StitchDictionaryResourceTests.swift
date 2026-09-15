import Foundation
import Testing
@testable import KnitNote

@Suite struct StitchDictionaryResourceTests {
    @Test func actualAppBundleContainsCompleteCatalogAndDiagrams() throws {
        #expect(Bundle.main.bundleURL.pathExtension == "app")
        let catalog = try StitchCatalog.bundled()
        let diagrams = try StitchDiagram.loadBundled()
        #expect(catalog.entries.count == 15)
        #expect(diagrams.count == 61)
        #expect(Set(diagrams.map(\.id)).count == diagrams.count)
        for diagram in diagrams { try diagram.validate() }
        for language in ["da", "de", "el", "en", "fi", "fr", "ja", "ko", "nb", "nl", "sv", "zh-Hans", "zh-Hant"] {
            let directory = try #require(Bundle.main.url(forResource: language, withExtension: "lproj"))
            let data = try Data(contentsOf: directory.appendingPathComponent("Localizable.strings"))
            let strings = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            let keys = Set(strings.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.key))
            try catalog.validate(diagramIDs: Set(diagrams.map(\.id)), localizedKeys: keys)
            #expect(keys.contains("stitchDictionary.title"), "Missing UI key in \(language)")
        }
    }
    @Test func missingBundledReferenceIsRejected() throws {
        let catalog = try StitchCatalog.bundled()
        let diagrams = try StitchDiagram.loadBundled()
        let directory = try #require(Bundle.main.url(forResource: "en", withExtension: "lproj"))
        let data = try Data(contentsOf: directory.appendingPathComponent("Localizable.strings"))
        let strings = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        let keys = Set(strings.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.key))
        try catalog.validate(diagramIDs: Set(diagrams.map(\.id)), localizedKeys: keys)
        let removedDiagramID = catalog.entries[0].steps[0].diagramID
        #expect(throws: StitchCatalogError.missingReference(removedDiagramID)) {
            try catalog.validate(diagramIDs: Set(diagrams.map(\.id)).subtracting([removedDiagramID]), localizedKeys: keys)
        }
    }
}
