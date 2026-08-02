import Foundation
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

    @Test func everySupportedLayoutUsesACompactStripAndKeepsFortyFourPointHitTargets() {
        let layouts = PatternPageThumbnailPlatform.allCases.flatMap { platform in
            [false, true].map { usesAccessibilitySizes in
                PatternPageThumbnailLayoutPolicy.resolve(
                    platform: platform,
                    usesAccessibilitySizes: usesAccessibilitySizes
                )
            }
        }

        #expect(layouts.allSatisfy { $0.minimumHitTarget >= 44 })
        #expect(layouts.allSatisfy { (70...80).contains($0.stripHeight) })
    }

    @Test func layoutRespondsToPlatformAndAccessibilityTextNeeds() {
        let phone = PatternPageThumbnailLayoutPolicy.resolve(
            platform: .phone,
            usesAccessibilitySizes: false
        )
        let pad = PatternPageThumbnailLayoutPolicy.resolve(
            platform: .pad,
            usesAccessibilitySizes: false
        )
        let mac = PatternPageThumbnailLayoutPolicy.resolve(
            platform: .mac,
            usesAccessibilitySizes: false
        )
        let accessiblePhone = PatternPageThumbnailLayoutPolicy.resolve(
            platform: .phone,
            usesAccessibilitySizes: true
        )

        #expect(phone != pad)
        #expect(mac != pad)
        #expect(accessiblePhone != phone)
        #expect(accessiblePhone.stripHeight >= phone.stripHeight)
        #expect(phone.thumbnailWidth < pad.thumbnailWidth)
        #expect(mac.thumbnailWidth < pad.thumbnailWidth)
        #expect(accessiblePhone.thumbnailHeight < phone.thumbnailHeight)
        #expect(phone.itemSpacing < pad.itemSpacing)
    }

    @Test func pageRequestIdentityIsScopedToTheAssetRevisionPageAndPageCount() {
        let assetID = UUID()
        let identity = PatternPageThumbnailAssetIdentity(
            assetID: assetID,
            assetRevision: "sha-a",
            pageCount: 8
        )
        let request = identity.request(pageIndex: 2)

        #expect(request == identity.request(pageIndex: 2))
        #expect(request != identity.request(pageIndex: 3))
        #expect(request != PatternPageThumbnailAssetIdentity(
            assetID: assetID,
            assetRevision: "sha-b",
            pageCount: 8
        ).request(pageIndex: 2))
        #expect(request != PatternPageThumbnailAssetIdentity(
            assetID: assetID,
            assetRevision: "sha-a",
            pageCount: 9
        ).request(pageIndex: 2))
    }

    @Test func preloadIdentityRestartsForAnotherAssetAtTheSameSelectedPage() {
        let first = PatternPageThumbnailAssetIdentity(
            assetID: UUID(),
            assetRevision: "sha-a",
            pageCount: 8
        )
        let second = PatternPageThumbnailAssetIdentity(
            assetID: UUID(),
            assetRevision: "sha-a",
            pageCount: 8
        )

        #expect(first.preload(selectedPage: 2) != second.preload(selectedPage: 2))
        #expect(first.preload(selectedPage: 2) != first.preload(selectedPage: 3))
    }
}
