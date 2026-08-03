import Foundation

public struct YarnLabelDraftSeed: Equatable, Sendable {
    public let brand: String?
    public let series: String?
    public let color: String?
    public let colorCode: String?
    public let dyeLot: String?
    public let ballWeightGrams: Decimal?
    public let lengthMeters: Decimal?
    public let fiberContent: String?
    public let recommendedNeedleMM: YarnMetricRange?
    public let recommendedHookMM: YarnMetricRange?

    public init(
        scanResult: YarnLabelParseResult,
        accepted fields: Set<YarnLabelField>
    ) {
        let pairs: [(YarnLabelField, YarnLabelCandidate)] = fields.compactMap { field in
            guard !scanResult.fieldsRequiringConfirmation.contains(field),
                  let candidate = scanResult.best(field) else {
                return nil
            }
            return (field, candidate)
        }
        let selected = Dictionary(uniqueKeysWithValues: pairs)
        self.init(validatedCandidates: selected)
    }

    public init(
        scanResult: YarnLabelParseResult,
        selectedCandidates: [YarnLabelField: YarnLabelCandidate]
    ) {
        let selected = selectedCandidates.filter { field, candidate in
            candidate.field == field && scanResult.candidates(for: field).contains(candidate)
        }
        self.init(validatedCandidates: selected)
    }

    private init(validatedCandidates: [YarnLabelField: YarnLabelCandidate]) {
        brand = validatedCandidates[.brand]?.text
        series = validatedCandidates[.series]?.text
        color = validatedCandidates[.color]?.text
        colorCode = validatedCandidates[.colorCode]?.text
        dyeLot = validatedCandidates[.dyeLot]?.text
        ballWeightGrams = validatedCandidates[.ballWeightGrams]?.decimalValue
        lengthMeters = validatedCandidates[.lengthMeters]?.decimalValue
        fiberContent = validatedCandidates[.fiberContent]?.text
        recommendedNeedleMM = validatedCandidates[.recommendedNeedleMM]?.metricRangeValue
        recommendedHookMM = validatedCandidates[.recommendedHookMM]?.metricRangeValue
    }
}
