import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KnitNoteCore

@Suite @MainActor
struct JSONProjectStoreYarnLabelTests {
    @Test func addPersistsOneOrTwoManagedLabelPhotos() throws {
        let fixture = makeFixture()
        let yarn = try StoredYarn(name: "Merino")

        try fixture.store.addYarn(
            yarn,
            photoData: nil,
            labelPhotos: [try fixtureJPEG(red: 0.2), try fixtureJPEG(red: 0.7)]
        )

        let saved = try #require(fixture.store.yarn(id: yarn.id))
        #expect(saved.labelPhotoFilenames.count == 2)
        #expect(saved.labelPhotoFilenames.allSatisfy {
            FileManager.default.fileExists(atPath: fixture.labelService.url(filename: $0)?.path ?? "")
        })
        let reloaded = JSONProjectStore(
            url: fixture.archiveURL,
            yarnLabelPhotoService: fixture.labelService
        )
        #expect(reloaded.yarn(id: yarn.id)?.labelPhotoFilenames == saved.labelPhotoFilenames)
    }

    @Test func replaceAndRemoveAllPublishOnlyTheCommittedLabelPhotos() throws {
        let fixture = makeFixture()
        let yarn = try StoredYarn(name: "Cotton")
        try fixture.store.addYarn(
            yarn,
            photoData: nil,
            labelPhotos: [try fixtureJPEG(red: 0.1), try fixtureJPEG(red: 0.2)]
        )
        let oldFilenames = try #require(fixture.store.yarn(id: yarn.id)).labelPhotoFilenames

        try fixture.store.updateYarn(
            yarn,
            photoChange: .unchanged,
            labelPhotoChange: .replace(first: try fixtureJPEG(red: 0.9), second: nil)
        )

        let replaced = try #require(fixture.store.yarn(id: yarn.id))
        #expect(replaced.labelPhotoFilenames.count == 1)
        #expect(replaced.labelPhotoFilenames[0].contains("-label-1-"))
        #expect(oldFilenames.allSatisfy {
            !FileManager.default.fileExists(atPath: fixture.labelService.url(filename: $0)?.path ?? "")
        })

        try fixture.store.updateYarn(
            replaced,
            photoChange: .unchanged,
            labelPhotoChange: .removeAll
        )
        #expect(fixture.store.yarn(id: yarn.id)?.labelPhotoFilenames.isEmpty == true)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.labelService.url(filename: replaced.labelPhotoFilenames[0])?.path ?? ""
        ))
    }

    @Test func removingOneExistingLabelPhotoPreservesTheOtherAndConfirmedText() throws {
        let fixture = makeFixture()
        var yarn = try StoredYarn(name: "Cashmere")
        try yarn.updateLabelDetails(
            ballWeightGrams: 50,
            lengthMeters: 125,
            fiberContent: "100% Cashmere",
            recommendedNeedleMM: nil,
            recommendedHookMM: nil
        )
        try fixture.store.addYarn(
            yarn,
            photoData: nil,
            labelPhotos: [try fixtureJPEG(red: 0.2), try fixtureJPEG(red: 0.6)]
        )
        let saved = try #require(fixture.store.yarn(id: yarn.id))
        let removed = saved.labelPhotoFilenames[0]
        let retained = saved.labelPhotoFilenames[1]

        try fixture.store.updateYarn(
            saved,
            photoChange: .unchanged,
            labelPhotoChange: .retainExisting([retained])
        )

        let updated = try #require(fixture.store.yarn(id: yarn.id))
        #expect(updated.labelPhotoFilenames == [retained])
        #expect(updated.ballWeightGrams == 50)
        #expect(updated.lengthMeters == 125)
        #expect(updated.fiberContent == "100% Cashmere")
        #expect(!FileManager.default.fileExists(
            atPath: try #require(fixture.labelService.url(filename: removed)).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: try #require(fixture.labelService.url(filename: retained)).path
        ))
    }

    @Test func labelPhotoURLKeepsFilenameIdentityWhenAnotherFileIsMissing() throws {
        let fixture = makeFixture()
        let yarn = try StoredYarn(name: "Mohair")
        try fixture.store.addYarn(
            yarn,
            photoData: nil,
            labelPhotos: [try fixtureJPEG(red: 0.2), try fixtureJPEG(red: 0.8)]
        )
        let saved = try #require(fixture.store.yarn(id: yarn.id))
        let missing = saved.labelPhotoFilenames[0]
        let retained = saved.labelPhotoFilenames[1]
        try fixture.labelService.delete(filename: missing)

        #expect(fixture.store.labelPhotoURL(filename: missing) == nil)
        #expect(
            fixture.store.labelPhotoURL(filename: retained)
                == fixture.labelService.url(filename: retained)
        )
    }

    @Test func persistenceFailureRollsBackPublishedLabelPhotosAndYarn() throws {
        let fixture = makeFixture(archiveWrite: { _, _ in throw FixtureError.writeFailed })
        let yarn = try StoredYarn(name: "Silk")

        #expect(throws: ProjectStoreError.persistenceFailed) {
            try fixture.store.addYarn(
                yarn,
                photoData: nil,
                labelPhotos: [try fixtureJPEG(red: 0.4)]
            )
        }

        #expect(fixture.store.yarn(id: yarn.id) == nil)
        #expect(try fixture.labelService.totalStorageBytes() == 0)
    }

    @Test func corruptCandidateDoesNotPersistYarnOrFiles() throws {
        let fixture = makeFixture()
        let yarn = try StoredYarn(name: "Linen")

        #expect(throws: YarnLabelPhotoFileError.invalidImage) {
            try fixture.store.addYarn(
                yarn,
                photoData: nil,
                labelPhotos: [Data("not an image".utf8)]
            )
        }

        #expect(fixture.store.yarn(id: yarn.id) == nil)
        #expect(try fixture.labelService.totalStorageBytes() == 0)
    }

    @Test func deletingYarnRemovesItsManagedLabelPhotos() throws {
        let fixture = makeFixture()
        let yarn = try StoredYarn(name: "Alpaca")
        try fixture.store.addYarn(
            yarn,
            photoData: nil,
            labelPhotos: [try fixtureJPEG(red: 0.5)]
        )
        let filename = try #require(fixture.store.yarn(id: yarn.id)?.labelPhotoFilenames.first)

        try fixture.store.deleteYarn(id: yarn.id)

        #expect(fixture.store.yarn(id: yarn.id) == nil)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.labelService.url(filename: filename)?.path ?? ""
        ))
    }

    @Test func trustedReloadRemovesUnreferencedManagedLabelPhotos() throws {
        let fixture = makeFixture()
        let yarn = try StoredYarn(name: "Wool")
        try fixture.store.addYarn(
            yarn,
            photoData: nil,
            labelPhotos: [try fixtureJPEG(red: 0.3)]
        )
        let retained = try #require(fixture.store.yarn(id: yarn.id)?.labelPhotoFilenames.first)
        let orphan = try fixture.labelService.prepare(
            data: try fixtureJPEG(red: 0.8),
            yarnID: yarn.id,
            ordinal: 2
        )
        try fixture.labelService.publish(orphan)

        _ = JSONProjectStore(
            url: fixture.archiveURL,
            yarnLabelPhotoService: fixture.labelService
        )

        #expect(FileManager.default.fileExists(
            atPath: try #require(fixture.labelService.url(filename: retained)).path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: try #require(fixture.labelService.url(filename: orphan.filename)).path
        ))
    }
}

private enum FixtureError: Error { case writeFailed }

@MainActor
private func makeFixture(
    archiveWrite: @escaping @Sendable (Data, URL) throws -> Void = {
        try $0.write(to: $1, options: .atomic)
    }
) -> (
    store: JSONProjectStore,
    archiveURL: URL,
    labelService: YarnLabelPhotoFileService
) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let archiveURL = root.appendingPathComponent("projects.json")
    let labelService = YarnLabelPhotoFileService(
        directory: root.appendingPathComponent("YarnLabelPhotos", isDirectory: true)
    )
    let backupService = KnitNoteBackupService(
        liveRoot: root,
        workRoot: root.appendingPathComponent("BackupWork", isDirectory: true)
    )
    return (
        JSONProjectStore(
            url: archiveURL,
            yarnLabelPhotoService: labelService,
            backupService: backupService,
            archiveWrite: archiveWrite
        ),
        archiveURL,
        labelService
    )
}

private func fixtureJPEG(red: CGFloat) throws -> Data {
    let context = try #require(CGContext(
        data: nil,
        width: 80,
        height: 40,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: red, green: 0.3, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}
