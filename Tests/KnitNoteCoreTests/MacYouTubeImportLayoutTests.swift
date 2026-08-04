import Testing
@testable import KnitNoteCore

@Suite struct MacYouTubeImportLayoutTests {
    @Test func approvedMacSheetDimensionsStayUsable() {
        #expect(MacYouTubeImportLayout.minimumWidth == 520)
        #expect(MacYouTubeImportLayout.idealWidth == 620)
        #expect(MacYouTubeImportLayout.minimumHeight == 520)
        #expect(MacYouTubeImportLayout.contentMaximumWidth == 560)
        #expect(MacYouTubeImportLayout.outerPadding == 28)
    }

    @Test func previewUsesABoundedWidescreenFrame() {
        #expect(MacYouTubeImportLayout.previewMaximumWidth == 320)
        #expect(MacYouTubeImportLayout.previewAspectRatio == 16.0 / 9.0)
    }
}
