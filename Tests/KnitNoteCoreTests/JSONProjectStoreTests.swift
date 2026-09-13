import CoreGraphics
import Dispatch
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KnitNoteCore

private enum DirectCounterManagerArchiveWriteError: Error {
    case failed
}

private final class DirectCounterManagerArchiveWriteGate: @unchecked Sendable {
    var shouldFail = false
}

@MainActor @Test func persistsProjectsAcrossStoreInstances() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let first = JSONProjectStore(url: url)
    try first.add(name: "  圍巾  ")
    let project = first.projects[0]
    try first.incrementCounter(projectID: project.id, counterID: project.selectedCounterID)
    try first.rename(id: project.id, to: "新圍巾")
    let second = JSONProjectStore(url: url)
    #expect(second.projects[0].name == "新圍巾")
    #expect(second.projects[0].selectedCounter.value == 1)
    try second.delete(id: project.id)
    #expect(JSONProjectStore(url: url).projects.isEmpty)
}

@MainActor @Test func storePersistsSixCounterMutationsAndNotes() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = JSONProjectStore(url: url)
    try store.add(name: "Cardigan")
    let project = try #require(store.projects.first)
    let counterID = project.counters[2].id

    try store.selectCounter(projectID: project.id, counterID: counterID)
    try store.renameCounter(projectID: project.id, counterID: counterID, name: "Sleeve A")
    try store.incrementCounter(projectID: project.id, counterID: counterID)
    try store.saveNote(projectID: project.id, counterID: counterID, row: 1, text: "increase")

    let reloaded = try #require(JSONProjectStore(url: url).projects.first)
    #expect(reloaded.selectedCounterID == counterID)
    #expect(reloaded.selectedCounter.customName == "Sleeve A")
    #expect(reloaded.selectedCounter.value == 1)
    #expect(reloaded.note(counterID: counterID, row: 1)?.text == "increase")
}

@MainActor @Test func storePersistsCounterDecrementAndNoteDeletion() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = JSONProjectStore(url: url)
    try store.add(name: "Beanie")
    let project = try #require(store.projects.first)
    let counterID = project.counters[4].id

    try store.incrementCounter(projectID: project.id, counterID: counterID)
    try store.decrementCounter(projectID: project.id, counterID: counterID)
    try store.saveNote(projectID: project.id, counterID: counterID, row: 4, text: "remove")
    try store.deleteNote(projectID: project.id, counterID: counterID, row: 4)

    let reloaded = try #require(JSONProjectStore(url: url).projects.first)
    #expect(reloaded.counters[4].value == 0)
    #expect(reloaded.note(counterID: counterID, row: 4) == nil)
}

@MainActor @Test func storePersistsReminderConfigurationCompletionAndStop() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = JSONProjectStore(url: url)
    try store.add(name: "Cardigan")
    let project = try #require(store.projects.first)
    let counterID = project.counters[0].id
    try store.configureCounterReminder(
        projectID: project.id,
        counterID: counterID,
        draft: .repeating(interval: 2, limit: nil, message: "Turn")
    )

    let persisted = try store.updateCounter(
        projectID: project.id,
        counterID: counterID,
        name: nil,
        value: 5
    )
    let mutation = try #require(persisted)
    let reminder = try #require(store.project(id: project.id)?.knittingReminders.first)
    let pending = reminder.progress.pending
    #expect(mutation.counter == store.project(id: project.id)?.counters[0])
    try store.completeCounterReminder(
        projectID: project.id,
        counterID: counterID,
        reminderID: reminder.id,
        observedCount: pending.count
    )

    let completed = try #require(JSONProjectStore(url: url).project(id: project.id)?.knittingReminders.first)
    #expect(completed.progress.pending.isEmpty)
    #expect(completed.progress.completedCount == 2)
    try store.stopCounterReminder(
        projectID: project.id,
        counterID: counterID,
        reminderID: reminder.id
    )

    let stopped = try #require(JSONProjectStore(url: url).project(id: project.id)?.knittingReminders.first)
    #expect(stopped.state == .stopped)
    #expect(stopped.progress.nextTarget == nil)
}

@MainActor @Test func directCounterManagerPersistsNameValueAndReminderInOneMutation() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = JSONProjectStore(url: url)
    try store.add(name: "Cardigan")
    let project = try #require(store.projects.first)
    let counterID = project.counters[0].id

    let result = try store.manageCounter(
        projectID: project.id,
        counterID: counterID,
        name: "Body",
        value: 7,
        reminder: .replace(.repeating(interval: 3, limit: 2, message: "Turn"))
    )

    let mutation = try #require(result)
    let reopened = try #require(JSONProjectStore(url: url).project(id: project.id)?.counters[0])
    #expect(mutation.counter == reopened)
    #expect(reopened.customName == "Body")
    #expect(reopened.value == 7)
    let reminder = try #require(JSONProjectStore(url: url).project(id: project.id)?.knittingReminders.first)
    #expect(reminder.rule == .repeating(firstTarget: 10, interval: 3, limit: 2))
    #expect(reminder.text == "Turn")
}

@MainActor @Test func staleDirectReminderRemovalRejectsTheWholeManagerTransaction() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = JSONProjectStore(url: url)
    try store.add(name: "Cardigan")
    let project = try #require(store.projects.first)
    let counterID = project.counters[0].id
    try store.configureCounterReminder(
        projectID: project.id,
        counterID: counterID,
        draft: .oneTime(target: 3, message: "First")
    )
    let staleReminder = try #require(
        store.project(id: project.id)?.knittingReminders.first
    )
    try store.deleteKnittingReminder(
        projectID: project.id,
        reminderID: staleReminder.id,
        observedRevision: staleReminder.mutationRevision
    )
    try store.configureCounterReminder(
        projectID: project.id,
        counterID: counterID,
        draft: .oneTime(target: 4, message: "Replacement")
    )
    let replacementReminder = try #require(
        store.project(id: project.id)?.knittingReminders.first
    )
    #expect(replacementReminder.id != staleReminder.id)
    #expect(replacementReminder.text == "Replacement")
    let unrelatedReminderID = try store.addKnittingReminder(
        projectID: project.id,
        draft: .oneTime(kind: .measure, target: 6, text: "Unrelated")
    )
    let selectedCounterID = project.counters[1].id
    try store.selectCounter(projectID: project.id, counterID: selectedCounterID)
    let projectsBefore = store.projects
    let projectBefore = try #require(store.project(id: project.id))
    let remindersBefore = projectBefore.knittingReminders
    #expect(remindersBefore.map(\.id) == [replacementReminder.id, unrelatedReminderID])
    #expect(!remindersBefore.contains(where: { $0.id == staleReminder.id }))
    let selectionBefore = projectBefore.selectedCounterID
    #expect(selectionBefore == selectedCounterID)
    let generationBefore = store.dataGeneration
    let archiveBefore = try Data(contentsOf: url)

    let result = try store.manageCounter(
        projectID: project.id,
        counterID: counterID,
        name: "Changed",
        value: 2,
        reminder: .remove(expectedReminderID: staleReminder.id)
    )

    #expect(result == nil)
    #expect(store.projects == projectsBefore)
    let projectAfter = try #require(store.project(id: project.id))
    #expect(projectAfter.selectedCounterID == selectionBefore)
    #expect(store.dataGeneration == generationBefore)
    #expect(try Data(contentsOf: url) == archiveBefore)
    #expect(projectAfter.counters[0].customName == nil)
    #expect(projectAfter.counters[0].value == 0)
    #expect(projectAfter.knittingReminders == remindersBefore)
    #expect(projectAfter.knittingReminders.map(\.id) == [replacementReminder.id, unrelatedReminderID])
    #expect(JSONProjectStore(url: url).project(id: project.id) == projectBefore)
}

@MainActor @Test func rejectedDirectCounterManagerMutationPublishesNothing() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = JSONProjectStore(url: url)
    try store.add(name: "Cardigan")
    let project = try #require(store.projects.first)
    try store.markCompleted(projectID: project.id)
    let projectsBefore = store.projects
    let generationBefore = store.dataGeneration
    let archiveBefore = try Data(contentsOf: url)

    let result = try store.manageCounter(
        projectID: project.id,
        counterID: project.counters[0].id,
        name: "Changed",
        value: 9,
        reminder: .replace(.oneTime(target: 10, message: nil))
    )

    #expect(result == nil)
    #expect(store.projects == projectsBefore)
    #expect(store.dataGeneration == generationBefore)
    #expect(try Data(contentsOf: url) == archiveBefore)
}

@MainActor @Test func failedDirectCounterManagerMutationPublishesNothing() throws {
    let gate = DirectCounterManagerArchiveWriteGate()
    let harness = try PatternImportHarness(archiveWrite: { data, destination in
        if gate.shouldFail { throw DirectCounterManagerArchiveWriteError.failed }
        try data.write(to: destination, options: .atomic)
    })
    try harness.store.add(name: "Cardigan")
    let project = try #require(harness.store.projects.first)
    let projectsBefore = harness.store.projects
    let generationBefore = harness.store.dataGeneration
    let archiveBefore = try Data(contentsOf: harness.archiveURL)
    gate.shouldFail = true

    #expect(throws: ProjectStoreError.persistenceFailed) {
        try harness.store.manageCounter(
            projectID: project.id,
            counterID: project.counters[0].id,
            name: "Changed",
            value: 9,
            reminder: .replace(.oneTime(target: 10, message: nil))
        )
    }

    #expect(harness.store.projects == projectsBefore)
    #expect(harness.store.dataGeneration == generationBefore)
    #expect(try Data(contentsOf: harness.archiveURL) == archiveBefore)
}

@MainActor @Test func rejectedDirectReminderOperationsPublishNothing() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = JSONProjectStore(url: url)
    try store.add(name: "Cardigan")
    let project = try #require(store.projects.first)
    let counterID = project.counters[0].id
    try store.configureCounterReminder(
        projectID: project.id,
        counterID: counterID,
        draft: .oneTime(target: 2, message: nil)
    )
    _ = try store.updateCounter(
        projectID: project.id,
        counterID: counterID,
        name: nil,
        value: 2
    )
    let reminder = try #require(store.project(id: project.id)?.knittingReminders.first)
    let pending = reminder.progress.pending
    let rejectedOperations: [() throws -> Void] = [
        {
            try store.configureCounterReminder(
                projectID: project.id,
                counterID: UUID(),
                draft: .oneTime(target: 3, message: nil)
            )
        },
        {
            try store.completeCounterReminder(
                projectID: project.id,
                counterID: counterID,
                reminderID: reminder.id,
                observedCount: pending.count + 1
            )
        },
        {
            try store.stopCounterReminder(
                projectID: project.id,
                counterID: counterID,
                reminderID: UUID()
            )
        },
    ]

    for operation in rejectedOperations {
        let projectsBefore = store.projects
        let generationBefore = store.dataGeneration
        let archiveBefore = try Data(contentsOf: url)

        try operation()

        #expect(store.projects == projectsBefore)
        #expect(store.project(id: project.id)?.selectedCounterID == project.selectedCounterID)
        #expect(store.dataGeneration == generationBefore)
        #expect(try Data(contentsOf: url) == archiveBefore)
    }
}

@MainActor @Test func completedProjectRejectsDirectReminderOperationsWithoutPublishing() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = JSONProjectStore(url: url)
    try store.add(name: "Cardigan")
    let project = try #require(store.projects.first)
    let counterID = project.counters[0].id
    try store.configureCounterReminder(
        projectID: project.id,
        counterID: counterID,
        draft: .oneTime(target: 1, message: nil)
    )
    _ = try store.updateCounter(
        projectID: project.id,
        counterID: counterID,
        name: nil,
        value: 1
    )
    let reminder = try #require(store.project(id: project.id)?.knittingReminders.first)
    let pending = reminder.progress.pending
    try store.markCompleted(projectID: project.id)
    let operations: [() throws -> Void] = [
        {
            try store.configureCounterReminder(
                projectID: project.id,
                counterID: counterID,
                draft: .oneTime(target: 2, message: nil)
            )
        },
        {
            try store.completeCounterReminder(
                projectID: project.id,
                counterID: counterID,
                reminderID: reminder.id,
                observedCount: pending.count
            )
        },
        {
            try store.stopCounterReminder(
                projectID: project.id,
                counterID: counterID,
                reminderID: reminder.id
            )
        },
    ]

    for operation in operations {
        let projectsBefore = store.projects
        let generationBefore = store.dataGeneration
        let archiveBefore = try Data(contentsOf: url)

        #expect(throws: PatternLibraryMutationError.projectCompleted) {
            try operation()
        }
        #expect(store.projects == projectsBefore)
        #expect(store.dataGeneration == generationBefore)
        #expect(try Data(contentsOf: url) == archiveBefore)
    }
}

@MainActor @Test func storePersistsCompletionAndResume() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = JSONProjectStore(url: url)
    try store.add(name: "Cardigan")
    let projectID = try #require(store.projects.first?.id)

    try store.markCompleted(projectID: projectID)
    #expect(JSONProjectStore(url: url).project(id: projectID)?.isCompleted == true)

    try store.resumeProject(projectID: projectID)
    #expect(JSONProjectStore(url: url).project(id: projectID)?.isCompleted == false)
}

@MainActor
@Test func completedProjectDeletionIsRejectedWithoutChangingStoredData() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CompletedDeletion-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = JSONProjectStore(url: url)
    try store.add(name: "Finished cardigan")
    let projectID = try #require(store.projects.first?.id)
    try store.markCompleted(projectID: projectID)
    let archiveBefore = try Data(contentsOf: url)

    #expect(throws: ProjectDeletionError.projectCompleted) {
        try store.delete(id: projectID)
    }

    #expect(store.project(id: projectID)?.isCompleted == true)
    #expect(try Data(contentsOf: url) == archiveBefore)
}

@MainActor
@Test func resumedProjectCanBeDeleted() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ResumedDeletion-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = JSONProjectStore(url: url)
    try store.add(name: "Finished cardigan")
    let projectID = try #require(store.projects.first?.id)
    try store.markCompleted(projectID: projectID)
    try store.resumeProject(projectID: projectID)

    try store.delete(id: projectID)

    #expect(store.project(id: projectID) == nil)
    #expect(JSONProjectStore(url: url).project(id: projectID) == nil)
}

@MainActor @Test func legacyArchiveLoadsWithEmptyYarnLibrary() throws {
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let projectData = try JSONEncoder().encode(try StoredProject(name: "Scarf"))
    let projectJSON = try #require(String(data: projectData, encoding: .utf8))
    let fixture = Data("{\"version\":7,\"projects\":[\(projectJSON)]}".utf8)
    try fixture.write(to: storeURL, options: .atomic)

    let store = JSONProjectStore(url: storeURL)

    #expect(store.projects.count == 1)
    #expect(store.yarns.isEmpty)
}

@MainActor @Test func malformedYarnArchiveReportsLoadFailureAndCannotBeOverwritten() throws {
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = try StoredProject(name: "Scarf")
    let yarn = try StoredYarn(name: "Merino")
    var yarnObject = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(yarn)) as? [String: Any]
    )
    yarnObject["remainingBalls"] = -1
    let projectObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project))
    let fixture = try JSONSerialization.data(withJSONObject: [
        "version": 8,
        "projects": [projectObject],
        "yarns": [yarnObject],
    ])
    try fixture.write(to: storeURL, options: .atomic)

    let store = JSONProjectStore(url: storeURL)

    #expect(store.loadError == .unreadableArchive)
    #expect(store.projects.isEmpty)
    #expect(store.yarns.isEmpty)
    #expect(throws: ProjectStoreError.archiveUnavailable) {
        try store.add(name: "Must not replace the archive")
    }
    #expect(try Data(contentsOf: storeURL) == fixture)
}

@MainActor @Test func partialYarnArchiveLoadsWithoutHidingItsValidProject() throws {
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = try StoredProject(name: "Scarf")
    let yarn = try StoredYarn(name: "Placeholder")
    var yarnObject = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(yarn)) as? [String: Any]
    )
    yarnObject["name"] = "  Merino  "
    yarnObject.removeValue(forKey: "linkedProjectIDs")
    let projectObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project))
    let fixture = try JSONSerialization.data(withJSONObject: [
        "version": 8,
        "projects": [projectObject],
        "yarns": [yarnObject],
    ])
    try fixture.write(to: storeURL, options: .atomic)

    let store = JSONProjectStore(url: storeURL)

    #expect(store.loadError == nil)
    #expect(store.projects.map(\.id) == [project.id])
    #expect(store.yarns.map(\.name) == ["Merino"])
    #expect(store.yarns.first?.linkedProjectIDs.isEmpty == true)
}

@MainActor @Test func missingArchiveIsAValidEmptyStore() {
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    let store = JSONProjectStore(url: storeURL)

    #expect(store.loadError == nil)
    #expect(store.projects.isEmpty)
    #expect(store.yarns.isEmpty)
}

@MainActor @Test func unreadableArchiveCanBeRetriedAfterItsBytesAreRestored() throws {
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("not JSON".utf8).write(to: storeURL, options: .atomic)
    let store = JSONProjectStore(url: storeURL)
    #expect(store.loadError == .unreadableArchive)
    let project = try StoredProject(name: "Restored scarf")
    let archive = ProjectArchive(version: 8, projects: [project], yarns: [])
    try JSONEncoder().encode(archive).write(to: storeURL, options: .atomic)

    store.retryLoad()

    #expect(store.loadError == nil)
    #expect(store.projects.map(\.id) == [project.id])
}

@MainActor @Test func unreadableArchiveIsRejectedBeforeCreatingAYarnPhotoCandidate() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let storeURL = base.appendingPathComponent("projects.json")
    let photosURL = base.appendingPathComponent("yarn-photos")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try Data("not JSON".utf8).write(to: storeURL, options: .atomic)
    let service = YarnPhotoFileService(directory: photosURL)
    let store = JSONProjectStore(url: storeURL, yarnPhotoService: service)

    #expect(throws: ProjectStoreError.archiveUnavailable) {
        try store.addYarn(
            StoredYarn(name: "Merino"),
            photoData: makeStoreJPEG(red: 0.4)
        )
    }

    #expect(!FileManager.default.fileExists(atPath: photosURL.path))
}

@MainActor @Test func yarnCRUDAndLinksPersistAcrossStoreInstances() throws {
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = JSONProjectStore(url: storeURL)
    try store.add(name: "Scarf")
    let projectID = try #require(store.projects.first?.id)
    var yarn = try StoredYarn(name: "Merino", now: Date(timeIntervalSince1970: 100))
    let olderYarn = try StoredYarn(name: "Cotton", now: Date(timeIntervalSince1970: 50))

    try store.addYarn(yarn)
    try store.addYarn(olderYarn)
    try yarn.rename(to: "Fine Merino", now: Date(timeIntervalSince1970: 200))
    try store.updateYarn(yarn)
    try store.setYarnProjects(yarnID: yarn.id, projectIDs: [projectID])

    let reloaded = JSONProjectStore(url: storeURL)
    #expect(reloaded.yarns.map(\.id) == [yarn.id, olderYarn.id])
    #expect(reloaded.yarn(id: yarn.id)?.name == "Fine Merino")
    #expect(reloaded.yarn(id: yarn.id)?.linkedProjectIDs == [projectID])
    let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: storeURL))
    #expect(archive.version == ProjectArchive.currentVersion)

    try reloaded.deleteYarn(id: yarn.id)
    let afterDelete = JSONProjectStore(url: storeURL)
    #expect(afterDelete.yarn(id: yarn.id) == nil)
    #expect(afterDelete.project(id: projectID) != nil)
}

@MainActor @Test func yarnLinksRejectMissingProjectsWithoutPersistingChanges() throws {
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = JSONProjectStore(url: storeURL)
    let yarn = try StoredYarn(name: "Merino")
    try store.addYarn(yarn)
    let committedData = try Data(contentsOf: storeURL)

    #expect(throws: (any Error).self) {
        try store.setYarnProjects(yarnID: yarn.id, projectIDs: [UUID()])
    }

    #expect(store.yarn(id: yarn.id)?.linkedProjectIDs.isEmpty == true)
    #expect(try Data(contentsOf: storeURL) == committedData)
}

@MainActor @Test func loadingArchiveDropsLinksToMissingProjects() throws {
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = try StoredProject(name: "Scarf")
    let missingProjectID = UUID()
    var yarn = try StoredYarn(name: "Merino")
    yarn.setLinkedProjectIDs([project.id, missingProjectID])
    let archive = ProjectArchive(version: 8, projects: [project], yarns: [yarn])
    try JSONEncoder().encode(archive).write(to: storeURL, options: .atomic)

    let store = JSONProjectStore(url: storeURL)

    #expect(store.yarn(id: yarn.id)?.linkedProjectIDs == [project.id])
    try store.rename(id: project.id, to: "Finished scarf")
    let persistedArchive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: storeURL))
    #expect(persistedArchive.yarns.first?.linkedProjectIDs == [project.id])
}

@MainActor @Test func deletingProjectRemovesItsLinkFromEveryYarn() throws {
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = JSONProjectStore(url: storeURL)
    try store.add(name: "Scarf")
    try store.add(name: "Hat")
    let deletedProjectID = try #require(store.projects.first(where: { $0.name == "Scarf" })?.id)
    let retainedProjectID = try #require(store.projects.first(where: { $0.name == "Hat" })?.id)
    let merino = try StoredYarn(name: "Merino")
    let cotton = try StoredYarn(name: "Cotton")
    try store.addYarn(merino)
    try store.addYarn(cotton)
    try store.setYarnProjects(yarnID: merino.id, projectIDs: [deletedProjectID, retainedProjectID])
    try store.setYarnProjects(yarnID: cotton.id, projectIDs: [deletedProjectID])

    try store.delete(id: deletedProjectID)

    let reloaded = JSONProjectStore(url: storeURL)
    #expect(reloaded.project(id: deletedProjectID) == nil)
    #expect(reloaded.yarn(id: merino.id)?.linkedProjectIDs == [retainedProjectID])
    #expect(reloaded.yarn(id: cotton.id)?.linkedProjectIDs.isEmpty == true)
}

@MainActor @Test func savingAnOlderYarnDraftDropsAConcurrentlyDeletedProjectLink() throws {
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = JSONProjectStore(url: storeURL)
    try store.add(name: "Scarf")
    try store.add(name: "Hat")
    let deletedProjectID = try #require(store.projects.first(where: { $0.name == "Scarf" })?.id)
    let retainedProjectID = try #require(store.projects.first(where: { $0.name == "Hat" })?.id)
    let yarn = try StoredYarn(name: "Merino")
    try store.addYarn(yarn)
    try store.setYarnProjects(
        yarnID: yarn.id,
        projectIDs: [deletedProjectID, retainedProjectID]
    )
    var editorSnapshot = try #require(store.yarn(id: yarn.id))

    try store.delete(id: deletedProjectID)
    try editorSnapshot.rename(to: "Edited Merino")
    editorSnapshot.setLinkedProjectIDs(
        editorSnapshot.linkedProjectIDs.intersection(store.projects.map(\.id))
    )
    try store.updateYarn(editorSnapshot)

    let saved = try #require(store.yarn(id: yarn.id))
    #expect(saved.name == "Edited Merino")
    #expect(saved.linkedProjectIDs == [retainedProjectID])
}

@MainActor @Test func updatingYarnStillRejectsArbitraryMissingProjectLinks() throws {
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = JSONProjectStore(url: storeURL)
    var yarn = try StoredYarn(name: "Merino")
    try store.addYarn(yarn)
    yarn.setLinkedProjectIDs([UUID()])

    #expect(throws: ProjectStoreError.invalidYarnProjectLinks) {
        try store.updateYarn(yarn)
    }
    #expect(store.yarn(id: yarn.id)?.linkedProjectIDs.isEmpty == true)
}

@MainActor @Test func deletingProjectCleansYarnLinksBeforePhotoCleanup() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let archiveURL = base.appendingPathComponent("projects.json")
    let photoService = ProjectPhotoFileService(directory: base.appendingPathComponent("photos"))
    let store = JSONProjectStore(url: archiveURL, photoService: photoService)
    try store.add(name: "Scarf", photoData: makeStoreJPEG(red: 0.4))
    let project = try #require(store.projects.first)
    let filename = try #require(project.photoFilename)
    let yarn = try StoredYarn(name: "Merino")
    try store.addYarn(yarn)
    try store.setYarnProjects(yarnID: yarn.id, projectIDs: [project.id])

    try FileManager.default.removeItem(at: archiveURL)
    try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) {
        try store.delete(id: project.id)
    }

    #expect(store.project(id: project.id) != nil)
    #expect(store.yarn(id: yarn.id)?.linkedProjectIDs == [project.id])
    #expect(FileManager.default.fileExists(atPath: photoService.url(filename: filename).path))
}

@Test func projectPhotoMetadataRoundTrips() throws {
    var project = try StoredProject(name: "Cardigan")
    #expect(project.photoFilename == nil)

    project.setPhotoFilename("project-photo.jpg")
    let decoded = try JSONDecoder().decode(StoredProject.self, from: JSONEncoder().encode(project))

    #expect(decoded.photoFilename == "project-photo.jpg")
}

@Test func legacyProjectWithoutPhotoMetadataStillDecodes() throws {
    let project = try StoredProject(name: "Legacy scarf")
    let encoded = try JSONEncoder().encode(project)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "photoFilename")

    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(StoredProject.self, from: legacyData)

    #expect(decoded.photoFilename == nil)
}

@MainActor @Test func projectToolDetailsNormalizeAndPersist() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = JSONProjectStore(url: url)
    try store.add(name: "Cardigan")
    let project = try #require(store.projects.first)

    try store.updateProject(
        id: project.id,
        name: project.name,
        toolType: .crochetHook,
        toolSize: "  3.5 mm  ",
        toolNotes: "  ergonomic handle  ",
        photoChange: .unchanged
    )

    let reloaded = try #require(JSONProjectStore(url: url).project(id: project.id))
    #expect(reloaded.toolType == .crochetHook)
    #expect(reloaded.toolSize == "3.5 mm")
    #expect(reloaded.toolNotes == "ergonomic handle")

    try store.updateProject(
        id: project.id,
        name: project.name,
        toolType: nil,
        toolSize: "   ",
        toolNotes: "\n",
        photoChange: .unchanged
    )
    let cleared = try #require(JSONProjectStore(url: url).project(id: project.id))
    #expect(cleared.toolType == nil)
    #expect(cleared.toolSize == nil)
    #expect(cleared.toolNotes == nil)
}

@Test func projectToolDetailsOnlyUpdateTimestampWhenNormalizedValuesChange() throws {
    let start = Date(timeIntervalSince1970: 1_000)
    var project = try StoredProject(name: "Cardigan", now: start)

    project.updateToolDetails(
        type: .knittingNeedles,
        size: " 4 mm ",
        notes: " bamboo ",
        now: Date(timeIntervalSince1970: 2_000)
    )
    #expect(project.updatedAt == Date(timeIntervalSince1970: 2_000))

    project.updateToolDetails(
        type: .knittingNeedles,
        size: "4 mm",
        notes: "bamboo",
        now: Date(timeIntervalSince1970: 3_000)
    )
    #expect(project.updatedAt == Date(timeIntervalSince1970: 2_000))
}

@Test func legacyProjectWithoutToolDetailsDefaultsToEmpty() throws {
    let original = try StoredProject(name: "Scarf")
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    object.removeValue(forKey: "toolType")
    object.removeValue(forKey: "toolSize")
    object.removeValue(forKey: "toolNotes")
    let decoded = try JSONDecoder().decode(
        StoredProject.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
    #expect(decoded.toolType == nil)
    #expect(decoded.toolSize == nil)
    #expect(decoded.toolNotes == nil)
}

@MainActor @Test func storeCreatesReplacesAndRemovesProjectPhoto() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let archiveURL = base.appendingPathComponent("projects.json")
    let photoService = ProjectPhotoFileService(directory: base.appendingPathComponent("photos"))
    let store = JSONProjectStore(url: archiveURL, photoService: photoService)

    try store.add(name: "Sweater", photoData: makeStoreJPEG(red: 0.3))
    let projectID = try #require(store.projects.first?.id)
    let firstFilename = try #require(store.projects.first?.photoFilename)
    #expect(FileManager.default.fileExists(atPath: photoService.url(filename: firstFilename).path))

    let counterID = try #require(store.project(id: projectID)?.selectedCounterID)
    try store.incrementCounter(projectID: projectID, counterID: counterID)
    try store.updateProject(
        id: projectID,
        name: "Blue sweater",
        toolType: nil,
        toolSize: nil,
        toolNotes: nil,
        photoChange: .replace(makeStoreJPEG(red: 0.1))
    )
    let replaced = try #require(store.project(id: projectID))
    let secondFilename = try #require(replaced.photoFilename)
    #expect(replaced.name == "Blue sweater")
    #expect(replaced.selectedCounter.value == 1)
    #expect(secondFilename != firstFilename)
    #expect(!FileManager.default.fileExists(atPath: photoService.url(filename: firstFilename).path))
    #expect(FileManager.default.fileExists(atPath: photoService.url(filename: secondFilename).path))

    try store.updateProject(
        id: projectID,
        name: "Blue sweater",
        toolType: nil,
        toolSize: nil,
        toolNotes: nil,
        photoChange: .remove
    )
    #expect(store.project(id: projectID)?.photoFilename == nil)
    #expect(!FileManager.default.fileExists(atPath: photoService.url(filename: secondFilename).path))

    let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: archiveURL))
    #expect(archive.version == ProjectArchive.currentVersion)
}

@MainActor @Test func projectCoverPrefersCustomPhotoThenFirstActiveUsage() async throws {
    let harness = try PatternImportHarness()
    let store = harness.store
    try store.add(name: "Sweater", photoData: makeStoreJPEG(red: 0.5))
    let projectID = try #require(store.projects.first?.id)
    let firstSource = try harness.makePDF(named: "First.pdf")
    let secondSource = harness.sourceRoot.appendingPathComponent("Second.pdf")
    try makeTestPatternPDF(at: secondSource, pageCount: 2)
    _ = try await harness.importURL(firstSource)
    _ = try await harness.importURL(secondSource)
    let firstPattern = try #require(store.patterns.first { $0.displayName == "First" })
    let secondPattern = try #require(store.patterns.first { $0.displayName == "Second" })
    let firstAsset = try #require(store.patternAssets.first { $0.id == firstPattern.assetID })
    let secondAsset = try #require(store.patternAssets.first { $0.id == secondPattern.assetID })
    try store.linkPattern(patternID: firstPattern.id, to: projectID)
    try store.linkPattern(patternID: secondPattern.id, to: projectID)

    let withPhoto = try #require(store.project(id: projectID))
    let customCoverURL = await store.projectCoverURL(for: withPhoto)
    #expect(customCoverURL == store.photoURL(for: withPhoto))

    try store.updateProject(
        id: projectID,
        name: withPhoto.name,
        toolType: withPhoto.toolType,
        toolSize: withPhoto.toolSize,
        toolNotes: withPhoto.toolNotes,
        photoChange: .remove
    )
    let withoutPhoto = try #require(store.project(id: projectID))
    let firstPatternCoverURL = await store.projectCoverURL(for: withoutPhoto)
    #expect(firstPatternCoverURL == harness.thumbnailService.cachedURL(assetID: firstAsset.id))

    try store.unlinkPattern(patternID: firstPattern.id, from: projectID)
    let afterFirstUnlink = try #require(store.project(id: projectID))
    let secondPatternCoverURL = await store.projectCoverURL(for: afterFirstUnlink)
    #expect(secondPatternCoverURL == harness.thumbnailService.cachedURL(assetID: secondAsset.id))

    try store.unlinkPattern(patternID: secondPattern.id, from: projectID)
    let withoutActiveUsages = try #require(store.project(id: projectID))
    let defaultCoverURL = await store.projectCoverURL(for: withoutActiveUsages)
    #expect(defaultCoverURL == nil)
}

@MainActor @Test func deletingOneSharedPatternRetainsItsAssetThumbnailUntilTheLastPatternIsDeleted() async throws {
    let harness = try PatternImportHarness()
    let store = harness.store
    try store.add(name: "Shared cover")
    let projectID = try #require(store.projects.first?.id)
    _ = try await harness.importURL(harness.makePDF(named: "shared.pdf"))
    let firstPattern = try #require(store.patterns.first)
    let asset = try #require(store.patternAssets.first)
    let secondPattern = StoredPattern(assetID: asset.id, displayName: "Shared copy")
    var archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: harness.archiveURL))
    archive.patterns.append(secondPattern)
    try JSONEncoder().encode(archive).write(to: harness.archiveURL, options: .atomic)
    try store.reloadFromDisk()
    try store.linkPattern(patternID: firstPattern.id, to: projectID)
    try store.linkPattern(patternID: secondPattern.id, to: projectID)

    let project = try #require(store.project(id: projectID))
    let cacheURL = try #require(await store.projectCoverURL(for: project))
    #expect(cacheURL == harness.thumbnailService.cachedURL(assetID: asset.id))

    try store.unlinkPattern(patternID: firstPattern.id, from: projectID)
    try store.deletePatternPermanently(id: firstPattern.id)
    #expect(FileManager.default.fileExists(atPath: cacheURL.path))
    let secondCover = try #require(await store.projectCoverURL(for: project))
    #expect(secondCover == cacheURL)

    let afterFirstDeletion = try harness.reopenedStore()
    #expect(afterFirstDeletion.patterns.map(\.id) == [secondPattern.id])
    #expect(afterFirstDeletion.patternAssets.map(\.id) == [asset.id])

    try store.unlinkPattern(patternID: secondPattern.id, from: projectID)
    try store.deletePatternPermanently(id: secondPattern.id)
    #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
    let assetURL = try harness.assetURLFor(source: try harness.makePDF(named: "shared.pdf"))
    #expect(!FileManager.default.fileExists(atPath: assetURL.path))

    let afterLastDeletion = try harness.reopenedStore()
    #expect(afterLastDeletion.patterns.isEmpty)
    #expect(afterLastDeletion.patternAssets.isEmpty)
}

@MainActor @Test func coverCacheRegeneratesWithoutChangingArchiveOrImportSuccess() async throws {
    let harness = try PatternImportHarness()
    let store = harness.store
    try store.add(name: "Hat")
    let projectID = try #require(store.projects.first?.id)
    let source = try harness.makePDF(named: "chart.pdf")
    _ = try await harness.importURL(source)
    let pattern = try #require(store.patterns.first)
    let asset = try #require(store.patternAssets.first)
    try store.linkPattern(patternID: pattern.id, to: projectID)
    let project = try #require(store.project(id: projectID))
    let firstCandidate = await store.projectCoverURL(for: project)
    let firstURL = try #require(firstCandidate)
    try FileManager.default.removeItem(at: firstURL)

    let restarted = try harness.reopenedStore()
    let restartedProject = try #require(restarted.project(id: projectID))
    let regeneratedCandidate = await restarted.projectCoverURL(for: restartedProject)
    let regenerated = try #require(regeneratedCandidate)

    #expect(regenerated == harness.thumbnailService.cachedURL(assetID: asset.id))
    #expect(FileManager.default.fileExists(atPath: regenerated.path))
    let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: harness.archiveURL))
    #expect(archive.projects.first?.photoFilename == nil)
}

@MainActor @Test func exportBackupExcludesDisposablePatternThumbnailCache() async throws {
    let harness = try PatternImportHarness()
    let store = harness.store
    try store.add(name: "Exported pattern")
    let projectID = try #require(store.projects.first?.id)
    let sourceURL = harness.sourceRoot.appendingPathComponent("source.png")
    try makeStorePNG(at: sourceURL, red: 0.2)
    _ = try await harness.importURL(sourceURL)
    let pattern = try #require(store.patterns.first)
    let asset = try #require(store.patternAssets.first)
    try store.linkPattern(patternID: pattern.id, to: projectID)
    let project = try #require(store.project(id: projectID))
    let cacheURL = try #require(await store.projectCoverURL(for: project))
    #expect(FileManager.default.fileExists(atPath: cacheURL.path))

    let packageURL = try await store.exportBackup(appVersion: "1.0")
    let packagedPaths = try backupPackageRelativePaths(at: packageURL)

    #expect(!packagedPaths.contains { $0.contains(".KnitNote-PatternThumbnailCache") })
    #expect(!packagedPaths.contains { $0.hasSuffix("\(asset.id.uuidString).jpg") })
}

@MainActor @Test func restoreBackupInvalidatesTheDisposableThumbnailCache() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let thumbnailService = PatternThumbnailFileService(
        directory: base.appendingPathComponent("ThumbnailCache", isDirectory: true)
    )
    let store = JSONProjectStore(
        url: base.appendingPathComponent("KnitNote/projects-v1.json"),
        patternThumbnailService: thumbnailService
    )
    try store.add(name: "Restored pattern")
    let sourceURL = base.appendingPathComponent("source.png")
    try makeStorePNG(at: sourceURL, red: 0.2)
    let asset = PatternAsset(
        sha256: "thumbnail-test",
        kind: .image,
        storedFilename: "\(UUID().uuidString).png",
        byteCount: 0,
        pageCount: nil
    )
    let cacheURL = try thumbnailService.thumbnailURL(asset: asset, sourceURL: sourceURL)
    let packageURL = try await store.exportBackup(appVersion: "1.0")
    let staged = try await store.prepareBackupRestore(from: packageURL)

    let generationBeforeRestore = store.projectCoverGeneration

    try await store.restoreBackup(staged)

    #expect(store.projectCoverGeneration == generationBeforeRestore + 1)
    #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
}

@MainActor @Test func formatTwoBackupRoundTripRestoresSharedPatternStateAndMarkupPrecisely() async throws {
    let harness = try BackupPatternHarness()
    defer { harness.cleanup() }
    let store = harness.store
    try store.add(name: "Inactive cardigan")
    try store.add(name: "Active cardigan")
    let inactiveProject = try #require(store.projects.first { $0.name == "Inactive cardigan" })
    let activeProject = try #require(store.projects.first { $0.name == "Active cardigan" })
    let counterID = activeProject.counters[2].id
    try store.selectCounter(projectID: activeProject.id, counterID: counterID)
    try store.renameCounter(projectID: activeProject.id, counterID: counterID, name: "Sleeve")
    try store.updateCounter(
        projectID: activeProject.id,
        counterID: counterID,
        name: "Sleeve",
        value: 37
    )
    try store.saveNote(
        projectID: activeProject.id,
        counterID: counterID,
        row: 37,
        text: "Begin shaping"
    )

    let source = harness.sourceRoot.appendingPathComponent("Shared chart.pdf")
    try makeStorePatternPDF(at: source)
    let outcome = try await store.importPatternFromLibrary(
        source,
        now: .init(timeIntervalSince1970: 100)
    )
    guard case let .created(patternID) = outcome else {
        Issue.record("Expected a new pattern")
        return
    }
    try store.setPatternNote(id: patternID, note: "Designer and shop")
    try store.markPatternOpened(id: patternID, at: .init(timeIntervalSince1970: 101))
    let inactiveUsage = try store.linkPattern(
        patternID: patternID,
        to: inactiveProject.id
    )
    let activeUsage = try store.linkPattern(
        patternID: patternID,
        to: activeProject.id
    )
    let inactiveState = PatternReadingState(
        pageIndex: 0,
        zoomScale: 1.75,
        offsetX: 0.2,
        offsetY: 0.3,
        highlightEnabled: true,
        highlightPosition: 0.35,
        highlightMode: .horizontal,
        verticalHighlightPosition: 0.55,
        pageNote: "Inactive note",
        pageStates: [0: .init(
            horizontalPosition: 0.35,
            verticalPosition: 0.55,
            note: "Inactive note"
        )]
    )
    let activeState = PatternReadingState(
        pageIndex: 0,
        zoomScale: 2.5,
        offsetX: 0.6,
        offsetY: 0.7,
        highlightEnabled: true,
        highlightPosition: 0.45,
        highlightMode: .vertical,
        verticalHighlightPosition: 0.8,
        pageNote: "Active note",
        pageStates: [0: .init(
            horizontalPosition: 0.45,
            verticalPosition: 0.8,
            note: "Active note"
        )]
    )
    _ = try store.updatePatternState(usageID: inactiveUsage.id, state: inactiveState)
    _ = try store.updatePatternState(usageID: activeUsage.id, state: activeState)
    let inactiveMarkup = PatternMarkupDocument(strokes: [
        .init(points: [.init(x: 0.1, y: 0.2)], color: .red, width: 0.006),
    ])
    let activeMarkup = PatternMarkupDocument(strokes: [
        .init(
            points: [.init(x: 0.7, y: 0.8), .init(x: 0.8, y: 0.9)],
            color: .blue,
            width: 0.008
        ),
    ])
    _ = try store.savePatternMarkup(
        inactiveMarkup,
        usageID: inactiveUsage.id,
        pageIndex: 0,
        expectedDataGeneration: store.dataGeneration
    )
    _ = try store.savePatternMarkup(
        activeMarkup,
        usageID: activeUsage.id,
        pageIndex: 0,
        expectedDataGeneration: store.dataGeneration
    )
    try store.unlinkPattern(patternID: patternID, from: inactiveProject.id)
    let originalBytes = try Data(contentsOf: store.patternAssetURL(patternID: patternID))

    let package = try await store.exportBackup(appVersion: "1.2.0")
    let preview = try harness.service.inspectPackage(at: package)
    #expect(preview.patternCount == 1)
    try store.unlinkPattern(patternID: patternID, from: activeProject.id)
    try store.deletePatternPermanently(id: patternID)
    try store.delete(id: inactiveProject.id)
    try store.delete(id: activeProject.id)
    #expect(store.patterns.isEmpty)
    #expect(store.projects.isEmpty)

    let staged = try await store.prepareBackupRestore(from: package)
    try await store.restoreBackup(staged)

    #expect(store.patternAssets.count == 1)
    #expect(store.patterns.count == 1)
    #expect(store.patterns.first?.note == "Designer and shop")
    #expect(store.patterns.first?.lastOpenedAt == .init(timeIntervalSince1970: 101))
    #expect(store.patternUsages.count == 2)
    let restoredInactive = try #require(
        store.patternUsages.first { $0.id == inactiveUsage.id }
    )
    let restoredActive = try #require(
        store.patternUsages.first { $0.id == activeUsage.id }
    )
    #expect(restoredInactive.isActive == false)
    #expect(restoredInactive.readingState == inactiveState)
    #expect(restoredActive.isActive == true)
    #expect(restoredActive.readingState == activeState)
    #expect(try store.loadPatternMarkup(usageID: inactiveUsage.id, pageIndex: 0) == inactiveMarkup)
    #expect(try store.loadPatternMarkup(usageID: activeUsage.id, pageIndex: 0) == activeMarkup)
    let restoredProject = try #require(store.project(id: activeProject.id))
    #expect(restoredProject.selectedCounterID == counterID)
    #expect(restoredProject.selectedCounter.customName == "Sleeve")
    #expect(restoredProject.selectedCounter.value == 37)
    #expect(restoredProject.note(counterID: counterID, row: 37)?.text == "Begin shaping")
    #expect(
        store.patternUsages
            .filter { $0.projectID == activeProject.id && $0.isActive }
            .map(\.id)
            == [activeUsage.id]
    )
    #expect(try Data(contentsOf: store.patternAssetURL(patternID: patternID)) == originalBytes)
}

@MainActor @Test func publicRestorePublishesValidPatternFolderMembership() async throws {
    let harness = try BackupPatternHarness()
    defer { harness.cleanup() }
    let folder = PatternFolder(displayName: "Sweaters")
    let packaged = try await makeFolderMembershipPackage(
        harness: harness,
        folders: [folder],
        assignedFolderID: folder.id
    )

    let staged = try await harness.store.prepareBackupRestore(from: packaged.package)
    try await harness.store.restoreBackup(staged)

    #expect(harness.store.patterns.map(\.id) == [packaged.patternID])
    #expect(harness.store.patterns.first?.folderID == folder.id)
}

@MainActor @Test func publicRestorePublishesOrphanMembershipAsUncategorized() async throws {
    let harness = try BackupPatternHarness()
    defer { harness.cleanup() }
    let packaged = try await makeFolderMembershipPackage(
        harness: harness,
        folders: [],
        assignedFolderID: UUID()
    )

    let staged = try await harness.store.prepareBackupRestore(from: packaged.package)
    try await harness.store.restoreBackup(staged)

    #expect(harness.store.patterns.map(\.id) == [packaged.patternID])
    #expect(harness.store.patterns.first?.folderID == nil)
}

@MainActor @Test func failedPublicRestoreRollsBackFolderMembershipWithoutPartialPublication() async throws {
    let original = try BackupPatternHarness()
    let replacement = try BackupPatternHarness()
    defer {
        original.cleanup()
        replacement.cleanup()
    }
    let originalFolder = PatternFolder(displayName: "Original folder")
    let originalPattern = try await installFolderMembership(
        harness: original,
        folders: [originalFolder],
        assignedFolderID: originalFolder.id,
        filename: "Original.pdf"
    )
    let replacementFolder = PatternFolder(displayName: "Replacement folder")
    _ = try await installFolderMembership(
        harness: replacement,
        folders: [replacementFolder],
        assignedFolderID: replacementFolder.id,
        filename: "Replacement.pdf"
    )
    let replacementPackage = try replacement.service.createPackage(appVersion: "1.5.0")
    let nameContext = try shippingPatternFolderNameContext()
    let failureService = KnitNoteBackupService(
        liveRoot: original.liveRoot,
        workRoot: original.root.appendingPathComponent("FailureRestoreWork", isDirectory: true),
        patternFolderNameContext: nameContext,
        replacementStepHook: { step in
            if step == .afterStagedMove {
                try Data("not JSON".utf8).write(to: original.archiveURL, options: .atomic)
            }
        }
    )
    let store = JSONProjectStore(
        url: original.archiveURL,
        patternFileService: PatternFileService(
            root: original.liveRoot.appendingPathComponent("Patterns", isDirectory: true)
        ),
        patternMarkupFileService: PatternMarkupFileService(
            root: original.liveRoot.appendingPathComponent("Patterns", isDirectory: true)
        ),
        patternFolderNameContext: nameContext,
        backupService: failureService
    )
    let staged = try await store.prepareBackupRestore(from: replacementPackage)

    await #expect(throws: KnitNoteBackupError.installFailedOriginalPreserved) {
        try await store.restoreBackup(staged)
    }

    #expect(store.patterns == [originalPattern])
    #expect(store.patterns.first?.folderID == originalFolder.id)
    let archive = try JSONDecoder().decode(
        ProjectArchive.self,
        from: Data(contentsOf: original.archiveURL)
    )
    #expect(archive.patternFolders == [originalFolder])
    #expect(archive.patterns == [originalPattern])
}

@MainActor @Test func publicRestoreRejectsReservedFolderNameWithoutPublishing() async throws {
    let harness = try BackupPatternHarness()
    defer { harness.cleanup() }
    let originalFolder = PatternFolder(displayName: "Original folder")
    let originalPattern = try await installFolderMembership(
        harness: harness,
        folders: [originalFolder],
        assignedFolderID: originalFolder.id,
        filename: "Original reserved restore.pdf"
    )
    let package = try harness.service.createPackage(appVersion: "1.5.0")
    let staged = try await harness.store.prepareBackupRestore(from: package)
    let stagedArchiveURL = staged.root.appendingPathComponent("Data/projects-v1.json")
    var stagedArchive = try JSONDecoder().decode(
        ProjectArchive.self,
        from: Data(contentsOf: stagedArchiveURL)
    )
    stagedArchive.patternFolders[0].displayName = "未分類"
    try JSONEncoder().encode(stagedArchive).write(to: stagedArchiveURL, options: .atomic)

    let liveBytes = try Data(contentsOf: harness.archiveURL)
    let folders = harness.store.patternFolders
    let patterns = harness.store.patterns
    let generation = harness.store.dataGeneration
    let selection = PatternLibraryScope.folder(originalFolder.id)

    await #expect(throws: KnitNoteBackupError.invalidArchive) {
        try await harness.store.restoreBackup(staged)
    }
    #expect(try Data(contentsOf: harness.archiveURL) == liveBytes)
    #expect(harness.store.patternFolders == folders)
    #expect(harness.store.patterns == patterns)
    #expect(harness.store.patterns == [originalPattern])
    #expect(harness.store.dataGeneration == generation)
    #expect(selection == .folder(originalFolder.id))
}

@MainActor @Test func formatOneLegacyPatternBackupRestoresAndMigratesToSchemaTen() async throws {
    let harness = try BackupPatternHarness()
    defer { harness.cleanup() }
    try harness.store.add(name: "Current data")
    let legacy = try harness.makeFormatOneLegacyPatternPackage()

    let staged = try await harness.store.prepareBackupRestore(from: legacy.package)
    #expect(staged.preview.patternCount == nil)
    try await harness.store.restoreBackup(staged)

    #expect(harness.store.projects.map(\.name) == ["Legacy pattern project"])
    #expect(harness.store.patternAssets.count == 1)
    #expect(harness.store.patterns.count == 1)
    #expect(harness.store.patternUsages.count == 1)
    let usage = try #require(harness.store.patternUsages.first)
    #expect(usage.id == legacy.patternID)
    #expect(usage.isActive)
    #expect(usage.readingState == legacy.readingState)
    #expect(
        try harness.store.loadPatternMarkup(
            usageID: usage.id,
            pageIndex: legacy.readingState.pageIndex
        ) == legacy.markup
    )
    #expect(
        try Data(contentsOf: harness.store.patternAssetURL(
            patternID: try #require(harness.store.patterns.first?.id)
        )) == legacy.originalBytes
    )
    let archive = try JSONDecoder().decode(
        ProjectArchive.self,
        from: Data(contentsOf: harness.archiveURL)
    )
    #expect(archive.version == ProjectArchive.currentVersion)
}

@MainActor @Test func corruptFormatTwoPreflightLeavesLivePatternDataUnchanged() async throws {
    let harness = try BackupPatternHarness()
    defer { harness.cleanup() }
    try harness.store.add(name: "Preserved project")
    let projectID = try #require(harness.store.projects.first?.id)
    let source = harness.sourceRoot.appendingPathComponent("Preserved.pdf")
    try makeStorePatternPDF(at: source)
    guard case let .created(patternID) = try await harness.store.importPatternFromLibrary(source)
    else {
        Issue.record("Expected a new pattern")
        return
    }
    _ = try harness.store.linkPattern(patternID: patternID, to: projectID)
    let originalBytes = try Data(contentsOf: harness.store.patternAssetURL(patternID: patternID))
    let package = try await harness.store.exportBackup(appVersion: "1.2.0")
    let manifest = try JSONDecoder().decode(
        KnitNoteBackupManifest.self,
        from: Data(contentsOf: package.appendingPathComponent("manifest.json"))
    )
    let assetPath = try #require(
        manifest.files.first { $0.relativePath.hasPrefix("Patterns/Assets/") }
    ).relativePath
    try Data(repeating: 0xA5, count: originalBytes.count).write(
        to: package.appendingPathComponent("Data/\(assetPath)"),
        options: .atomic
    )

    await #expect(throws: KnitNoteBackupError.integrityMismatch(assetPath)) {
        _ = try await harness.store.prepareBackupRestore(from: package)
    }

    #expect(harness.store.projects.map(\.name) == ["Preserved project"])
    #expect(harness.store.patterns.map(\.id) == [patternID])
    #expect(try Data(contentsOf: harness.store.patternAssetURL(patternID: patternID)) == originalBytes)
    #expect(!harness.store.isDataOperationInProgress)
}

@MainActor @Test func thumbnailFailureDoesNotRollbackStandaloneLibraryImportOrProjectCoverFallback() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let blockedCacheRoot = base.appendingPathComponent("blocked-cache")
    try Data("not a directory".utf8).write(to: blockedCacheRoot)
    let locations = PatternStorageLocations(
        assetRoot: base.appendingPathComponent("KnitNote/Patterns", isDirectory: true),
        inboxRoot: base.appendingPathComponent("PatternInbox", isDirectory: true)
    )
    let inbox = PatternInboxFileService(root: locations.inboxRoot)
    let store = JSONProjectStore(
        url: base.appendingPathComponent("KnitNote/projects-v1.json"),
        patternFileService: PatternFileService(root: locations.assetRoot),
        patternInboxFileService: inbox,
        patternThumbnailService: PatternThumbnailFileService(directory: blockedCacheRoot)
    )
    try store.add(name: "Scarf")
    let projectID = try #require(store.projects.first?.id)
    let source = base.appendingPathComponent("chart.png")
    try makeStorePNG(at: source, red: 0.6)
    let item = try inbox.enqueue(
        source: source,
        origin: .project,
        targetProjectID: projectID,
        now: .now
    )
    let outcome = try await store.processPatternInboxItem(id: item.id)
    guard case let .created(patternID) = outcome else {
        Issue.record("Expected a new library pattern")
        return
    }
    let savedProject = try #require(store.project(id: projectID))
    let fallbackURL = await store.projectCoverURL(for: savedProject)

    #expect(store.patterns.map(\.id) == [patternID])
    #expect(store.patternAssets.count == 1)
    #expect(store.patternUsages.map(\.patternID) == [patternID])
    #expect(fallbackURL == nil)

    let reopened = JSONProjectStore(
        url: base.appendingPathComponent("KnitNote/projects-v1.json"),
        patternFileService: PatternFileService(root: locations.assetRoot),
        patternInboxFileService: PatternInboxFileService(root: locations.inboxRoot),
        patternThumbnailService: PatternThumbnailFileService(directory: blockedCacheRoot)
    )
    #expect(reopened.patterns.map(\.id) == [patternID])
    #expect(reopened.patternAssets.count == 1)
    #expect(reopened.patternUsages.map(\.patternID) == [patternID])
}

@MainActor @Test func invalidReplacementPreservesCommittedPhotoAndDeleteCleansIt() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let archiveURL = base.appendingPathComponent("projects.json")
    let photoService = ProjectPhotoFileService(directory: base.appendingPathComponent("photos"))
    let store = JSONProjectStore(url: archiveURL, photoService: photoService)
    try store.add(name: "Hat", photoData: makeStoreJPEG(red: 0.7))
    let project = try #require(store.projects.first)
    let filename = try #require(project.photoFilename)

    #expect(throws: ProjectPhotoFileError.invalidImage) {
        try store.updateProject(
            id: project.id,
            name: "Changed",
            toolType: project.toolType,
            toolSize: project.toolSize,
            toolNotes: project.toolNotes,
            photoChange: .replace(Data("bad".utf8))
        )
    }
    #expect(store.project(id: project.id)?.name == "Hat")
    #expect(store.project(id: project.id)?.photoFilename == filename)
    #expect(FileManager.default.fileExists(atPath: photoService.url(filename: filename).path))

    try store.delete(id: project.id)
    #expect(!FileManager.default.fileExists(atPath: photoService.url(filename: filename).path))
}

@MainActor @Test func storeCreatesReplacesRemovesAndDeletesYarnPhotos() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let archiveURL = base.appendingPathComponent("projects.json")
    let yarnPhotoService = YarnPhotoFileService(directory: base.appendingPathComponent("yarn-photos"))
    let store = JSONProjectStore(url: archiveURL, yarnPhotoService: yarnPhotoService)
    var yarn = try StoredYarn(name: "Merino")

    try store.addYarn(yarn, photoData: makeStoreJPEG(red: 0.3))
    let firstFilename = try #require(store.yarn(id: yarn.id)?.photoFilename)
    #expect(FileManager.default.fileExists(atPath: yarnPhotoService.url(filename: firstFilename).path))
    #expect(store.photoURL(for: try #require(store.yarn(id: yarn.id))) == yarnPhotoService.url(filename: firstFilename))

    try yarn.rename(to: "Fine Merino")
    try store.updateYarn(yarn, photoChange: .replace(makeStoreJPEG(red: 0.1)))
    let replaced = try #require(store.yarn(id: yarn.id))
    let secondFilename = try #require(replaced.photoFilename)
    #expect(replaced.name == "Fine Merino")
    #expect(secondFilename != firstFilename)
    #expect(!FileManager.default.fileExists(atPath: yarnPhotoService.url(filename: firstFilename).path))
    #expect(FileManager.default.fileExists(atPath: yarnPhotoService.url(filename: secondFilename).path))

    try store.updateYarn(replaced, photoChange: .remove)
    #expect(store.yarn(id: yarn.id)?.photoFilename == nil)
    #expect(!FileManager.default.fileExists(atPath: yarnPhotoService.url(filename: secondFilename).path))

    try store.updateYarn(try #require(store.yarn(id: yarn.id)), photoChange: .replace(makeStoreJPEG(red: 0.8)))
    let deletedFilename = try #require(store.yarn(id: yarn.id)?.photoFilename)
    try store.deleteYarn(id: yarn.id)
    #expect(store.yarn(id: yarn.id) == nil)
    #expect(!FileManager.default.fileExists(atPath: yarnPhotoService.url(filename: deletedFilename).path))
}

@MainActor @Test func invalidYarnPhotoReplacementPreservesCommittedPhoto() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let archiveURL = base.appendingPathComponent("projects.json")
    let yarnPhotoService = YarnPhotoFileService(directory: base.appendingPathComponent("yarn-photos"))
    let store = JSONProjectStore(url: archiveURL, yarnPhotoService: yarnPhotoService)
    let yarn = try StoredYarn(name: "Merino")
    try store.addYarn(yarn, photoData: makeStoreJPEG(red: 0.4))
    let original = try #require(store.yarn(id: yarn.id)?.photoFilename)

    #expect(throws: YarnPhotoFileError.invalidImage) {
        try store.updateYarn(yarn, photoChange: .replace(Data("bad".utf8)))
    }

    #expect(store.yarn(id: yarn.id)?.photoFilename == original)
    #expect(FileManager.default.fileExists(atPath: yarnPhotoService.url(filename: original).path))
}

@MainActor @Test func successfulArchiveLoadReconcilesUnreferencedYarnPhotos() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let archiveURL = base.appendingPathComponent("projects.json")
    let yarnPhotoService = YarnPhotoFileService(directory: base.appendingPathComponent("yarn-photos"))
    let store = JSONProjectStore(url: archiveURL, yarnPhotoService: yarnPhotoService)
    let yarn = try StoredYarn(name: "Merino")
    try store.addYarn(yarn, photoData: makeStoreJPEG(red: 0.4))
    let referenced = try #require(store.yarn(id: yarn.id)?.photoFilename)
    let orphan = try yarnPhotoService.save(data: makeStoreJPEG(red: 0.2), yarnID: UUID())

    _ = JSONProjectStore(url: archiveURL, yarnPhotoService: yarnPhotoService)

    #expect(FileManager.default.fileExists(atPath: yarnPhotoService.url(filename: referenced).path))
    #expect(!FileManager.default.fileExists(atPath: yarnPhotoService.url(filename: orphan).path))
}

@MainActor @Test func unreadableArchiveNeverReconcilesYarnPhotosWithoutKnownReferences() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let archiveURL = base.appendingPathComponent("projects.json")
    let yarnPhotoService = YarnPhotoFileService(directory: base.appendingPathComponent("yarn-photos"))
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let candidate = try yarnPhotoService.save(data: makeStoreJPEG(red: 0.3), yarnID: UUID())
    try Data("not JSON".utf8).write(to: archiveURL, options: .atomic)

    let store = JSONProjectStore(url: archiveURL, yarnPhotoService: yarnPhotoService)

    #expect(store.loadError == .unreadableArchive)
    #expect(FileManager.default.fileExists(atPath: yarnPhotoService.url(filename: candidate).path))
}

@MainActor @Test func firstTrustworthyCommitReconcilesAnOrphanFromBeforeTheArchiveExisted() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let archiveURL = base.appendingPathComponent("projects.json")
    let yarnPhotoService = YarnPhotoFileService(directory: base.appendingPathComponent("yarn-photos"))
    let orphan = try yarnPhotoService.save(data: makeStoreJPEG(red: 0.3), yarnID: UUID())
    let store = JSONProjectStore(url: archiveURL, yarnPhotoService: yarnPhotoService)
    #expect(FileManager.default.fileExists(atPath: yarnPhotoService.url(filename: orphan).path))

    try store.addYarn(StoredYarn(name: "Merino"))

    #expect(!FileManager.default.fileExists(atPath: yarnPhotoService.url(filename: orphan).path))
}

@MainActor @Test func failedYarnPhotoAddRemovesUncommittedFile() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let archiveURL = base.appendingPathComponent("projects.json")
    let photosURL = base.appendingPathComponent("yarn-photos")
    let yarnPhotoService = YarnPhotoFileService(directory: photosURL)
    let store = JSONProjectStore(url: archiveURL, yarnPhotoService: yarnPhotoService)
    try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: true)

    #expect(throws: (any Error).self) {
        try store.addYarn(StoredYarn(name: "Merino"), photoData: makeStoreJPEG(red: 0.5))
    }

    #expect(store.yarns.isEmpty)
    #expect((try? FileManager.default.contentsOfDirectory(atPath: photosURL.path))?.isEmpty != false)
}

@MainActor @Test func failedYarnPhotoReplacementRemovesNewFileAndPreservesCommittedPhoto() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let archiveURL = base.appendingPathComponent("projects.json")
    let photosURL = base.appendingPathComponent("yarn-photos")
    let yarnPhotoService = YarnPhotoFileService(directory: photosURL)
    let store = JSONProjectStore(url: archiveURL, yarnPhotoService: yarnPhotoService)
    var yarn = try StoredYarn(name: "Merino")
    try store.addYarn(yarn, photoData: makeStoreJPEG(red: 0.6))
    let original = try #require(store.yarn(id: yarn.id)?.photoFilename)
    let committedFiles = try FileManager.default.contentsOfDirectory(atPath: photosURL.path)
    try yarn.rename(to: "Changed")
    try FileManager.default.removeItem(at: archiveURL)
    try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: false)

    #expect(throws: (any Error).self) {
        try store.updateYarn(yarn, photoChange: .replace(makeStoreJPEG(red: 0.2)))
    }

    #expect(store.yarn(id: yarn.id)?.name == "Merino")
    #expect(store.yarn(id: yarn.id)?.photoFilename == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: photosURL.path) == committedFiles)
    #expect(FileManager.default.fileExists(atPath: yarnPhotoService.url(filename: original).path))
}

@MainActor @Test func failedYarnPhotoRemovalPreservesCommittedPhoto() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let archiveURL = base.appendingPathComponent("projects.json")
    let yarnPhotoService = YarnPhotoFileService(directory: base.appendingPathComponent("yarn-photos"))
    let store = JSONProjectStore(url: archiveURL, yarnPhotoService: yarnPhotoService)
    let yarn = try StoredYarn(name: "Merino")
    try store.addYarn(yarn, photoData: makeStoreJPEG(red: 0.6))
    let committedYarn = try #require(store.yarn(id: yarn.id))
    let filename = try #require(committedYarn.photoFilename)
    try FileManager.default.removeItem(at: archiveURL)
    try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: false)

    #expect(throws: (any Error).self) {
        try store.updateYarn(committedYarn, photoChange: .remove)
    }

    #expect(store.yarn(id: yarn.id)?.photoFilename == filename)
    #expect(FileManager.default.fileExists(atPath: yarnPhotoService.url(filename: filename).path))
}

@MainActor @Test func failedYarnDeletePreservesCommittedPhoto() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let archiveURL = base.appendingPathComponent("projects.json")
    let yarnPhotoService = YarnPhotoFileService(directory: base.appendingPathComponent("yarn-photos"))
    let store = JSONProjectStore(url: archiveURL, yarnPhotoService: yarnPhotoService)
    let yarn = try StoredYarn(name: "Merino")
    try store.addYarn(yarn, photoData: makeStoreJPEG(red: 0.6))
    let filename = try #require(store.yarn(id: yarn.id)?.photoFilename)
    try FileManager.default.removeItem(at: archiveURL)
    try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: false)

    #expect(throws: (any Error).self) {
        try store.deleteYarn(id: yarn.id)
    }

    #expect(store.yarn(id: yarn.id)?.photoFilename == filename)
    #expect(FileManager.default.fileExists(atPath: yarnPhotoService.url(filename: filename).path))
}

@MainActor @Test func reloadReplacesPublishedProjectsAndYarns() throws {
    let fixture = try StoreBackupFixture.make()
    defer { fixture.cleanup() }
    let store = JSONProjectStore(url: fixture.archiveURL)
    try fixture.writeArchive(projectName: "Restored project", yarnName: "Restored yarn")

    try store.reloadFromDisk()

    #expect(store.projects.map(\.name) == ["Restored project"])
    #expect(store.yarns.map(\.name) == ["Restored yarn"])
    #expect(store.loadError == nil)
}

@MainActor @Test func successfulReloadAdvancesDataGenerationAndRejectsStalePatternMarkupSave() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appendingPathComponent("projects-v1.json")
    let store = JSONProjectStore(url: archiveURL)
    try store.add(name: "Original")
    let projectID = try #require(store.projects.first?.id)
    let pattern = PatternDocument(
        displayName: "Chart",
        kind: .pdf,
        storedFilename: "\(UUID().uuidString).pdf"
    )
    try store.addPattern(projectID: projectID, pattern: pattern)
    let staleGeneration = store.dataGeneration
    let staleDocument = PatternMarkupDocument(strokes: [
        .init(points: [.init(x: 0.1, y: 0.2)], color: .red, width: 0.006),
    ])
    try store.savePatternMarkup(
        staleDocument,
        projectID: projectID,
        patternID: pattern.id,
        pageIndex: 0,
        expectedDataGeneration: staleGeneration
    )

    let restoredDocument = PatternMarkupDocument(strokes: [
        .init(points: [.init(x: 0.8, y: 0.9)], color: .blue, width: 0.012),
    ])
    try PatternMarkupFileService(root: root.appendingPathComponent("Patterns"))
        .save(restoredDocument, projectID: projectID, patternID: pattern.id, pageIndex: 0)
    try store.reloadFromDisk()

    #expect(store.dataGeneration != staleGeneration)
    #expect(try store.loadPatternMarkup(
        projectID: projectID,
        patternID: pattern.id,
        pageIndex: 0
    ) == restoredDocument)
    #expect(throws: ProjectStoreError.staleDataGeneration) {
        try store.savePatternMarkup(
            staleDocument,
            projectID: projectID,
            patternID: pattern.id,
            pageIndex: 0,
            expectedDataGeneration: staleGeneration
        )
    }
    #expect(try store.loadPatternMarkup(
        projectID: projectID,
        patternID: pattern.id,
        pageIndex: 0
    ) == restoredDocument)
}

@MainActor @Test func failedReloadPreservesEveryPublishedValue() throws {
    let fixture = try StoreBackupFixture.make()
    defer { fixture.cleanup() }
    let store = JSONProjectStore(url: fixture.archiveURL)
    let projectsBefore = store.projects
    let yarnsBefore = store.yarns
    try Data("not JSON".utf8).write(to: fixture.archiveURL, options: .atomic)

    #expect(throws: ProjectStoreError.unreadableArchive) {
        try store.reloadFromDisk()
    }

    #expect(store.projects == projectsBefore)
    #expect(store.yarns == yarnsBefore)
    #expect(store.loadError == .unreadableArchive)
}

@MainActor @Test func reloadRejectsFutureProjectArchiveWithoutDowngradingIt() throws {
    let fixture = try StoreBackupFixture.make()
    defer { fixture.cleanup() }
    let store = fixture.store
    let projectsBefore = store.projects
    let future = ProjectArchive(
        version: ProjectArchive.currentVersion + 1,
        projects: projectsBefore,
        yarns: store.yarns
    )
    let futureData = try JSONEncoder().encode(future)
    try futureData.write(to: fixture.archiveURL, options: .atomic)

    #expect(throws: ProjectStoreError.unreadableArchive) {
        try store.reloadFromDisk()
    }

    #expect(store.projects == projectsBefore)
    #expect(try Data(contentsOf: fixture.archiveURL) == futureData)
    #expect(store.loadError == .unreadableArchive)
}

@MainActor @Test func freshLiveStoreCanRelaunchBeforeFirstProjectAndThenPersist() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let first = JSONProjectStore.live(baseDirectory: base)
    #expect(first.loadError == nil)
    #expect(first.projects.isEmpty)
    let second = JSONProjectStore.live(baseDirectory: base)
    #expect(second.loadError == nil)
    #expect(second.projects.isEmpty)
    try second.add(name: "First project")
    let third = JSONProjectStore.live(baseDirectory: base)
    #expect(third.loadError == nil)
    #expect(third.projects.map(\.name) == ["First project"])
}

@MainActor @Test func liveStoreRecoversRollbackWhenLiveRootIsMissing() throws {
    let fixture = try StoreLaunchRecoveryFixture.interruptedAfterLiveRename()
    defer { fixture.cleanup() }

    let store = JSONProjectStore.live(baseDirectory: fixture.applicationSupport)

    #expect(store.projects.map(\.name) == ["Original project"])
    #expect(store.loadError == nil)
    #expect(FileManager.default.fileExists(atPath: fixture.liveRoot.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.rollbackRoot.path))
}

@MainActor @Test func validLiveRootWinsOverStaleRollback() throws {
    let fixture = try StoreLaunchRecoveryFixture.validLiveWithStaleRollback()
    defer { fixture.cleanup() }

    let store = JSONProjectStore.live(baseDirectory: fixture.applicationSupport)

    #expect(store.projects.map(\.name) == ["Installed project"])
    #expect(store.loadError == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.rollbackRoot.path))
}

@MainActor @Test func backupStageRejectsInvalidLegacyPatternBeforeInstall() throws {
    let fixture = try StoreLaunchRecoveryFixture.validLiveOnly()
    defer { fixture.cleanup() }
    let originalArchiveURL = fixture.liveRoot.appendingPathComponent("projects-v1.json")

    var replacementProject = try StoredProject(name: "Replacement project")
    let legacyPatternID = UUID()
    let legacyPattern = PatternDocument(
        id: legacyPatternID,
        displayName: "Broken legacy pattern",
        kind: .pdf,
        storedFilename: "\(legacyPatternID.uuidString).pdf"
    )
    replacementProject.addPattern(legacyPattern)
    let replacementArchive = ProjectArchive(
        version: 9,
        projects: [replacementProject]
    )
    try JSONEncoder().encode(replacementArchive).write(
        to: originalArchiveURL,
        options: .atomic
    )
    let brokenPatternURL = fixture.liveRoot
        .appendingPathComponent("Patterns/\(replacementProject.id.uuidString)")
        .appendingPathComponent(legacyPattern.storedFilename)
    try FileManager.default.createDirectory(
        at: brokenPatternURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("not a PDF".utf8).write(to: brokenPatternURL)

    let service = KnitNoteBackupService(
        liveRoot: fixture.liveRoot,
        workRoot: fixture.workRoot
    )
    let package = try service.createPackage(appVersion: "1.0")
    #expect(throws: PatternLibraryMigrationError.invalidLegacyFile) {
        _ = try service.stagePackage(at: package)
    }
}

@MainActor @Test func launchCommitsInstalledLegacyBackupAfterMigrationPersists() throws {
    let fixture = try StoreLaunchRecoveryFixture.validLiveOnly()
    defer { fixture.cleanup() }
    let archiveURL = fixture.liveRoot.appendingPathComponent("projects-v1.json")

    var replacementProject = try StoredProject(name: "Migrated replacement")
    let patternID = UUID()
    let legacyPattern = PatternDocument(
        id: patternID,
        displayName: "Valid legacy pattern",
        kind: .pdf,
        storedFilename: "\(patternID.uuidString).pdf"
    )
    replacementProject.addPattern(legacyPattern)
    try JSONEncoder().encode(ProjectArchive(
        version: 9,
        projects: [replacementProject]
    )).write(to: archiveURL, options: .atomic)
    let patternURL = fixture.liveRoot
        .appendingPathComponent("Patterns/\(replacementProject.id.uuidString)")
        .appendingPathComponent(legacyPattern.storedFilename)
    try FileManager.default.createDirectory(
        at: patternURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try makeStorePatternPDF(at: patternURL)
    let service = KnitNoteBackupService(
        liveRoot: fixture.liveRoot,
        workRoot: fixture.workRoot
    )
    let staged = try service.stagePackage(
        at: service.createPackage(appVersion: "1.0")
    )

    try FileManager.default.removeItem(at: fixture.liveRoot)
    try FileManager.default.createDirectory(
        at: fixture.liveRoot,
        withIntermediateDirectories: true
    )
    try JSONEncoder().encode(ProjectArchive(
        version: ProjectArchive.currentVersion,
        projects: [try StoredProject(name: "Original")]
    )).write(to: archiveURL, options: .atomic)
    let installation = try service.install(staged)

    let store = JSONProjectStore.live(baseDirectory: fixture.applicationSupport)

    #expect(store.projects.map(\.name) == ["Migrated replacement"])
    #expect(store.patternAssets.count == 1)
    #expect(store.loadError == nil)
    let persisted = try JSONDecoder().decode(
        ProjectArchive.self,
        from: Data(contentsOf: archiveURL)
    )
    #expect(persisted.version == ProjectArchive.currentVersion)
    #expect(!FileManager.default.fileExists(atPath: installation.rollbackRoot.path))
}

@MainActor @Test func liveStoreRemovesAbandonedExportAndStagedArtifacts() throws {
    let fixture = try StoreLaunchRecoveryFixture.validLiveWithAbandonedArtifacts()
    defer { fixture.cleanup() }

    let store = JSONProjectStore.live(baseDirectory: fixture.applicationSupport)

    #expect(store.projects.map(\.name) == ["Current project"])
    #expect(!FileManager.default.fileExists(atPath: fixture.exportRoot.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.stagedRoot.path))
    #expect(FileManager.default.fileExists(atPath: fixture.unrecognizedRoot.path))
}

@MainActor @Test func failedLiveRecoveryPreservesOnlyValidRollback() throws {
    let fixture = try StoreLaunchRecoveryFixture.invalidLiveWithValidRollback()
    defer { fixture.cleanup() }

    let store = JSONProjectStore.live(baseDirectory: fixture.applicationSupport)

    #expect(store.projects.isEmpty)
    #expect(store.loadError == .unreadableArchive)
    #expect(FileManager.default.fileExists(atPath: fixture.liveRoot.path))
    #expect(FileManager.default.fileExists(atPath: fixture.rollbackRoot.path))
}

@MainActor @Test func missingLiveWithTwoValidRollbacksPreservesBoth() throws {
    let fixture = try StoreLaunchRecoveryFixture.interruptedAfterLiveRename()
    defer { fixture.cleanup() }
    let secondRollback = fixture.workRoot.appendingPathComponent(
        "Rollback-\(UUID().uuidString)",
        isDirectory: true
    )
    try fixture.writeArchive(projectName: "Other original", to: secondRollback)

    let store = JSONProjectStore.live(baseDirectory: fixture.applicationSupport)

    #expect(store.projects.isEmpty)
    #expect(store.loadError == .unreadableArchive)
    #expect(!FileManager.default.fileExists(atPath: fixture.liveRoot.path))
    #expect(FileManager.default.fileExists(atPath: fixture.rollbackRoot.path))
    #expect(FileManager.default.fileExists(atPath: secondRollback.path))
}

@MainActor @Test func validLiveRootPreservesMalformedRollbackName() throws {
    let fixture = try StoreLaunchRecoveryFixture.validLiveOnly()
    defer { fixture.cleanup() }
    let malformedRollback = fixture.workRoot.appendingPathComponent(
        "Rollback-not-a-uuid",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: malformedRollback,
        withIntermediateDirectories: true
    )
    let marker = malformedRollback.appendingPathComponent("preserve.txt")
    try Data("preserve".utf8).write(to: marker)

    let store = JSONProjectStore.live(baseDirectory: fixture.applicationSupport)

    #expect(store.projects.map(\.name) == ["Current project"])
    #expect(store.loadError == nil)
    #expect(FileManager.default.fileExists(atPath: malformedRollback.path))
    #expect(FileManager.default.fileExists(atPath: marker.path))
}

@MainActor @Test func launchCleanupPreservesGeneratedSymlinksAndNonDirectories() throws {
    let fixture = try StoreLaunchRecoveryFixture.validLiveOnly()
    defer { fixture.cleanup() }
    let outsideTarget = fixture.root.appendingPathComponent(
        "OutsideArtifactTarget",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: outsideTarget, withIntermediateDirectories: true)
    let outsideMarker = outsideTarget.appendingPathComponent("preserve.txt")
    try Data("outside".utf8).write(to: outsideMarker)

    let symlinkArtifacts = [
        fixture.workRoot.appendingPathComponent(
            "Rollback-\(UUID().uuidString)",
            isDirectory: true
        ),
        fixture.workRoot.appendingPathComponent(
            "\(UUID().uuidString).knitnote-backup",
            isDirectory: true
        ),
        fixture.workRoot.appendingPathComponent(
            "Staged-\(UUID().uuidString)",
            isDirectory: true
        ),
    ]
    for artifact in symlinkArtifacts {
        try FileManager.default.createSymbolicLink(
            at: artifact,
            withDestinationURL: outsideTarget
        )
    }
    let fileArtifacts = [
        fixture.workRoot.appendingPathComponent("Rollback-\(UUID().uuidString)"),
        fixture.workRoot.appendingPathComponent("\(UUID().uuidString).knitnote-backup"),
        fixture.workRoot.appendingPathComponent("Staged-\(UUID().uuidString)"),
    ]
    for artifact in fileArtifacts {
        try Data("not a directory".utf8).write(to: artifact)
    }

    let store = JSONProjectStore.live(baseDirectory: fixture.applicationSupport)

    #expect(store.projects.map(\.name) == ["Current project"])
    #expect(store.loadError == nil)
    for artifact in symlinkArtifacts + fileArtifacts {
        #expect(FileManager.default.fileExists(atPath: artifact.path))
    }
    #expect(FileManager.default.fileExists(atPath: outsideMarker.path))
}

@MainActor @Test func symbolicWorkRootFailsVisiblyAndPreservesOutsideTarget() throws {
    let fixture = try StoreLaunchRecoveryFixture.validLiveOnly()
    defer { fixture.cleanup() }
    try FileManager.default.removeItem(at: fixture.workRoot)
    let outsideWorkRoot = fixture.root.appendingPathComponent(
        "OutsideWorkRoot",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: outsideWorkRoot,
        withIntermediateDirectories: true
    )
    let outsideArtifact = outsideWorkRoot.appendingPathComponent(
        "\(UUID().uuidString).knitnote-backup",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: outsideArtifact,
        withIntermediateDirectories: true
    )
    let marker = outsideArtifact.appendingPathComponent("preserve.txt")
    try Data("outside".utf8).write(to: marker)
    try FileManager.default.createSymbolicLink(
        at: fixture.workRoot,
        withDestinationURL: outsideWorkRoot
    )

    let store = JSONProjectStore.live(baseDirectory: fixture.applicationSupport)

    #expect(store.projects.isEmpty)
    #expect(store.loadError == .unreadableArchive)
    #expect(FileManager.default.fileExists(atPath: fixture.liveRoot.path))
    #expect(FileManager.default.fileExists(atPath: marker.path))
    let workValues = try fixture.workRoot.resourceValues(forKeys: [.isSymbolicLinkKey])
    #expect(workValues.isSymbolicLink == true)
}

@Suite(.serialized) @MainActor struct StoreBackupTransactionGateTests {
@MainActor @Test(arguments: [false, true])
func exportSerializesProjectYarnAndJournalMutations(delayedStart: Bool) async throws {
    let blocker = StoreOperationBlocker()
    let fixture = try StoreBackupFixture.make(metadataBlocker: blocker)
    defer {
        blocker.resume()
        fixture.cleanup()
    }
    let store = fixture.store
    let project = try #require(store.projects.first)
    let export = Task { @MainActor in
        if delayedStart { try await Task.sleep(for: .seconds(11)) }
        blocker.startObservingOperation()
        defer { blocker.finishObservation(reachedBlock: false) }
        return try await store.exportBackup(appVersion: "1.0")
    }
    do {
        try #require(await blocker.waitForObservedBlock())
    } catch {
        blocker.resume()
        export.cancel()
        _ = try? await export.value
        throw error
    }

    #expect(store.isDataOperationInProgress)
    #expect(throws: KnitNoteBackupError.operationInProgress) {
        try store.add(name: "Blocked project")
    }
    #expect(throws: KnitNoteBackupError.operationInProgress) {
        try store.rename(id: project.id, to: "Blocked rename")
    }
    #expect(throws: KnitNoteBackupError.operationInProgress) {
        try store.addYarn(StoredYarn(name: "Blocked yarn"))
    }
    #expect(throws: KnitNoteBackupError.operationInProgress) {
        try store.savePatternMarkup(
            PatternMarkupDocument(strokes: [
                .init(points: [.init(x: 0.2, y: 0.3)], color: .green, width: 0.006),
            ]),
            projectID: project.id,
            patternID: UUID(),
            pageIndex: 0,
            expectedDataGeneration: store.dataGeneration
        )
    }
    await #expect(throws: KnitNoteBackupError.operationInProgress) {
        try await store.addJournalEntry(
            projectID: project.id,
            photoData: try makeStoreJPEG(red: 0.3),
            caption: nil
        )
    }
    await #expect(throws: KnitNoteBackupError.operationInProgress) {
        _ = try await store.exportBackup(appVersion: "1.0")
    }

    blocker.resume()
    let artifact = try await export.value
    #expect(!store.isDataOperationInProgress)
    try store.add(name: "Allowed afterward")
    store.cleanupBackupArtifact(at: artifact)
    #expect(!FileManager.default.fileExists(atPath: artifact.path))
}

@MainActor @Test func activePatternImportRejectsExportAndRestore() async throws {
    let patternBlocker = StoreOperationBlocker()
    let fixture = try StoreBackupFixture.make(patternBlocker: patternBlocker)
    defer {
        patternBlocker.resume()
        fixture.cleanup()
    }
    let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)
    let projectID = try #require(fixture.store.projects.first?.id)
    let source = fixture.root.appendingPathComponent("chart.pdf")
    try makeStorePatternPDF(at: source)
    let patternImport = Task { @MainActor in
        try await fixture.store.importPattern(from: source, projectID: projectID)
    }
    #expect(await Task.detached { patternBlocker.waitUntilBlocked() }.value)

    await #expect(throws: KnitNoteBackupError.operationInProgress) {
        _ = try await fixture.store.exportBackup(appVersion: "1.0")
    }
    await #expect(throws: KnitNoteBackupError.operationInProgress) {
        try await fixture.store.restoreBackup(staged)
    }
    #expect(!fixture.store.isDataOperationInProgress)

    patternBlocker.resume()
    _ = try await patternImport.value
    fixture.store.cancelBackupRestore(staged)
}

@MainActor @Test func projectPatternEnqueueRejectsExportAndRestoreUntilPublicationCompletes() async throws {
    let blocker = StoreOperationBlocker()
    let fixture = try StoreBackupFixture.make(patternInboxBlocker: blocker)
    defer {
        blocker.resume()
        fixture.cleanup()
    }
    let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)
    let projectID = try #require(fixture.store.projects.first?.id)
    let source = fixture.root.appendingPathComponent("project-pattern.pdf")
    try makeStorePatternPDF(at: source)
    let patternImport = Task { @MainActor in
        try await fixture.store.importPatternFromProject(source, projectID: projectID)
    }
    #expect(await Task.detached { blocker.waitUntilBlocked() }.value)

    await #expect(throws: KnitNoteBackupError.operationInProgress) {
        _ = try await fixture.store.exportBackup(appVersion: "1.0")
    }
    await #expect(throws: KnitNoteBackupError.operationInProgress) {
        try await fixture.store.restoreBackup(staged)
    }
    #expect(!fixture.store.isDataOperationInProgress)

    blocker.resume()
    _ = try await patternImport.value

    let artifact = try await fixture.store.exportBackup(appVersion: "1.0")
    fixture.store.cleanupBackupArtifact(at: artifact)
    fixture.store.cancelBackupRestore(staged)
}

@MainActor @Test func failedProjectPatternEnqueueReleasesTheBackupGate() async throws {
    let blocker = StoreOperationBlocker()
    let fixture = try StoreBackupFixture.make(
        patternInboxBlocker: blocker,
        failPatternInboxMove: true
    )
    defer {
        blocker.resume()
        fixture.cleanup()
    }
    let projectID = try #require(fixture.store.projects.first?.id)
    let source = fixture.root.appendingPathComponent("failed-project-pattern.pdf")
    try makeStorePatternPDF(at: source)
    let patternImport = Task { @MainActor in
        try await fixture.store.importPatternFromProject(source, projectID: projectID)
    }
    #expect(await Task.detached { blocker.waitUntilBlocked() }.value)

    await #expect(throws: KnitNoteBackupError.operationInProgress) {
        _ = try await fixture.store.exportBackup(appVersion: "1.0")
    }
    blocker.resume()
    await #expect(throws: (any Error).self) {
        try await patternImport.value
    }

    let artifact = try await fixture.store.exportBackup(appVersion: "1.0")
    fixture.store.cleanupBackupArtifact(at: artifact)
}

@MainActor @Test func cancelledProjectPatternEnqueueReleasesTheBackupGateWithoutPublishing() async throws {
    let blocker = StoreOperationBlocker()
    let fixture = try StoreBackupFixture.make(patternInboxBlocker: blocker)
    defer {
        blocker.resume()
        fixture.cleanup()
    }
    let projectID = try #require(fixture.store.projects.first?.id)
    let source = fixture.root.appendingPathComponent("cancelled-project-pattern.pdf")
    try makeStorePatternPDF(at: source)
    let patternImport = Task { @MainActor in
        try await fixture.store.importPatternFromProject(source, projectID: projectID)
    }
    #expect(await Task.detached { blocker.waitUntilBlocked() }.value)

    patternImport.cancel()
    blocker.resume()
    await #expect(throws: CancellationError.self) {
        try await patternImport.value
    }
    #expect(fixture.store.patterns.isEmpty)
    #expect(fixture.store.patternUsages.isEmpty)

    let artifact = try await fixture.store.exportBackup(appVersion: "1.0")
    fixture.store.cleanupBackupArtifact(at: artifact)
}

@MainActor @Test(arguments: [
    KnitNoteBackupReplacementStep.beforeLiveMove,
    .afterLiveMove,
    .afterStagedMove,
])
func restoreRejectsPatternWritesAtEveryReplacementStep(
    _ blockedStep: KnitNoteBackupReplacementStep
) async throws {
    let blocker = StoreOperationBlocker()
    let fixture = try StoreBackupFixture.make(
        replacementBlocker: blocker,
        blockedReplacementStep: blockedStep
    )
    defer {
        blocker.resume()
        fixture.cleanup()
    }
    let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)
    let project = try #require(fixture.store.projects.first)
    let source = fixture.root.appendingPathComponent("blocked.pdf")
    try makeStorePatternPDF(at: source)
    let restore = Task { @MainActor in
        try await fixture.store.restoreBackup(staged)
    }
    #expect(await Task.detached { blocker.waitUntilBlocked() }.value)

    #expect(throws: KnitNoteBackupError.operationInProgress) {
        try fixture.store.savePatternMarkup(
            PatternMarkupDocument(strokes: [
                .init(points: [.init(x: 0.4, y: 0.5)], color: .black, width: 0.006),
            ]),
            projectID: project.id,
            patternID: UUID(),
            pageIndex: 0,
            expectedDataGeneration: fixture.store.dataGeneration
        )
    }
    #expect(throws: KnitNoteBackupError.operationInProgress) {
        try fixture.store.deletePattern(projectID: project.id, id: UUID())
    }
    await #expect(throws: KnitNoteBackupError.operationInProgress) {
        _ = try await fixture.store.importPattern(from: source, projectID: project.id)
    }

    blocker.resume()
    try await restore.value
    #expect(fixture.store.projects.map(\.name) == ["replacement"])
}

@MainActor @Test func activeJournalPhotoTransactionRejectsExportAndRestore() async throws {
    let journalBlocker = StoreOperationBlocker()
    let fixture = try StoreBackupFixture.make(journalBlocker: journalBlocker)
    defer {
        journalBlocker.resume()
        fixture.cleanup()
    }
    let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)
    let projectID = try #require(fixture.store.projects.first?.id)
    let journalAddition = Task { @MainActor in
        try await fixture.store.addJournalEntry(
            projectID: projectID,
            photoData: try makeStoreJPEG(red: 0.6),
            caption: "active"
        )
    }
    #expect(await Task.detached { journalBlocker.waitUntilBlocked() }.value)

    await #expect(throws: KnitNoteBackupError.operationInProgress) {
        _ = try await fixture.store.exportBackup(appVersion: "1.0")
    }
    await #expect(throws: KnitNoteBackupError.operationInProgress) {
        try await fixture.store.restoreBackup(staged)
    }
    #expect(!fixture.store.isDataOperationInProgress)

    journalBlocker.resume()
    try await journalAddition.value
    fixture.store.cancelBackupRestore(staged)
}

@MainActor @Test func prepareBackupRestoreReturnsIndependentOwnedCopyAndCancelRemovesIt() async throws {
    let blocker = StoreOperationBlocker()
    let fixture = try StoreBackupFixture.make(stageBlocker: blocker)
    defer {
        blocker.resume()
        fixture.cleanup()
    }

    let preparation = Task { @MainActor in
        try await fixture.store.prepareBackupRestore(
            from: fixture.replacementPackage
        )
    }
    #expect(await Task.detached { blocker.waitUntilBlocked() }.value)
    #expect(!fixture.store.isDataOperationInProgress)
    try fixture.store.add(name: "Allowed during preparation")

    blocker.resume()
    let staged = try await preparation.value
    try FileManager.default.removeItem(at: fixture.replacementPackage)

    #expect(staged.root.deletingLastPathComponent() == fixture.workRoot)
    #expect(FileManager.default.fileExists(
        atPath: staged.root.appendingPathComponent("Data/projects-v1.json").path
    ))
    fixture.store.cancelBackupRestore(staged)
    #expect(!FileManager.default.fileExists(atPath: staged.root.path))
}

@MainActor @Test func publicPrepareBackupRestoreRejectsInvalidVersionThirteenReminderWithoutPublishing() async throws {
    let fixture = try StoreBackupFixture.make()
    defer { fixture.cleanup() }
    let packageArchiveURL = fixture.replacementPackage.appendingPathComponent("Data/projects-v1.json")
    let packaged = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: packageArchiveURL))
    let project = try #require(packaged.projects.first)
    let counterID = project.counters[0].id
    var legacy = try #require(CounterReminder(
        draft: .repeating(interval: Int.max / 2, limit: nil, message: "Overflow"),
        anchorValue: 0,
        id: UUID()
    ))
    _ = legacy.applyUpwardChange(to: Int.max - 1)
    let legacyProject = try StoredProject(
        id: project.id,
        name: project.name,
        counters: [ProjectCounter(id: counterID, defaultOrdinal: 1, reminder: legacy)]
    )
    try JSONEncoder().encode(ProjectArchive(
        version: 13,
        projects: [legacyProject],
        yarns: packaged.yarns
    )).write(
        to: packageArchiveURL,
        options: .atomic
    )
    let manifestURL = fixture.replacementPackage.appendingPathComponent("manifest.json")
    let manifest = try JSONDecoder().decode(KnitNoteBackupManifest.self, from: Data(contentsOf: manifestURL))
    try JSONEncoder().encode(KnitNoteBackupManifest(
        formatVersion: 1,
        createdAt: manifest.createdAt,
        appVersion: manifest.appVersion,
        projectCount: manifest.projectCount,
        yarnCount: manifest.yarnCount
    )).write(to: manifestURL, options: .atomic)
    let bytesBefore = try Data(contentsOf: fixture.archiveURL)
    let projectsBefore = fixture.store.projects

    await #expect(throws: KnitNoteBackupError.invalidArchive) {
        _ = try await fixture.store.prepareBackupRestore(from: fixture.replacementPackage)
    }

    #expect(try Data(contentsOf: fixture.archiveURL) == bytesBefore)
    #expect(fixture.store.projects == projectsBefore)
}

@MainActor @Test func restoreSerializesMutationReloadsAndCommits() async throws {
    let blocker = StoreOperationBlocker()
    let fixture = try StoreBackupFixture.make(replacementBlocker: blocker)
    defer {
        blocker.resume()
        fixture.cleanup()
    }
    let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)
    let restore = Task { @MainActor in
        try await fixture.store.restoreBackup(staged)
    }
    #expect(await Task.detached { blocker.waitUntilBlocked() }.value)

    #expect(fixture.store.isDataOperationInProgress)
    #expect(throws: KnitNoteBackupError.operationInProgress) {
        try fixture.store.add(name: "Blocked during restore")
    }
    blocker.resume()
    try await restore.value

    #expect(fixture.store.projects.map(\.name) == ["replacement"])
    #expect(fixture.store.yarns.map(\.name) == ["replacement yarn"])
    #expect(!fixture.store.isDataOperationInProgress)
    #expect(try fixture.rollbackRoots().isEmpty)
}

@MainActor @Test func publicCleanupAndCancelCannotDeleteActiveRestoreRollback() async throws {
    let blocker = StoreOperationBlocker()
    let fixture = try StoreBackupFixture.make(replacementBlocker: blocker)
    defer {
        blocker.resume()
        fixture.cleanup()
    }
    let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)
    let restore = Task { @MainActor in
        try await fixture.store.restoreBackup(staged)
    }
    #expect(await Task.detached { blocker.waitUntilBlocked() }.value)
    let rollbackRoot = try #require(fixture.rollbackRoots().first)
    let forgedCancellation = StagedKnitNoteBackup(
        root: rollbackRoot,
        preview: staged.preview
    )

    fixture.store.cleanupBackupArtifact(at: rollbackRoot)
    fixture.store.cancelBackupRestore(forgedCancellation)

    #expect(FileManager.default.fileExists(atPath: rollbackRoot.path))
    blocker.resume()
    try await restore.value
    #expect(fixture.store.projects.map(\.name) == ["replacement"])
    #expect(!FileManager.default.fileExists(atPath: rollbackRoot.path))
}
}

@MainActor @Test func restoreReloadFailureRollsBackAndReloadsOriginal() async throws {
    let fixture = try StoreBackupFixture.make(corruptInstalledArchive: true)
    defer { fixture.cleanup() }
    let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)

    await #expect(throws: KnitNoteBackupError.installFailedOriginalPreserved) {
        try await fixture.store.restoreBackup(staged)
    }

    #expect(fixture.store.projects.map(\.name) == ["original"])
    #expect(fixture.store.yarns.map(\.name) == ["original yarn"])
    #expect(try fixture.diskProjectName() == "original")
    #expect(try fixture.rollbackRoots().isEmpty)
    #expect(!fixture.store.isDataOperationInProgress)
}

@MainActor @Test func restoreSucceedsWhenCommitCleanupPartiallyDeletesThenFails() async throws {
    let fixture = try StoreBackupFixture.make(partialCommitCleanupFailure: true)
    defer { fixture.cleanup() }
    let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)

    try await fixture.store.restoreBackup(staged)

    #expect(fixture.store.projects.map(\.name) == ["replacement"])
    #expect(fixture.store.yarns.map(\.name) == ["replacement yarn"])
    #expect(try fixture.diskProjectName() == "replacement")
    #expect(try fixture.rollbackRoots().isEmpty)
    #expect(try fixture.cleanupRoots().count == 1)
    try fixture.store.add(name: "Usable after deferred cleanup")
    #expect(fixture.store.projects.contains { $0.name == "Usable after deferred cleanup" })
}

@MainActor @Test func restoreRevalidatesOwnedStageImmediatelyBeforeInstall() async throws {
    let fixture = try StoreBackupFixture.make()
    defer { fixture.cleanup() }
    let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)
    try Data("not JSON".utf8).write(
        to: staged.root.appendingPathComponent("Data/projects-v1.json"),
        options: .atomic
    )

    await #expect(throws: KnitNoteBackupError.invalidArchive) {
        try await fixture.store.restoreBackup(staged)
    }

    #expect(fixture.store.projects.map(\.name) == ["original"])
    #expect(try fixture.diskProjectName() == "original")
    #expect(try fixture.rollbackRoots().isEmpty)
    #expect(!fixture.store.isDataOperationInProgress)
}

@MainActor @Test func restoreRejectsStagedRootSymlinkBeforeTouchingLive() async throws {
    let fixture = try StoreBackupFixture.make()
    defer { fixture.cleanup() }
    let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)
    let alternate = try fixture.service.stagePackage(at: fixture.replacementPackage)
    try FileManager.default.removeItem(at: staged.root)
    try FileManager.default.createSymbolicLink(
        at: staged.root,
        withDestinationURL: alternate.root
    )

    await #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
        try await fixture.store.restoreBackup(staged)
    }

    #expect(fixture.store.projects.map(\.name) == ["original"])
    #expect(try fixture.diskProjectName() == "original")
    #expect(try fixture.rollbackRoots().isEmpty)
    #expect(!fixture.store.isDataOperationInProgress)
}

@MainActor @Test func restoreReportsRollbackFailureWhenOriginalCannotBeReinstalled() async throws {
    let fixture = try StoreBackupFixture.make(
        corruptInstalledArchive: true,
        failRollback: true
    )
    defer { fixture.cleanup() }
    let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)

    await #expect(throws: KnitNoteBackupError.rollbackFailed) {
        try await fixture.store.restoreBackup(staged)
    }

    #expect(fixture.store.projects.map(\.name) == ["original"])
    #expect(try fixture.rollbackRoots().count == 1)
    #expect(!fixture.store.isDataOperationInProgress)
}

private struct StoreLaunchRecoveryFixture {
    let root: URL
    let applicationSupport: URL
    let liveRoot: URL
    let workRoot: URL
    let rollbackRoot: URL
    let exportRoot: URL
    let stagedRoot: URL
    let unrecognizedRoot: URL

    static func interruptedAfterLiveRename() throws -> Self {
        let fixture = try make()
        try writeArchive(projectName: "Original project", to: fixture.rollbackRoot)
        return fixture
    }

    static func validLiveWithStaleRollback() throws -> Self {
        let fixture = try make()
        try writeArchive(projectName: "Installed project", to: fixture.liveRoot)
        try writeArchive(projectName: "Original project", to: fixture.rollbackRoot)
        return fixture
    }

    static func validLiveOnly() throws -> Self {
        let fixture = try make()
        try writeArchive(projectName: "Current project", to: fixture.liveRoot)
        return fixture
    }

    static func validLiveWithAbandonedArtifacts() throws -> Self {
        let fixture = try make()
        try writeArchive(projectName: "Current project", to: fixture.liveRoot)
        for artifact in [fixture.exportRoot, fixture.stagedRoot, fixture.unrecognizedRoot] {
            try FileManager.default.createDirectory(
                at: artifact,
                withIntermediateDirectories: true
            )
            try Data("partial".utf8).write(to: artifact.appendingPathComponent("partial.tmp"))
        }
        return fixture
    }

    static func invalidLiveWithValidRollback() throws -> Self {
        let fixture = try make()
        try FileManager.default.createDirectory(
            at: fixture.liveRoot,
            withIntermediateDirectories: true
        )
        try Data("not JSON".utf8).write(
            to: fixture.liveRoot.appendingPathComponent("projects-v1.json")
        )
        try writeArchive(projectName: "Only recoverable project", to: fixture.rollbackRoot)
        return fixture
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeArchive(projectName: String, to root: URL) throws {
        try Self.writeArchive(projectName: projectName, to: root)
    }

    private static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let applicationSupport = root.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        let liveRoot = applicationSupport.appendingPathComponent("KnitNote", isDirectory: true)
        let workRoot = applicationSupport.appendingPathComponent(
            ".KnitNote-BackupWork",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        return Self(
            root: root,
            applicationSupport: applicationSupport,
            liveRoot: liveRoot,
            workRoot: workRoot,
            rollbackRoot: workRoot.appendingPathComponent(
                "Rollback-\(UUID().uuidString)",
                isDirectory: true
            ),
            exportRoot: workRoot.appendingPathComponent(
                "\(UUID().uuidString).knitnote-backup",
                isDirectory: true
            ),
            stagedRoot: workRoot.appendingPathComponent(
                "Staged-\(UUID().uuidString)",
                isDirectory: true
            ),
            unrecognizedRoot: workRoot.appendingPathComponent(
                "Staged-not-a-uuid",
                isDirectory: true
            )
        )
    }

    private static func writeArchive(projectName: String, to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = ProjectArchive(
            version: 9,
            projects: [try StoredProject(name: projectName)],
            yarns: []
        )
        try JSONEncoder().encode(archive).write(
            to: root.appendingPathComponent("projects-v1.json"),
            options: .atomic
        )
    }
}

@Suite(.serialized) @MainActor struct StoreBackupSessionDrainTests {
    @Test func backupWaitRetainsItsPublicOpenSessionError() async throws {
        let fixture = try StoreBackupFixture.make()
        defer { fixture.cleanup() }
        await #expect(throws: BackupSessionDrainError.sessionStillActive) {
            try await fixture.store.waitForBackupOperationsAfterRevocation()
        }
        await #expect(throws: StoreSessionDrainError.sessionStillActive) {
            try await fixture.store.waitForTrackedBackgroundWritesAfterRevocation()
        }
    }

    @Test func revokedBackupEntriesAndCleanupLeaveOwnedDataUntouched() async throws {
        let fixture = try StoreBackupFixture.make()
        defer { fixture.cleanup() }
        let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)
        let before = try Data(contentsOf: fixture.archiveURL)
        let workBefore = try backupEvidenceBytes(fixture.workRoot)
        fixture.store.revokeSessionWrites()
        await #expect(throws: StoreSessionAccessError.revoked) {
            _ = try await fixture.store.exportBackup(appVersion: "1.0")
        }
        await #expect(throws: StoreSessionAccessError.revoked) {
            _ = try await fixture.store.prepareBackupRestore(from: fixture.replacementPackage)
        }
        await #expect(throws: StoreSessionAccessError.revoked) {
            try await fixture.store.restoreBackup(staged)
        }
        fixture.store.cancelBackupRestore(staged)
        fixture.store.cleanupBackupArtifact(at: fixture.replacementPackage)
        #expect(FileManager.default.fileExists(atPath: staged.root.path))
        #expect(FileManager.default.fileExists(atPath: fixture.replacementPackage.path))
        #expect(try Data(contentsOf: fixture.archiveURL) == before)
        #expect(try backupEvidenceBytes(fixture.workRoot) == workBefore)
        try await fixture.store.waitForBackupOperationsAfterRevocation()
    }

    @Test(arguments: [false, true])
    func lateBackupArtifactsStayOwnedAndAreNotReturned(prepare: Bool) async throws {
        let blocker = StoreOperationBlocker()
        let fixture = try StoreBackupFixture.make(
            metadataBlocker: prepare ? nil : blocker,
            stageBlocker: prepare ? blocker : nil
        )
        defer { blocker.resume(); fixture.cleanup() }
        let cancellationObserved = AsyncStream<Void>.makeStream()
        let operation = Task { @MainActor in
            blocker.startObservingOperation()
            defer { blocker.finishObservation(reachedBlock: false) }
            try await withTaskCancellationHandler {
                if prepare {
                    _ = try await fixture.store.prepareBackupRestore(
                        from: fixture.replacementPackage
                    )
                } else {
                    _ = try await fixture.store.exportBackup(appVersion: "1.0")
                }
            } onCancel: {
                cancellationObserved.continuation.yield(())
                cancellationObserved.continuation.finish()
            }
        }
        do {
            try #require(await blocker.waitForObservedBlock())
        } catch {
            blocker.resume()
            _ = try? await operation.value
            throw error
        }
        operation.cancel()
        var cancellationIterator = cancellationObserved.stream.makeAsyncIterator()
        try #require(await cancellationIterator.next() != nil)
        fixture.store.cleanupBackupArtifact(at: fixture.replacementPackage)
        #expect(FileManager.default.fileExists(atPath: fixture.replacementPackage.path))
        fixture.store.revokeSessionWrites()
        let ready = AsyncStream<Void>.makeStream()
        var ended = false
        let drain = Task { @MainActor in
            ready.continuation.yield(())
            try await fixture.store.waitForBackupOperationsAfterRevocation()
            ended = true
        }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(!ended)
        blocker.resume()
        await #expect(throws: StoreSessionAccessError.revoked) {
            try await operation.value
        }
        try await drain.value
        #expect(ended)
        #expect(FileManager.default.fileExists(atPath: fixture.replacementPackage.path))
        let artifacts = try FileManager.default.contentsOfDirectory(
            at: fixture.workRoot,
            includingPropertiesForKeys: nil
        )
        #expect(artifacts.contains {
            prepare ? $0.lastPathComponent.hasPrefix("Staged-") :
                ($0.pathExtension == "knitnote-backup" && $0 != fixture.replacementPackage)
        })
    }

    @Test(arguments: [KnitNoteBackupReplacementStep.beforeLiveMove,
                      .afterLiveMove, .afterStagedMove, .beforeCommitCleanup])
    func restoreCannotDrainWhileNativeReplacementIsBlocked(
        step: KnitNoteBackupReplacementStep
    ) async throws {
        let blocker = StoreOperationBlocker()
        let fixture = try StoreBackupFixture.make(
            replacementBlocker: blocker,
            blockedReplacementStep: step
        )
        let other = try StoreBackupFixture.make()
        defer { blocker.resume(); fixture.cleanup(); other.cleanup() }
        let otherBytes = try Data(contentsOf: other.archiveURL)
        let otherBackupEvidence = try backupEvidenceBytes(other.root)
        let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)
        let operation = Task { @MainActor in
            blocker.startObservingOperation()
            defer { blocker.finishObservation(reachedBlock: false) }
            try await fixture.store.restoreBackup(staged)
        }
        do {
            try #require(await blocker.waitForObservedBlock())
        } catch {
            blocker.resume()
            _ = try? await operation.value
            throw error
        }
        fixture.store.cancelBackupRestore(staged)
        if step == .beforeLiveMove || step == .afterLiveMove {
            #expect(FileManager.default.fileExists(atPath: staged.root.path))
        }
        fixture.store.revokeSessionWrites()
        let ready = AsyncStream<Void>.makeStream()
        var ended = false
        let waiter = Task { @MainActor in
            ready.continuation.yield(())
            try await fixture.store.waitForBackupOperationsAfterRevocation()
            ended = true
        }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(!ended)
        blocker.resume()
        try await operation.value
        try await waiter.value
        #expect(ended)
        #expect(try fixture.diskProjectName() == "replacement")
        #expect(!fixture.store.isDataOperationInProgress)
        #expect(try Data(contentsOf: other.archiveURL) == otherBytes)
        #expect(try backupEvidenceBytes(other.root) == otherBackupEvidence)
        try other.store.add(name: "Other session remains open")
    }

    @Test(arguments: ["reload", "rollback", "commit-cleanup"])
    func drainPreservesNativeFailureEvidence(mode: String) async throws {
        let blocker = StoreOperationBlocker()
        let fixture = try StoreBackupFixture.make(
            replacementBlocker: blocker,
            corruptInstalledArchive: mode != "commit-cleanup",
            failRollback: mode == "rollback",
            partialCommitCleanupFailure: mode == "commit-cleanup"
        )
        defer { blocker.resume(); fixture.cleanup() }
        let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)
        let operation = Task { @MainActor in
            blocker.startObservingOperation()
            defer { blocker.finishObservation(reachedBlock: false) }
            try await fixture.store.restoreBackup(staged)
        }
        do {
            try #require(await blocker.waitForObservedBlock())
        } catch {
            blocker.resume()
            _ = try? await operation.value
            throw error
        }
        fixture.store.revokeSessionWrites()
        blocker.resume()
        if mode == "reload" {
            await #expect(throws: KnitNoteBackupError.installFailedOriginalPreserved) {
                try await operation.value
            }
            #expect(try fixture.diskProjectName() == "original")
        } else if mode == "rollback" {
            await #expect(throws: KnitNoteBackupError.rollbackFailed) {
                try await operation.value
            }
            #expect(try fixture.rollbackRoots().count == 1)
        } else {
            try await operation.value
            #expect(try fixture.diskProjectName() == "replacement")
            #expect(try fixture.cleanupRoots().count == 1)
        }
        let before = try backupEvidenceBytes(fixture.workRoot)
        try await fixture.store.waitForBackupOperationsAfterRevocation()
        #expect(try backupEvidenceBytes(fixture.workRoot) == before)
    }

    @Test func twoPrepareOperationsMustBothEndBeforeDrain() async throws {
        let gates = TwoStageBlocks()
        let fixture = try StoreBackupFixture.make(stageObserver: { gates.visit($0) })
        defer { gates.first.resume(); gates.second.resume(); fixture.cleanup() }
        let one = Task { @MainActor in
            gates.first.startObservingOperation()
            return try await fixture.store.prepareBackupRestore(
                from: fixture.replacementPackage
            )
        }
        do {
            try #require(await gates.first.waitForObservedBlock())
        } catch {
            gates.first.resume()
            _ = try? await one.value
            throw error
        }
        let two = Task { @MainActor in
            gates.second.startObservingOperation()
            return try await fixture.store.prepareBackupRestore(
                from: fixture.replacementPackage
            )
        }
        do {
            try #require(await gates.second.waitForObservedBlock())
        } catch {
            gates.first.resume()
            gates.second.resume()
            _ = try? await one.value
            _ = try? await two.value
            throw error
        }
        fixture.store.revokeSessionWrites()
        let ready = AsyncStream<Void>.makeStream()
        var ended = false
        let waiter = Task { @MainActor in
            ready.continuation.yield(())
            try await fixture.store.waitForBackupOperationsAfterRevocation()
            ended = true
        }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        gates.first.resume()
        await #expect(throws: StoreSessionAccessError.revoked) {
            _ = try await one.value
        }
        #expect(!ended)
        gates.second.resume()
        await #expect(throws: StoreSessionAccessError.revoked) {
            _ = try await two.value
        }
        try await waiter.value
        #expect(ended)
    }

    @Test func drainIncludesRollbackAfterReloadFailure() async throws {
        let gate = StoreOperationBlocker()
        let fixture = try StoreBackupFixture.make(
            corruptInstalledArchive: true,
            rollbackBlocker: gate
        )
        defer { gate.resume(); fixture.cleanup() }
        let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)
        let operation = Task { @MainActor in
            gate.startObservingOperation()
            defer { gate.finishObservation(reachedBlock: false) }
            try await fixture.store.restoreBackup(staged)
        }
        do {
            try #require(await gate.waitForObservedBlock())
        } catch {
            gate.resume()
            _ = try? await operation.value
            throw error
        }
        fixture.store.revokeSessionWrites()
        let ready = AsyncStream<Void>.makeStream()
        var ended = false
        let waiter = Task { @MainActor in
            ready.continuation.yield(())
            try await fixture.store.waitForBackupOperationsAfterRevocation()
            ended = true
        }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(!ended)
        gate.resume()
        await #expect(throws: KnitNoteBackupError.installFailedOriginalPreserved) {
            try await operation.value
        }
        try await waiter.value
        #expect(try fixture.diskProjectName() == "original")
    }
}

enum StorePatternRevokedEntry: CaseIterable, Sendable {
    case directImport
    case libraryImport
    case projectImport
    case processInbox
    case pendingInbox
    case discardInbox
    case addYouTube
}

private enum StorePatternNativeTestError: Error, Equatable {
    case injected
}

@Suite(.serialized) @MainActor struct StorePatternSessionDrainTests {
    @Test(arguments: StorePatternRevokedEntry.allCases)
    func revokedEntriesLeavePatternEvidenceUntouched(_ entry: StorePatternRevokedEntry) async throws {
        let fixture = try StoreBackupFixture.make()
        defer { fixture.cleanup() }
        let source = fixture.liveRoot.appendingPathComponent("Revoked source.png")
        try makeStorePNG(at: source, red: 0.25)
        let projectID = try #require(fixture.store.projects.first?.id)
        let setupInbox = PatternInboxFileService(
            root: fixture.liveRoot.appendingPathComponent("PatternInbox", isDirectory: true)
        )
        let item = try setupInbox.enqueue(
            source: source,
            origin: .shareExtension,
            targetProjectID: projectID,
            now: Date(timeIntervalSince1970: 100)
        )
        let before = try backupEvidenceBytes(fixture.root)

        fixture.store.revokeSessionWrites()
        switch entry {
        case .directImport:
            await #expect(throws: StoreSessionAccessError.revoked) {
                _ = try await fixture.store.importPattern(from: source, projectID: projectID)
            }
        case .libraryImport:
            await #expect(throws: StoreSessionAccessError.revoked) {
                _ = try await fixture.store.importPatternFromLibrary(source)
            }
        case .projectImport:
            await #expect(throws: StoreSessionAccessError.revoked) {
                _ = try await fixture.store.importPatternFromProject(source, projectID: projectID)
            }
        case .processInbox:
            await #expect(throws: StoreSessionAccessError.revoked) {
                _ = try await fixture.store.processPatternInboxItem(id: item.id)
            }
        case .pendingInbox:
            await #expect(throws: StoreSessionAccessError.revoked) {
                _ = try await fixture.store.pendingPatternInboxItems()
            }
        case .discardInbox:
            await #expect(throws: StoreSessionAccessError.revoked) {
                try await fixture.store.discardPatternInboxItem(id: item.id)
            }
        case .addYouTube:
            await #expect(throws: StoreSessionAccessError.revoked) {
                _ = try await fixture.store.addYouTubePattern(
                    link: YouTubePatternLink(videoID: "dQw4w9WgXcQ"),
                    title: "Revoked video",
                    targetProjectID: projectID
                )
            }
        }

        #expect(try backupEvidenceBytes(fixture.root) == before)
        #expect(try Data(contentsOf: source).isEmpty == false)
        try await fixture.store.waitForTrackedBackgroundWritesAfterRevocation()
    }

    @Test func directImportRemainsTrackedUntilNativeCopyEnds() async throws {
        let blocker = StoreOperationBlocker()
        let fixture = try StoreBackupFixture.make(patternBlocker: blocker)
        let other = try StoreBackupFixture.make()
        defer { blocker.resume(); fixture.cleanup(); other.cleanup() }
        let source = fixture.liveRoot.appendingPathComponent("source.png")
        try makeStorePNG(at: source, red: 0.5)
        let original = try Data(contentsOf: source)
        let projectID = try #require(fixture.store.projects.first?.id)
        let otherBefore = try backupEvidenceBytes(other.root)
        let operation = Task { @MainActor in
            blocker.startObservingOperation()
            defer { blocker.finishObservation(reachedBlock: false) }
            return try await fixture.store.importPattern(from: source, projectID: projectID)
        }
        do {
            try #require(await blocker.waitForObservedBlock())
        } catch {
            blocker.resume()
            _ = try? await operation.value
            throw error
        }
        fixture.store.revokeSessionWrites()
        let ready = AsyncStream<Void>.makeStream()
        var ended = false
        let drain = Task { @MainActor in
            ready.continuation.yield(())
            try await fixture.store.waitForTrackedBackgroundWritesAfterRevocation()
            ended = true
        }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(!ended)
        blocker.resume()
        await #expect(throws: StoreSessionAccessError.revoked) {
            try await operation.value
        }
        try await drain.value
        #expect(try Data(contentsOf: source) == original)
        #expect(fixture.store.projects.first?.patterns.isEmpty == true)
        #expect(try backupEvidenceBytes(other.root) == otherBefore)
        try other.store.add(name: "Other session remains writable")
    }

    @Test(arguments: [false, true])
    func inboxEnqueueRemainsTrackedAndPreservesNativeMoveResult(failMove: Bool) async throws {
        let blocker = StoreOperationBlocker()
        let fixture = try StoreBackupFixture.make(
            patternInboxBlocker: blocker,
            failPatternInboxMove: failMove
        )
        defer { blocker.resume(); fixture.cleanup() }
        let source = fixture.liveRoot.appendingPathComponent("enqueue.png")
        try makeStorePNG(at: source, red: 0.35)
        let original = try Data(contentsOf: source)
        let operation = Task { @MainActor in
            blocker.startObservingOperation()
            defer { blocker.finishObservation(reachedBlock: false) }
            return try await fixture.store.importPatternFromLibrary(source)
        }
        do {
            try #require(await blocker.waitForObservedBlock())
        } catch {
            blocker.resume()
            _ = try? await operation.value
            throw error
        }
        fixture.store.revokeSessionWrites()
        let ready = AsyncStream<Void>.makeStream()
        var ended = false
        let drain = Task { @MainActor in
            ready.continuation.yield(())
            try await fixture.store.waitForTrackedBackgroundWritesAfterRevocation()
            ended = true
        }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(!ended)
        blocker.resume()
        if failMove {
            do {
                _ = try await operation.value
                Issue.record("Expected the injected native move failure")
            } catch {
                #expect(error as? StorePatternNativeTestError == .injected)
            }
        } else {
            await #expect(throws: StoreSessionAccessError.revoked) {
                try await operation.value
            }
        }
        try await drain.value
        #expect(try Data(contentsOf: source) == original)
        #expect(fixture.store.patterns.isEmpty)
    }

    @Test(arguments: [false, true])
    func processRechecksRevocationBeforePrepareAndPreservesRecoveryFailure(
        failReconciliation: Bool
    ) async throws {
        let blocker = StoreOperationBlocker()
        let removal = StorePatternInboxRemovalSequence(
            mode: .blockReconciliation(blocker, fail: failReconciliation)
        )
        let fixture = try StoreBackupFixture.make(patternInboxRemove: { try removal.remove($0) })
        defer { blocker.resume(); fixture.cleanup() }
        let source = fixture.liveRoot.appendingPathComponent("reconcile.png")
        try makeStorePNG(at: source, red: 0.45)
        let setupInbox = PatternInboxFileService(
            root: fixture.liveRoot.appendingPathComponent("PatternInbox", isDirectory: true)
        )
        let published = try setupInbox.enqueue(
            source: source,
            origin: .library,
            targetProjectID: nil,
            now: Date(timeIntervalSince1970: 200)
        )
        let pending = try setupInbox.enqueue(
            source: source,
            origin: .library,
            targetProjectID: nil,
            now: Date(timeIntervalSince1970: 201)
        )
        _ = try await fixture.store.processPatternInboxItem(id: published.id)
        let operation = Task { @MainActor in
            blocker.startObservingOperation()
            defer { blocker.finishObservation(reachedBlock: false) }
            return try await fixture.store.processPatternInboxItem(id: pending.id)
        }
        do {
            try #require(await blocker.waitForObservedBlock())
            try Data("invalidated after reconciliation began".utf8).write(
                to: setupInbox.stagedURL(for: pending),
                options: .atomic
            )
        } catch {
            blocker.resume()
            _ = try? await operation.value
            throw error
        }
        fixture.store.revokeSessionWrites()
        let ready = AsyncStream<Void>.makeStream()
        var ended = false
        let drain = Task { @MainActor in
            ready.continuation.yield(())
            try await fixture.store.waitForTrackedBackgroundWritesAfterRevocation()
            ended = true
        }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(!ended)
        blocker.resume()
        if failReconciliation {
            do {
                _ = try await operation.value
                Issue.record("Expected unresolved native recovery evidence")
            } catch {
                #expect(error as? PatternInboxError == .invalidItem)
            }
        } else {
            await #expect(throws: StoreSessionAccessError.revoked) {
                try await operation.value
            }
        }
        try await drain.value
    }

    @Test func pendingItemsRejectsResultCompletedAfterRevocation() async throws {
        let blocker = StoreOperationBlocker()
        let removal = StorePatternInboxRemovalSequence(mode: .blockItems(blocker))
        let fixture = try StoreBackupFixture.make(patternInboxRemove: { try removal.remove($0) })
        defer { blocker.resume(); fixture.cleanup() }
        let source = fixture.liveRoot.appendingPathComponent("pending.png")
        try makeStorePNG(at: source, red: 0.65)
        let setupInbox = PatternInboxFileService(
            root: fixture.liveRoot.appendingPathComponent("PatternInbox", isDirectory: true)
        )
        let published = try setupInbox.enqueue(
            source: source,
            origin: .library,
            targetProjectID: nil,
            now: Date(timeIntervalSince1970: 400)
        )
        _ = try await fixture.store.processPatternInboxItem(id: published.id)
        let operation = Task { @MainActor in
            blocker.startObservingOperation()
            defer { blocker.finishObservation(reachedBlock: false) }
            return try await fixture.store.pendingPatternInboxItems()
        }
        do {
            try #require(await blocker.waitForObservedBlock())
        } catch {
            blocker.resume()
            _ = try? await operation.value
            throw error
        }
        fixture.store.revokeSessionWrites()
        let ready = AsyncStream<Void>.makeStream()
        var ended = false
        let drain = Task { @MainActor in
            ready.continuation.yield(())
            try await fixture.store.waitForTrackedBackgroundWritesAfterRevocation()
            ended = true
        }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(!ended)
        blocker.resume()
        await #expect(throws: StoreSessionAccessError.revoked) {
            try await operation.value
        }
        try await drain.value
    }

    @Test(arguments: [false, true])
    func acceptedDiscardFinishesWithItsNativeResult(failRemoval: Bool) async throws {
        let blocker = StoreOperationBlocker()
        let removal = StorePatternDiscardRemoval(blocker: blocker, fail: failRemoval)
        let fixture = try StoreBackupFixture.make(patternInboxRemove: { try removal.remove($0) })
        defer { blocker.resume(); fixture.cleanup() }
        let source = fixture.liveRoot.appendingPathComponent("discard.png")
        try makeStorePNG(at: source, red: 0.75)
        let inbox = PatternInboxFileService(
            root: fixture.liveRoot.appendingPathComponent("PatternInbox", isDirectory: true)
        )
        let item = try inbox.enqueue(
            source: source,
            origin: .shareExtension,
            targetProjectID: nil,
            now: Date(timeIntervalSince1970: 500)
        )
        let operation = Task { @MainActor in
            blocker.startObservingOperation()
            defer { blocker.finishObservation(reachedBlock: false) }
            try await fixture.store.discardPatternInboxItem(id: item.id)
        }
        do {
            try #require(await blocker.waitForObservedBlock())
        } catch {
            blocker.resume()
            _ = try? await operation.value
            throw error
        }
        fixture.store.revokeSessionWrites()
        let ready = AsyncStream<Void>.makeStream()
        var ended = false
        let drain = Task { @MainActor in
            ready.continuation.yield(())
            try await fixture.store.waitForTrackedBackgroundWritesAfterRevocation()
            ended = true
        }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(!ended)
        blocker.resume()
        if failRemoval {
            do {
                try await operation.value
                Issue.record("Expected the injected native removal failure")
            } catch {
                #expect(error as? StorePatternNativeTestError == .injected)
            }
        } else {
            try await operation.value
        }
        try await drain.value
    }
}

enum StoreMediaRevokedEntry: CaseIterable, Sendable {
    case youtubeThumbnail
    case patternThumbnail
    case patternPDFPageThumbnail
    case directPhotoCover
    case patternCover
}

private enum StoreMediaNativeTestError: Error, Equatable {
    case journalThumbnailWrite
}

@Suite(.serialized) @MainActor struct StoreMediaSessionDrainTests {
    @Test func revokedJournalEntryLeavesDomainAndFilesUntouched() async throws {
        let fixture = try StoreBackupFixture.make()
        defer { fixture.cleanup() }
        let projectID = try #require(fixture.store.projects.first?.id)
        let photo = try makeStoreJPEG(red: 0.15)
        let before = try backupEvidenceBytes(fixture.root)

        fixture.store.revokeSessionWrites()
        await #expect(throws: StoreSessionAccessError.revoked) {
            try await fixture.store.addJournalEntry(
                projectID: projectID,
                photoData: photo,
                caption: "revoked"
            )
        }

        #expect(fixture.store.projects.first?.journalEntries.isEmpty == true)
        #expect(try backupEvidenceBytes(fixture.root) == before)
        try await fixture.store.waitForTrackedBackgroundWritesAfterRevocation()
    }

    @Test(arguments: StoreMediaRevokedEntry.allCases)
    func revokedThumbnailAndCoverEntriesLeaveEvidenceUntouched(
        _ entry: StoreMediaRevokedEntry
    ) async throws {
        let fixture = try StoreBackupFixture.make()
        defer { fixture.cleanup() }
        let projectID = try #require(fixture.store.projects.first?.id)
        var patternID: UUID?
        var assetID: UUID?

        switch entry {
        case .youtubeThumbnail:
            let added = try await fixture.store.addYouTubePattern(
                link: YouTubePatternLink(videoID: "dQw4w9WgXcQ"),
                title: "Revoked video",
                targetProjectID: projectID
            )
            patternID = added.patternID
        case .patternThumbnail, .patternPDFPageThumbnail, .patternCover:
            let source = fixture.root.appendingPathComponent("revoked.pdf")
            try makeStorePatternPDF(at: source)
            _ = try await fixture.store.importPatternFromProject(
                source,
                projectID: projectID
            )
            patternID = try #require(fixture.store.patterns.first?.id)
            assetID = try #require(fixture.store.patternAssets.first?.id)
        case .directPhotoCover:
            let project = try #require(fixture.store.project(id: projectID))
            try fixture.store.updateProject(
                id: projectID,
                name: project.name,
                toolType: project.toolType,
                toolSize: project.toolSize,
                toolNotes: project.toolNotes,
                photoChange: .replace(makeStoreJPEG(red: 0.25))
            )
        }

        let project = try #require(fixture.store.project(id: projectID))
        let thumbnail = try makeStoreJPEG(red: 0.35)
        let before = try backupEvidenceBytes(fixture.root)
        fixture.store.revokeSessionWrites()

        switch entry {
        case .youtubeThumbnail:
            await fixture.store.cacheYouTubeThumbnail(
                thumbnail,
                patternID: try #require(patternID)
            )
        case .patternThumbnail:
            #expect(await fixture.store.patternThumbnailURL(
                patternID: try #require(patternID)
            ) == nil)
        case .patternPDFPageThumbnail:
            #expect(await fixture.store.patternPDFPageThumbnailURL(
                assetID: try #require(assetID),
                pageIndex: 0
            ) == nil)
        case .directPhotoCover, .patternCover:
            #expect(await fixture.store.projectCoverURL(for: project) == nil)
        }

        #expect(try backupEvidenceBytes(fixture.root) == before)
        try await fixture.store.waitForTrackedBackgroundWritesAfterRevocation()
    }

    @Test(arguments: [false, true])
    func journalSaveDrainsThroughReconcileAndPreservesNativeFailure(
        failNativeWrite: Bool
    ) async throws {
        let blocker = StoreOperationBlocker()
        let fixture = try StoreBackupFixture.make(
            journalBlocker: blocker,
            failJournalThumbnailWrite: failNativeWrite
        )
        defer { blocker.resume(); fixture.cleanup() }
        let projectID = try #require(fixture.store.projects.first?.id)
        let photo = try makeStoreJPEG(red: 0.45)
        let operation = Task { @MainActor in
            blocker.startObservingOperation()
            defer { blocker.finishObservation(reachedBlock: false) }
            try await fixture.store.addJournalEntry(
                projectID: projectID,
                photoData: photo,
                caption: "late"
            )
        }
        do {
            try #require(await blocker.waitForObservedBlock())
        } catch {
            blocker.resume()
            _ = try? await operation.value
            throw error
        }

        fixture.store.revokeSessionWrites()
        let ready = AsyncStream<Void>.makeStream()
        var ended = false
        let drain = Task { @MainActor in
            ready.continuation.yield(())
            try await fixture.store.waitForTrackedBackgroundWritesAfterRevocation()
            ended = true
        }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(!ended)
        blocker.resume()

        if failNativeWrite {
            do {
                try await operation.value
                Issue.record("Expected the native journal thumbnail write failure")
            } catch {
                #expect(error as? StoreMediaNativeTestError == .journalThumbnailWrite)
            }
        } else {
            await #expect(throws: StoreSessionAccessError.revoked) {
                try await operation.value
            }
        }
        try await drain.value
        #expect(ended)
        #expect(fixture.store.projects.first?.journalEntries.isEmpty == true)
        let journalRoot = fixture.liveRoot.appendingPathComponent(
            "ProjectJournalPhotos",
            isDirectory: true
        )
        #expect(try FileManager.default.contentsOfDirectory(
            at: journalRoot,
            includingPropertiesForKeys: nil
        ).isEmpty)
    }

    @Test func youtubeThumbnailStageRemainsTrackedAndIsDiscardedAfterRevocation() async throws {
        let blocker = StoreOperationBlocker()
        let fixture = try StoreBackupFixture.make(thumbnailStageBlocker: blocker)
        defer { blocker.resume(); fixture.cleanup() }
        let projectID = try #require(fixture.store.projects.first?.id)
        let added = try await fixture.store.addYouTubePattern(
            link: YouTubePatternLink(videoID: "dQw4w9WgXcQ"),
            title: "Staged video",
            targetProjectID: projectID
        )
        let assetID = try #require(fixture.store.patterns.first {
            $0.id == added.patternID
        }?.assetID)
        let thumbnail = try makeStoreJPEG(red: 0.55)
        let operation = Task { @MainActor in
            blocker.startObservingOperation()
            defer { blocker.finishObservation(reachedBlock: false) }
            await fixture.store.cacheYouTubeThumbnail(
                thumbnail,
                patternID: added.patternID
            )
        }
        do {
            try #require(await blocker.waitForObservedBlock())
        } catch {
            blocker.resume()
            await operation.value
            throw error
        }

        fixture.store.revokeSessionWrites()
        let ready = AsyncStream<Void>.makeStream()
        var ended = false
        let drain = Task { @MainActor in
            ready.continuation.yield(())
            try await fixture.store.waitForTrackedBackgroundWritesAfterRevocation()
            ended = true
        }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(!ended)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.thumbnailService.cachedURL(assetID: assetID).path
        ))
        blocker.resume()
        await operation.value
        try await drain.value

        #expect(ended)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.thumbnailService.cachedURL(assetID: assetID).path
        ))
        let stagedRoot = fixture.thumbnailService.directory.appendingPathComponent(
            ".ExternalThumbnailStaging",
            isDirectory: true
        )
        #expect(try FileManager.default.contentsOfDirectory(
            at: stagedRoot,
            includingPropertiesForKeys: nil
        ).isEmpty)
    }

    @Test func pdfPageThumbnailRemainsTrackedAndRejectsItsLateURL() async throws {
        let blocker = StoreOperationBlocker()
        let fixture = try StoreBackupFixture.make(thumbnailRenderBlocker: blocker)
        defer { blocker.resume(); fixture.cleanup() }
        let projectID = try #require(fixture.store.projects.first?.id)
        let source = fixture.root.appendingPathComponent("page-source.pdf")
        try makeStorePatternPDF(at: source)
        _ = try await fixture.store.importPatternFromProject(source, projectID: projectID)
        let asset = try #require(fixture.store.patternAssets.first)
        let operation = Task { @MainActor in
            blocker.startObservingOperation()
            defer { blocker.finishObservation(reachedBlock: false) }
            return await fixture.store.patternPDFPageThumbnailURL(
                assetID: asset.id,
                pageIndex: 0
            )
        }
        do {
            try #require(await blocker.waitForObservedBlock())
        } catch {
            blocker.resume()
            _ = await operation.value
            throw error
        }

        fixture.store.revokeSessionWrites()
        let ready = AsyncStream<Void>.makeStream()
        var ended = false
        let drain = Task { @MainActor in
            ready.continuation.yield(())
            try await fixture.store.waitForTrackedBackgroundWritesAfterRevocation()
            ended = true
        }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(!ended)
        blocker.resume()
        let result = await operation.value
        try await drain.value

        #expect(ended)
        #expect(result == nil)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(
            atPath: fixture.thumbnailService.cachedPageURL(asset: asset, pageIndex: 0).path
        ))
    }

    @Test(arguments: [false, true])
    func ordinaryThumbnailAndPatternCoverRemainTrackedAndRejectLateURLs(
        cover: Bool
    ) async throws {
        let blocker = StoreOperationBlocker()
        let fixture = try StoreBackupFixture.make(thumbnailRenderBlocker: blocker)
        defer { blocker.resume(); fixture.cleanup() }
        let projectID = try #require(fixture.store.projects.first?.id)
        let source = fixture.root.appendingPathComponent(
            cover ? "cover-source.pdf" : "thumbnail-source.pdf"
        )
        try makeStorePatternPDF(at: source)
        _ = try await fixture.store.importPatternFromProject(source, projectID: projectID)
        let pattern = try #require(fixture.store.patterns.first)
        let asset = try #require(fixture.store.patternAssets.first)
        let storedSource = try fixture.store.patternAssetURL(patternID: pattern.id)
        let project = try #require(fixture.store.project(id: projectID))
        let ordinaryURL = fixture.thumbnailService.cachedURL(assetID: asset.id)
        #expect(!FileManager.default.fileExists(atPath: ordinaryURL.path))

        blocker.startObservingOperation()
        let lockHolder = Task.detached {
            try fixture.thumbnailService.thumbnailURL(
                asset: asset,
                sourceURL: storedSource,
                pageIndex: 0
            )
        }
        do {
            try #require(await blocker.waitForObservedBlock())
        } catch {
            blocker.resume()
            _ = try? await lockHolder.value
            throw error
        }

        let operationReady = AsyncStream<Void>.makeStream()
        let operation = Task { @MainActor in
            operationReady.continuation.yield(())
            if cover {
                return await fixture.store.projectCoverURL(for: project)
            }
            return await fixture.store.patternThumbnailURL(patternID: pattern.id)
        }
        var operationIterator = operationReady.stream.makeAsyncIterator()
        _ = await operationIterator.next()
        fixture.store.revokeSessionWrites()
        let drainReady = AsyncStream<Void>.makeStream()
        var ended = false
        let drain = Task { @MainActor in
            drainReady.continuation.yield(())
            try await fixture.store.waitForTrackedBackgroundWritesAfterRevocation()
            ended = true
        }
        var drainIterator = drainReady.stream.makeAsyncIterator()
        _ = await drainIterator.next()
        #expect(!ended)
        blocker.resume()
        let heldPageURL: URL
        do {
            heldPageURL = try await lockHolder.value
        } catch {
            blocker.resume()
            _ = await operation.value
            _ = try? await drain.value
            throw error
        }
        let result = await operation.value
        try await drain.value

        #expect(ended)
        #expect(result == nil)
        #expect(heldPageURL == fixture.thumbnailService.cachedPageURL(
            asset: asset,
            pageIndex: 0
        ))
        #expect(FileManager.default.fileExists(atPath: ordinaryURL.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
}

enum StoreBackgroundTerminalFailure: CaseIterable, Sendable {
    case journalPhoto
    case patternInbox
}

@Suite(.serialized) @MainActor struct StoreBackgroundDrainIntegrationTests {
    @Test func aggregateWaitIncludesBothNativeProducers() async throws {
        let photo = StoreOperationBlocker()
        let pattern = StoreOperationBlocker()
        let fixture = try StoreBackupFixture.make(
            journalBlocker: photo,
            patternBlocker: pattern
        )
        let other = try StoreBackupFixture.make()
        defer { photo.resume(); pattern.resume(); fixture.cleanup(); other.cleanup() }
        let projectID = try #require(fixture.store.projects.first?.id)
        let source = fixture.root.appendingPathComponent("mixed-source.png")
        try makeStorePNG(at: source, red: 0.4)
        let photoData = try makeStoreJPEG(red: 0.6)
        let before = try backupEvidenceBytes(fixture.root)
        let otherBefore = try backupEvidenceBytes(other.root)
        let photoTask = Task { @MainActor in
            photo.startObservingOperation()
            defer { photo.finishObservation(reachedBlock: false) }
            try await fixture.store.addJournalEntry(
                projectID: projectID,
                photoData: photoData,
                caption: nil
            )
        }
        let patternTask = Task { @MainActor in
            pattern.startObservingOperation()
            defer { pattern.finishObservation(reachedBlock: false) }
            return try await fixture.store.importPattern(
                from: source,
                projectID: projectID
            )
        }

        do {
            try #require(await photo.waitForObservedBlock())
            try #require(await pattern.waitForObservedBlock())
            fixture.store.revokeSessionWrites()
            try await fixture.store.waitForBackupOperationsAfterRevocation()
            let ready = AsyncStream<Void>.makeStream()
            var ended = false
            let all = Task { @MainActor in
                ready.continuation.yield(())
                try await fixture.store.waitForTrackedBackgroundWritesAfterRevocation()
                ended = true
            }
            var iterator = ready.stream.makeAsyncIterator()
            _ = await iterator.next()
            #expect(!ended)
            photo.resume()
            await #expect(throws: StoreSessionAccessError.revoked) {
                try await photoTask.value
            }
            #expect(!ended)
            pattern.resume()
            await #expect(throws: StoreSessionAccessError.revoked) {
                try await patternTask.value
            }
            try await all.value
            #expect(ended)
            #expect(try backupEvidenceBytes(fixture.root) == before)
            #expect(try backupEvidenceBytes(other.root) == otherBefore)
            try other.store.add(name: "Other session remains writable")
        } catch {
            photo.resume()
            pattern.resume()
            _ = try? await photoTask.value
            _ = try? await patternTask.value
            throw error
        }
    }

    @Test func cancellingOneAggregateWaiterDoesNotCancelItsPeerOrNativeWork() async throws {
        let blocker = StoreOperationBlocker()
        let fixture = try StoreBackupFixture.make(patternBlocker: blocker)
        defer { blocker.resume(); fixture.cleanup() }
        let projectID = try #require(fixture.store.projects.first?.id)
        let source = fixture.root.appendingPathComponent("cancelled-wait-source.png")
        try makeStorePNG(at: source, red: 0.7)
        let operation = Task { @MainActor in
            blocker.startObservingOperation()
            defer { blocker.finishObservation(reachedBlock: false) }
            return try await fixture.store.importPattern(
                from: source,
                projectID: projectID
            )
        }

        do {
            try #require(await blocker.waitForObservedBlock())
            fixture.store.revokeSessionWrites()
            let ready = AsyncStream<Int>.makeStream()
            var peerEnded = false
            let cancelled = Task { @MainActor in
                ready.continuation.yield(1)
                try await fixture.store.waitForTrackedBackgroundWritesAfterRevocation()
            }
            let peer = Task { @MainActor in
                ready.continuation.yield(2)
                try await fixture.store.waitForTrackedBackgroundWritesAfterRevocation()
                peerEnded = true
            }

            do {
                var iterator = ready.stream.makeAsyncIterator()
                let registered = Set([
                    try #require(await iterator.next()),
                    try #require(await iterator.next()),
                ])
                #expect(registered == [1, 2])
                cancelled.cancel()
                await #expect(throws: CancellationError.self) {
                    try await cancelled.value
                }
                #expect(!peerEnded)
                blocker.resume()
                await #expect(throws: StoreSessionAccessError.revoked) {
                    try await operation.value
                }
                try await peer.value
                #expect(peerEnded)
            } catch {
                cancelled.cancel()
                peer.cancel()
                blocker.resume()
                _ = try? await operation.value
                _ = try? await cancelled.value
                _ = try? await peer.value
                throw error
            }
        } catch {
            blocker.resume()
            _ = try? await operation.value
            throw error
        }
    }

    @Test func publicAggregateWaitRejectsAnOpenSession() async throws {
        let fixture = try StoreBackupFixture.make()
        defer { fixture.cleanup() }
        await #expect(throws: StoreSessionDrainError.sessionStillActive) {
            try await fixture.store.waitForTrackedBackgroundWritesAfterRevocation()
        }
    }

    @Test func publicAggregateWaitReturnsForAnEmptyClosedSession() async throws {
        let fixture = try StoreBackupFixture.make()
        defer { fixture.cleanup() }
        fixture.store.revokeSessionWrites()
        try await fixture.store.waitForTrackedBackgroundWritesAfterRevocation()
    }

    @Test(arguments: StoreBackgroundTerminalFailure.allCases)
    func aggregateWaitRetainsTerminalNativeFailureEvidence(
        _ failure: StoreBackgroundTerminalFailure
    ) async throws {
        let blocker = StoreOperationBlocker()
        let fixture: StoreBackupFixture
        switch failure {
        case .journalPhoto:
            fixture = try StoreBackupFixture.make(
                journalBlocker: blocker,
                failJournalThumbnailWrite: true
            )
        case .patternInbox:
            fixture = try StoreBackupFixture.make(
                patternInboxBlocker: blocker,
                failPatternInboxMove: true
            )
        }
        defer { blocker.resume(); fixture.cleanup() }
        let projectID = try #require(fixture.store.projects.first?.id)
        let source = fixture.root.appendingPathComponent("terminal-failure-source.png")
        try makeStorePNG(at: source, red: 0.8)
        let sourceBefore = try Data(contentsOf: source)
        let operation = Task { @MainActor in
            blocker.startObservingOperation()
            defer { blocker.finishObservation(reachedBlock: false) }
            switch failure {
            case .journalPhoto:
                try await fixture.store.addJournalEntry(
                    projectID: projectID,
                    photoData: try makeStoreJPEG(red: 0.9),
                    caption: "terminal failure"
                )
            case .patternInbox:
                _ = try await fixture.store.importPatternFromLibrary(source)
            }
        }

        do {
            try #require(await blocker.waitForObservedBlock())
            fixture.store.revokeSessionWrites()
            blocker.resume()
            switch failure {
            case .journalPhoto:
                await #expect(throws: StoreMediaNativeTestError.journalThumbnailWrite) {
                    try await operation.value
                }
            case .patternInbox:
                await #expect(throws: StorePatternNativeTestError.injected) {
                    try await operation.value
                }
            }

            let beforeWait = try backupEvidenceBytes(fixture.root)
            try await fixture.store.waitForTrackedBackgroundWritesAfterRevocation()
            #expect(try backupEvidenceBytes(fixture.root) == beforeWait)
            #expect(try Data(contentsOf: source) == sourceBefore)
        } catch {
            blocker.resume()
            _ = try? await operation.value
            throw error
        }
    }
}

private enum BackupEvidenceError: Error {
    case enumerationFailed(URL)
}

private final class StorePatternDiscardRemoval: @unchecked Sendable {
    private let blocker: StoreOperationBlocker
    private let fail: Bool

    init(blocker: StoreOperationBlocker, fail: Bool) {
        self.blocker = blocker
        self.fail = fail
    }

    func remove(_ url: URL) throws {
        blocker.blockOnce()
        if fail { throw StorePatternNativeTestError.injected }
        try FileManager.default.removeItem(at: url)
    }
}

private final class StorePatternInboxRemovalSequence: @unchecked Sendable {
    enum Mode {
        case blockReconciliation(StoreOperationBlocker, fail: Bool)
        case blockItems(StoreOperationBlocker)
    }

    private let mode: Mode
    private let lock = NSLock()
    private var callCount = 0

    init(mode: Mode) {
        self.mode = mode
    }

    func remove(_ url: URL) throws {
        lock.lock()
        callCount += 1
        let call = callCount
        lock.unlock()

        if call == 1 {
            throw StorePatternNativeTestError.injected
        }
        switch mode {
        case let .blockReconciliation(blocker, fail):
            if call == 2 {
                blocker.blockOnce()
                if fail { throw StorePatternNativeTestError.injected }
            }
        case let .blockItems(blocker):
            if call == 3 {
                try FileManager.default.removeItem(at: url)
                let candidate = url
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent(".Candidates", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString)
                try Data("late candidate".utf8).write(to: candidate)
                return
            }
            if call == 4 { blocker.blockOnce() }
        }
        try FileManager.default.removeItem(at: url)
    }
}

private func backupEvidenceBytes(_ root: URL) throws -> [String: Data] {
    var enumerationError: Error?
    guard let files = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [],
        errorHandler: { _, error in
            enumerationError = error
            return false
        }
    ) else {
        throw BackupEvidenceError.enumerationFailed(root)
    }
    var result: [String: Data] = [:]
    while let file = files.nextObject() as? URL {
        if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[file.path] = try Data(contentsOf: file)
        }
    }
    if let enumerationError {
        throw enumerationError
    }
    return result
}

private final class TwoStageBlocks: @unchecked Sendable {
    let first = StoreOperationBlocker()
    let second = StoreOperationBlocker()
    private let lock = NSLock()
    private var count = 0

    func visit(_ url: URL) {
        lock.lock()
        count += 1
        let index = count
        lock.unlock()
        (index == 1 ? first : second).blockOnce()
    }
}

@MainActor private struct StoreBackupFixture {
    private struct InjectedFailure: Error {}

    let root: URL
    let liveRoot: URL
    let archiveURL: URL
    let workRoot: URL
    let replacementPackage: URL
    let service: KnitNoteBackupService
    let thumbnailService: PatternThumbnailFileService
    let store: JSONProjectStore

    static func make(
        metadataBlocker: StoreOperationBlocker? = nil,
        stageBlocker: StoreOperationBlocker? = nil,
        stageObserver: (@Sendable (URL) -> Void)? = nil,
        journalBlocker: StoreOperationBlocker? = nil,
        patternBlocker: StoreOperationBlocker? = nil,
        patternInboxBlocker: StoreOperationBlocker? = nil,
        failPatternInboxMove: Bool = false,
        patternInboxRemove: (@Sendable (URL) throws -> Void)? = nil,
        replacementBlocker: StoreOperationBlocker? = nil,
        blockedReplacementStep: KnitNoteBackupReplacementStep = .afterStagedMove,
        corruptInstalledArchive: Bool = false,
        failRollback: Bool = false,
        partialCommitCleanupFailure: Bool = false,
        rollbackBlocker: StoreOperationBlocker? = nil,
        thumbnailRenderBlocker: StoreOperationBlocker? = nil,
        thumbnailStageBlocker: StoreOperationBlocker? = nil,
        failJournalThumbnailWrite: Bool = false
    ) throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let liveRoot = root.appendingPathComponent("KnitNote", isDirectory: true)
        let archiveURL = liveRoot.appendingPathComponent("projects-v1.json")
        let workRoot = root.appendingPathComponent("BackupWork", isDirectory: true)
        try writeArchive(
            projectName: "replacement",
            yarnName: "replacement yarn",
            to: archiveURL
        )
        let packageBuilder = KnitNoteBackupService(liveRoot: liveRoot, workRoot: workRoot)
        let replacementPackage = try packageBuilder.createPackage(appVersion: "1.0")
        try writeArchive(
            projectName: "original",
            yarnName: "original yarn",
            to: archiveURL
        )

        let service: KnitNoteBackupService
        if let metadataBlocker {
            service = KnitNoteBackupService(
                liveRoot: liveRoot,
                workRoot: workRoot,
                resourceMetadata: { url in
                    if url.standardizedFileURL == archiveURL.standardizedFileURL {
                        metadataBlocker.blockOnce()
                    }
                    return try backupMetadata(for: url)
                }
            )
        } else if stageBlocker != nil || stageObserver != nil {
            service = KnitNoteBackupService(
                liveRoot: liveRoot,
                workRoot: workRoot,
                afterStageCopy: { url in
                    stageObserver?(url)
                    stageBlocker?.blockOnce()
                }
            )
        } else {
            service = KnitNoteBackupService(
                liveRoot: liveRoot,
                workRoot: workRoot,
                replacementStepHook: { step in
                    if step == blockedReplacementStep {
                        if corruptInstalledArchive {
                            try Data("not JSON".utf8).write(
                                to: archiveURL,
                                options: .atomic
                            )
                        }
                        replacementBlocker?.blockOnce()
                    }
                    if step == .beforeRollback {
                        rollbackBlocker?.blockOnce()
                        if failRollback {
                            throw InjectedFailure()
                        }
                    }
                },
                cleanupItem: { cleanupRoot in
                    guard partialCommitCleanupFailure,
                          cleanupRoot.lastPathComponent.hasPrefix("Cleanup-") else {
                        try FileManager.default.removeItem(at: cleanupRoot)
                        return
                    }
                    try FileManager.default.removeItem(
                        at: cleanupRoot.appendingPathComponent("projects-v1.json")
                    )
                    throw InjectedFailure()
                }
            )
        }
        let journalService: ProjectJournalPhotoFileService?
        if let journalBlocker {
            journalService = ProjectJournalPhotoFileService(
                directory: liveRoot.appendingPathComponent("ProjectJournalPhotos"),
                writeData: { data, url in
                    try data.write(to: url, options: .atomic)
                    if ProjectJournalPhotoFilename.isFullImage(url.lastPathComponent) {
                        journalBlocker.blockOnce()
                    } else if failJournalThumbnailWrite,
                              ProjectJournalPhotoFilename.isThumbnail(url.lastPathComponent) {
                        throw StoreMediaNativeTestError.journalThumbnailWrite
                    }
                }
            )
        } else {
            journalService = nil
        }
        let patternService: PatternFileService?
        if let patternBlocker {
            patternService = PatternFileService(
                root: liveRoot.appendingPathComponent("Patterns"),
                copyFile: { source, destination in
                    patternBlocker.blockOnce()
                    try FileManager.default.copyItem(at: source, to: destination)
                }
            )
        } else {
            patternService = nil
        }
        let patternInboxService: PatternInboxFileService?
        if patternInboxBlocker != nil || patternInboxRemove != nil {
            patternInboxService = PatternInboxFileService(
                root: liveRoot.appendingPathComponent("PatternInbox"),
                moveItem: { source, destination in
                    patternInboxBlocker?.blockOnce()
                    if failPatternInboxMove {
                        throw StorePatternNativeTestError.injected
                    }
                    try FileManager.default.moveItem(at: source, to: destination)
                },
                removeItem: patternInboxRemove ?? { try FileManager.default.removeItem(at: $0) },
                writeData: { try $0.write(to: $1, options: .atomic) }
            )
        } else {
            patternInboxService = nil
        }
        let thumbnailService = PatternThumbnailFileService(
            directory: root.appendingPathComponent("ThumbnailCache"),
            afterPageRender: { thumbnailRenderBlocker?.blockOnce() }
        )
        let store = JSONProjectStore(
            url: archiveURL,
            journalPhotoService: journalService,
            patternFileService: patternService,
            patternInboxFileService: patternInboxService,
            patternThumbnailService: thumbnailService,
            afterYouTubeThumbnailStage: {
                if let thumbnailStageBlocker {
                    await Task.detached { thumbnailStageBlocker.blockOnce() }.value
                }
            },
            backupService: service
        )
        return Self(
            root: root,
            liveRoot: liveRoot,
            archiveURL: archiveURL,
            workRoot: workRoot,
            replacementPackage: replacementPackage,
            service: service,
            thumbnailService: thumbnailService,
            store: store
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeArchive(projectName: String, yarnName: String) throws {
        try Self.writeArchive(
            projectName: projectName,
            yarnName: yarnName,
            to: archiveURL
        )
    }

    func diskProjectName() throws -> String {
        let archive = try JSONDecoder().decode(
            ProjectArchive.self,
            from: Data(contentsOf: archiveURL)
        )
        return try #require(archive.projects.first?.name)
    }

    func rollbackRoots() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: workRoot.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: workRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("Rollback-") }
    }

    func cleanupRoots() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: workRoot.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: workRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("Cleanup-") }
    }

    private static func writeArchive(
        projectName: String,
        yarnName: String,
        to archiveURL: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: archiveURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let project = try StoredProject(name: projectName)
        var yarn = try StoredYarn(name: yarnName)
        yarn.setLinkedProjectIDs([project.id])
        let archive = ProjectArchive(version: 9, projects: [project], yarns: [yarn])
        try JSONEncoder().encode(archive).write(to: archiveURL, options: .atomic)
    }
}

@MainActor private final class BackupPatternHarness {
    struct LegacyPatternPackage {
        let package: URL
        let patternID: UUID
        let readingState: PatternReadingState
        let markup: PatternMarkupDocument
        let originalBytes: Data
    }

    let root: URL
    let liveRoot: URL
    let sourceRoot: URL
    let archiveURL: URL
    let service: KnitNoteBackupService
    let store: JSONProjectStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BackupPatternHarness-\(UUID().uuidString)",
            isDirectory: true
        )
        liveRoot = root.appendingPathComponent("KnitNote", isDirectory: true)
        sourceRoot = root.appendingPathComponent("Sources", isDirectory: true)
        archiveURL = liveRoot.appendingPathComponent("projects-v1.json")
        try FileManager.default.createDirectory(
            at: sourceRoot,
            withIntermediateDirectories: true
        )
        let nameContext = try shippingPatternFolderNameContext()
        service = KnitNoteBackupService(
            liveRoot: liveRoot,
            workRoot: root.appendingPathComponent("BackupWork", isDirectory: true),
            patternFolderNameContext: nameContext
        )
        let inbox = PatternInboxFileService(
            root: root.appendingPathComponent("PatternInbox", isDirectory: true)
        )
        store = JSONProjectStore(
            url: archiveURL,
            patternFileService: PatternFileService(
                root: liveRoot.appendingPathComponent("Patterns", isDirectory: true)
            ),
            patternInboxFileService: inbox,
            patternMarkupFileService: PatternMarkupFileService(
                root: liveRoot.appendingPathComponent("Patterns", isDirectory: true)
            ),
            patternThumbnailService: PatternThumbnailFileService(
                directory: root.appendingPathComponent("ThumbnailCache", isDirectory: true)
            ),
            patternFolderNameContext: nameContext,
            backupService: service
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeFormatOneLegacyPatternPackage() throws -> LegacyPatternPackage {
        let package = root.appendingPathComponent(
            "Legacy.knitnote-backup",
            isDirectory: true
        )
        let dataRoot = package.appendingPathComponent("Data", isDirectory: true)
        let projectID = UUID()
        let patternID = UUID()
        let storedFilename = "\(patternID.uuidString).pdf"
        let patternPath = "Patterns/\(projectID.uuidString)/\(storedFilename)"
        let markupPath = "Patterns/\(projectID.uuidString)/Markup/\(patternID.uuidString)/1.json"
        try FileManager.default.createDirectory(
            at: dataRoot.appendingPathComponent(patternPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makeStorePatternPDF(at: dataRoot.appendingPathComponent(patternPath))
        let originalBytes = try Data(contentsOf: dataRoot.appendingPathComponent(patternPath))

        var pattern = PatternDocument(
            id: patternID,
            displayName: "Legacy chart",
            kind: .pdf,
            storedFilename: storedFilename,
            createdAt: .init(timeIntervalSince1970: 40)
        )
        pattern.lastOpenedAt = .init(timeIntervalSince1970: 41)
        pattern.pageIndex = 1
        pattern.zoomScale = 2
        pattern.contentOffsetX = 0.25
        pattern.contentOffsetY = 0.75
        pattern.highlightEnabled = true
        pattern.highlightPosition = 0.3
        pattern.highlightMode = .cross
        pattern.verticalHighlightPosition = 0.8
        pattern.pageStates = [
            1: .init(
                horizontalPosition: 0.3,
                verticalPosition: 0.8,
                note: "Legacy page note"
            ),
        ]
        var project = try StoredProject(id: projectID, name: "Legacy pattern project")
        project.addPattern(pattern)
        let archive = ProjectArchive(version: 9, projects: [project])
        try JSONEncoder().encode(archive).write(
            to: dataRoot.appendingPathComponent("projects-v1.json"),
            options: .atomic
        )
        let markup = PatternMarkupDocument(strokes: [
            .init(points: [.init(x: 0.3, y: 0.6)], color: .green, width: 0.007),
        ])
        let markupURL = dataRoot.appendingPathComponent(markupPath)
        try FileManager.default.createDirectory(
            at: markupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(markup).write(to: markupURL, options: .atomic)
        let manifest = KnitNoteBackupManifest(
            formatVersion: 1,
            createdAt: .init(timeIntervalSince1970: 42),
            appVersion: "1.1.0",
            projectCount: 1,
            yarnCount: 0
        )
        try JSONEncoder().encode(manifest).write(
            to: package.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        return LegacyPatternPackage(
            package: package,
            patternID: patternID,
            readingState: pattern.readingState,
            markup: markup,
            originalBytes: originalBytes
        )
    }
}

@MainActor private func installFolderMembership(
    harness: BackupPatternHarness,
    folders: [PatternFolder],
    assignedFolderID: UUID,
    filename: String
) async throws -> StoredPattern {
    let source = harness.sourceRoot.appendingPathComponent(filename)
    try makeStorePatternPDF(at: source)
    guard case let .created(patternID) = try await harness.store.importPatternFromLibrary(source)
    else {
        Issue.record("Expected a new pattern")
        throw PatternLibraryMutationError.patternNotFound
    }
    var archive = try JSONDecoder().decode(
        ProjectArchive.self,
        from: Data(contentsOf: harness.archiveURL)
    )
    archive.patternFolders = folders
    let index = try #require(archive.patterns.firstIndex { $0.id == patternID })
    archive.patterns[index].folderID = assignedFolderID
    try JSONEncoder().encode(archive).write(to: harness.archiveURL, options: .atomic)
    try harness.store.reloadFromDisk()
    return try #require(harness.store.patterns.first { $0.id == patternID })
}

@MainActor private func makeFolderMembershipPackage(
    harness: BackupPatternHarness,
    folders: [PatternFolder],
    assignedFolderID: UUID
) async throws -> (package: URL, patternID: UUID) {
    let pattern = try await installFolderMembership(
        harness: harness,
        folders: folders,
        assignedFolderID: assignedFolderID,
        filename: "Folder restore.pdf"
    )
    let package = try harness.service.createPackage(appVersion: "1.5.0")
    try harness.store.deletePatternPermanently(id: pattern.id)
    #expect(harness.store.patterns.isEmpty)
    return (package, pattern.id)
}

@Suite struct StoreBackupHandshakeTests {
    @Test func signalBeforeWaitIsRetainedAndCompletionCannotOverwriteIt() async {
        let blocker = StoreOperationBlocker()
        // This tests the signal's first-result latch, independently of scheduling.
        blocker.finishObservation(reachedBlock: true)
        blocker.finishObservation(reachedBlock: false)
        #expect(await blocker.waitForObservedBlock())
    }

    @Test func operationEndingWithoutBlockFailsInsteadOfHanging() async {
        let blocker = StoreOperationBlocker()
        blocker.finishObservation(reachedBlock: false)
        blocker.finishObservation(reachedBlock: true)
        #expect(await blocker.waitForObservedBlock() == false)
    }

    @Test func startedOperationWithoutSignalTimesOut() async {
        let blocker = StoreOperationBlocker()
        blocker.startObservingOperation(timeout: .milliseconds(20))
        #expect(await blocker.waitForObservedBlock() == false)
    }

    @Test func cancelledWaitDoesNotHang() async {
        let blocker = StoreOperationBlocker()
        let waiter = Task { await blocker.waitForObservedBlock() }
        waiter.cancel()
        #expect(await waiter.value == false)
    }
}

private final class StoreOperationBlocker: @unchecked Sendable {
    private let observedBlock: AsyncStream<Bool>
    private let observation: AsyncStream<Bool>.Continuation
    private let blocked = DispatchSemaphore(value: 0)
    private let continuation = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hasBlocked = false
    private var observationFinished = false

    init() {
        let stream = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observedBlock = stream.stream
        observation = stream.continuation
    }

    // Only the export handshake uses this observer. Its deadline starts when
    // the operation actually runs, not while it is queued on MainActor.
    func startObservingOperation(timeout: DispatchTimeInterval = .seconds(10)) {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finishObservation(reachedBlock: false)
        }
    }

    func waitForObservedBlock() async -> Bool {
        for await result in observedBlock { return result }
        return false
    }

    func finishObservation(reachedBlock: Bool) {
        lock.lock()
        guard !observationFinished else { lock.unlock(); return }
        observationFinished = true
        lock.unlock()
        observation.yield(reachedBlock)
        observation.finish()
    }

    func blockOnce() {
        lock.lock()
        guard !hasBlocked else {
            lock.unlock()
            return
        }
        hasBlocked = true
        lock.unlock()
        finishObservation(reachedBlock: true)
        blocked.signal()
        continuation.wait()
    }

    func waitUntilBlocked() -> Bool {
        blocked.wait(timeout: .now() + 10) == .success
    }

    func resume() {
        continuation.signal()
    }
}

private func backupMetadata(for url: URL) throws -> KnitNoteBackupResourceMetadata {
    let values = try url.resourceValues(forKeys: [
        .isRegularFileKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .volumeIdentifierKey,
    ])
    return (
        isRegularFile: values.isRegularFile,
        isDirectory: values.isDirectory,
        isSymbolicLink: values.isSymbolicLink,
        fileSize: values.fileSize.map(Int64.init),
        physicalVolumeIdentifier: values.volumeIdentifier.map(String.init(describing:))
    )
}

private func makeStoreJPEG(red: CGFloat) throws -> Data {
    let context = try #require(CGContext(
        data: nil,
        width: 32,
        height: 24,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: red, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func makeStorePNG(at url: URL, red: CGFloat) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let context = try #require(CGContext(
        data: nil,
        width: 32,
        height: 16,
        bitsPerComponent: 8,
        bytesPerRow: 128,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
    let destination = try #require(CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
}

private func backupPackageRelativePaths(at packageURL: URL) throws -> [String] {
    let root = packageURL.standardizedFileURL.path + "/"
    let enumerator = try #require(FileManager.default.enumerator(
        at: packageURL,
        includingPropertiesForKeys: nil
    ))
    var paths: [String] = []
    for case let url as URL in enumerator {
        let path = url.standardizedFileURL.path
        if path.hasPrefix(root) {
            paths.append(String(path.dropFirst(root.count)))
        }
    }
    return paths
}

private func makeStorePatternPDF(at url: URL) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 100, height: 100)
    let consumer = try #require(CGDataConsumer(url: url as CFURL))
    let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
    context.beginPDFPage(nil)
    context.endPDFPage()
    context.closePDF()
}
