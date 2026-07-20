import PhotosUI
import SwiftUI

#if os(iOS)
import UIKit
#endif

struct JournalPhotoPicker: View {
    @Binding var selectedData: Data?
    @Binding var isLoading: Bool
    @State private var pickerItem: PhotosPickerItem?
    @State private var publicationGate = ProjectJournalAsyncPublicationGate()
    @State private var previewRevision = UUID()
    @State private var loadTask: Task<Void, Never>?
    @State private var showingCamera = false
    @State private var loadFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                ProjectJournalPhotoView(
                    url: nil,
                    data: selectedData,
                    dataRevision: previewRevision,
                    maximumPixelSize: 900
                )
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .clipShape(.rect(cornerRadius: 18, style: .continuous))

                if isLoading {
                    ProgressView("journal.photo.loading")
                        .padding()
                        .background(.regularMaterial, in: .rect(cornerRadius: 14))
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 12) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("journal.photo.library", systemImage: "photo.on.rectangle")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(isLoading)

#if os(iOS)
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button {
                        cancelPendingLoad()
                        showingCamera = true
                    } label: {
                        Label("journal.photo.camera", systemImage: "camera")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoading)
                }
#endif
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            load(item)
        }
#if os(iOS)
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCaptureView { data in
                cancelPendingLoad()
                selectedData = data
                previewRevision = UUID()
            }
            .ignoresSafeArea()
        }
#endif
        .alert("journal.photo.loadFailed", isPresented: $loadFailed) {
            Button("common.ok") {}
        }
        .onDisappear {
            cancelPendingLoad()
        }
    }

    private func load(_ item: PhotosPickerItem) {
        loadTask?.cancel()
        let revision = publicationGate.begin()
        isLoading = true
        loadTask = Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    finishLoadFailure(for: revision)
                    return
                }
                try Task.checkCancellation()
                guard publicationGate.finish(revision) else { return }
                selectedData = data
                previewRevision = UUID()
                finishLoad()
            } catch is CancellationError {
                finishCancelledLoad(for: revision)
            } catch {
                finishLoadFailure(for: revision)
            }
        }
    }

    private func finishLoad() {
        pickerItem = nil
        isLoading = false
        loadTask = nil
    }

    private func finishLoadFailure(for revision: UUID) {
        guard publicationGate.finish(revision) else { return }
        finishLoad()
        loadFailed = true
    }

    private func finishCancelledLoad(for revision: UUID) {
        guard publicationGate.finish(revision) else { return }
        finishLoad()
    }

    private func cancelPendingLoad() {
        publicationGate.cancel()
        loadTask?.cancel()
        loadTask = nil
        pickerItem = nil
        isLoading = false
    }
}
