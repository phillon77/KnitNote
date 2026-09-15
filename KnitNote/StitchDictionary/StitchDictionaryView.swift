import SwiftUI

struct StitchDictionaryContentPreferenceKey: PreferenceKey {
    static let defaultValue: [String: String] = [:]
    static func reduce(value: inout [String: String], nextValue: () -> [String: String]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

enum StitchDictionaryMode: Hashable { case list, symbols }
struct StitchSymbolResult: Identifiable {
    let entry: StitchEntry
    let symbol: StitchSymbol
    let repetitions: Int?
    var id: String { symbol.id }
}
struct StitchDictionaryPresentation {
    let catalog: StitchCatalog?
    let errorKey: String?
    var query = ""
    var category: StitchCategory?
    var mode = StitchDictionaryMode.list
    init(catalogResult: Result<StitchCatalog, Error>) {
        switch catalogResult {
        case let .success(catalog): self.catalog = catalog; errorKey = nil
        case .failure: catalog = nil; errorKey = "stitchDictionary.error.title"
        }
    }
    var results: [StitchSearchResult] {
        guard let catalog else { return [] }
        return StitchSearch.results(query: query, category: category, in: catalog)
    }
    var symbols: [StitchSymbolResult] {
        results.flatMap { result in
            guard let entry = catalog?.entry(id: result.entryID) else { return [StitchSymbolResult]() }
            return entry.symbols.map { StitchSymbolResult(entry: entry, symbol: $0, repetitions: result.repetitions) }
        }
    }
    mutating func clear() { query = ""; category = nil }
}

struct StitchDictionaryView: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var presentation: StitchDictionaryPresentation
    private let diagrams: [StitchDiagram]
    init() { self.init(catalogResult: Result { try StitchCatalog.bundled() }) }
    init(catalogResult: Result<StitchCatalog, Error>) {
        do {
            diagrams = try StitchDiagram.loadBundled()
            _presentation = State(initialValue: StitchDictionaryPresentation(catalogResult: catalogResult))
        } catch {
            diagrams = []
            _presentation = State(initialValue: StitchDictionaryPresentation(catalogResult: .failure(error)))
        }
    }
    private func text(_ key: String) -> String { LocaleAwareText.string("stitchDictionary." + key, locale: locale) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let errorKey = presentation.errorKey {
                    ContentUnavailableView {
                        Label(LocaleAwareText.string(errorKey, locale: locale), systemImage: "exclamationmark.triangle")
                    } actions: {
                        Button(text("back")) { dismiss() }
                    }
                    .accessibilityIdentifier("stitchDictionary.error")
                    .preference(key: StitchDictionaryContentPreferenceKey.self, value: ["stitchDictionary.error": LocaleAwareText.string(errorKey, locale: locale)])
                } else if let catalog = presentation.catalog {
                    TextField(text("search.prompt"), text: $presentation.query)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("stitchDictionary.search")
                        .preference(key: StitchDictionaryContentPreferenceKey.self, value: ["stitchDictionary.search": text("search.prompt")])
                    Picker(text("title"), selection: $presentation.mode) {
                        Text(text("mode.list")).tag(StitchDictionaryMode.list)
                        Text(text("mode.symbols")).tag(StitchDictionaryMode.symbols)
                    }.pickerStyle(.segmented).accessibilityIdentifier("stitchDictionary.mode")
                    Picker(text("category.all"), selection: $presentation.category) {
                        Text(text("category.all")).tag(nil as StitchCategory?)
                        ForEach(StitchCategory.allCases, id: \.self) { category in
                            Text(text("category." + category.rawValue)).tag(category as StitchCategory?)
                        }
                    }.accessibilityIdentifier("stitchDictionary.category")
                    if !presentation.query.isEmpty || presentation.category != nil {
                        Button(text("empty.clear")) { presentation.clear() }
                            .accessibilityIdentifier("stitchDictionary.clear")
                    }
                    if presentation.results.isEmpty {
                        ContentUnavailableView(text("empty.title"), systemImage: "magnifyingglass")
                    } else if presentation.mode == .symbols {
                        if presentation.symbols.isEmpty {
                            Text(text("symbol.unavailable"))
                            Button(text("empty.switchToList")) { presentation.mode = .list }
                        } else {
                            StitchSymbolGrid(symbols: presentation.symbols, catalog: catalog, diagrams: diagrams)
                        }
                    } else {
                        ForEach(presentation.results, id: \.entryID) { result in
                            if let entry = catalog.entry(id: result.entryID) {
                                NavigationLink {
                                    StitchDetailView(entry: entry, repetitions: result.repetitions, catalog: catalog, diagrams: diagrams)
                                } label: {
                                    WatercolorCard {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(LocaleAwareText.string(entry.titleKey, locale: locale)).font(.headline)
                                            Text(entry.names["en"] ?? "").font(.subheadline)
                                            if let notation = entry.displayNotation {
                                                Text(notation).font(.subheadline.monospaced())
                                                    .preference(key: StitchDictionaryContentPreferenceKey.self, value: ["stitchDictionary.notation." + entry.id: notation])
                                            }
                                            Text(LocaleAwareText.string(entry.summaryKey, locale: locale))
                                                .preference(key: StitchDictionaryContentPreferenceKey.self, value: ["stitchDictionary.entry." + entry.id: LocaleAwareText.string(entry.summaryKey, locale: locale)])
                                            if let repetitions = result.repetitions {
                                                Text(LocaleAwareText.format("stitchDictionary.repeat.format", locale: locale, Int64(repetitions)))
                                            }
                                            HStack {
                                                ForEach(entry.symbols) { symbol in
                                                    if let diagram = diagrams.first(where: { $0.id == symbol.diagramID }) {
                                                        StitchDiagramView(diagram: diagram, accessibilityText: LocaleAwareText.string(symbol.traditionKey, locale: locale)).frame(width: 40, height: 40)
                                                    }
                                                }
                                            }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }.buttonStyle(.plain).accessibilityIdentifier("stitchDictionary.entry." + entry.id)
                            }
                        }
                    }
                }
            }.frame(maxWidth: 620).padding().frame(maxWidth: .infinity)
        }.background(WatercolorBackground()).navigationTitle(text("title"))
    }
}
