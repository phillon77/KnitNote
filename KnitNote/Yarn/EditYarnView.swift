import SwiftUI

struct EditYarnView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var store: JSONProjectStore
    let yarnID: UUID
    @State private var draft = YarnEditorDraft()
    @State private var selectedPhotoData: Data?
    @State private var removesExistingPhoto = false
    @State private var isPhotoLoading = false
    @State private var errorMessage: YarnOperationFailure?
    @State private var didLoadYarn = false

    var body: some View {
        NavigationStack {
            Form {
                YarnEditorFields(draft: $draft)
                Section("yarn.photo") {
                    YarnPhotoPicker(
                        existingURL: yarn.flatMap(store.photoURL(for:)),
                        selectedData: $selectedPhotoData,
                        removesExistingPhoto: $removesExistingPhoto,
                        isLoading: $isPhotoLoading
                    )
                }
            }
            .scrollContentBackground(.hidden)
            .background(WatercolorBackground())
            .navigationTitle("yarn.edit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { save() }
                        .disabled(yarn == nil || !draft.canSave(locale: locale) || isPhotoLoading)
                }
            }
            .alert("error.saveFailed", isPresented: errorIsPresented) {
                Button("common.retry") { save() }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text(LocalizedStringKey(errorMessage?.rawValue ?? YarnOperationFailure.saveRetry.rawValue))
            }
        }
        .frame(minWidth: 340, minHeight: 520)
        .tint(WatercolorTheme.actionBerry)
        .onAppear {
            guard !didLoadYarn, let yarn else { return }
            draft = YarnEditorDraft(yarn: yarn, locale: locale)
            didLoadYarn = true
        }
    }

    private var yarn: StoredYarn? {
        store.yarn(id: yarnID)
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func save() {
        guard let yarn else { return }
        let photoChange: YarnPhotoChange
        if let selectedPhotoData {
            photoChange = .replace(selectedPhotoData)
        } else if removesExistingPhoto {
            photoChange = .remove
        } else {
            photoChange = .unchanged
        }

        do {
            let currentProjectIDs = Set(store.projects.map(\.id))
            draft.linkedProjectIDs.formIntersection(currentProjectIDs)
            let updated = try draft.applying(to: yarn, locale: locale)
            try store.updateYarn(updated, photoChange: photoChange)
            dismiss()
        } catch {
            errorMessage = .saving(error)
        }
    }
}
