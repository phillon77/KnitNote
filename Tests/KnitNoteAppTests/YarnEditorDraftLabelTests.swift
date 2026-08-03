import Foundation
import Testing
@testable import KnitNote

@Suite struct YarnEditorDraftLabelTests {
    private let locale = Locale(identifier: "en_US")

    @Test func confirmedSeedFillsLabelFieldsAndSuggestsBlankName() throws {
        let needle = try YarnMetricRange(lower: 3.5, upper: 4)
        let seed = YarnLabelDraftSeed(
            scanResult: YarnLabelParseResult(
                allCandidates: [
                    candidate(.series, "Belle", text: "Belle"),
                    candidate(.ballWeightGrams, "50 g", decimal: 50),
                    candidate(.recommendedNeedleMM, "3.5–4 mm", range: needle),
                ],
                fieldsRequiringConfirmation: []
            ),
            accepted: [.series, .ballWeightGrams, .recommendedNeedleMM]
        )
        var draft = YarnEditorDraft()

        draft.apply(seed, locale: locale)
        let yarn = try draft.makeYarn(locale: locale)

        #expect(yarn.name == "Belle")
        #expect(yarn.series == "Belle")
        #expect(yarn.ballWeightGrams == 50)
        #expect(yarn.recommendedNeedleMM == needle)
    }

    @Test func applyingPartialSeedDoesNotClearExistingEditValues() throws {
        var yarn = try StoredYarn(name: "Existing")
        try yarn.updateDetails(
            brand: "Old Brand",
            series: "Old Series",
            color: "Blue",
            colorCode: "12",
            dyeLot: "A1",
            storageLocation: nil,
            notes: nil
        )
        var draft = YarnEditorDraft(yarn: yarn, locale: locale)
        let seed = YarnLabelDraftSeed(
            scanResult: YarnLabelParseResult(
                allCandidates: [candidate(.brand, "New Brand", text: "New Brand")],
                fieldsRequiringConfirmation: []
            ),
            accepted: [.brand]
        )

        draft.apply(seed, locale: locale)

        #expect(draft.brand == "New Brand")
        #expect(draft.series == "Old Series")
        #expect(draft.color == "Blue")
        #expect(draft.name == "Existing")
    }

    @Test func descendingMetricRangeCannotBeSaved() {
        var draft = YarnEditorDraft()
        draft.name = "Test"
        draft.needleLowerMM.text = "5"
        draft.needleUpperMM.text = "3"

        #expect(!draft.canSave(locale: locale))
    }

    private func candidate(
        _ field: YarnLabelField,
        _ fallback: String,
        text: String? = nil,
        decimal: Decimal? = nil,
        range: YarnMetricRange? = nil
    ) -> YarnLabelCandidate {
        YarnLabelCandidate(
            field: field,
            text: text ?? fallback,
            decimalValue: decimal,
            metricRangeValue: range,
            confidence: 0.95,
            sourceImageIndex: 0
        )
    }
}
