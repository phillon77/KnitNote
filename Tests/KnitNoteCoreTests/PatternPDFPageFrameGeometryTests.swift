import CoreGraphics
import Testing
@testable import KnitNoteCore

@Suite struct PatternPDFPageFrameGeometryTests {
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
