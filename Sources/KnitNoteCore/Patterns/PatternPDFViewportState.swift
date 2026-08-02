import CoreGraphics

public struct PatternPDFViewportState: Equatable, Sendable {
    public var pageIndex: Int
    public var pageFrame: CGRect?
    public var scaleFactor: CGFloat
    public var fitWidthScaleFactor: CGFloat
    public var isUserInteracting: Bool

    public init(
        pageIndex: Int = 0,
        pageFrame: CGRect? = nil,
        scaleFactor: CGFloat = 1,
        fitWidthScaleFactor: CGFloat = 1,
        isUserInteracting: Bool = false
    ) {
        self.pageIndex = max(0, pageIndex)
        self.pageFrame = Self.validFrame(pageFrame)
        self.scaleFactor = Self.validScale(scaleFactor)
        self.fitWidthScaleFactor = Self.validScale(fitWidthScaleFactor)
        self.isUserInteracting = isUserInteracting
    }

    private static func validFrame(_ frame: CGRect?) -> CGRect? {
        guard let frame,
              frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0
        else { return nil }
        return frame
    }

    private static func validScale(_ value: CGFloat) -> CGFloat {
        value.isFinite && value > 0 ? value : 1
    }
}

public struct PatternPDFViewportPublicationGate: Sendable {
    private var lastAccepted: PatternPDFViewportState?

    public init() {}

    public mutating func accept(_ candidate: PatternPDFViewportState) -> Bool {
        guard candidate != lastAccepted else { return false }
        lastAccepted = candidate
        return true
    }

    public mutating func reset() {
        lastAccepted = nil
    }
}
