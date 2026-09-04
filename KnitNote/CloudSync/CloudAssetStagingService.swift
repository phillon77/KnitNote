import CloudKit
import CryptoKit
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

enum CloudAssetUploadFaultBoundary: Equatable, Sendable {
    case uploadAfterFilePublish
    case acknowledgementAfterManifest
}

enum CloudAssetDownloadFaultBoundary: Equatable, Sendable {
    case installAfterTemporaryFileSync
    case quarantineAfterEvictionManifestCommit
}

protocol CloudAssetUploadStagingBoundary: AnyObject {
    func stageUpload(
        version: SyncAttachmentVersion,
        source: SyncAttachmentSource,
        mutationID: UUID
    ) throws
    func assetForUpload(versionID: UUID, mutationID: UUID) throws -> CKAsset
    func acknowledgeUpload(versionID: UUID, mutationID: UUID) throws
    func reconcile() throws
}

protocol CloudAssetStagingBoundary: CloudAssetUploadStagingBoundary {
    func installDownload(version: SyncAttachmentVersion, sourceURL: URL) throws -> URL
    func quarantine(
        version: SyncAttachmentVersion,
        sourceURL: URL,
        reason: CloudAssetQuarantineReason
    ) throws
}

/// CloudKit-facing upload workflow. The manifest is the only durable reference
/// authority and every mutation owns a separate immutable staged file.
final class CloudAssetStagingService: CloudAssetStagingBoundary, @unchecked Sendable {
    typealias BeforeBoundary = @Sendable (CloudAssetUploadFaultBoundary) throws -> Void
    typealias BeforeDownloadBoundary = @Sendable (
        CloudAssetDownloadFaultBoundary
    ) throws -> Void

    static let defaultMaximumAssetBytes = SyncPublicationFileLimits.maximumAttachmentBytes

    let accountRootURL: URL
    let uploadsRootURL: URL
    let installedRootURL: URL
    let quarantineRootURL: URL

    private let fileStore: CloudAssetAccountFileStore
    private let manifestStore: CloudAssetManifestStore
    private let beforeBoundary: BeforeBoundary
    private let maximumQuarantineEntries: Int
    private let maximumQuarantineBytes: Int64
    private let beforeDownloadBoundary: BeforeDownloadBoundary

    init(
        rootURL: URL,
        accountIdentifier: String,
        maximumAssetBytes: Int = CloudAssetStagingService.defaultMaximumAssetBytes,
        externalReader: any SyncRegularFileReading = SyncRegularFileReader(),
        beforeBoundary: @escaping BeforeBoundary = { _ in },
        maximumQuarantineEntries: Int = 4,
        maximumQuarantineBytes: Int64 = 400_000_000,
        beforeDownloadBoundary: @escaping BeforeDownloadBoundary = { _ in }
    ) throws {
        guard rootURL.isFileURL,
              !accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw CloudAssetStagingError.invalidAccount }
        guard maximumAssetBytes >= 0 else { throw CloudAssetStagingError.tooLarge }
        guard (1...4).contains(maximumQuarantineEntries),
              maximumQuarantineBytes >= 0,
              maximumQuarantineBytes <= 400_000_000
        else { throw CloudAssetStagingError.invalidMetadata }

        do {
            let store = try CloudAssetAccountFileStore(
                rootURL: rootURL,
                accountIdentifier: accountIdentifier,
                maximumAssetBytes: maximumAssetBytes,
                externalReader: externalReader
            )
            fileStore = store
            manifestStore = CloudAssetManifestStore(fileStore: store)
            self.beforeBoundary = beforeBoundary
            self.maximumQuarantineEntries = maximumQuarantineEntries
            self.maximumQuarantineBytes = maximumQuarantineBytes
            self.beforeDownloadBoundary = beforeDownloadBoundary

            let account = rootURL.standardizedFileURL
                .appendingPathComponent("Accounts", isDirectory: true)
                .appendingPathComponent(store.stableAccountBinding, isDirectory: true)
            accountRootURL = account
            uploadsRootURL = account.appendingPathComponent("Uploads", isDirectory: true)
            installedRootURL = account.appendingPathComponent("Installed", isDirectory: true)
            quarantineRootURL = account.appendingPathComponent("Quarantine", isDirectory: true)
        } catch {
            throw Self.map(error)
        }
        try reconcile()
    }

    func stageUpload(
        version: SyncAttachmentVersion,
        source: SyncAttachmentSource,
        mutationID: UUID
    ) throws {
        let version = try validate(version)
        try validate(source, against: version)
        let filename = Self.filename(mutationID: mutationID, versionID: version.versionID)

        do {
            try fileStore.withAccountLock { directories in
                var references = try reconcileUploads(in: directories)
                if let existing = references.first(where: { $0.mutationID == mutationID }) {
                    guard existing.version == version,
                          existing.relativeFilename == filename
                    else { throw CloudAssetStagingError.immutableIdentityMismatch }
                    try verify(existing, in: directories)
                    return
                }
                guard references.allSatisfy({
                    $0.version.versionID != version.versionID || $0.version == version
                }) else { throw CloudAssetStagingError.immutableIdentityMismatch }

                let data = try fileStore.readExternal(
                    source.fileURL,
                    expectedByteCount: version.byteCount,
                    expectedSHA256: version.contentSHA256
                )
                do {
                    try fileStore.publishNoClobber(data, named: filename, in: directories.uploads)
                } catch CloudAssetFileStoreError.alreadyExists {
                    throw CloudAssetStagingError.immutableIdentityMismatch
                }
                _ = try fileStore.readOwned(
                    named: filename,
                    in: directories.uploads,
                    expectedByteCount: version.byteCount,
                    expectedSHA256: version.contentSHA256
                )
                try beforeBoundary(.uploadAfterFilePublish)
                references.append(
                    CloudAssetUploadReference(
                        mutationID: mutationID,
                        version: version,
                        relativeFilename: filename
                    )
                )
                try manifestStore.commitUploads(references, in: directories)
            }
        } catch {
            throw Self.map(error)
        }
    }

    /// A new CKAsset object is created for each save attempt while its URL is
    /// stable until acknowledgement removes the exact manifest reference.
    func assetForUpload(versionID: UUID, mutationID: UUID) throws -> CKAsset {
        do {
            return try fileStore.withAccountLock { directories in
                let references = try reconcileUploads(in: directories)
                guard let reference = references.first(where: { $0.mutationID == mutationID })
                else { throw CloudAssetStagingError.unknownUpload }
                guard reference.version.versionID == versionID
                else { throw CloudAssetStagingError.immutableIdentityMismatch }
                try verify(reference, in: directories)
                return CKAsset(
                    fileURL: uploadsRootURL.appendingPathComponent(reference.relativeFilename)
                )
            }
        } catch {
            throw Self.map(error)
        }
    }

    func acknowledgeUpload(versionID: UUID, mutationID: UUID) throws {
        do {
            try fileStore.withAccountLock { directories in
                var references = try reconcileUploads(in: directories)
                guard let index = references.firstIndex(where: { $0.mutationID == mutationID }) else {
                    return
                }
                let reference = references[index]
                guard reference.version.versionID == versionID
                else { throw CloudAssetStagingError.immutableIdentityMismatch }

                references.remove(at: index)
                try manifestStore.commitUploads(references, in: directories)
                try beforeBoundary(.acknowledgementAfterManifest)

                if try fileStore.ownedFileExists(
                    named: reference.relativeFilename,
                    in: directories.uploads
                ) {
                    try fileStore.removeOwned(
                        named: reference.relativeFilename,
                        in: directories.uploads
                    )
                }
            }
        } catch {
            throw Self.map(error)
        }
    }

    func installDownload(version: SyncAttachmentVersion, sourceURL: URL) throws -> URL {
        let version = try validate(version)
        guard sourceURL.isFileURL else { throw CloudAssetStagingError.invalidMetadata }
        let filename = Self.installedFilename(versionID: version.versionID)

        do {
            return try fileStore.withAccountLock { directories in
                try reconcileInstalled(in: directories)
                var quarantineReferences = try reconcileQuarantine(in: directories)
                let observed = try fileStore.readExternalObserved(
                    sourceURL,
                    maximumByteCount: Int(version.byteCount)
                )
                if observed.byteCount != version.byteCount {
                    try quarantine(
                        observed: observed,
                        version: version,
                        reason: .byteCountMismatch,
                        references: &quarantineReferences,
                        in: directories
                    )
                    throw CloudAssetStagingError.contentMismatch
                }
                if observed.sha256 != version.contentSHA256 {
                    try quarantine(
                        observed: observed,
                        version: version,
                        reason: .contentHashMismatch,
                        references: &quarantineReferences,
                        in: directories
                    )
                    throw CloudAssetStagingError.contentMismatch
                }

                if try fileStore.ownedFileExists(named: filename, in: directories.installed) {
                    do {
                        _ = try fileStore.readOwned(
                            named: filename,
                            in: directories.installed,
                            expectedByteCount: version.byteCount,
                            expectedSHA256: version.contentSHA256
                        )
                    } catch CloudAssetFileStoreError.contentMismatch {
                        throw CloudAssetStagingError.immutableIdentityMismatch
                    } catch CloudAssetFileStoreError.tooLarge {
                        throw CloudAssetStagingError.immutableIdentityMismatch
                    }
                    return installedRootURL.appendingPathComponent(filename)
                }

                do {
                    try fileStore.publishNoClobber(
                        observed.data,
                        named: filename,
                        in: directories.installed,
                        afterTemporaryFileSync: { [beforeDownloadBoundary] in
                            try beforeDownloadBoundary(.installAfterTemporaryFileSync)
                        }
                    )
                } catch CloudAssetFileStoreError.alreadyExists {
                    do {
                        _ = try fileStore.readOwned(
                            named: filename,
                            in: directories.installed,
                            expectedByteCount: version.byteCount,
                            expectedSHA256: version.contentSHA256
                        )
                    } catch {
                        throw CloudAssetStagingError.immutableIdentityMismatch
                    }
                }
                _ = try fileStore.readOwned(
                    named: filename,
                    in: directories.installed,
                    expectedByteCount: version.byteCount,
                    expectedSHA256: version.contentSHA256
                )
                return installedRootURL.appendingPathComponent(filename)
            }
        } catch {
            throw Self.map(error)
        }
    }

    func quarantine(
        version: SyncAttachmentVersion,
        sourceURL: URL,
        reason: CloudAssetQuarantineReason
    ) throws {
        let version = try validate(version)
        guard sourceURL.isFileURL else { throw CloudAssetStagingError.invalidMetadata }
        do {
            try fileStore.withAccountLock { directories in
                var references = try reconcileQuarantine(in: directories)
                let observed = try fileStore.readExternalObserved(
                    sourceURL,
                    maximumByteCount: Int(version.byteCount)
                )
                switch reason {
                case .byteCountMismatch:
                    guard observed.byteCount != version.byteCount else {
                        throw CloudAssetStagingError.invalidMetadata
                    }
                case .contentHashMismatch:
                    guard observed.byteCount == version.byteCount,
                          observed.sha256 != version.contentSHA256
                    else { throw CloudAssetStagingError.invalidMetadata }
                }
                try quarantine(
                    observed: observed,
                    version: version,
                    reason: reason,
                    references: &references,
                    in: directories
                )
            }
        } catch {
            throw Self.map(error)
        }
    }

    func reconcile() throws {
        do {
            try fileStore.withAccountLock { directories in
                _ = try reconcileUploads(in: directories)
                try reconcileInstalled(in: directories)
                _ = try reconcileQuarantine(in: directories)
            }
        } catch {
            throw Self.map(error)
        }
    }

    private func reconcileInstalled(in directories: CloudAssetAccountDirectories) throws {
        for name in try fileStore.listOwned(in: directories.installed) {
            if Self.isInstalledFilename(name) { continue }
            guard Self.isTemporaryFilename(name) else {
                throw CloudAssetStagingError.unsafeFile
            }
            try fileStore.removeOwned(named: name, in: directories.installed)
        }
    }

    private func reconcileQuarantine(
        in directories: CloudAssetAccountDirectories
    ) throws -> [CloudAssetQuarantineReference] {
        let references = try manifestStore.loadQuarantine(in: directories)
        for reference in references {
            _ = try fileStore.readOwned(
                named: reference.relativeFilename,
                in: directories.quarantine,
                expectedByteCount: reference.byteCount,
                expectedSHA256: reference.contentSHA256
            )
        }
        let referenced = Set(references.map(\.relativeFilename))
        for name in try fileStore.listOwned(in: directories.quarantine) {
            if name == "manifest.json" || referenced.contains(name) { continue }
            guard Self.isQuarantineFilename(name) || Self.isTemporaryFilename(name) else {
                throw CloudAssetStagingError.unsafeFile
            }
            try fileStore.removeOwned(named: name, in: directories.quarantine)
        }
        return references
    }

    private func quarantine(
        observed: SyncRegularFileRead,
        version: SyncAttachmentVersion,
        reason: CloudAssetQuarantineReason,
        references: inout [CloudAssetQuarantineReference],
        in directories: CloudAssetAccountDirectories
    ) throws {
        let identifier = UUID()
        let reference = CloudAssetQuarantineReference(
            id: identifier,
            createdAt: Date(),
            versionID: version.versionID,
            reason: reason,
            byteCount: observed.byteCount,
            contentSHA256: observed.sha256,
            relativeFilename: Self.quarantineFilename(id: identifier)
        )
        var retained = references.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        var evicted: [CloudAssetQuarantineReference] = []
        var total = retained.reduce(Int64(0)) { $0 + $1.byteCount }
        while retained.count + 1 > maximumQuarantineEntries
            || total + observed.byteCount > maximumQuarantineBytes
        {
            guard !retained.isEmpty else { throw CloudAssetStagingError.tooLarge }
            let oldest = retained.removeFirst()
            evicted.append(oldest)
            total -= oldest.byteCount
        }

        if !evicted.isEmpty {
            try manifestStore.commitQuarantine(retained, in: directories)
            try beforeDownloadBoundary(.quarantineAfterEvictionManifestCommit)
            for old in evicted {
                try fileStore.removeOwned(
                    named: old.relativeFilename,
                    in: directories.quarantine
                )
            }
        }

        try fileStore.publishNoClobber(
            observed.data,
            named: reference.relativeFilename,
            in: directories.quarantine
        )
        retained.append(reference)
        try manifestStore.commitQuarantine(retained, in: directories)
        references = retained
    }

    private func reconcileUploads(
        in directories: CloudAssetAccountDirectories
    ) throws -> [CloudAssetUploadReference] {
        let references = try manifestStore.loadUploads(in: directories)
        for reference in references {
            try verify(reference, in: directories)
        }

        let referenced = Set(references.map(\.relativeFilename))
        for name in try fileStore.listOwned(in: directories.uploads) {
            if referenced.contains(name) { continue }
            guard Self.isUploadFilename(name) || Self.isTemporaryFilename(name) else {
                throw CloudAssetStagingError.unsafeFile
            }
            try fileStore.removeOwned(named: name, in: directories.uploads)
        }
        return references
    }

    private func verify(
        _ reference: CloudAssetUploadReference,
        in directories: CloudAssetAccountDirectories
    ) throws {
        let expected = Self.filename(
            mutationID: reference.mutationID,
            versionID: reference.version.versionID
        )
        guard reference.relativeFilename == expected
        else { throw CloudAssetStagingError.corruptManifest }
        _ = try fileStore.readOwned(
            named: reference.relativeFilename,
            in: directories.uploads,
            expectedByteCount: reference.version.byteCount,
            expectedSHA256: reference.version.contentSHA256
        )
    }

    private func validate(_ version: SyncAttachmentVersion) throws -> SyncAttachmentVersion {
        do {
            let result = try version.validated()
            guard result.byteCount <= Int64(SyncPublicationFileLimits.maximumAttachmentBytes)
            else { throw CloudAssetStagingError.tooLarge }
            return result
        } catch let error as CloudAssetStagingError {
            throw error
        } catch {
            throw CloudAssetStagingError.invalidMetadata
        }
    }

    private func validate(
        _ source: SyncAttachmentSource,
        against version: SyncAttachmentVersion
    ) throws {
        guard source.fileURL.isFileURL,
              source.byteCount >= 0,
              source.contentSHA256.count == SHA256.byteCount
        else { throw CloudAssetStagingError.invalidMetadata }
        guard source.byteCount == version.byteCount,
              source.contentSHA256 == version.contentSHA256
        else { throw CloudAssetStagingError.contentMismatch }
    }

    private static func filename(mutationID: UUID, versionID: UUID) -> String {
        "\(mutationID.uuidString.lowercased())-\(versionID.uuidString.lowercased()).asset"
    }

    private static func installedFilename(versionID: UUID) -> String {
        "\(versionID.uuidString.lowercased()).asset"
    }

    private static func quarantineFilename(id: UUID) -> String {
        "\(id.uuidString.lowercased()).asset"
    }

    private static func isInstalledFilename(_ name: String) -> Bool {
        isQuarantineFilename(name)
    }

    private static func isQuarantineFilename(_ name: String) -> Bool {
        guard name.hasSuffix(".asset"), name.count == 36 + 6 else { return false }
        let identifier = String(name.prefix(36))
        return UUID(uuidString: identifier) != nil && identifier == identifier.lowercased()
    }

    private static func isUploadFilename(_ name: String) -> Bool {
        guard name.hasSuffix(".asset"), name.count == 36 + 1 + 36 + 6 else { return false }
        let first = String(name.prefix(36))
        let separator = name.index(name.startIndex, offsetBy: 36)
        let secondStart = name.index(after: separator)
        let secondEnd = name.index(secondStart, offsetBy: 36)
        let second = String(name[secondStart..<secondEnd])
        return name[separator] == "-"
            && UUID(uuidString: first) != nil
            && UUID(uuidString: second) != nil
            && first == first.lowercased()
            && second == second.lowercased()
    }

    private static func isTemporaryFilename(_ name: String) -> Bool {
        guard name.hasPrefix(".tmp-"), name.count == 5 + 36 else { return false }
        let id = String(name.dropFirst(5))
        return UUID(uuidString: id) != nil && id == id.lowercased()
    }

    private static func map(_ error: Error) -> CloudAssetStagingError {
        if let error = error as? CloudAssetStagingError { return error }
        if let error = error as? CloudAssetManifestStoreError {
            return switch error {
            case .corruptManifest: .corruptManifest
            case .immutableIdentityMismatch: .immutableIdentityMismatch
            case .quarantineLimitExceeded: .corruptManifest
            case .unavailable: .unavailable
            }
        }
        if let error = error as? CloudAssetFileStoreError {
            return switch error {
            case .invalidAccount: .invalidAccount
            case .unsafeFile: .unsafeFile
            case .tooLarge: .tooLarge
            case .contentMismatch: .contentMismatch
            case .alreadyExists: .immutableIdentityMismatch
            case .unavailable: .unavailable
            }
        }
        return .unavailable
    }
}
