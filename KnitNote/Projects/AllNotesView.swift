import SwiftUI
struct AllNotesView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: JSONProjectStore
    let projectID: UUID
    @State private var editingRow: Int?
    var body: some View { NavigationStack { List(store.project(id: projectID)?.sortedNotes ?? []) { note in Button { editingRow = note.row } label: { VStack(alignment: .leading) { Text(verbatim: "\(note.row)").font(.headline); Text(note.text) } }.swipeActions { Button("common.delete", role: .destructive) { try? store.deleteNote(projectID: projectID, row: note.row) } } }.navigationTitle("notes.all").toolbar { Button("common.ok") { dismiss() } }.sheet(item: $editingRow) { EditRowNoteView(projectID: projectID, row: $0) } } }
}
