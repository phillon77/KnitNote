import CloudKit
import CryptoKit
import Darwin
import Foundation

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
    case manifestBeforeDirectorySync
    case downloadBeforeFileSync
    case downloadBeforeRename(destination: URL)
    case downloadBeforeDirectorySync
    case quarantineBeforeFileSync
    case quarantineBeforeRename
    case quarantineBeforeDirectorySync
    case acknowledgementAfterManifest

    func sameKind(as other: CloudAssetStagingBoundary?) -> Bool {
        guard let other else { return false }
        return switch (self, other) {
        case (.uploadBeforeFileSync, .uploadBeforeFileSync),
            (.uploadBeforeRename, .uploadBeforeRename),
            (.uploadBeforeDirectorySync, .uploadBeforeDirectorySync),
            (.manifestBeforeFileSync, .manifestBeforeFileSync),
            (.manifestBeforeRename, .manifestBeforeRename),
            (.manifestBeforeDirectorySync, .manifestBeforeDirectorySync),
            (.downloadBeforeFileSync, .downloadBeforeFileSync),
            (.downloadBeforeRename, .downloadBeforeRename),
            (.downloadBeforeDirectorySync, .downloadBeforeDirectorySync),
            (.quarantineBeforeFileSync, .quarantineBeforeFileSync),
            (.quarantineBeforeRename, .quarantineBeforeRename),
            (.quarantineBeforeDirectorySync, .quarantineBeforeDirectorySync),
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
    private let beforeBoundary: BeforeBoundary

    init(
        rootURL: URL,
        accountIdentifier: String,
        maximumAssetBytes: Int = CloudAssetStagingService.defaultMaximumAssetBytes,
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
            var manifest = try loadManifest(accountDescriptor: directories.account)
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
            guard
                manifest.references.allSatisfy({ reference in
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
                fileSyncBoundary: .uploadBeforeFileSync,
                renameBoundary: .uploadBeforeRename,
                directorySyncBoundary: .uploadBeforeDirectorySync,
                expectedByteCount: version.byteCount,
                expectedSHA256: version.contentSHA256
            )
            manifest.references.append(result)
            try writeManifest(manifest, accountDescriptor: directories.account)
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
            let manifest = try loadManifest(accountDescriptor: directories.account)
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
            var manifest = try loadManifest(accountDescriptor: directories.account)
            guard
                let index = manifest.references.firstIndex(where: {
                    referencesMatch($0, reference)
                })
            else {
                throw CloudAssetStagingError.unknownUpload
            }
            manifest.references.remove(at: index)
            try writeManifest(manifest, accountDescriptor: directories.account)
            try beforeBoundary(.acknowledgementAfterManifest)
            guard
                !manifest.references.contains(where: {
                    $0.stagedFileURL.lastPathComponent == fileName
                })
            else { return }
            try removeRegularFile(named: fileName, from: directories.uploads)
        }
    }

    @discardableResult
    func installDownload(
        from sourceURL: URL,
        version: SyncAttachmentVersion
    ) throws -> URL {
        let version = try validated(version)
        let read = try readExternal(sourceURL)
        guard read.byteCount == version.byteCount,
            read.sha256 == version.contentSHA256
        else {
            _ = try quarantine(read.data)
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
            let manifest = try loadManifest(accountDescriptor: directories.account)
            let referenced = Set(manifest.references.map { $0.stagedFileURL.lastPathComponent })
            for reference in manifest.references {
                try verifyFile(
                    named: reference.stagedFileURL.lastPathComponent,
                    in: directories.uploads,
                    expectedByteCount: reference.version.byteCount,
                    expectedSHA256: reference.version.contentSHA256
                )
            }
            var removedUpload = false
            for name in try directoryEntryNames(directories.uploads)
            where name != "." && name != ".." {
                if name.hasSuffix(".tmp")
                    || (name.hasSuffix(".asset") && !referenced.contains(name))
                {
                    try removeRegularFile(
                        named: name, from: directories.uploads, synchronize: false)
                    removedUpload = true
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
                try removeRegularFile(named: name, from: directories.installed, synchronize: false)
                removedInstall = true
            }
            if removedInstall, Darwin.fsync(directories.installed) != 0 {
                throw CloudAssetStagingError.unavailable
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

    private func coordinated<T>(_ body: (OpenDirectories) throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        return try withDirectories { directories in
            let lockDescriptor = Self.openOrCreateLock(in: directories.account)
            guard lockDescriptor >= 0 else { throw CloudAssetStagingError.unavailable }
            defer { Darwin.close(lockDescriptor) }
            try Self.setLock(lockDescriptor, type: Int16(F_WRLCK))
            defer { try? Self.setLock(lockDescriptor, type: Int16(F_UNLCK)) }
            return try body(directories)
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
        expectedByteCount: Int64? = nil,
        expectedSHA256: Data? = nil
    ) throws -> SyncRegularFileRead {
        do {
            return try SyncRegularFileReader().read(
                url,
                maximumBytes: maximumAssetBytes,
                expected: .init(byteCount: expectedByteCount, sha256: expectedSHA256)
            )
        } catch let error as SyncRegularFileReadError {
            throw Self.map(error)
        } catch {
            throw CloudAssetStagingError.unavailable
        }
    }

    private struct Manifest: Codable {
        let version: Int
        var references: [CloudAssetUploadReference]
    }

    private func loadManifest(accountDescriptor: Int32) throws -> Manifest {
        let descriptor = Self.manifestName.withCString {
            Darwin.openat(accountDescriptor, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0 {
            if errno == ENOENT { return Manifest(version: Self.manifestVersion, references: []) }
            if errno == ELOOP { throw CloudAssetStagingError.unsafeFile }
            throw CloudAssetStagingError.unavailable
        }
        defer { Darwin.close(descriptor) }
        let data = try readDescriptor(descriptor, maximumBytes: Self.maximumManifestBytes).data
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw CloudAssetStagingError.corruptManifest
        }
        guard manifest.version == Self.manifestVersion else {
            throw CloudAssetStagingError.corruptManifest
        }
        var identities: Set<String> = []
        var mutationIDs: Set<UUID> = []
        var versions: [UUID: SyncAttachmentVersion] = [:]
        for reference in manifest.references {
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
        return manifest
    }

    private func writeManifest(_ manifest: Manifest, accountDescriptor: Int32) throws {
        var normalized = manifest
        normalized.references.sort {
            if $0.mutationID != $1.mutationID {
                return $0.mutationID.uuidString < $1.mutationID.uuidString
            }
            return $0.version.versionID.uuidString < $1.version.versionID.uuidString
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(normalized)
        } catch {
            throw CloudAssetStagingError.corruptManifest
        }
        guard data.count <= Self.maximumManifestBytes else {
            throw CloudAssetStagingError.corruptManifest
        }
        let original = try destinationIdentity(named: Self.manifestName, in: accountDescriptor)
        let temporaryName = ".\(Self.manifestName).\(UUID().uuidString).tmp"
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                accountDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else { throw CloudAssetStagingError.unavailable }
        var removeTemporary = true
        defer {
            Darwin.close(descriptor)
            if removeTemporary {
                _ = temporaryName.withCString { Darwin.unlinkat(accountDescriptor, $0, 0) }
            }
        }
        try Self.writeAll(data, descriptor: descriptor)
        try beforeBoundary(.manifestBeforeFileSync)
        guard Darwin.fsync(descriptor) == 0 else { throw CloudAssetStagingError.unavailable }
        try beforeBoundary(.manifestBeforeRename)
        guard try destinationIdentity(named: Self.manifestName, in: accountDescriptor) == original
        else {
            throw CloudAssetStagingError.unsafeFile
        }
        let result = temporaryName.withCString { temporary in
            Self.manifestName.withCString { destination in
                Darwin.renameat(accountDescriptor, temporary, accountDescriptor, destination)
            }
        }
        guard result == 0 else { throw CloudAssetStagingError.unavailable }
        removeTemporary = false
        try beforeBoundary(.manifestBeforeDirectorySync)
        guard Darwin.fsync(accountDescriptor) == 0 else { throw CloudAssetStagingError.unavailable }
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

    private func createImmutableFile(
        _ data: Data,
        named name: String,
        directoryDescriptor: Int32,
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
        fileSyncBoundary: CloudAssetStagingBoundary,
        renameBoundary: CloudAssetStagingBoundary,
        directorySyncBoundary: CloudAssetStagingBoundary
    ) throws {
        let temporaryName = ".\(name).\(UUID().uuidString).tmp"
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else { throw CloudAssetStagingError.unavailable }
        var removeTemporary = true
        defer {
            Darwin.close(descriptor)
            if removeTemporary {
                _ = temporaryName.withCString { Darwin.unlinkat(directoryDescriptor, $0, 0) }
            }
        }
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
        removeTemporary = false
        try beforeBoundary(directorySyncBoundary)
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw CloudAssetStagingError.unavailable
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
        let read = try readDescriptor(descriptor, maximumBytes: maximumAssetBytes)
        guard read.byteCount == expectedByteCount,
            read.sha256 == expectedSHA256
        else {
            throw CloudAssetStagingError.contentMismatch
        }
    }

    private func readDescriptor(_ descriptor: Int32, maximumBytes: Int) throws -> DescriptorRead {
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
            (before.st_mode & S_IFMT) == S_IFREG,
            before.st_size >= 0
        else {
            throw CloudAssetStagingError.unsafeFile
        }
        guard before.st_size <= maximumBytes else { throw CloudAssetStagingError.tooLarge }
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw CloudAssetStagingError.unavailable }
            guard count > 0 else { break }
            guard data.count <= maximumBytes - count else {
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

        func close() {
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
        var transferredOwnership = false
        defer {
            if !transferredOwnership {
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
        let directories = OpenDirectories(
            root: root,
            accounts: accounts,
            account: account,
            uploads: uploads,
            installed: installed,
            quarantine: quarantine
        )
        transferredOwnership = true
        defer { directories.close() }
        return try body(directories)
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

    private static func openOrCreateLock(in directory: Int32) -> Int32 {
        lockName.withCString {
            Darwin.openat(
                directory,
                $0,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
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

    private func removeRegularFile(
        named name: String,
        from directory: Int32,
        synchronize: Bool = true
    ) throws {
        guard try destinationIdentity(named: name, in: directory) != nil else { return }
        let result = name.withCString { Darwin.unlinkat(directory, $0, 0) }
        guard result == 0 else { throw CloudAssetStagingError.unavailable }
        if synchronize, Darwin.fsync(directory) != 0 {
            throw CloudAssetStagingError.unavailable
        }
    }

    private func directoryEntryNames(_ descriptor: Int32) throws -> [String] {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0, let stream = Darwin.fdopendir(duplicate) else {
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
