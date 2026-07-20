#if os(iOS)
import ImageIO
import SwiftUI
import UIKit

struct CameraCaptureView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onCapture: (Data) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.cameraCaptureMode = .photo
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    static func dismantleUIViewController(
        _ uiViewController: UIImagePickerController,
        coordinator: Coordinator
    ) {
        coordinator.cancelEncoding()
    }

    @MainActor
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraCaptureView
        var encodingTask: Task<Void, Never>?
        private weak var processingOverlay: UIView?

        init(parent: CameraCaptureView) { self.parent = parent }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            cancelEncoding()
            parent.dismiss()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage,
                  let cgImage = image.cgImage else {
                parent.dismiss()
                return
            }
            let photo = CameraCapturePhoto(
                image: cgImage,
                orientation: image.imageOrientation.cgImagePropertyOrientation
            )
            showProcessing(in: picker)
            encodingTask?.cancel()
            encodingTask = Task { [weak self, weak picker] in
                do {
                    let data = try await CameraCapturePhotoEncoder.encode(photo)
                    try Task.checkCancellation()
                    guard let self, let picker else { return }
                    encodingTask = nil
                    hideProcessing(in: picker)
                    parent.onCapture(data)
                    parent.dismiss()
                } catch is CancellationError {
                    // Dismantling the representable invalidates this publication.
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    encodingTask = nil
                    parent.dismiss()
                }
            }
        }

        func cancelEncoding() {
            encodingTask?.cancel()
            encodingTask = nil
        }

        private func showProcessing(in picker: UIImagePickerController) {
            picker.view.isUserInteractionEnabled = false
            let overlay = UIView(frame: picker.view.bounds)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.backgroundColor = UIColor.black.withAlphaComponent(0.28)
            overlay.accessibilityLabel = String(localized: "journal.photo.loading")

            let indicator = UIActivityIndicatorView(style: .large)
            indicator.color = .white
            indicator.translatesAutoresizingMaskIntoConstraints = false
            indicator.startAnimating()
            overlay.addSubview(indicator)
            NSLayoutConstraint.activate([
                indicator.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                indicator.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            ])
            picker.view.addSubview(overlay)
            processingOverlay = overlay
        }

        private func hideProcessing(in picker: UIImagePickerController) {
            processingOverlay?.removeFromSuperview()
            processingOverlay = nil
            picker.view.isUserInteractionEnabled = true
        }
    }
}

private extension UIImage.Orientation {
    var cgImagePropertyOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: .up
        case .upMirrored: .upMirrored
        case .down: .down
        case .downMirrored: .downMirrored
        case .left: .left
        case .leftMirrored: .leftMirrored
        case .right: .right
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}
#endif
