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

func shippingPatternFolderNameContext(
    locale: Locale = Locale(identifier: "en")
) throws -> PatternFolderNameContext {
    let translations = try shippingPatternFolderTranslations()
    return PatternFolderNameContext(
        locale: locale,
        reservedNames: Set(translations.values.flatMap(\.values))
    )
}

func shippingPatternFolderLocalizationBundle() throws -> Bundle {
    let translations = try shippingPatternFolderTranslations()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PatternFolderLocalization-\(UUID().uuidString).bundle")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": "KnitNoteTests.PatternFolderLocalization.\(UUID().uuidString)",
        "CFBundleDevelopmentRegion": "en",
        "CFBundleLocalizations": SupportedLocalization.v150Identifiers,
    ]
    try PropertyListSerialization.data(
        fromPropertyList: info,
        format: .xml,
        options: 0
    ).write(to: root.appendingPathComponent("Info.plist"))
    for (identifier, values) in translations {
        let localization = root.appendingPathComponent("\(identifier).lproj")
        try FileManager.default.createDirectory(at: localization, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: values,
            format: .binary,
            options: 0
        ).write(to: localization.appendingPathComponent("Localizable.strings"))
    }
    guard let bundle = Bundle(url: root) else { throw CocoaError(.fileReadCorruptFile) }
    return bundle
}

private func shippingPatternFolderTranslations() throws -> [String: [String: String]] {
    let data = try Data(contentsOf: patternLibraryRepositoryURL(
        "KnitNote/Localization/Localizable.xcstrings"
    ))
    let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let strings = catalog?["strings"] as? [String: Any]
    var translations = Dictionary(
        uniqueKeysWithValues: SupportedLocalization.v150Identifiers.map { ($0, [String: String]()) }
    )
    for key in ["patterns.folder.all", "patterns.folder.uncategorized"] {
        guard let entry = strings?[key] as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for identifier in SupportedLocalization.v150Identifiers {
            guard let localization = localizations[identifier] as? [String: Any],
                  let unit = localization["stringUnit"] as? [String: Any],
                  let value = unit["value"] as? String else {
                throw CocoaError(.fileReadCorruptFile)
            }
            translations[identifier]?[key] = value
        }
    }
    return translations
}

@MainActor
final class PatternImportHarness {
    let root: URL
    let sourceRoot: URL
    let assetsRoot: URL
    let archiveURL: URL
    let inbox: PatternInboxFileService
    let store: JSONProjectStore
    let thumbnailService: PatternThumbnailFileService

    init(
        archiveWrite: (@Sendable (Data, URL) throws -> Void)? = nil,
        assetMove: (@Sendable (URL, URL) throws -> Void)? = nil,
        inboxMove: (@Sendable (URL, URL) throws -> Void)? = nil,
        inboxRemove: (@Sendable (URL) throws -> Void)? = nil,
        inboxWrite: (@Sendable (Data, URL) throws -> Void)? = nil,
        thumbnailService: PatternThumbnailFileService? = nil
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
        self.thumbnailService = thumbnailService ?? PatternThumbnailFileService(
            directory: root.appendingPathComponent("ThumbnailCache", isDirectory: true)
        )
        inbox = PatternInboxFileService(
            root: locations.inboxRoot,
            moveItem: inboxMove ?? { try FileManager.default.moveItem(at: $0, to: $1) },
            removeItem: inboxRemove ?? { try FileManager.default.removeItem(at: $0) },
            writeData: inboxWrite ?? { try $0.write(to: $1, options: .atomic) }
        )
        let nameContext = try shippingPatternFolderNameContext()
        store = JSONProjectStore(
            url: archiveURL,
            patternFileService: PatternFileService(
                root: locations.assetRoot,
                moveFile: assetMove ?? { try FileManager.default.moveItem(at: $0, to: $1) }
            ),
            patternInboxFileService: inbox,
            patternThumbnailService: self.thumbnailService,
            patternFolderNameContext: nameContext,
            backupService: KnitNoteBackupService(
                liveRoot: root,
                workRoot: root.appendingPathComponent(".BackupWork", isDirectory: true),
                patternFolderNameContext: nameContext
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
        let nameContext = try shippingPatternFolderNameContext()
        return JSONProjectStore(
            url: archiveURL,
            patternFileService: PatternFileService(root: assetsRoot),
            patternInboxFileService: PatternInboxFileService(root: inbox.root),
            patternThumbnailService: thumbnailService,
            patternFolderNameContext: nameContext
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
