import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct StoredYarnTests {
    @Test func nameIsTheOnlyRequiredField() throws {
        let yarn = try StoredYarn(name: "  Merino  ")
        #expect(yarn.name == "Merino")
        #expect(yarn.remainingBalls == nil)
        #expect(yarn.remainingGrams == nil)
        #expect(yarn.linkedProjectIDs.isEmpty)
    }

    @Test func inventoryAcceptsIndependentDecimalsAndRejectsNegatives() throws {
        var yarn = try StoredYarn(name: "Merino")
        try yarn.updateInventory(balls: Decimal(string: "2.5"), grams: 86)
        #expect(yarn.remainingBalls == Decimal(string: "2.5"))
        #expect(yarn.remainingGrams == 86)
        #expect(throws: YarnValidationError.negativeInventory) {
            try yarn.updateInventory(balls: -1, grams: nil)
        }
    }

    @Test func yarnRoundTripPreservesDetailsAndLinks() throws {
        let projectIDs = [UUID(), UUID()]
        var yarn = try StoredYarn(name: "Cotton")
        try yarn.updateDetails(brand: "Brand", series: "Summer", color: "Blue", colorCode: "B12", dyeLot: "L7", storageLocation: "Box A", notes: "Soft")
        yarn.setLinkedProjectIDs(Set(projectIDs))
        let decoded = try JSONDecoder().decode(StoredYarn.self, from: JSONEncoder().encode(yarn))
        #expect(decoded == yarn)
    }

    @Test func partialArchiveRecordDefaultsLinksAndNormalizesStrings() throws {
        let yarn = try StoredYarn(name: "Placeholder")
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(yarn)) as? [String: Any]
        )
        object["name"] = "  Merino  "
        object["photoFilename"] = "  yarn.jpg  "
        object["brand"] = "  "
        object["series"] = "  Cloud  "
        object.removeValue(forKey: "color")
        object.removeValue(forKey: "linkedProjectIDs")

        let decoded = try JSONDecoder().decode(
            StoredYarn.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.name == "Merino")
        #expect(decoded.photoFilename == "yarn.jpg")
        #expect(decoded.brand == nil)
        #expect(decoded.series == "Cloud")
        #expect(decoded.color == nil)
        #expect(decoded.linkedProjectIDs.isEmpty)
    }

    @Test func archiveRecordWithBlankNameIsRejected() throws {
        let yarn = try StoredYarn(name: "Merino")
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(yarn)) as? [String: Any]
        )
        object["name"] = "   "

        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(StoredYarn.self, from: data)
        }
    }

    @Test(arguments: ["remainingBalls", "remainingGrams"])
    func archiveRecordWithNegativeInventoryIsRejected(key: String) throws {
        let yarn = try StoredYarn(name: "Merino")
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(yarn)) as? [String: Any]
        )
        object[key] = -0.01

        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(StoredYarn.self, from: data)
        }
    }

    @Test(arguments: [
        "0.1234567890123456",
        "1234567890123456.5",
        "0.12345678901234567890123456789012345678",
    ])
    func untouchedEditorInventoryPreservesEveryDecimalDigit(source: String) throws {
        let original = try #require(Decimal(string: source))
        let locale = Locale(identifier: "de_DE")
        let editValue = YarnInventoryEditValue(value: original, locale: locale)

        #expect(editValue.text == source.replacingOccurrences(of: ".", with: ","))
        #expect(editValue.input(locale: locale) == .value(original))
        #expect(editValue.resolvedValue(locale: locale) == original)
    }

    @Test func editingAnUnrelatedFieldDoesNotChangeHighPrecisionInventory() throws {
        let balls = try #require(Decimal(string: "0.1234567890123456"))
        let grams = try #require(Decimal(string: "1234567890123456.5"))
        let locale = Locale(identifier: "fr_FR")
        var yarn = try StoredYarn(name: "Merino")
        try yarn.updateInventory(balls: balls, grams: grams)
        let ballsEditValue = YarnInventoryEditValue(value: balls, locale: locale)
        let gramsEditValue = YarnInventoryEditValue(value: grams, locale: locale)

        try yarn.rename(to: "Edited Merino")
        try yarn.updateInventory(
            balls: ballsEditValue.resolvedValue(locale: locale),
            grams: gramsEditValue.resolvedValue(locale: locale)
        )

        #expect(yarn.remainingBalls == balls)
        #expect(yarn.remainingGrams == grams)
    }

    @Test func changedEditorInventoryUsesTheRegionDecimalSeparatorStrictly() {
        let locale = Locale(identifier: "de_DE")
        var editValue = YarnInventoryEditValue()
        editValue.text = "1,5"

        #expect(editValue.input(locale: locale) == .value(Decimal(string: "1.5")!))
        editValue.text = "1.5"
        #expect(editValue.input(locale: locale) == .invalid)
        editValue.text = "1,5 trailing"
        #expect(editValue.input(locale: locale) == .invalid)
    }
}
