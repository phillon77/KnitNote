import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

@Test func storesAndReloadsAValidatedYouTubeSidecar() throws {
    let root = temporaryYouTubeAssetDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = PatternFileService(root: root)
    let link = try YouTubePatternLink(videoID: "dQw4w9WgXcQ")
    let metadata = YouTubePatternMetadata(link: link)

    let asset = try service.storeYouTubeMetadata(metadata, assetID: UUID())

    #expect(asset.kind == .youtube)
    #expect(asset.pageCount == nil)
    #expect(asset.storedFilename == "\(asset.id.uuidString).youtube")
    #expect(try service.youtubeMetadata(for: asset) == metadata)
}

@Test func rejectsTraversalWrongExtensionAndTamperedSidecars() throws {
    let root = temporaryYouTubeAssetDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = PatternFileService(root: root)
    let id = UUID()
    let validData = try JSONEncoder().encode(
        YouTubePatternMetadata(link: try YouTubePatternLink(videoID: "dQw4w9WgXcQ"))
    )
    let sha = SHA256.hash(data: validData).map { String(format: "%02x", $0) }.joined()

    let traversal = PatternAsset(
        id: id,
        sha256: sha,
        kind: .youtube,
        storedFilename: "../\(id.uuidString).youtube",
        byteCount: Int64(validData.count),
        pageCount: nil
    )
    let wrongExtension = PatternAsset(
        id: id,
        sha256: sha,
        kind: .youtube,
        storedFilename: "\(id.uuidString).json",
        byteCount: Int64(validData.count),
        pageCount: nil
    )

    #expect(throws: PatternFileError.unsafeStoredFilename) { _ = try service.youtubeMetadata(for: traversal) }
    #expect(throws: PatternFileError.unsafeStoredFilename) { _ = try service.youtubeMetadata(for: wrongExtension) }

    let malformed = PatternAsset(
        id: id,
        sha256: sha,
        kind: .youtube,
        storedFilename: "\(id.uuidString).youtube",
        byteCount: Int64(validData.count),
        pageCount: nil
    )
    let malformedURL = try service.assetURL(malformed)
    try FileManager.default.createDirectory(at: malformedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not-json".utf8).write(to: malformedURL, options: .atomic)
    #expect(throws: PatternFileError.invalidContent) { _ = try service.youtubeMetadata(for: malformed) }

    let tamperedURL = try service.assetURL(malformed)
    try validData.write(to: tamperedURL, options: .atomic)
    let wrongHash = PatternAsset(
        id: id,
        sha256: String(repeating: "0", count: 64),
        kind: .youtube,
        storedFilename: "\(id.uuidString).youtube",
        byteCount: Int64(validData.count),
        pageCount: nil
    )
    #expect(throws: PatternFileError.invalidContent) { _ = try service.youtubeMetadata(for: wrongHash) }
}

@Test func rejectsSidecarsWhoseCanonicalURLDisagreesWithVideoID() throws {
    let root = temporaryYouTubeAssetDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = PatternFileService(root: root)
    let id = UUID()
    let data = Data(#"{"canonicalURL":"https:\/\/www.youtube.com\/watch?v=9bZkp7q19f0","version":1,"videoID":"dQw4w9WgXcQ"}"#.utf8)
    let asset = PatternAsset(
        id: id,
        sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
        kind: .youtube,
        storedFilename: "\(id.uuidString).youtube",
        byteCount: Int64(data.count),
        pageCount: nil
    )
    let url = try service.assetURL(asset)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)

    #expect(throws: PatternFileError.invalidContent) { _ = try service.youtubeMetadata(for: asset) }
}

@Test func youtubeAssetsNeverRenderImageThumbnails() throws {
    let root = temporaryYouTubeAssetDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("source.png")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let onePixelPNG = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADElEQVR42mP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"))
    try onePixelPNG.write(to: sourceURL, options: .atomic)
    let thumbnailService = PatternThumbnailFileService(directory: root.appendingPathComponent("thumbnails"))
    let asset = PatternAsset(
        id: UUID(),
        sha256: String(repeating: "0", count: 64),
        kind: .youtube,
        storedFilename: "sidecar.youtube",
        byteCount: 0,
        pageCount: nil
    )

    #expect(throws: PatternThumbnailFileError.unreadableSource) {
        _ = try thumbnailService.thumbnailURL(asset: asset, sourceURL: sourceURL)
    }
}

@Test func youtubeAssetsRejectCachedThumbnails() throws {
    let root = temporaryYouTubeAssetDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let thumbnailService = PatternThumbnailFileService(directory: root.appendingPathComponent("thumbnails"))
    let asset = PatternAsset(
        id: UUID(),
        sha256: String(repeating: "0", count: 64),
        kind: .youtube,
        storedFilename: "sidecar.youtube",
        byteCount: 0,
        pageCount: nil
    )
    let cachedThumbnail = thumbnailService.cachedURL(assetID: asset.id)
    try FileManager.default.createDirectory(at: cachedThumbnail.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("stale-thumbnail".utf8).write(to: cachedThumbnail, options: .atomic)

    #expect(throws: PatternThumbnailFileError.unreadableSource) {
        _ = try thumbnailService.thumbnailURL(asset: asset, sourceURL: root.appendingPathComponent("ignored.png"))
    }
}

@Test func youtubeMetadataRejectsNonYouTubeAssetKinds() throws {
    let root = temporaryYouTubeAssetDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = PatternFileService(root: root)
    let data = try JSONEncoder().encode(
        YouTubePatternMetadata(link: try YouTubePatternLink(videoID: "dQw4w9WgXcQ"))
    )
    let id = UUID()
    let imageAsset = PatternAsset(
        id: id,
        sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
        kind: .image,
        storedFilename: "\(id.uuidString).png",
        byteCount: Int64(data.count),
        pageCount: nil
    )
    let url = try service.assetURL(imageAsset)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)

    #expect(throws: PatternFileError.invalidContent) {
        _ = try service.youtubeMetadata(for: imageAsset)
    }
}

private func temporaryYouTubeAssetDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("KnitNoteYouTubeAssets-\(UUID().uuidString)", isDirectory: true)
}
