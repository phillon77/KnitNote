import Testing
@testable import KnitNoteCore

@Suite struct PatternPageThumbnailPresentationTests {
    @Test func pageItemUsesOneBasedLabelsAndSelectedState() {
        let item = PatternPageThumbnailPresentation(
            pageIndex: 2,
            pageCount: 8,
            selectedPage: 2
        )

        #expect(item.pageNumber == 3)
        #expect(item.isSelected)
        #expect(item.accessibilityArguments == [3, 8])
    }

    @Test func outOfRangeSelectedPageDoesNotSelectAnyItem() {
        let items = (0..<8).map {
            PatternPageThumbnailPresentation(
                pageIndex: $0,
                pageCount: 8,
                selectedPage: 8
            )
        }

        #expect(items.allSatisfy { !$0.isSelected })
    }

    @Test func everySupportedLayoutKeepsHitTargetAndStripAtLeastFortyFourPoints() {
        let layouts = PatternPageThumbnailPlatform.allCases.flatMap { platform in
            [false, true].map {
                PatternPageThumbnailLayoutPolicy.resolve(
                    platform: platform,
                    usesAccessibilitySizes: $0
                )
            }
        }

        #expect(layouts.allSatisfy { $0.minimumHitTarget >= 44 })
        #expect(layouts.allSatisfy { $0.stripHeight >= 44 })
    }
}
