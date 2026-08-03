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
    @State private var initialLinkedProjectIDs: Set<UUID> = []
    @State private var scannedLabelPhotos: [Data]?
    @State private var retainedLabelPhotoFilenames: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    YarnLabelScanLauncher { output in
                        draft.apply(output.seed, locale: locale)
                        scannedLabelPhotos = output.labelPhotos
                    } label: {
                        Label("yarn.scan.action", systemImage: "viewfinder")
                    }
                }
                YarnEditorFields(draft: $draft)
                if !labelPhotoItems.isEmpty {
                    Section("yarn.labelPhotos") {
                        YarnLabelPhotoGallery(items: labelPhotoItems) { index in
                            removeLabelPhoto(at: index)
                        }
                    }
                }
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
            initialLinkedProjectIDs = yarn.linkedProjectIDs
            retainedLabelPhotoFilenames = yarn.labelPhotoFilenames
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

    private var labelPhotoItems: [YarnLabelPhotoItem] {
        if let scannedLabelPhotos {
            return scannedLabelPhotos.enumerated().map {
                YarnLabelPhotoItem.selected($0.element, index: $0.offset)
            }
        }
        return retainedLabelPhotoFilenames.compactMap { filename in
            store.labelPhotoURL(filename: filename).map(YarnLabelPhotoItem.stored)
        }
    }

    private func removeLabelPhoto(at index: Int) {
        if scannedLabelPhotos != nil {
            guard scannedLabelPhotos?.indices.contains(index) == true else { return }
            scannedLabelPhotos?.remove(at: index)
        } else {
            guard retainedLabelPhotoFilenames.indices.contains(index) else { return }
            retainedLabelPhotoFilenames.remove(at: index)
        }
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
            var mergedDraft = draft
            mergedDraft.linkedProjectIDs = YarnLinkSelectionMerge.merged(
                initial: initialLinkedProjectIDs,
                edited: draft.linkedProjectIDs,
                current: yarn.linkedProjectIDs
            )
            let updated = try mergedDraft.applying(to: yarn, locale: locale)
            let labelPhotoChange: YarnLabelPhotoChange
            if let scannedLabelPhotos {
                labelPhotoChange = .replace(
                    first: scannedLabelPhotos.first,
                    second: scannedLabelPhotos.dropFirst().first
                )
            } else if retainedLabelPhotoFilenames != yarn.labelPhotoFilenames {
                labelPhotoChange = .retainExisting(retainedLabelPhotoFilenames)
            } else {
                labelPhotoChange = .unchanged
            }
            try store.updateYarn(
                updated,
                photoChange: photoChange,
                labelPhotoChange: labelPhotoChange
            )
            dismiss()
        } catch {
            errorMessage = .saving(error)
        }
    }
}
