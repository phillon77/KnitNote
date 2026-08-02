import Combine
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class PatternSystemAppearanceMonitor: ObservableObject {
    typealias Resolver = @MainActor () -> PatternSystemAppearance

    @Published private(set) var appearance: PatternSystemAppearance = .unresolved
    private let resolve: Resolver
    private var notificationTokens: [NSObjectProtocol] = []
#if os(macOS)
    private var appearanceObservation: NSKeyValueObservation?
#endif

    init(resolve: @escaping Resolver = PatternSystemAppearanceMonitor.resolveSystemAppearance) {
        self.resolve = resolve
    }

    func start() {
#if os(macOS)
        guard appearanceObservation == nil else { refresh(); return }
#else
        guard notificationTokens.isEmpty else { refresh(); return }
#endif
        refresh()

#if os(macOS)
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
#else
        let notificationCenter = NotificationCenter.default
        notificationTokens = [
            UIApplication.didBecomeActiveNotification,
            UIApplication.willEnterForegroundNotification,
        ].map { name in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
        }
#endif
    }

    func refresh() {
        appearance = resolve()
    }

    func stop() {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
#if os(macOS)
        appearanceObservation = nil
#endif
    }

    private static func resolveSystemAppearance() -> PatternSystemAppearance {
#if os(macOS)
        switch NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
        case .darkAqua:
            return .dark
        case .aqua:
            return .light
        default:
            return .unresolved
        }
#else
        let windowScenes = UIApplication.shared.connectedScenes.compactMap {
            $0 as? UIWindowScene
        }
        guard let scene = windowScenes.first(where: {
            $0.activationState == .foregroundActive
        }) ?? windowScenes.first else {
            return .unresolved
        }

        switch scene.screen.traitCollection.userInterfaceStyle {
        case .dark:
            return .dark
        case .light:
            return .light
        default:
            return .unresolved
        }
#endif
    }
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
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func traitCollectionDidChange(
            _ previousTraitCollection: UITraitCollection?
        ) {
            let previousStyle = previousTraitCollection?.userInterfaceStyle
            super.traitCollectionDidChange(previousTraitCollection)
            guard previousStyle != nil,
                  previousStyle != traitCollection.userInterfaceStyle else {
                return
            }
            onChange()
        }
    }
}
#endif
