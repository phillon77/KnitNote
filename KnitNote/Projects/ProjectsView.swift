import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject private var store: JSONProjectStore
    @State private var showingCreate = false
    @State private var pendingDeletion: StoredProject?
    var body: some View {
        NavigationStack {
            Group { if store.projects.isEmpty { ContentUnavailableView("projects.empty.title", systemImage: "square.grid.2x2", description: Text("projects.empty.message")) } else {
                List(store.projects) { project in
                    NavigationLink(value: project.id) { VStack(alignment: .leading) { Text(project.name).font(.headline); Text(verbatim: "\(project.currentRow)").foregroundStyle(.secondary) } }
                        .swipeActions { Button("common.delete", role: .destructive) { pendingDeletion = project } }
                }
            }}
            .navigationTitle("nav.projects")
            .navigationDestination(for: UUID.self) { ProjectDetailView(projectID: $0) }
            .toolbar { Button("projects.add", systemImage: "plus") { showingCreate = true } }
            .sheet(isPresented: $showingCreate) { CreateProjectView() }
            .confirmationDialog("project.delete.title", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
                Button("common.delete", role: .destructive) { if let id = pendingDeletion?.id { try? store.delete(id: id) }; pendingDeletion = nil }
                Button("common.cancel", role: .cancel) { pendingDeletion = nil }
            }
        }
    }
}
