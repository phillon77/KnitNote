import Testing
@testable import KnitNoteCore

@Suite struct PatternReaderPageTransitionTests {
    @Test func failedPageSaveRestoresTheCompletePreTransitionReaderState() {
        let oldState = PatternReadingState(
            pageIndex: 2,
            zoomScale: 2.4,
            offsetX: 0.18,
            offsetY: 0.82,
            highlightEnabled: true,
            highlightPosition: 0.23,
            highlightMode: .cross,
            verticalHighlightPosition: 0.77,
            pageNote: "keep sleeve shaping",
            pageStates: [
                2: .init(horizontalPosition: 0.23, verticalPosition: 0.77, note: "keep sleeve shaping"),
                7: .init(horizontalPosition: 0.91, verticalPosition: 0.09, note: "new-page note")
            ]
        )
        var proposedState = oldState
        proposedState.transitionToPDFPage(7)

        let transition = PatternReaderPageTransition(previousState: oldState, proposedState: proposedState)
        let restoredState = try! #require(transition?.rollbackState)

        #expect(restoredState == oldState)
        #expect(restoredState.pageIndex == 2)
        #expect(restoredState.highlightPosition == 0.23)
        #expect(restoredState.verticalHighlightPosition == 0.77)
        #expect(restoredState.pageNote == "keep sleeve shaping")
        #expect(restoredState.pageStates[7]?.note == "new-page note")
    }

    @Test func unchangedReaderStateDoesNotCreateARollbackTransaction() {
        let state = PatternReadingState(pageIndex: 3, pageNote: "stable")

        #expect(PatternReaderPageTransition(previousState: state, proposedState: state) == nil)
    }
}
