import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct YarnLabelDraftSeedTests {
    @Test func acceptedUniqueCandidatesProduceDraftSeedWithoutSaving() throws {
        let needleRange = try YarnMetricRange(lower: 3.5, upper: 4)
        let result = YarnLabelParseResult(
            allCandidates: [
                Self.candidate(.brand, "DROPS"),
                Self.candidate(.series, "BELLE"),
                Self.candidate(.colorCode, "12"),
                Self.candidate(.ballWeightGrams, "50", decimal: 50),
                Self.candidate(.recommendedNeedleMM, "3.5–4 mm", range: needleRange),
            ],
            fieldsRequiringConfirmation: []
        )

        let seed = YarnLabelDraftSeed(
            scanResult: result,
            accepted: [.brand, .series, .colorCode, .ballWeightGrams, .recommendedNeedleMM]
        )

        #expect(seed.brand == "DROPS")
        #expect(seed.series == "BELLE")
        #expect(seed.colorCode == "12")
        #expect(seed.ballWeightGrams == 50)
        #expect(seed.recommendedNeedleMM == needleRange)
        #expect(seed.color == nil)
    }

    @Test func unacceptedCandidatesRemainEmpty() {
        let result = YarnLabelParseResult(
            allCandidates: [Self.candidate(.brand, "DROPS"), Self.candidate(.series, "BELLE")],
            fieldsRequiringConfirmation: []
        )

        let seed = YarnLabelDraftSeed(scanResult: result, accepted: [.brand])

        #expect(seed.brand == "DROPS")
        #expect(seed.series == nil)
    }

    @Test func ambiguousFieldRequiresTheReviewedCandidateInsteadOfImplicitBest() {
        let first = Self.candidate(.colorCode, "12", confidence: 0.96, sourceImageIndex: 0)
        let second = Self.candidate(.colorCode, "13", confidence: 0.94, sourceImageIndex: 1)
        let result = YarnLabelParseResult(
            allCandidates: [first, second],
            fieldsRequiringConfirmation: [.colorCode]
        )

        let implicit = YarnLabelDraftSeed(scanResult: result, accepted: [.colorCode])
        let reviewed = YarnLabelDraftSeed(scanResult: result, selectedCandidates: [.colorCode: second])

        #expect(implicit.colorCode == nil)
        #expect(reviewed.colorCode == "13")
    }

    private static func candidate(
        _ field: YarnLabelField,
        _ text: String,
        decimal: Decimal? = nil,
        range: YarnMetricRange? = nil,
        confidence: Float = 0.95,
        sourceImageIndex: Int = 0
    ) -> YarnLabelCandidate {
        YarnLabelCandidate(
            field: field,
            text: text,
            decimalValue: decimal,
            metricRangeValue: range,
            confidence: confidence,
            sourceImageIndex: sourceImageIndex
        )
    }
}
