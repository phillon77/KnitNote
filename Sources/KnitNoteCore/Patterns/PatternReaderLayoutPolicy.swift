import CoreGraphics

public enum PatternPDFScaleMode: Sendable, Equatable {
    case automatic
    case fitWidth
}

public enum PatternPageControlPlacement: Sendable, Equatable {
    case overlay
    case reservedBelow
}

public struct PatternReaderLayoutPolicy: Sendable, Equatable {
    public let pdfScaleMode: PatternPDFScaleMode
    public let pageControlPlacement: PatternPageControlPlacement

    public init(
        pdfScaleMode: PatternPDFScaleMode,
        pageControlPlacement: PatternPageControlPlacement
    ) {
        self.pdfScaleMode = pdfScaleMode
        self.pageControlPlacement = pageControlPlacement
    }

    public static func resolve(isPad: Bool, width: Double, height: Double) -> Self {
        guard isPad else {
            return .init(pdfScaleMode: .automatic, pageControlPlacement: .overlay)
        }
        if width > height {
            return .init(pdfScaleMode: .fitWidth, pageControlPlacement: .overlay)
        }
        return .init(pdfScaleMode: .automatic, pageControlPlacement: .reservedBelow)
    }
}

public enum PatternHighlightMetrics {
    public static let horizontalVisibleThickness: CGFloat = 22
    public static let verticalVisibleThickness: CGFloat = 3
    public static let minimumDragThickness: CGFloat = 44
}
