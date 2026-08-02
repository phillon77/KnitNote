import Combine
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class PatternSystemAppearanceMonitor: ObservableObject {
    typealias Resolver = PatternSystemAppearanceObservation.Resolver

    @Published private(set) var appearance: PatternSystemAppearance = .unresolved
    private let resolve: Resolver
    private lazy var observation = PatternSystemAppearanceObservation(
        resolve: resolve,
        installObservation: Self.installSystemObservation,
        publish: { [weak self] appearance in
            self?.appearance = appearance
        }
    )

    init(resolve: @escaping Resolver = PatternSystemAppearanceMonitor.resolveSystemAppearance) {
        self.resolve = resolve
    }

    func start() {
        observation.start()
    }

    func refresh() {
        observation.refresh()
    }

    func stop() {
        observation.stop()
    }

    private static func resolveSystemAppearance() -> PatternSystemAppearance {
#if os(macOS)
        let style: PatternSystemInterfaceStyle
        switch NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
        case .darkAqua:
            style = .dark
        case .aqua:
            style = .light
        default:
            style = .unspecified
        }
        return PatternSystemAppearanceResolver.appearance(for: style)
#else
        let scenes = UIApplication.shared.connectedScenes.compactMap {
            scene -> PatternSystemAppearanceScene? in
            guard let windowScene = scene as? UIWindowScene else { return nil }
            return PatternSystemAppearanceScene(
                style: interfaceStyle(
                    for: windowScene.screen.traitCollection.userInterfaceStyle
                ),
                isForegroundActive: windowScene.activationState == .foregroundActive
            )
        }
        return PatternSystemAppearanceResolver.resolve(scenes: scenes)
#endif
    }

    private static func installSystemObservation(
        _ onChange: @escaping PatternSystemAppearanceObservation.Action
    ) -> PatternSystemAppearanceObservation.Action {
#if os(macOS)
        let appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in
                onChange()
            }
        }
        return {
            appearanceObservation.invalidate()
        }
#else
        let notificationCenter = NotificationCenter.default
        let tokens = [
            UIApplication.didBecomeActiveNotification,
            UIApplication.willEnterForegroundNotification,
        ].map { name in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    onChange()
                }
            }
        }
        return {
            tokens.forEach(notificationCenter.removeObserver)
        }
#endif
    }

#if !os(macOS)
    fileprivate static func interfaceStyle(
        for style: UIUserInterfaceStyle
    ) -> PatternSystemInterfaceStyle {
        switch style {
        case .dark:
            return .dark
        case .light:
            return .light
        default:
            return .unspecified
        }
    }
#endif
}

#if !os(macOS)
struct PatternSystemAppearanceChangeProbe: UIViewRepresentable {
    let onChange: () -> Void

    func makeUIView(context: Context) -> AppearanceChangeView {
        AppearanceChangeView(onChange: onChange)
    }

    func updateUIView(_ uiView: AppearanceChangeView, context: Context) {
        uiView.onChange = onChange
    }

    final class AppearanceChangeView: UIView {
        var onChange: () -> Void

        init(onChange: @escaping () -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
                (view: AppearanceChangeView, previousTraitCollection: UITraitCollection) in
                view.notifyIfStyleChanged(
                    from: previousTraitCollection.userInterfaceStyle
                )
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func notifyIfStyleChanged(from previousStyle: UIUserInterfaceStyle) {
            let previous = PatternSystemAppearanceMonitor.interfaceStyle(for: previousStyle)
            let current = PatternSystemAppearanceMonitor.interfaceStyle(
                for: traitCollection.userInterfaceStyle
            )
            PatternSystemAppearanceChangeFilter.notifyIfChanged(
                from: previous,
                to: current,
                onChange: onChange
            )
        }
    }
}
#endif
