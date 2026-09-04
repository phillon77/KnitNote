import CloudKit
import CryptoKit
import Darwin
import Foundation

@_silgen_name("flock")
private func cloudAssetFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

enum CloudAssetStagingError: Error, Equatable {
    case invalidAccount
    case invalidMetadata
    case contentMismatch
    case tooLarge
    case unsafeFile
    case unavailable
    case corruptManifest
    case unknownUpload
    case immutableIdentityMismatch
}

enum CloudAssetStagingBoundary: Sendable {
    case uploadBeforeFileSync
    case uploadBeforeRename
    case uploadBeforeDirectorySync
    case manifestBeforeFileSync
    case manifestBeforeRename
    case manifestAfterLoad(destination: URL)
    case manifestAfterIdentityCheck(destination: URL)
    case manifestAfterSwap(destination: URL, displaced: URL)
    case manifestAfterFinalIdentityCheck(destination: URL, displaced: URL)
    case manifestBeforeDirectorySync
    case downloadBeforeFileSync
    case downloadBeforeRename(destination: URL)
    case downloadBeforeDirectorySync
    case quarantineBeforeFileSync
    case quarantineBeforeRename
    case quarantineBeforeDirectorySync
    case quarantineMismatchBeforeRead(source: URL)
    case cleanupAfterIdentityCheck(candidate: URL)
    case cleanupAfterMove
    case cleanupBeforeUnlink(candidate: URL)
    case cleanupAfterFinalIdentityCheck(candidate: URL)
    case coordinationAfterLock(lock: URL)
    case coordinationBeforeReturn(account: URL)
    case acknowledgementAfterManifest

    func sameKind(as other: CloudAssetStagingBoundary?) -> Bool {
        guard let other else { return false }
        return switch (self, other) {
        case (.uploadBeforeFileSync, .uploadBeforeFileSync),
            (.uploadBeforeRename, .uploadBeforeRename),
            (.uploadBeforeDirectorySync, .uploadBeforeDirectorySync),
            (.manifestBeforeFileSync, .manifestBeforeFileSync),
            (.manifestBeforeRename, .manifestBeforeRename),
            (.manifestAfterLoad, .manifestAfterLoad),
            (.manifestAfterIdentityCheck, .manifestAfterIdentityCheck),
            (.manifestAfterSwap, .manifestAfterSwap),
            (.manifestAfterFinalIdentityCheck, .manifestAfterFinalIdentityCheck),
            (.manifestBeforeDirectorySync, .manifestBeforeDirectorySync),
            (.downloadBeforeFileSync, .downloadBeforeFileSync),
            (.downloadBeforeRename, .downloadBeforeRename),
            (.downloadBeforeDirectorySync, .downloadBeforeDirectorySync),
            (.quarantineBeforeFileSync, .quarantineBeforeFileSync),
            (.quarantineBeforeRename, .quarantineBeforeRename),
            (.quarantineBeforeDirectorySync, .quarantineBeforeDirectorySync),
            (.quarantineMismatchBeforeRead, .quarantineMismatchBeforeRead),
            (.cleanupAfterIdentityCheck, .cleanupAfterIdentityCheck),
            (.cleanupAfterMove, .cleanupAfterMove),
            (.cleanupBeforeUnlink, .cleanupBeforeUnlink),
            (.cleanupAfterFinalIdentityCheck, .cleanupAfterFinalIdentityCheck),
            (.coordinationAfterLock, .coordinationAfterLock),
            (.coordinationBeforeReturn, .coordinationBeforeReturn),
            (.acknowledgementAfterManifest, .acknowledgementAfterManifest):
            true
        default:
            false
        }
    }
}

struct CloudAssetUploadReference: Codable, Equatable, Sendable {
    let version: SyncAttachmentVersion
    let mutationID: UUID
    let stagedFileURL: URL
}

/// Owns immutable CloudKit asset bytes after the mutation journal has staged
/// its source. This service never removes that source; it only retires its own
/// account-scoped copy after an exact server acknowledgement.
final class CloudAssetStagingService: @unchecked Sendable {
    typealias BeforeBoundary = @Sendable (CloudAssetStagingBoundary) throws -> Void

    static let defaultMaximumAssetBytes = SyncPublicationFileLimits.maximumAttachmentBytes
    private static let manifestVersion = 1
    private static let manifestIntegrityVersion = 1
    private static let manifestIntegrityDomain = "knitnote.cloud-asset.upload-references"
    private static let maximumManifestBytes = 16 * 1_024 * 1_024
    private static let manifestName = "upload-references.json"
    private static let lockName = ".asset-staging.lock"
    private static let processLock = NSLock()

    let accountRootURL: URL
    let uploadsRootURL: URL
    let installedRootURL: URL
    let quarantineRootURL: URL

    private let rootURL: URL
    private let accountToken: String
    private let maximumAssetBytes: Int
    private let externalReader: any SyncRegularFileReading
    private let beforeBoundary: BeforeBoundary

    init(
        rootURL: URL,
        accountIdentifier: String,
        maximumAssetBytes: Int = CloudAssetStagingService.defaultMaximumAssetBytes,
        externalReader: any SyncRegularFileReading = SyncRegularFileReader(),
        beforeBoundary: @escaping BeforeBoundary = { _ in }
    ) throws {
        guard rootURL.isFileURL,
            !accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CloudAssetStagingError.invalidAccount
        }
        guard maximumAssetBytes >= 0 else { throw CloudAssetStagingError.tooLarge }
        self.rootURL = rootURL.standardizedFileURL
        self.maximumAssetBytes = maximumAssetBytes
        self.externalReader = externalReader
        self.beforeBoundary = beforeBoundary
        accountToken = Self.hex(Data(SHA256.hash(data: Data(accountIdentifier.utf8))))
        accountRootURL = self.rootURL
            .appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent(accountToken, isDirectory: true)
        uploadsRootURL = accountRootURL.appendingPathComponent("Uploads", isDirectory: true)
        installedRootURL = accountRootURL.appendingPathComponent("Installed", isDirectory: true)
        quarantineRootURL = accountRootURL.appendingPathComponent("Quarantine", isDirectory: true)
        try withDirectories { _ in }
    }

    func stageUpload(
        source: SyncAttachmentSource,
        version: SyncAttachmentVersion,
        mutationID: UUID
    ) throws -> CloudAssetUploadReference {
        let version = try validated(version)
        try validate(source: source, against: version)
        let sourceRead = try readExternal(
            source.fileURL,
            expectedByteCount: version.byteCount,
            expectedSHA256: version.contentSHA256
        )
        let fileName = try immutableFileName(for: version)
        let result = CloudAssetUploadReference(
            version: version,
            mutationID: mutationID,
            stagedFileURL: uploadsRootURL.appendingPathComponent(fileName)
        )

        return try coordinated { directories in
            let loadedManifest = try loadManifest(directories: directories)
            var manifest = loadedManifest.payload
            if let existing = manifest.references.first(where: { $0.mutationID == mutationID }) {
                guard referencesMatch(existing, result) else {
                    throw CloudAssetStagingError.immutableIdentityMismatch
                }
                try verifyFile(
                    named: fileName,
                    in: directories.uploads,
                    expectedByteCount: version.byteCount,
                    expectedSHA256: version.contentSHA256
                )
                return existing
            }
            if let intentIndex = manifest.cleanupIntents.firstIndex(where: {
                $0.mutationID == mutationID
            }) {
                guard referencesMatch(manifest.cleanupIntents[intentIndex], result) else {
                    throw CloudAssetStagingError.immutableIdentityMismatch
                }
                try restoreOrCreateStagedFile(
                    sourceRead.data,
                    named: fileName,
                    version: version,
                    directories: directories
                )
                manifest.cleanupIntents.remove(at: intentIndex)
                manifest.references.append(result)
                _ = try writeManifest(
                    manifest,
                    replacing: loadedManifest.authority,
                    accountDescriptor: directories.account,
                    retiredDescriptor: directories.retired
                )
                return result
            }
            guard
                (manifest.references + manifest.cleanupIntents).allSatisfy({ reference in
                    reference.version.versionID != version.versionID || reference.version == version
                })
            else {
                throw CloudAssetStagingError.immutableIdentityMismatch
            }
            try rejectDifferentSnapshot(
                versionID: version.versionID,
                expectedFileName: fileName,
                directoryDescriptor: directories.uploads
            )
            try createImmutableFile(
                sourceRead.data,
                named: fileName,
                directoryDescriptor: directories.uploads,
                retiredDescriptor: directories.retired,
                fileSyncBoundary: .uploadBeforeFileSync,
                renameBoundary: .uploadBeforeRename,
                directorySyncBoundary: .uploadBeforeDirectorySync,
                expectedByteCount: version.byteCount,
                expectedSHA256: version.contentSHA256
            )
            manifest.references.append(result)
            _ = try writeManifest(
                manifest,
                replacing: loadedManifest.authority,
                accountDescriptor: directories.account,
                retiredDescriptor: directories.retired
            )
            return result
        }
    }

    /// CKAsset is intentionally constructed at the last possible moment. A
    /// caller must request a new object for every CKRecord save attempt.
    func asset(for reference: CloudAssetUploadReference) throws -> CKAsset {
        let version = try validated(reference.version)
        let expectedURL = uploadsRootURL.appendingPathComponent(
            try immutableFileName(for: version)
        )
        guard reference.stagedFileURL.standardizedFileURL == expectedURL.standardizedFileURL else {
            throw CloudAssetStagingError.unknownUpload
        }
        try coordinated { directories in
            let manifest = try loadManifest(directories: directories).payload
            guard manifest.references.contains(where: { referencesMatch($0, reference) }) else {
                throw CloudAssetStagingError.unknownUpload
            }
            try verifyFile(
                named: expectedURL.lastPathComponent,
                in: directories.uploads,
                expectedByteCount: version.byteCount,
                expectedSHA256: version.contentSHA256
            )
        }
        return CKAsset(fileURL: expectedURL)
    }

    func acknowledgeUpload(_ reference: CloudAssetUploadReference) throws {
        let version = try validated(reference.version)
        let fileName = try immutableFileName(for: version)
        let expectedURL = uploadsRootURL.appendingPathComponent(fileName)
        guard reference.stagedFileURL.standardizedFileURL == expectedURL.standardizedFileURL else {
            throw CloudAssetStagingError.unknownUpload
        }
        try coordinated { directories in
            var loadedManifest = try loadManifest(directories: directories)
            var manifest = loadedManifest.payload
            guard
                let index = manifest.references.firstIndex(where: {
                    referencesMatch($0, reference)
                })
            else {
                throw CloudAssetStagingError.unknownUpload
            }
            manifest.references.remove(at: index)
            manifest.cleanupIntents.append(reference)
            loadedManifest = try writeManifest(
                manifest,
                replacing: loadedManifest.authority,
                accountDescriptor: directories.account,
                retiredDescriptor: directories.retired
            )
            try beforeBoundary(.acknowledgementAfterManifest)
            guard
                !manifest.references.contains(where: {
                    $0.stagedFileURL.lastPathComponent == fileName
                })
            else {
                manifest.cleanupIntents.removeAll { referencesMatch($0, reference) }
                _ = try writeManifest(
                    manifest,
                    replacing: loadedManifest.authority,
                    accountDescriptor: directories.account,
                    retiredDescriptor: directories.retired
                )
                return
            }
            try removeRegularFile(
                named: fileName,
                from: directories.uploads,
                retiredDescriptor: directories.retired,
                candidateURL: uploadsRootURL.appendingPathComponent(fileName),
                expectedByteCount: version.byteCount,
                expectedSHA256: version.contentSHA256
            )
            manifest.cleanupIntents.removeAll { referencesMatch($0, reference) }
            _ = try writeManifest(
                manifest,
                replacing: loadedManifest.authority,
                accountDescriptor: directories.account,
                retiredDescriptor: directories.retired
            )
        }
    }

    @discardableResult
    func installDownload(
        from sourceURL: URL,
        version: SyncAttachmentVersion
    ) throws -> URL {
        let version = try validated(version)
        let read: SyncRegularFileRead
        do {
            read = try readExternal(
                sourceURL,
                expectedByteCount: version.byteCount,
                expectedSHA256: version.contentSHA256
            )
        } catch CloudAssetStagingError.contentMismatch {
            try quarantineMismatch(
                sourceURL,
                expectedByteCount: version.byteCount
            )
            throw CloudAssetStagingError.contentMismatch
        }
        let fileName = try immutableFileName(for: version)
        let destination = installedRootURL.appendingPathComponent(fileName)
        return try coordinated { directories in
            try rejectDifferentSnapshot(
                versionID: version.versionID,
                expectedFileName: fileName,
                directoryDescriptor: directories.installed
            )
            try createImmutableFile(
                read.data,
                named: fileName,
                directoryDescriptor: directories.installed,
                retiredDescriptor: directories.retired,
                fileSyncBoundary: .downloadBeforeFileSync,
                renameBoundary: .downloadBeforeRename(destination: destination),
                directorySyncBoundary: .downloadBeforeDirectorySync,
                expectedByteCount: version.byteCount,
                expectedSHA256: version.contentSHA256
            )
            return destination
        }
    }

    /// Copies diagnostic bytes into an owned account-scoped location. The
    /// source is deliberately retained because it may belong to CloudKit or a
    /// journal authority outside this service.
    @discardableResult
    func quarantine(_ sourceURL: URL) throws -> URL {
        try quarantine(readExternal(sourceURL).data)
    }

    /// Removes only unreferenced upload bytes and interrupted temporary files.
    /// Missing or corrupt referenced bytes fail closed instead of silently
    /// discarding durable upload intent.
    func reconcile() throws {
        try coordinated { directories in
            let loadedManifest = try loadManifest(directories: directories)
            var manifest = loadedManifest.payload
            try recoverRetiredFiles(manifest: manifest, directories: directories)
            let referenced = Set(manifest.references.map { $0.stagedFileURL.lastPathComponent })
            for reference in manifest.references {
                try verifyFile(
                    named: reference.stagedFileURL.lastPathComponent,
                    in: directories.uploads,
                    expectedByteCount: reference.version.byteCount,
                    expectedSHA256: reference.version.contentSHA256
                )
            }
            for intent in manifest.cleanupIntents {
                let name = intent.stagedFileURL.lastPathComponent
                guard !referenced.contains(name) else { continue }
                let cleanupResidues = try directoryEntryNames(directories.uploads).filter {
                    $0.hasPrefix(".\(name).") && $0.hasSuffix(".cleanup")
                }
                guard cleanupResidues.count <= 1,
                    cleanupResidues.allSatisfy({ isCleanupTombstone($0, for: name) })
                else {
                    throw CloudAssetStagingError.corruptManifest
                }
                if let cleanupResidue = cleanupResidues.first {
                    try removeRegularFile(
                        named: cleanupResidue,
                        from: directories.uploads,
                        retiredDescriptor: directories.retired,
                        retirementLogicalName: name,
                        expectedByteCount: intent.version.byteCount,
                        expectedSHA256: intent.version.contentSHA256
                    )
                }
                try removeRegularFile(
                    named: name,
                    from: directories.uploads,
                    retiredDescriptor: directories.retired,
                    candidateURL: uploadsRootURL.appendingPathComponent(name),
                    expectedByteCount: intent.version.byteCount,
                    expectedSHA256: intent.version.contentSHA256
                )
            }
            if !manifest.cleanupIntents.isEmpty {
                manifest.cleanupIntents.removeAll()
                _ = try writeManifest(
                    manifest,
                    replacing: loadedManifest.authority,
                    accountDescriptor: directories.account,
                    retiredDescriptor: directories.retired
                )
            }
            var removedUpload = false
            for name in try directoryEntryNames(directories.uploads)
            where name != "." && name != ".." {
                if name.hasSuffix(".tmp") {
                    guard isGeneratedTemporaryName(name, domain: .immutableAsset) else {
                        throw CloudAssetStagingError.unsafeFile
                    }
                    try removeRegularFile(
                        named: name,
                        from: directories.uploads,
                        retiredDescriptor: directories.retired
                    )
                    removedUpload = true
                } else if name.hasSuffix(".asset") && !referenced.contains(name) {
                    throw CloudAssetStagingError.corruptManifest
                } else if !referenced.contains(name) {
                    throw CloudAssetStagingError.unsafeFile
                }
            }
            if removedUpload, Darwin.fsync(directories.uploads) != 0 {
                throw CloudAssetStagingError.unavailable
            }
            var removedInstall = false
            for name in try directoryEntryNames(directories.installed)
            where name.hasSuffix(".tmp") {
                guard isGeneratedTemporaryName(name, domain: .immutableAsset) else {
                    throw CloudAssetStagingError.unsafeFile
                }
                try removeRegularFile(
                    named: name,
                    from: directories.installed,
                    retiredDescriptor: directories.retired
                )
                removedInstall = true
            }
            if removedInstall, Darwin.fsync(directories.installed) != 0 {
                throw CloudAssetStagingError.unavailable
            }
            var removedManifestTemporary = false
            for name in try directoryEntryNames(directories.account)
            where name.hasSuffix(".tmp") {
                guard isGeneratedTemporaryName(name, domain: .manifest) else {
                    throw CloudAssetStagingError.unsafeFile
                }
                try removeRegularFile(
                    named: name,
                    from: directories.account,
                    retiredDescriptor: directories.retired
                )
                removedManifestTemporary = true
            }
            if removedManifestTemporary, Darwin.fsync(directories.account) != 0 {
                throw CloudAssetStagingError.unavailable
            }
            var removedQuarantineTemporary = false
            for name in try directoryEntryNames(directories.quarantine)
            where name.hasSuffix(".tmp") {
                guard isGeneratedTemporaryName(name, domain: .quarantineAsset) else {
                    throw CloudAssetStagingError.unsafeFile
                }
                try removeRegularFile(
                    named: name,
                    from: directories.quarantine,
                    retiredDescriptor: directories.retired
                )
                removedQuarantineTemporary = true
            }
            if removedQuarantineTemporary, Darwin.fsync(directories.quarantine) != 0 {
                throw CloudAssetStagingError.unavailable
            }
            let emptySHA256 = Data(SHA256.hash(data: Data()))
            for name in try directoryEntryNames(directories.retired)
            where name != "." && name != ".." {
                guard isRetirementTombstone(name) else {
                    throw CloudAssetStagingError.unsafeFile
                }
                try verifyFile(
                    named: name,
                    in: directories.retired,
                    expectedByteCount: 0,
                    expectedSHA256: emptySHA256
                )
            }
        }
    }

    private func quarantine(_ data: Data) throws -> URL {
        try coordinated { directories in
            while true {
                let name = "\(UUID().uuidString.lowercased()).asset"
                let destination = quarantineRootURL.appendingPathComponent(name)
                do {
                    try createNewFile(
                        data,
                        named: name,
                        directoryDescriptor: directories.quarantine,
                        retiredDescriptor: directories.retired,
                        fileSyncBoundary: .quarantineBeforeFileSync,
                        renameBoundary: .quarantineBeforeRename,
                        directorySyncBoundary: .quarantineBeforeDirectorySync
                    )
                    return destination
                } catch CloudAssetStagingError.immutableIdentityMismatch {
                    continue
                }
            }
        }
    }

    private func quarantineMismatch(
        _ sourceURL: URL,
        expectedByteCount: Int64
    ) throws {
        var status = stat()
        guard sourceURL.path.withCString({ Darwin.lstat($0, &status) }) == 0,
            (status.st_mode & S_IFMT) == S_IFREG,
            status.st_size >= 0
        else {
            throw CloudAssetStagingError.unsafeFile
        }
        if status.st_size <= expectedByteCount {
            try beforeBoundary(.quarantineMismatchBeforeRead(source: sourceURL))
            let declaredBound: Int
            if expectedByteCount >= Int64(maximumAssetBytes) {
                declaredBound = maximumAssetBytes
            } else {
                declaredBound = Int(expectedByteCount) + 1
            }
            do {
                let read = try readExternal(
                    sourceURL,
                    maximumBytes: declaredBound,
                    expectedByteCount: expectedByteCount
                )
                _ = try quarantine(read.data)
            } catch CloudAssetStagingError.contentMismatch,
                CloudAssetStagingError.tooLarge
            {
                _ = try quarantine(Data())
            }
        } else {
            // The descriptor reader already rejected this size before allocating
            // or reading. Retain a bounded marker without rereading attacker-sized
            // input; the source remains owned by CloudKit/the caller.
            _ = try quarantine(Data())
        }
    }

    private func coordinated<T>(_ body: (OpenDirectories) throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        return try withDirectories { directories in
            try Self.setDirectoryLock(directories.account, operation: LOCK_EX)
            defer { try? Self.setDirectoryLock(directories.account, operation: LOCK_UN) }
            let lockDescriptor = try Self.openOrCreateLock(in: directories.account)
            defer { Darwin.close(lockDescriptor) }
            try Self.setLock(lockDescriptor, type: Int16(F_WRLCK))
            defer { try? Self.setLock(lockDescriptor, type: Int16(F_UNLCK)) }
            try Self.validateLock(lockDescriptor, in: directories.account)
            try beforeBoundary(.coordinationAfterLock(
                lock: accountRootURL.appendingPathComponent(Self.lockName)
            ))
            try Self.validateLock(lockDescriptor, in: directories.account)
            try validateDirectoryTree(directories)
            let result = try body(directories)
            try beforeBoundary(.coordinationBeforeReturn(account: accountRootURL))
            try validateDirectoryTree(directories)
            try Self.validateLock(lockDescriptor, in: directories.account)
            return result
        }
    }

    private func validated(_ version: SyncAttachmentVersion) throws -> SyncAttachmentVersion {
        do {
            let value = try version.validated()
            guard value.byteCount <= Int64(maximumAssetBytes),
                value.byteCount <= Int64(Int.max)
            else {
                throw CloudAssetStagingError.tooLarge
            }
            return value
        } catch let error as CloudAssetStagingError {
            throw error
        } catch {
            throw CloudAssetStagingError.invalidMetadata
        }
    }

    private func validate(
        source: SyncAttachmentSource,
        against version: SyncAttachmentVersion
    ) throws {
        guard source.fileURL.isFileURL,
            source.contentSHA256.count == SHA256.byteCount,
            source.byteCount >= 0
        else {
            throw CloudAssetStagingError.invalidMetadata
        }
        guard source.contentSHA256 == version.contentSHA256,
            source.byteCount == version.byteCount
        else {
            throw CloudAssetStagingError.contentMismatch
        }
    }

    private func immutableFileName(for version: SyncAttachmentVersion) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let snapshot = try encoder.encode(version)
        let digest = Self.hex(Data(SHA256.hash(data: snapshot)))
        return "\(version.versionID.uuidString.lowercased())-\(digest).asset"
    }

    private func referencesMatch(
        _ lhs: CloudAssetUploadReference,
        _ rhs: CloudAssetUploadReference
    ) -> Bool {
        lhs.version == rhs.version
            && lhs.mutationID == rhs.mutationID
            && lhs.stagedFileURL.standardizedFileURL == rhs.stagedFileURL.standardizedFileURL
    }

    private func readExternal(
        _ url: URL,
        maximumBytes: Int? = nil,
        expectedByteCount: Int64? = nil,
        expectedSHA256: Data? = nil
    ) throws -> SyncRegularFileRead {
        do {
            return try externalReader.read(
                url,
                maximumBytes: maximumBytes ?? maximumAssetBytes,
                expected: .init(byteCount: expectedByteCount, sha256: expectedSHA256)
            )
        } catch let error as SyncRegularFileReadError {
            throw Self.map(error)
        } catch {
            throw CloudAssetStagingError.unavailable
        }
    }

    private struct Manifest: Codable, Equatable {
        let version: Int
        var references: [CloudAssetUploadReference]
        var cleanupIntents: [CloudAssetUploadReference]
    }

    private struct StoredManifest: Codable {
        let integrityVersion: Int
        let payload: Manifest
        let checksum: Data
    }

    private struct ManifestChecksumMaterial: Encodable {
        let integrityVersion: Int
        let domain: String
        let payload: Manifest
    }

    private enum ManifestAuthority {
        case missing
        case present(
            identity: FileIdentity,
            byteCount: Int64,
            sha256: Data,
            canonicalData: Data
        )

        var identity: FileIdentity? {
            switch self {
            case .missing:
                nil
            case .present(let identity, _, _, _):
                identity
            }
        }
    }

    private struct LoadedManifest {
        var payload: Manifest
        var authority: ManifestAuthority
    }

    private func loadManifest(directories: OpenDirectories) throws -> LoadedManifest {
        let descriptor = Self.manifestName.withCString {
            Darwin.openat(
                directories.account,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        if descriptor < 0 {
            if errno == ENOENT {
                let entries = try directoryEntryNames(directories.uploads)
                guard !entries.contains(where: { $0.hasSuffix(".asset") }) else {
                    throw CloudAssetStagingError.corruptManifest
                }
                let result = LoadedManifest(
                    payload: Manifest(
                        version: Self.manifestVersion,
                        references: [],
                        cleanupIntents: []
                    ),
                    authority: .missing
                )
                try beforeBoundary(.manifestAfterLoad(
                    destination: accountRootURL.appendingPathComponent(Self.manifestName)
                ))
                return result
            }
            if errno == ELOOP { throw CloudAssetStagingError.unsafeFile }
            throw CloudAssetStagingError.unavailable
        }
        defer { Darwin.close(descriptor) }
        let identity = try Self.fileIdentity(of: descriptor)
        let read = try readDescriptor(descriptor, maximumBytes: Self.maximumManifestBytes)
        let manifest = try decodeManifest(read.data)
        let result = LoadedManifest(
            payload: manifest,
            authority: .present(
                identity: identity,
                byteCount: read.byteCount,
                sha256: read.sha256,
                canonicalData: read.data
            )
        )
        try beforeBoundary(.manifestAfterLoad(
            destination: accountRootURL.appendingPathComponent(Self.manifestName)
        ))
        return result
    }

    private func decodeManifest(_ data: Data) throws -> Manifest {
        let stored: StoredManifest
        do {
            stored = try JSONDecoder().decode(StoredManifest.self, from: data)
        } catch {
            throw CloudAssetStagingError.corruptManifest
        }
        let manifest = stored.payload
        let canonicalStored = try encodeCanonical(stored)
        guard stored.integrityVersion == Self.manifestIntegrityVersion,
            stored.checksum.count == SHA256.byteCount,
            stored.checksum == (try manifestChecksum(
                manifest,
                integrityVersion: stored.integrityVersion
            )),
            canonicalStored == data
        else {
            throw CloudAssetStagingError.corruptManifest
        }
        try validateManifest(manifest)
        return manifest
    }

    private func validateManifest(_ manifest: Manifest) throws {
        guard manifest.version == Self.manifestVersion,
            manifest.references == sorted(manifest.references),
            manifest.cleanupIntents == sorted(manifest.cleanupIntents)
        else {
            throw CloudAssetStagingError.corruptManifest
        }
        var identities: Set<String> = []
        var mutationIDs: Set<UUID> = []
        var versions: [UUID: SyncAttachmentVersion] = [:]
        for reference in manifest.references + manifest.cleanupIntents {
            let version = try validated(reference.version)
            let expectedName = try immutableFileName(for: version)
            guard
                reference.stagedFileURL.standardizedFileURL
                    == uploadsRootURL.appendingPathComponent(expectedName).standardizedFileURL,
                mutationIDs.insert(reference.mutationID).inserted,
                identities.insert(
                    "\(reference.mutationID.uuidString)-\(version.versionID.uuidString)"
                )
                .inserted
            else {
                throw CloudAssetStagingError.corruptManifest
            }
            if let prior = versions[version.versionID], prior != version {
                throw CloudAssetStagingError.immutableIdentityMismatch
            }
            versions[version.versionID] = version
        }
        guard Set(manifest.references.map(\.mutationID)).isDisjoint(
            with: Set(manifest.cleanupIntents.map(\.mutationID))
        ) else {
            throw CloudAssetStagingError.corruptManifest
        }
    }

    private func writeManifest(
        _ manifest: Manifest,
        replacing expectedAuthority: ManifestAuthority,
        accountDescriptor: Int32,
        retiredDescriptor: Int32
    ) throws -> LoadedManifest {
        var normalized = manifest
        normalized.references = sorted(normalized.references)
        normalized.cleanupIntents = sorted(normalized.cleanupIntents)
        try validateManifest(normalized)
        let data: Data
        do {
            let checksum = try manifestChecksum(normalized)
            data = try encodeCanonical(StoredManifest(
                integrityVersion: Self.manifestIntegrityVersion,
                payload: normalized,
                checksum: checksum
            ))
        } catch {
            throw CloudAssetStagingError.corruptManifest
        }
        guard data.count <= Self.maximumManifestBytes else {
            throw CloudAssetStagingError.corruptManifest
        }
        try verifyManifestAuthority(expectedAuthority, in: accountDescriptor)
        let original = expectedAuthority.identity
        let temporaryName = ".\(Self.manifestName).\(UUID().uuidString).tmp"
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                accountDescriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else { throw CloudAssetStagingError.unavailable }
        let stagedIdentity = try Self.fileIdentity(of: descriptor)
        var removeTemporary = true
        defer {
            if removeTemporary {
                try? retireBoundFile(
                    named: temporaryName,
                    logicalName: Self.manifestName,
                    from: accountDescriptor,
                    descriptor: descriptor,
                    expectedIdentity: stagedIdentity,
                    retiredDescriptor: retiredDescriptor
                )
            }
            Darwin.close(descriptor)
        }
        try Self.writeAll(data, descriptor: descriptor)
        try beforeBoundary(.manifestBeforeFileSync)
        guard Darwin.fsync(descriptor) == 0 else { throw CloudAssetStagingError.unavailable }
        try beforeBoundary(.manifestBeforeRename)
        try verifyManifestAuthority(expectedAuthority, in: accountDescriptor)
        try beforeBoundary(.manifestAfterIdentityCheck(
            destination: accountRootURL.appendingPathComponent(Self.manifestName)
        ))
        try verifyManifestAuthority(expectedAuthority, in: accountDescriptor)
        if let original {
            let result = temporaryName.withCString { temporary in
                Self.manifestName.withCString { destination in
                    Darwin.renameatx_np(
                        accountDescriptor,
                        temporary,
                        accountDescriptor,
                        destination,
                        UInt32(RENAME_SWAP)
                    )
                }
            }
            guard result == 0 else { throw CloudAssetStagingError.unavailable }
            var displacedDescriptor: Int32 = -1
            var capturedRetirementName: String?
            defer {
                if displacedDescriptor >= 0 { Darwin.close(displacedDescriptor) }
            }
            do {
                try beforeBoundary(.manifestAfterSwap(
                    destination: accountRootURL.appendingPathComponent(Self.manifestName),
                    displaced: accountRootURL.appendingPathComponent(temporaryName)
                ))
                guard
                    try destinationIdentity(
                        named: Self.manifestName,
                        in: accountDescriptor
                    ) == stagedIdentity,
                    try destinationIdentity(
                        named: temporaryName,
                        in: accountDescriptor
                    ) == original
                else {
                    throw CloudAssetStagingError.unsafeFile
                }
                displacedDescriptor = temporaryName.withCString {
                    Darwin.openat(
                        accountDescriptor,
                        $0,
                        O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard displacedDescriptor >= 0,
                    try Self.fileIdentity(of: displacedDescriptor) == original
                else {
                    throw CloudAssetStagingError.unsafeFile
                }
                try verifyManifestDescriptor(
                    displacedDescriptor,
                    against: expectedAuthority
                )
                try beforeBoundary(.manifestAfterFinalIdentityCheck(
                    destination: accountRootURL.appendingPathComponent(Self.manifestName),
                    displaced: accountRootURL.appendingPathComponent(temporaryName)
                ))
                let retirementName = try captureBoundFile(
                    named: temporaryName,
                    logicalName: Self.manifestName,
                    from: accountDescriptor,
                    descriptor: displacedDescriptor,
                    expectedIdentity: original,
                    retiredDescriptor: retiredDescriptor,
                    synchronize: false
                )
                capturedRetirementName = retirementName
                try beforeBoundary(.manifestBeforeDirectorySync)
                guard try destinationIdentity(
                    named: Self.manifestName,
                    in: accountDescriptor
                    ) == stagedIdentity,
                    try destinationIdentity(
                        named: retirementName,
                        in: retiredDescriptor
                    ) == original
                else {
                    throw CloudAssetStagingError.unsafeFile
                }
                guard Darwin.fsync(accountDescriptor) == 0,
                    Darwin.fsync(retiredDescriptor) == 0
                else {
                    throw CloudAssetStagingError.unavailable
                }
                removeTemporary = false
            } catch let operationError {
                try restoreManifestAuthority(
                    expectedAuthority,
                    accountDescriptor: accountDescriptor,
                    additionalNamesToPreserve: [temporaryName],
                    fallbackCanonicalData: nil
                )
                if let capturedRetirementName {
                    try finishRetiredFile(
                        named: capturedRetirementName,
                        descriptor: displacedDescriptor,
                        expectedIdentity: original,
                        retiredDescriptor: retiredDescriptor
                    )
                }
                removeTemporary = false
                throw operationError
            }
            if let capturedRetirementName {
                // Publication is committed. A crash or cleanup failure here is
                // resumed from the checksummed manifest during reconciliation.
                try? finishRetiredFile(
                    named: capturedRetirementName,
                    descriptor: displacedDescriptor,
                    expectedIdentity: original,
                    retiredDescriptor: retiredDescriptor
                )
            }
        } else {
            let result = temporaryName.withCString { temporary in
                Self.manifestName.withCString { destination in
                    Darwin.renameatx_np(
                        accountDescriptor,
                        temporary,
                        accountDescriptor,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            if result != 0 {
                guard errno == EEXIST else { throw CloudAssetStagingError.unavailable }
                throw CloudAssetStagingError.unsafeFile
            }
            // With no prior authority to restore, the published candidate is
            // recoverable crash state. A returning hook is followed by an
            // inode check so substitution can never report success.
            removeTemporary = false
            do {
                try beforeBoundary(.manifestBeforeDirectorySync)
                guard try destinationIdentity(
                    named: Self.manifestName,
                    in: accountDescriptor
                ) == stagedIdentity else {
                    throw CloudAssetStagingError.unsafeFile
                }
                guard Darwin.fsync(accountDescriptor) == 0 else {
                    throw CloudAssetStagingError.unavailable
                }
            } catch let operationError {
                try restoreManifestAuthority(
                    expectedAuthority,
                    accountDescriptor: accountDescriptor,
                    additionalNamesToPreserve: [temporaryName],
                    fallbackCanonicalData: data
                )
                throw operationError
            }
        }
        return LoadedManifest(
            payload: normalized,
            authority: .present(
                identity: stagedIdentity,
                byteCount: Int64(data.count),
                sha256: Data(SHA256.hash(data: data)),
                canonicalData: data
            )
        )
    }

    private func verifyManifestAuthority(
        _ authority: ManifestAuthority,
        in accountDescriptor: Int32
    ) throws {
        switch authority {
        case .missing:
            guard try destinationIdentity(
                named: Self.manifestName,
                in: accountDescriptor
            ) == nil else {
                throw CloudAssetStagingError.unsafeFile
            }
        case .present(let expectedIdentity, _, _, _):
            let descriptor = Self.manifestName.withCString {
                Darwin.openat(
                    accountDescriptor,
                    $0,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else { throw CloudAssetStagingError.unsafeFile }
            defer { Darwin.close(descriptor) }
            guard try Self.fileIdentity(of: descriptor) == expectedIdentity else {
                throw CloudAssetStagingError.unsafeFile
            }
            try verifyManifestDescriptor(descriptor, against: authority)
        }
    }

    private func verifyManifestDescriptor(
        _ descriptor: Int32,
        against authority: ManifestAuthority
    ) throws {
        guard case .present(_, let expectedByteCount, let expectedSHA256, _) = authority,
            expectedByteCount <= Int64(Self.maximumManifestBytes)
        else {
            throw CloudAssetStagingError.unsafeFile
        }
        let read = try readDescriptorPreservingOffset(
            descriptor,
            maximumBytes: Self.maximumManifestBytes
        )
        guard read.byteCount == expectedByteCount, read.sha256 == expectedSHA256 else {
            throw CloudAssetStagingError.unsafeFile
        }
    }

    /// Reinstalls the exact bytes that were loaded before publication. For the
    /// first manifest, the already-synchronized candidate is the recoverable
    /// authority. Any pathname occupant observed after a failed publication is
    /// moved aside rather than overwritten or truncated.
    private func restoreManifestAuthority(
        _ authority: ManifestAuthority,
        accountDescriptor: Int32,
        additionalNamesToPreserve: [String],
        fallbackCanonicalData: Data?
    ) throws {
        try preserveEntryIfPresent(
            named: Self.manifestName,
            in: accountDescriptor
        )
        for name in additionalNamesToPreserve {
            try preserveEntryIfPresent(named: name, in: accountDescriptor)
        }

        let canonicalData: Data?
        switch authority {
        case .missing:
            canonicalData = fallbackCanonicalData
        case .present(_, _, _, let loadedData):
            canonicalData = loadedData
        }
        if let canonicalData {
            let recoveryName = ".\(Self.manifestName).\(UUID().uuidString).tmp"
            let recoveryDescriptor = recoveryName.withCString {
                Darwin.openat(
                    accountDescriptor,
                    $0,
                    O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    S_IRUSR | S_IWUSR
                )
            }
            guard recoveryDescriptor >= 0 else { throw CloudAssetStagingError.unavailable }
            defer { Darwin.close(recoveryDescriptor) }
            try Self.writeAll(canonicalData, descriptor: recoveryDescriptor)
            guard Darwin.fsync(recoveryDescriptor) == 0 else {
                throw CloudAssetStagingError.unavailable
            }
            let publish = recoveryName.withCString { source in
                Self.manifestName.withCString { destination in
                    Darwin.renameatx_np(
                        accountDescriptor,
                        source,
                        accountDescriptor,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard publish == 0 else { throw CloudAssetStagingError.unavailable }
        }
        guard Darwin.fsync(accountDescriptor) == 0 else {
            throw CloudAssetStagingError.unavailable
        }
    }

    private func preserveEntryIfPresent(named name: String, in directory: Int32) throws {
        var status = stat()
        let exists = name.withCString {
            Darwin.fstatat(directory, $0, &status, AT_SYMLINK_NOFOLLOW)
        } == 0
        if !exists {
            guard errno == ENOENT else { throw CloudAssetStagingError.unavailable }
            return
        }
        let preservedName = ".\(Self.manifestName).\(UUID().uuidString.lowercased()).preserved"
        let result = name.withCString { source in
            preservedName.withCString { destination in
                Darwin.renameatx_np(
                    directory,
                    source,
                    directory,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else { throw CloudAssetStagingError.unavailable }
    }

    private func manifestChecksum(
        _ manifest: Manifest,
        integrityVersion: Int = CloudAssetStagingService.manifestIntegrityVersion
    ) throws -> Data {
        guard integrityVersion == Self.manifestIntegrityVersion else {
            throw CloudAssetStagingError.corruptManifest
        }
        return Data(SHA256.hash(data: try encodeCanonical(ManifestChecksumMaterial(
            integrityVersion: integrityVersion,
            domain: Self.manifestIntegrityDomain,
            payload: manifest
        ))))
    }

    private func encodeCanonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func sorted(
        _ references: [CloudAssetUploadReference]
    ) -> [CloudAssetUploadReference] {
        references.sorted {
            if $0.mutationID != $1.mutationID {
                return $0.mutationID.uuidString < $1.mutationID.uuidString
            }
            return $0.version.versionID.uuidString < $1.version.versionID.uuidString
        }
    }

    private func rejectDifferentSnapshot(
        versionID: UUID,
        expectedFileName: String,
        directoryDescriptor: Int32
    ) throws {
        let prefix = versionID.uuidString.lowercased() + "-"
        for name in try directoryEntryNames(directoryDescriptor)
        where name.hasPrefix(prefix) && name.hasSuffix(".asset") && name != expectedFileName {
            throw CloudAssetStagingError.immutableIdentityMismatch
        }
    }

    private func restoreOrCreateStagedFile(
        _ data: Data,
        named name: String,
        version: SyncAttachmentVersion,
        directories: OpenDirectories
    ) throws {
        let matchingResidues = try directoryEntryNames(directories.uploads).filter {
            $0.hasPrefix(".\(name).") && $0.hasSuffix(".cleanup")
        }
        guard matchingResidues.allSatisfy({ isCleanupTombstone($0, for: name) }),
            matchingResidues.count <= 1
        else {
            throw CloudAssetStagingError.corruptManifest
        }
        if try destinationIdentity(named: name, in: directories.uploads) != nil {
            guard matchingResidues.isEmpty else {
                throw CloudAssetStagingError.corruptManifest
            }
            try verifyFile(
                named: name,
                in: directories.uploads,
                expectedByteCount: version.byteCount,
                expectedSHA256: version.contentSHA256
            )
            return
        }
        if let residue = matchingResidues.first {
            try verifyFile(
                named: residue,
                in: directories.uploads,
                expectedByteCount: version.byteCount,
                expectedSHA256: version.contentSHA256
            )
            let result = residue.withCString { source in
                name.withCString { destination in
                    Darwin.renameatx_np(
                        directories.uploads,
                        source,
                        directories.uploads,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard result == 0, Darwin.fsync(directories.uploads) == 0 else {
                throw CloudAssetStagingError.unavailable
            }
            try verifyFile(
                named: name,
                in: directories.uploads,
                expectedByteCount: version.byteCount,
                expectedSHA256: version.contentSHA256
            )
            return
        }
        try createImmutableFile(
            data,
            named: name,
            directoryDescriptor: directories.uploads,
            retiredDescriptor: directories.retired,
            fileSyncBoundary: .uploadBeforeFileSync,
            renameBoundary: .uploadBeforeRename,
            directorySyncBoundary: .uploadBeforeDirectorySync,
            expectedByteCount: version.byteCount,
            expectedSHA256: version.contentSHA256
        )
    }

    private func isCleanupTombstone(_ candidate: String, for name: String) -> Bool {
        let prefix = ".\(name)."
        let suffix = ".cleanup"
        guard candidate.hasPrefix(prefix), candidate.hasSuffix(suffix) else { return false }
        let start = candidate.index(candidate.startIndex, offsetBy: prefix.count)
        let end = candidate.index(candidate.endIndex, offsetBy: -suffix.count)
        let token = String(candidate[start ..< end])
        guard let uuid = UUID(uuidString: token) else { return false }
        return token == uuid.uuidString.lowercased()
    }

    private enum TemporaryDomain {
        case immutableAsset
        case manifest
        case quarantineAsset
    }

    private func isGeneratedTemporaryName(
        _ candidate: String,
        domain: TemporaryDomain
    ) -> Bool {
        guard candidate.hasPrefix("."), candidate.hasSuffix(".tmp") else { return false }
        let bodyStart = candidate.index(after: candidate.startIndex)
        let bodyEnd = candidate.index(candidate.endIndex, offsetBy: -4)
        let body = String(candidate[bodyStart ..< bodyEnd])
        guard let separator = body.lastIndex(of: ".") else { return false }
        let finalName = String(body[..<separator])
        let token = String(body[body.index(after: separator)...])
        guard let temporaryID = UUID(uuidString: token), token == temporaryID.uuidString else {
            return false
        }
        switch domain {
        case .immutableAsset:
            return isImmutableAssetName(finalName)
        case .manifest:
            return finalName == Self.manifestName
        case .quarantineAsset:
            return isQuarantineAssetName(finalName)
        }
    }

    private func isImmutableAssetName(_ candidate: String) -> Bool {
        let expectedCount = 36 + 1 + SHA256.byteCount * 2 + ".asset".count
        guard candidate.count == expectedCount else { return false }
        let uuidEnd = candidate.index(candidate.startIndex, offsetBy: 36)
        let uuidText = String(candidate[..<uuidEnd])
        guard let versionID = UUID(uuidString: uuidText),
            uuidText == versionID.uuidString.lowercased(),
            candidate[uuidEnd] == "-",
            candidate.hasSuffix(".asset")
        else {
            return false
        }
        let digestStart = candidate.index(after: uuidEnd)
        let digestEnd = candidate.index(candidate.endIndex, offsetBy: -".asset".count)
        let digest = candidate[digestStart ..< digestEnd]
        return digest.count == SHA256.byteCount * 2
            && digest.allSatisfy { ("0" ... "9").contains($0) || ("a" ... "f").contains($0) }
    }

    private func isQuarantineAssetName(_ candidate: String) -> Bool {
        guard candidate.hasSuffix(".asset") else { return false }
        let end = candidate.index(candidate.endIndex, offsetBy: -".asset".count)
        let uuidText = String(candidate[..<end])
        guard let identifier = UUID(uuidString: uuidText) else { return false }
        return uuidText == identifier.uuidString.lowercased()
    }

    private func createImmutableFile(
        _ data: Data,
        named name: String,
        directoryDescriptor: Int32,
        retiredDescriptor: Int32,
        fileSyncBoundary: CloudAssetStagingBoundary,
        renameBoundary: CloudAssetStagingBoundary,
        directorySyncBoundary: CloudAssetStagingBoundary,
        expectedByteCount: Int64,
        expectedSHA256: Data
    ) throws {
        if try destinationIdentity(named: name, in: directoryDescriptor) != nil {
            try verifyFile(
                named: name,
                in: directoryDescriptor,
                expectedByteCount: expectedByteCount,
                expectedSHA256: expectedSHA256
            )
            return
        }
        do {
            try createNewFile(
                data,
                named: name,
                directoryDescriptor: directoryDescriptor,
                retiredDescriptor: retiredDescriptor,
                fileSyncBoundary: fileSyncBoundary,
                renameBoundary: renameBoundary,
                directorySyncBoundary: directorySyncBoundary
            )
        } catch CloudAssetStagingError.immutableIdentityMismatch {
            try verifyFile(
                named: name,
                in: directoryDescriptor,
                expectedByteCount: expectedByteCount,
                expectedSHA256: expectedSHA256
            )
        }
    }

    private func createNewFile(
        _ data: Data,
        named name: String,
        directoryDescriptor: Int32,
        retiredDescriptor: Int32,
        fileSyncBoundary: CloudAssetStagingBoundary,
        renameBoundary: CloudAssetStagingBoundary,
        directorySyncBoundary: CloudAssetStagingBoundary
    ) throws {
        let temporaryName = ".\(name).\(UUID().uuidString).tmp"
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else { throw CloudAssetStagingError.unavailable }
        let temporaryIdentity = try Self.fileIdentity(of: descriptor)
        var removeTemporary = true
        var temporaryPathName = temporaryName
        defer { Darwin.close(descriptor) }
        do {
            try Self.writeAll(data, descriptor: descriptor)
            try beforeBoundary(fileSyncBoundary)
            guard Darwin.fsync(descriptor) == 0 else { throw CloudAssetStagingError.unavailable }
            try beforeBoundary(renameBoundary)
            let result = temporaryName.withCString { temporary in
                name.withCString { destination in
                    Darwin.renameatx_np(
                        directoryDescriptor,
                        temporary,
                        directoryDescriptor,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            if result != 0 {
                guard errno == EEXIST else { throw CloudAssetStagingError.unavailable }
                throw CloudAssetStagingError.immutableIdentityMismatch
            }
            temporaryPathName = name
            // A completed no-clobber rename is recoverable published state.
            // Boundary failures model a process crash and must leave it for
            // manifest/installed reconciliation; identity failures still fail
            // closed without deleting either pathname occupant.
            removeTemporary = false
            try beforeBoundary(directorySyncBoundary)
            guard try destinationIdentity(named: name, in: directoryDescriptor)
                == temporaryIdentity
            else {
                throw CloudAssetStagingError.unsafeFile
            }
            guard Darwin.fsync(directoryDescriptor) == 0 else {
                throw CloudAssetStagingError.unavailable
            }
        } catch let operationError {
            if removeTemporary {
                do {
                    try retireBoundFile(
                        named: temporaryPathName,
                        logicalName: name,
                        from: directoryDescriptor,
                        descriptor: descriptor,
                        expectedIdentity: temporaryIdentity,
                        retiredDescriptor: retiredDescriptor
                    )
                } catch {
                    throw error
                }
            }
            throw operationError
        }
    }

    private func verifyFile(
        named name: String,
        in directoryDescriptor: Int32,
        expectedByteCount: Int64,
        expectedSHA256: Data
    ) throws {
        let descriptor = name.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        if descriptor < 0 {
            if errno == ELOOP { throw CloudAssetStagingError.unsafeFile }
            throw CloudAssetStagingError.unavailable
        }
        defer { Darwin.close(descriptor) }
        let read = try readDescriptor(
            descriptor,
            maximumBytes: maximumAssetBytes,
            expectedByteCount: expectedByteCount
        )
        guard read.byteCount == expectedByteCount,
            read.sha256 == expectedSHA256
        else {
            throw CloudAssetStagingError.contentMismatch
        }
    }

    private func readDescriptor(
        _ descriptor: Int32,
        maximumBytes: Int,
        expectedByteCount: Int64? = nil
    ) throws -> DescriptorRead {
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
            (before.st_mode & S_IFMT) == S_IFREG,
            before.st_size >= 0
        else {
            throw CloudAssetStagingError.unsafeFile
        }
        guard before.st_size <= maximumBytes else { throw CloudAssetStagingError.tooLarge }
        if let expectedByteCount {
            guard expectedByteCount >= 0,
                expectedByteCount <= Int64(maximumBytes),
                Int64(before.st_size) == expectedByteCount
            else {
                throw CloudAssetStagingError.contentMismatch
            }
        }
        let readLimit = expectedByteCount.map(Int.init) ?? maximumBytes
        var data = Data()
        data.reserveCapacity(min(Int(before.st_size), readLimit))
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let remaining = readLimit - data.count
            let requestedCount = remaining >= buffer.count ? buffer.count : remaining + 1
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requestedCount)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw CloudAssetStagingError.unavailable }
            guard count > 0 else { break }
            guard count <= remaining else {
                if expectedByteCount != nil {
                    throw CloudAssetStagingError.contentMismatch
                }
                throw CloudAssetStagingError.tooLarge
            }
            data.append(buffer, count: count)
            hasher.update(data: Data(buffer.prefix(count)))
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
            (after.st_mode & S_IFMT) == S_IFREG
        else {
            throw CloudAssetStagingError.unsafeFile
        }
        guard before.st_dev == after.st_dev,
            before.st_ino == after.st_ino,
            before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            data.count == Int(before.st_size)
        else {
            throw CloudAssetStagingError.contentMismatch
        }
        return DescriptorRead(
            data: data,
            byteCount: Int64(data.count),
            sha256: Data(hasher.finalize())
        )
    }

    private func readDescriptorPreservingOffset(
        _ descriptor: Int32,
        maximumBytes: Int
    ) throws -> DescriptorRead {
        let originalOffset = Darwin.lseek(descriptor, 0, SEEK_CUR)
        guard originalOffset >= 0, Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw CloudAssetStagingError.unavailable
        }
        defer { _ = Darwin.lseek(descriptor, originalOffset, SEEK_SET) }
        return try readDescriptor(descriptor, maximumBytes: maximumBytes)
    }

    private struct DescriptorRead {
        let data: Data
        let byteCount: Int64
        let sha256: Data
    }

    private struct OpenDirectories {
        let root: Int32
        let accounts: Int32
        let account: Int32
        let uploads: Int32
        let installed: Int32
        let quarantine: Int32
        let retired: Int32

        func close() {
            Darwin.close(retired)
            Darwin.close(quarantine)
            Darwin.close(installed)
            Darwin.close(uploads)
            Darwin.close(account)
            Darwin.close(accounts)
            Darwin.close(root)
        }
    }

    private func withDirectories<T>(_ body: (OpenDirectories) throws -> T) throws -> T {
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        } catch {
            throw CloudAssetStagingError.unavailable
        }
        let root = try Self.openDirectory(at: rootURL)
        var accounts: Int32 = -1
        var account: Int32 = -1
        var uploads: Int32 = -1
        var installed: Int32 = -1
        var quarantine: Int32 = -1
        var retired: Int32 = -1
        var transferredOwnership = false
        defer {
            if !transferredOwnership {
                if retired >= 0 { Darwin.close(retired) }
                if quarantine >= 0 { Darwin.close(quarantine) }
                if installed >= 0 { Darwin.close(installed) }
                if uploads >= 0 { Darwin.close(uploads) }
                if account >= 0 { Darwin.close(account) }
                if accounts >= 0 { Darwin.close(accounts) }
                Darwin.close(root)
            }
        }
        accounts = try Self.openOrCreateDirectory(named: "Accounts", in: root)
        account = try Self.openOrCreateDirectory(named: accountToken, in: accounts)
        uploads = try Self.openOrCreateDirectory(named: "Uploads", in: account)
        installed = try Self.openOrCreateDirectory(named: "Installed", in: account)
        quarantine = try Self.openOrCreateDirectory(named: "Quarantine", in: account)
        retired = try Self.openOrCreateDirectory(named: "Retired", in: account)
        let directories = OpenDirectories(
            root: root,
            accounts: accounts,
            account: account,
            uploads: uploads,
            installed: installed,
            quarantine: quarantine,
            retired: retired
        )
        transferredOwnership = true
        defer { directories.close() }
        try validateDirectoryTree(directories)
        return try body(directories)
    }

    private func validateDirectoryTree(_ directories: OpenDirectories) throws {
        let rootIdentity = try Self.directoryIdentity(of: directories.root)
        var rootStatus = stat()
        guard rootURL.path.withCString({ Darwin.lstat($0, &rootStatus) }) == 0,
            (rootStatus.st_mode & S_IFMT) == S_IFDIR,
            rootIdentity == FileIdentity(device: rootStatus.st_dev, inode: rootStatus.st_ino)
        else {
            throw CloudAssetStagingError.unsafeFile
        }
        try validateDirectory(
            descriptor: directories.accounts,
            named: "Accounts",
            in: directories.root
        )
        try validateDirectory(
            descriptor: directories.account,
            named: accountToken,
            in: directories.accounts
        )
        try validateDirectory(
            descriptor: directories.uploads,
            named: "Uploads",
            in: directories.account
        )
        try validateDirectory(
            descriptor: directories.installed,
            named: "Installed",
            in: directories.account
        )
        try validateDirectory(
            descriptor: directories.quarantine,
            named: "Quarantine",
            in: directories.account
        )
        try validateDirectory(
            descriptor: directories.retired,
            named: "Retired",
            in: directories.account
        )
    }

    private func validateDirectory(
        descriptor: Int32,
        named name: String,
        in parent: Int32
    ) throws {
        var status = stat()
        guard name.withCString({
            Darwin.fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
        }) == 0,
            (status.st_mode & S_IFMT) == S_IFDIR,
            try Self.directoryIdentity(of: descriptor)
                == FileIdentity(device: status.st_dev, inode: status.st_ino)
        else {
            throw CloudAssetStagingError.unsafeFile
        }
    }

    private static func openDirectory(at url: URL) throws -> Int32 {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0 {
            if errno == ELOOP { throw CloudAssetStagingError.unsafeFile }
            throw CloudAssetStagingError.unavailable
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFDIR
        else {
            Darwin.close(descriptor)
            throw CloudAssetStagingError.unsafeFile
        }
        return descriptor
    }

    private static func openOrCreateDirectory(named name: String, in parent: Int32) throws -> Int32
    {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw CloudAssetStagingError.unsafeFile
        }
        var descriptor = name.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0, errno == ENOENT {
            let result = name.withCString {
                Darwin.mkdirat(parent, $0, S_IRWXU)
            }
            if result != 0, errno != EEXIST { throw CloudAssetStagingError.unavailable }
            guard Darwin.fsync(parent) == 0 else { throw CloudAssetStagingError.unavailable }
            descriptor = name.withCString {
                Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
        }
        if descriptor < 0 {
            if errno == ELOOP || errno == ENOTDIR { throw CloudAssetStagingError.unsafeFile }
            throw CloudAssetStagingError.unavailable
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFDIR
        else {
            Darwin.close(descriptor)
            throw CloudAssetStagingError.unsafeFile
        }
        return descriptor
    }

    private static func openOrCreateLock(in directory: Int32) throws -> Int32 {
        let descriptor = lockName.withCString {
            Darwin.openat(
                directory,
                $0,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        if descriptor < 0 {
            if errno == ELOOP { throw CloudAssetStagingError.unsafeFile }
            throw CloudAssetStagingError.unavailable
        }
        do {
            try validateLockDescriptor(descriptor)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func validateLock(_ descriptor: Int32, in directory: Int32) throws {
        try validateLockDescriptor(descriptor)
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0,
            lockName.withCString({
                Darwin.fstatat(directory, $0, &pathStatus, AT_SYMLINK_NOFOLLOW)
            }) == 0,
            (pathStatus.st_mode & S_IFMT) == S_IFREG,
            pathStatus.st_uid == Darwin.geteuid(),
            pathStatus.st_nlink == 1,
            descriptorStatus.st_dev == pathStatus.st_dev,
            descriptorStatus.st_ino == pathStatus.st_ino
        else {
            throw CloudAssetStagingError.unsafeFile
        }
    }

    private static func validateLockDescriptor(_ descriptor: Int32) throws {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFREG,
            status.st_uid == Darwin.geteuid(),
            status.st_nlink == 1
        else {
            throw CloudAssetStagingError.unsafeFile
        }
    }

    private static func setLock(_ descriptor: Int32, type: Int16) throws {
        var lock = flock()
        lock.l_type = type
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        while true {
            if Darwin.fcntl(descriptor, F_SETLKW, &lock) == 0 { return }
            if errno == EINTR { continue }
            throw CloudAssetStagingError.unavailable
        }
    }

    private static func setDirectoryLock(_ descriptor: Int32, operation: Int32) throws {
        while true {
            if cloudAssetFlock(descriptor, operation) == 0 { return }
            if errno == EINTR { continue }
            throw CloudAssetStagingError.unavailable
        }
    }

    private static func fileIdentity(of descriptor: Int32) throws -> FileIdentity {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFREG
        else {
            throw CloudAssetStagingError.unsafeFile
        }
        return FileIdentity(device: status.st_dev, inode: status.st_ino)
    }

    private static func directoryIdentity(of descriptor: Int32) throws -> FileIdentity {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFDIR
        else {
            throw CloudAssetStagingError.unsafeFile
        }
        return FileIdentity(device: status.st_dev, inode: status.st_ino)
    }

    private func destinationIdentity(named name: String, in directory: Int32) throws
        -> FileIdentity?
    {
        var status = stat()
        let result = name.withCString {
            Darwin.fstatat(directory, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw CloudAssetStagingError.unavailable
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw CloudAssetStagingError.unsafeFile
        }
        return FileIdentity(device: status.st_dev, inode: status.st_ino)
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private func retirementToken(for logicalName: String) -> String {
        Self.hex(Data(SHA256.hash(data: Data(logicalName.utf8))))
    }

    private enum RetirementKind: String, Hashable {
        case asset
        case manifest
        case quarantine
    }

    private struct RetirementMetadata {
        let kind: RetirementKind
        let logicalToken: String
        let byteCount: Int64
        let contentSHA256: String
    }

    private func retirementKind(for logicalName: String) throws -> RetirementKind {
        if logicalName == Self.manifestName
            || isGeneratedTemporaryName(logicalName, domain: .manifest)
        {
            return .manifest
        }
        if isImmutableAssetName(logicalName)
            || isGeneratedTemporaryName(logicalName, domain: .immutableAsset)
            || logicalName.hasSuffix(".cleanup")
        {
            return .asset
        }
        if isQuarantineAssetName(logicalName)
            || isGeneratedTemporaryName(logicalName, domain: .quarantineAsset)
        {
            return .quarantine
        }
        throw CloudAssetStagingError.unsafeFile
    }

    private func isRetirementTombstone(_ candidate: String, for logicalName: String? = nil)
        -> Bool
    {
        guard let metadata = retirementMetadata(from: candidate) else { return false }
        return logicalName.map { metadata.logicalToken == retirementToken(for: $0) } ?? true
    }

    private func retirementMetadata(from candidate: String) -> RetirementMetadata? {
        let suffix = ".retired"
        guard candidate.hasSuffix(suffix) else { return nil }
        let body = candidate.dropLast(suffix.count)
        let fields = body.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 5,
            let kind = RetirementKind(rawValue: String(fields[0])),
            Self.isLowercaseHex(fields[1]),
            fields[1].count == SHA256.byteCount * 2,
            let byteCount = Int64(fields[2]),
            byteCount >= 0,
            String(byteCount) == fields[2],
            Self.isLowercaseHex(fields[3]),
            fields[3].count == SHA256.byteCount * 2,
            let identifier = UUID(uuidString: String(fields[4])),
            fields[4] == Substring(identifier.uuidString.lowercased())
        else {
            return nil
        }
        return RetirementMetadata(
            kind: kind,
            logicalToken: String(fields[1]),
            byteCount: byteCount,
            contentSHA256: String(fields[3])
        )
    }

    private func recoverRetiredFiles(
        manifest: Manifest,
        directories: OpenDirectories
    ) throws {
        let correlatedReferences = manifest.references + manifest.cleanupIntents
        for name in try directoryEntryNames(directories.retired)
        where name != "." && name != ".." {
            guard let metadata = retirementMetadata(from: name) else {
                throw CloudAssetStagingError.unsafeFile
            }
            let descriptor = name.withCString {
                Darwin.openat(
                    directories.retired,
                    $0,
                    O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else { throw CloudAssetStagingError.unsafeFile }
            defer { Darwin.close(descriptor) }
            let identity = try Self.fileIdentity(of: descriptor)
            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0,
                status.st_nlink == 1,
                status.st_size >= 0
            else {
                throw CloudAssetStagingError.unsafeFile
            }
            if status.st_size == 0 { continue }
            let maximumBytes = max(maximumAssetBytes, Self.maximumManifestBytes)
            guard metadata.byteCount <= Int64(maximumBytes) else {
                throw CloudAssetStagingError.tooLarge
            }
            let read = try readDescriptor(
                descriptor,
                maximumBytes: maximumBytes,
                expectedByteCount: metadata.byteCount
            )
            guard Self.hex(read.sha256) == metadata.contentSHA256 else {
                throw CloudAssetStagingError.contentMismatch
            }
            switch metadata.kind {
            case .manifest:
                guard metadata.logicalToken == retirementToken(for: Self.manifestName) else {
                    throw CloudAssetStagingError.contentMismatch
                }
                _ = try decodeManifest(read.data)
            case .asset:
                if let reference = try correlatedReferences.first(where: {
                    metadata.logicalToken == retirementToken(
                        for: try immutableFileName(for: $0.version)
                    )
                }) {
                    guard read.byteCount == reference.version.byteCount,
                        read.sha256 == reference.version.contentSHA256
                    else {
                        throw CloudAssetStagingError.contentMismatch
                    }
                }
            case .quarantine:
                break
            }
            try finishRetiredFile(
                named: name,
                descriptor: descriptor,
                expectedIdentity: identity,
                retiredDescriptor: directories.retired
            )
        }
        _ = try compactZeroRetirementMarkers(
            kind: nil,
            retiredDescriptor: directories.retired
        )
    }

    /// Atomically removes a pathname from an active directory, proves the
    /// moved entry is still the descriptor-bound inode, then retires only that
    /// inode's payload. One canonical zero-byte marker per retirement kind is
    /// reused by atomic rename because Darwin has no unlink-by-descriptor primitive.
    private func retireBoundFile(
        named name: String,
        logicalName: String,
        from directory: Int32,
        descriptor: Int32,
        expectedIdentity: FileIdentity,
        retiredDescriptor: Int32,
        synchronize: Bool = true
    ) throws {
        let retirementName = try captureBoundFile(
            named: name,
            logicalName: logicalName,
            from: directory,
            descriptor: descriptor,
            expectedIdentity: expectedIdentity,
            retiredDescriptor: retiredDescriptor,
            synchronize: synchronize
        )
        try finishRetiredFile(
            named: retirementName,
            descriptor: descriptor,
            expectedIdentity: expectedIdentity,
            retiredDescriptor: retiredDescriptor
        )
    }

    private func captureBoundFile(
        named name: String,
        logicalName: String,
        from directory: Int32,
        descriptor: Int32,
        expectedIdentity: FileIdentity,
        retiredDescriptor: Int32,
        synchronize: Bool = true
    ) throws -> String {
        let fingerprint = try readDescriptorPreservingOffset(
            descriptor,
            maximumBytes: max(maximumAssetBytes, Self.maximumManifestBytes)
        )
        let kind = try retirementKind(for: logicalName)
        let retirementName = [
            kind.rawValue,
            retirementToken(for: logicalName),
            String(fingerprint.byteCount),
            Self.hex(fingerprint.sha256),
            UUID().uuidString.lowercased(),
        ].joined(separator: ".") + ".retired"
        let reusableMarker = try reusableRetirementMarker(
            kind: kind,
            retiredDescriptor: retiredDescriptor
        )
        if let reusableMarker {
            let renameMarker = reusableMarker.withCString { source in
                retirementName.withCString { destination in
                    Darwin.renameatx_np(
                        retiredDescriptor,
                        source,
                        retiredDescriptor,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard renameMarker == 0 else { throw CloudAssetStagingError.unavailable }
        }
        let moveResult = name.withCString { source in
            retirementName.withCString { destination in
                if reusableMarker == nil {
                    Darwin.renameatx_np(
                        directory,
                        source,
                        retiredDescriptor,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                } else {
                    // Replacing a verified zero-byte marker is one atomic
                    // rename. It removes the active pathname and bounds the
                    // retirement namespace without a check-then-unlink race.
                    Darwin.renameat(
                        directory,
                        source,
                        retiredDescriptor,
                        destination
                    )
                }
            }
        }
        guard moveResult == 0 else { throw CloudAssetStagingError.unavailable }

        var capturedExpectedInode = false
        do {
            guard try destinationIdentity(named: retirementName, in: retiredDescriptor)
                == expectedIdentity,
                try Self.fileIdentity(of: descriptor) == expectedIdentity
            else {
                throw CloudAssetStagingError.unsafeFile
            }
            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0,
                (status.st_mode & S_IFMT) == S_IFREG,
                status.st_nlink == 1
            else {
                throw CloudAssetStagingError.unsafeFile
            }
            if synchronize {
                guard Darwin.fsync(directory) == 0,
                    Darwin.fsync(retiredDescriptor) == 0
                else {
                    throw CloudAssetStagingError.unavailable
                }
            }
            capturedExpectedInode = true
            return retirementName
        } catch {
            if !capturedExpectedInode {
                _ = retirementName.withCString { source in
                    name.withCString { destination in
                        Darwin.renameatx_np(
                            retiredDescriptor,
                            source,
                            directory,
                            destination,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
            }
            throw error
        }
    }

    private func reusableRetirementMarker(
        kind: RetirementKind,
        retiredDescriptor: Int32
    ) throws -> String? {
        try compactZeroRetirementMarkers(
            kind: kind,
            retiredDescriptor: retiredDescriptor
        )[kind]
    }

    private func compactZeroRetirementMarkers(
        kind requestedKind: RetirementKind?,
        retiredDescriptor: Int32
    ) throws -> [RetirementKind: String] {
        let emptySHA256 = Data(SHA256.hash(data: Data()))
        var result: [RetirementKind: String] = [:]
        var changed = false
        for candidate in try directoryEntryNames(retiredDescriptor)
        where candidate != "." && candidate != ".." {
            guard let metadata = retirementMetadata(from: candidate) else {
                throw CloudAssetStagingError.unsafeFile
            }
            guard requestedKind == nil || metadata.kind == requestedKind else { continue }
            try verifyFile(
                named: candidate,
                in: retiredDescriptor,
                expectedByteCount: 0,
                expectedSHA256: emptySHA256
            )
            guard let survivor = result[metadata.kind] else {
                result[metadata.kind] = candidate
                continue
            }
            try replaceZeroRetirementMarker(
                survivor,
                with: candidate,
                retiredDescriptor: retiredDescriptor
            )
            changed = true
        }
        if changed, Darwin.fsync(retiredDescriptor) != 0 {
            throw CloudAssetStagingError.unavailable
        }
        return result
    }

    private func replaceZeroRetirementMarker(
        _ destinationName: String,
        with sourceName: String,
        retiredDescriptor: Int32
    ) throws {
        let sourceDescriptor = sourceName.withCString {
            Darwin.openat(retiredDescriptor, $0, O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        let destinationDescriptor = destinationName.withCString {
            Darwin.openat(retiredDescriptor, $0, O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard sourceDescriptor >= 0, destinationDescriptor >= 0 else {
            if sourceDescriptor >= 0 { Darwin.close(sourceDescriptor) }
            if destinationDescriptor >= 0 { Darwin.close(destinationDescriptor) }
            throw CloudAssetStagingError.unsafeFile
        }
        defer {
            Darwin.close(destinationDescriptor)
            Darwin.close(sourceDescriptor)
        }
        let sourceIdentity = try Self.fileIdentity(of: sourceDescriptor)
        let destinationIdentity = try Self.fileIdentity(of: destinationDescriptor)
        var sourceStatus = stat()
        var destinationStatus = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceStatus) == 0,
            Darwin.fstat(destinationDescriptor, &destinationStatus) == 0,
            sourceStatus.st_size == 0,
            destinationStatus.st_size == 0,
            sourceStatus.st_nlink == 1,
            destinationStatus.st_nlink == 1
        else {
            throw CloudAssetStagingError.unsafeFile
        }
        let result = sourceName.withCString { source in
            destinationName.withCString { destination in
                Darwin.renameat(
                    retiredDescriptor,
                    source,
                    retiredDescriptor,
                    destination
                )
            }
        }
        guard result == 0,
            try self.destinationIdentity(named: destinationName, in: retiredDescriptor)
                == sourceIdentity,
            Darwin.fstat(sourceDescriptor, &sourceStatus) == 0,
            sourceStatus.st_nlink == 1,
            Darwin.fstat(destinationDescriptor, &destinationStatus) == 0,
            destinationStatus.st_nlink == 0,
            try Self.fileIdentity(of: destinationDescriptor) == destinationIdentity
        else {
            throw CloudAssetStagingError.unsafeFile
        }
    }

    private func finishRetiredFile(
        named name: String,
        descriptor: Int32,
        expectedIdentity: FileIdentity,
        retiredDescriptor: Int32
    ) throws {
        var status = stat()
        guard try destinationIdentity(named: name, in: retiredDescriptor) == expectedIdentity,
            try Self.fileIdentity(of: descriptor) == expectedIdentity,
            Darwin.fstat(descriptor, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFREG,
            status.st_nlink == 1
        else {
            throw CloudAssetStagingError.unsafeFile
        }
        guard Darwin.ftruncate(descriptor, 0) == 0,
            Darwin.fsync(descriptor) == 0,
            Darwin.fstat(descriptor, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFREG,
            status.st_size == 0,
            status.st_nlink == 1,
            try destinationIdentity(named: name, in: retiredDescriptor) == expectedIdentity,
            Darwin.fsync(retiredDescriptor) == 0
        else {
            throw CloudAssetStagingError.unavailable
        }
    }

    private func removeRegularFile(
        named name: String,
        from directory: Int32,
        retiredDescriptor: Int32,
        retirementLogicalName: String? = nil,
        candidateURL: URL? = nil,
        expectedByteCount: Int64? = nil,
        expectedSHA256: Data? = nil
    ) throws {
        guard let original = try destinationIdentity(named: name, in: directory) else { return }
        if let candidateURL {
            try beforeBoundary(.cleanupAfterIdentityCheck(candidate: candidateURL))
        }
        let tombstoneName = ".\(name).\(UUID().uuidString.lowercased()).cleanup"
        let moveResult = name.withCString { candidate in
            tombstoneName.withCString { tombstone in
                Darwin.renameatx_np(
                    directory,
                    candidate,
                    directory,
                    tombstone,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard moveResult == 0 else { throw CloudAssetStagingError.unavailable }
        try beforeBoundary(.cleanupAfterMove)
        let descriptor = tombstoneName.withCString {
            Darwin.openat(directory, $0, O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            try rollbackCleanupTombstone(tombstoneName, to: name, in: directory)
            throw CloudAssetStagingError.unsafeFile
        }
        defer { Darwin.close(descriptor) }
        do {
            guard try Self.fileIdentity(of: descriptor) == original else {
                throw CloudAssetStagingError.unsafeFile
            }
            if let expectedByteCount, let expectedSHA256 {
                let read = try readDescriptor(
                    descriptor,
                    maximumBytes: maximumAssetBytes,
                    expectedByteCount: expectedByteCount,
                )
                guard read.byteCount == expectedByteCount, read.sha256 == expectedSHA256 else {
                    throw CloudAssetStagingError.contentMismatch
                }
            }
        } catch {
            try rollbackCleanupTombstone(tombstoneName, to: name, in: directory)
            throw error
        }
        if let candidateURL {
            let tombstoneURL = candidateURL.deletingLastPathComponent()
                .appendingPathComponent(tombstoneName)
            try beforeBoundary(.cleanupBeforeUnlink(candidate: tombstoneURL))
        }
        guard try destinationIdentity(named: tombstoneName, in: directory) == original else {
            throw CloudAssetStagingError.unsafeFile
        }
        if let candidateURL {
            let tombstoneURL = candidateURL.deletingLastPathComponent()
                .appendingPathComponent(tombstoneName)
            try beforeBoundary(.cleanupAfterFinalIdentityCheck(candidate: tombstoneURL))
        }
        try retireBoundFile(
            named: tombstoneName,
            logicalName: retirementLogicalName ?? name,
            from: directory,
            descriptor: descriptor,
            expectedIdentity: original,
            retiredDescriptor: retiredDescriptor
        )
    }

    private func rollbackCleanupTombstone(
        _ tombstoneName: String,
        to candidateName: String,
        in directory: Int32
    ) throws {
        let rollback = tombstoneName.withCString { tombstone in
            candidateName.withCString { candidate in
                Darwin.renameatx_np(
                    directory,
                    tombstone,
                    directory,
                    candidate,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard rollback == 0 else { throw CloudAssetStagingError.unavailable }
    }

    private func directoryEntryNames(_ descriptor: Int32) throws -> [String] {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0,
            Darwin.lseek(duplicate, 0, SEEK_SET) >= 0,
            let stream = Darwin.fdopendir(duplicate)
        else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw CloudAssetStagingError.unavailable
        }
        defer { Darwin.closedir(stream) }
        var names: [String] = []
        while let entry = Darwin.readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            names.append(name)
        }
        return names
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw CloudAssetStagingError.unavailable }
                offset += count
            }
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func isLowercaseHex(_ value: Substring) -> Bool {
        value.allSatisfy { ("0" ... "9").contains($0) || ("a" ... "f").contains($0) }
    }

    private static func map(_ error: SyncRegularFileReadError) -> CloudAssetStagingError {
        switch error {
        case .unsafeFile:
            .unsafeFile
        case .tooLarge:
            .tooLarge
        case .expectationMismatch, .changed, .replaced:
            .contentMismatch
        case .unavailable:
            .unavailable
        }
    }
}
