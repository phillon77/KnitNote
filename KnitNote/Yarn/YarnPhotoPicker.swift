import PhotosUI
import SwiftUI

#if os(iOS)
import UIKit
#endif

struct YarnPhotoPicker: View {
    let existingURL: URL?
    @Binding var selectedData: Data?
    @Binding var removesExistingPhoto: Bool
    @Binding var isLoading: Bool
    @State private var pickerItem: PhotosPickerItem?
    @State private var selectionRevision = UUID()
    @State private var showingCamera = false
    @State private var loadFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            YarnPhotoView(
                url: removesExistingPhoto ? nil : existingURL,
                data: selectedData
            )
            .frame(maxWidth: .infinity)
            .frame(height: 190)
            .clipShape(.rect(cornerRadius: 18))

            HStack {
                if hasPhoto {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("yarn.photo.replace", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.bordered)
                } else {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("yarn.photo.choose", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.bordered)
                }

#if os(iOS)
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button {
                        invalidatePendingLoad()
                        showingCamera = true
                    } label: {
                        Label("yarn.photo.take", systemImage: "camera")
                    }
                    .buttonStyle(.bordered)
                }
#endif

                Spacer()
                if hasPhoto {
                    Button(role: .destructive) {
                        invalidatePendingLoad()
                        pickerItem = nil
                        selectedData = nil
                        removesExistingPhoto = true
                    } label: {
                        Label("yarn.photo.remove", systemImage: "trash")
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel(Text("yarn.photo.remove"))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
                }
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            let revision = UUID()
            selectionRevision = revision
            isLoading = true
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        finishLoadFailure(for: revision)
                        return
                    }
                    guard selectionRevision == revision else { return }
                    selectedData = data
                    removesExistingPhoto = false
                    isLoading = false
                } catch {
                    finishLoadFailure(for: revision)
                }
            }
        }
#if os(iOS)
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCaptureView { data in
                invalidatePendingLoad()
                selectedData = data
                removesExistingPhoto = false
            }
            .ignoresSafeArea()
        }
#endif
        .alert("yarn.photo.loadFailed", isPresented: $loadFailed) {
            Button("common.ok") {}
        }
    }

    private var hasPhoto: Bool {
        selectedData != nil || (!removesExistingPhoto && existingURL != nil)
    }

    private func finishLoadFailure(for revision: UUID) {
        guard selectionRevision == revision else { return }
        invalidatePendingLoad()
        loadFailed = true
    }

    private func invalidatePendingLoad() {
        selectionRevision = UUID()
        pickerItem = nil
        isLoading = false
    }
}
