import Foundation
import Testing
@testable import KnitNoteCore

@Test func assetURLsRejectTraversalAndMismatchedAssetIdentifiers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = PatternFileService(root: root)
    let id = UUID()
    let traversal = PatternAsset(
        id: id,
        sha256: "0",
        kind: .pdf,
        storedFilename: "../outside.pdf",
        byteCount: 1,
        pageCount: 1
    )
    let mismatched = PatternAsset(
        id: id,
        sha256: "0",
        kind: .pdf,
        storedFilename: "\(UUID().uuidString).pdf",
        byteCount: 1,
        pageCount: 1
    )

    #expect(throws: PatternFileError.unsafeStoredFilename) { _ = try service.assetURL(traversal) }
    #expect(throws: PatternFileError.unsafeStoredFilename) { _ = try service.assetURL(mismatched) }
}

@Test func assetURLsRejectAssetsDirectoryWhosePhysicalParentIsASymlink() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = PatternFileService(root: root)
    let realAssets = root.appendingPathComponent("RealAssets", isDirectory: true)
    try FileManager.default.createDirectory(at: realAssets, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: service.assetsRoot,
        withDestinationURL: realAssets
    )
    let id = UUID()
    let asset = PatternAsset(
        id: id,
        sha256: "0",
        kind: .pdf,
        storedFilename: "\(id.uuidString).pdf",
        byteCount: 1,
        pageCount: 1
    )

    #expect(throws: PatternFileError.unsafeStoredFilename) { _ = try service.assetURL(asset) }
}

@MainActor
@Test func reopeningStoreRejectsArchiveWhoseAssetEscapesAssetsDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let liveRoot = root.appendingPathComponent("KnitNote", isDirectory: true)
    let escaped = liveRoot.appendingPathComponent("Patterns/escaped.pdf")
    try FileManager.default.createDirectory(at: escaped.deletingLastPathComponent(), withIntermediateDirectories: true)
    try makeTestPatternPDF(at: escaped)
    let metadata = try PatternFileService(root: liveRoot.appendingPathComponent("Patterns")).inspect(escaped)
    let asset = PatternAsset(
        sha256: metadata.sha256,
        kind: .pdf,
        storedFilename: "../escaped.pdf",
        byteCount: metadata.byteCount,
        pageCount: metadata.pageCount
    )
    let archive = ProjectArchive(
        version: ProjectArchive.currentVersion,
        projects: [],
        patternAssets: [asset]
    )
    let archiveURL = liveRoot.appendingPathComponent("projects-v1.json")
    try JSONEncoder().encode(archive).write(to: archiveURL, options: .atomic)

    let reopened = JSONProjectStore(url: archiveURL)

    #expect(reopened.loadError == .unreadableArchive)
}
