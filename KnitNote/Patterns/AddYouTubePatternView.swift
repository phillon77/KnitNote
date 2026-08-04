import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct AddYouTubePatternView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: JSONProjectStore

    private let metadataFetcher: any YouTubePatternMetadataFetching
    private let onFinished: (UUID, YouTubePatternAddResult.Resolution) -> Void
    @StateObject private var coordinator: YouTubePatternAddCoordinator

    init(
        targetProjectID: UUID? = nil,
        metadataFetcher: any YouTubePatternMetadataFetching = LiveYouTubeLinkMetadataFetcher(),
        onFinished: @escaping (UUID, YouTubePatternAddResult.Resolution) -> Void = { _, _ in }
    ) {
        self.metadataFetcher = metadataFetcher
        self.onFinished = onFinished
        _coordinator = StateObject(wrappedValue: YouTubePatternAddCoordinator(
            targetProjectID: targetProjectID
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("patterns.youtube.link") {
                    youtubeURLField
                    Button("patterns.youtube.readMetadata") {
                        coordinator.readMetadata(using: metadataFetcher)
                    }
                    .disabled(
                        coordinator.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || coordinator.isAdding
                    )
                }

                Section("patterns.youtube.details") {
                    thumbnail
                    TextField("patterns.youtube.title", text: $coordinator.title)
                        .accessibilityLabel(Text("patterns.youtube.title"))
                    fallbackMessage
                }

                if let addErrorKey = coordinator.addErrorKey {
                    Section {
                        Text(LocalizedStringKey(addErrorKey))
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("patterns.youtube.add")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") {
                        coordinator.cancelMetadataRequest()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.add") { addPattern() }
                        .disabled(!coordinator.isAddEnabled || coordinator.isAdding)
                }
            }
        }
        .tint(WatercolorTheme.actionBerry)
        .onDisappear {
            coordinator.cancelMetadataRequest()
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if case let .loaded(thumbnailData) = coordinator.fetchState,
           let thumbnailData,
           let image = platformImage(data: thumbnailData) {
            Image(platformImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 140)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
        } else {
            defaultThumbnail
        }
    }

    private var defaultThumbnail: some View {
        Image(systemName: "play.rectangle.fill")
            .font(.system(size: 42))
            .foregroundStyle(WatercolorTheme.actionBerry)
            .frame(maxWidth: .infinity, minHeight: 76)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var youtubeURLField: some View {
        #if os(iOS)
        TextField("patterns.youtube.url", text: $coordinator.urlText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel(Text("patterns.youtube.url"))
        #else
        TextField("patterns.youtube.url", text: $coordinator.urlText)
            .accessibilityLabel(Text("patterns.youtube.url"))
        #endif
    }

    @ViewBuilder
    private var fallbackMessage: some View {
        switch coordinator.fetchState {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("patterns.youtube.loading")
            }
        case let .manualEntry(messageKey):
            Text(LocalizedStringKey(messageKey))
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .idle, .loaded:
            EmptyView()
        }
    }

    private func addPattern() {
        Task { @MainActor in
            let result = await coordinator.add(
                add: { link, title, targetProjectID in
                    try await store.addYouTubePattern(
                        link: link,
                        title: title,
                        targetProjectID: targetProjectID
                    )
                },
                cache: { data, patternID in
                    await store.cacheYouTubeThumbnail(data, patternID: patternID)
                }
            )
            guard let result else { return }
            onFinished(result.patternID, result.resolution)
            dismiss()
        }
    }

    #if os(iOS)
    private func platformImage(data: Data) -> UIImage? {
        UIImage(data: data)
    }
    #else
    private func platformImage(data: Data) -> NSImage? {
        NSImage(data: data)
    }
    #endif
}

private extension Image {
    #if os(iOS)
    init(platformImage: UIImage) {
        self.init(uiImage: platformImage)
    }
    #else
    init(platformImage: NSImage) {
        self.init(nsImage: platformImage)
    }
    #endif
}
