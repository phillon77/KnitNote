import Testing
@testable import KnitNoteCore

@Test func preloadWindowContainsCurrentAndImmediateNeighborsOnly() {
    #expect(PatternPageThumbnailPolicy.preloadIndices(pageCount: 10, currentPage: 5) == [4, 5, 6])
    #expect(PatternPageThumbnailPolicy.preloadIndices(pageCount: 10, currentPage: 0) == [0, 1])
    #expect(PatternPageThumbnailPolicy.preloadIndices(pageCount: 1, currentPage: 0) == [])
}

@Test func thumbnailStripIsLimitedToMultiPagePDFOutsideMarkupMode() {
    #expect(PatternPageThumbnailPolicy.shouldShow(kind: .pdf, pageCount: 2, markupMode: false))
    #expect(!PatternPageThumbnailPolicy.shouldShow(kind: .pdf, pageCount: 1, markupMode: false))
    #expect(!PatternPageThumbnailPolicy.shouldShow(kind: .image, pageCount: 2, markupMode: false))
    #expect(!PatternPageThumbnailPolicy.shouldShow(kind: .pdf, pageCount: 2, markupMode: true))
}
