import CoreGraphics

struct PaintingOverlayRegion: Sendable, Equatable {
    let rect: CGRect

    static let handsAndYarn = PaintingOverlayRegion(
        rect: CGRect(x: 0.30, y: 0.32, width: 0.12, height: 0.21)
    )

    static let lemonEars = PaintingOverlayRegion(
        rect: CGRect(x: 0.61, y: 0.68, width: 0.10, height: 0.17)
    )

    static let yarnBall = PaintingOverlayRegion(
        rect: CGRect(x: 0.64, y: 0.72, width: 0.17, height: 0.27)
    )

    static let lemonEyes = PaintingOverlayRegion(
        rect: CGRect(x: 0.625, y: 0.785, width: 0.052, height: 0.030)
    )

    static let lemonEyeCoverSource = PaintingOverlayRegion(
        rect: CGRect(x: 0.625, y: 0.758, width: 0.052, height: 0.030)
    )
}

struct PaintingBlinkState: Sendable, Equatable {
    let opacity: Double
    let scaleY: CGFloat

    static let resting = PaintingBlinkState(opacity: 0, scaleY: 1)

    init(phase: LaunchExperiencePhase, progress: CGFloat) {
        guard phase == .animating else {
            self = .resting
            return
        }

        let progress = min(max(progress, 0), 1)
        self.init(
            opacity: Double(progress),
            scaleY: 1 - (0.65 * progress)
        )
    }

    private init(opacity: Double, scaleY: CGFloat) {
        self.opacity = opacity
        self.scaleY = scaleY
    }
}

/// The whole-painting transition, expressed entirely in the shared
/// `KnitNoteRoot` coordinate space.
struct PaintingCompositeTransition: Sendable, Equatable {
    let scaleX: CGFloat
    let scaleY: CGFloat
    let offset: CGSize
    let opacity: Double

    init(
        phase: LaunchExperiencePhase,
        sourceFrame: CGRect,
        destinationFrame: CGRect,
        reduceMotion: Bool
    ) {
        guard phase == .enteringHome else {
            scaleX = 1
            scaleY = 1
            offset = .zero
            opacity = 1
            return
        }

        guard !reduceMotion else {
            scaleX = 1
            scaleY = 1
            offset = .zero
            opacity = 0
            return
        }

        guard sourceFrame.width > 0,
              sourceFrame.height > 0,
              destinationFrame.width > 0,
              destinationFrame.height > 0 else {
            scaleX = 1
            scaleY = 1
            offset = .zero
            opacity = 1
            return
        }

        scaleX = destinationFrame.width / sourceFrame.width
        scaleY = destinationFrame.height / sourceFrame.height
        offset = CGSize(
            width: destinationFrame.midX - sourceFrame.midX,
            height: destinationFrame.midY - sourceFrame.midY
        )
        opacity = 1
    }
}
