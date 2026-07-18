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
        rect: CGRect(x: 0.63, y: 0.738, width: 0.05, height: 0.024)
    )

    static let lemonEyeCoverSource = PaintingOverlayRegion(
        rect: CGRect(x: 0.63, y: 0.714, width: 0.05, height: 0.024)
    )
}

struct PaintingOverlayMotion: Sendable, Equatable {
    let handsOffset: CGSize
    let handsRotationDegrees: CGFloat
    let yarnRotationDegrees: CGFloat
    let earsOffset: CGSize
    let earsRotationDegrees: CGFloat
    let blinkOpacity: Double
    let blinkScaleY: CGFloat

    static let resting = PaintingOverlayMotion(
        handsOffset: .zero,
        handsRotationDegrees: 0,
        yarnRotationDegrees: 0,
        earsOffset: .zero,
        earsRotationDegrees: 0,
        blinkOpacity: 0,
        blinkScaleY: 1
    )

    init(
        phase: LaunchExperiencePhase,
        motionProgress: CGFloat,
        blinkProgress: CGFloat
    ) {
        guard phase == .animating else {
            self = .resting
            return
        }

        let motionProgress = min(max(motionProgress, 0), 1)
        let blinkProgress = min(max(blinkProgress, 0), 1)
        self.init(
            handsOffset: CGSize(width: 0, height: -0.45 * motionProgress),
            handsRotationDegrees: 0.18 * motionProgress,
            yarnRotationDegrees: -0.18 * motionProgress,
            earsOffset: CGSize(width: 0, height: -0.25 * motionProgress),
            earsRotationDegrees: 0.15 * motionProgress,
            blinkOpacity: Double(blinkProgress),
            blinkScaleY: 1 - (0.65 * blinkProgress)
        )
    }

    private init(
        handsOffset: CGSize,
        handsRotationDegrees: CGFloat,
        yarnRotationDegrees: CGFloat,
        earsOffset: CGSize,
        earsRotationDegrees: CGFloat,
        blinkOpacity: Double,
        blinkScaleY: CGFloat
    ) {
        self.handsOffset = handsOffset
        self.handsRotationDegrees = handsRotationDegrees
        self.yarnRotationDegrees = yarnRotationDegrees
        self.earsOffset = earsOffset
        self.earsRotationDegrees = earsRotationDegrees
        self.blinkOpacity = blinkOpacity
        self.blinkScaleY = blinkScaleY
    }
}
