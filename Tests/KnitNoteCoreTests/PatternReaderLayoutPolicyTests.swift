import Testing
@testable import KnitNoteCore

@Suite struct PatternReaderLayoutPolicyTests {
    @Test func iPadLandscapeFitsWidthAndKeepsOverlayPageControls() {
        let policy = PatternReaderLayoutPolicy.resolve(isPad: true, width: 1194, height: 834)
        #expect(policy.pdfScaleMode == .fitWidth)
        #expect(policy.pageControlPlacement == .overlay)
    }

    @Test func iPadPortraitReservesPageControlsBelowThePDF() {
        let policy = PatternReaderLayoutPolicy.resolve(isPad: true, width: 834, height: 1194)
        #expect(policy.pdfScaleMode == .automatic)
        #expect(policy.pageControlPlacement == .reservedBelow)
    }

    @Test func iPhoneKeepsAutomaticOverlayBehaviorInBothOrientations() {
        #expect(PatternReaderLayoutPolicy.resolve(isPad: false, width: 430, height: 932)
            == .init(pdfScaleMode: .automatic, pageControlPlacement: .overlay))
        #expect(PatternReaderLayoutPolicy.resolve(isPad: false, width: 932, height: 430)
            == .init(pdfScaleMode: .automatic, pageControlPlacement: .overlay))
    }

    @Test func squareIPadUsesPortraitSafeBehavior() {
        let policy = PatternReaderLayoutPolicy.resolve(isPad: true, width: 800, height: 800)
        #expect(policy.pdfScaleMode == .automatic)
        #expect(policy.pageControlPlacement == .reservedBelow)
    }

    @Test func highlightMetricsMatchTheApprovedVisualAndTouchSizes() {
        #expect(PatternHighlightMetrics.horizontalVisibleThickness == 22)
        #expect(PatternHighlightMetrics.verticalVisibleThickness == 3)
        #expect(PatternHighlightMetrics.minimumDragThickness == 44)
    }
}
