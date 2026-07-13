import SwiftUI
struct EditRowNoteView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: JSONProjectStore
    let projectID: UUID; let row: Int
    @State private var text = ""
    var body: some View { NavigationStack { Form { Section { TextEditor(text: $text).frame(minHeight: 160) } header: { Text(verbatim: String(format: String(localized: "notes.row.format"), row)) } }.navigationTitle("notes.edit").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("common.save") { try? store.saveNote(projectID: projectID, row: row, text: text); dismiss() } }
    }}.frame(minWidth: 340, minHeight: 280).onAppear { text = store.project(id: projectID)?.note(row: row)?.text ?? "" } }
}
