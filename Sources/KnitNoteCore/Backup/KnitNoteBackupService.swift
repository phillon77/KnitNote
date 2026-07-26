import CryptoKit
import Foundation
import Darwin

typealias KnitNoteBackupResourceMetadata = (
    isRegularFile: Bool?,
    isDirectory: Bool?,
    isSymbolicLink: Bool?,
    fileSize: Int64?,
    physicalVolumeIdentifier: String?
)

public struct StagedKnitNoteBackup: Sendable {
    public let root: URL
    public let preview: KnitNoteBackupPreview
    let manifest: KnitNoteBackupManifest?

    init(
        root: URL,
        preview: KnitNoteBackupPreview,
        manifest: KnitNoteBackupManifest? = nil
    ) {
        self.root = root
        self.preview = preview
        self.manifest = manifest
    }
}

public struct KnitNoteBackupInstallation: Sendable {
    public let liveRoot: URL
    public let rollbackRoot: URL
    let hadLiveRoot: Bool
    let transactionID: UUID

    init(
        liveRoot: URL,
        rollbackRoot: URL,
        hadLiveRoot: Bool,
        transactionID: UUID
    ) {
        self.liveRoot = liveRoot
        self.rollbackRoot = rollbackRoot
        self.hadLiveRoot = hadLiveRoot
        self.transactionID = transactionID
    }
}

private enum KnitNoteBackupReplacementPhase: String, Codable, Sendable {
    case prepared
    case installedAwaitingReload
    case rollingBack
    case committed
    case rolledBack
}

private struct KnitNoteBackupReplacementJournal: Codable, Sendable {
    private struct Payload: Codable {
        let version: Int
        let transactionID: UUID
        let rollbackName: String
        let hadLiveRoot: Bool
        let phase: KnitNoteBackupReplacementPhase
    }

    let version: Int
    let transactionID: UUID
    let rollbackName: String
    let hadLiveRoot: Bool
    let phase: KnitNoteBackupReplacementPhase
    let integrity: String

    init(
        transactionID: UUID,
        hadLiveRoot: Bool,
        phase: KnitNoteBackupReplacementPhase
    ) throws {
        let payload = Payload(
            version: 1,
            transactionID: transactionID,
            rollbackName: "Rollback-\(transactionID.uuidString)",
            hadLiveRoot: hadLiveRoot,
            phase: phase
        )
        version = payload.version
        self.transactionID = transactionID
        rollbackName = payload.rollbackName
        self.hadLiveRoot = hadLiveRoot
        self.phase = phase
        integrity = try Self.integrity(for: payload)
    }

    var isValid: Bool {
        guard version == 1,
              rollbackName == "Rollback-\(transactionID.uuidString)" else {
            return false
        }
        let payload = Payload(
            version: version,
            transactionID: transactionID,
            rollbackName: rollbackName,
            hadLiveRoot: hadLiveRoot,
            phase: phase
        )
        return (try? Self.integrity(for: payload)) == integrity
    }

    private static func integrity(for payload: Payload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(payload))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum KnitNoteBackupReplacementStep: Sendable {
    case beforeLiveMove
    case afterLiveMove
    case afterStagedMove
    case beforeRollback
    case afterRollbackJournal
    case afterRollbackLiveRemoval
    case afterRollbackRestore
    case afterRollbackFinalized
    case beforeCommitCleanup
}

public struct KnitNoteBackupService: Sendable {
    public let liveRoot: URL
    public let workRoot: URL
    private let loadResourceMetadata: @Sendable (URL) throws -> KnitNoteBackupResourceMetadata
    private let afterStageCopy: @Sendable (URL) throws -> Void
    private let replacementStepHook: @Sendable (KnitNoteBackupReplacementStep) throws -> Void
    private let cleanupItem: @Sendable (URL) throws -> Void
    private let copyChunkHook: @Sendable (URL, Int64) throws -> Void
    private var beforeSourceEntryOpen: @Sendable (String) throws -> Void = { _ in }

    public init(liveRoot: URL, workRoot: URL) {
        self.liveRoot = liveRoot
        self.workRoot = workRoot
        loadResourceMetadata = Self.defaultResourceMetadata
        afterStageCopy = { _ in }
        replacementStepHook = { _ in }
        cleanupItem = { try FileManager.default.removeItem(at: $0) }
        copyChunkHook = { _, _ in }
    }

    init(
        liveRoot: URL,
        workRoot: URL,
        resourceMetadata: @escaping @Sendable (URL) throws -> KnitNoteBackupResourceMetadata
    ) {
        self.liveRoot = liveRoot
        self.workRoot = workRoot
        loadResourceMetadata = resourceMetadata
        afterStageCopy = { _ in }
        replacementStepHook = { _ in }
        cleanupItem = { try FileManager.default.removeItem(at: $0) }
        copyChunkHook = { _, _ in }
    }

    init(
        liveRoot: URL,
        workRoot: URL,
        resourceMetadata: @escaping @Sendable (URL) throws -> KnitNoteBackupResourceMetadata,
        replacementStepHook: @escaping @Sendable (KnitNoteBackupReplacementStep) throws -> Void
    ) {
        self.liveRoot = liveRoot
        self.workRoot = workRoot
        loadResourceMetadata = resourceMetadata
        afterStageCopy = { _ in }
        self.replacementStepHook = replacementStepHook
        cleanupItem = { try FileManager.default.removeItem(at: $0) }
        copyChunkHook = { _, _ in }
    }

    init(
        liveRoot: URL,
        workRoot: URL,
        afterStageCopy: @escaping @Sendable (URL) throws -> Void
    ) {
        self.liveRoot = liveRoot
        self.workRoot = workRoot
        loadResourceMetadata = Self.defaultResourceMetadata
        self.afterStageCopy = afterStageCopy
        replacementStepHook = { _ in }
        cleanupItem = { try FileManager.default.removeItem(at: $0) }
        copyChunkHook = { _, _ in }
    }

    init(
        liveRoot: URL,
        workRoot: URL,
        replacementStepHook: @escaping @Sendable (KnitNoteBackupReplacementStep) throws -> Void
    ) {
        self.liveRoot = liveRoot
        self.workRoot = workRoot
        loadResourceMetadata = Self.defaultResourceMetadata
        afterStageCopy = { _ in }
        self.replacementStepHook = replacementStepHook
        cleanupItem = { try FileManager.default.removeItem(at: $0) }
        copyChunkHook = { _, _ in }
    }

    init(
        liveRoot: URL,
        workRoot: URL,
        cleanupItem: @escaping @Sendable (URL) throws -> Void
    ) {
        self.liveRoot = liveRoot
        self.workRoot = workRoot
        loadResourceMetadata = Self.defaultResourceMetadata
        afterStageCopy = { _ in }
        replacementStepHook = { _ in }
        self.cleanupItem = cleanupItem
        copyChunkHook = { _, _ in }
    }

    init(
        liveRoot: URL,
        workRoot: URL,
        replacementStepHook: @escaping @Sendable (KnitNoteBackupReplacementStep) throws -> Void,
        cleanupItem: @escaping @Sendable (URL) throws -> Void
    ) {
        self.liveRoot = liveRoot
        self.workRoot = workRoot
        loadResourceMetadata = Self.defaultResourceMetadata
        afterStageCopy = { _ in }
        self.replacementStepHook = replacementStepHook
        self.cleanupItem = cleanupItem
        copyChunkHook = { _, _ in }
    }

    init(
        liveRoot: URL,
        workRoot: URL,
        copyChunkHook: @escaping @Sendable (URL, Int64) throws -> Void
    ) {
        self.liveRoot = liveRoot
        self.workRoot = workRoot
        loadResourceMetadata = Self.defaultResourceMetadata
        afterStageCopy = { _ in }
        replacementStepHook = { _ in }
        cleanupItem = { try FileManager.default.removeItem(at: $0) }
        self.copyChunkHook = copyChunkHook
    }

    init(
        liveRoot: URL,
        workRoot: URL,
        beforeSourceEntryOpen: @escaping @Sendable (String) throws -> Void
    ) {
        self.liveRoot = liveRoot
        self.workRoot = workRoot
        loadResourceMetadata = Self.defaultResourceMetadata
        afterStageCopy = { _ in }
        replacementStepHook = { _ in }
        cleanupItem = { try FileManager.default.removeItem(at: $0) }
        copyChunkHook = { _, _ in }
        self.beforeSourceEntryOpen = beforeSourceEntryOpen
    }

    public func createPackage(appVersion: String, now: Date = .now) throws -> URL {
        try validateLiveSource(relativePath: "projects-v1.json", expectsDirectory: false)
        let archiveData: Data
        let archive: ProjectArchive
        do {
            archiveData = try readLiveRegularFileBounded(
                relativePath: "projects-v1.json",
                limit: KnitNoteBackupLimits.maximumArchiveBytes
            )
            archive = try JSONDecoder().decode(ProjectArchive.self, from: archiveData)
        } catch let error as KnitNoteBackupError {
            throw error
        } catch {
            throw KnitNoteBackupError.invalidArchive
        }
        try validateArchive(archive)
        let mediaPaths = referencedMediaPaths(in: archive).sorted()
        for relativePath in mediaPaths {
            try validateLiveSource(relativePath: relativePath, expectsDirectory: false)
        }
        let referencedPaths = try referencedRelativePaths(in: archive, sourceRoot: liveRoot)
            .sorted()
        try preflightLiveExport(
            relativePaths: referencedPaths,
            archiveBytes: Int64(archiveData.count)
        )

        let packageRoot = workRoot
            .appendingPathComponent("\(UUID().uuidString).knitnote-backup", isDirectory: true)
        let dataRoot = packageRoot.appendingPathComponent("Data", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
            let archiveDestination = dataRoot.appendingPathComponent("projects-v1.json")
            try archiveData.write(to: archiveDestination, options: .atomic)
            try normalizeOwnedFile(archiveDestination)
            var totalBytes = Int64(archiveData.count)
            var manifestFiles = [
                KnitNoteBackupManifestFile(
                    relativePath: "projects-v1.json",
                    byteCount: totalBytes,
                    sha256: SHA256.hash(data: archiveData)
                        .map { String(format: "%02x", $0) }
                        .joined()
                ),
            ]
            for relativePath in referencedPaths {
                let destination = dataRoot.appendingPathComponent(relativePath)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                manifestFiles.append(
                    try copyLiveRegularFileBounded(
                        relativePath: relativePath,
                        to: destination,
                        totalBytes: &totalBytes
                    )
                )
            }
            manifestFiles.sort {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
            let manifest = KnitNoteBackupManifest(
                createdAt: now,
                appVersion: appVersion,
                projectCount: archive.projects.count,
                yarnCount: archive.yarns.count,
                patternCount: patternCount(in: archive),
                files: manifestFiles,
                criticalFeatures: [KnitNoteBackupManifest.fileIntegrityFeature]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(manifest).write(
                to: packageRoot.appendingPathComponent("manifest.json"),
                options: .atomic
            )
            _ = try inspectPackage(at: packageRoot)
            return packageRoot
        } catch {
            try? FileManager.default.removeItem(at: packageRoot)
            throw error
        }
    }

    public func inspectPackage(at packageRoot: URL) throws -> KnitNoteBackupPreview {
        try validatePackageRoot(packageRoot)
        try validatePackageSizes(packageRoot)
        let manifest: KnitNoteBackupManifest
        do {
            let data = try Data(contentsOf: packageRoot.appendingPathComponent("manifest.json"))
            manifest = try JSONDecoder().decode(KnitNoteBackupManifest.self, from: data)
        } catch let error as KnitNoteBackupError {
            throw error
        } catch {
            throw KnitNoteBackupError.invalidManifest
        }
        let preview = try manifest.preview()

        let dataRoot = packageRoot.appendingPathComponent("Data", isDirectory: true)
        try validateDataTopLevel(dataRoot)
        let archive: ProjectArchive
        do {
            let data = try Data(contentsOf: dataRoot.appendingPathComponent("projects-v1.json"))
            archive = try JSONDecoder().decode(ProjectArchive.self, from: data)
        } catch {
            throw KnitNoteBackupError.invalidArchive
        }
        try validateArchive(archive)
        guard manifest.projectCount == archive.projects.count,
              manifest.yarnCount == archive.yarns.count,
              manifest.formatVersion == 1
                || manifest.patternCount == patternCount(in: archive) else {
            throw KnitNoteBackupError.countMismatch
        }
        try validateDataTree(dataRoot, archive: archive)
        try validateManifestFiles(manifest, in: dataRoot)
        return preview
    }

    public func stagePackage(at packageRoot: URL) throws -> StagedKnitNoteBackup {
        let preview = try inspectPackage(at: packageRoot)
        let manifest = try decodeManifest(at: packageRoot)
        let stagedRoot = workRoot.appendingPathComponent(
            "Staged-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagedData = stagedRoot.appendingPathComponent("Data", isDirectory: true)
        do {
            try ensureOwnedWorkRoot()
            try createOwnedDirectory(stagedRoot)
            try createOwnedDirectory(stagedData)
            try copyDataContentsBounded(
                fromPackageRoot: packageRoot,
                to: stagedData
            )
            try afterStageCopy(stagedRoot)
            try validatePackageSizes(stagedRoot)
            try validateDataTopLevel(stagedData)
            let archive: ProjectArchive
            do {
                archive = try JSONDecoder().decode(
                    ProjectArchive.self,
                    from: Data(contentsOf: stagedData.appendingPathComponent("projects-v1.json"))
                )
            } catch {
                throw KnitNoteBackupError.invalidArchive
            }
            try validateArchive(archive)
            guard preview.projectCount == archive.projects.count,
                  preview.yarnCount == archive.yarns.count,
                  manifest.formatVersion == 1
                    || preview.patternCount == patternCount(in: archive) else {
                throw KnitNoteBackupError.countMismatch
            }
            try validateDataTree(stagedData, archive: archive)
            try validateManifestFiles(manifest, in: stagedData)
            try verifyStagedTreeIsWritable(stagedData)
            return StagedKnitNoteBackup(
                root: stagedRoot,
                preview: preview,
                manifest: manifest
            )
        } catch {
            try? FileManager.default.removeItem(at: stagedRoot)
            throw error
        }
    }

    public func install(_ staged: StagedKnitNoteBackup) throws -> KnitNoteBackupInstallation {
        do {
            try validateStagedBackup(staged)
        } catch let error as KnitNoteBackupError {
            throw error
        } catch {
            throw KnitNoteBackupError.invalidArchive
        }

        let fileManager = FileManager.default
        let transactionID = UUID()
        let rollbackRoot = workRoot.appendingPathComponent(
            "Rollback-\(transactionID.uuidString)",
            isDirectory: true
        )
        let stagedData = staged.root.appendingPathComponent("Data", isDirectory: true)
        let hadLiveRoot = fileManager.fileExists(atPath: liveRoot.path)
        try validatePhysicalReplacementVolume(
            stagedData: stagedData,
            rollbackRoot: rollbackRoot,
            includesLiveRoot: hadLiveRoot
        )
        var movedLive = false
        var movedStaged = false

        do {
            try fileManager.createDirectory(at: workRoot, withIntermediateDirectories: true)
            try persistReplacementJournal(
                transactionID: transactionID,
                hadLiveRoot: hadLiveRoot,
                phase: .prepared
            )
            try replacementStepHook(.beforeLiveMove)
            if hadLiveRoot {
                try fileManager.moveItem(at: liveRoot, to: rollbackRoot)
                movedLive = true
            }
            try replacementStepHook(.afterLiveMove)
            try fileManager.moveItem(at: stagedData, to: liveRoot)
            movedStaged = true
            try replacementStepHook(.afterStagedMove)
            try persistReplacementJournal(
                transactionID: transactionID,
                hadLiveRoot: hadLiveRoot,
                phase: .installedAwaitingReload
            )
            try? fileManager.removeItem(at: staged.root)
            return KnitNoteBackupInstallation(
                liveRoot: liveRoot,
                rollbackRoot: rollbackRoot,
                hadLiveRoot: hadLiveRoot,
                transactionID: transactionID
            )
        } catch {
            do {
                if movedStaged, fileManager.fileExists(atPath: liveRoot.path) {
                    try fileManager.removeItem(at: liveRoot)
                }
                if movedLive {
                    try replacementStepHook(.beforeRollback)
                    try fileManager.moveItem(at: rollbackRoot, to: liveRoot)
                }
                try? removeReplacementJournal()
            } catch {
                throw KnitNoteBackupError.rollbackFailed
            }
            throw KnitNoteBackupError.installFailedOriginalPreserved
        }
    }

    public func commit(_ installation: KnitNoteBackupInstallation) {
        do {
            try persistReplacementJournal(
                transactionID: installation.transactionID,
                hadLiveRoot: installation.hadLiveRoot,
                phase: .committed
            )
            try replacementStepHook(.beforeCommitCleanup)
            if FileManager.default.fileExists(atPath: installation.rollbackRoot.path) {
                let cleanupRoot = workRoot.appendingPathComponent(
                    "Cleanup-\(installation.transactionID.uuidString)",
                    isDirectory: true
                )
                try FileManager.default.moveItem(
                    at: installation.rollbackRoot,
                    to: cleanupRoot
                )
                try cleanupItem(cleanupRoot)
            }
            try removeReplacementJournal()
        } catch {
            // The installed tree has already reloaded successfully. Leave the
            // rollback artifact for launch housekeeping rather than risking it.
        }
    }

    public func rollback(_ installation: KnitNoteBackupInstallation) throws {
        let fileManager = FileManager.default
        do {
            if installation.hadLiveRoot,
               !fileManager.fileExists(atPath: installation.rollbackRoot.path) {
                throw KnitNoteBackupError.rollbackFailed
            }
            try persistReplacementJournal(
                transactionID: installation.transactionID,
                hadLiveRoot: installation.hadLiveRoot,
                phase: .rollingBack
            )
            try replacementStepHook(.afterRollbackJournal)
            try replacementStepHook(.beforeRollback)
            if fileManager.fileExists(atPath: installation.liveRoot.path) {
                try fileManager.removeItem(at: installation.liveRoot)
            }
            try replacementStepHook(.afterRollbackLiveRemoval)
            if installation.hadLiveRoot {
                try fileManager.moveItem(
                    at: installation.rollbackRoot,
                    to: installation.liveRoot
                )
            }
            try replacementStepHook(.afterRollbackRestore)
            try persistReplacementJournal(
                transactionID: installation.transactionID,
                hadLiveRoot: installation.hadLiveRoot,
                phase: .rolledBack
            )
            try replacementStepHook(.afterRollbackFinalized)
            try removeReplacementJournal()
        } catch {
            throw KnitNoteBackupError.rollbackFailed
        }
    }

    public func recoverInterruptedReplacement() throws -> KnitNoteBackupInstallation? {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: workRoot.path) {
            try validateWorkRootAncestry()
        }

        if let journal = try loadReplacementJournal() {
            let rollbackRoot = workRoot.appendingPathComponent(
                journal.rollbackName,
                isDirectory: true
            )
            let liveExists = fileManager.fileExists(atPath: liveRoot.path)
            let rollbackExists = fileManager.fileExists(atPath: rollbackRoot.path)
            switch journal.phase {
            case .committed:
                try finishCommittedReplacement(
                    journal: journal,
                    rollbackRoot: rollbackRoot
                )
            case .rolledBack:
                try removeReplacementJournal()
            case .rollingBack:
                try finishInterruptedRollback(
                    journal: journal,
                    rollbackRoot: rollbackRoot,
                    liveExists: liveExists,
                    rollbackExists: rollbackExists
                )
            case .prepared:
                if journal.hadLiveRoot, rollbackExists, !liveExists {
                    try fileManager.moveItem(at: rollbackRoot, to: liveRoot)
                    try removeReplacementJournal()
                } else if journal.hadLiveRoot, rollbackExists, liveExists {
                    return replacementInstallation(journal, rollbackRoot: rollbackRoot)
                } else if journal.hadLiveRoot, !rollbackExists, liveExists {
                    try removeReplacementJournal()
                } else if !journal.hadLiveRoot, liveExists {
                    return replacementInstallation(journal, rollbackRoot: rollbackRoot)
                } else if !journal.hadLiveRoot, !liveExists {
                    try removeReplacementJournal()
                } else {
                    throw KnitNoteBackupError.rollbackFailed
                }
            case .installedAwaitingReload:
                if liveExists, (!journal.hadLiveRoot || rollbackExists) {
                    return replacementInstallation(journal, rollbackRoot: rollbackRoot)
                }
                if journal.hadLiveRoot, rollbackExists, !liveExists {
                    try fileManager.moveItem(at: rollbackRoot, to: liveRoot)
                    try removeReplacementJournal()
                } else {
                    throw KnitNoteBackupError.rollbackFailed
                }
            }
        }

        if fileManager.fileExists(atPath: liveRoot.path) {
            do {
                try validateLiveRoot(liveRoot)
                cleanupGeneratedArtifactsAfterValidChoice()
                return nil
            } catch {
                throw KnitNoteBackupError.rollbackFailed
            }
        }

        let rollbackRoots = try availableRollbackRoots()
        let validRollbackRoots = rollbackRoots.filter {
            (try? validateLiveRoot($0)) != nil
        }
        guard !rollbackRoots.isEmpty else {
            cleanupGeneratedArtifactsAfterValidChoice()
            return nil
        }
        guard validRollbackRoots.count == 1 else {
            throw KnitNoteBackupError.rollbackFailed
        }
        do {
            try fileManager.moveItem(at: validRollbackRoots[0], to: liveRoot)
            cleanupGeneratedArtifactsAfterValidChoice()
            return nil
        } catch {
            throw KnitNoteBackupError.rollbackFailed
        }
    }

    private var replacementJournalURL: URL {
        workRoot.appendingPathComponent(".ReplacementJournal.json")
    }

    private func persistReplacementJournal(
        transactionID: UUID,
        hadLiveRoot: Bool,
        phase: KnitNoteBackupReplacementPhase
    ) throws {
        try ensureOwnedWorkRoot()
        let journal = try KnitNoteBackupReplacementJournal(
            transactionID: transactionID,
            hadLiveRoot: hadLiveRoot,
            phase: phase
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(journal).write(to: replacementJournalURL, options: .atomic)
        let journalDescriptor = replacementJournalURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard journalDescriptor >= 0 else {
            throw KnitNoteBackupError.rollbackFailed
        }
        defer { Darwin.close(journalDescriptor) }
        guard Darwin.fsync(journalDescriptor) == 0 else {
            throw KnitNoteBackupError.rollbackFailed
        }
        try synchronizeWorkDirectory()
    }

    private func loadReplacementJournal() throws -> KnitNoteBackupReplacementJournal? {
        guard FileManager.default.fileExists(atPath: replacementJournalURL.path) else {
            return nil
        }
        let values = try entryValues(replacementJournalURL)
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw KnitNoteBackupError.rollbackFailed
        }
        guard let journal = try? JSONDecoder().decode(
            KnitNoteBackupReplacementJournal.self,
            from: Data(contentsOf: replacementJournalURL)
        ), journal.isValid else {
            throw KnitNoteBackupError.rollbackFailed
        }
        return journal
    }

    private func removeReplacementJournal() throws {
        guard FileManager.default.fileExists(atPath: replacementJournalURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: replacementJournalURL)
        try synchronizeWorkDirectory()
    }

    private func synchronizeWorkDirectory() throws {
        let descriptor = workRoot.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw KnitNoteBackupError.rollbackFailed
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw KnitNoteBackupError.rollbackFailed
        }
    }

    private func replacementInstallation(
        _ journal: KnitNoteBackupReplacementJournal,
        rollbackRoot: URL
    ) -> KnitNoteBackupInstallation {
        KnitNoteBackupInstallation(
            liveRoot: liveRoot,
            rollbackRoot: rollbackRoot,
            hadLiveRoot: journal.hadLiveRoot,
            transactionID: journal.transactionID
        )
    }

    private func finishCommittedReplacement(
        journal: KnitNoteBackupReplacementJournal,
        rollbackRoot: URL
    ) throws {
        let cleanupRoot = workRoot.appendingPathComponent(
            "Cleanup-\(journal.transactionID.uuidString)",
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: rollbackRoot.path) {
            try FileManager.default.moveItem(at: rollbackRoot, to: cleanupRoot)
        }
        if FileManager.default.fileExists(atPath: cleanupRoot.path) {
            try cleanupItem(cleanupRoot)
        }
        try removeReplacementJournal()
    }

    private func finishInterruptedRollback(
        journal: KnitNoteBackupReplacementJournal,
        rollbackRoot: URL,
        liveExists: Bool,
        rollbackExists: Bool
    ) throws {
        let fileManager = FileManager.default
        if journal.hadLiveRoot {
            if rollbackExists {
                if liveExists {
                    try fileManager.removeItem(at: liveRoot)
                }
                try fileManager.moveItem(at: rollbackRoot, to: liveRoot)
            } else {
                guard liveExists else {
                    throw KnitNoteBackupError.rollbackFailed
                }
                try validateLiveRoot(liveRoot)
            }
        } else if liveExists {
            try fileManager.removeItem(at: liveRoot)
        }
        try persistReplacementJournal(
            transactionID: journal.transactionID,
            hadLiveRoot: journal.hadLiveRoot,
            phase: .rolledBack
        )
        try removeReplacementJournal()
    }

    private func validateStagedBackup(_ staged: StagedKnitNoteBackup) throws {
        guard let manifest = staged.manifest,
              try manifest.preview() == staged.preview else {
            throw KnitNoteBackupError.invalidManifest
        }
        try validateWorkRootAncestry()
        let standardizedWorkRoot = workRoot.standardizedFileURL.path
        let standardizedStagedRoot = staged.root.standardizedFileURL
        guard standardizedStagedRoot.deletingLastPathComponent().path == standardizedWorkRoot,
              isGeneratedArtifactName(
                standardizedStagedRoot.lastPathComponent,
                prefix: "Staged-"
              ) else {
            throw KnitNoteBackupError.unsafePackageEntry
        }
        let stagedValues = try entryValues(standardizedStagedRoot)
        guard stagedValues.isDirectory == true,
              stagedValues.isSymbolicLink != true else {
            throw KnitNoteBackupError.unsafePackageEntry
        }
        try validatePackageSizes(staged.root)
        let dataRoot = staged.root.appendingPathComponent("Data", isDirectory: true)
        let dataValues = try entryValues(dataRoot)
        guard dataValues.isDirectory == true,
              dataValues.isSymbolicLink != true else {
            throw KnitNoteBackupError.unsafePackageEntry
        }
        try validateDataTopLevel(dataRoot)
        let archive: ProjectArchive
        do {
            archive = try JSONDecoder().decode(
                ProjectArchive.self,
                from: Data(contentsOf: dataRoot.appendingPathComponent("projects-v1.json"))
            )
        } catch {
            throw KnitNoteBackupError.invalidArchive
        }
        try validateArchive(archive)
        guard staged.preview.projectCount == archive.projects.count,
              staged.preview.yarnCount == archive.yarns.count,
              manifest.formatVersion == 1
                || staged.preview.patternCount == patternCount(in: archive) else {
            throw KnitNoteBackupError.countMismatch
        }
        try validateDataTree(dataRoot, archive: archive)
        try validateManifestFiles(manifest, in: dataRoot)
        try verifyStagedTreeIsWritable(dataRoot)
    }

    private func readLiveRegularFileBounded(
        relativePath: String,
        limit: Int64
    ) throws -> Data {
        try withLiveRegularFile(relativePath: relativePath) { descriptor, initialInfo, source in
            guard initialInfo.st_size >= 0 else {
                throw KnitNoteBackupError.unsafePackageEntry
            }
            guard initialInfo.st_size <= limit else {
                throw KnitNoteBackupError.fileTooLarge
            }
            var result = Data()
            result.reserveCapacity(Int(initialInfo.st_size))
            var copiedBytes: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let remaining = limit - copiedBytes
                let requested = min(buffer.count, Int(remaining + 1))
                let readCount = buffer.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, requested)
                }
                guard readCount >= 0 else { throw KnitNoteBackupError.unsafePackageEntry }
                guard readCount > 0 else { break }
                guard Int64(readCount) <= remaining else {
                    throw KnitNoteBackupError.fileTooLarge
                }
                result.append(contentsOf: buffer.prefix(readCount))
                copiedBytes += Int64(readCount)
                try copyChunkHook(source, copiedBytes)
            }
            try validateUnchangedSource(
                descriptor: descriptor,
                initialInfo: initialInfo,
                copiedBytes: copiedBytes
            )
            return result
        }
    }

    private func preflightLiveExport(
        relativePaths: [String],
        archiveBytes: Int64
    ) throws {
        guard archiveBytes <= KnitNoteBackupLimits.maximumPackageBytes else {
            throw KnitNoteBackupError.packageTooLarge
        }
        var totalBytes = archiveBytes
        for relativePath in relativePaths {
            try withLiveRegularFile(relativePath: relativePath) {
                _,
                info,
                _ in
                guard info.st_size >= 0 else {
                    throw KnitNoteBackupError.unsafePackageEntry
                }
                guard info.st_size <= copyFileLimit(for: relativePath) else {
                    throw KnitNoteBackupError.fileTooLarge
                }
                guard info.st_size <= KnitNoteBackupLimits.maximumPackageBytes - totalBytes else {
                    throw KnitNoteBackupError.packageTooLarge
                }
                totalBytes += info.st_size
            }
        }
    }

    private func copyLiveRegularFileBounded(
        relativePath: String,
        to destination: URL,
        totalBytes: inout Int64
    ) throws -> KnitNoteBackupManifestFile {
        try withLiveRegularFile(relativePath: relativePath) {
            descriptor,
            initialInfo,
            source in
            let fileLimit = copyFileLimit(for: relativePath)
            guard initialInfo.st_size >= 0 else {
                throw KnitNoteBackupError.unsafePackageEntry
            }
            guard initialInfo.st_size <= fileLimit else {
                throw KnitNoteBackupError.fileTooLarge
            }
            guard initialInfo.st_size <= KnitNoteBackupLimits.maximumPackageBytes - totalBytes else {
                throw KnitNoteBackupError.packageTooLarge
            }

            let temporary = destination.deletingLastPathComponent().appendingPathComponent(
                ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
            )
            let destinationDescriptor = temporary.path.withCString {
                Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
            }
            guard destinationDescriptor >= 0 else {
                throw KnitNoteBackupError.unsafePackageEntry
            }
            var installed = false
            defer {
                Darwin.close(destinationDescriptor)
                if !installed { try? FileManager.default.removeItem(at: temporary) }
            }

            var copiedBytes: Int64 = 0
            var hasher = SHA256()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let fileRemaining = fileLimit - copiedBytes
                let packageRemaining = KnitNoteBackupLimits.maximumPackageBytes - totalBytes
                let allowed = max(0, min(fileRemaining, packageRemaining))
                let requested = min(buffer.count, Int(allowed + 1))
                let readCount = buffer.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, requested)
                }
                guard readCount >= 0 else { throw KnitNoteBackupError.unsafePackageEntry }
                guard readCount > 0 else { break }
                let chunkBytes = Int64(readCount)
                guard chunkBytes <= fileRemaining else {
                    throw KnitNoteBackupError.fileTooLarge
                }
                guard chunkBytes <= packageRemaining else {
                    throw KnitNoteBackupError.packageTooLarge
                }
                var written = 0
                try buffer.withUnsafeBytes { bytes in
                    while written < readCount {
                        let count = Darwin.write(
                            destinationDescriptor,
                            bytes.baseAddress?.advanced(by: written),
                            readCount - written
                        )
                        guard count > 0 else {
                            throw KnitNoteBackupError.unsafePackageEntry
                        }
                        written += count
                    }
                    hasher.update(data: Data(bytes: bytes.baseAddress!, count: readCount))
                }
                copiedBytes += chunkBytes
                totalBytes += chunkBytes
                try copyChunkHook(source, copiedBytes)
            }
            try validateUnchangedSource(
                descriptor: descriptor,
                initialInfo: initialInfo,
                copiedBytes: copiedBytes
            )
            guard Darwin.fsync(destinationDescriptor) == 0 else {
                throw KnitNoteBackupError.unsafePackageEntry
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            installed = true
            try normalizeOwnedFile(destination)
            return KnitNoteBackupManifestFile(
                relativePath: relativePath,
                byteCount: copiedBytes,
                sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
            )
        }
    }

    private func withLiveRegularFile<T>(
        relativePath: String,
        body: (Int32, stat, URL) throws -> T
    ) throws -> T {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.isEmpty,
              components.allSatisfy(isSafeFileComponent) else {
            throw KnitNoteBackupError.unsafePackageEntry
        }
        let rootDescriptor = liveRoot.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rootDescriptor >= 0 else { throw KnitNoteBackupError.unsafePackageEntry }
        defer { Darwin.close(rootDescriptor) }

        var parentDescriptor = rootDescriptor
        var ownedDescriptors: [Int32] = []
        defer { ownedDescriptors.reversed().forEach { Darwin.close($0) } }
        for component in components.dropLast() {
            var info = stat()
            let status = component.withCString {
                Darwin.fstatat(parentDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else { throw KnitNoteBackupError.unsafePackageEntry }
            let child = try openChildDirectory(
                named: component,
                relativeTo: parentDescriptor,
                expectedInfo: info
            )
            ownedDescriptors.append(child)
            parentDescriptor = child
        }

        let filename = components[components.count - 1]
        var initialInfo = stat()
        let status = filename.withCString {
            Darwin.fstatat(parentDescriptor, $0, &initialInfo, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else { throw KnitNoteBackupError.unsafePackageEntry }
        try beforeSourceEntryOpen(relativePath)
        let descriptor = try openChildRegularFile(
            named: filename,
            relativeTo: parentDescriptor,
            expectedInfo: initialInfo
        )
        defer { Darwin.close(descriptor) }
        return try body(
            descriptor,
            initialInfo,
            liveRoot.appendingPathComponent(relativePath)
        )
    }

    private func validateUnchangedSource(
        descriptor: Int32,
        initialInfo: stat,
        copiedBytes: Int64
    ) throws {
        var finalInfo = stat()
        guard Darwin.fstat(descriptor, &finalInfo) == 0,
              finalInfo.st_dev == initialInfo.st_dev,
              finalInfo.st_ino == initialInfo.st_ino,
              finalInfo.st_size == initialInfo.st_size,
              copiedBytes == initialInfo.st_size,
              finalInfo.st_mtimespec.tv_sec == initialInfo.st_mtimespec.tv_sec,
              finalInfo.st_mtimespec.tv_nsec == initialInfo.st_mtimespec.tv_nsec,
              finalInfo.st_ctimespec.tv_sec == initialInfo.st_ctimespec.tv_sec,
              finalInfo.st_ctimespec.tv_nsec == initialInfo.st_ctimespec.tv_nsec else {
            throw KnitNoteBackupError.unsafePackageEntry
        }
    }

    private func copyDataContentsBounded(
        fromPackageRoot packageRoot: URL,
        to destinationRoot: URL
    ) throws {
        let packageDescriptor = packageRoot.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard packageDescriptor >= 0 else { throw KnitNoteBackupError.unsafePackageEntry }
        defer { Darwin.close(packageDescriptor) }
        var packageInfo = stat()
        guard Darwin.fstat(packageDescriptor, &packageInfo) == 0,
              (packageInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw KnitNoteBackupError.unsafePackageEntry
        }

        var dataInfo = stat()
        let dataStatus = "Data".withCString {
            Darwin.fstatat(packageDescriptor, $0, &dataInfo, AT_SYMLINK_NOFOLLOW)
        }
        guard dataStatus == 0,
              (dataInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw KnitNoteBackupError.unsafePackageEntry
        }
        try beforeSourceEntryOpen("Data")
        let sourceDescriptor = try openChildDirectory(
            named: "Data",
            relativeTo: packageDescriptor,
            expectedInfo: dataInfo
        )
        defer { Darwin.close(sourceDescriptor) }

        var totalBytes: Int64 = 0
        try copyDirectoryContentsBounded(
            sourceDescriptor: sourceDescriptor,
            sourceDirectory: packageRoot.appendingPathComponent("Data", isDirectory: true),
            to: destinationRoot,
            relativeDirectory: "",
            totalBytes: &totalBytes
        )
    }

    private func copyDirectoryContentsBounded(
        sourceDescriptor: Int32,
        sourceDirectory: URL,
        to destinationDirectory: URL,
        relativeDirectory: String,
        totalBytes: inout Int64
    ) throws {
        for name in try directoryEntryNames(sourceDescriptor) {
            guard !name.hasPrefix("."), name != ".", name != ".." else {
                throw KnitNoteBackupError.unsafePackageEntry
            }
            let relativePath = relativeDirectory.isEmpty
                ? name
                : "\(relativeDirectory)/\(name)"
            var entryInfo = stat()
            let entryStatus = name.withCString {
                Darwin.fstatat(sourceDescriptor, $0, &entryInfo, AT_SYMLINK_NOFOLLOW)
            }
            guard entryStatus == 0 else { throw KnitNoteBackupError.unsafePackageEntry }
            try beforeSourceEntryOpen(relativePath)

            let source = sourceDirectory.appendingPathComponent(name)
            let entryType = entryInfo.st_mode & S_IFMT
            let destination = destinationDirectory.appendingPathComponent(
                name,
                isDirectory: entryType == S_IFDIR
            )
            if entryType == S_IFDIR {
                let childDescriptor = try openChildDirectory(
                    named: name,
                    relativeTo: sourceDescriptor,
                    expectedInfo: entryInfo
                )
                do {
                    defer { Darwin.close(childDescriptor) }
                    try createOwnedDirectory(destination)
                    try copyDirectoryContentsBounded(
                        sourceDescriptor: childDescriptor,
                        sourceDirectory: source,
                        to: destination,
                        relativeDirectory: relativePath,
                        totalBytes: &totalBytes
                    )
                }
            } else if entryType == S_IFREG {
                let fileDescriptor = try openChildRegularFile(
                    named: name,
                    relativeTo: sourceDescriptor,
                    expectedInfo: entryInfo
                )
                do {
                    defer { Darwin.close(fileDescriptor) }
                    try copyRegularFileBounded(
                        sourceDescriptor: fileDescriptor,
                        source: source,
                        to: destination,
                        relativePath: relativePath,
                        totalBytes: &totalBytes
                    )
                }
            } else {
                throw KnitNoteBackupError.unsafePackageEntry
            }
        }
    }

    private func copyRegularFileBounded(
        sourceDescriptor: Int32,
        source: URL,
        to destination: URL,
        relativePath: String,
        totalBytes: inout Int64
    ) throws {
        let fileLimit = copyFileLimit(for: relativePath)
        let destinationDescriptor = destination.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        }
        guard destinationDescriptor >= 0 else {
            throw KnitNoteBackupError.unsafePackageEntry
        }
        defer { Darwin.close(destinationDescriptor) }

        var copiedBytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let fileRemaining = fileLimit - copiedBytes
            let packageRemaining = KnitNoteBackupLimits.maximumPackageBytes - totalBytes
            let allowed = max(0, min(fileRemaining, packageRemaining))
            let requested = min(buffer.count, Int(allowed + 1))
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(sourceDescriptor, bytes.baseAddress, requested)
            }
            guard readCount >= 0 else { throw KnitNoteBackupError.unsafePackageEntry }
            guard readCount > 0 else { break }
            let chunkBytes = Int64(readCount)
            guard chunkBytes <= fileRemaining else {
                throw KnitNoteBackupError.fileTooLarge
            }
            guard chunkBytes <= packageRemaining else {
                throw KnitNoteBackupError.packageTooLarge
            }
            var written = 0
            try buffer.withUnsafeBytes { bytes in
                while written < readCount {
                    let result = Darwin.write(
                        destinationDescriptor,
                        bytes.baseAddress?.advanced(by: written),
                        readCount - written
                    )
                    guard result > 0 else { throw KnitNoteBackupError.unsafePackageEntry }
                    written += result
                }
            }
            copiedBytes += chunkBytes
            totalBytes += chunkBytes
            try copyChunkHook(source, copiedBytes)
        }
        try normalizeOwnedFile(destination)
    }

    private func openChildRegularFile(
        named name: String,
        relativeTo parentDescriptor: Int32,
        expectedInfo: stat
    ) throws -> Int32 {
        guard (expectedInfo.st_mode & S_IFMT) == S_IFREG else {
            throw KnitNoteBackupError.unsafePackageEntry
        }
        let descriptor = name.withCString {
            Darwin.openat(parentDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw KnitNoteBackupError.unsafePackageEntry }
        var openedInfo = stat()
        guard Darwin.fstat(descriptor, &openedInfo) == 0,
              (openedInfo.st_mode & S_IFMT) == S_IFREG,
              openedInfo.st_dev == expectedInfo.st_dev,
              openedInfo.st_ino == expectedInfo.st_ino else {
            Darwin.close(descriptor)
            throw KnitNoteBackupError.unsafePackageEntry
        }
        return descriptor
    }

    private func directoryEntryNames(_ descriptor: Int32) throws -> [String] {
        let duplicateDescriptor = Darwin.dup(descriptor)
        guard duplicateDescriptor >= 0 else { throw KnitNoteBackupError.unsafePackageEntry }
        guard let stream = Darwin.fdopendir(duplicateDescriptor) else {
            Darwin.close(duplicateDescriptor)
            throw KnitNoteBackupError.unsafePackageEntry
        }
        defer { Darwin.closedir(stream) }

        var names: [String] = []
        errno = 0
        while let entry = Darwin.readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { namePointer in
                namePointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(entry.pointee.d_namlen) + 1
                ) {
                    String(validatingCString: $0)
                }
            }
            guard let name else { throw KnitNoteBackupError.unsafePackageEntry }
            if name != ".", name != ".." { names.append(name) }
        }
        guard errno == 0 else { throw KnitNoteBackupError.unsafePackageEntry }
        return names.sorted()
    }

    private func copyFileLimit(for relativePath: String) -> Int64 {
        if relativePath == "projects-v1.json" {
            return KnitNoteBackupLimits.maximumArchiveBytes
        }
        if isStructuredMarkupPath(relativePath) {
            return KnitNoteBackupLimits.maximumMarkupBytes
        }
        return KnitNoteBackupLimits.maximumFileBytes
    }

    private func createOwnedDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        var attributes: [FileAttributeKey: Any] = [
            .posixPermissions: NSNumber(value: 0o700),
        ]
#if os(iOS) || os(watchOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
#endif
        try FileManager.default.setAttributes(attributes, ofItemAtPath: directory.path)
    }

    private func ensureOwnedWorkRoot() throws {
        let trustedParent = liveRoot.deletingLastPathComponent().standardizedFileURL
        let standardizedWorkRoot = workRoot.standardizedFileURL
        guard standardizedWorkRoot.path.hasPrefix(trustedParent.path + "/") else {
            throw KnitNoteBackupError.unsafePackageEntry
        }

        let parentDescriptor = try openDescendantDirectory(
            standardizedWorkRoot.deletingLastPathComponent(),
            below: trustedParent
        )
        defer { Darwin.close(parentDescriptor) }
        let leafName = standardizedWorkRoot.lastPathComponent
        guard !leafName.isEmpty, leafName != ".", leafName != ".." else {
            throw KnitNoteBackupError.unsafePackageEntry
        }

        var leafInfo = stat()
        let status = leafName.withCString {
            Darwin.fstatat(parentDescriptor, $0, &leafInfo, AT_SYMLINK_NOFOLLOW)
        }
        if status != 0 {
            guard errno == ENOENT else { throw KnitNoteBackupError.unsafePackageEntry }
            let created = leafName.withCString {
                Darwin.mkdirat(parentDescriptor, $0, mode_t(0o700))
            }
            guard created == 0 else { throw KnitNoteBackupError.unsafePackageEntry }
        } else {
            guard (leafInfo.st_mode & S_IFMT) == S_IFDIR else {
                throw KnitNoteBackupError.unsafePackageEntry
            }
        }

        let workDescriptor = try openChildDirectory(
            named: leafName,
            relativeTo: parentDescriptor,
            expectedInfo: status == 0 ? leafInfo : nil
        )
        defer { Darwin.close(workDescriptor) }
        guard Darwin.fchmod(workDescriptor, mode_t(0o700)) == 0 else {
            throw KnitNoteBackupError.accessDenied
        }
    }

    private func openDescendantDirectory(_ directory: URL, below root: URL) throws -> Int32 {
        let standardizedRoot = root.standardizedFileURL
        let standardizedDirectory = directory.standardizedFileURL
        guard standardizedDirectory.path == standardizedRoot.path
                || standardizedDirectory.path.hasPrefix(standardizedRoot.path + "/") else {
            throw KnitNoteBackupError.unsafePackageEntry
        }

        var currentDescriptor = standardizedRoot.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard currentDescriptor >= 0 else { throw KnitNoteBackupError.unsafePackageEntry }
        do {
            let relativePath = standardizedDirectory.path == standardizedRoot.path
                ? ""
                : String(standardizedDirectory.path.dropFirst(standardizedRoot.path.count + 1))
            for component in relativePath.split(separator: "/").map(String.init) {
                let nextDescriptor = try openChildDirectory(
                    named: component,
                    relativeTo: currentDescriptor
                )
                Darwin.close(currentDescriptor)
                currentDescriptor = nextDescriptor
            }
            return currentDescriptor
        } catch {
            Darwin.close(currentDescriptor)
            throw error
        }
    }

    private func openChildDirectory(
        named name: String,
        relativeTo parentDescriptor: Int32,
        expectedInfo: stat? = nil
    ) throws -> Int32 {
        var entryInfo = stat()
        if let expectedInfo {
            entryInfo = expectedInfo
        } else {
            let status = name.withCString {
                Darwin.fstatat(parentDescriptor, $0, &entryInfo, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else { throw KnitNoteBackupError.unsafePackageEntry }
        }
        guard (entryInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw KnitNoteBackupError.unsafePackageEntry
        }
        let descriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { throw KnitNoteBackupError.unsafePackageEntry }
        var openedInfo = stat()
        guard Darwin.fstat(descriptor, &openedInfo) == 0,
              (openedInfo.st_mode & S_IFMT) == S_IFDIR,
              openedInfo.st_dev == entryInfo.st_dev,
              openedInfo.st_ino == entryInfo.st_ino else {
            Darwin.close(descriptor)
            throw KnitNoteBackupError.unsafePackageEntry
        }
        return descriptor
    }

    private func normalizeOwnedFile(_ file: URL) throws {
        var attributes: [FileAttributeKey: Any] = [
            .posixPermissions: NSNumber(value: 0o600),
        ]
#if os(iOS) || os(watchOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
#endif
        try FileManager.default.setAttributes(attributes, ofItemAtPath: file.path)
    }

    private func verifyStagedTreeIsWritable(_ dataRoot: URL) throws {
        let probe = dataRoot.appendingPathComponent(
            ".write-probe-\(UUID().uuidString)",
            isDirectory: false
        )
        do {
            try Data([0]).write(to: probe, options: .withoutOverwriting)
            try FileManager.default.removeItem(at: probe)
        } catch {
            try? FileManager.default.removeItem(at: probe)
            throw KnitNoteBackupError.accessDenied
        }
    }

    private func validateWorkRootAncestry() throws {
        let trustedParent = liveRoot.deletingLastPathComponent().standardizedFileURL
        var candidate = workRoot.standardizedFileURL
        guard candidate.path.hasPrefix(trustedParent.path + "/") else {
            throw KnitNoteBackupError.unsafePackageEntry
        }

        while true {
            let values = try entryValues(candidate)
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else {
                throw KnitNoteBackupError.unsafePackageEntry
            }
            if candidate.path == trustedParent.path { return }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            guard parent.path != candidate.path else {
                throw KnitNoteBackupError.unsafePackageEntry
            }
            candidate = parent
        }
    }

    private func validatePhysicalReplacementVolume(
        stagedData: URL,
        rollbackRoot: URL,
        includesLiveRoot: Bool
    ) throws {
        var locations = [
            liveRoot.deletingLastPathComponent(),
            workRoot,
            stagedData,
            rollbackRoot.deletingLastPathComponent(),
        ]
        if includesLiveRoot {
            locations.append(liveRoot)
        }
        let identifiers = try locations.map {
            try entryValues($0).physicalVolumeIdentifier
        }
        guard identifiers.allSatisfy({ $0 != nil }),
              Set(identifiers.compactMap { $0 }).count == 1 else {
            throw KnitNoteBackupError.crossVolumeReplacement
        }
    }

    private func isGeneratedArtifactName(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    private func availableRollbackRoots() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: workRoot.path) else { return [] }
        return try contents(of: workRoot).filter { candidate in
            guard isGeneratedArtifactName(
                candidate.lastPathComponent,
                prefix: "Rollback-"
            ) else { return false }
            let values = try? entryValues(candidate)
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
    }

    private func cleanupGeneratedArtifactsAfterValidChoice() {
        guard FileManager.default.fileExists(atPath: workRoot.path) else { return }
        guard let candidates = try? contents(of: workRoot) else { return }
        for candidate in candidates {
            let filename = candidate.lastPathComponent
            let exportSuffix = ".knitnote-backup"
            let isExport = filename.hasSuffix(exportSuffix)
                && UUID(uuidString: String(filename.dropLast(exportSuffix.count))) != nil
            let isStaged = isGeneratedArtifactName(filename, prefix: "Staged-")
            let isRollback = isGeneratedArtifactName(filename, prefix: "Rollback-")
            let isCleanup = isGeneratedArtifactName(filename, prefix: "Cleanup-")
            guard isExport || isStaged || isRollback || isCleanup,
                  let values = try? entryValues(candidate) else { continue }
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else {
                continue
            }
            try? cleanupItem(candidate)
        }
    }

    private func validateLiveRoot(_ root: URL) throws {
        let validator = KnitNoteBackupService(liveRoot: root, workRoot: workRoot)
        try validator.validateLiveArchive()
    }

    private func validateLiveArchive() throws {
        try validateLiveSource(relativePath: "projects-v1.json", expectsDirectory: false)
        let archive: ProjectArchive
        do {
            archive = try JSONDecoder().decode(
                ProjectArchive.self,
                from: Data(contentsOf: liveRoot.appendingPathComponent("projects-v1.json"))
            )
        } catch {
            throw KnitNoteBackupError.invalidArchive
        }
        try validateArchive(archive)
        for relativePath in try referencedRelativePaths(in: archive, sourceRoot: liveRoot) {
            try validateLiveSource(relativePath: relativePath, expectsDirectory: false)
        }
    }

    private func referencedRelativePaths(
        in archive: ProjectArchive,
        sourceRoot: URL
    ) throws -> [String] {
        guard sourceRoot.standardizedFileURL == liveRoot.standardizedFileURL else {
            throw KnitNoteBackupError.unsafePackageEntry
        }
        var paths = referencedMediaPaths(in: archive)
        for project in archive.projects {
            for pattern in project.patterns {
                let ownerPath = "Patterns/\(project.id.uuidString)/Markup/\(pattern.id.uuidString)"
                for relativePath in try descriptorMarkupPaths(ownerPath: ownerPath) {
                    paths.insert(relativePath)
                }
            }
        }
        for usage in archive.patternUsages {
            let ownerPath = "Patterns/UsageMarkup/\(usage.id.uuidString)"
            for relativePath in try descriptorMarkupPaths(ownerPath: ownerPath) {
                paths.insert(relativePath)
            }
        }
        return paths.sorted()
    }

    private func descriptorMarkupPaths(ownerPath: String) throws -> [String] {
        let components = ownerPath.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.isEmpty,
              components.allSatisfy(isSafeFileComponent) else {
            throw KnitNoteBackupError.unsafePackageEntry
        }
        let rootDescriptor = liveRoot.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rootDescriptor >= 0 else {
            throw KnitNoteBackupError.unsafePackageEntry
        }
        var openedDescriptors = [rootDescriptor]
        defer { openedDescriptors.reversed().forEach { Darwin.close($0) } }

        var currentDescriptor = rootDescriptor
        var ownerParentDescriptor = rootDescriptor
        var ownerInfo = stat()
        var relativePath = ""
        for (index, component) in components.enumerated() {
            var entryInfo = stat()
            errno = 0
            let status = component.withCString {
                Darwin.fstatat(currentDescriptor, $0, &entryInfo, AT_SYMLINK_NOFOLLOW)
            }
            if status != 0, errno == ENOENT {
                return []
            }
            guard status == 0,
                  (entryInfo.st_mode & S_IFMT) == S_IFDIR else {
                throw KnitNoteBackupError.unsafePackageEntry
            }
            relativePath = relativePath.isEmpty
                ? component
                : "\(relativePath)/\(component)"
            try beforeSourceEntryOpen(relativePath)
            let childDescriptor = try openChildDirectory(
                named: component,
                relativeTo: currentDescriptor,
                expectedInfo: entryInfo
            )
            openedDescriptors.append(childDescriptor)
            if index == components.count - 1 {
                ownerParentDescriptor = currentDescriptor
                ownerInfo = entryInfo
            }
            currentDescriptor = childDescriptor
        }

        let filenames = try boundedMarkupEntryNames(
            currentDescriptor,
            ownerPath: ownerPath,
            initialInfo: ownerInfo
        )
        var finalBinding = stat()
        let bindingStatus = components[components.count - 1].withCString {
            Darwin.fstatat(
                ownerParentDescriptor,
                $0,
                &finalBinding,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard bindingStatus == 0,
              (finalBinding.st_mode & S_IFMT) == S_IFDIR,
              finalBinding.st_dev == ownerInfo.st_dev,
              finalBinding.st_ino == ownerInfo.st_ino else {
            throw KnitNoteBackupError.unsafePackageEntry
        }
        return filenames.map { "\(ownerPath)/\($0)" }
    }

    private func boundedMarkupEntryNames(
        _ descriptor: Int32,
        ownerPath: String,
        initialInfo: stat
    ) throws -> [String] {
        let duplicateDescriptor = Darwin.dup(descriptor)
        guard duplicateDescriptor >= 0 else {
            throw KnitNoteBackupError.unsafePackageEntry
        }
        guard let stream = Darwin.fdopendir(duplicateDescriptor) else {
            Darwin.close(duplicateDescriptor)
            throw KnitNoteBackupError.unsafePackageEntry
        }
        defer { Darwin.closedir(stream) }

        var names: [String] = []
        var didReachFirstEntry = false
        while true {
            errno = 0
            guard let entry = Darwin.readdir(stream) else {
                guard errno == 0 else {
                    throw KnitNoteBackupError.unsafePackageEntry
                }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) { namePointer in
                namePointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(entry.pointee.d_namlen) + 1
                ) {
                    String(validatingCString: $0)
                }
            }
            guard let name else {
                throw KnitNoteBackupError.unsafePackageEntry
            }
            guard name != ".", name != ".." else { continue }
            guard !name.hasPrefix("."), isSafeFileComponent(name) else {
                throw KnitNoteBackupError.unsafePackageEntry
            }
            guard names.count < KnitNoteBackupLimits.maximumMarkupEntriesPerPattern else {
                throw KnitNoteBackupError.invalidMarkup
            }
            if !didReachFirstEntry {
                didReachFirstEntry = true
                try beforeSourceEntryOpen("\(ownerPath)/.enumerating")
            }
            var entryInfo = stat()
            let status = name.withCString {
                Darwin.fstatat(descriptor, $0, &entryInfo, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else {
                throw KnitNoteBackupError.unsafePackageEntry
            }
            guard (entryInfo.st_mode & S_IFMT) == S_IFREG,
                  isMarkupFilename(name) else {
                throw KnitNoteBackupError.unknownPackageEntry
            }
            names.append(name)
        }
        var finalInfo = stat()
        guard Darwin.fstat(descriptor, &finalInfo) == 0,
              finalInfo.st_dev == initialInfo.st_dev,
              finalInfo.st_ino == initialInfo.st_ino,
              finalInfo.st_mtimespec.tv_sec == initialInfo.st_mtimespec.tv_sec,
              finalInfo.st_mtimespec.tv_nsec == initialInfo.st_mtimespec.tv_nsec,
              finalInfo.st_ctimespec.tv_sec == initialInfo.st_ctimespec.tv_sec,
              finalInfo.st_ctimespec.tv_nsec == initialInfo.st_ctimespec.tv_nsec else {
            throw KnitNoteBackupError.unsafePackageEntry
        }
        return names.sorted()
    }

    private func decodeManifest(at packageRoot: URL) throws -> KnitNoteBackupManifest {
        do {
            return try JSONDecoder().decode(
                KnitNoteBackupManifest.self,
                from: Data(contentsOf: packageRoot.appendingPathComponent("manifest.json"))
            )
        } catch let error as KnitNoteBackupError {
            throw error
        } catch {
            throw KnitNoteBackupError.invalidManifest
        }
    }

    private func patternCount(in archive: ProjectArchive) -> Int {
        archive.version == ProjectArchive.currentVersion
            ? archive.patterns.count
            : archive.projects.reduce(0) { $0 + $1.patterns.count }
    }

    private func manifestFiles(in dataRoot: URL) throws -> [KnitNoteBackupManifestFile] {
        var entries: [KnitNoteBackupManifestFile] = []
        try collectManifestFiles(
            in: dataRoot,
            relativeDirectory: "",
            entries: &entries
        )
        return entries.sorted { $0.relativePath < $1.relativePath }
    }

    private func collectManifestFiles(
        in directory: URL,
        relativeDirectory: String,
        entries: inout [KnitNoteBackupManifestFile]
    ) throws {
        for item in try contents(of: directory) {
            try rejectHiddenOrSymbolic(item)
            let values = try entryValues(item)
            let relativePath = relativeDirectory.isEmpty
                ? item.lastPathComponent
                : "\(relativeDirectory)/\(item.lastPathComponent)"
            if values.isDirectory == true {
                try collectManifestFiles(
                    in: item,
                    relativeDirectory: relativePath,
                    entries: &entries
                )
            } else if values.isRegularFile == true {
                let integrity = try fileIntegrity(at: item)
                entries.append(.init(
                    relativePath: relativePath,
                    byteCount: integrity.byteCount,
                    sha256: integrity.sha256
                ))
            } else {
                throw KnitNoteBackupError.unsafePackageEntry
            }
        }
    }

    private func validateManifestFiles(
        _ manifest: KnitNoteBackupManifest,
        in dataRoot: URL
    ) throws {
        guard manifest.formatVersion == 2 else { return }
        guard !manifest.files.isEmpty,
              manifest.criticalFeatures == [KnitNoteBackupManifest.fileIntegrityFeature] else {
            throw KnitNoteBackupError.invalidManifest
        }
        var exactPaths: Set<String> = []
        var foldedPaths: Set<String> = []
        for entry in manifest.files {
            guard isSafeManifestRelativePath(entry.relativePath),
                  entry.byteCount >= 0,
                  entry.byteCount <= copyFileLimit(for: entry.relativePath),
                  isSHA256(entry.sha256),
                  exactPaths.insert(entry.relativePath).inserted,
                  foldedPaths.insert(foldedPath(entry.relativePath)).inserted else {
                throw KnitNoteBackupError.unsafePackageEntry
            }
        }
        guard exactPaths.contains("projects-v1.json") else {
            throw KnitNoteBackupError.invalidManifest
        }

        let physicalFiles = try manifestFiles(in: dataRoot)
        guard Set(physicalFiles.map(\.relativePath)) == exactPaths else {
            throw KnitNoteBackupError.unknownPackageEntry
        }
        let expectedByPath = Dictionary(
            uniqueKeysWithValues: manifest.files.map { ($0.relativePath, $0) }
        )
        for actual in physicalFiles {
            guard let expected = expectedByPath[actual.relativePath] else {
                throw KnitNoteBackupError.unknownPackageEntry
            }
            guard actual.byteCount == expected.byteCount,
                  actual.sha256 == expected.sha256 else {
                throw KnitNoteBackupError.integrityMismatch(actual.relativePath)
            }
        }
    }

    private func isSafeManifestRelativePath(_ relativePath: String) -> Bool {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\") else {
            return false
        }
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".")
              }) else {
            return false
        }
        return components.joined(separator: "/") == relativePath
    }

    private func foldedPath(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased(
            with: Locale(identifier: "en_US_POSIX")
        )
    }

    private func isSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) }
    }

    private func fileIntegrity(at file: URL) throws -> (byteCount: Int64, sha256: String) {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file)
        } catch {
            throw KnitNoteBackupError.unsafePackageEntry
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        do {
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                guard byteCount <= KnitNoteBackupLimits.maximumPackageBytes - Int64(chunk.count) else {
                    throw KnitNoteBackupError.packageTooLarge
                }
                byteCount += Int64(chunk.count)
                hasher.update(data: chunk)
            }
        } catch let error as KnitNoteBackupError {
            throw error
        } catch {
            throw KnitNoteBackupError.unsafePackageEntry
        }
        return (
            byteCount,
            hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private func validatePackageRoot(_ packageRoot: URL) throws {
        let rootValues = try entryValues(packageRoot)
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw KnitNoteBackupError.unsafePackageEntry
        }
        let children = try contents(of: packageRoot)
        var hasManifest = false
        var hasData = false
        for child in children {
            try rejectHiddenOrSymbolic(child)
            let values = try entryValues(child)
            switch child.lastPathComponent {
            case "manifest.json":
                guard values.isRegularFile == true else {
                    throw KnitNoteBackupError.unsafePackageEntry
                }
                hasManifest = true
            case "Data":
                guard values.isDirectory == true else {
                    throw KnitNoteBackupError.unsafePackageEntry
                }
                hasData = true
            default:
                throw KnitNoteBackupError.unknownPackageEntry
            }
        }
        guard hasManifest else { throw KnitNoteBackupError.invalidManifest }
        guard hasData else { throw KnitNoteBackupError.invalidArchive }
    }

    private func validatePackageSizes(_ root: URL) throws {
        var totalBytes: Int64 = 0
        try accumulatePackageSizes(
            in: root,
            packageRoot: root,
            totalBytes: &totalBytes
        )
    }

    private func accumulatePackageSizes(
        in directory: URL,
        packageRoot: URL,
        totalBytes: inout Int64
    ) throws {
        for item in try contents(of: directory) {
            try rejectHiddenOrSymbolic(item)
            let values = try entryValues(item)
            if values.isDirectory == true {
                try accumulatePackageSizes(
                    in: item,
                    packageRoot: packageRoot,
                    totalBytes: &totalBytes
                )
                continue
            }
            guard values.isRegularFile == true,
                  let rawSize = values.fileSize,
                  rawSize >= 0 else {
                throw KnitNoteBackupError.unsafePackageEntry
            }
            let size = rawSize
            let relativePath = relativePath(of: item, below: packageRoot)
            let fileLimit: Int64
            switch relativePath {
            case "manifest.json":
                fileLimit = KnitNoteBackupLimits.maximumManifestBytes
            case "projects-v1.json", "Data/projects-v1.json":
                fileLimit = KnitNoteBackupLimits.maximumArchiveBytes
            case let path where isStructuredMarkupPath(path):
                fileLimit = KnitNoteBackupLimits.maximumMarkupBytes
            default:
                fileLimit = KnitNoteBackupLimits.maximumFileBytes
            }
            guard size <= fileLimit else {
                throw KnitNoteBackupError.fileTooLarge
            }
            guard totalBytes <= KnitNoteBackupLimits.maximumPackageBytes - size else {
                throw KnitNoteBackupError.packageTooLarge
            }
            totalBytes += size
        }
    }

    private func validateDataTopLevel(_ dataRoot: URL) throws {
        let children = try contents(of: dataRoot)
        var hasArchive = false
        let directoryNames: Set<String> = [
            "ProjectPhotos", "YarnPhotos", "ProjectJournalPhotos", "Patterns",
        ]
        for child in children {
            try rejectHiddenOrSymbolic(child)
            let values = try entryValues(child)
            let name = child.lastPathComponent
            if name == "projects-v1.json" {
                guard values.isRegularFile == true else {
                    throw KnitNoteBackupError.unsafePackageEntry
                }
                hasArchive = true
            } else if directoryNames.contains(name) {
                guard values.isDirectory == true else {
                    throw KnitNoteBackupError.unsafePackageEntry
                }
            } else {
                throw KnitNoteBackupError.unknownPackageEntry
            }
        }
        guard hasArchive else { throw KnitNoteBackupError.invalidArchive }
    }

    private func validateArchive(_ archive: ProjectArchive) throws {
        guard archive.version <= ProjectArchive.currentVersion else {
            throw KnitNoteBackupError.unsupportedNewerVersion(archive.version)
        }
        guard ProjectArchive.isSupported(version: archive.version) else {
            throw KnitNoteBackupError.invalidArchive
        }
        guard Set(archive.projects.map(\.id)).count == archive.projects.count,
              Set(archive.yarns.map(\.id)).count == archive.yarns.count,
              Set(archive.patternAssets.map(\.id)).count == archive.patternAssets.count,
              Set(archive.patterns.map(\.id)).count == archive.patterns.count,
              Set(archive.patternUsages.map(\.id)).count == archive.patternUsages.count else {
            throw KnitNoteBackupError.duplicateIdentifier
        }
        let projectIDs = Set(archive.projects.map(\.id))
        guard archive.yarns.allSatisfy({ $0.linkedProjectIDs.isSubset(of: projectIDs) }) else {
            throw KnitNoteBackupError.invalidYarnProjectLinks
        }
        if archive.version == ProjectArchive.currentVersion {
            do {
                _ = try PatternLibrarySnapshot(
                    assets: archive.patternAssets,
                    patterns: archive.patterns,
                    usages: archive.patternUsages,
                    validProjectIDs: archive.projects.map(\.id)
                ).validated()
            } catch let error as PatternLibraryValidationError {
                switch error {
                case .duplicateAssetID, .duplicatePatternID, .duplicateUsageID,
                     .duplicateProjectID, .duplicateUsage:
                    throw KnitNoteBackupError.duplicateIdentifier
                case .missingAsset, .missingPattern, .missingProject:
                    throw KnitNoteBackupError.invalidArchive
                }
            } catch {
                throw KnitNoteBackupError.invalidArchive
            }
            for asset in archive.patternAssets {
                guard isOwnedAssetFilename(asset.storedFilename, asset: asset),
                      asset.byteCount >= 0,
                      asset.byteCount <= 100_000_000,
                      isSHA256(asset.sha256) else {
                    throw KnitNoteBackupError.unsafePackageEntry
                }
            }
        } else if !archive.patternAssets.isEmpty
                    || !archive.patterns.isEmpty
                    || !archive.patternUsages.isEmpty {
            throw KnitNoteBackupError.invalidArchive
        }

        for project in archive.projects {
            if let filename = project.photoFilename {
                guard isOwnedPhotoFilename(filename, ownerID: project.id) else {
                    throw KnitNoteBackupError.unsafePackageEntry
                }
            }
            for entry in project.journalEntries {
                guard ProjectJournalPhotoFilename.isOwnedPair(
                    full: entry.photoFilename,
                    thumbnail: entry.thumbnailFilename,
                    projectID: project.id,
                    entryID: entry.id
                ) else {
                    throw KnitNoteBackupError.unsafePackageEntry
                }
            }
            for pattern in project.patterns {
                guard isOwnedPatternFilename(pattern.storedFilename, pattern: pattern) else {
                    throw KnitNoteBackupError.unsafePackageEntry
                }
            }
        }
        for yarn in archive.yarns {
            if let filename = yarn.photoFilename {
                guard isOwnedPhotoFilename(filename, ownerID: yarn.id) else {
                    throw KnitNoteBackupError.unsafePackageEntry
                }
            }
        }
    }

    private func validateDataTree(_ dataRoot: URL, archive: ProjectArchive) throws {
        var allowedFiles = referencedMediaPaths(in: archive)
        allowedFiles.insert("projects-v1.json")
        var allowedDirectories: Set<String> = [
            "ProjectPhotos", "YarnPhotos", "ProjectJournalPhotos", "Patterns",
        ]
        var knownMarkupOwners: Set<String> = []
        for project in archive.projects {
            let projectPath = "Patterns/\(project.id.uuidString)"
            allowedDirectories.insert(projectPath)
            allowedDirectories.insert("\(projectPath)/Markup")
            for pattern in project.patterns {
                let owner = "\(projectPath)/Markup/\(pattern.id.uuidString)"
                allowedDirectories.insert(owner)
                knownMarkupOwners.insert(owner)
            }
        }
        if archive.version == ProjectArchive.currentVersion {
            allowedDirectories.insert("Patterns/Assets")
            allowedDirectories.insert("Patterns/UsageMarkup")
            for usage in archive.patternUsages {
                let owner = "Patterns/UsageMarkup/\(usage.id.uuidString)"
                allowedDirectories.insert(owner)
                knownMarkupOwners.insert(owner)
            }
        }

        var foundFiles: Set<String> = []
        var markupEntryCounts: [String: Int] = [:]
        try walkDataDirectory(
            dataRoot,
            relativeDirectory: "",
            allowedFiles: allowedFiles,
            allowedDirectories: allowedDirectories,
            knownMarkupOwners: knownMarkupOwners,
            foundFiles: &foundFiles,
            markupEntryCounts: &markupEntryCounts
        )
        for relativePath in allowedFiles where relativePath != "projects-v1.json" {
            guard foundFiles.contains(relativePath) else {
                throw KnitNoteBackupError.missingReferencedFile(relativePath)
            }
        }
        if archive.version == ProjectArchive.currentVersion {
            for asset in archive.patternAssets {
                let relativePath = "Patterns/Assets/\(asset.storedFilename)"
                let file = dataRoot.appendingPathComponent(relativePath)
                let integrity = try fileIntegrity(at: file)
                guard integrity.byteCount == asset.byteCount,
                      integrity.sha256 == asset.sha256 else {
                    throw KnitNoteBackupError.integrityMismatch(relativePath)
                }
            }
        }
    }

    private func walkDataDirectory(
        _ directory: URL,
        relativeDirectory: String,
        allowedFiles: Set<String>,
        allowedDirectories: Set<String>,
        knownMarkupOwners: Set<String>,
        foundFiles: inout Set<String>,
        markupEntryCounts: inout [String: Int]
    ) throws {
        for item in try contents(of: directory) {
            try rejectHiddenOrSymbolic(item)
            let values = try entryValues(item)
            let relativePath = relativeDirectory.isEmpty
                ? item.lastPathComponent
                : "\(relativeDirectory)/\(item.lastPathComponent)"
            if values.isDirectory == true {
                guard allowedDirectories.contains(relativePath) else {
                    throw KnitNoteBackupError.unknownPackageEntry
                }
                try walkDataDirectory(
                    item,
                    relativeDirectory: relativePath,
                    allowedFiles: allowedFiles,
                    allowedDirectories: allowedDirectories,
                    knownMarkupOwners: knownMarkupOwners,
                    foundFiles: &foundFiles,
                    markupEntryCounts: &markupEntryCounts
                )
            } else if values.isRegularFile == true {
                if allowedFiles.contains(relativePath) {
                    foundFiles.insert(relativePath)
                } else if let owner = markupOwner(of: relativePath),
                          knownMarkupOwners.contains(owner),
                          isMarkupFilename(item.lastPathComponent) {
                    do {
                        let nextEntryCount = (markupEntryCounts[owner] ?? 0) + 1
                        guard nextEntryCount <= KnitNoteBackupLimits.maximumMarkupEntriesPerPattern else {
                            throw KnitNoteBackupError.invalidMarkup
                        }
                        markupEntryCounts[owner] = nextEntryCount
                        let metadata = try entryValues(item)
                        guard let byteCount = metadata.fileSize,
                              byteCount >= 0,
                              byteCount <= KnitNoteBackupLimits.maximumMarkupBytes else {
                            throw KnitNoteBackupError.fileTooLarge
                        }
                        let data = try Data(contentsOf: item, options: .mappedIfSafe)
                        guard data.count <= KnitNoteBackupLimits.maximumMarkupBytes else {
                            throw KnitNoteBackupError.fileTooLarge
                        }
                        let document = try JSONDecoder().decode(
                            PatternMarkupDocument.self,
                            from: data
                        )
                        try validateMarkupDocument(document)
                    } catch let error as KnitNoteBackupError {
                        throw error
                    } catch {
                        throw KnitNoteBackupError.invalidMarkup
                    }
                } else {
                    throw KnitNoteBackupError.unknownPackageEntry
                }
            } else {
                throw KnitNoteBackupError.unsafePackageEntry
            }
        }
    }

    private func referencedMediaPaths(in archive: ProjectArchive) -> Set<String> {
        var paths: Set<String> = []
        for project in archive.projects {
            if let filename = project.photoFilename {
                paths.insert("ProjectPhotos/\(filename)")
            }
            for entry in project.journalEntries {
                paths.insert("ProjectJournalPhotos/\(entry.photoFilename)")
                paths.insert("ProjectJournalPhotos/\(entry.thumbnailFilename)")
            }
            for pattern in project.patterns {
                paths.insert("Patterns/\(project.id.uuidString)/\(pattern.storedFilename)")
            }
        }
        for yarn in archive.yarns {
            if let filename = yarn.photoFilename {
                paths.insert("YarnPhotos/\(filename)")
            }
        }
        for asset in archive.patternAssets {
            paths.insert("Patterns/Assets/\(asset.storedFilename)")
        }
        return paths
    }

    private func isOwnedPhotoFilename(_ filename: String, ownerID: UUID) -> Bool {
        guard isSafeFileComponent(filename), filename.hasSuffix(".jpg") else { return false }
        let stem = String(filename.dropLast(4))
        guard stem.count == 73 else { return false }
        let separator = stem.index(stem.startIndex, offsetBy: 36)
        guard stem[separator] == "-" else { return false }
        return UUID(uuidString: String(stem[..<separator])) == ownerID
            && UUID(uuidString: String(stem[stem.index(after: separator)...])) != nil
    }

    private func isOwnedPatternFilename(
        _ filename: String,
        pattern: PatternDocument
    ) -> Bool {
        guard isSafeFileComponent(filename) else { return false }
        let url = URL(fileURLWithPath: filename)
        guard url.deletingPathExtension().lastPathComponent == pattern.id.uuidString else {
            return false
        }
        switch pattern.kind {
        case .pdf:
            return url.pathExtension == "pdf"
        case .image:
            return ["png", "jpg", "jpeg", "heic"].contains(url.pathExtension)
        }
    }

    private func isOwnedAssetFilename(
        _ filename: String,
        asset: PatternAsset
    ) -> Bool {
        guard isSafeFileComponent(filename) else { return false }
        let url = URL(fileURLWithPath: filename)
        guard url.deletingPathExtension().lastPathComponent == asset.id.uuidString else {
            return false
        }
        switch asset.kind {
        case .pdf:
            return url.pathExtension == "pdf"
        case .image:
            return ["png", "jpg", "jpeg", "heic"].contains(url.pathExtension)
        }
    }

    private func isSafeFileComponent(_ value: String) -> Bool {
        !value.isEmpty
            && !value.hasPrefix(".")
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("..")
            && URL(fileURLWithPath: value).lastPathComponent == value
    }

    private func markupOwner(of relativePath: String) -> String? {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        if components.count == 5,
           components[0] == "Patterns",
           components[2] == "Markup" {
            return components.prefix(4).joined(separator: "/")
        }
        if components.count == 4,
           components[0] == "Patterns",
           components[1] == "UsageMarkup" {
            return components.prefix(3).joined(separator: "/")
        }
        return nil
    }

    private func isMarkupFilename(_ filename: String) -> Bool {
        guard isSafeFileComponent(filename), filename.hasSuffix(".json") else { return false }
        let page = filename.dropLast(5)
        return Int(page).map { $0 >= 0 && String($0) == page } == true
    }

    private func isStructuredMarkupPath(_ relativePath: String) -> Bool {
        var components = relativePath.split(separator: "/").map(String.init)
        if components.first == "Data" { components.removeFirst() }
        if components.count == 5,
           components[0] == "Patterns",
           components[2] == "Markup" {
            return isMarkupFilename(components[4])
        }
        if components.count == 4,
           components[0] == "Patterns",
           components[1] == "UsageMarkup" {
            return isMarkupFilename(components[3])
        }
        return false
    }

    private func validateMarkupDocument(_ document: PatternMarkupDocument) throws {
        guard document.strokes.count <= KnitNoteBackupLimits.maximumMarkupStrokesPerDocument else {
            throw KnitNoteBackupError.invalidMarkup
        }
        var totalPoints = 0
        for stroke in document.strokes {
            guard stroke.points.count <= KnitNoteBackupLimits.maximumMarkupPointsPerStroke,
                  totalPoints <= KnitNoteBackupLimits.maximumMarkupPointsPerDocument - stroke.points.count else {
                throw KnitNoteBackupError.invalidMarkup
            }
            totalPoints += stroke.points.count
        }
    }

    private func rejectHiddenOrSymbolic(_ url: URL) throws {
        let values = try entryValues(url)
        guard !url.lastPathComponent.hasPrefix("."), values.isSymbolicLink != true else {
            throw KnitNoteBackupError.unsafePackageEntry
        }
    }

    private func validateLiveSource(
        relativePath: String,
        expectsDirectory: Bool
    ) throws {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ isSafeFileComponent(String($0)) }) else {
            throw KnitNoteBackupError.unsafePackageEntry
        }

        let rootValues = try entryValues(liveRoot)
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw KnitNoteBackupError.unsafePackageEntry
        }

        var candidate = liveRoot
        for (index, component) in components.enumerated() {
            candidate.appendPathComponent(String(component))
            let values = try entryValues(candidate)
            guard values.isSymbolicLink != true else {
                throw KnitNoteBackupError.unsafePackageEntry
            }
            let isLeaf = index == components.count - 1
            if isLeaf {
                guard expectsDirectory
                    ? values.isDirectory == true
                    : values.isRegularFile == true else {
                    throw KnitNoteBackupError.unsafePackageEntry
                }
            } else {
                guard values.isDirectory == true else {
                    throw KnitNoteBackupError.unsafePackageEntry
                }
            }
        }

        let rootPath = liveRoot.standardizedFileURL.path
        let sourcePath = candidate.standardizedFileURL.path
        guard sourcePath.hasPrefix(rootPath + "/") else {
            throw KnitNoteBackupError.unsafePackageEntry
        }
    }

    private func entryValues(_ url: URL) throws -> KnitNoteBackupResourceMetadata {
        do {
            return try loadResourceMetadata(url)
        } catch {
            throw KnitNoteBackupError.unsafePackageEntry
        }
    }

    private func contents(of directory: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ],
                options: []
            )
        } catch {
            throw KnitNoteBackupError.unsafePackageEntry
        }
    }

    private func relativePath(of url: URL, below root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let itemPath = url.standardizedFileURL.path
        guard itemPath.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(itemPath.dropFirst(rootPath.count + 1))
    }

    private static func defaultResourceMetadata(
        _ url: URL
    ) throws -> KnitNoteBackupResourceMetadata {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .volumeIdentifierKey,
        ])
        return (
            isRegularFile: values.isRegularFile,
            isDirectory: values.isDirectory,
            isSymbolicLink: values.isSymbolicLink,
            fileSize: values.fileSize.map(Int64.init),
            physicalVolumeIdentifier: values.volumeIdentifier.map(String.init(describing:))
        )
    }
}
