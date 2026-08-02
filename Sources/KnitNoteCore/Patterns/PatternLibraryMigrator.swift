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
    case transactionRecoveryRequired
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
        guard ProjectArchive.isSupported(version: archive.version),
              archive.version < ProjectArchive.currentVersion else {
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

        let transactionDirectory = liveRoot.appendingPathComponent(
            ".KnitNote-PatternMigrations",
            isDirectory: true
        )
        let stagedRoot = transactionDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: stagedRoot, withIntermediateDirectories: true)
            try JSONEncoder().encode(PatternMigrationTransaction()).write(
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
        var transaction = try loadTransaction(at: migrated.stagedRoot)

        do {
            try stepHook(.beforeInstall)
            transaction.phase = .preparingRollback
            try persist(transaction, at: migrated.stagedRoot)
            try fileManager.createDirectory(at: rollbackRoot, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: archiveURL.path) {
                try fileManager.moveItem(at: archiveURL, to: rollbackArchiveURL)
                transaction.phase = .archiveBackedUp
                try persist(transaction, at: migrated.stagedRoot)
            }
            if fileManager.fileExists(atPath: livePatternsRoot.path) {
                try fileManager.moveItem(at: livePatternsRoot, to: rollbackPatternsRoot)
                transaction.phase = .patternsBackedUp
                try persist(transaction, at: migrated.stagedRoot)
            }
            try fileManager.moveItem(at: stagedArchiveURL, to: archiveURL)
            transaction.phase = .archiveInstalled
            try persist(transaction, at: migrated.stagedRoot)
            if fileManager.fileExists(atPath: stagedPatternsRoot.path) {
                try fileManager.moveItem(at: stagedPatternsRoot, to: livePatternsRoot)
                transaction.phase = .installed
                try persist(transaction, at: migrated.stagedRoot)
            }

            try validateInstalledArchive(at: archiveURL, liveRoot: liveRoot)
            transaction.phase = .validated
            try persist(transaction, at: migrated.stagedRoot)
            try stepHook(.afterInstall)
            transaction.phase = .committed
            try persist(transaction, at: migrated.stagedRoot)
            cleanupTerminalTransaction(at: migrated.stagedRoot)
        } catch {
            do {
                try restoreRollback(
                    at: migrated.stagedRoot,
                    archiveURL: archiveURL,
                    liveRoot: liveRoot
                )
            } catch {
                throw PatternLibraryMigrationError.rollbackFailed
            }
            throw error
        }
    }

    func recoverInterruptedMigration(archiveURL: URL) throws {
        let liveRoot = archiveURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        let transactionDirectory = liveRoot.appendingPathComponent(
            ".KnitNote-PatternMigrations",
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: transactionDirectory.path) else { return }
        let transactions = try fileManager.contentsOfDirectory(
            at: transactionDirectory,
            includingPropertiesForKeys: nil
        ).filter {
            fileManager.fileExists(atPath: $0.appendingPathComponent("transaction.json").path)
        }

        for transactionRoot in transactions {
            let transaction: PatternMigrationTransaction
            do {
                transaction = try loadTransaction(at: transactionRoot)
            } catch {
                throw PatternLibraryMigrationError.transactionRecoveryRequired
            }
            switch transaction.phase {
            case .committed, .rolledBack:
                cleanupTerminalTransaction(at: transactionRoot)
                continue
            case .staged, .preparingRollback:
                let rollbackArchiveURL = transactionRoot
                    .appendingPathComponent("Rollback/archive.json")
                guard fileManager.fileExists(atPath: rollbackArchiveURL.path) else {
                    try? fileManager.removeItem(at: transactionRoot)
                    continue
                }
                fallthrough
            case .archiveBackedUp, .patternsBackedUp, .archiveInstalled, .installed, .validated, .rollingBack:
                do {
                    try restoreRollback(
                        at: transactionRoot,
                        archiveURL: archiveURL,
                        liveRoot: liveRoot
                    )
                } catch {
                    throw PatternLibraryMigrationError.rollbackFailed
                }
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
        let service = PatternFileService(
            root: liveRoot.appendingPathComponent("Patterns", isDirectory: true)
        )
        for asset in archive.patternAssets {
            let url = try service.assetURL(asset)
            try validate(asset: asset, at: url)
        }
    }

    private func validate(asset: PatternAsset, at url: URL) throws {
        guard asset.storedFilename == url.lastPathComponent,
              FileManager.default.fileExists(atPath: url.path) else {
            throw PatternLibraryMigrationError.missingLegacyFile
        }
        let data = try Data(contentsOf: url)
        guard Int64(data.count) == asset.byteCount else {
            throw PatternLibraryMigrationError.invalidLegacyFile
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == asset.sha256 else {
            throw PatternLibraryMigrationError.invalidLegacyFile
        }
        switch asset.kind {
        case .pdf:
            guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0,
                  asset.pageCount == document.numberOfPages else {
                throw PatternLibraryMigrationError.invalidLegacyFile
            }
        case .image:
            guard let image = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetCount(image) > 0 else {
                throw PatternLibraryMigrationError.invalidLegacyFile
            }
        }
    }

    private func loadTransaction(at root: URL) throws -> PatternMigrationTransaction {
        try JSONDecoder().decode(
            PatternMigrationTransaction.self,
            from: Data(contentsOf: root.appendingPathComponent("transaction.json"))
        )
    }

    private func persist(_ transaction: PatternMigrationTransaction, at root: URL) throws {
        try JSONEncoder().encode(transaction).write(
            to: root.appendingPathComponent("transaction.json"),
            options: .atomic
        )
    }

    private func restoreRollback(at transactionRoot: URL, archiveURL: URL, liveRoot: URL) throws {
        let fileManager = FileManager.default
        let rollbackRoot = transactionRoot.appendingPathComponent("Rollback", isDirectory: true)
        let rollbackArchiveURL = rollbackRoot.appendingPathComponent("archive.json")
        let rollbackPatternsRoot = rollbackRoot.appendingPathComponent("Patterns", isDirectory: true)
        var transaction = try loadTransaction(at: transactionRoot)
        guard fileManager.fileExists(atPath: rollbackArchiveURL.path) else {
            if transaction.phase == .staged || transaction.phase == .preparingRollback {
                try? fileManager.removeItem(at: transactionRoot)
                return
            }
            throw PatternLibraryMigrationError.rollbackFailed
        }
        transaction.phase = .rollingBack
        try persist(transaction, at: transactionRoot)
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
        transaction.phase = .rolledBack
        try persist(transaction, at: transactionRoot)
        cleanupTerminalTransaction(at: transactionRoot)
    }

    private func cleanupTerminalTransaction(at root: URL) {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            // A durable terminal phase makes a retained artifact unambiguous:
            // startup will only retry this cleanup and never roll back live data.
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

struct PatternMigrationTransaction: Codable, Sendable {
    enum Phase: String, Codable, Sendable {
        case staged
        case preparingRollback
        case archiveBackedUp
        case patternsBackedUp
        case archiveInstalled
        case installed
        case validated
        case committed
        case rollingBack
        case rolledBack
    }

    let id: UUID
    var phase: Phase

    init(id: UUID = UUID(), phase: Phase = .staged) {
        self.id = id
        self.phase = phase
    }
}

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
