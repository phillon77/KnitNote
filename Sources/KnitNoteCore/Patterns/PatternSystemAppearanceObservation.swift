public enum PatternSystemInterfaceStyle: Equatable, Sendable {
    case unspecified
    case light
    case dark
}

public struct PatternSystemAppearanceScene: Equatable, Sendable {
    public let style: PatternSystemInterfaceStyle
    public let isForegroundActive: Bool

    public init(style: PatternSystemInterfaceStyle, isForegroundActive: Bool) {
        self.style = style
        self.isForegroundActive = isForegroundActive
    }
}

public enum PatternSystemAppearanceResolver: Sendable {
    public static func appearance(
        for style: PatternSystemInterfaceStyle
    ) -> PatternSystemAppearance {
        switch style {
        case .unspecified:
            return .unresolved
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    public static func resolve(
        scenes: [PatternSystemAppearanceScene]
    ) -> PatternSystemAppearance {
        guard let scene = scenes.first(where: \.isForegroundActive) ?? scenes.first else {
            return .unresolved
        }
        return appearance(for: scene.style)
    }

}

public enum PatternSystemAppearanceChangeFilter: Sendable {
    @MainActor
    public static func notifyIfChanged(
        from previous: PatternSystemInterfaceStyle,
        to current: PatternSystemInterfaceStyle,
        onChange: () -> Void
    ) {
        guard previous != current else { return }
        onChange()
    }
}

@MainActor
public final class PatternSystemAppearanceObservation {
    public typealias Resolver = @MainActor () -> PatternSystemAppearance
    public typealias Action = @MainActor () -> Void
    public typealias Installer = @MainActor (
        _ onChange: @escaping Action
    ) -> Action
    public typealias Publisher = @MainActor (PatternSystemAppearance) -> Void

    public private(set) var appearance: PatternSystemAppearance = .unresolved

    private let resolve: Resolver
    private let installObservation: Installer
    private let publish: Publisher
    private var isStarted = false
    private var removeObservation: Action?

    public init(
        resolve: @escaping Resolver,
        installObservation: @escaping Installer,
        publish: @escaping Publisher
    ) {
        self.resolve = resolve
        self.installObservation = installObservation
        self.publish = publish
    }

    public func start() {
        guard !isStarted else {
            refresh()
            return
        }

        isStarted = true
        removeObservation = installObservation { [weak self] in
            guard let self, self.isStarted else { return }
            self.refresh()
        }
        refresh()
    }

    public func refresh() {
        appearance = resolve()
        publish(appearance)
    }

    public func stop() {
        guard isStarted else { return }
        isStarted = false
        let removeObservation = removeObservation
        self.removeObservation = nil
        removeObservation?()
    }
}
