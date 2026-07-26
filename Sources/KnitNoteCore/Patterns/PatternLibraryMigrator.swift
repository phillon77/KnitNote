import CryptoKit
import CoreGraphics
import Foundation
import ImageIO

public enum PatternMigrationStep: Sendable {
    case afterLegacyValidation
    case afterStaging
    case beforeInstall
    case afterInstall
}

public struct MigratedPatternLibrary: Sendable {
    public let archive: ProjectArchive
    public let stagedRoot: URL

    public var assets: [PatternAsset] { archive.patternAssets }
    public var patterns: [StoredPattern] { archive.patterns }
    public var usages: [PatternProjectUsage] { archive.patternUsages }
}

public enum PatternLibraryMigrationError: Error, Equatable, Sendable {
    case unsupportedArchiveVersion
    case unsafeLegacyFilename
    case missingLegacyFile
    case emptyLegacyFile
    case invalidLegacyFile
    case duplicateLegacyPatternID
    case incompatibleSharedAsset
    case emptyDisplayName
    case rollbackFailed
}

public struct PatternLibraryMigrator: Sendable {
    private let stepHook: @Sendable (PatternMigrationStep) throws -> Void

    public init(
        stepHook: @escaping @Sendable (PatternMigrationStep) throws -> Void = { _ in }
    ) {
        self.stepHook = stepHook
    }

    public func migrate(
        archive: ProjectArchive,
        liveRoot: URL
    ) throws -> MigratedPatternLibrary {
        guard (ProjectArchive.minimumSupportedVersion...9).contains(archive.version) else {
            throw PatternLibraryMigrationError.unsupportedArchiveVersion
        }

        let legacyDocuments = archive.projects.flatMap { project in
            project.legacyPatternDocuments.enumerated().map { offset, document in
                LegacyDocument(project: project, document: document, sortOrder: offset)
            }
        }
        guard Set(legacyDocuments.map(\.document.id)).count == legacyDocuments.count else {
            throw PatternLibraryMigrationError.duplicateLegacyPatternID
        }

        let validatedDocuments = try legacyDocuments.map { legacy in
            try ValidatedLegacyDocument(legacy: legacy, liveRoot: liveRoot)
        }
        try stepHook(.afterLegacyValidation)

        let stagedRoot = liveRoot.appendingPathComponent(
            ".KnitNote-PatternMigration-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: stagedRoot, withIntermediateDirectories: true)
            try JSONEncoder().encode(MigrationTransaction()).write(
                to: stagedRoot.appendingPathComponent("transaction.json"),
                options: .atomic
            )
            let stagedPatternsRoot = stagedRoot.appendingPathComponent("Patterns", isDirectory: true)
            let livePatternsRoot = liveRoot.appendingPathComponent("Patterns", isDirectory: true)
            if FileManager.default.fileExists(atPath: livePatternsRoot.path) {
                try FileManager.default.copyItem(at: livePatternsRoot, to: stagedPatternsRoot)
            }

            let migrated = try makeArchive(
                from: archive,
                documents: validatedDocuments,
                liveRoot: liveRoot,
                stagedPatternsRoot: stagedPatternsRoot
            )
            try JSONEncoder().encode(migrated).write(
                to: stagedRoot.appendingPathComponent("archive.json"),
                options: .atomic
            )
            try stepHook(.afterStaging)
            return MigratedPatternLibrary(archive: migrated, stagedRoot: stagedRoot)
        } catch {
            try? FileManager.default.removeItem(at: stagedRoot)
            throw error
        }
    }

    public func migrateOnDisk(archiveURL: URL) throws {
        try recoverInterruptedMigration(archiveURL: archiveURL)
        let liveRoot = archiveURL.deletingLastPathComponent()
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: archiveURL))
        let migrated = try migrate(archive: archive, liveRoot: liveRoot)
        let fileManager = FileManager.default
        let stagedArchiveURL = migrated.stagedRoot.appendingPathComponent("archive.json")
        let stagedPatternsRoot = migrated.stagedRoot.appendingPathComponent("Patterns", isDirectory: true)
        let livePatternsRoot = liveRoot.appendingPathComponent("Patterns", isDirectory: true)
        let rollbackRoot = migrated.stagedRoot.appendingPathComponent("Rollback", isDirectory: true)
        let rollbackArchiveURL = rollbackRoot.appendingPathComponent("archive.json")
        let rollbackPatternsRoot = rollbackRoot.appendingPathComponent("Patterns", isDirectory: true)
        var movedArchive = false
        var movedPatterns = false
        var installedArchive = false
        var installedPatterns = false

        do {
            try stepHook(.beforeInstall)
            try fileManager.createDirectory(at: rollbackRoot, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: archiveURL.path) {
                try fileManager.moveItem(at: archiveURL, to: rollbackArchiveURL)
                movedArchive = true
            }
            if fileManager.fileExists(atPath: livePatternsRoot.path) {
                try fileManager.moveItem(at: livePatternsRoot, to: rollbackPatternsRoot)
                movedPatterns = true
            }
            try fileManager.moveItem(at: stagedArchiveURL, to: archiveURL)
            installedArchive = true
            if fileManager.fileExists(atPath: stagedPatternsRoot.path) {
                try fileManager.moveItem(at: stagedPatternsRoot, to: livePatternsRoot)
                installedPatterns = true
            }

            try validateInstalledArchive(at: archiveURL, liveRoot: liveRoot)
            try stepHook(.afterInstall)
            try? fileManager.removeItem(at: migrated.stagedRoot)
        } catch {
            do {
                if installedArchive, fileManager.fileExists(atPath: archiveURL.path) {
                    try fileManager.removeItem(at: archiveURL)
                }
                if installedPatterns, fileManager.fileExists(atPath: livePatternsRoot.path) {
                    try fileManager.removeItem(at: livePatternsRoot)
                }
                if movedArchive, fileManager.fileExists(atPath: rollbackArchiveURL.path) {
                    try fileManager.moveItem(at: rollbackArchiveURL, to: archiveURL)
                }
                if movedPatterns, fileManager.fileExists(atPath: rollbackPatternsRoot.path) {
                    try fileManager.moveItem(at: rollbackPatternsRoot, to: livePatternsRoot)
                }
                try? fileManager.removeItem(at: migrated.stagedRoot)
            } catch {
                throw PatternLibraryMigrationError.rollbackFailed
            }
            throw error
        }
    }

    func recoverInterruptedMigration(archiveURL: URL) throws {
        let liveRoot = archiveURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: liveRoot.path) else { return }
        let transactions = try fileManager.contentsOfDirectory(
            at: liveRoot,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(".KnitNote-PatternMigration-")
                && fileManager.fileExists(atPath: $0.appendingPathComponent("transaction.json").path)
        }

        for transactionRoot in transactions {
            let rollbackRoot = transactionRoot.appendingPathComponent("Rollback", isDirectory: true)
            let rollbackArchiveURL = rollbackRoot.appendingPathComponent("archive.json")
            let rollbackPatternsRoot = rollbackRoot.appendingPathComponent("Patterns", isDirectory: true)
            guard fileManager.fileExists(atPath: rollbackArchiveURL.path) else {
                continue
            }

            if (try? validateCurrentArchive(at: archiveURL, liveRoot: liveRoot)) != nil {
                try? fileManager.removeItem(at: transactionRoot)
                continue
            }

            do {
                if fileManager.fileExists(atPath: archiveURL.path) {
                    try fileManager.removeItem(at: archiveURL)
                }
                try fileManager.moveItem(at: rollbackArchiveURL, to: archiveURL)
                if fileManager.fileExists(atPath: rollbackPatternsRoot.path) {
                    let livePatternsRoot = liveRoot.appendingPathComponent("Patterns", isDirectory: true)
                    if fileManager.fileExists(atPath: livePatternsRoot.path) {
                        try fileManager.removeItem(at: livePatternsRoot)
                    }
                    try fileManager.moveItem(at: rollbackPatternsRoot, to: livePatternsRoot)
                }
                try? fileManager.removeItem(at: transactionRoot)
            } catch {
                throw PatternLibraryMigrationError.rollbackFailed
            }
        }
    }

    func validateCurrentArchive(at archiveURL: URL) throws {
        try validateCurrentArchive(at: archiveURL, liveRoot: archiveURL.deletingLastPathComponent())
    }

    private func makeArchive(
        from archive: ProjectArchive,
        documents: [ValidatedLegacyDocument],
        liveRoot: URL,
        stagedPatternsRoot: URL
    ) throws -> ProjectArchive {
        var assets = archive.patternAssets
        var patterns = archive.patterns
        var usages = archive.patternUsages
        var assetIDsByHash: [String: UUID] = [:]
        for asset in assets where assetIDsByHash[asset.sha256] == nil {
            assetIDsByHash[asset.sha256] = asset.id
        }
        var patternIDsByKey: [PatternKey: UUID] = [:]
        var usagePairs = Set(usages.map { PatternProjectUsagePair(
            patternID: $0.patternID,
            projectID: $0.projectID
        ) })
        let markupSource = PatternMarkupFileService(
            root: liveRoot.appendingPathComponent("Patterns", isDirectory: true)
        )
        let markupDestination = PatternMarkupFileService(root: stagedPatternsRoot)

        for document in documents {
            let assetID: UUID
            if let existingAssetID = assetIDsByHash[document.sha256] {
                guard let existing = assets.first(where: { $0.id == existingAssetID }),
                      existing.kind == document.document.kind else {
                    throw PatternLibraryMigrationError.incompatibleSharedAsset
                }
                assetID = existingAssetID
            } else {
                assetID = Self.deterministicUUID(fromSHA256: document.sha256)
                let asset = PatternAsset(
                    id: assetID,
                    sha256: document.sha256,
                    kind: document.document.kind,
                    storedFilename: "\(assetID.uuidString).\(document.fileExtension)",
                    byteCount: document.byteCount,
                    pageCount: document.pageCount
                )
                assets.append(asset)
                assetIDsByHash[document.sha256] = assetID
                let assetURL = stagedPatternsRoot
                    .appendingPathComponent("Assets", isDirectory: true)
                    .appendingPathComponent(asset.storedFilename)
                try FileManager.default.createDirectory(
                    at: assetURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: document.sourceURL, to: assetURL)
            }

            let patternKey = PatternKey(sha256: document.sha256, normalizedName: document.normalizedName)
            let patternID: UUID
            if let existingPatternID = patternIDsByKey[patternKey],
               !usagePairs.contains(.init(patternID: existingPatternID, projectID: document.project.id)) {
                patternID = existingPatternID
            } else {
                patternID = document.document.id
                patterns.append(
                    StoredPattern(
                        id: patternID,
                        assetID: assetID,
                        displayName: document.displayName,
                        createdAt: document.document.createdAt,
                        lastOpenedAt: document.document.lastOpenedAt
                    )
                )
                patternIDsByKey[patternKey] = patternID
            }

            usages.append(
                PatternProjectUsage(
                    id: document.document.id,
                    patternID: patternID,
                    projectID: document.project.id,
                    linkedAt: document.document.createdAt,
                    sortOrder: document.sortOrder,
                    readingState: document.document.readingState
                )
            )
            usagePairs.insert(.init(patternID: patternID, projectID: document.project.id))
            try markupDestination.copyLegacyMarkup(
                from: markupSource,
                projectID: document.project.id,
                patternID: document.document.id,
                usageID: document.document.id
            )
            try removeLegacyFiles(
                for: document,
                stagedPatternsRoot: stagedPatternsRoot
            )
        }

        let clearedProjects = try archive.projects.map(Self.clearingLegacyPatterns)
        let migrated = ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: clearedProjects,
            yarns: archive.yarns,
            patternAssets: assets,
            patterns: patterns,
            patternUsages: usages
        )
        _ = try PatternLibrarySnapshot(
            assets: migrated.patternAssets,
            patterns: migrated.patterns,
            usages: migrated.patternUsages,
            validProjectIDs: migrated.projects.map(\.id)
        ).validated()
        return migrated
    }

    private func removeLegacyFiles(
        for document: ValidatedLegacyDocument,
        stagedPatternsRoot: URL
    ) throws {
        let projectDirectory = stagedPatternsRoot.appendingPathComponent(document.project.id.uuidString)
        let stagedFile = projectDirectory.appendingPathComponent(document.document.storedFilename)
        if FileManager.default.fileExists(atPath: stagedFile.path) {
            try FileManager.default.removeItem(at: stagedFile)
        }
        let stagedMarkup = projectDirectory
            .appendingPathComponent("Markup")
            .appendingPathComponent(document.document.id.uuidString)
        if FileManager.default.fileExists(atPath: stagedMarkup.path) {
            try FileManager.default.removeItem(at: stagedMarkup)
        }
    }

    private func validateInstalledArchive(at archiveURL: URL, liveRoot: URL) throws {
        try validateCurrentArchive(at: archiveURL, liveRoot: liveRoot)
    }

    private func validateCurrentArchive(at archiveURL: URL, liveRoot: URL) throws {
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: archiveURL))
        guard archive.version == ProjectArchive.currentVersion else {
            throw PatternLibraryMigrationError.invalidLegacyFile
        }
        _ = try PatternLibrarySnapshot(
            assets: archive.patternAssets,
            patterns: archive.patterns,
            usages: archive.patternUsages,
            validProjectIDs: archive.projects.map(\.id)
        ).validated()
        for asset in archive.patternAssets {
            let url = liveRoot
                .appendingPathComponent("Patterns/Assets")
                .appendingPathComponent(asset.storedFilename)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PatternLibraryMigrationError.missingLegacyFile
            }
        }
    }

    private static func clearingLegacyPatterns(_ project: StoredProject) throws -> StoredProject {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any] ?? [:]
        object["patterns"] = []
        return try JSONDecoder().decode(
            StoredProject.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private static func deterministicUUID(fromSHA256 sha256: String) -> UUID {
        let characters = Array(sha256)
        let value = String(characters[0..<32])
        let formatted = "\(value.prefix(8))-\(value.dropFirst(8).prefix(4))-\(value.dropFirst(12).prefix(4))-\(value.dropFirst(16).prefix(4))-\(value.dropFirst(20))"
        guard let identifier = UUID(uuidString: formatted) else {
            preconditionFailure("SHA-256 hashes must produce a UUID-compatible prefix.")
        }
        return identifier
    }
}

private struct MigrationTransaction: Codable {}

private struct PatternProjectUsagePair: Hashable {
    let patternID: UUID
    let projectID: UUID
}

private struct LegacyDocument: Sendable {
    let project: StoredProject
    let document: PatternDocument
    let sortOrder: Int
}

private struct PatternKey: Hashable {
    let sha256: String
    let normalizedName: String
}

private struct ValidatedLegacyDocument: Sendable {
    let project: StoredProject
    let document: PatternDocument
    let sortOrder: Int
    let sourceURL: URL
    let sha256: String
    let byteCount: Int64
    let pageCount: Int?
    let fileExtension: String
    let displayName: String
    let normalizedName: String

    init(legacy: LegacyDocument, liveRoot: URL) throws {
        let filename = legacy.document.storedFilename
        guard Self.isSafeFilename(filename) else {
            throw PatternLibraryMigrationError.unsafeLegacyFilename
        }
        let sourceURL = liveRoot
            .appendingPathComponent("Patterns/\(legacy.project.id.uuidString)")
            .appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw PatternLibraryMigrationError.missingLegacyFile
        }
        let data = try Data(contentsOf: sourceURL)
        guard !data.isEmpty else { throw PatternLibraryMigrationError.emptyLegacyFile }
        let pageCount = try Self.validate(document: legacy.document, at: sourceURL)
        let displayName = legacy.document.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else { throw PatternLibraryMigrationError.emptyDisplayName }

        self.project = legacy.project
        self.document = legacy.document
        self.sortOrder = legacy.sortOrder
        self.sourceURL = sourceURL
        self.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        self.byteCount = Int64(data.count)
        self.pageCount = pageCount
        self.fileExtension = sourceURL.pathExtension.lowercased()
        self.displayName = displayName
        self.normalizedName = displayName.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func isSafeFilename(_ filename: String) -> Bool {
        filename == URL(fileURLWithPath: filename).lastPathComponent
            && !filename.isEmpty
            && filename != "."
            && filename != ".."
    }

    private static func validate(document: PatternDocument, at url: URL) throws -> Int? {
        switch document.kind {
        case .pdf:
            guard let pdf = CGPDFDocument(url as CFURL), pdf.numberOfPages > 0 else {
                throw PatternLibraryMigrationError.invalidLegacyFile
            }
            return pdf.numberOfPages
        case .image:
            guard let image = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetCount(image) > 0 else {
                throw PatternLibraryMigrationError.invalidLegacyFile
            }
            return nil
        }
    }
}
