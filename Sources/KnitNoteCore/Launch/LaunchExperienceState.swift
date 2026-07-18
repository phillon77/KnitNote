public enum LaunchExperiencePhase: Sendable, Equatable {
    case revealing
    case animating
    case settling
    case enteringHome
    case complete
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
