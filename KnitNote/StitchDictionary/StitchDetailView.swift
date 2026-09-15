import SwiftUI

struct StitchDetailPresentation {
    let entry: StitchEntry
    let repetitions: Int?
    var consumes: Int { entry.consumes }
    var produces: Int { entry.produces }
}
struct StitchDetailView: View {
    @Environment(\.locale) private var locale
    let entry: StitchEntry
    let repetitions: Int?
    let catalog: StitchCatalog
    let diagrams: [StitchDiagram]
    private var presentation: StitchDetailPresentation { StitchDetailPresentation(entry: entry, repetitions: repetitions) }
    private func text(_ key: String) -> String { LocaleAwareText.string(key, locale: locale) }
    private func heading(_ key: String) -> some View { Text(text("stitchDictionary.detail." + key)).font(.title2.bold()).accessibilityAddTraits(.isHeader) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let repetitions {
                    Text(LocaleAwareText.format("stitchDictionary.repeat.format", locale: locale, Int64(repetitions))).font(.headline)
                }
                heading("names")
                ForEach(["zh-Hant", "zh-Hans", "en", "ja", "ko"], id: \.self) { language in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(text("stitchDictionary.name." + language)).font(.caption).foregroundStyle(.secondary)
                        Text(entry.names[language] ?? "")
                    }
                }
                heading("meaning")
                Text(text(entry.summaryKey))
                heading("symbols")
                if entry.symbols.isEmpty { Text(text("stitchDictionary.symbol.unavailable")) }
                ForEach(entry.symbols) { symbol in
                    WatercolorCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(text(symbol.traditionKey)).font(.headline)
                            drawing(symbol.diagramID, alternative: symbol.conditionKey)
                            Text(text(symbol.conditionKey))
                            sources(symbol.sourceIDs)
                        }
                    }
                }
                heading("steps")
                ForEach(Array(entry.steps.enumerated()), id: \.offset) { index, step in
                    WatercolorCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(LocaleAwareText.format("stitchDictionary.step.format", locale: locale, Int64(index + 1))).font(.headline)
                            Text(text(step.textKey))
                            drawing(step.diagramID, alternative: step.accessibilityKey)
                        }
                    }
                }
                Text(text("stitchDictionary.legend.title")).font(.headline)
                ForEach(["leftNeedle", "rightNeedle", "cableNeedle", "workingYarn", "oldLoop", "newLoop", "arrow"], id: \.self) { role in
                    Text(text("stitchDictionary.legend." + role))
                }
                heading("count")
                count("consumes", presentation.consumes)
                count("produces", presentation.produces)
                count("net", presentation.produces - presentation.consumes)
                heading("notes")
                ForEach(entry.noteKeys, id: \.self) { key in Text(text(key)) }
                heading("sources")
                sources(entry.sourceIDs)
                heading("related")
                ForEach(entry.relatedIDs, id: \.self) { id in
                    if let related = catalog.entry(id: id) {
                        NavigationLink(text(related.titleKey)) {
                            StitchDetailView(entry: related, repetitions: nil, catalog: catalog, diagrams: diagrams)
                        }.accessibilityIdentifier("stitchDictionary.entry." + id)
                    }
                }
            }.frame(maxWidth: 620, alignment: .leading).padding().frame(maxWidth: .infinity)
        }.background(WatercolorBackground()).navigationTitle(text(entry.titleKey))
    }
    @ViewBuilder private func drawing(_ id: String, alternative: String) -> some View {
        if let diagram = diagrams.first(where: { $0.id == id }) {
            StitchDiagramView(diagram: diagram, accessibilityText: text(alternative)).frame(maxWidth: 360)
        }
    }
    private func count(_ key: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text("stitchDictionary.count." + key)).font(.subheadline)
            Text(LocaleAwareText.format("stitchDictionary.count.value", locale: locale, Int64(value)))
        }
    }
    private func sources(_ ids: [String]) -> some View {
        ForEach(ids, id: \.self) { id in
            if let source = catalog.sources.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 4) {
                    Link(source.title, destination: source.url)
                    Text(source.checkedOn).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
