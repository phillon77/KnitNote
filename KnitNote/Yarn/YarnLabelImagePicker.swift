import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import AVFoundation
import UIKit
#endif

struct YarnLabelImagePicker: View {
    @Binding var images: [Data]
    @Binding var isLoading: Bool
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showingPhotoLibrary = false
    @State private var showingCamera = false
    @State private var showingFileImporter = false
    @State private var errorPresented = false
    @State private var cameraPermissionDenied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if images.isEmpty {
                ContentUnavailableView(
                    "yarn.scan.images.empty",
                    systemImage: "viewfinder",
                    description: Text("yarn.scan.images.hint")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                HStack(spacing: 12) {
                    ForEach(images.indices, id: \.self) { index in
                        ZStack(alignment: .topTrailing) {
                            YarnPhotoView(url: nil, data: images[index])
                                .frame(maxWidth: .infinity)
                                .frame(height: 180)
                                .clipShape(.rect(cornerRadius: 16))
                            Button(role: .destructive) {
                                images.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .accessibilityLabel(Text("yarn.scan.image.remove"))
                            .padding(8)
                        }
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { imageActions }
                VStack(alignment: .leading, spacing: 10) { imageActions }
            }
        }
        .onChange(of: pickerItems) { _, items in load(items) }
        .photosPicker(
            isPresented: $showingPhotoLibrary,
            selection: $pickerItems,
            maxSelectionCount: 2,
            matching: .images
        )
#if os(iOS)
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCaptureView { data in
                if images.count < 2 { images.append(data) }
            }
            .ignoresSafeArea()
        }
#endif
#if os(macOS)
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            do {
                let urls = try result.get()
                images = try MacYarnLabelFileImporter().load(urls)
            } catch {
                errorPresented = true
            }
        }
#endif
        .alert("yarn.scan.image.error", isPresented: $errorPresented) {
            Button("common.ok") {}
        }
#if os(iOS)
        .alert("yarn.scan.camera.denied", isPresented: $cameraPermissionDenied) {
            Button("yarn.scan.photoLibrary") { showingPhotoLibrary = true }
            Button("yarn.scan.openSettings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            Button("common.cancel", role: .cancel) {}
        }
#endif
    }

    @ViewBuilder
    private var imageActions: some View {
        PhotosPicker(selection: $pickerItems, maxSelectionCount: 2, matching: .images) {
            Label("yarn.scan.photoLibrary", systemImage: "photo.on.rectangle")
        }
        .buttonStyle(.bordered)
        .disabled(isLoading)

#if os(iOS)
        if images.count < 2, UIImagePickerController.isSourceTypeAvailable(.camera) {
            Button { requestCamera() } label: {
                Label("yarn.scan.camera", systemImage: "camera")
            }
            .buttonStyle(.bordered)
            .disabled(isLoading)
        }
#else
        Button { showingFileImporter = true } label: {
            Label("yarn.scan.finder", systemImage: "folder")
        }
        .buttonStyle(.bordered)
        .disabled(isLoading)
#endif
    }

    private func load(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        isLoading = true
        Task {
            do {
                var loaded: [Data] = []
                for item in items.prefix(2) {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw MacYarnLabelFileImportErrorFallback()
                    }
                    loaded.append(data)
                }
                images = loaded
                pickerItems = []
                isLoading = false
            } catch {
                pickerItems = []
                isLoading = false
                errorPresented = true
            }
        }
    }

#if os(iOS)
    private func requestCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showingCamera = true
        case .notDetermined:
            Task {
                if await AVCaptureDevice.requestAccess(for: .video) {
                    showingCamera = true
                } else {
                    cameraPermissionDenied = true
                }
            }
        case .denied, .restricted:
            cameraPermissionDenied = true
        @unknown default:
            cameraPermissionDenied = true
        }
    }
#endif
}

private struct MacYarnLabelFileImportErrorFallback: Error {}
