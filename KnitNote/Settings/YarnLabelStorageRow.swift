import SwiftUI

struct YarnLabelStorageRow: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject private var store: JSONProjectStore
    @State private var state: StorageState = .loading

    private enum StorageState {
        case loading
        case loaded(Int64)
        case unavailable
    }

    var body: some View {
        HStack(spacing: 12) {
            Label("yarn.labelPhotos", systemImage: "tag")
            Spacer(minLength: 12)
            switch state {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityValue(Text("common.loading"))
            case let .loaded(bytes):
                let value = LocaleAwareText.byteCount(bytes, locale: locale)
                Text(value)
                    .foregroundStyle(.secondary)
                    .accessibilityValue(Text(value))
            case .unavailable:
                Text("yarn.labelPhotos.storage.unavailable")
                    .foregroundStyle(.secondary)
                    .accessibilityValue(Text("yarn.labelPhotos.storage.unavailable"))
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .yarnLabelPhotosDidChange)) { _ in
            Task { await load() }
        }
    }

    @MainActor
    private func load() async {
        state = .loading
        do {
            let bytes = try await store.yarnLabelPhotoStorageBytes()
            state = .loaded(bytes)
        } catch {
            state = .unavailable
        }
    }
}
