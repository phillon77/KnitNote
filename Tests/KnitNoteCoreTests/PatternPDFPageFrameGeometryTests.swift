import CoreGraphics
import Testing
@testable import KnitNoteCore

@Suite struct PatternPDFPageFrameGeometryTests {
    @Test func pageAnchorRoundTripsTheVisiblePDFDestination() {
        let pageBounds = CGRect(x: 10, y: 20, width: 400, height: 800)
        let destination = CGPoint(x: 110, y: 620)

        let anchor = PatternPDFPageAnchorGeometry.normalizedAnchor(
            for: destination,
            in: pageBounds
        )
        let restoredDestination = PatternPDFPageAnchorGeometry.pagePoint(
            offsetX: anchor.x,
            offsetY: anchor.y,
            in: pageBounds
        )

        #expect(anchor.x == 0.25)
        #expect(anchor.y == 0.75)
        #expect(restoredDestination == destination)
    }

    @Test func pageAnchorClampsPointsOutsideThePDFPage() {
        let pageBounds = CGRect(x: 10, y: 20, width: 400, height: 800)

        let anchor = PatternPDFPageAnchorGeometry.normalizedAnchor(
            for: CGPoint(x: -50, y: 900),
            in: pageBounds
        )

        #expect(anchor.x == 0)
        #expect(anchor.y == 1)
    }

    @Test func scrollAnchorRoundTripsTheActualContentOffset() {
        let minimum = CGPoint(x: -12, y: -20)
        let maximum = CGPoint(x: 488, y: 980)
        let contentOffset = CGPoint(x: 113, y: 730)

        let anchor = PatternPDFScrollAnchorGeometry.normalizedAnchor(
            for: contentOffset,
            minimum: minimum,
            maximum: maximum
        )
        let restored = PatternPDFScrollAnchorGeometry.contentOffset(
            anchorX: anchor.x,
            anchorY: anchor.y,
            minimum: minimum,
            maximum: maximum
        )

        #expect(anchor == CGPoint(x: 0.25, y: 0.75))
        #expect(restored == contentOffset)
    }

    @Test func scrollAnchorClampsOverscrollAndHandlesAnUnscrollableAxis() {
        let anchor = PatternPDFScrollAnchorGeometry.normalizedAnchor(
            for: CGPoint(x: 80, y: 900),
            minimum: CGPoint(x: 20, y: 100),
            maximum: CGPoint(x: 20, y: 500)
        )

        #expect(anchor == CGPoint(x: 0, y: 1))
    }

    @Test func verticalViewportAnchorKeepsTheSamePDFLineAtTheVisibleCenter() {
        let restored = PatternPDFViewportAnchorGeometry.verticalContentOffset(
            currentContentOffsetY: 220,
            targetYInViewport: 410,
            viewportBounds: CGRect(x: 0, y: 0, width: 700, height: 500),
            minimumY: -20,
            maximumY: 980
        )

        #expect(restored == 380)
    }

    @Test func verticalViewportAnchorClampsAtTheScrollableEdges() {
        let restored = PatternPDFViewportAnchorGeometry.verticalContentOffset(
            currentContentOffsetY: 900,
            targetYInViewport: 700,
            viewportBounds: CGRect(x: 0, y: 0, width: 700, height: 500),
            minimumY: -20,
            maximumY: 980
        )

        #expect(restored == 980)
    }

    @Test func unflippedFrameUsesScrolledBoundsOriginWhenConvertingToFlippedCoordinates() {
        let bounds = CGRect(x: 0, y: 100, width: 500, height: 492)
        let appKitFrame = CGRect(x: 25, y: 9.5, width: 450, height: 792)

        let swiftUIFrame = PatternPDFPageFrameGeometry.flippedFrame(
            appKitFrame,
            in: bounds
        )

        #expect(swiftUIFrame == CGRect(x: 25, y: -209.5, width: 450, height: 792))
    }

    @Test func conversionPreservesAFrameExtendingOutsideVisibleBounds() {
        let bounds = CGRect(x: 0, y: 100, width: 500, height: 240)
        let appKitFrame = CGRect(x: -20, y: -30, width: 540, height: 400)

        let swiftUIFrame = PatternPDFPageFrameGeometry.flippedFrame(
            appKitFrame,
            in: bounds
        )

        #expect(swiftUIFrame == CGRect(x: -20, y: -30, width: 540, height: 400))
        #expect(swiftUIFrame.minY < bounds.minY)
        #expect(swiftUIFrame.maxY > bounds.maxY)
    }
}
