import Foundation

public struct YarnLabelCandidateReviewState: Equatable, Sendable {
    public static let automaticSelectionConfidence: Float = 0.8

    public let scanResult: YarnLabelParseResult
    private var selections: [YarnLabelField: YarnLabelCandidate]

    public init(scanResult: YarnLabelParseResult) {
        self.scanResult = scanResult
        selections = Dictionary(uniqueKeysWithValues: YarnLabelField.allCases.compactMap { field in
            let candidates = scanResult.candidates(for: field)
            guard candidates.count == 1,
                  !scanResult.fieldsRequiringConfirmation.contains(field),
                  let candidate = candidates.first,
                  candidate.confidence >= Self.automaticSelectionConfidence else {
                return nil
            }
            return (field, candidate)
        })
    }

    public func selectedCandidate(for field: YarnLabelField) -> YarnLabelCandidate? {
        selections[field]
    }

    @discardableResult
    public mutating func select(
        _ candidate: YarnLabelCandidate,
        for field: YarnLabelField
    ) -> Bool {
        guard candidate.field == field,
              scanResult.candidates(for: field).contains(candidate) else {
            return false
        }
        selections[field] = candidate
        return true
    }

    public mutating func clearSelection(for field: YarnLabelField) {
        selections[field] = nil
    }

    public var draftSeed: YarnLabelDraftSeed {
        YarnLabelDraftSeed(scanResult: scanResult, selectedCandidates: selections)
    }
}
