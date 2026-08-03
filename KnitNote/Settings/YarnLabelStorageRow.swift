import SwiftUI

struct YarnLabelStorageRow: View {
    @EnvironmentObject private var store: JSONProjectStore
    @State private var state: StorageState = .loading

    private enum StorageState {
        case loading
        case loaded(String)
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
            case let .loaded(value):
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
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            formatter.allowedUnits = [.useKB, .useMB, .useGB]
            formatter.includesUnit = true
            formatter.isAdaptive = true
            state = .loaded(formatter.string(fromByteCount: bytes))
        } catch {
            state = .unavailable
        }
    }
}
