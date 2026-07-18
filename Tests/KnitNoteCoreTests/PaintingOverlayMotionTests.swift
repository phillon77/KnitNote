import Testing
@testable import KnitNoteCore

@Test func handExtremaAreVisibleAndRestIsExact() {
    let left = PaintingOverlayMotion(handProgress: -1, blinkProgress: 0)
    let right = PaintingOverlayMotion(handProgress: 1, blinkProgress: 0)
    let rest = PaintingOverlayMotion(handProgress: 0, blinkProgress: 0)
    #expect(right.handsRotationDegrees - left.handsRotationDegrees >= 2.4)
    #expect(right.handsVerticalTravel - left.handsVerticalTravel >= 3.0)
    #expect(rest.handsRotationDegrees == 0)
    #expect(rest.handsVerticalTravel == 0)
}

@Test func closedBlinkIsReadableOnPhone() {
    let open = PaintingOverlayMotion(handProgress: 0, blinkProgress: 0)
    let closed = PaintingOverlayMotion(handProgress: 0, blinkProgress: 1)
    #expect(open.eyeCoverOpacity == 0)
    #expect(closed.eyeCoverOpacity == 1)
    #expect(closed.eyeScaleY <= 0.12)
}

@Test func motionInputsClampToTheirSupportedRanges() {
    #expect(
        PaintingOverlayMotion(handProgress: -10, blinkProgress: -2)
            == PaintingOverlayMotion(handProgress: -1, blinkProgress: 0)
    )
    #expect(
        PaintingOverlayMotion(handProgress: 10, blinkProgress: 2)
            == PaintingOverlayMotion(handProgress: 1, blinkProgress: 1)
    )
}
