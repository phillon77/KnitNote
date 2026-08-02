import Testing
@testable import KnitNoteCore

@Suite struct PatternReaderThumbnailIntegrationTests {
    @Test func thumbnailSelectionUsesTheSameClampedPageTargetAsOtherControls() {
        #expect(PatternReaderPageTarget.resolve(requested: 7, current: 2, pageCount: 5) == 4)
        #expect(PatternReaderPageTarget.resolve(requested: 2, current: 2, pageCount: 5) == nil)
    }

    @Test func thumbnailStripOnlyShowsForMultiPagePDFsOutsideMarkupMode() {
        #expect(PatternPageThumbnailPolicy.shouldShow(kind: .pdf, pageCount: 2, markupMode: false))
        #expect(!PatternPageThumbnailPolicy.shouldShow(kind: .pdf, pageCount: 1, markupMode: false))
        #expect(!PatternPageThumbnailPolicy.shouldShow(kind: .image, pageCount: 2, markupMode: false))
        #expect(!PatternPageThumbnailPolicy.shouldShow(kind: .pdf, pageCount: 2, markupMode: true))
    }
}
