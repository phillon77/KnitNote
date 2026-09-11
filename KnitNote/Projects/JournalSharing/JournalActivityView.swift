#if os(iOS)
import SwiftUI
import UIKit

struct JournalActivityView: UIViewControllerRepresentable {
    let payload: JournalSharePayload
    let completion: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [payload.fileURL, payload.text],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, _, _, _ in completion() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
