import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KnitNoteCore

@Suite struct ProjectJournalPhotoFileServiceTests {
    @Test func saveCreatesUniqueFullAndThumbnailFiles() throws {
        let service = ProjectJournalPhotoFileService(directory: temporaryDirectory())
        let projectID = UUID()
        let entryID = UUID()

        let first = try service.save(
            data: try fixtureJPEG(width: 2_400, height: 1_200),
            projectID: projectID,
            entryID: entryID
        )
        let second = try service.save(
            data: try fixtureJPEG(width: 2_400, height: 1_200),
            projectID: projectID,
            entryID: entryID
        )

        #expect(first != second)
        #expect(first.photoFilename.hasPrefix("\(projectID.uuidString)-\(entryID.uuidString)-"))
        #expect(first.photoFilename.hasSuffix("-full.jpg"))
        #expect(first.thumbnailFilename.hasSuffix("-thumb.jpg"))
        #expect(FileManager.default.fileExists(atPath: try #require(service.url(filename: first.photoFilename)).path))
        #expect(FileManager.default.fileExists(atPath: try #require(service.url(filename: first.thumbnailFilename)).path))
    }

    @Test func fullImageIsLimitedTo1600WithoutUpscaling() throws {
        let service = ProjectJournalPhotoFileService(directory: temporaryDirectory())

        let large = try service.save(
            data: try fixtureJPEG(width: 2_400, height: 1_200),
            projectID: UUID(),
            entryID: UUID()
        )
        #expect(try pixelSize(try #require(service.url(filename: large.photoFilename))) == CGSize(width: 1_600, height: 800))

        let small = try service.save(
            data: try fixtureJPEG(width: 640, height: 480),
            projectID: UUID(),
            entryID: UUID()
        )
        #expect(try pixelSize(try #require(service.url(filename: small.photoFilename))) == CGSize(width: 640, height: 480))
    }

    @Test func thumbnailUsesIndependent360PixelLongEdge() throws {
        let service = ProjectJournalPhotoFileService(directory: temporaryDirectory())
        let files = try service.save(
            data: try fixtureJPEG(width: 2_400, height: 1_200),
            projectID: UUID(),
            entryID: UUID()
        )

        #expect(try pixelSize(try #require(service.url(filename: files.thumbnailFilename))) == CGSize(width: 360, height: 180))
    }

    @Test func saveNormalizesEXIFOrientation() throws {
        let service = ProjectJournalPhotoFileService(directory: temporaryDirectory())
        let files = try service.save(
            data: try fixtureJPEG(width: 300, height: 100, orientation: 6),
            projectID: UUID(),
            entryID: UUID()
        )

        #expect(try pixelSize(try #require(service.url(filename: files.photoFilename))) == CGSize(width: 100, height: 300))
    }

    @Test func saveRejectsInvalidImageDataBeforeCreatingDirectory() throws {
        let directory = temporaryDirectory()
        let service = ProjectJournalPhotoFileService(directory: directory)

        #expect(throws: ProjectJournalPhotoFileError.invalidImage) {
            try service.save(data: Data("not an image".utf8), projectID: UUID(), entryID: UUID())
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func deleteRemovesBothFilesAndIsIdempotent() throws {
        let service = ProjectJournalPhotoFileService(directory: temporaryDirectory())
        let files = try service.save(
            data: try fixtureJPEG(width: 40, height: 20),
            projectID: UUID(),
            entryID: UUID()
        )

        try service.delete(files: files)
        try service.delete(files: files)

        #expect(!FileManager.default.fileExists(atPath: try #require(service.url(filename: files.photoFilename)).path))
        #expect(!FileManager.default.fileExists(atPath: try #require(service.url(filename: files.thumbnailFilename)).path))
    }

    @Test func deleteRemovesTheRemainingFileWhenItsPairIsAlreadyPartlyMissing() throws {
        let service = ProjectJournalPhotoFileService(directory: temporaryDirectory())
        let files = try service.save(
            data: try fixtureJPEG(width: 40, height: 20),
            projectID: UUID(),
            entryID: UUID()
        )
        try FileManager.default.removeItem(at: try #require(service.url(filename: files.photoFilename)))

        try service.delete(files: files)

        #expect(!FileManager.default.fileExists(atPath: try #require(service.url(filename: files.thumbnailFilename)).path))
    }

    @Test func urlRejectsTraversalAbsoluteAndNonManagedFilenames() {
        let service = ProjectJournalPhotoFileService(directory: temporaryDirectory())

        #expect(service.url(filename: "../outside.jpg") == nil)
        #expect(service.url(filename: "/tmp/outside.jpg") == nil)
        #expect(service.url(filename: "full.jpg") == nil)
    }

    @Test func reconcileRemovesOnlyUnreferencedManagedFiles() throws {
        let directory = temporaryDirectory()
        let service = ProjectJournalPhotoFileService(directory: directory)
        let retained = try service.save(
            data: try fixtureJPEG(width: 40, height: 20),
            projectID: UUID(),
            entryID: UUID()
        )
        let orphan = try service.save(
            data: try fixtureJPEG(width: 40, height: 20),
            projectID: UUID(),
            entryID: UUID()
        )
        let unrelated = directory.appendingPathComponent("keep-me.txt")
        try Data("not managed by ProjectJournalPhotoFileService".utf8).write(to: unrelated)

        try service.reconcile(referencedFilenames: [retained.photoFilename, retained.thumbnailFilename])

        #expect(FileManager.default.fileExists(atPath: try #require(service.url(filename: retained.photoFilename)).path))
        #expect(FileManager.default.fileExists(atPath: try #require(service.url(filename: retained.thumbnailFilename)).path))
        #expect(!FileManager.default.fileExists(atPath: try #require(service.url(filename: orphan.photoFilename)).path))
        #expect(!FileManager.default.fileExists(atPath: try #require(service.url(filename: orphan.thumbnailFilename)).path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func secondWriteFailureRollsBackTheFullCandidate() throws {
        let directory = temporaryDirectory()
        let writer = FailSecondWrite()
        let service = ProjectJournalPhotoFileService(directory: directory, writeData: writer.write)

        #expect(throws: FailSecondWrite.Error.expected) {
            try service.save(data: try fixtureJPEG(width: 40, height: 20), projectID: UUID(), entryID: UUID())
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true)
    }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func fixtureJPEG(width: Int, height: Int, orientation: Int? = nil) throws -> Data {
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.4, green: 0.3, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
    var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
    if let orientation {
        properties[kCGImagePropertyOrientation] = orientation
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func pixelSize(_ url: URL) throws -> CGSize {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    return CGSize(
        width: try #require(properties[kCGImagePropertyPixelWidth] as? Int),
        height: try #require(properties[kCGImagePropertyPixelHeight] as? Int)
    )
}

private final class FailSecondWrite: @unchecked Sendable {
    enum Error: Swift.Error { case expected }

    private var writes = 0

    func write(_ data: Data, _ url: URL) throws {
        writes += 1
        guard writes != 2 else { throw Error.expected }
        try data.write(to: url, options: .atomic)
    }
}
