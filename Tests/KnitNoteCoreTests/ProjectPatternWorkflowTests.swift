import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct ProjectPatternWorkflowTests {
    @Test func projectPatternAddActionsRemainTheExactSupportedThree() {
        #expect(ProjectPatternAddAction.allCases == [
            .linkExisting,
            .importFile,
            .addYouTube,
        ])
    }

    @Test func youtubeUsesAnExternalRouteWhileFilesUseTheReaderRoute() {
        #expect(projectPatternOpenRoute(for: asset(kind: .youtube)) == .externalYouTube)
        #expect(projectPatternOpenRoute(for: asset(kind: .pdf)) == .reader)
        #expect(projectPatternOpenRoute(for: asset(kind: .image)) == .reader)
    }

    @Test func chooserOmitsPatternsWhoseAssetsAreNoLongerAvailable() {
        let projectID = UUID()
        let validAsset = asset(kind: .youtube)
        let validPattern = StoredPattern(
            id: UUID(),
            assetID: validAsset.id,
            displayName: "Video tutorial"
        )
        let brokenPattern = StoredPattern(
            id: UUID(),
            assetID: UUID(),
            displayName: "Missing asset"
        )

        let choices = ProjectPatternLinkChoiceIndex(
            patterns: [validPattern, brokenPattern],
            assets: [validAsset],
            usages: [],
            projectID: projectID,
            locale: Locale(identifier: "en")
        ).options

        #expect(choices.map(\.option.pattern.id) == [validPattern.id])
        #expect(choices.first?.asset == validAsset)
    }

    @Test func chooserAccessibilityLabelIncludesTheAssetTypeAndRelinkState() {
        let label = projectPatternLinkChoiceAccessibilityLabel(
            name: "Video tutorial",
            assetTypeDescription: "YouTube video",
            status: .relink,
            relinkDescription: "Relink"
        )

        #expect(label == "Video tutorial, YouTube video, Relink")
    }
}

private func asset(kind: PatternKind) -> PatternAsset {
    PatternAsset(
        id: UUID(),
        sha256: UUID().uuidString,
        kind: kind,
        storedFilename: "pattern",
        byteCount: 1,
        pageCount: nil
    )
}
