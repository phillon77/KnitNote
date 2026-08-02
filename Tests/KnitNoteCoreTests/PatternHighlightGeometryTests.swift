import CoreGraphics
import Testing
@testable import KnitNoteCore

@Suite struct PatternHighlightGeometryTests {
    @Test func sameNormalizedLineSurvivesPortraitAndLandscapePageFrames() {
        let portrait = CGRect(x: 72, y: 96, width: 620, height: 900)
        let landscape = CGRect(x: 84, y: -238, width: 940, height: 1364)

        let portraitY = PatternHighlightGeometry.coordinate(
            normalized: 0.72,
            origin: portrait.minY,
            length: portrait.height
        )
        let landscapeY = PatternHighlightGeometry.coordinate(
            normalized: 0.72,
            origin: landscape.minY,
            length: landscape.height
        )

        #expect(PatternHighlightGeometry.normalized(
            coordinate: portraitY,
            origin: portrait.minY,
            length: portrait.height
        ) == 0.72)
        #expect(PatternHighlightGeometry.normalized(
            coordinate: landscapeY,
            origin: landscape.minY,
            length: landscape.height
        ) == 0.72)
    }

    @Test func dragPositionsClampToTheDisplayedPage() {
        #expect(PatternHighlightGeometry.normalized(
            coordinate: 40,
            origin: 100,
            length: 800
        ) == 0)
        #expect(PatternHighlightGeometry.normalized(
            coordinate: 960,
            origin: 100,
            length: 800
        ) == 1)
    }

    @Test func missingOrInvalidPageFrameFallsBackToTheCanvas() {
        let canvas = CGSize(width: 700, height: 900)
        #expect(PatternHighlightGeometry.resolvedContentRect(nil, canvasSize: canvas)
            == CGRect(origin: .zero, size: canvas))
        #expect(PatternHighlightGeometry.resolvedContentRect(
            CGRect(x: 1, y: 2, width: 0, height: 500),
            canvasSize: canvas
        ) == CGRect(origin: .zero, size: canvas))
    }

    @Test func fullCanvasEndpointsKeepDragTargetCentersInsideEachEdge() {
        let inset = PatternHighlightGeometry.centerInset(contentRect: nil)

        #expect(inset == 22)
        #expect(PatternHighlightGeometry.coordinate(
            normalized: 0,
            origin: 0,
            length: 200,
            centerInset: inset
        ) == 22)
        #expect(PatternHighlightGeometry.coordinate(
            normalized: 1,
            origin: 0,
            length: 200,
            centerInset: inset
        ) == 178)
        #expect(PatternHighlightGeometry.normalized(
            coordinate: 22,
            origin: 0,
            length: 200,
            centerInset: inset
        ) == 0.11)
        #expect(PatternHighlightGeometry.normalized(
            coordinate: 178,
            origin: 0,
            length: 200,
            centerInset: inset
        ) == 0.89)
    }

    @Test func fullCanvasIntermediatePositionsPreserveLegacyCoordinates() {
        let inset = PatternHighlightGeometry.centerInset(contentRect: nil)

        #expect(PatternHighlightGeometry.coordinate(
            normalized: 0.25,
            origin: 0,
            length: 200,
            centerInset: inset
        ) == 50)
        #expect(PatternHighlightGeometry.coordinate(
            normalized: 0.75,
            origin: 0,
            length: 200,
            centerInset: inset
        ) == 150)
        #expect(PatternHighlightGeometry.normalized(
            coordinate: 50,
            origin: 0,
            length: 200,
            centerInset: inset
        ) == 0.25)
        #expect(PatternHighlightGeometry.normalized(
            coordinate: 150,
            origin: 0,
            length: 200,
            centerInset: inset
        ) == 0.75)
    }

    @Test func fullCanvasInsetCollapsesSafelyWhenEitherAxisIsSmallerThanDragTarget() {
        let inset = PatternHighlightGeometry.centerInset(contentRect: nil)

        for length: CGFloat in [0, 20, 43.9, 44] {
            let minimum = PatternHighlightGeometry.coordinate(
                normalized: 0,
                origin: 7,
                length: length,
                centerInset: inset
            )
            let maximum = PatternHighlightGeometry.coordinate(
                normalized: 1,
                origin: 7,
                length: length,
                centerInset: inset
            )

            #expect(minimum.isFinite)
            #expect(maximum.isFinite)
            #expect(minimum == maximum)
            #expect(minimum == 7 + (max(0, length) / 2))
        }
    }

    @Test func validPDFPageFrameKeepsExactNormalizedEndpointsWithoutAnInset() {
        let pageFrame = CGRect(x: 83, y: -217, width: 612, height: 792)
        let inset = PatternHighlightGeometry.centerInset(contentRect: pageFrame)

        #expect(inset == 0)
        #expect(PatternHighlightGeometry.coordinate(
            normalized: 0,
            origin: pageFrame.minY,
            length: pageFrame.height,
            centerInset: inset
        ) == pageFrame.minY)
        #expect(PatternHighlightGeometry.coordinate(
            normalized: 1,
            origin: pageFrame.minX,
            length: pageFrame.width,
            centerInset: inset
        ) == pageFrame.maxX)
    }

    @Test func oversizedZoomedPageDrawsOnlyItsVisibleCanvasIntersection() {
        let pageFrame = CGRect(x: -900, y: -240, width: 1_200, height: 1_600)
        let canvas = CGSize(width: 700, height: 900)

        #expect(
            PatternHighlightGeometry.visibleDrawingRect(
                contentRect: pageFrame,
                canvasSize: canvas
            ) == CGRect(x: 0, y: 0, width: 300, height: 900)
        )
    }
}
