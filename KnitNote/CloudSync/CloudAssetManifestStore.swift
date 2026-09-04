import CryptoKit
import Foundation

enum CloudAssetManifestStoreError: Error, Equatable {
    case corruptManifest
    case immutableIdentityMismatch
    case quarantineLimitExceeded
    case unavailable
}

struct CloudAssetUploadReference: Codable, Equatable, Sendable {
    let mutationID: UUID
    let version: SyncAttachmentVersion
    let relativeFilename: String
}

enum CloudAssetQuarantineReason: String, Codable, Equatable, Sendable {
    case byteCountMismatch
    case contentHashMismatch
}

struct CloudAssetQuarantineReference: Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let versionID: UUID
    let reason: CloudAssetQuarantineReason
    let byteCount: Int64
    let contentSHA256: Data
    let relativeFilename: String
}

struct CloudAssetManifestSnapshot: Equatable, Sendable {
    var uploads: [CloudAssetUploadReference]
    var quarantine: [CloudAssetQuarantineReference]
}

/// Owns two intentionally independent manifest authorities. Upload corruption
/// cannot prevent quarantine inspection, and quarantine corruption cannot
/// prevent upload acknowledgement.
final class CloudAssetManifestStore {
    private static let schemaVersion = 1
    private static let uploadManifestName = "manifest.json"
    private static let quarantineManifestName = "manifest.json"
    private static let uploadDomain = "knitnote.cloud-asset.upload-manifest.v1"
    private static let quarantineDomain = "knitnote.cloud-asset.quarantine-manifest.v1"
    private static let defaultMaximumManifestBytes = 16 * 1_024 * 1_024
    private static let maximumQuarantineEntries = 4
    private static let maximumQuarantineBytes: Int64 = 400_000_000

    private let fileStore: CloudAssetAccountFileStore
    private let maximumManifestBytes: Int

    init(
        fileStore: CloudAssetAccountFileStore,
        maximumManifestBytes: Int = CloudAssetManifestStore.defaultMaximumManifestBytes
    ) {
        self.fileStore = fileStore
        self.maximumManifestBytes = max(0, maximumManifestBytes)
    }

    func loadUploads(in directories: CloudAssetAccountDirectories) throws
        -> [CloudAssetUploadReference]
    {
        let payload: UploadPayload = try load(
            name: Self.uploadManifestName,
            directory: directories.account,
            finalDirectory: directories.uploads,
            domain: Self.uploadDomain,
            isFinalName: Self.isUploadFilename,
            empty: UploadPayload(
                schemaVersion: Self.schemaVersion,
                accountBinding: fileStore.stableAccountBinding,
                entries: []
            )
        )
        try validate(payload)
        return payload.entries
    }

    func commitUploads(
        _ references: [CloudAssetUploadReference],
        in directories: CloudAssetAccountDirectories
    ) throws {
        let payload = UploadPayload(
            schemaVersion: Self.schemaVersion,
            accountBinding: fileStore.stableAccountBinding,
            entries: Self.sortedUploads(references)
        )
        try validate(payload)
        try commit(
            payload,
            name: Self.uploadManifestName,
            directory: directories.account,
            domain: Self.uploadDomain
        )
    }

    func loadQuarantine(in directories: CloudAssetAccountDirectories) throws
        -> [CloudAssetQuarantineReference]
    {
        let payload: QuarantinePayload = try load(
            name: Self.quarantineManifestName,
            directory: directories.quarantine,
            finalDirectory: directories.quarantine,
            domain: Self.quarantineDomain,
            isFinalName: Self.isQuarantineFilename,
            empty: QuarantinePayload(
                schemaVersion: Self.schemaVersion,
                accountBinding: fileStore.stableAccountBinding,
                entries: []
            )
        )
        try validate(payload)
        return payload.entries
    }

    func commitQuarantine(
        _ references: [CloudAssetQuarantineReference],
        in directories: CloudAssetAccountDirectories
    ) throws {
        let payload = QuarantinePayload(
            schemaVersion: Self.schemaVersion,
            accountBinding: fileStore.stableAccountBinding,
            entries: Self.sortedQuarantine(references)
        )
        try validate(payload)
        try commit(
            payload,
            name: Self.quarantineManifestName,
            directory: directories.quarantine,
            domain: Self.quarantineDomain
        )
    }

    private struct Envelope: Codable, Equatable {
        let integrityVersion: Int
        let checksum: Data
        let payload: Data
    }

    private struct UploadPayload: Codable, Equatable {
        let schemaVersion: Int
        let accountBinding: String
        let entries: [CloudAssetUploadReference]
    }

    private struct QuarantinePayload: Codable, Equatable {
        let schemaVersion: Int
        let accountBinding: String
        let entries: [CloudAssetQuarantineReference]
    }

    private func load<Payload: Codable & Equatable>(
        name: String,
        directory: Int32,
        finalDirectory: Int32,
        domain: String,
        isFinalName: (String) -> Bool,
        empty: Payload
    ) throws -> Payload {
        do {
            try fileStore.recoverAtomicReplacement(
                named: name,
                in: directory,
                transactionDomain: "\(domain).transaction"
            )
        } catch { throw map(error) }
        let exists: Bool
        do { exists = try fileStore.ownedFileExists(named: name, in: directory) }
        catch { throw map(error) }
        guard exists else {
            let finalNames: [String]
            do { finalNames = try fileStore.listOwned(in: finalDirectory) }
            catch { throw map(error) }
            guard !finalNames.contains(where: isFinalName) else {
                throw CloudAssetManifestStoreError.corruptManifest
            }
            return empty
        }

        let data: Data
        do {
            data = try fileStore.readOwned(
                named: name,
                in: directory,
                maximumByteCount: maximumManifestBytes
            )
        } catch { throw map(error) }
        do {
            let envelope = try decoder().decode(Envelope.self, from: data)
            guard envelope.integrityVersion == Self.schemaVersion,
                  envelope.checksum.count == SHA256.byteCount,
                  envelope.checksum == Self.checksum(domain: domain, payload: envelope.payload),
                  try encoder().encode(envelope) == data
            else { throw CloudAssetManifestStoreError.corruptManifest }
            let payload = try decoder().decode(Payload.self, from: envelope.payload)
            guard try encoder().encode(payload) == envelope.payload else {
                throw CloudAssetManifestStoreError.corruptManifest
            }
            return payload
        } catch let error as CloudAssetManifestStoreError {
            throw error
        } catch {
            throw CloudAssetManifestStoreError.corruptManifest
        }
    }

    private func commit<Payload: Codable>(
        _ payload: Payload,
        name: String,
        directory: Int32,
        domain: String
    ) throws {
        do {
            let payloadData = try encoder().encode(payload)
            let envelope = Envelope(
                integrityVersion: Self.schemaVersion,
                checksum: Self.checksum(domain: domain, payload: payloadData),
                payload: payloadData
            )
            let envelopeData = try encoder().encode(envelope)
            guard envelopeData.count <= maximumManifestBytes else {
                throw CloudAssetManifestStoreError.corruptManifest
            }
            try fileStore.replaceAtomically(
                envelopeData,
                named: name,
                in: directory,
                transactionDomain: "\(domain).transaction"
            )
        } catch let error as CloudAssetManifestStoreError {
            throw error
        } catch {
            throw map(error)
        }
    }

    private func validate(_ payload: UploadPayload) throws {
        guard payload.schemaVersion == Self.schemaVersion,
              payload.accountBinding == fileStore.stableAccountBinding,
              payload.entries == Self.sortedUploads(payload.entries)
        else { throw CloudAssetManifestStoreError.corruptManifest }
        var mutations: Set<UUID> = []
        var filenames: Set<String> = []
        for reference in payload.entries {
            let validated: SyncAttachmentVersion
            do { validated = try reference.version.validated() }
            catch { throw CloudAssetManifestStoreError.corruptManifest }
            guard validated.byteCount <= Int64(SyncPublicationFileLimits.maximumAttachmentBytes),
                  mutations.insert(reference.mutationID).inserted,
                  filenames.insert(reference.relativeFilename).inserted
            else { throw CloudAssetManifestStoreError.corruptManifest }
            guard Self.isUploadFilename(reference.relativeFilename) else {
                throw CloudAssetManifestStoreError.corruptManifest
            }
            let expected = "\(reference.mutationID.uuidString.lowercased())-\(validated.versionID.uuidString.lowercased()).asset"
            guard reference.relativeFilename == expected else {
                throw CloudAssetManifestStoreError.immutableIdentityMismatch
            }
        }
    }

    private func validate(_ payload: QuarantinePayload) throws {
        guard payload.schemaVersion == Self.schemaVersion,
              payload.accountBinding == fileStore.stableAccountBinding,
              payload.entries == Self.sortedQuarantine(payload.entries)
        else { throw CloudAssetManifestStoreError.corruptManifest }
        guard payload.entries.count <= Self.maximumQuarantineEntries else {
            throw CloudAssetManifestStoreError.quarantineLimitExceeded
        }
        var ids: Set<UUID> = []
        var filenames: Set<String> = []
        var total: Int64 = 0
        for reference in payload.entries {
            guard reference.byteCount >= 0,
                  reference.byteCount <= Int64(SyncPublicationFileLimits.maximumAttachmentBytes),
                  reference.contentSHA256.count == SHA256.byteCount,
                  ids.insert(reference.id).inserted,
                  filenames.insert(reference.relativeFilename).inserted,
                  reference.relativeFilename == "\(reference.id.uuidString.lowercased()).asset",
                  reference.createdAt.timeIntervalSinceReferenceDate.isFinite
            else { throw CloudAssetManifestStoreError.corruptManifest }
            let addition = total.addingReportingOverflow(reference.byteCount)
            guard !addition.overflow, addition.partialValue <= Self.maximumQuarantineBytes else {
                throw CloudAssetManifestStoreError.quarantineLimitExceeded
            }
            total = addition.partialValue
        }
    }

    private static func sortedUploads(
        _ values: [CloudAssetUploadReference]
    ) -> [CloudAssetUploadReference] {
        values.sorted {
            if $0.mutationID != $1.mutationID {
                return $0.mutationID.uuidString < $1.mutationID.uuidString
            }
            return $0.version.versionID.uuidString < $1.version.versionID.uuidString
        }
    }

    private static func sortedQuarantine(
        _ values: [CloudAssetQuarantineReference]
    ) -> [CloudAssetQuarantineReference] {
        values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func checksum(domain: String, payload: Data) -> Data {
        var material = Data(domain.utf8)
        material.append(0)
        material.append(payload)
        return Data(SHA256.hash(data: material))
    }

    private static func isUploadFilename(_ name: String) -> Bool {
        let parts = name.dropLast(".asset".count).split(separator: "-", omittingEmptySubsequences: false)
        guard name.hasSuffix(".asset"), parts.count == 10 else { return false }
        let prefixCount = 36
        guard name.count == prefixCount + 1 + prefixCount + ".asset".count else { return false }
        let first = String(name.prefix(prefixCount))
        let secondStart = name.index(name.startIndex, offsetBy: prefixCount + 1)
        let second = String(name[secondStart..<name.index(secondStart, offsetBy: prefixCount)])
        return UUID(uuidString: first) != nil && UUID(uuidString: second) != nil
            && first == first.lowercased() && second == second.lowercased()
    }

    private static func isQuarantineFilename(_ name: String) -> Bool {
        guard name.hasSuffix(".asset"), name.count == 36 + ".asset".count else { return false }
        let id = String(name.prefix(36))
        return UUID(uuidString: id) != nil && id == id.lowercased()
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private func map(_ error: Error) -> CloudAssetManifestStoreError {
        if let error = error as? CloudAssetManifestStoreError { return error }
        if let error = error as? CloudAssetFileStoreError {
            switch error {
            case .unsafeFile, .contentMismatch, .tooLarge:
                return .corruptManifest
            case .invalidAccount, .alreadyExists, .unavailable:
                return .unavailable
            }
        }
        return .unavailable
    }
}
