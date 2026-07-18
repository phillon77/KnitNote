public enum LaunchExperiencePhase: Sendable, Equatable {
    case revealing
    case animating
    case settling
    case enteringHome
    case complete
}

public enum LaunchExperienceTiming {
    public static let revealMilliseconds = 300
    public static let localAnimationMilliseconds = 1_400
    public static let settlingMilliseconds = 300
    public static let normalHomeTransitionMilliseconds = 600
    public static let skipHomeTransitionMilliseconds = normalHomeTransitionMilliseconds
    public static let reduceMotionHomeTransitionMilliseconds = normalHomeTransitionMilliseconds

    public static let homeTransitionSeconds =
        Double(normalHomeTransitionMilliseconds) / 1_000

    public static let normalTotalMilliseconds =
        revealMilliseconds
        + localAnimationMilliseconds
        + settlingMilliseconds
        + normalHomeTransitionMilliseconds
}

public func launchHomeIsInteractive(phase: LaunchExperiencePhase) -> Bool {
    phase == .complete
}

public struct LaunchExperienceState: Sendable, Equatable {
    public private(set) var phase: LaunchExperiencePhase = .revealing
    public let reduceMotion: Bool

    public init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
    }

    public mutating func advance() {
        switch phase {
        case .revealing:
            phase = reduceMotion ? .enteringHome : .animating
        case .animating:
            phase = .settling
        case .settling:
            phase = .enteringHome
        case .enteringHome:
            phase = .complete
        case .complete:
            break
        }
    }

    public mutating func skip() {
        guard phase != .complete else { return }
        phase = .enteringHome
    }
}
