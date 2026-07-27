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
        return validContentRect(contentRect) ?? fallback
    }

    public static func centerInset(contentRect: CGRect?) -> CGFloat {
        validContentRect(contentRect) == nil
            ? PatternHighlightMetrics.minimumDragThickness / 2
            : 0
    }

    public static func coordinate(
        normalized: Double,
        origin: CGFloat,
        length: CGFloat,
        centerInset: CGFloat = 0
    ) -> CGFloat {
        let clamped = min(1, max(0, normalized))
        let inset = resolvedCenterInset(centerInset, length: length)
        let effectiveLength = max(0, length - (inset * 2))
        return origin + inset + (effectiveLength * clamped)
    }

    public static func normalized(
        coordinate: CGFloat,
        origin: CGFloat,
        length: CGFloat,
        centerInset: CGFloat = 0
    ) -> Double {
        guard length.isFinite, length > 0 else { return 0.5 }
        let inset = resolvedCenterInset(centerInset, length: length)
        let effectiveLength = length - (inset * 2)
        guard effectiveLength > 0 else { return 0.5 }
        return min(1, max(
            0,
            Double((coordinate - origin - inset) / effectiveLength)
        ))
    }

    private static func validContentRect(_ contentRect: CGRect?) -> CGRect? {
        guard let contentRect,
              contentRect.origin.x.isFinite,
              contentRect.origin.y.isFinite,
              contentRect.width.isFinite,
              contentRect.height.isFinite,
              contentRect.width > 0,
              contentRect.height > 0
        else {
            return nil
        }
        return contentRect
    }

    private static func resolvedCenterInset(
        _ centerInset: CGFloat,
        length: CGFloat
    ) -> CGFloat {
        guard centerInset.isFinite, length.isFinite, length > 0 else { return 0 }
        return min(max(0, centerInset), length / 2)
    }
}

public enum PatternPDFPageFrameGeometry {
    public static func flippedFrame(_ frame: CGRect, in bounds: CGRect) -> CGRect {
        var result = frame
        result.origin.y = bounds.maxY - frame.maxY
        return result
    }
}
