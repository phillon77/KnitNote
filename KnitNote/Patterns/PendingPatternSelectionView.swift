import SwiftUI

struct PendingPatternSelectionView: View {
    @EnvironmentObject private var store: JSONProjectStore
    @EnvironmentObject private var processor: PatternInboxProcessor
    let selection: PendingInboxPatternSelection

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(selection.candidatePatternIDs, id: \.self) { patternID in
                        if let pattern = store.patterns.first(where: { $0.id == patternID }) {
                            Button {
                                processor.resolve(
                                    itemID: selection.item.id,
                                    resolution: .existing(patternID)
                                )
                            } label: {
                                Label(pattern.displayName, systemImage: "doc.text.image")
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            .accessibilityLabel(Text(pattern.displayName))
                        }
                    }
                } header: {
                    Text("patterns.inbox.choose.message")
                }

                Section {
                    Button {
                        processor.resolve(
                            itemID: selection.item.id,
                            resolution: .createNew
                        )
                    } label: {
                        Label("patterns.inbox.createNew", systemImage: "plus")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityLabel(Text("patterns.inbox.createNew"))
                }
            }
            .navigationTitle("patterns.inbox.choose.title")
        }
        .interactiveDismissDisabled()
    }
}
