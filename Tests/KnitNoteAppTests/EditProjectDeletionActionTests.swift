import Foundation
import Testing
@testable import KnitNote

@MainActor
@Test func completedProjectRequiresResumeBeforeEditorDeletion() throws {
    var project = try StoredProject(name: "Finished cardigan")
    project.markCompleted(at: Date(timeIntervalSince1970: 1_000))

    #expect(ProjectDeletionAvailability(project: project) == .requiresResume)
}

@MainActor
@Test func inProgressProjectAllowsEditorDeletion() throws {
    let project = try StoredProject(name: "Cardigan")

    #expect(ProjectDeletionAvailability(project: project) == .allowed)
}

@MainActor
@Test func projectEditorDeletionRemovesTheProjectBeforeLeavingTheEditor() throws {
    let archiveURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("EditProjectDeletion-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: archiveURL) }
    let store = JSONProjectStore(url: archiveURL)
    try store.add(name: "Test")
    let projectID = try #require(store.projects.first?.id)
    var didLeaveEditor = false

    try EditProjectDeletionAction.perform(
        projectID: projectID,
        store: store,
        onDeleted: { didLeaveEditor = true }
    )

    #expect(store.project(id: projectID) == nil)
    #expect(didLeaveEditor)
}
