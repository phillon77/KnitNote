public struct FamilyLaunchFrame: Sendable, Equatable {
    public let cameraZoom: Double
    public let cameraFocusX: Double
    public let cameraFocusY: Double
    public let handProgress: Double
    public let blinkProgress: Double

    public init(
        cameraZoom: Double,
        cameraFocusX: Double,
        cameraFocusY: Double,
        handProgress: Double,
        blinkProgress: Double
    ) {
        self.cameraZoom = cameraZoom
        self.cameraFocusX = cameraFocusX
        self.cameraFocusY = cameraFocusY
        self.handProgress = handProgress
        self.blinkProgress = blinkProgress
    }
}

public enum FamilyLaunchTimeline {
    public static let handsEndMilliseconds = 1_100
    public static let firstWideEndMilliseconds = 1_800
    public static let lemonEndMilliseconds = 2_800
    public static let finalWideEndMilliseconds = 3_100
    public static let localSequenceMilliseconds = finalWideEndMilliseconds

    public static let handsFocusX = 0.345
    public static let handsFocusY = 0.425
    public static let lemonFocusX = 0.665
    public static let lemonFocusY = 0.755

    public static func frame(atMilliseconds elapsed: Int) -> FamilyLaunchFrame {
        let time = min(max(elapsed, 0), localSequenceMilliseconds)
        let camera = camera(at: time)

        return FamilyLaunchFrame(
            cameraZoom: camera.zoom,
            cameraFocusX: camera.x,
            cameraFocusY: camera.y,
            handProgress: handProgress(at: time),
            blinkProgress: blinkProgress(at: time)
        )
    }

    private static func camera(at time: Int) -> (zoom: Double, x: Double, y: Double) {
        switch time {
        case ..<250:
            let progress = smooth(Double(time) / 250)
            return (
                mix(1, 2.2, progress),
                mix(0.5, handsFocusX, progress),
                mix(0.5, handsFocusY, progress)
            )
        case 250..<900:
            return (2.2, handsFocusX, handsFocusY)
        case 900..<1_100:
            let progress = smooth(Double(time - 900) / 200)
            return (
                mix(2.2, 1, progress),
                mix(handsFocusX, 0.5, progress),
                mix(handsFocusY, 0.5, progress)
            )
        case 1_100..<1_800:
            return (1, 0.5, 0.5)
        case 1_800..<2_050:
            let progress = smooth(Double(time - 1_800) / 250)
            return (
                mix(1, 2.7, progress),
                mix(0.5, lemonFocusX, progress),
                mix(0.5, lemonFocusY, progress)
            )
        case 2_050..<2_700:
            return (2.7, lemonFocusX, lemonFocusY)
        case 2_700..<2_800:
            let progress = smooth(Double(time - 2_700) / 100)
            return (
                mix(2.7, 1, progress),
                mix(lemonFocusX, 0.5, progress),
                mix(lemonFocusY, 0.5, progress)
            )
        default:
            return (1, 0.5, 0.5)
        }
    }

    private static func handProgress(at time: Int) -> Double {
        switch time {
        case 250..<450:
            return mix(0, 1, smooth(Double(time - 250) / 200))
        case 450..<650:
            return mix(1, -1, smooth(Double(time - 450) / 200))
        case 650..<850:
            return mix(-1, 1, smooth(Double(time - 650) / 200))
        case 850..<900:
            return mix(1, 0, smooth(Double(time - 850) / 50))
        default:
            return 0
        }
    }

    private static func blinkProgress(at time: Int) -> Double {
        switch time {
        case 2_250..<2_420:
            return smooth(Double(time - 2_250) / 170)
        case 2_420..<2_580:
            return 1 - smooth(Double(time - 2_420) / 160)
        default:
            return 0
        }
    }

    private static func mix(_ from: Double, _ to: Double, _ progress: Double) -> Double {
        from + ((to - from) * progress)
    }

    private static func smooth(_ progress: Double) -> Double {
        let progress = min(max(progress, 0), 1)
        return progress * progress * (3 - (2 * progress))
    }
}
