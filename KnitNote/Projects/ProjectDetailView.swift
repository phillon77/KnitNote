import SwiftUI
struct ProjectDetailView: View {
    @EnvironmentObject private var store: JSONProjectStore
    let projectID: UUID
    @State private var showingRename = false
    @State private var editingRow: Int?
    @State private var showingAllNotes = false
    @State private var showingPatterns = false
    var body: some View {
        if let project = store.project(id: projectID) { VStack(spacing: 24) {
            Text(project.name).font(.title2.bold()); Text(project.currentRow, format: .number).font(.system(size: 88, weight: .bold, design: .rounded))
            Button { try? store.completeRow(id: projectID) } label: { Label("project.completeRow", systemImage: "plus.circle.fill").frame(maxWidth: .infinity).padding() }.buttonStyle(.borderedProminent)
            Button("project.undo") { try? store.undoRow(id: projectID) }.disabled(project.currentRow == 0)
            Button("notes.edit") { editingRow = project.currentRow }
            Button("patterns.open") { showingPatterns = true }
            if !project.sortedNotes.isEmpty { VStack(alignment: .leading) { Text("notes.recent").font(.headline); ForEach(project.sortedNotes.prefix(3)) { note in Button { editingRow = note.row } label: { HStack { Text(verbatim: "\(note.row)").font(.headline); Text(note.text).lineLimit(1) } }.buttonStyle(.plain) }; if project.rowNotes.count > 3 { Button("notes.all") { showingAllNotes = true } } }.frame(maxWidth: .infinity, alignment: .leading) }
        }.padding().frame(maxWidth: 560).navigationTitle(project.name).toolbar { Button("project.rename", systemImage: "pencil") { showingRename = true } }.sheet(isPresented: $showingRename) { RenameProjectView(projectID: projectID) }.sheet(item: $editingRow) { EditRowNoteView(projectID: projectID, row: $0) }.sheet(isPresented: $showingAllNotes) { AllNotesView(projectID: projectID) }.sheet(isPresented: $showingPatterns) { ProjectPatternsView(projectID: projectID) } }
    }
}

extension Int: @retroactive Identifiable { public var id: Int { self } }
