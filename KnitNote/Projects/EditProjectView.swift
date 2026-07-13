import SwiftUI

struct EditProjectView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: JSONProjectStore
    let projectID: UUID
    @State private var name = ""
    @State private var selectedPhotoData: Data?
    @State private var removesExistingPhoto = false
    @State private var isPhotoLoading = false
    @State private var errorMessage: String?

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
        }
        .frame(minWidth: 340, minHeight: 420)
        .tint(WatercolorTheme.actionBerry)
        .onAppear { name = project?.name ?? "" }
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
            try store.updateProject(id: projectID, name: name, photoChange: photoChange)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
