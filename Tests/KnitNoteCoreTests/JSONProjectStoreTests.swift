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
    let id = first.projects[0].id
    try first.completeRow(id: id)
    try first.rename(id: id, to: "新圍巾")
    let second = JSONProjectStore(url: url)
    #expect(second.projects[0].name == "新圍巾")
    #expect(second.projects[0].currentRow == 1)
    try second.delete(id: id)
    #expect(JSONProjectStore(url: url).projects.isEmpty)
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

@MainActor @Test func storeCreatesReplacesAndRemovesProjectPhoto() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let archiveURL = base.appendingPathComponent("projects.json")
    let photoService = ProjectPhotoFileService(directory: base.appendingPathComponent("photos"))
    let store = JSONProjectStore(url: archiveURL, photoService: photoService)

    try store.add(name: "Sweater", photoData: makeStoreJPEG(red: 0.3))
    let projectID = try #require(store.projects.first?.id)
    let firstFilename = try #require(store.projects.first?.photoFilename)
    #expect(FileManager.default.fileExists(atPath: photoService.url(filename: firstFilename).path))

    try store.completeRow(id: projectID)
    try store.updateProject(id: projectID, name: "Blue sweater", photoChange: .replace(makeStoreJPEG(red: 0.1)))
    let replaced = try #require(store.project(id: projectID))
    let secondFilename = try #require(replaced.photoFilename)
    #expect(replaced.name == "Blue sweater")
    #expect(replaced.currentRow == 1)
    #expect(secondFilename != firstFilename)
    #expect(!FileManager.default.fileExists(atPath: photoService.url(filename: firstFilename).path))
    #expect(FileManager.default.fileExists(atPath: photoService.url(filename: secondFilename).path))

    try store.updateProject(id: projectID, name: "Blue sweater", photoChange: .remove)
    #expect(store.project(id: projectID)?.photoFilename == nil)
    #expect(!FileManager.default.fileExists(atPath: photoService.url(filename: secondFilename).path))

    let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: archiveURL))
    #expect(archive.version == 6)
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
        try store.updateProject(id: project.id, name: "Changed", photoChange: .replace(Data("bad".utf8)))
    }
    #expect(store.project(id: project.id)?.name == "Hat")
    #expect(store.project(id: project.id)?.photoFilename == filename)
    #expect(FileManager.default.fileExists(atPath: photoService.url(filename: filename).path))

    try store.delete(id: project.id)
    #expect(!FileManager.default.fileExists(atPath: photoService.url(filename: filename).path))
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
