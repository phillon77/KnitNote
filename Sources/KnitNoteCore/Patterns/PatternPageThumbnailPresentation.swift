import Foundation

public struct PatternPageThumbnailPresentation: Sendable, Equatable {
    public let pageIndex: Int
    public let pageCount: Int
    public let selectedPage: Int

    public init(pageIndex: Int, pageCount: Int, selectedPage: Int) {
        self.pageIndex = pageIndex
        self.pageCount = pageCount
        self.selectedPage = selectedPage
    }

    public var pageNumber: Int {
        pageIndex + 1
    }

    public var isSelected: Bool {
        pageIndex >= 0
            && pageIndex < pageCount
            && selectedPage >= 0
            && selectedPage < pageCount
            && selectedPage == pageIndex
    }

    public var accessibilityArguments: [Int] {
        [pageNumber, pageCount]
    }
}

struct PatternPageThumbnailAssetIdentity: Hashable, Sendable {
    let assetID: UUID
    let assetRevision: String
    let pageCount: Int

    func request(pageIndex: Int) -> PatternPageThumbnailRequestIdentity {
        PatternPageThumbnailRequestIdentity(asset: self, pageIndex: pageIndex)
    }

    func preload(selectedPage: Int) -> PatternPageThumbnailPreloadIdentity {
        PatternPageThumbnailPreloadIdentity(asset: self, selectedPage: selectedPage)
    }
}

struct PatternPageThumbnailRequestIdentity: Hashable, Sendable {
    let asset: PatternPageThumbnailAssetIdentity
    let pageIndex: Int
}

struct PatternPageThumbnailPreloadIdentity: Hashable, Sendable {
    let asset: PatternPageThumbnailAssetIdentity
    let selectedPage: Int
}

public enum PatternPageThumbnailPlatform: Sendable, Equatable, CaseIterable {
    case phone
    case pad
    case mac
}

public struct PatternPageThumbnailLayoutPolicy: Sendable, Equatable {
    public let minimumHitTarget: Double
    public let stripHeight: Double
    let thumbnailWidth: Double
    let thumbnailHeight: Double
    let itemSpacing: Double

    public static func resolve(
        platform: PatternPageThumbnailPlatform,
        usesAccessibilitySizes: Bool
    ) -> Self {
        switch (platform, usesAccessibilitySizes) {
        case (.phone, false):
            return Self(
                minimumHitTarget: 44,
                stripHeight: 72,
                thumbnailWidth: 46,
                thumbnailHeight: 44,
                itemSpacing: 6
            )
        case (.pad, false):
            return Self(
                minimumHitTarget: 44,
                stripHeight: 76,
                thumbnailWidth: 52,
                thumbnailHeight: 48,
                itemSpacing: 10
            )
        case (.mac, false):
            return Self(
                minimumHitTarget: 44,
                stripHeight: 72,
                thumbnailWidth: 48,
                thumbnailHeight: 44,
                itemSpacing: 8
            )
        case (.phone, true):
            return Self(
                minimumHitTarget: 44,
                stripHeight: 80,
                thumbnailWidth: 52,
                thumbnailHeight: 36,
                itemSpacing: 8
            )
        case (.pad, true):
            return Self(
                minimumHitTarget: 44,
                stripHeight: 80,
                thumbnailWidth: 58,
                thumbnailHeight: 38,
                itemSpacing: 12
            )
        case (.mac, true):
            return Self(
                minimumHitTarget: 44,
                stripHeight: 80,
                thumbnailWidth: 54,
                thumbnailHeight: 36,
                itemSpacing: 10
            )
        }
    }
}
