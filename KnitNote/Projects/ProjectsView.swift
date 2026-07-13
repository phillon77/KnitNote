import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject private var store: JSONProjectStore
    @State private var showingCreate = false
    @State private var pendingDeletion: StoredProject?

    var body: some View {
        NavigationStack {
            ZStack {
                WatercolorBackground()
                ScrollView {
                    LazyVStack(spacing: 16) {
                        FamilyHeroView()
                        if store.projects.isEmpty {
                            LemonEmptyState(
                                title: "projects.empty.title",
                                message: "projects.empty.message",
                                actionTitle: "projects.add",
                                action: { showingCreate = true }
                            )
                        } else {
                            ForEach(store.projects) { project in
                                NavigationLink(value: project.id) {
                                    ProjectCard(project: project)
                                }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    Button("common.delete", role: .destructive) {
                                        pendingDeletion = project
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 880)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("nav.projects")
            .navigationDestination(for: UUID.self) { ProjectDetailView(projectID: $0) }
            .toolbar { Button("projects.add", systemImage: "plus") { showingCreate = true } }
            .sheet(isPresented: $showingCreate) { CreateProjectView() }
            .confirmationDialog(
                "project.delete.title",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                )
            ) {
                Button("common.delete", role: .destructive) {
                    if let id = pendingDeletion?.id { try? store.delete(id: id) }
                    pendingDeletion = nil
                }
                Button("common.cancel", role: .cancel) { pendingDeletion = nil }
            }
        }
    }
}
