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
        HStack(alignment: .top, spacing: 14) {
            PatternThumbnailView(patternID: model.patternID)
                .frame(width: 76, height: 96)

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
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
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
        return String(
            format: String(localized: "patterns.library.links.format", locale: locale),
            locale: locale,
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
            guard let thumbnailURL = await store.patternThumbnailURL(patternID: patternID) else {
                loadedImage = nil
                return
            }
            let bytes = await Task.detached(priority: .utility) {
                try? Data(contentsOf: thumbnailURL)
            }.value
            guard !Task.isCancelled else { return }
            loadedImage = bytes.flatMap(decodedImage)
        }
    }

    private var fallback: some View {
        Image(systemName: "doc.richtext")
            .font(.title2)
            .foregroundStyle(WatercolorTheme.actionBerry)
            .accessibilityHidden(true)
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
    }
}
