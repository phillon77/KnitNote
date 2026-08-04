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

    @ViewBuilder
    var body: some View {
        #if os(macOS)
        navigationContent
            .frame(
                minWidth: CGFloat(MacYouTubeImportLayout.minimumWidth),
                idealWidth: CGFloat(MacYouTubeImportLayout.idealWidth),
                minHeight: CGFloat(MacYouTubeImportLayout.minimumHeight)
            )
        #else
        navigationContent
        #endif
    }

    private var navigationContent: some View {
        NavigationStack {
            platformContent
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
    private var platformContent: some View {
        #if os(macOS)
        macYouTubeContent
        #else
        youtubeForm
        #endif
    }

    #if os(macOS)
    private var macYouTubeContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("patterns.youtube.link")
                    .font(.headline)

                youtubeURLField

                readMetadataButton

                Divider()

                Text("patterns.youtube.details")
                    .font(.headline)

                thumbnail
                    .frame(maxWidth: .infinity, alignment: .center)

                TextField("patterns.youtube.title", text: $coordinator.title)
                    .accessibilityLabel(Text("patterns.youtube.title"))

                fallbackMessage
                addErrorMessage
            }
            .frame(maxWidth: CGFloat(MacYouTubeImportLayout.contentMaximumWidth))
            .padding(CGFloat(MacYouTubeImportLayout.outerPadding))
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(WatercolorBackground())
    }
    #else
    private var youtubeForm: some View {
        Form {
            Section("patterns.youtube.link") {
                youtubeURLField
                readMetadataButton
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
    }
    #endif

    private var readMetadataButton: some View {
        Button("patterns.youtube.readMetadata") {
            coordinator.readMetadata(using: metadataFetcher)
        }
        .disabled(
            coordinator.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || coordinator.isAdding
        )
    }

    @ViewBuilder
    private var addErrorMessage: some View {
        if let addErrorKey = coordinator.addErrorKey {
            Text(LocalizedStringKey(addErrorKey))
                .foregroundStyle(.red)
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
                .modifier(YouTubePreviewFrameModifier())
                .accessibilityLabel(Text("patterns.youtube.accessibility.thumbnail"))
        } else {
            defaultThumbnail
        }
    }

    private var defaultThumbnail: some View {
        ZStack {
            WatercolorTheme.softWhite.opacity(0.9)
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 42))
                .foregroundStyle(WatercolorTheme.actionBerry)
        }
            .modifier(YouTubePreviewFrameModifier())
            .accessibilityLabel(Text("patterns.youtube.accessibility.thumbnail"))
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("patterns.youtube.status"))
            .accessibilityValue(Text("patterns.youtube.loading"))
        case let .manualEntry(messageKey):
            Text(LocalizedStringKey(messageKey))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("patterns.youtube.status"))
                .accessibilityValue(Text(LocalizedStringKey(messageKey)))
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

private struct YouTubePreviewFrameModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .aspectRatio(MacYouTubeImportLayout.previewAspectRatio, contentMode: .fit)
            .frame(maxWidth: CGFloat(MacYouTubeImportLayout.previewMaximumWidth))
        #else
        content
            .frame(maxHeight: 140)
            .frame(maxWidth: .infinity)
        #endif
    }
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
