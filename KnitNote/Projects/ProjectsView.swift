import SwiftUI

struct ProjectsView: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject private var store: JSONProjectStore
    @EnvironmentObject private var entitlementCoordinator: EntitlementCoordinator
    @State private var showingCreate = false
    @State private var pendingUnlockAfterCreate = false
    @State private var pendingDeletion: StoredProject?
    let onShowUnlock: () -> Void
    let onCreateSheetPresentationChanged: (Bool) -> Void

    init(
        onShowUnlock: @escaping () -> Void = {},
        onCreateSheetPresentationChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.onShowUnlock = onShowUnlock
        self.onCreateSheetPresentationChanged =
            onCreateSheetPresentationChanged
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        TrialStatusPill(
                            snapshot: entitlementCoordinator.snapshot,
                            action: onShowUnlock
                        )
                        .frame(maxWidth: 880, alignment: .leading)

                        if store.projects.isEmpty {
                            LemonEmptyState(
                                title: "projects.empty.title",
                                message: "projects.empty.message",
                                actionTitle: "projects.add",
                                action: showCreateSheet
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
            .background {
                ProjectsPaintingBackground()
            }
            .navigationTitle("nav.projects")
            .navigationDestination(for: UUID.self) { ProjectDetailView(projectID: $0) }
            .toolbar {
                Button(
                    "projects.add",
                    systemImage: "plus",
                    action: showCreateSheet
                )
            }
            .sheet(isPresented: $showingCreate, onDismiss: {
                onCreateSheetPresentationChanged(false)
                guard pendingUnlockAfterCreate else { return }
                pendingUnlockAfterCreate = false
                onShowUnlock()
            }) {
                CreateProjectView(onRequestUnlock: {
                    pendingUnlockAfterCreate = true
                })
                .environment(\.locale, locale)
#if os(macOS)
                .presentationSizing(.fitted)
#endif
                .onAppear {
                    onCreateSheetPresentationChanged(true)
                }
            }
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

    private func showCreateSheet() {
        showingCreate = true
    }
}
