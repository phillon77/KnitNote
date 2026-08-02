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

public enum PatternPageThumbnailPlatform: Sendable, Equatable, CaseIterable {
    case phone
    case pad
    case mac
}

public struct PatternPageThumbnailLayoutPolicy: Sendable, Equatable {
    public let minimumHitTarget: Double
    public let stripHeight: Double

    public static func resolve(
        platform _: PatternPageThumbnailPlatform,
        usesAccessibilitySizes _: Bool
    ) -> Self {
        return Self(minimumHitTarget: 44, stripHeight: 44)
    }
}
