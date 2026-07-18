import Combine
import Foundation

public protocol LaunchExperienceSleeping: Sendable {
    func sleep(milliseconds: Int) async
}

public struct SystemLaunchExperienceSleeper: LaunchExperienceSleeping {
    public init() {}

    public func sleep(milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }
}

@MainActor
public final class LaunchExperienceCoordinator: ObservableObject {
    @Published public private(set) var phase: LaunchExperiencePhase = .revealing
    @Published public private(set) var revealProgress: Double = 0

    private let sleeper: any LaunchExperienceSleeping
    private var state: LaunchExperienceState?
    private var playbackTask: Task<Void, Never>?
    private var playbackGeneration = 0
    private var didStart = false

    public init(sleeper: any LaunchExperienceSleeping = SystemLaunchExperienceSleeper()) {
        self.sleeper = sleeper
    }

    public var showsOverlay: Bool { phase != .complete }
    public var homeOpacity: Double { phase == .enteringHome || phase == .complete ? 1 : 0 }

    public func start(reduceMotion: Bool) {
        guard !didStart else { return }
        didStart = true
        state = LaunchExperienceState(reduceMotion: reduceMotion)
        phase = .revealing
        revealProgress = 0

        let generation = beginPlayback()
        let sleeper = sleeper
        playbackTask = Task { [weak self, sleeper] in
            await sleeper.sleep(milliseconds: LaunchExperienceTiming.revealKickoffMilliseconds)
            guard self?.isCurrentPlayback(generation) == true else { return }
            self?.revealProgress = 1

            await sleeper.sleep(milliseconds: LaunchExperienceTiming.revealVisualMilliseconds)
            guard self?.isCurrentPlayback(generation) == true else { return }
            self?.advance()

            if reduceMotion {
                await sleeper.sleep(
                    milliseconds: LaunchExperienceTiming.reduceMotionHomeTransitionMilliseconds
                )
                guard self?.isCurrentPlayback(generation) == true else { return }
                self?.advance()
                return
            }

            await sleeper.sleep(milliseconds: LaunchExperienceTiming.localAnimationMilliseconds)
            guard self?.isCurrentPlayback(generation) == true else { return }
            self?.advance()
            await sleeper.sleep(milliseconds: LaunchExperienceTiming.settlingMilliseconds)
            guard self?.isCurrentPlayback(generation) == true else { return }
            self?.advance()
            await sleeper.sleep(
                milliseconds: LaunchExperienceTiming.normalHomeTransitionMilliseconds
            )
            guard self?.isCurrentPlayback(generation) == true else { return }
            self?.advance()
        }
    }

    public func skip() {
        guard didStart, phase != .complete && phase != .enteringHome else { return }
        playbackTask?.cancel()
        revealProgress = 1
        state?.skip()
        publishState()

        let generation = beginPlayback()
        let sleeper = sleeper
        playbackTask = Task { [weak self, sleeper] in
            await sleeper.sleep(
                milliseconds: LaunchExperienceTiming.skipHomeTransitionMilliseconds
            )
            guard self?.isCurrentPlayback(generation) == true else { return }
            self?.advance()
        }
    }

    private func beginPlayback() -> Int {
        playbackGeneration += 1
        return playbackGeneration
    }

    private func isCurrentPlayback(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == playbackGeneration
    }

    private func advance() {
        state?.advance()
        publishState()
    }

    private func publishState() {
        if let state { phase = state.phase }
    }
}
