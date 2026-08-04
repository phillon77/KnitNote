import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KnitNoteCore

@Suite struct YouTubeThumbnailCacheTests {
    @Test func rejectsEmptyAndNonImageExternalThumbnailData() throws {
        let root = try makeThumbnailCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = PatternThumbnailFileService(directory: root.appendingPathComponent("cache"))

        #expect(throws: PatternThumbnailFileError.unreadableSource) {
            try service.storeExternalThumbnail(data: Data(), assetID: UUID())
        }
        #expect(throws: PatternThumbnailFileError.unreadableSource) {
            try service.storeExternalThumbnail(data: Data("not an image".utf8), assetID: UUID())
        }
    }

    @Test func rejectsInputBytesAndDimensionsBeyondTheExternalThumbnailSafetyCaps() throws {
        let root = try makeThumbnailCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = PatternThumbnailFileService(directory: root.appendingPathComponent("cache"))

        #expect(throws: PatternThumbnailFileError.unreadableSource) {
            try service.storeExternalThumbnail(
                data: Data(repeating: 0, count: PatternThumbnailFileService.maximumExternalThumbnailBytes + 1),
                assetID: UUID()
            )
        }
        #expect(throws: PatternThumbnailFileError.unreadableSource) {
            try service.storeExternalThumbnail(
                data: try makePNG(width: PatternThumbnailFileService.maximumExternalThumbnailDimension + 1, height: 1),
                assetID: UUID()
            )
        }
    }

    @Test func rejectsAThumbnailDestinationThatEscapesThroughASymlink() throws {
        let root = try makeThumbnailCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let assetID = UUID()
        let outside = root.appendingPathComponent("outside.jpg")
        let destination = cache.appendingPathComponent("\(assetID.uuidString).jpg")
        try Data("keep me".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
        let service = PatternThumbnailFileService(directory: cache)

        #expect(throws: PatternThumbnailFileError.unreadableSource) {
            try service.storeExternalThumbnail(data: try makePNG(width: 2, height: 2), assetID: assetID)
        }
        #expect(try Data(contentsOf: outside) == Data("keep me".utf8))
    }

    @Test func rejectsAThumbnailCacheDirectoryThatEscapesThroughASymlink() throws {
        let root = try makeThumbnailCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: outside)
        let assetID = UUID()
        let service = PatternThumbnailFileService(directory: cache)

        #expect(throws: PatternThumbnailFileError.unreadableSource) {
            try service.storeExternalThumbnail(data: try makePNG(width: 2, height: 2), assetID: assetID)
        }
        #expect(!FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("\(assetID.uuidString).jpg").path
        ))
    }

    @Test func acceptedExternalThumbnailIsDownsampledAsJPEGAtTheCacheURL() throws {
        let root = try makeThumbnailCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = PatternThumbnailFileService(
            directory: root.appendingPathComponent("cache"),
            maxPixelSize: 200
        )
        let assetID = UUID()

        let destination = try service.storeExternalThumbnail(
            data: try makePNG(width: 1_600, height: 800),
            assetID: assetID
        )

        #expect(destination == service.cachedURL(assetID: assetID))
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let source = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        #expect(CGImageSourceGetType(source) == UTType.jpeg.identifier as CFString)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 200)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 100)
    }

    @Test @MainActor func cachesOnlyForAPersistedYouTubePattern() async throws {
        let root = try makeThumbnailCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("archive.json")
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [])
        try JSONEncoder().encode(archive).write(to: archiveURL, options: .atomic)

        let thumbnailService = PatternThumbnailFileService(
            directory: root.appendingPathComponent("thumbnails", isDirectory: true)
        )
        let patternsRoot = root.appendingPathComponent("patterns", isDirectory: true)
        let store = JSONProjectStore(
            url: archiveURL,
            patternFileService: PatternFileService(root: patternsRoot),
            patternInboxFileService: PatternInboxFileService(
                root: root.appendingPathComponent("PatternInbox", isDirectory: true)
            ),
            patternPublicationReceiptService: PatternInboxPublicationReceiptService(root: patternsRoot),
            patternThumbnailService: thumbnailService,
            backupService: KnitNoteBackupService(
                liveRoot: root,
                workRoot: root.appendingPathComponent(".BackupWork", isDirectory: true)
            )
        )
        let link = try YouTubePatternLink(videoID: "abcdefghijk")
        let added = try await store.addYouTubePattern(link: link, title: "Video pattern")
        let thumbnail = try makePNG(width: 8, height: 8)

        await store.cacheYouTubeThumbnail(thumbnail, patternID: added.patternID)

        let storedPattern = try #require(store.patterns.first(where: { $0.id == added.patternID }))
        #expect(FileManager.default.fileExists(
            atPath: thumbnailService.cachedURL(assetID: storedPattern.assetID).path
        ))

        await store.cacheYouTubeThumbnail(thumbnail, patternID: UUID())
        #expect(FileManager.default.fileExists(
            atPath: thumbnailService.cachedURL(assetID: storedPattern.assetID).path
        ))
    }
}

private func makeThumbnailCacheRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("YouTubeThumbnailCacheTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makePNG(width: Int, height: Int) throws -> Data {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = context.makeImage() else {
        throw PatternThumbnailFileError.renderingFailed
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        output,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw PatternThumbnailFileError.encodingFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw PatternThumbnailFileError.encodingFailed
    }
    return output as Data
}
