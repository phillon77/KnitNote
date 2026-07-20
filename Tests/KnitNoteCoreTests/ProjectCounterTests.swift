import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct ProjectCounterTests {
    @Test func newProjectHasSixIndependentCounters() throws {
        var project = try StoredProject(name: "Sweater")
        #expect(project.counters.count == 6)
        #expect(project.counters.map(\.defaultOrdinal) == Array(1...6))

        let second = project.counters[1].id
        project.incrementCounter(id: second)
        #expect(project.counters[0].value == 0)
        #expect(project.counters[1].value == 1)
        project.decrementCounter(id: second)
        project.decrementCounter(id: second)
        #expect(project.counters[1].value == 0)
    }

    @Test func aCounterCanBeResetWithoutChangingTheOtherCounters() throws {
        var project = try StoredProject(name: "Cardigan")
        let first = project.counters[0].id
        let second = project.counters[1].id
        project.incrementCounter(id: first)
        project.incrementCounter(id: first)
        project.incrementCounter(id: second)

        project.resetCounter(id: first)

        #expect(project.counters[0].value == 0)
        #expect(project.counters[1].value == 1)
    }

    @Test func counterManagementSavesNameAndValueTogether() throws {
        var project = try StoredProject(name: "Cardigan")
        let first = project.counters[0].id
        project.incrementCounter(id: first)
        project.incrementCounter(id: first)

        project.updateCounter(id: first, name: "Body repeat", value: 1)

        #expect(project.counters[0].customName == "Body repeat")
        #expect(project.counters[0].value == 1)
    }

    @Test func completedProjectLocksCountersUntilResumed() throws {
        let completed = Date(timeIntervalSince1970: 100)
        let resumed = Date(timeIntervalSince1970: 200)
        var project = try StoredProject(name: "Cardigan")
        let counterID = project.counters[0].id
        project.incrementCounter(id: counterID, now: Date(timeIntervalSince1970: 50))

        project.markCompleted(at: completed)
        project.incrementCounter(id: counterID, now: resumed)
        project.decrementCounter(id: counterID)
        project.resetCounter(id: counterID)
        project.updateCounter(id: counterID, name: "Changed", value: 9)

        #expect(project.isCompleted)
        #expect(project.completedAt == completed)
        #expect(project.counters[0].value == 1)
        #expect(project.counters[0].customName == nil)

        project.resume(at: resumed)
        project.incrementCounter(id: counterID, now: resumed)
        #expect(!project.isCompleted)
        #expect(project.completedAt == nil)
        #expect(project.counters[0].value == 2)
        #expect(project.updatedAt == resumed)
    }

    @Test func completionStateSurvivesCodableAndLegacyDataDefaultsToActive() throws {
        let completed = Date(timeIntervalSince1970: 100)
        var project = try StoredProject(name: "Cardigan")
        project.markCompleted(at: completed)
        let data = try JSONEncoder().encode(project)
        #expect(try JSONDecoder().decode(StoredProject.self, from: data).completedAt == completed)

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "completedAt")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(StoredProject.self, from: legacy).completedAt == nil)
    }

    @Test func counterMutationsSelectAndRenameWithoutChangingAnUnchangedProject() throws {
        let start = Date(timeIntervalSince1970: 10)
        let later = Date(timeIntervalSince1970: 20)
        var project = try StoredProject(name: "Sweater", now: start)
        let second = project.counters[1].id

        project.selectCounter(id: second)
        #expect(project.selectedCounterID == second)
        #expect(project.selectedCounter.id == second)

        project.renameCounter(id: second, to: "  Sleeves  ", now: later)
        #expect(project.counters[1].customName == "Sleeves")
        #expect(project.updatedAt == later)
        project.renameCounter(id: second, to: "   ", now: later)
        #expect(project.counters[1].customName == nil)
        project.renameCounter(id: second, to: "", now: later.addingTimeInterval(10))
        project.selectCounter(id: second, now: later.addingTimeInterval(10))
        #expect(project.updatedAt == later)
    }

    @Test func renamingAProjectToItsNormalizedCurrentNameKeepsItsTimestamp() throws {
        let start = Date(timeIntervalSince1970: 10)
        let later = Date(timeIntervalSince1970: 20)
        var project = try StoredProject(name: "Sweater", now: start)

        try project.rename(to: "  Sweater  ", now: later)

        #expect(project.updatedAt == start)
    }

    @Test func selectingACounterUpdatesTheSelectedCounterUsedByExplicitAPIs() throws {
        var project = try StoredProject(name: "Sweater")
        let first = project.counters[0].id
        let second = project.counters[1].id

        project.selectCounter(id: second)
        project.incrementCounter(id: second)
        try project.saveNote(counterID: second, row: 4, text: "sleeve repeat")
        project.renameCounter(id: second, to: "Sleeve")

        #expect(project.selectedCounter.value == 1)
        #expect(project.note(counterID: second, row: 4)?.text == "sleeve repeat")
        #expect(project.selectedCounter.rowNotes.count == 1)

        project.selectCounter(id: first)
        #expect(project.selectedCounter.value == 0)
        #expect(project.selectedCounter.rowNotes.isEmpty)
    }

    @Test func counterCodableNormalizesMalformedArraysToSixUniqueSlots() throws {
        let duplicate = UUID()
        let note = RowNote(
            row: 4,
            text: "preserve me",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let malformed = [
            ProjectCounter(id: duplicate, defaultOrdinal: 7, value: 3),
            ProjectCounter(id: duplicate, defaultOrdinal: 1, value: 9),
            ProjectCounter(
                id: duplicate,
                defaultOrdinal: 2,
                customName: "Sleeve",
                value: 4,
                rowNotes: [note]
            ),
        ]
        let project = try StoredProject(name: "Hat")
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any]
        )
        object["counters"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(malformed))
        object["selectedCounterID"] = duplicate.uuidString
        let malformedData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(
            StoredProject.self,
            from: malformedData
        )
        let decodedAgain = try JSONDecoder().decode(
            StoredProject.self,
            from: malformedData
        )

        #expect(decoded.counters.count == 6)
        #expect(decoded.counters.map(\.defaultOrdinal) == Array(1...6))
        #expect(Set(decoded.counters.map(\.id)).count == 6)
        #expect(decoded.counters.map(\.id) == decodedAgain.counters.map(\.id))
        #expect(decoded.counters[0].value == 9)
        #expect(decoded.counters[1].customName == "Sleeve")
        #expect(decoded.counters[1].value == 4)
        #expect(decoded.counters[1].rowNotes == [note])
        #expect(decoded.selectedCounterID == decoded.counters[0].id)
        #expect(decodedAgain.selectedCounterID == decoded.selectedCounterID)
    }

    @Test func selectedCounterRemainsDirectlyAccessibleAfterDecodingAnInvalidID() throws {
        let project = try StoredProject(name: "Hat")
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any]
        )
        object["selectedCounterID"] = UUID().uuidString

        let decoded = try JSONDecoder().decode(
            StoredProject.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.selectedCounter.id == decoded.counters[0].id)
        #expect(decoded.selectedCounter.value == 0)
    }

    @Test func directCounterDecodingNormalizesNegativeValuesAndBlankNames() throws {
        let counter = ProjectCounter(defaultOrdinal: 2, customName: "Sleeves", value: 5)
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(counter)) as? [String: Any]
        )
        object["customName"] = "  \n \t "
        object["value"] = -1

        let decoded = try JSONDecoder().decode(
            ProjectCounter.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.customName == nil)
        #expect(decoded.value == 0)
    }

    @Test func counterGridLayoutUsesExactPhoneAndPadColumnCounts() {
        #expect(
            CounterGridLayoutPolicy.columnCount(
                availableWidth: 256,
                deviceClass: .phone
            ) == 2
        )
        #expect(
            CounterGridLayoutPolicy.columnCount(
                availableWidth: 326,
                deviceClass: .phone
            ) == 2
        )
        #expect(
            CounterGridLayoutPolicy.columnCount(
                availableWidth: 500,
                deviceClass: .pad
            ) == 3
        )
        #expect(
            CounterGridLayoutPolicy.columnCount(
                availableWidth: 704,
                deviceClass: .pad
            ) == 3
        )
        #expect(
            CounterGridLayoutPolicy.columnCount(
                availableWidth: 779,
                deviceClass: .pad
            ) == 3
        )
        #expect(
            CounterGridLayoutPolicy.columnCount(
                availableWidth: 780,
                deviceClass: .pad
            ) == 6
        )
        #expect(
            CounterGridLayoutPolicy.columnCount(
                availableWidth: 960,
                deviceClass: .pad
            ) == 6
        )
    }

    @Test func counterActionTouchTargetsRejectEitherDimensionBelowFortyFourPoints() {
        #expect(
            CounterActionControlPolicy.hasPracticalTouchTarget(width: 44, height: 44)
        )
        #expect(
            !CounterActionControlPolicy.hasPracticalTouchTarget(width: 43.9, height: 44)
        )
        #expect(
            !CounterActionControlPolicy.hasPracticalTouchTarget(width: 44, height: 43.9)
        )
    }

    @Test func counterAccessibilityActionLabelsIncludePurposeIdentityAndCurrentValue() {
        let english = CounterAccessibilityPolicy.actionLabel(
            format: "Increase %@, current value %lld",
            counterName: "Sleeve",
            currentValue: 12,
            locale: Locale(identifier: "en")
        )
        let traditionalChinese = CounterAccessibilityPolicy.actionLabel(
            format: "減少 %@，目前數值 %lld",
            counterName: "袖子",
            currentValue: 12,
            locale: Locale(identifier: "zh-Hant")
        )

        #expect(english == "Increase Sleeve, current value 12")
        #expect(traditionalChinese == "減少 袖子，目前數值 12")
    }

    @Test func completingRowAdvancesCount() {
        var project = KnittingProject(name: "米色圍巾")
        project.completeRow()
        #expect(project.currentRow == 1)
    }

    @Test func undoNeverProducesNegativeCount() {
        var project = KnittingProject(name: "Scarf")
        project.undoRow()
        #expect(project.currentRow == 0)
    }

    @Test func userNameSurvivesLanguageIndependentChanges() {
        var project = KnittingProject(name: "My 圍巾")
        project.completeRow()
        #expect(project.name == "My 圍巾")
    }
}
