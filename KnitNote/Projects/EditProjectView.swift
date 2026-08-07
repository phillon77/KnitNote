import SwiftUI

@MainActor
enum EditProjectDeletionAction {
    static func perform(
        projectID: UUID,
        store: JSONProjectStore,
        onDeleted: () -> Void
    ) throws {
        try store.delete(id: projectID)
        onDeleted()
    }
}

struct EditProjectView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: JSONProjectStore
    let projectID: UUID
    let onDeleted: () -> Void
    @State private var name = ""
    @State private var toolType: ProjectToolType?
    @State private var toolSize = ""
    @State private var toolNotes = ""
    @State private var selectedPhotoData: Data?
    @State private var removesExistingPhoto = false
    @State private var isPhotoLoading = false
    @State private var errorMessage: String?
    @State private var showingDeleteConfirmation = false

    init(projectID: UUID, onDeleted: @escaping () -> Void = {}) {
        self.projectID = projectID
        self.onDeleted = onDeleted
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("project.name", text: $name)
                }
                Section("project.photo") {
                    ProjectPhotoPicker(
                        existingURL: project.flatMap(store.photoURL(for:)),
                        selectedData: $selectedPhotoData,
                        removesExistingPhoto: $removesExistingPhoto,
                        isLoading: $isPhotoLoading
                    )
                }
                Section("project.tool.section") {
                    Picker("project.tool.type", selection: $toolType) {
                        Text("project.tool.type.none").tag(ProjectToolType?.none)
                        ForEach(ProjectToolType.allCases, id: \.self) { toolType in
                            Text(toolTypeLocalizationKey(toolType)).tag(Optional(toolType))
                        }
                    }
                    TextField("project.tool.size", text: $toolSize)
                    TextField("project.tool.notes", text: $toolNotes, axis: .vertical)
                }
                if let project {
                    Section("project.status") {
                        if let completedAt = project.completedAt {
                            LabeledContent("project.status.completed") {
                                Text(completedAt, format: .dateTime.year().month().day())
                            }
                            Button("project.status.resume", systemImage: "arrow.counterclockwise") {
                                changeCompletion(resume: true)
                            }
                        } else {
                            LabeledContent("project.status") {
                                Text("project.status.inProgress")
                            }
                            Button("project.status.markCompleted", systemImage: "checkmark.seal") {
                                changeCompletion(resume: false)
                            }
                        }
                    }
                }
                Section {
                    Button("common.delete", systemImage: "trash", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(WatercolorBackground())
            .navigationTitle("project.edit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPhotoLoading)
                }
            }
            .alert("error.saveFailed", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("common.ok") {} } message: { Text(errorMessage ?? "") }
            .confirmationDialog(
                "project.delete.title",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("common.delete", role: .destructive) { deleteProject() }
                Button("common.cancel", role: .cancel) {}
            }
        }
        .frame(minWidth: 340, minHeight: 420)
        .tint(WatercolorTheme.actionBerry)
        .onAppear {
            name = project?.name ?? ""
            toolType = project?.toolType
            toolSize = project?.toolSize ?? ""
            toolNotes = project?.toolNotes ?? ""
        }
    }

    private var project: StoredProject? { store.project(id: projectID) }

    private func save() {
        let photoChange: ProjectPhotoChange
        if let selectedPhotoData {
            photoChange = .replace(selectedPhotoData)
        } else if removesExistingPhoto {
            photoChange = .remove
        } else {
            photoChange = .unchanged
        }
        do {
            try store.updateProject(
                id: projectID,
                name: name,
                toolType: toolType,
                toolSize: toolSize,
                toolNotes: toolNotes,
                photoChange: photoChange
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteProject() {
        do {
            try EditProjectDeletionAction.perform(
                projectID: projectID,
                store: store,
                onDeleted: {
                    dismiss()
                    onDeleted()
                }
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toolTypeLocalizationKey(_ toolType: ProjectToolType) -> LocalizedStringKey {
        switch toolType {
        case .crochetHook:
            "project.tool.type.crochetHook"
        case .knittingNeedles:
            "project.tool.type.knittingNeedles"
        case .other:
            "project.tool.type.other"
        }
    }

    private func changeCompletion(resume: Bool) {
        do {
            if resume {
                try store.resumeProject(projectID: projectID)
            } else {
                try store.markCompleted(projectID: projectID)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
