import SwiftUI

struct YarnLibraryView: View {
    @EnvironmentObject private var store: JSONProjectStore
    @State private var showingCreate = false
    @State private var editingYarn: StoredYarn?
    @State private var pendingDeletion: StoredYarn?
    @State private var showingDeleteConfirmation = false
    @State private var deleteFailure: YarnOperationFailure?

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                WatercolorBackground()
                ScrollView {
                    if store.yarns.isEmpty {
                        LemonEmptyState(
                            title: "yarn.empty.title",
                            message: "yarn.empty.message",
                            actionTitle: "yarn.create",
                            action: { showingCreate = true }
                        )
                        .frame(maxWidth: 520)
                        .frame(maxWidth: .infinity)
                    } else {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(store.yarns) { yarn in
                                NavigationLink(value: yarn.id) {
                                    YarnCard(yarn: yarn, photoURL: store.photoURL(for: yarn))
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("yarn.edit", systemImage: "pencil") {
                                        editingYarn = yarn
                                    }
                                    Button("yarn.delete", systemImage: "trash", role: .destructive) {
                                        pendingDeletion = yarn
                                        showingDeleteConfirmation = true
                                    }
                                }
                            }
                        }
                    }
                }
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .contentMargins(.vertical, 16, for: .scrollContent)
            }
            .navigationTitle("yarn.library.title")
            .navigationDestination(for: UUID.self) { yarnID in
                YarnDetailView(yarnID: yarnID)
            }
            .toolbar {
                Button("yarn.create", systemImage: "plus") {
                    showingCreate = true
                }
            }
            .sheet(isPresented: $showingCreate) {
                CreateYarnView()
            }
            .sheet(item: $editingYarn) { yarn in
                EditYarnView(yarnID: yarn.id)
            }
            .confirmationDialog(
                "yarn.delete.confirm",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("yarn.delete", role: .destructive) {
                    deletePendingYarn()
                }
                Button("common.cancel", role: .cancel) {
                    pendingDeletion = nil
                }
            }
            .alert("yarn.error.deleteFailed.title", isPresented: deleteFailureIsPresented) {
                Button("common.retry") { deletePendingYarn() }
                Button("common.cancel", role: .cancel) {
                    pendingDeletion = nil
                }
            } message: {
                Text(LocalizedStringKey(
                    deleteFailure?.rawValue ?? YarnOperationFailure.deleteFailed.rawValue
                ))
            }
        }
    }

    private var deleteFailureIsPresented: Binding<Bool> {
        Binding(
            get: { deleteFailure != nil },
            set: { if !$0 { deleteFailure = nil } }
        )
    }

    private func deletePendingYarn() {
        guard let id = pendingDeletion?.id else { return }
        do {
            try store.deleteYarn(id: id)
            pendingDeletion = nil
            deleteFailure = nil
        } catch {
            deleteFailure = .deleting(error)
        }
    }
}
