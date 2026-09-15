import SwiftUI

struct StitchSymbolGrid: View {
    @Environment(\.locale) private var locale
    let symbols: [StitchSymbolResult]
    let catalog: StitchCatalog
    let diagrams: [StitchDiagram]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), alignment: .top)], spacing: 16) {
            ForEach(symbols) { result in
                NavigationLink {
                    StitchDetailView(entry: result.entry, repetitions: result.repetitions, catalog: catalog, diagrams: diagrams)
                } label: {
                    WatercolorCard {
                        VStack(alignment: .leading, spacing: 10) {
                            if let diagram = diagrams.first(where: { $0.id == result.symbol.diagramID }) {
                                StitchDiagramView(diagram: diagram, accessibilityText: LocaleAwareText.string(result.symbol.conditionKey, locale: locale)).frame(maxHeight: 180)
                            }
                            Text(LocaleAwareText.string(result.entry.titleKey, locale: locale)).font(.headline)
                            Text(LocaleAwareText.string(result.symbol.traditionKey, locale: locale)).font(.subheadline)
                            ForEach(result.symbol.sourceIDs, id: \.self) { id in
                                if let source = catalog.sources.first(where: { $0.id == id }) {
                                    Text(source.title).font(.caption)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("stitchDictionary.symbol." + result.symbol.id)
            }
        }
    }
}
