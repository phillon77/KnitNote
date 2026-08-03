import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct StoredYarnLabelFieldsTests {
    @Test func oldYarnDecodesWithEmptyLabelDetails() throws {
        let original = try StoredYarn(name: "Legacy yarn")
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
        )
        object.removeValue(forKey: "ballWeightGrams")
        object.removeValue(forKey: "lengthMeters")
        object.removeValue(forKey: "fiberContent")
        object.removeValue(forKey: "recommendedNeedleMM")
        object.removeValue(forKey: "recommendedHookMM")
        object.removeValue(forKey: "labelPhotoFilenames")

        let yarn = try JSONDecoder().decode(
            StoredYarn.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(yarn.ballWeightGrams == nil)
        #expect(yarn.lengthMeters == nil)
        #expect(yarn.fiberContent == nil)
        #expect(yarn.recommendedNeedleMM == nil)
        #expect(yarn.recommendedHookMM == nil)
        #expect(yarn.labelPhotoFilenames.isEmpty)
    }

    @Test func metricRangeRejectsNegativeOrDescendingValues() {
        #expect(throws: YarnValidationError.invalidMetricRange) {
            try YarnMetricRange(lower: 5, upper: 4)
        }
        #expect(throws: YarnValidationError.invalidMetricRange) {
            try YarnMetricRange(lower: -1, upper: 2)
        }
    }

    @Test func labelDetailsNormalizeAndRoundTrip() throws {
        var yarn = try StoredYarn(name: "Merino")
        try yarn.updateLabelDetails(
            ballWeightGrams: 50,
            lengthMeters: 120,
            fiberContent: "  100% wool  ",
            recommendedNeedleMM: try YarnMetricRange(lower: 3.5, upper: 4),
            recommendedHookMM: try YarnMetricRange(lower: 4, upper: 4)
        )

        let decoded = try JSONDecoder().decode(
            StoredYarn.self,
            from: JSONEncoder().encode(yarn)
        )

        #expect(decoded == yarn)
        #expect(decoded.fiberContent == "100% wool")
        #expect(decoded.ballWeightGrams == 50)
        #expect(decoded.lengthMeters == 120)
    }

    @Test func labelDetailsRejectNegativeMeasurements() throws {
        var yarn = try StoredYarn(name: "Merino")
        #expect(throws: YarnValidationError.negativeLabelMeasurement) {
            try yarn.updateLabelDetails(
                ballWeightGrams: -1,
                lengthMeters: nil,
                fiberContent: nil,
                recommendedNeedleMM: nil,
                recommendedHookMM: nil
            )
        }
    }

    @Test func labelPhotoFilenamesBelongToYarnAndUseTwoUniqueOrdinals() throws {
        var yarn = try StoredYarn(name: "Merino")
        let first = "\(yarn.id.uuidString)-label-1-\(UUID().uuidString).jpg"
        let second = "\(yarn.id.uuidString)-label-2-\(UUID().uuidString).jpg"

        try yarn.setLabelPhotoFilenames([first, second])
        #expect(yarn.labelPhotoFilenames == [first, second])

        #expect(throws: YarnValidationError.invalidLabelPhotoFilenames) {
            try yarn.setLabelPhotoFilenames([first, second, first])
        }
        #expect(throws: YarnValidationError.invalidLabelPhotoFilenames) {
            try yarn.setLabelPhotoFilenames(["../outside.jpg"])
        }
    }
}
