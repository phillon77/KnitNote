import Testing
@testable import KnitNoteCore

private actor ManualLaunchSleeper: LaunchExperienceSleeping {
    private struct Waiter {
        let milliseconds: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var waiters: [Waiter] = []

    func sleep(milliseconds: Int) async {
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(milliseconds: milliseconds, continuation: continuation))
        }
    }

    func pendingDurations() -> [Int] {
        waiters.map(\.milliseconds)
    }

    func resumeNext() {
        waiters.removeFirst().continuation.resume()
    }
}

@MainActor
private func waitForPendingSleep(
    _ sleeper: ManualLaunchSleeper,
    count: Int = 1
) async {
    for _ in 0..<100 {
        if await sleeper.pendingDurations().count == count { return }
        await Task.yield()
    }
}

@MainActor
private func resumeNext(_ sleeper: ManualLaunchSleeper) async {
    await sleeper.resumeNext()
    await Task.yield()
}

@Test @MainActor
func repeatedStartIsIgnoredForTheColdLaunchLifetime() async {
    let sleeper = ManualLaunchSleeper()
    let coordinator = LaunchExperienceCoordinator(sleeper: sleeper)

    coordinator.start(reduceMotion: false)
    coordinator.start(reduceMotion: true)
    await waitForPendingSleep(sleeper)

    #expect(await sleeper.pendingDurations() == [LaunchExperienceTiming.revealKickoffMilliseconds])
    #expect(coordinator.phase == .revealing)
}

@Test @MainActor
func normalPlaybackPublishesRevealAndVisitsEveryTimedPhase() async {
    let sleeper = ManualLaunchSleeper()
    let coordinator = LaunchExperienceCoordinator(sleeper: sleeper)
    coordinator.start(reduceMotion: false)

    await waitForPendingSleep(sleeper)
    #expect(coordinator.revealProgress == 0)
    await resumeNext(sleeper)
    await waitForPendingSleep(sleeper)
    #expect(coordinator.revealProgress == 1)
    #expect(coordinator.phase == .revealing)

    await resumeNext(sleeper)
    await waitForPendingSleep(sleeper)
    #expect(coordinator.phase == .animating)
    await resumeNext(sleeper)
    await waitForPendingSleep(sleeper)
    #expect(coordinator.phase == .settling)
    await resumeNext(sleeper)
    await waitForPendingSleep(sleeper)
    #expect(coordinator.phase == .enteringHome)
    await resumeNext(sleeper)
    #expect(coordinator.phase == .complete)
    #expect(!coordinator.showsOverlay)
}

@Test @MainActor
func reduceMotionSkipsLocalAnimationAndSettling() async {
    let sleeper = ManualLaunchSleeper()
    let coordinator = LaunchExperienceCoordinator(sleeper: sleeper)
    coordinator.start(reduceMotion: true)

    await waitForPendingSleep(sleeper)
    await resumeNext(sleeper)
    await waitForPendingSleep(sleeper)
    await resumeNext(sleeper)
    await waitForPendingSleep(sleeper)
    #expect(coordinator.phase == .enteringHome)
    #expect(await sleeper.pendingDurations() == [LaunchExperienceTiming.reduceMotionHomeTransitionMilliseconds])
    await resumeNext(sleeper)
    #expect(coordinator.phase == .complete)
}

@Test @MainActor
func skipCancelsPlaybackAndStaleWakeupsCannotMoveThePhaseBackward() async {
    let sleeper = ManualLaunchSleeper()
    let coordinator = LaunchExperienceCoordinator(sleeper: sleeper)
    coordinator.start(reduceMotion: false)
    await waitForPendingSleep(sleeper)

    coordinator.skip()
    #expect(coordinator.phase == .enteringHome)
    #expect(coordinator.revealProgress == 1)
    await waitForPendingSleep(sleeper, count: 2)

    await resumeNext(sleeper) // Wake the cancelled reveal task.
    #expect(coordinator.phase == .enteringHome)
    #expect(coordinator.revealProgress == 1)
    await resumeNext(sleeper) // Finish the skip transition.
    #expect(coordinator.phase == .complete)
    coordinator.skip()
    #expect(coordinator.phase == .complete)
}

@Test @MainActor
func skipAfterRevealPreservesPublishedRevealWithoutCompletingTwice() async {
    let sleeper = ManualLaunchSleeper()
    let coordinator = LaunchExperienceCoordinator(sleeper: sleeper)
    coordinator.start(reduceMotion: false)
    await waitForPendingSleep(sleeper)
    await resumeNext(sleeper)
    await waitForPendingSleep(sleeper)
    #expect(coordinator.revealProgress == 1)

    coordinator.skip()
    #expect(coordinator.phase == .enteringHome)
    #expect(coordinator.revealProgress == 1)
    await waitForPendingSleep(sleeper, count: 2)
    await resumeNext(sleeper) // Old reveal-visual sleep.
    #expect(coordinator.phase == .enteringHome)
    await resumeNext(sleeper) // Skip transition.
    #expect(coordinator.phase == .complete)
    #expect(coordinator.revealProgress == 1)
}
