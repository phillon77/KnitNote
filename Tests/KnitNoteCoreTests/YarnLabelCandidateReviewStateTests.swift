import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct YarnLabelCandidateReviewStateTests {
    @Test func preselectsOnlyUniqueHighConfidenceCandidates() {
        let brand = Self.candidate(.brand, "Drops", confidence: 0.92)
        let ambiguousColor = Self.candidate(.color, "Rose", confidence: 0.95)
        let lowConfidenceSeries = Self.candidate(.series, "Belle", confidence: 0.62)
        let result = YarnLabelParseResult(
            allCandidates: [brand, ambiguousColor, lowConfidenceSeries],
            fieldsRequiringConfirmation: [.color]
        )

        let state = YarnLabelCandidateReviewState(scanResult: result)

        #expect(state.selectedCandidate(for: .brand) == brand)
        #expect(state.selectedCandidate(for: .color) == nil)
        #expect(state.selectedCandidate(for: .series) == nil)
    }

    @Test func selectingCandidateProducesReviewedSeed() {
        let first = Self.candidate(.colorCode, "12", confidence: 0.88)
        let second = Self.candidate(.colorCode, "17", confidence: 0.83, sourceImageIndex: 1)
        let result = YarnLabelParseResult(
            allCandidates: [first, second],
            fieldsRequiringConfirmation: [.colorCode]
        )
        var state = YarnLabelCandidateReviewState(scanResult: result)

        let didSelect = state.select(second, for: .colorCode)
        #expect(didSelect)
        #expect(state.draftSeed.colorCode == "17")
    }

    @Test func rejectsCandidateThatDoesNotBelongToFieldOrScan() {
        let recognized = Self.candidate(.brand, "Drops", confidence: 0.94)
        let unrelated = Self.candidate(.series, "Belle", confidence: 0.91)
        let result = YarnLabelParseResult(
            allCandidates: [recognized],
            fieldsRequiringConfirmation: []
        )
        var state = YarnLabelCandidateReviewState(scanResult: result)

        let didSelect = state.select(unrelated, for: .brand)
        #expect(!didSelect)
        #expect(state.selectedCandidate(for: .brand) == recognized)
    }

    @Test func clearingSelectionLeavesThatFieldEmpty() {
        let brand = Self.candidate(.brand, "Drops", confidence: 0.96)
        let result = YarnLabelParseResult(
            allCandidates: [brand],
            fieldsRequiringConfirmation: []
        )
        var state = YarnLabelCandidateReviewState(scanResult: result)

        state.clearSelection(for: .brand)

        #expect(state.selectedCandidate(for: .brand) == nil)
        #expect(state.draftSeed.brand == nil)
    }

    private static func candidate(
        _ field: YarnLabelField,
        _ text: String,
        confidence: Float,
        sourceImageIndex: Int = 0
    ) -> YarnLabelCandidate {
        YarnLabelCandidate(
            field: field,
            text: text,
            confidence: confidence,
            sourceImageIndex: sourceImageIndex
        )
    }
}
