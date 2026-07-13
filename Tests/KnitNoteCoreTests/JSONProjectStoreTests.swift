import Foundation
import Testing
@testable import KnitNoteCore

@MainActor @Test func persistsProjectsAcrossStoreInstances() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let first = JSONProjectStore(url: url)
    try first.add(name: "  圍巾  ")
    let id = first.projects[0].id
    try first.completeRow(id: id)
    try first.rename(id: id, to: "新圍巾")
    let second = JSONProjectStore(url: url)
    #expect(second.projects[0].name == "新圍巾")
    #expect(second.projects[0].currentRow == 1)
    try second.delete(id: id)
    #expect(JSONProjectStore(url: url).projects.isEmpty)
}
