import CoreGraphics
import Foundation
@testable import KnitNoteCore

func makeTestPatternPDF(at url: URL, pageCount: Int = 1) throws {
    let pageCount = max(1, pageCount)
    guard let context = CGContext(url as CFURL, mediaBox: nil, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }

    let mediaBox = CGRect(x: 0, y: 0, width: 100, height: 100)
    for _ in 0..<pageCount {
        context.beginPDFPage([kCGPDFContextMediaBox as String: mediaBox] as CFDictionary)
        context.endPDFPage()
    }
    context.closePDF()
}

func readRepositoryFile(_ relativePath: String) throws -> String {
    try String(contentsOf: patternLibraryRepositoryURL(relativePath), encoding: .utf8)
}

func patternLibraryRepositoryURL(_ relativePath: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(relativePath)
}

@MainActor
final class PatternImportHarness {
    let root: URL
    let sourceRoot: URL
    let assetsRoot: URL
    let archiveURL: URL
    let inbox: PatternInboxFileService
    let store: JSONProjectStore

    init(
        archiveWrite: (@Sendable (Data, URL) throws -> Void)? = nil,
        assetMove: (@Sendable (URL, URL) throws -> Void)? = nil,
        inboxRemove: (@Sendable (URL) throws -> Void)? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatternImportHarness-\(UUID().uuidString)", isDirectory: true)
        sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let locations = PatternStorageLocations(
            assetRoot: root.appendingPathComponent("Patterns", isDirectory: true),
            inboxRoot: root.appendingPathComponent("PatternInbox", isDirectory: true)
        )
        assetsRoot = locations.assetRoot
        archiveURL = root.appendingPathComponent("projects-v1.json")
        inbox = PatternInboxFileService(
            root: locations.inboxRoot,
            moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
            removeItem: inboxRemove ?? { try FileManager.default.removeItem(at: $0) },
            writeData: { try $0.write(to: $1, options: .atomic) }
        )
        store = JSONProjectStore(
            url: archiveURL,
            patternFileService: PatternFileService(
                root: locations.assetRoot,
                moveFile: assetMove ?? { try FileManager.default.moveItem(at: $0, to: $1) }
            ),
            patternInboxFileService: inbox,
            backupService: KnitNoteBackupService(
                liveRoot: root,
                workRoot: root.appendingPathComponent(".BackupWork", isDirectory: true)
            ),
            archiveWrite: archiveWrite ?? { try $0.write(to: $1, options: .atomic) }
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func makePDF(named name: String) throws -> URL {
        let url = sourceRoot.appendingPathComponent(name)
        try makeTestPatternPDF(at: url)
        return url
    }

    func writeFile(named name: String, bytes: Data) throws -> URL {
        let url = sourceRoot.appendingPathComponent(name)
        try bytes.write(to: url, options: .atomic)
        return url
    }

    func importURL(_ url: URL) async throws -> PatternImportOutcome {
        let item = try inbox.enqueue(source: url, origin: .library, targetProjectID: nil, now: .now)
        return try await store.processPatternInboxItem(id: item.id)
    }

    func enqueueMatchingFile() throws -> PatternInboxItem {
        let url = sourceRoot.appendingPathComponent("Matching.pdf")
        if !FileManager.default.fileExists(atPath: url.path) {
            try makeTestPatternPDF(at: url)
        }
        return try inbox.enqueue(source: url, origin: .shareExtension, targetProjectID: nil, now: .now)
    }

    func reopenedStore() throws -> JSONProjectStore {
        JSONProjectStore(
            url: archiveURL,
            patternFileService: PatternFileService(root: assetsRoot),
            patternInboxFileService: PatternInboxFileService(root: inbox.root)
        )
    }

    func assetURLFor(source: URL) throws -> URL {
        let metadata = try PatternFileService(root: assetsRoot).inspect(source)
        let asset = PatternAsset(
            id: PatternImportCoordinator().deterministicAssetID(for: metadata.sha256),
            sha256: metadata.sha256,
            kind: metadata.kind,
            storedFilename: "\(PatternImportCoordinator().deterministicAssetID(for: metadata.sha256).uuidString).\(metadata.fileExtension)",
            byteCount: metadata.byteCount,
            pageCount: metadata.pageCount
        )
        return try PatternFileService(root: assetsRoot).assetURL(asset)
    }

    func archivePatternCount() -> Int {
        (try? JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: archiveURL)))?.patterns.count ?? 0
    }

    static func withTwoNamesForOneAsset() async throws -> PatternImportHarness {
        let harness = try PatternImportHarness()
        let source = try harness.makePDF(named: "Original.pdf")
        let bytes = try Data(contentsOf: source)
        let first = try harness.writeFile(named: "Alpha.pdf", bytes: bytes)
        _ = try harness.writeFile(named: "Matching.pdf", bytes: bytes)
        _ = try await harness.importURL(first)
        guard let asset = harness.store.patternAssets.first,
              let firstPattern = harness.store.patterns.first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let secondPattern = StoredPattern(
            assetID: asset.id,
            displayName: "Beta",
            createdAt: firstPattern.createdAt
        )
        let archive = ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: [],
            patternAssets: [asset],
            patterns: [firstPattern, secondPattern]
        )
        try JSONEncoder().encode(archive).write(
            to: harness.archiveURL,
            options: .atomic
        )
        try harness.store.reloadFromDisk()
        return harness
    }
}
