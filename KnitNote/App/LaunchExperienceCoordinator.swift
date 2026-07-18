import SwiftUI

@MainActor
final class LaunchExperienceCoordinator: ObservableObject {
    @Published private(set) var phase: LaunchExperiencePhase = .revealing
    private var state: LaunchExperienceState?
    private var playbackTask: Task<Void, Never>?
    private var didStart = false

    var showsOverlay: Bool { phase != .complete }
    var homeOpacity: Double { phase == .enteringHome || phase == .complete ? 1 : 0 }

    func start(reduceMotion: Bool) {
        guard !didStart else { return }
        didStart = true
        state = LaunchExperienceState(reduceMotion: reduceMotion)
        phase = .revealing
        playbackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(LaunchExperienceTiming.revealMilliseconds))
            guard !Task.isCancelled else { return }
            self?.advance()
            if reduceMotion {
                try? await Task.sleep(for: .milliseconds(LaunchExperienceTiming.reduceMotionHomeTransitionMilliseconds))
                guard !Task.isCancelled else { return }
                self?.advance()
                return
            }
            try? await Task.sleep(for: .milliseconds(LaunchExperienceTiming.localAnimationMilliseconds))
            guard !Task.isCancelled else { return }
            self?.advance()
            try? await Task.sleep(for: .milliseconds(LaunchExperienceTiming.settlingMilliseconds))
            guard !Task.isCancelled else { return }
            self?.advance()
            try? await Task.sleep(for: .milliseconds(LaunchExperienceTiming.normalHomeTransitionMilliseconds))
            guard !Task.isCancelled else { return }
            self?.advance()
        }
    }

    func skip() {
        guard didStart, phase != .complete && phase != .enteringHome else { return }
        playbackTask?.cancel()
        state?.skip()
        publishState()
        playbackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(LaunchExperienceTiming.skipHomeTransitionMilliseconds))
            guard !Task.isCancelled else { return }
            self?.advance()
        }
    }

    private func advance() {
        state?.advance()
        publishState()
    }

    private func publishState() {
        if let state { phase = state.phase }
    }
}
