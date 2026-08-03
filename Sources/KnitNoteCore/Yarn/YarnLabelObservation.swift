import CoreGraphics
import Foundation

public struct YarnLabelObservation: Equatable, Sendable {
    public let text: String
    public let confidence: Float
    public let boundingBox: CGRect
    public let sourceImageIndex: Int

    public init(
        text: String,
        confidence: Float,
        boundingBox: CGRect = .zero,
        sourceImageIndex: Int
    ) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.sourceImageIndex = sourceImageIndex
    }
}

public enum YarnLabelField: String, CaseIterable, Hashable, Sendable {
    case brand
    case series
    case color
    case colorCode
    case dyeLot
    case ballWeightGrams
    case lengthMeters
    case fiberContent
    case recommendedNeedleMM
    case recommendedHookMM
}

public struct YarnLabelCandidate: Equatable, Sendable {
    public let field: YarnLabelField
    public let text: String
    public let decimalValue: Decimal?
    public let metricRangeValue: YarnMetricRange?
    public let confidence: Float
    public let sourceImageIndex: Int

    public init(
        field: YarnLabelField,
        text: String,
        decimalValue: Decimal? = nil,
        metricRangeValue: YarnMetricRange? = nil,
        confidence: Float,
        sourceImageIndex: Int
    ) {
        self.field = field
        self.text = text
        self.decimalValue = decimalValue
        self.metricRangeValue = metricRangeValue
        self.confidence = confidence
        self.sourceImageIndex = sourceImageIndex
    }
}

public struct YarnLabelParseResult: Equatable, Sendable {
    public let allCandidates: [YarnLabelCandidate]
    public let fieldsRequiringConfirmation: Set<YarnLabelField>

    public init(
        allCandidates: [YarnLabelCandidate],
        fieldsRequiringConfirmation: Set<YarnLabelField>
    ) {
        self.allCandidates = allCandidates
        self.fieldsRequiringConfirmation = fieldsRequiringConfirmation
    }

    public func candidates(for field: YarnLabelField) -> [YarnLabelCandidate] {
        allCandidates.filter { $0.field == field }
    }

    public func best(_ field: YarnLabelField) -> YarnLabelCandidate? {
        candidates(for: field).first
    }
}
