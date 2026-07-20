import Foundation
import Testing
@testable import KnitNoteCore

@Test func equalRowsOnDifferentCountersKeepIndependentNotes() throws {
    var project = try StoredProject(name: "Cable")
    let first = project.counters[0].id
    let second = project.counters[1].id
    try project.saveNote(counterID: first, row: 4, text: "left cable")
    try project.saveNote(counterID: second, row: 4, text: "right cable")
    #expect(project.note(counterID: first, row: 4)?.text == "left cable")
    #expect(project.note(counterID: second, row: 4)?.text == "right cable")
}

@Test func legacyProjectDecodingMigratesRowsAndNotesToFirstCounter() throws {
    let created = Date(timeIntervalSince1970: 10)
    let updated = Date(timeIntervalSince1970: 20)
    let note = RowNote(row: 3, text: "legacy note", createdAt: updated, updatedAt: updated)
    let migrated = try JSONDecoder().decode(
        StoredProject.self,
        from: legacyProjectData(
            name: "Legacy",
            currentRow: 8,
            rowNotes: [note],
            createdAt: created,
            updatedAt: updated
        )
    )

    #expect(migrated.counters.count == 6)
    #expect(migrated.counters.map(\.value) == [8, 0, 0, 0, 0, 0])
    #expect(migrated.counters[0].rowNotes.map(\.text) == ["legacy note"])
    let remainingNotes = migrated.counters.dropFirst().flatMap(\.rowNotes)
    #expect(remainingNotes.isEmpty)
}

@Test func decodingTheSameLegacyProjectTwiceUsesStableCounterIdentifiers() throws {
    let timestamp = Date(timeIntervalSince1970: 20)
    let note = RowNote(row: 3, text: "legacy note", createdAt: timestamp, updatedAt: timestamp)
    let legacyData = try legacyProjectData(
        name: "Legacy",
        currentRow: 8,
        rowNotes: [note],
        createdAt: Date(timeIntervalSince1970: 10),
        updatedAt: timestamp
    )

    let firstDecode = try JSONDecoder().decode(StoredProject.self, from: legacyData)
    let secondDecode = try JSONDecoder().decode(StoredProject.self, from: legacyData)

    #expect(firstDecode.counters.map(\.id) == secondDecode.counters.map(\.id))
    #expect(firstDecode.selectedCounterID == secondDecode.selectedCounterID)
    #expect(firstDecode.counters.map(\.value) == [8, 0, 0, 0, 0, 0])
    #expect(firstDecode.counters[0].rowNotes == [note])
}

@Test func migratedLegacyProjectRoundTripsWithoutChangingArchiveData() throws {
    let created = Date(timeIntervalSince1970: 10)
    let updated = Date(timeIntervalSince1970: 20)
    let note = RowNote(row: 3, text: "legacy note", createdAt: updated, updatedAt: updated)
    let pattern = PatternDocument(
        displayName: "Cable chart",
        kind: .pdf,
        storedFilename: "cable-chart.pdf",
        createdAt: created
    )
    let migrated = try JSONDecoder().decode(
        StoredProject.self,
        from: legacyProjectData(
            name: "Legacy",
            currentRow: 8,
            rowNotes: [note],
            createdAt: created,
            updatedAt: updated,
            pattern: pattern,
            photoFilename: "legacy-photo.jpg"
        )
    )
    let reloaded = try JSONDecoder().decode(
        StoredProject.self,
        from: JSONEncoder().encode(migrated)
    )

    #expect(reloaded.id == migrated.id)
    #expect(reloaded.counters == migrated.counters)
    #expect(reloaded.selectedCounterID == migrated.selectedCounterID)
    #expect(reloaded.createdAt == migrated.createdAt)
    #expect(reloaded.updatedAt == migrated.updatedAt)
    #expect(reloaded.patterns == migrated.patterns)
    #expect(reloaded.photoFilename == migrated.photoFilename)
}

@Test func oneNotePerRowAndBlankDeletes() throws {
    let start = Date(timeIntervalSince1970: 10)
    let later = Date(timeIntervalSince1970: 20)
    var project = try StoredProject(name: "Scarf", now: start)
    let counterID = project.selectedCounterID
    try project.saveNote(counterID: counterID, row: 4, text: " first ", now: start)
    try project.saveNote(counterID: counterID, row: 4, text: "updated", now: later)
    #expect(project.selectedCounter.rowNotes.count == 1)
    #expect(project.selectedCounter.rowNotes[0].text == "updated")
    #expect(project.selectedCounter.rowNotes[0].createdAt == start)
    #expect(project.selectedCounter.rowNotes[0].updatedAt == later)
    try project.saveNote(counterID: counterID, row: 4, text: "   ", now: later)
    #expect(project.selectedCounter.rowNotes.isEmpty)
}

@MainActor @Test func archiveWritesCurrentVersionAndOnlyCounterScopedNotes() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = JSONProjectStore(url: url)
    try store.add(name: "Scarf")
    let project = store.projects[0]
    try store.saveNote(
        projectID: project.id,
        counterID: project.selectedCounterID,
        row: 2,
        text: "K2tog"
    )
    let data = try Data(contentsOf: url)
    let archiveObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let projects = try #require(archiveObject["projects"] as? [[String: Any]])
    let storedProject = try #require(projects.first)
    #expect(archiveObject["version"] as? Int == 9)
    #expect(storedProject["currentRow"] == nil)
    #expect(storedProject["rowNotes"] == nil)
    #expect(JSONProjectStore(url: url).projects[0].selectedCounter.rowNotes[0].text == "K2tog")
}

private func legacyProjectData(
    name: String,
    currentRow: Int,
    rowNotes: [RowNote],
    createdAt: Date,
    updatedAt: Date,
    pattern: PatternDocument? = nil,
    photoFilename: String? = nil
) throws -> Data {
    var project = try StoredProject(name: name, now: createdAt)
    if let pattern { project.addPattern(pattern) }
    project.setPhotoFilename(photoFilename, now: updatedAt)

    var object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any]
    )
    object.removeValue(forKey: "counters")
    object.removeValue(forKey: "selectedCounterID")
    object["currentRow"] = currentRow
    object["rowNotes"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rowNotes))
    return try JSONSerialization.data(withJSONObject: object)
}
