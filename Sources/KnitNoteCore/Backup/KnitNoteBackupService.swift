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

    init(root: URL, preview: KnitNoteBackupPreview) {
        self.root = root
        self.preview = preview
    }
}

public struct KnitNoteBackupInstallation: Sendable {
    public let liveRoot: URL
    public let rollbackRoot: URL
    let hadLiveRoot: Bool

    init(liveRoot: URL, rollbackRoot: URL, hadLiveRoot: Bool) {
        self.liveRoot = liveRoot
        self.rollbackRoot = rollbackRoot
        self.hadLiveRoot = hadLiveRoot
    }
}

enum KnitNoteBackupReplacementStep: Sendable {
    case beforeLiveMove
    case afterLiveMove
    case afterStagedMove
    case beforeRollback
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
        let archiveURL = liveRoot.appendingPathComponent("projects-v1.json")
        let archiveData: Data
        let archive: ProjectArchive
        do {
            archiveData = try Data(contentsOf: archiveURL)
            archive = try JSONDecoder().decode(ProjectArchive.self, from: archiveData)
        } catch {
            throw KnitNoteBackupError.invalidArchive
        }
        try validateArchive(archive)
        let mediaPaths = referencedMediaPaths(in: archive).sorted()
        for relativePath in mediaPaths {
            try validateLiveSource(relativePath: relativePath, expectsDirectory: false)
        }

        let packageRoot = workRoot
            .appendingPathComponent("\(UUID().uuidString).knitnote-backup", isDirectory: true)
        let dataRoot = packageRoot.appendingPathComponent("Data", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
            try archiveData.write(
                to: dataRoot.appendingPathComponent("projects-v1.json"),
                options: .atomic
            )
            for relativePath in try referencedRelativePaths(in: archive, sourceRoot: liveRoot) {
                try validateLiveSource(relativePath: relativePath, expectsDirectory: false)
                let source = liveRoot.appendingPathComponent(relativePath)
                let destination = dataRoot.appendingPathComponent(relativePath)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: source, to: destination)
            }

            let manifest = KnitNoteBackupManifest(
                createdAt: now,
                appVersion: appVersion,
                projectCount: archive.projects.count,
                yarnCount: archive.yarns.count
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
              manifest.yarnCount == archive.yarns.count else {
            throw KnitNoteBackupError.countMismatch
        }
        try validateDataTree(dataRoot, archive: archive)
        return preview
    }

    public func stagePackage(at packageRoot: URL) throws -> StagedKnitNoteBackup {
        let preview = try inspectPackage(at: packageRoot)
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
                  preview.yarnCount == archive.yarns.count else {
                throw KnitNoteBackupError.countMismatch
            }
            try validateDataTree(stagedData, archive: archive)
            try verifyStagedTreeIsWritable(stagedData)
            return StagedKnitNoteBackup(root: stagedRoot, preview: preview)
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
        let rollbackRoot = workRoot.appendingPathComponent(
            "Rollback-\(UUID().uuidString)",
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
            try replacementStepHook(.beforeLiveMove)
            if hadLiveRoot {
                try fileManager.moveItem(at: liveRoot, to: rollbackRoot)
                movedLive = true
            }
            try replacementStepHook(.afterLiveMove)
            try fileManager.moveItem(at: stagedData, to: liveRoot)
            movedStaged = true
            try replacementStepHook(.afterStagedMove)
            try? fileManager.removeItem(at: staged.root)
            return KnitNoteBackupInstallation(
                liveRoot: liveRoot,
                rollbackRoot: rollbackRoot,
                hadLiveRoot: hadLiveRoot
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
            } catch {
                throw KnitNoteBackupError.rollbackFailed
            }
            throw KnitNoteBackupError.installFailedOriginalPreserved
        }
    }

    public func commit(_ installation: KnitNoteBackupInstallation) {
        do {
            try replacementStepHook(.beforeCommitCleanup)
            if FileManager.default.fileExists(atPath: installation.rollbackRoot.path) {
                let cleanupRoot = workRoot.appendingPathComponent(
                    "Cleanup-\(UUID().uuidString)",
                    isDirectory: true
                )
                try FileManager.default.moveItem(
                    at: installation.rollbackRoot,
                    to: cleanupRoot
                )
                try? cleanupItem(cleanupRoot)
            }
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
            try replacementStepHook(.beforeRollback)
            if fileManager.fileExists(atPath: installation.liveRoot.path) {
                try fileManager.removeItem(at: installation.liveRoot)
            }
            if installation.hadLiveRoot {
                try fileManager.moveItem(
                    at: installation.rollbackRoot,
                    to: installation.liveRoot
                )
            }
        } catch {
            throw KnitNoteBackupError.rollbackFailed
        }
    }

    public func recoverInterruptedReplacement() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: workRoot.path) {
            try validateWorkRootAncestry()
        }

        if fileManager.fileExists(atPath: liveRoot.path) {
            do {
                try validateLiveRoot(liveRoot)
                cleanupGeneratedArtifactsAfterValidChoice()
                return
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
            return
        }
        guard validRollbackRoots.count == 1 else {
            throw KnitNoteBackupError.rollbackFailed
        }
        do {
            try fileManager.moveItem(at: validRollbackRoots[0], to: liveRoot)
            cleanupGeneratedArtifactsAfterValidChoice()
        } catch {
            throw KnitNoteBackupError.rollbackFailed
        }
    }

    private func validateStagedBackup(_ staged: StagedKnitNoteBackup) throws {
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
              staged.preview.yarnCount == archive.yarns.count else {
            throw KnitNoteBackupError.countMismatch
        }
        try validateDataTree(dataRoot, archive: archive)
        try verifyStagedTreeIsWritable(dataRoot)
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
        var paths = referencedMediaPaths(in: archive)
        for project in archive.projects {
            for pattern in project.patterns {
                let markupRootPath = "Patterns/\(project.id.uuidString)/Markup"
                let markupOwnerPath = "\(markupRootPath)/\(pattern.id.uuidString)"
                let markupRoot = sourceRoot.appendingPathComponent(markupRootPath)
                if FileManager.default.fileExists(atPath: markupRoot.path) {
                    try validateLiveSource(
                        relativePath: markupRootPath,
                        expectsDirectory: true
                    )
                }
                let markupDirectory = sourceRoot
                    .appendingPathComponent(markupOwnerPath)
                if FileManager.default.fileExists(atPath: markupDirectory.path) {
                    try validateLiveSource(
                        relativePath: markupOwnerPath,
                        expectsDirectory: true
                    )
                    let markupFiles = try FileManager.default.contentsOfDirectory(
                        at: markupDirectory,
                        includingPropertiesForKeys: nil
                    )
                    for file in markupFiles {
                        let values = try entryValues(file)
                        guard values.isRegularFile == true,
                              isMarkupFilename(file.lastPathComponent) else {
                            throw KnitNoteBackupError.unknownPackageEntry
                        }
                        paths.insert(
                            "Patterns/\(project.id.uuidString)/Markup/\(pattern.id.uuidString)/\(file.lastPathComponent)"
                        )
                    }
                }
            }
        }
        return paths.sorted()
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
              Set(archive.yarns.map(\.id)).count == archive.yarns.count else {
            throw KnitNoteBackupError.duplicateIdentifier
        }
        let projectIDs = Set(archive.projects.map(\.id))
        guard archive.yarns.allSatisfy({ $0.linkedProjectIDs.isSubset(of: projectIDs) }) else {
            throw KnitNoteBackupError.invalidYarnProjectLinks
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
        guard components.count == 5,
              components[0] == "Patterns",
              components[2] == "Markup" else {
            return nil
        }
        return components.prefix(4).joined(separator: "/")
    }

    private func isMarkupFilename(_ filename: String) -> Bool {
        guard isSafeFileComponent(filename), filename.hasSuffix(".json") else { return false }
        let page = filename.dropLast(5)
        return Int(page).map { $0 >= 0 && String($0) == page } == true
    }

    private func isStructuredMarkupPath(_ relativePath: String) -> Bool {
        var components = relativePath.split(separator: "/").map(String.init)
        if components.first == "Data" { components.removeFirst() }
        guard components.count == 5,
              components[0] == "Patterns",
              components[2] == "Markup" else {
            return false
        }
        return isMarkupFilename(components[4])
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
