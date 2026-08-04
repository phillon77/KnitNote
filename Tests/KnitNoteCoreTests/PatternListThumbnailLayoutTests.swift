import Testing
@testable import KnitNoteCore

@Suite struct PatternListThumbnailLayoutTests {
    @Test func youtubeUsesCompactWidescreenThumbnail() {
        let layout = PatternListThumbnailLayout.resolve(for: .youtube)

        #expect(layout.width == 76)
        #expect(layout.height == 43)
        #expect(layout.minimumRowHeight == 43)
    }

    @Test(arguments: [PatternKind.pdf, .image])
    func localDocumentsKeepTheExistingPortraitThumbnail(_ kind: PatternKind) {
        let layout = PatternListThumbnailLayout.resolve(for: kind)

        #expect(layout.width == 76)
        #expect(layout.height == 96)
        #expect(layout.minimumRowHeight == 96)
    }
}
