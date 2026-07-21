import CoreGraphics
import Dispatch
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KnitNoteCore

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
    #expect(archive.version == 9)

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
    #expect(archive.version == 9)
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

@MainActor @Test func exportSerializesProjectYarnAndJournalMutations() async throws {
    let blocker = StoreOperationBlocker()
    let fixture = try StoreBackupFixture.make(metadataBlocker: blocker)
    defer {
        blocker.resume()
        fixture.cleanup()
    }
    let store = fixture.store
    let project = try #require(store.projects.first)
    let export = Task { @MainActor in
        try await store.exportBackup(appVersion: "1.0")
    }
    #expect(await Task.detached { blocker.waitUntilBlocked() }.value)

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

@MainActor private struct StoreBackupFixture {
    private struct InjectedFailure: Error {}

    let root: URL
    let liveRoot: URL
    let archiveURL: URL
    let workRoot: URL
    let replacementPackage: URL
    let service: KnitNoteBackupService
    let store: JSONProjectStore

    static func make(
        metadataBlocker: StoreOperationBlocker? = nil,
        stageBlocker: StoreOperationBlocker? = nil,
        journalBlocker: StoreOperationBlocker? = nil,
        patternBlocker: StoreOperationBlocker? = nil,
        replacementBlocker: StoreOperationBlocker? = nil,
        blockedReplacementStep: KnitNoteBackupReplacementStep = .afterStagedMove,
        corruptInstalledArchive: Bool = false,
        failRollback: Bool = false,
        partialCommitCleanupFailure: Bool = false
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
        } else if let stageBlocker {
            service = KnitNoteBackupService(
                liveRoot: liveRoot,
                workRoot: workRoot,
                afterStageCopy: { _ in stageBlocker.blockOnce() }
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
                    if step == .beforeRollback, failRollback {
                        throw InjectedFailure()
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
        let store = JSONProjectStore(
            url: archiveURL,
            journalPhotoService: journalService,
            patternFileService: patternService,
            backupService: service
        )
        return Self(
            root: root,
            liveRoot: liveRoot,
            archiveURL: archiveURL,
            workRoot: workRoot,
            replacementPackage: replacementPackage,
            service: service,
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

private final class StoreOperationBlocker: @unchecked Sendable {
    private let blocked = DispatchSemaphore(value: 0)
    private let continuation = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hasBlocked = false

    func blockOnce() {
        lock.lock()
        guard !hasBlocked else {
            lock.unlock()
            return
        }
        hasBlocked = true
        lock.unlock()
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

private func makeStorePatternPDF(at url: URL) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 100, height: 100)
    let consumer = try #require(CGDataConsumer(url: url as CFURL))
    let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
    context.beginPDFPage(nil)
    context.endPDFPage()
    context.closePDF()
}
