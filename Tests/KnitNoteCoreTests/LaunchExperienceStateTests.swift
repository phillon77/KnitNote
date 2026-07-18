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
