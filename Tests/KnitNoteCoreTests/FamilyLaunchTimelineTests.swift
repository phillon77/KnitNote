import Testing
@testable import KnitNoteCore

@Test func familyLaunchUsesApprovedShotBoundaries() {
    #expect(FamilyLaunchTimeline.localSequenceMilliseconds == 3_100)
    #expect(FamilyLaunchTimeline.handsEndMilliseconds == 1_100)
    #expect(FamilyLaunchTimeline.firstWideEndMilliseconds == 1_800)
    #expect(FamilyLaunchTimeline.lemonEndMilliseconds == 2_800)
    #expect(FamilyLaunchTimeline.finalWideEndMilliseconds == 3_100)
    #expect(LaunchExperienceTiming.normalTotalMilliseconds == 4_000)
}

@Test func timelineStartsAndEndsWideAndStill() {
    let start = FamilyLaunchTimeline.frame(atMilliseconds: 0)
    let end = FamilyLaunchTimeline.frame(atMilliseconds: 3_100)
    #expect(start.cameraZoom == 1)
    #expect(end.cameraZoom == 1)
    #expect(start.handProgress == 0)
    #expect(end.handProgress == 0)
    #expect(start.blinkProgress == 0)
    #expect(end.blinkProgress == 0)
}

@Test func handsShotFocusesHandsAndHasTwoExtrema() {
    let first = FamilyLaunchTimeline.frame(atMilliseconds: 450)
    let second = FamilyLaunchTimeline.frame(atMilliseconds: 650)
    #expect(first.cameraZoom >= 2.0)
    #expect(first.cameraFocusX == FamilyLaunchTimeline.handsFocusX)
    #expect(first.cameraFocusY == FamilyLaunchTimeline.handsFocusY)
    #expect(abs(first.handProgress - second.handProgress) >= 1.5)
    #expect(first.blinkProgress == 0)
}

@Test func lemonShotFocusesLemonAndCompletesOneBlink() {
    let open = FamilyLaunchTimeline.frame(atMilliseconds: 2_150)
    let closingFinished = FamilyLaunchTimeline.frame(atMilliseconds: 2_320)
    let closed = FamilyLaunchTimeline.frame(atMilliseconds: 2_450)
    let reopened = FamilyLaunchTimeline.frame(atMilliseconds: 2_650)
    #expect(closed.cameraZoom >= 2.5)
    #expect(closed.cameraFocusX == FamilyLaunchTimeline.lemonFocusX)
    #expect(closed.cameraFocusY == FamilyLaunchTimeline.lemonFocusY)
    #expect(open.blinkProgress == 0)
    #expect(closingFinished.blinkProgress == 1)
    #expect(closed.blinkProgress == 1)
    #expect(reopened.blinkProgress == 0)
    #expect(closed.handProgress == 0)
}

@Test func timelineClampsElapsedTime() {
    #expect(
        FamilyLaunchTimeline.frame(atMilliseconds: -1)
            == FamilyLaunchTimeline.frame(atMilliseconds: 0)
    )
    #expect(
        FamilyLaunchTimeline.frame(atMilliseconds: 99_000)
            == FamilyLaunchTimeline.frame(atMilliseconds: 3_100)
    )
}
