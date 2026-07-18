import Testing
@testable import KnitNoteCore

@Test(arguments: [
    LaunchExperiencePhase.revealing,
    .animating,
    .settling,
    .enteringHome,
    .complete
])
func homeInteractionIsEnabledOnlyAfterLaunchCompletes(phase: LaunchExperiencePhase) {
    #expect(launchHomeIsInteractive(phase: phase) == (phase == .complete))
}

@Test func normalLaunchVisitsEveryPhaseOnce() {
    var state = LaunchExperienceState(reduceMotion: false)
    #expect(state.phase == .revealing)
    state.advance(); #expect(state.phase == .animating)
    state.advance(); #expect(state.phase == .settling)
    state.advance(); #expect(state.phase == .enteringHome)
    state.advance(); #expect(state.phase == .complete)
    state.advance(); #expect(state.phase == .complete)
}

@Test func reduceMotionOmitsLocalObjectMotion() {
    var state = LaunchExperienceState(reduceMotion: true)
    #expect(state.phase == .revealing)
    state.advance(); #expect(state.phase == .enteringHome)
    state.advance(); #expect(state.phase == .complete)
}

@Test func skipIsIdempotentAndConvergesThroughHomeTransition() {
    var state = LaunchExperienceState(reduceMotion: false)
    state.skip(); #expect(state.phase == .enteringHome)
    state.skip(); #expect(state.phase == .enteringHome)
    state.advance(); #expect(state.phase == .complete)
    state.skip(); #expect(state.phase == .complete)
}

@Test func skipFromEveryLaterPhaseNeverMovesBackward() {
    var animating = LaunchExperienceState(reduceMotion: false)
    animating.advance()
    #expect(animating.phase == .animating)
    animating.skip()
    #expect(animating.phase == .enteringHome)

    var settling = LaunchExperienceState(reduceMotion: false)
    settling.advance()
    settling.advance()
    #expect(settling.phase == .settling)
    settling.skip()
    #expect(settling.phase == .enteringHome)

    var enteringHome = LaunchExperienceState(reduceMotion: false)
    enteringHome.advance()
    enteringHome.advance()
    enteringHome.advance()
    #expect(enteringHome.phase == .enteringHome)
    enteringHome.skip()
    #expect(enteringHome.phase == .enteringHome)

    var complete = LaunchExperienceState(reduceMotion: false)
    complete.advance()
    complete.advance()
    complete.advance()
    complete.advance()
    #expect(complete.phase == .complete)
    complete.skip()
    #expect(complete.phase == .complete)
}

@Test func completePhaseRemainsStableAfterRepeatedAdvances() {
    var state = LaunchExperienceState(reduceMotion: false)
    state.advance()
    state.advance()
    state.advance()
    state.advance()
    #expect(state.phase == .complete)

    for _ in 0..<3 {
        state.advance()
        #expect(state.phase == .complete)
    }
}

@Test func everyHomeTransitionGetsTheFullVisualTransitionLifetime() {
    #expect(LaunchExperienceTiming.normalHomeTransitionMilliseconds == 600)
    #expect(LaunchExperienceTiming.skipHomeTransitionMilliseconds == 600)
    #expect(LaunchExperienceTiming.reduceMotionHomeTransitionMilliseconds == 600)
}

@Test func normalLaunchStillLastsTwentySixHundredMilliseconds() {
    #expect(LaunchExperienceTiming.normalTotalMilliseconds == 2_600)
}

@Test func homeTransitionExposesSecondsForSwiftUI() {
    #expect(LaunchExperienceTiming.homeTransitionSeconds == 0.6)
}

@Test func paintingRevealUsesTheSharedThreeHundredMillisecondTiming() {
    #expect(LaunchExperienceTiming.revealMilliseconds == 300)
    #expect(LaunchExperienceTiming.revealSeconds == 0.3)
}

@Test func paintingRevealComposesWithTheExistingHomeTransitionOpacity() {
    #expect(launchPaintingOpacity(revealProgress: 0, transitionOpacity: 1) == 0)
    #expect(launchPaintingOpacity(revealProgress: 0.5, transitionOpacity: 1) == 0.5)
    #expect(launchPaintingOpacity(revealProgress: 1, transitionOpacity: 1) == 1)
    #expect(launchPaintingOpacity(revealProgress: 0.5, transitionOpacity: 0.5) == 0.25)
    #expect(launchPaintingOpacity(revealProgress: 1, transitionOpacity: 0) == 0)
}
