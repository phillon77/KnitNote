import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct YarnPhotoView: View {
    let url: URL?
    var data: Data? = nil
    @State private var loadedImage: Image?

    var body: some View {
        Group {
            if let image = data.flatMap(decodedImage) ?? loadedImage {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "shippingbox.fill")
                    .font(.title2)
                    .foregroundStyle(WatercolorTheme.actionBerry, WatercolorTheme.lavender)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(WatercolorTheme.lavender.opacity(0.22))
            }
        }
        .accessibilityLabel(Text("yarn.accessibility.photo"))
        .task(id: url) {
            guard data == nil, let requestedURL = url else {
                loadedImage = nil
                return
            }
            let bytes = await Task.detached(priority: .utility) {
                try? Data(contentsOf: requestedURL)
            }.value
            guard !Task.isCancelled else { return }
            loadedImage = bytes.flatMap(decodedImage)
        }
    }

    private func decodedImage(_ bytes: Data) -> Image? {
#if os(iOS)
        guard let platformImage = UIImage(data: bytes) else { return nil }
        return Image(uiImage: platformImage)
#elseif os(macOS)
        guard let platformImage = NSImage(data: bytes) else { return nil }
        return Image(nsImage: platformImage)
#endif
    }
}
