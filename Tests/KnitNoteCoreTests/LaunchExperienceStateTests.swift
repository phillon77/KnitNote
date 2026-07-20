import Foundation
import Testing
@testable import KnitNoteCore

@Test func rootViewImmediatelyShowsHomeWithoutInAppLaunchAnimation() throws {
    let root = try appSource("KnitNote/App/RootView.swift")
    let app = try appSource("KnitNote/App/KnitNoteApp.swift")

    #expect(!root.contains("FamilyLaunchAnimationView"))
    #expect(!root.contains("LaunchExperienceCoordinator"))
    #expect(!root.contains("launchExperience"))
    #expect(!app.contains("LaunchExperienceCoordinator"))
    #expect(!app.contains("environmentObject(launchExperience)"))
}

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

@Test func normalLaunchLastsFourSeconds() {
    #expect(LaunchExperienceTiming.normalTotalMilliseconds == 4_000)
}

@Test func homeTransitionExposesSecondsForSwiftUI() {
    #expect(LaunchExperienceTiming.homeTransitionSeconds == 0.6)
}

@Test func paintingRevealUsesTheSharedThreeHundredMillisecondTiming() {
    #expect(LaunchExperienceTiming.revealMilliseconds == 300)
    #expect(LaunchExperienceTiming.revealKickoffMilliseconds > 0)
    #expect(LaunchExperienceTiming.revealVisualMilliseconds > 0)
    #expect(
        LaunchExperienceTiming.revealKickoffMilliseconds
        + LaunchExperienceTiming.revealVisualMilliseconds
        == LaunchExperienceTiming.revealMilliseconds
    )
    #expect(LaunchExperienceTiming.revealSeconds == 0.3)
    #expect(LaunchExperienceTiming.revealVisualSeconds == 0.28)
}

@Test func paintingRevealComposesWithTheExistingHomeTransitionOpacity() {
    #expect(launchPaintingOpacity(revealProgress: 0, transitionOpacity: 1) == 0)
    #expect(launchPaintingOpacity(revealProgress: 0.5, transitionOpacity: 1) == 0.5)
    #expect(launchPaintingOpacity(revealProgress: 1, transitionOpacity: 1) == 1)
    #expect(launchPaintingOpacity(revealProgress: 0.5, transitionOpacity: 0.5) == 0.25)
    #expect(launchPaintingOpacity(revealProgress: 1, transitionOpacity: 0) == 0)
}

@Test func paintingRevealAnimationIsScopedInsideTheGeometryTransition() throws {
    let source = try launchAnimationSource()

    let revealStart = try #require(source.range(of: "private func revealedPainting("))
    let revealEnd = try #require(
        source.range(of: "private func layeredPainting(", range: revealStart.upperBound..<source.endIndex)
    )
    let revealScope = source[revealStart.lowerBound..<revealEnd.lowerBound]

    #expect(revealScope.contains(".opacity("))
    #expect(revealScope.contains("value: revealProgress"))
    #expect(!revealScope.contains(".scaleEffect("))
    #expect(!revealScope.contains(".position("))

    let bodyBeforeRevealHelper = source[..<revealStart.lowerBound]
    #expect(bodyBeforeRevealHelper.contains("revealedPainting("))
    #expect(bodyBeforeRevealHelper.contains(".scaleEffect("))
    #expect(bodyBeforeRevealHelper.contains(".position("))
    #expect(bodyBeforeRevealHelper.contains("value: phase"))
}

@Test func launchViewSamplesTheTimelineEveryAnimationFrame() throws {
    let source = try launchAnimationSource()
    #expect(source.contains("TimelineView(.animation"))
    #expect(source.contains("FamilyLaunchTimeline.frame(atMilliseconds:"))
    #expect(source.contains("cameraTransform(frame:"))
    #expect(!source.contains("blinkProgress = 1"))
}

@Test func launchCannotRegressToWholeImageOnlyMotion() throws {
    let source = try launchAnimationSource()
    #expect(source.contains("featheredHandsMask"))
    #expect(source.contains("originalPixelOverlay(region: .handsAndYarn"))
    #expect(source.contains("sourceRegion: .lemonEyeCoverSource"))
    #expect(source.contains("motion.eyeScaleY"))
}

@Test func lemonEyeMaskTargetsTheFaceInsteadOfTheEarLine() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: repositoryRoot
            .appendingPathComponent("KnitNote/Launch/PaintingOverlayRegion.swift"),
        encoding: .utf8
    )
    #expect(source.contains("rect: CGRect(x: 0.625, y: 0.785"))
    #expect(source.contains("rect: CGRect(x: 0.625, y: 0.758"))
}

private func launchAnimationSource() throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: repositoryRoot
            .appendingPathComponent("KnitNote/Launch/FamilyLaunchAnimationView.swift"),
        encoding: .utf8
    )
}

private func appSource(_ relativePath: String) throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: repositoryRoot.appendingPathComponent(relativePath),
        encoding: .utf8
    )
}
