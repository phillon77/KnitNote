import SwiftUI

struct AllNotesView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: JSONProjectStore
    let projectID: UUID
    let counterID: UUID
    @State private var editingNote: CounterRowSelection?

    private var sortedNotes: [RowNote] {
        guard let selectedCounter = store.project(id: projectID)?.counters.first(where: { $0.id == counterID }) else {
            return []
        }
        return selectedCounter.rowNotes.sorted { $0.row > $1.row }
    }

    var body: some View {
        NavigationStack {
            List(sortedNotes) { note in
                Button {
                    editingNote = CounterRowSelection(counterID: counterID, row: note.row)
                } label: {
                    VStack(alignment: .leading) {
                        Text(note.row, format: .number)
                            .font(.headline.monospacedDigit())
                        Text(note.text)
                    }
                }
                .swipeActions {
                    Button("common.delete", role: .destructive) {
                        try? store.deleteNote(projectID: projectID, counterID: counterID, row: note.row)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(WatercolorBackground())
            .navigationTitle("notes.all")
            .toolbar {
                Button("common.ok") { dismiss() }
            }
            .sheet(item: $editingNote) { selection in
                EditRowNoteView(
                    projectID: projectID,
                    counterID: selection.counterID,
                    row: selection.row
                )
            }
        }
        .tint(WatercolorTheme.actionBerry)
    }
}
