import CoreGraphics
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
