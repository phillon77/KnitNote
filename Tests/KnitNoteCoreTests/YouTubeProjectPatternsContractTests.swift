import Foundation
import Testing

@Suite struct YouTubeProjectPatternsContractTests {
    @Test func projectAddMenuOffersExactlyTheThreeSupportedPatternActions() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/ProjectPatternsView.swift")

        #expect(source.contains("ForEach(ProjectPatternAddAction.allCases)"))
        #expect(source.contains("performAddAction(action)"))
        #expect(source.contains("AddYouTubePatternView(targetProjectID: projectID)"))
    }

    @Test func projectYouTubeRowsOpenExternallyWithoutCreatingAReaderSelection() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/ProjectPatternsView.swift")

        #expect(source.contains("projectPatternOpenRoute(for: selection.asset)"))
        #expect(source.contains("case .externalYouTube:"))
        #expect(source.contains("openYouTube(selection)"))
        #expect(source.contains("openURL(link.canonicalURL)"))
        #expect(source.contains("patterns.youtube.error.open"))
        #expect(source.contains("case .reader:"))
        #expect(source.contains("selectedPattern = selection"))
    }

    @Test func choosingLibraryPatternsShowsYouTubeTypeAndDropsBrokenAssetRelationships() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/ChooseLibraryPatternView.swift")

        #expect(source.contains("ProjectPatternLinkChoiceIndex("))
        #expect(source.contains("assets: store.patternAssets"))
        #expect(source.contains("patternAssetDescription(asset, locale: locale)"))
        #expect(source.contains("projectPatternLinkChoiceAccessibilityLabel("))
        #expect(source.contains("accessibilityLabel(for: selection)"))
    }

    @Test func projectUnlinkAndRelinkKeepTheExistingUsageContractForYouTubePatterns() throws {
        let projectSource = try readRepositoryFile("KnitNote/Patterns/ProjectPatternsView.swift")
        let chooserSource = try readRepositoryFile("KnitNote/Patterns/ChooseLibraryPatternView.swift")

        #expect(projectSource.contains("store.unlinkPattern(patternID:"))
        #expect(chooserSource.contains("ProjectPatternLinkChoiceIndex("))
        #expect(chooserSource.contains("patterns.relink"))
        #expect(chooserSource.contains("store.linkPattern(patternID:"))
    }

    @Test func youtubeMetadataProgressAndFallbackRemainVisibleAndExposeAccessibilityValues() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/AddYouTubePatternView.swift")

        #expect(source.contains("Text(\"patterns.youtube.loading\")"))
        #expect(source.contains(".accessibilityValue(Text(\"patterns.youtube.loading\"))"))
        #expect(source.contains("Text(LocalizedStringKey(messageKey))"))
        #expect(source.contains(".accessibilityValue(Text(LocalizedStringKey(messageKey)))"))
    }
}
