import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

private enum YouTubeMetadataFetchState: Equatable {
    case idle
    case loading
    case loaded(title: String?, thumbnailData: Data?)
    case manualEntry(messageKey: String)
}

struct AddYouTubePatternView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: JSONProjectStore

    let targetProjectID: UUID?
    private let metadataFetcher: any YouTubeLinkMetadataFetching
    private let onFinished: (UUID, YouTubePatternAddResult.Resolution) -> Void

    @State private var urlText = ""
    @State private var title = ""
    @State private var fetchState: YouTubeMetadataFetchState = .idle
    @State private var parsedLink: YouTubePatternLink?
    @State private var metadataTask: Task<Void, Never>?
    @State private var isAdding = false
    @State private var addErrorKey: String?

    init(
        targetProjectID: UUID? = nil,
        metadataFetcher: any YouTubeLinkMetadataFetching = LiveYouTubeLinkMetadataFetcher(),
        onFinished: @escaping (UUID, YouTubePatternAddResult.Resolution) -> Void = { _, _ in }
    ) {
        self.targetProjectID = targetProjectID
        self.metadataFetcher = metadataFetcher
        self.onFinished = onFinished
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("patterns.youtube.link") {
                    youtubeURLField

                    Button("patterns.youtube.readMetadata") {
                        readMetadata()
                    }
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAdding)
                }

                Section("patterns.youtube.details") {
                    thumbnail
                    TextField("patterns.youtube.title", text: $title)
                        .accessibilityLabel(Text("patterns.youtube.title"))
                    fallbackMessage
                }

                if let addErrorKey {
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
                        cancelMetadataRequest()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.add") {
                        addPattern()
                    }
                    .disabled(!addIsEnabled || isAdding)
                }
            }
        }
        .tint(WatercolorTheme.actionBerry)
        .onChange(of: urlText) { _, _ in
            cancelMetadataRequest()
            parsedLink = nil
            fetchState = .idle
        }
        .onDisappear {
            cancelMetadataRequest()
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch fetchState {
        case let .loaded(_, thumbnailData):
            if let thumbnailData, let image = platformImage(data: thumbnailData) {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 140)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            } else {
                defaultThumbnail
            }
        case .idle, .loading, .manualEntry:
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
        TextField("patterns.youtube.url", text: $urlText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel(Text("patterns.youtube.url"))
        #else
        TextField("patterns.youtube.url", text: $urlText)
            .accessibilityLabel(Text("patterns.youtube.url"))
        #endif
    }

    @ViewBuilder
    private var fallbackMessage: some View {
        switch fetchState {
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

    private var canonicalLink: YouTubePatternLink? {
        if let parsedLink { return parsedLink }
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return try? YouTubePatternLink(parsing: url)
    }

    private var addIsEnabled: Bool {
        canonicalLink != nil && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func readMetadata() {
        cancelMetadataRequest()
        addErrorKey = nil
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let link = try? YouTubePatternLink(parsing: url) else {
            parsedLink = nil
            fetchState = .manualEntry(messageKey: "patterns.youtube.invalidLink")
            return
        }

        parsedLink = link
        fetchState = .loading
        metadataTask = Task { @MainActor in
            do {
                let metadata = try await withYouTubeMetadataTimeout {
                    try await metadataFetcher.fetch(for: link.canonicalURL)
                }
                try Task.checkCancellation()
                guard parsedLink == link else { return }
                if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let fetchedTitle = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !fetchedTitle.isEmpty {
                    title = fetchedTitle
                }
                fetchState = .loaded(title: metadata.title, thumbnailData: metadata.thumbnailData)
            } catch is CancellationError {
                return
            } catch {
                guard parsedLink == link else { return }
                fetchState = .manualEntry(messageKey: "patterns.youtube.metadataUnavailable")
            }
            metadataTask = nil
        }
    }

    private func cancelMetadataRequest() {
        metadataTask?.cancel()
        metadataTask = nil
    }

    private func addPattern() {
        guard let link = canonicalLink else { return }
        isAdding = true
        addErrorKey = nil
        let thumbnailData: Data?
        if case let .loaded(_, data) = fetchState {
            thumbnailData = data
        } else {
            thumbnailData = nil
        }
        Task { @MainActor in
            do {
                let result = try await store.addYouTubePattern(
                    link: link,
                    title: title,
                    targetProjectID: targetProjectID
                )
                if let thumbnailData {
                    await store.cacheYouTubeThumbnail(thumbnailData, patternID: result.patternID)
                }
                onFinished(result.patternID, result.resolution)
                dismiss()
            } catch {
                addErrorKey = "patterns.youtube.addFailed"
                isAdding = false
            }
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
