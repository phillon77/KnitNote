import SwiftUI

struct CreateProjectView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: JSONProjectStore
    @State private var name = ""
    @State private var selectedPhotoData: Data?
    @State private var removesPhoto = false
    @State private var isPhotoLoading = false
    @State private var errorMessage: String?
    let onRequestUnlock: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("project.name", text: $name) }
                Section("project.photo.optional") {
                    ProjectPhotoPicker(
                        existingURL: nil,
                        selectedData: $selectedPhotoData,
                        removesExistingPhoto: $removesPhoto,
                        isLoading: $isPhotoLoading
                    )
                }
            }
                .scrollContentBackground(.hidden)
                .background(WatercolorBackground())
                .navigationTitle("project.create")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("project.create") { create() }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPhotoLoading)
                    }
                }
                .alert("error.saveFailed", isPresented: Binding(
                    get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
                )) { Button("common.ok") {} } message: { Text(errorMessage ?? "") }
        }
#if os(macOS)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 560)
#else
        .frame(minWidth: 340, minHeight: 420)
#endif
        .tint(WatercolorTheme.actionBerry)
    }

    private func create() {
        do {
            try store.add(name: name, photoData: selectedPhotoData)
            dismiss()
        } catch {
            switch CreateProjectFailureMapper.presentation(for: error) {
            case .requestUnlock:
                onRequestUnlock()
                dismiss()
            case let .saveError(message):
                errorMessage = message
            }
        }
    }
}
