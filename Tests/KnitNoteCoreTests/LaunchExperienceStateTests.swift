import Testing
@testable import KnitNoteCore

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
