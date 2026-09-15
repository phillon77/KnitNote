import Testing
import SwiftUI
#if os(macOS)
import AppKit
#endif
@testable import KnitNote

@Suite struct StitchDictionaryPresentationTests {
    @Test func failureAndNormalPresentationAreDistinct() throws {
        let failure = StitchDictionaryPresentation(catalogResult: .failure(StitchCatalogError.missingResource))
        #expect(failure.errorKey == "stitchDictionary.error.title")
        #expect(failure.results.isEmpty)
        let catalog = try StitchCatalog.bundled()
        var normal = StitchDictionaryPresentation(catalogResult: .success(catalog))
        #expect(normal.errorKey == nil)
        #expect(normal.results.count == 15)
        normal.query = "p3"
        #expect(normal.results == [StitchSearchResult(entryID: "purl", repetitions: 3)])
        let before = normal.results
        normal.mode = .symbols
        #expect(normal.results == before)
        normal.category = .cable
        #expect(normal.results.isEmpty)
        normal.clear()
        #expect(normal.query.isEmpty)
        #expect(normal.category == nil)
        #expect(normal.mode == .symbols)
        #expect(normal.results.count == 15)
        #expect(Set(normal.symbols.map { $0.symbol.id }).count == normal.symbols.count)
    }
    @Test func detailUsesSingleOperationCountsForHugeRepeat() throws {
        let entry = try #require(StitchCatalog.bundled().entry(id: "knit"))
        let detail = StitchDetailPresentation(entry: entry, repetitions: Int.max)
        #expect(detail.consumes == 1)
        #expect(detail.produces == 1)
        #expect(detail.repetitions == Int.max)
    }
    #if os(macOS)
    @MainActor @Test func injectedFailureHostsErrorContent() throws {
        let collector = ContentCollector()
        let host = NSHostingView(rootView: StitchDictionaryView(catalogResult: .failure(StitchCatalogError.missingResource))
            .environment(\.locale, Locale(identifier: "en"))
            .onPreferenceChange(StitchDictionaryContentPreferenceKey.self) { collector.content = $0 })
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.close() }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        #expect(collector.content["stitchDictionary.error"] == "Could not load the dictionary")
        #expect(collector.content["stitchDictionary.search"] == nil)
    }
    @MainActor @Test func normalHostRendersSearchAndEntryControls() throws {
        let catalog = try StitchCatalog.bundled()
        let collector = ContentCollector()
        let host = NSHostingView(rootView: NavigationStack { StitchDictionaryView(catalogResult: .success(catalog)) }
            .environment(\.locale, Locale(identifier: "en"))
            .onPreferenceChange(StitchDictionaryContentPreferenceKey.self) { collector.content = $0 })
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 620, height: 1600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.close() }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        #expect(collector.content["stitchDictionary.search"] == "Search a name or abbreviation")
        let knit = try #require(catalog.entry(id: "knit"))
        #expect(collector.content["stitchDictionary.entry.knit"] == LocaleAwareText.string(knit.summaryKey, locale: Locale(identifier: "en")))
        #expect(collector.content["stitchDictionary.error"] == nil)
    }
    private final class ContentCollector {
        var content: [String: String] = [:]
    }
    #endif
}
