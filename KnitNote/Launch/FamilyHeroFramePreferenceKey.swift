import SwiftUI

struct FamilyHeroFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty {
            value = next
        }
    }
}

enum FamilyHeroDestination {
    private static let paintingAspectRatio: CGFloat = 2560.0 / 1440.0
    private static let emergencyFallback = CGRect(
        x: 16,
        y: 16,
        width: 288,
        height: 162
    )

    static func resolved(liveFrame: CGRect, containerSize: CGSize) -> CGRect {
        guard !isValid(liveFrame) else { return liveFrame }
        return fallback(in: containerSize)
    }

    static func isValid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
            && frame.width > 0
            && frame.height > 0
    }

    private static func fallback(in containerSize: CGSize) -> CGRect {
        guard containerSize.width.isFinite,
              containerSize.height.isFinite,
              containerSize.width > 0,
              containerSize.height > 0 else {
            return emergencyFallback
        }

        let topThird = CGRect(
            origin: .zero,
            size: CGSize(
                width: containerSize.width,
                height: containerSize.height / 3
            )
        )
        let inset = min(
            16,
            topThird.width / 4,
            topThird.height / 4
        )
        let available = topThird.insetBy(dx: inset, dy: inset)
        let width = min(
            available.width,
            available.height * paintingAspectRatio
        )
        let height = width / paintingAspectRatio

        return CGRect(
            x: topThird.midX - (width / 2),
            y: topThird.midY - (height / 2),
            width: width,
            height: height
        )
    }
}
