import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct PatternReaderSessionTests {
    @Test func projectSessionStaysLoadingUntilItHydratesWithTheExactUsageState() {
        let context = projectContext()
        let savedState = richReadingState()
        var session = PatternReaderSession(context: context)

        #expect(session.phase == .loading)
        #expect(session.readingState == nil)
        #expect(!session.canAcceptCanvasCallbacks)
        #expect(!session.canPersist)

        session.hydrate(readingState: savedState)

        #expect(session.phase == .hydrated)
        #expect(session.readingState == savedState)
        #expect(session.canAcceptCanvasCallbacks)
        #expect(session.canPersist)
    }

    @Test func canvasCallbacksBeforeHydrationAreIgnored() {
        var session = PatternReaderSession(context: projectContext())

        let accepted = session.acceptCanvasState(PatternReadingState(pageIndex: 9, zoomScale: 3))

        #expect(!accepted)
        #expect(session.phase == .loading)
        #expect(session.readingState == nil)
    }

    @Test func entitlementLockedSessionNeverPersistsPassiveCanvasCallbacks() {
        let context = PatternReaderContext.project(
            patternID: UUID(),
            usageID: UUID(),
            projectID: UUID(),
            projectIsCompleted: false,
            entitlementCanWrite: false
        )
        var session = PatternReaderSession(context: context)
        session.hydrate(readingState: richReadingState())

        #expect(session.canAcceptCanvasCallbacks)
        #expect(!session.canPersist)
    }

    @Test func changingProjectUsageResetsThenLoadsOnlyTheNewUsageState() {
        let firstContext = projectContext()
        let secondContext = PatternReaderContext.project(
            patternID: firstContext.patternID,
            usageID: UUID(),
            projectID: UUID(),
            projectIsCompleted: false
        )
        var session = PatternReaderSession(context: firstContext)
        session.hydrate(readingState: richReadingState())

        session.beginLoading(context: secondContext)

        #expect(session.context == secondContext)
        #expect(session.phase == .loading)
        #expect(session.readingState == nil)
        #expect(!session.canAcceptCanvasCallbacks)

        let secondState = PatternReadingState(pageIndex: 1, zoomScale: 1.5, offsetX: 0.2, offsetY: 0.6)
        session.hydrate(readingState: secondState)

        #expect(session.phase == .hydrated)
        #expect(session.readingState == secondState)
    }

    @Test func freshSessionRehydratesEveryPersistedReaderField() {
        let persisted = richReadingState()
        var firstSession = PatternReaderSession(context: projectContext())
        firstSession.hydrate(readingState: persisted)
        let archivedState = try! #require(firstSession.readingState)

        var reopenedSession = PatternReaderSession(context: projectContext())
        reopenedSession.hydrate(readingState: archivedState)

        #expect(reopenedSession.readingState == persisted)
        #expect(reopenedSession.readingState?.pageIndex == 4)
        #expect(reopenedSession.readingState?.zoomScale == 2.25)
        #expect(reopenedSession.readingState?.offsetX == 0.15)
        #expect(reopenedSession.readingState?.offsetY == 0.8)
        #expect(reopenedSession.readingState?.highlightEnabled == true)
        #expect(reopenedSession.readingState?.highlightMode == .cross)
        #expect(reopenedSession.readingState?.pageStates[7]?.note == "sleeve repeat")
    }

    @Test func twoProjectUsagesKeepIndependentPDFWidthRatios() {
        let patternID = UUID()
        let first = PatternProjectUsage(
            patternID: patternID,
            projectID: UUID(),
            sortOrder: 0,
            readingState: .init(pdfWidthScaleRatio: 1.25)
        )
        let second = PatternProjectUsage(
            patternID: patternID,
            projectID: UUID(),
            sortOrder: 1,
            readingState: .init(pdfWidthScaleRatio: 2.0)
        )

        #expect(first.readingState.pdfWidthScaleRatio == 1.25)
        #expect(second.readingState.pdfWidthScaleRatio == 2.0)
    }

    @Test func browsingStateRestoresSharedPDFWidthRatio() {
        var state = PatternReadingState(pdfWidthScaleRatio: 1.4)
        let browsingState = PatternBrowsingState(readingState: state)

        state.pdfWidthScaleRatio = 2.0
        state.applyBrowsingState(browsingState)

        #expect(state.pdfWidthScaleRatio == 1.4)
    }

    @Test func usageUpdateNormalizesInvalidPDFWidthRatio() {
        var usage = PatternProjectUsage(
            patternID: UUID(),
            projectID: UUID(),
            sortOrder: 0
        )

        usage.updatePDFWidthScaleRatio(-1)

        #expect(usage.readingState.pdfWidthScaleRatio == 1.0)
    }

    private func projectContext() -> PatternReaderContext {
        .project(patternID: UUID(), usageID: UUID(), projectID: UUID(), projectIsCompleted: false)
    }

    private func richReadingState() -> PatternReadingState {
        .init(
            pageIndex: 4,
            pdfWidthScaleRatio: 1.75,
            zoomScale: 2.25,
            offsetX: 0.15,
            offsetY: 0.8,
            highlightEnabled: true,
            highlightPosition: 0.31,
            highlightMode: .cross,
            verticalHighlightPosition: 0.72,
            pageNote: "neck shaping",
            pageStates: [
                4: .init(horizontalPosition: 0.31, verticalPosition: 0.72, note: "neck shaping"),
                7: .init(horizontalPosition: 0.63, verticalPosition: 0.19, note: "sleeve repeat")
            ]
        )
    }
}
