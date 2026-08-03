import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KnitNoteCore

@Suite struct YarnLabelPhotoFileServiceTests {
    @Test func filenamesAreOwnedByYarnAndOrdinal() throws {
        let service = YarnLabelPhotoFileService(directory: labelTemporaryDirectory())
        let yarnID = UUID()

        let prepared = try service.prepare(
            data: try labelFixtureJPEG(width: 120, height: 80),
            yarnID: yarnID,
            ordinal: 1
        )

        #expect(prepared.filename.hasPrefix("\(yarnID.uuidString)-label-1-"))
        #expect(StoredYarn.isManagedLabelPhotoFilename(prepared.filename, yarnID: yarnID))
    }

    @Test func thirdPhotoIsRejectedBeforeCreatingStorage() throws {
        let directory = labelTemporaryDirectory()
        let service = YarnLabelPhotoFileService(directory: directory)

        #expect(throws: YarnLabelPhotoFileError.invalidOrdinal) {
            try service.prepare(
                data: try labelFixtureJPEG(width: 40, height: 20),
                yarnID: UUID(),
                ordinal: 3
            )
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func normalizedPhotoIsJPEGWithinDimensionAndMetadataPolicy() throws {
        let service = YarnLabelPhotoFileService(directory: labelTemporaryDirectory())
        let prepared = try service.prepare(
            data: try labelFixtureJPEG(width: 2_400, height: 1_200, orientation: 6),
            yarnID: UUID(),
            ordinal: 1
        )

        let properties = try labelImageProperties(prepared.temporaryURL)
        #expect(properties.width == 800)
        #expect(properties.height == 1_600)
        #expect(properties.exif == nil)
        #expect(properties.tiff == nil)
        #expect(properties.gps == nil)
        #expect(prepared.temporaryURL.pathExtension.lowercased() == "jpg")
    }

    @Test func preparePublishAndRollbackKeepOnlyCommittedFiles() throws {
        let service = YarnLabelPhotoFileService(directory: labelTemporaryDirectory())
        let first = try service.prepare(
            data: try labelFixtureJPEG(width: 100, height: 50),
            yarnID: UUID(),
            ordinal: 1
        )
        try service.publish(first)
        #expect(FileManager.default.fileExists(atPath: try #require(service.url(filename: first.filename)).path))
        #expect(!FileManager.default.fileExists(atPath: first.temporaryURL.path))

        let second = try service.prepare(
            data: try labelFixtureJPEG(width: 100, height: 50),
            yarnID: UUID(),
            ordinal: 2
        )
        try service.rollback(second)
        #expect(!FileManager.default.fileExists(atPath: second.temporaryURL.path))
        #expect(service.url(filename: second.filename) != nil)
        #expect(!FileManager.default.fileExists(atPath: try #require(service.url(filename: second.filename)).path))
    }

    @Test func storageUsageCountsOnlyManagedRegularFiles() throws {
        let directory = labelTemporaryDirectory()
        let service = YarnLabelPhotoFileService(directory: directory)
        let yarnID = UUID()
        let first = try service.prepare(
            data: try labelFixtureJPEG(width: 400, height: 200),
            yarnID: yarnID,
            ordinal: 1
        )
        let second = try service.prepare(
            data: try labelFixtureJPEG(width: 300, height: 150),
            yarnID: yarnID,
            ordinal: 2
        )
        try service.publish(first)
        try service.publish(second)
        let firstURL = try #require(service.url(filename: first.filename))
        let secondURL = try #require(service.url(filename: second.filename))
        let expected = try fileSize(firstURL) + fileSize(secondURL)

        try Data(repeating: 0, count: 99).write(to: directory.appendingPathComponent("unrelated.bin"))
        let symlink = directory.appendingPathComponent("\(UUID().uuidString)-label-1-\(UUID().uuidString).jpg")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: firstURL)

        #expect(try service.totalStorageBytes() == expected)
    }

    @Test func urlRejectsTraversalAbsoluteAndForeignFilenames() {
        let service = YarnLabelPhotoFileService(directory: labelTemporaryDirectory())

        #expect(service.url(filename: "../outside.jpg") == nil)
        #expect(service.url(filename: "/tmp/outside.jpg") == nil)
        #expect(service.url(filename: "label.jpg") == nil)
    }

    @Test func reconciliationDeletesOnlyUnreferencedManagedLabelPhotos() throws {
        let directory = labelTemporaryDirectory()
        let service = YarnLabelPhotoFileService(directory: directory)
        let yarnID = UUID()
        let retained = try service.prepare(
            data: try labelFixtureJPEG(width: 80, height: 40),
            yarnID: yarnID,
            ordinal: 1
        )
        let orphan = try service.prepare(
            data: try labelFixtureJPEG(width: 80, height: 40),
            yarnID: yarnID,
            ordinal: 2
        )
        try service.publish(retained)
        try service.publish(orphan)
        let unrelatedURL = directory.appendingPathComponent("keep-me.txt")
        try Data("not managed by YarnLabelPhotoFileService".utf8).write(to: unrelatedURL)

        try service.reconcile(referencedFilenames: [retained.filename])

        #expect(FileManager.default.fileExists(atPath: try #require(service.url(filename: retained.filename)).path))
        #expect(!FileManager.default.fileExists(atPath: try #require(service.url(filename: orphan.filename)).path))
        #expect(FileManager.default.fileExists(atPath: unrelatedURL.path))
    }
}

private func labelTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func labelFixtureJPEG(width: Int, height: Int, orientation: Int? = nil) throws -> Data {
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ))
    var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
    if let orientation { properties[kCGImagePropertyOrientation] = orientation }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func labelImageProperties(_ url: URL) throws -> (
    width: Int,
    height: Int,
    exif: Any?,
    tiff: Any?,
    gps: Any?
) {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let properties = try #require(
        CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    )
    return (
        try #require(properties[kCGImagePropertyPixelWidth] as? Int),
        try #require(properties[kCGImagePropertyPixelHeight] as? Int),
        properties[kCGImagePropertyExifDictionary],
        properties[kCGImagePropertyTIFFDictionary],
        properties[kCGImagePropertyGPSDictionary]
    )
}

private func fileSize(_ url: URL) throws -> Int64 {
    Int64(try #require(url.resourceValues(forKeys: [.fileSizeKey]).fileSize))
}
