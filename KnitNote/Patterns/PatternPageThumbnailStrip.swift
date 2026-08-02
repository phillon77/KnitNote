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
    let pageCount: Int
    let selectedPage: Int
    let onSelect: (Int) -> Void

    var body: some View {
        let layout = PatternPageThumbnailLayoutPolicy.resolve(
            platform: platform,
            usesAccessibilitySizes: dynamicTypeSize.isAccessibilitySize
        )

        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
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
                                assetID: assetID,
                                item: item,
                                minimumHitTarget: layout.minimumHitTarget
                            )
                        }
                        .buttonStyle(.plain)
                        .id(pageIndex)
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            .frame(minHeight: layout.stripHeight)
            .onAppear {
                proxy.scrollTo(selectedPage, anchor: .center)
            }
            .onChange(of: selectedPage) { _, pageIndex in
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(pageIndex, anchor: .center)
                }
            }
            .task(id: selectedPage) {
                for pageIndex in PatternPageThumbnailPolicy.preloadIndices(
                    pageCount: pageCount,
                    currentPage: selectedPage
                ) {
                    guard !Task.isCancelled else { return }
                    _ = await store.patternPDFPageThumbnailURL(
                        assetID: assetID,
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

    let assetID: UUID
    let item: PatternPageThumbnailPresentation
    let minimumHitTarget: Double

    @State private var loadedThumbnail: LoadedPatternPageThumbnail?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            thumbnail

            Text(item.pageNumber, format: .number)
                .font(.caption2.bold().monospacedDigit())
                .foregroundStyle(WatercolorTheme.ink)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(2)
        }
        .frame(
            width: minimumHitTarget,
            height: minimumHitTarget
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
        .accessibilityLabel(
            Text("Page \(item.accessibilityArguments[0]) of \(item.accessibilityArguments[1])")
        )
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
                .scaledToFill()
                .accessibilityHidden(true)
        } else {
            Image(systemName: "doc.richtext")
                .font(.title3)
                .foregroundStyle(WatercolorTheme.actionBerry)
                .accessibilityHidden(true)
        }
    }

    private var request: PatternPageThumbnailRequest {
        PatternPageThumbnailRequest(
            assetID: assetID,
            pageIndex: item.pageIndex,
            generation: store.dataGeneration
        )
    }

    private func loadThumbnail(for request: PatternPageThumbnailRequest) async {
        guard request == self.request else { return }
        loadedThumbnail = nil

        guard !Task.isCancelled,
              let url = await store.patternPDFPageThumbnailURL(
                  assetID: request.assetID,
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

private struct PatternPageThumbnailRequest: Hashable {
    let assetID: UUID
    let pageIndex: Int
    let generation: UInt64
}

private struct LoadedPatternPageThumbnail {
    let request: PatternPageThumbnailRequest
    let image: Image
}
