import enum StoreKit.AppStore
import SwiftUI
import UIKit

enum RatingEligibility {
    static func shouldRequest(
        validCount: Int,
        attemptVersion: String?,
        currentVersion: String
    ) -> Bool {
        validCount >= 5 && attemptVersion != currentVersion
    }
}

struct RatingRequestSceneObserver: UIViewRepresentable {
    let onWindowSceneChange: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> RatingRequestSceneView {
        RatingRequestSceneView(onWindowSceneChange: onWindowSceneChange)
    }

    func updateUIView(_ uiView: RatingRequestSceneView, context: Context) {
        uiView.onWindowSceneChange = onWindowSceneChange
        uiView.reportWindowSceneIfAvailable()
    }
}

final class RatingRequestSceneView: UIView {
    var onWindowSceneChange: (UIWindowScene) -> Void

    init(onWindowSceneChange: @escaping (UIWindowScene) -> Void) {
        self.onWindowSceneChange = onWindowSceneChange
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportWindowSceneIfAvailable()
    }

    func reportWindowSceneIfAvailable() {
        guard let windowScene = window?.windowScene else { return }
        onWindowSceneChange(windowScene)
    }
}

@MainActor
final class RatingRequestContext: ObservableObject {
    private weak var windowScene: UIWindowScene?

    func update(windowScene: UIWindowScene) {
        self.windowScene = windowScene
    }

    func considerRequest(using coordinator: RatingRequestCoordinator) {
        guard let windowScene else { return }
        coordinator.considerRequest(in: windowScene)
    }
}

@MainActor
final class RatingRequestCoordinator: ObservableObject {
    private let preferences: CalculatorPreferencesStore
    private let versionProvider: () -> String
    private let reviewRequester: (UIWindowScene) -> Void

    init(
        preferences: CalculatorPreferencesStore,
        versionProvider: @escaping () -> String = {
            Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "0"
        },
        reviewRequester: @escaping (UIWindowScene) -> Void = { scene in
            AppStore.requestReview(in: scene)
        }
    ) {
        self.preferences = preferences
        self.versionProvider = versionProvider
        self.reviewRequester = reviewRequester
    }

    func considerRequest(in scene: UIWindowScene) {
        considerRequest(currentVersion: versionProvider()) {
            reviewRequester(scene)
        }
    }

    func considerRequest(
        currentVersion: String,
        requestReview: () -> Void
    ) {
        guard RatingEligibility.shouldRequest(
            validCount: preferences.validCalculationCount,
            attemptVersion: preferences.ratingAttemptVersion,
            currentVersion: currentVersion
        ) else {
            return
        }
        preferences.markRatingAttempt(version: currentVersion)
        requestReview()
    }
}
