import Foundation
import SwiftUI

struct YarnLabelPhotoItem: Identifiable {
    let id: String
    let url: URL?
    let data: Data?

    static func stored(_ url: URL) -> Self {
        Self(id: url.path, url: url, data: nil)
    }

    static func selected(_ data: Data, index: Int) -> Self {
        Self(id: "selected-\(index)", url: nil, data: data)
    }
}

struct YarnLabelPhotoGallery: View {
    let items: [YarnLabelPhotoItem]
    var onRemove: ((Int) -> Void)? = nil

    var body: some View {
        let displayedItems = Array(items.prefix(2))
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(Array(displayedItems.enumerated()), id: \.element.id) { index, item in
                    VStack(spacing: 6) {
                        YarnPhotoView(url: item.url, data: item.data)
                            .frame(width: 220, height: 160)
                            .clipShape(.rect(cornerRadius: 18, style: .continuous))
                            .accessibilityLabel(
                                Text("yarn.labelPhoto.accessibility \(index + 1)")
                            )

                        if let onRemove {
                            Button("yarn.labelPhoto.remove", systemImage: "trash", role: .destructive) {
                                onRemove(index)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}
