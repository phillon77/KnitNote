import SwiftUI

struct CreateYarnView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var store: JSONProjectStore
    @State private var draft = YarnEditorDraft()
    @State private var selectedPhotoData: Data?
    @State private var removesExistingPhoto = false
    @State private var isPhotoLoading = false
    @State private var errorMessage: YarnOperationFailure?
    @State private var labelPhotos: [Data]
    @State private var didApplySeed = false
    private let seed: YarnLabelDraftSeed?
    private let onSaved: (() -> Void)?

    init(
        seed: YarnLabelDraftSeed? = nil,
        labelPhotos: [Data] = [],
        onSaved: (() -> Void)? = nil
    ) {
        self.seed = seed
        self.onSaved = onSaved
        _labelPhotos = State(initialValue: Array(labelPhotos.prefix(2)))
    }

    var body: some View {
        NavigationStack {
            Form {
                YarnEditorFields(draft: $draft)
                Section("yarn.photo") {
                    YarnPhotoPicker(
                        existingURL: nil,
                        selectedData: $selectedPhotoData,
                        removesExistingPhoto: $removesExistingPhoto,
                        isLoading: $isPhotoLoading
                    )
                }
            }
            .scrollContentBackground(.hidden)
            .background(WatercolorBackground())
            .navigationTitle("yarn.create")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { save() }
                        .disabled(!draft.canSave(locale: locale) || isPhotoLoading)
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
            guard !didApplySeed, let seed else { return }
            draft.apply(seed, locale: locale)
            didApplySeed = true
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func save() {
        do {
            let currentProjectIDs = Set(store.projects.map(\.id))
            draft.linkedProjectIDs.formIntersection(currentProjectIDs)
            let yarn = try draft.makeYarn(locale: locale)
            try store.addYarn(
                yarn,
                photoData: selectedPhotoData,
                labelPhotos: Array(labelPhotos.prefix(2))
            )
            dismiss()
            onSaved?()
        } catch {
            errorMessage = .saving(error)
        }
    }
}
