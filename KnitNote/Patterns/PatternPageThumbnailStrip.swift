import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct PatternPageThumbnailStrip: View {
    @EnvironmentObject private var store: JSONProjectStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let assetID: UUID
    let assetRevision: String
    let pageCount: Int
    let selectedPage: Int
    let onSelect: (Int) -> Void

    var body: some View {
        let layout = PatternPageThumbnailLayoutPolicy.resolve(
            platform: platform,
            usesAccessibilitySizes: dynamicTypeSize.isAccessibilitySize
        )
        let assetIdentity = PatternPageThumbnailAssetIdentity(
            assetID: assetID,
            assetRevision: assetRevision,
            pageCount: pageCount
        )
        let preloadIdentity = assetIdentity.preload(selectedPage: selectedPage)

        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: layout.itemSpacing) {
                    ForEach(0..<max(0, pageCount), id: \.self) { pageIndex in
                        let item = PatternPageThumbnailPresentation(
                            pageIndex: pageIndex,
                            pageCount: pageCount,
                            selectedPage: selectedPage
                        )
                        Button {
                            if item.isSelected {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    proxy.scrollTo(pageIndex, anchor: .center)
                                }
                            } else {
                                onSelect(pageIndex)
                            }
                        } label: {
                            PatternPageThumbnailCell(
                                request: assetIdentity.request(pageIndex: pageIndex),
                                item: item,
                                layout: layout
                            )
                        }
                        .buttonStyle(.plain)
                        .id(pageIndex)
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            .frame(height: layout.stripHeight)
            .onAppear {
                proxy.scrollTo(selectedPage, anchor: .center)
            }
            .onChange(of: selectedPage) { _, pageIndex in
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(pageIndex, anchor: .center)
                }
            }
            .task(id: preloadIdentity) {
                for pageIndex in PatternPageThumbnailPolicy.preloadIndices(
                    pageCount: preloadIdentity.asset.pageCount,
                    currentPage: preloadIdentity.selectedPage
                ) {
                    guard !Task.isCancelled else { return }
                    _ = await store.patternPDFPageThumbnailURL(
                        assetID: preloadIdentity.asset.assetID,
                        pageIndex: pageIndex
                    )
                }
            }
        }
    }

    private var platform: PatternPageThumbnailPlatform {
        #if os(macOS)
        return .mac
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
        #endif
    }
}

private struct PatternPageThumbnailCell: View {
    @EnvironmentObject private var store: JSONProjectStore
    @Environment(\.locale) private var locale

    let request: PatternPageThumbnailRequestIdentity
    let item: PatternPageThumbnailPresentation
    let layout: PatternPageThumbnailLayoutPolicy

    @State private var loadedThumbnail: LoadedPatternPageThumbnail?

    var body: some View {
        VStack(spacing: 2) {
            thumbnail
                .frame(
                    width: layout.thumbnailWidth,
                    height: layout.thumbnailHeight
                )
            Text(item.pageNumber, format: .number)
                .font(.caption2.bold().monospacedDigit())
                .foregroundStyle(WatercolorTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(
            minWidth: layout.minimumHitTarget,
            idealWidth: layout.thumbnailWidth,
            maxWidth: layout.thumbnailWidth,
            minHeight: layout.minimumHitTarget
        )
        .background(WatercolorTheme.softWhite.opacity(0.9))
        .clipShape(.rect(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    item.isSelected
                        ? WatercolorTheme.actionBerry
                        : WatercolorTheme.lavender.opacity(0.35),
                    lineWidth: item.isSelected ? 3 : 1
                )
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        .accessibilityAddTraits(item.isSelected ? .isSelected : [])
        .task(id: request) {
            await loadThumbnail(for: request)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let loadedThumbnail,
           loadedThumbnail.request == request {
            loadedThumbnail.image
                .resizable()
                .scaledToFit()
                .accessibilityHidden(true)
        } else {
            Image(systemName: "doc.richtext")
                .font(.title3)
                .foregroundStyle(WatercolorTheme.actionBerry)
                .accessibilityHidden(true)
        }
    }

    private var accessibilityLabel: String {
        let format = String(
            localized: "patterns.reader.thumbnail.accessibility.format",
            locale: locale
        )
        let pageLabel = String(
            format: format,
            locale: locale,
            Int64(item.accessibilityArguments[0]),
            Int64(item.accessibilityArguments[1])
        )
        guard item.isSelected else { return pageLabel }
        return pageLabel
            + String(localized: ", ", locale: locale)
            + String(localized: "patterns.reader.thumbnail.current", locale: locale)
    }

    private func loadThumbnail(for request: PatternPageThumbnailRequestIdentity) async {
        guard request == self.request else { return }
        loadedThumbnail = nil

        guard !Task.isCancelled,
              let url = await store.patternPDFPageThumbnailURL(
                  assetID: request.asset.assetID,
                  pageIndex: request.pageIndex
              ),
              !Task.isCancelled
        else { return }

        let dataTask = Task.detached(priority: .utility) {
            try? Data(contentsOf: url)
        }
        let data = await withTaskCancellationHandler {
            await dataTask.value
        } onCancel: {
            dataTask.cancel()
        }

        guard !Task.isCancelled,
              request == self.request,
              let data,
              let image = decodedImage(data)
        else { return }

        loadedThumbnail = LoadedPatternPageThumbnail(request: request, image: image)
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

private struct LoadedPatternPageThumbnail {
    let request: PatternPageThumbnailRequestIdentity
    let image: Image
}
