import Foundation
import Testing
@testable import KnitNoteCore

@Test func oneNotePerRowAndBlankDeletes() throws {
    let start = Date(timeIntervalSince1970: 10)
    let later = Date(timeIntervalSince1970: 20)
    var project = try StoredProject(name: "Scarf", now: start)
    try project.saveNote(row: 4, text: " first ", now: start)
    try project.saveNote(row: 4, text: "updated", now: later)
    #expect(project.rowNotes.count == 1)
    #expect(project.rowNotes[0].text == "updated")
    #expect(project.rowNotes[0].createdAt == start)
    #expect(project.rowNotes[0].updatedAt == later)
    try project.saveNote(row: 4, text: "   ", now: later)
    #expect(project.rowNotes.isEmpty)
}

@MainActor @Test func archiveWritesCurrentVersionAndReloadsNotes() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = JSONProjectStore(url: url)
    try store.add(name: "Scarf")
    let id = store.projects[0].id
    try store.saveNote(projectID: id, row: 2, text: "K2tog")
    let data = try Data(contentsOf: url)
    #expect(String(decoding: data, as: UTF8.self).contains("\"version\":4"))
    #expect(JSONProjectStore(url: url).projects[0].rowNotes[0].text == "K2tog")
}
