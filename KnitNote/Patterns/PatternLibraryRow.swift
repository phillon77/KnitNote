import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct PatternLibraryRow: View {
    @Environment(\.locale) private var locale
    let model: PatternLibraryRowModel
    let asset: PatternAsset

    var body: some View {
        let thumbnailLayout = PatternListThumbnailLayout.resolve(for: asset.kind)

        HStack(alignment: .top, spacing: 14) {
            PatternThumbnailView(patternID: model.patternID)
                .frame(
                    width: CGFloat(thumbnailLayout.width),
                    height: CGFloat(thumbnailLayout.height)
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(model.name)
                    .font(.headline)
                    .foregroundStyle(WatercolorTheme.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text(patternAssetDescription(asset, locale: locale))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(usageDescription)
                    .font(.caption)
                    .foregroundStyle(model.activeLinkCount == 0 ? .secondary : WatercolorTheme.actionBerry)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: CGFloat(thumbnailLayout.minimumRowHeight),
            alignment: .leading
        )
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(
                patternRowAccessibilityLabel(
                    name: model.name,
                    fileDescription: patternAssetDescription(asset, locale: locale),
                    usageDescription: usageDescription,
                    locale: locale
                )
            )
        )
    }

    private var usageDescription: String {
        guard model.activeLinkCount > 0 else {
            return String(localized: "patterns.library.unused", locale: locale)
        }
        return String.localizedStringWithFormat(
            String(localized: "patterns.library.links.format", locale: locale),
            model.activeLinkCount
        )
    }
}

func patternRowAccessibilityLabel(
    name: String,
    fileDescription: String,
    usageDescription: String,
    locale: Locale
) -> String {
    String(
        format: String(
            localized: "patterns.library.row.accessibility.format",
            locale: locale
        ),
        locale: locale,
        name,
        fileDescription,
        usageDescription
    )
}

struct PatternThumbnailView: View {
    @EnvironmentObject private var store: JSONProjectStore
    let patternID: UUID
    @State private var loadedImage: Image?

    var body: some View {
        Group {
            if let loadedImage {
                loadedImage
                    .resizable()
                    .scaledToFill()
            } else {
                fallback
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WatercolorTheme.softWhite.opacity(0.9))
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(WatercolorTheme.lavender.opacity(0.3), lineWidth: 1)
        }
        .clipped()
        .accessibilityLabel(Text("patterns.library.thumbnail"))
        .task(id: ThumbnailRequest(patternID: patternID, generation: store.dataGeneration)) {
            guard let asset else {
                loadedImage = nil
                return
            }
            if asset.kind == .youtube {
                await loadYouTubeThumbnail(asset)
            } else {
                await loadLocalThumbnail()
            }
        }
    }

    private var fallback: some View {
        Image(systemName: asset?.kind == .youtube ? "play.rectangle.fill" : "doc.richtext")
            .font(.title2)
            .foregroundStyle(WatercolorTheme.actionBerry)
            .accessibilityHidden(true)
    }

    private var asset: PatternAsset? {
        guard let pattern = store.patterns.first(where: { $0.id == patternID }) else {
            return nil
        }
        return store.patternAssets.first { $0.id == pattern.assetID }
    }

    private func loadLocalThumbnail() async {
        guard let thumbnailURL = await store.patternThumbnailURL(patternID: patternID) else {
            loadedImage = nil
            return
        }
        loadedImage = await decodedImage(at: thumbnailURL)
    }

    private func loadYouTubeThumbnail(_ asset: PatternAsset) async {
        loadedImage = nil
        let loader = YouTubePatternThumbnailLoader(
            fetcher: LiveYouTubeLinkMetadataFetcher(),
            cachedThumbnailURL: { patternID in
                await store.patternThumbnailURL(patternID: patternID)
            },
            linkForPattern: { patternID in
                try store.youtubeLink(patternID: patternID)
            },
            cacheThumbnail: { thumbnailData, patternID in
                await store.cacheYouTubeThumbnail(thumbnailData, patternID: patternID)
            },
            isCurrentYouTubeAsset: { patternID, assetID in
                store.patterns.first(where: { $0.id == patternID })?.assetID == assetID
                    && store.patternAssets.contains(where: { $0.id == assetID && $0.kind == .youtube })
            }
        )
        guard let cachedURL = await loader.thumbnailURL(patternID: patternID, assetID: asset.id),
              !Task.isCancelled else {
            return
        }
        loadedImage = await decodedImage(at: cachedURL)
    }

    private func decodedImage(at url: URL) async -> Image? {
        let bytes = await Task.detached(priority: .utility) {
            try? Data(contentsOf: url)
        }.value
        guard !Task.isCancelled else { return nil }
        return bytes.flatMap(decodedImage)
    }

    private func decodedImage(_ data: Data) -> Image? {
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #elseif os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #endif
    }
}

private struct ThumbnailRequest: Hashable {
    let patternID: UUID
    let generation: UInt64
}

func patternAssetDescription(_ asset: PatternAsset, locale: Locale) -> String {
    switch asset.kind {
    case .pdf:
        guard let pageCount = asset.pageCount else {
            return String(localized: "patterns.library.pdf", locale: locale)
        }
        return String(
            format: String(localized: "patterns.library.pdf.pages.format", locale: locale),
            locale: locale,
            pageCount
        )
    case .image:
        return String(localized: "patterns.library.image", locale: locale)
    case .youtube:
        return String(localized: "patterns.library.youtube", locale: locale)
    }
}
