import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct YouTubePatternLibraryContractTests {
    @Test @MainActor func cachedYouTubeThumbnailIsAvailableThroughTheStoreThumbnailAPI() async throws {
        let harness = try PatternImportHarness()
        let result = try await harness.store.addYouTubePattern(
            link: try YouTubePatternLink(videoID: "abcdefghijk"),
            title: "Cable tutorial"
        )
        await harness.store.cacheYouTubeThumbnail(
            try makeYouTubeLibraryThumbnailPNG(),
            patternID: result.patternID
        )

        let thumbnail = await harness.store.patternThumbnailURL(patternID: result.patternID)

        #expect(thumbnail == harness.thumbnailService.cachedURL(assetID: try #require(
            harness.store.patterns.first(where: { $0.id == result.patternID })?.assetID
        )))
    }

    @Test func libraryOffersSeparateFileAndYouTubeAddActions() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/PatternLibraryView.swift")

        #expect(source.contains("Menu {"))
        #expect(source.contains("Button(\"patterns.import.files\", systemImage: \"folder\")"))
        #expect(source.contains("Button(\"patterns.youtube.add\", systemImage: \"play.rectangle\")"))
        #expect(source.contains("AddYouTubePatternView(targetProjectID: nil)"))
        #expect(source.contains("importing = true"))
        #expect(source.contains(".fileImporter("))
    }

    @Test func youtubeRowsUseTheYoutubeDescriptionWithoutFileMetadata() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/PatternLibraryRow.swift")

        #expect(source.contains("case .youtube:"))
        #expect(source.contains("patterns.library.youtube"))
        #expect(!source.contains("return String(localized: \"YouTube\""))
    }

    @Test func youtubeThumbnailStartsWithAnImmediateFallbackThenCachesMetadataArtwork() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/PatternLibraryRow.swift")

        #expect(source.contains("play.rectangle.fill"))
        #expect(source.contains("LiveYouTubeLinkMetadataFetcher"))
        #expect(source.contains("cacheYouTubeThumbnail"))
        #expect(source.contains("Task.isCancelled"))
        #expect(source.contains("asset.kind == .youtube"))
    }

    @Test func youtubeDetailOpensTheCanonicalLinkWithoutReaderOrSidecarExport() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/PatternDetailView.swift")

        #expect(source.contains("@Environment(\\.openURL) private var openURL"))
        #expect(source.contains("patterns.youtube.open"))
        #expect(source.contains("store.youtubeLink(patternID: patternID)"))
        #expect(source.contains("openURL(link.canonicalURL)"))
        #expect(source.contains("store.markPatternOpened(id: patternID)"))
        #expect(source.contains("patterns.youtube.error.open"))
        #expect(source.contains("asset?.kind != .youtube"))
        #expect(source.contains("asset.kind == .youtube"))
    }

    @Test func pdfAndImageDetailStillUseTheReaderRoute() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/PatternDetailView.swift")

        #expect(source.contains("guard asset?.kind != .youtube else"))
        #expect(source.contains("PatternReaderRoute("))
        #expect(source.contains("PatternReaderView(context: route.context)"))
    }
}

private func makeYouTubeLibraryThumbnailPNG() throws -> Data {
    let source = URL(fileURLWithPath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns")
    return try Data(contentsOf: source)
}
