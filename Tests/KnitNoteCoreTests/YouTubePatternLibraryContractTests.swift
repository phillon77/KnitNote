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
        let source = try readRepositoryFile(
            "KnitNote/Patterns/PatternLibraryCollectionView.swift"
        )

        let addMenu = try youtubeSourceSlice(
            source,
            from: "Menu {\n                        Button(\"patterns.import.files\"",
            to: ".accessibilityLabel(Text(\"patterns.add\"))"
        )
        #expect(addMenu.contains("Button(\"patterns.import.files\", systemImage: \"folder\")"))
        #expect(addMenu.contains("importing = true"))
        #expect(addMenu.contains("Button(\"patterns.youtube.add\", systemImage: \"play.rectangle\")"))
        #expect(addMenu.contains("addingYouTubeLink = true"))

        #expect(source.contains(".fileImporter("))
        let fileImport = try youtubeSourceSlice(
            source,
            from: "private func importPattern",
            to: "private func acceptImportOutcome"
        )
        #expect(fileImport.contains("folderID: destinationFolderID"))

        let destination = try youtubeSourceSlice(
            source,
            from: "private var destinationFolderID",
            to: "private var scopeTitle"
        )
        #expect(destination.contains("case .all, .uncategorized:\n            nil"))
        #expect(destination.contains("case let .folder(folderID):\n            folderID"))
    }

    @Test func libraryYouTubeSheetReceivesTheSelectedAppLocale() throws {
        let source = try readRepositoryFile(
            "KnitNote/Patterns/PatternLibraryCollectionView.swift"
        )

        let youtubeSheet = try youtubeSourceSlice(
            source,
            from: ".sheet(isPresented: $addingYouTubeLink)",
            to: ".sheet(item: $pendingSelection)"
        )
        #expect(youtubeSheet.contains("AddYouTubePatternView("))
        #expect(youtubeSheet.contains("targetProjectID: nil"))
        #expect(youtubeSheet.contains("targetFolderID: destinationFolderID"))
        #expect(youtubeSheet.contains(".environment(\\.locale, locale)"))
    }

    @Test func youtubeRowsUseTheYoutubeDescriptionWithoutFileMetadata() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/PatternLibraryRow.swift")

        #expect(source.contains("case .youtube:"))
        #expect(source.contains("patterns.library.youtube"))
        #expect(!source.contains("return String(localized: \"YouTube\""))
    }

    @Test func youtubeLibraryRowsGiveVoiceOverTheTitleTypeAndActiveProjectCount() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/PatternLibraryRow.swift")

        #expect(source.contains(".accessibilityElement(children: .combine)"))
        #expect(source.contains("patternRowAccessibilityLabel("))
        #expect(source.contains("name: model.name"))
        #expect(source.contains("fileDescription: patternAssetDescription(asset, locale: locale)"))
        #expect(source.contains("usageDescription: usageDescription"))
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

private func youtubeSourceSlice(
    _ source: String,
    from startMarker: String,
    to endMarker: String
) throws -> Substring {
    let start = try #require(source.range(of: startMarker))
    let remainder = start.upperBound..<source.endIndex
    let end = try #require(source.range(of: endMarker, range: remainder))
    return source[start.lowerBound..<end.lowerBound]
}
