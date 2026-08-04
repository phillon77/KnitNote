public struct PatternListThumbnailLayout: Sendable, Equatable {
    public let width: Double
    public let height: Double
    public let minimumRowHeight: Double

    public static func resolve(for kind: PatternKind) -> Self {
        switch kind {
        case .youtube:
            return Self(width: 76, height: 43, minimumRowHeight: 43)
        case .pdf, .image:
            return Self(width: 76, height: 96, minimumRowHeight: 96)
        }
    }
}
