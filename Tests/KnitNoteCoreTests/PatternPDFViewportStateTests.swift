import CoreGraphics
import Testing
@testable import KnitNoteCore

@Suite struct PatternPDFViewportStateTests {
    @Test func validViewportPreservesPageGeometryAndScale() {
        let frame = CGRect(x: -40, y: 120, width: 612, height: 792)
        let state = PatternPDFViewportState(
            pageIndex: 3,
            pageFrame: frame,
            scaleFactor: 1.75,
            fitWidthScaleFactor: 1.25,
            isUserInteracting: true
        )

        #expect(state.pageIndex == 3)
        #expect(state.pageFrame == frame)
        #expect(state.scaleFactor == 1.75)
        #expect(state.fitWidthScaleFactor == 1.25)
        #expect(state.isUserInteracting)
    }

    @Test func invalidViewportValuesDegradeSafely() {
        let state = PatternPDFViewportState(
            pageIndex: -4,
            pageFrame: CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
            scaleFactor: CGFloat.infinity,
            fitWidthScaleFactor: 0,
            isUserInteracting: false
        )

        #expect(state.pageIndex == 0)
        #expect(state.pageFrame == nil)
        #expect(state.scaleFactor == 1)
        #expect(state.fitWidthScaleFactor == 1)
    }

    @Test func publicationGateAcceptsScrollFrameChangesButRejectsDuplicates() {
        var gate = PatternPDFViewportPublicationGate()
        let first = PatternPDFViewportState(pageFrame: CGRect(x: 0, y: 0, width: 500, height: 700))
        let scrolled = PatternPDFViewportState(pageFrame: CGRect(x: 0, y: -180, width: 500, height: 700))

        let acceptsFirst = gate.accept(first)
        let rejectsDuplicate = !gate.accept(first)
        let acceptsScrolled = gate.accept(scrolled)

        #expect(acceptsFirst)
        #expect(rejectsDuplicate)
        #expect(acceptsScrolled)
        gate.reset()
        let acceptsAfterReset = gate.accept(scrolled)
        #expect(acceptsAfterReset)
    }
}
