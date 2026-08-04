import Foundation
import Testing

@Suite struct YouTubeProjectPatternsContractTests {
    @Test func projectAddMenuOffersExactlyTheThreeSupportedPatternActions() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/ProjectPatternsView.swift")

        #expect(source.contains("patterns.linkExisting"))
        #expect(source.contains("patterns.importNew"))
        #expect(source.contains("patterns.youtube.add"))
        #expect(source.contains("AddYouTubePatternView(targetProjectID: projectID)"))
    }

    @Test func projectYouTubeRowsOpenExternallyWithoutCreatingAReaderSelection() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/ProjectPatternsView.swift")

        #expect(source.contains("switch selection.asset.kind"))
        #expect(source.contains("case .youtube:"))
        #expect(source.contains("openYouTube(selection)"))
        #expect(source.contains("openURL(link.canonicalURL)"))
        #expect(source.contains("patterns.youtube.error.open"))
        #expect(source.contains("case .pdf, .image:"))
        #expect(source.contains("selectedPattern = selection"))
    }

    @Test func choosingLibraryPatternsShowsYouTubeTypeAndDropsBrokenAssetRelationships() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/ChooseLibraryPatternView.swift")

        #expect(source.contains("store.patternAssets.first(where: { $0.id == option.pattern.assetID })"))
        #expect(source.contains("patternAssetDescription(asset, locale: locale)"))
        #expect(source.contains("Text(patternAssetDescription(asset, locale: locale))"))
        #expect(source.contains("accessibilityLabel(for: option, asset: asset)"))
        #expect(source.contains("compactMap"))
    }

    @Test func projectUnlinkAndRelinkKeepTheExistingUsageContractForYouTubePatterns() throws {
        let projectSource = try readRepositoryFile("KnitNote/Patterns/ProjectPatternsView.swift")
        let chooserSource = try readRepositoryFile("KnitNote/Patterns/ChooseLibraryPatternView.swift")

        #expect(projectSource.contains("store.unlinkPattern(patternID:"))
        #expect(chooserSource.contains("ProjectPatternLinkIndex("))
        #expect(chooserSource.contains("patterns.relink"))
        #expect(chooserSource.contains("store.linkPattern(patternID:"))
    }
}
