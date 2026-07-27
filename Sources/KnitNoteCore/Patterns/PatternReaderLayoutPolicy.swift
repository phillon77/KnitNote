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

public enum PatternHighlightGeometry {
    public static func resolvedContentRect(
        _ contentRect: CGRect?,
        canvasSize: CGSize
    ) -> CGRect {
        let fallback = CGRect(origin: .zero, size: canvasSize)
        guard let contentRect,
              contentRect.origin.x.isFinite,
              contentRect.origin.y.isFinite,
              contentRect.width.isFinite,
              contentRect.height.isFinite,
              contentRect.width > 0,
              contentRect.height > 0
        else {
            return fallback
        }
        return contentRect
    }

    public static func coordinate(
        normalized: Double,
        origin: CGFloat,
        length: CGFloat
    ) -> CGFloat {
        let clamped = min(1, max(0, normalized))
        return origin + (length * clamped)
    }

    public static func normalized(
        coordinate: CGFloat,
        origin: CGFloat,
        length: CGFloat
    ) -> Double {
        guard length.isFinite, length > 0 else { return 0.5 }
        return min(1, max(0, Double((coordinate - origin) / length)))
    }
}
