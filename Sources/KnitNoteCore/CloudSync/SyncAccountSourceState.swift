import CryptoKit
import Foundation

struct SyncAccountSourceFileProof: Codable, Equatable, Sendable {
    let relativePath: String
    let isDirectory: Bool
    let byteCount: Int64
    let sha256: Data
}

enum SyncAccountSourceOrigin: Codable, Equatable, Sendable {
    case freshAllocation(allocationID: UUID)
    case restoredSelection(vaultID: UUID, captureID: UUID,
        envelopeSHA256: Data, packetSHA256: Data, deletionSHA256: Data?)
    case bootstrapRollback(transactionID: UUID, activeRelativePath: String, activeEnvelopeSHA256: Data)

    private enum Keys: String, CodingKey {
        case kind, allocationID, vaultID, captureID, envelopeSHA256, packetSHA256, deletionSHA256
        case transactionID, activeRelativePath, activeEnvelopeSHA256
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "freshAllocation": self = .freshAllocation(allocationID: try c.decode(UUID.self, forKey: .allocationID))
        case "restoredSelection": self = .restoredSelection(vaultID: try c.decode(UUID.self, forKey: .vaultID),
            captureID: try c.decode(UUID.self, forKey: .captureID), envelopeSHA256: try c.decode(Data.self, forKey: .envelopeSHA256),
            packetSHA256: try c.decode(Data.self, forKey: .packetSHA256), deletionSHA256: try c.decodeIfPresent(Data.self, forKey: .deletionSHA256))
        case "bootstrapRollback": self = .bootstrapRollback(transactionID: try c.decode(UUID.self, forKey: .transactionID),
            activeRelativePath: try c.decode(String.self, forKey: .activeRelativePath),
            activeEnvelopeSHA256: try c.decode(Data.self, forKey: .activeEnvelopeSHA256))
        default: throw SyncAccountRecoveryTransaction.Error.invalidAuthority
        }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .freshAllocation(let allocationID):
            try c.encode("freshAllocation", forKey: .kind); try c.encode(allocationID, forKey: .allocationID)
        case .restoredSelection(let vaultID, let captureID, let envelope, let packet, let deletion):
            try c.encode("restoredSelection", forKey: .kind); try c.encode(vaultID, forKey: .vaultID)
            try c.encode(captureID, forKey: .captureID); try c.encode(envelope, forKey: .envelopeSHA256)
            try c.encode(packet, forKey: .packetSHA256); try c.encodeIfPresent(deletion, forKey: .deletionSHA256)
        case .bootstrapRollback(let transactionID, let path, let envelope):
            try c.encode("bootstrapRollback", forKey: .kind); try c.encode(transactionID, forKey: .transactionID)
            try c.encode(path, forKey: .activeRelativePath); try c.encode(envelope, forKey: .activeEnvelopeSHA256)
        }
    }
}

struct SyncAccountSourceState: Codable, Equatable, Sendable {
    let authorityID: UUID
    let generation: UUID
    let accountIDHash: String
    let accountRoot: URL
    let accountDevice: UInt64
    let accountInode: UInt64
    let archiveURL: URL
    let journalURL: URL
    let baselineSHA256: Data
    let origin: SyncAccountSourceOrigin
}

struct SyncAccountSourceEvidence: Codable, Equatable, Sendable {
    let state: SyncAccountSourceState
    let rollbackEnvelope: Data?
    private enum CodingKeys: String, CodingKey { case state, rollbackEnvelope }
    init(state: SyncAccountSourceState, rollbackEnvelope: Data?) {
        self.state = state; self.rollbackEnvelope = rollbackEnvelope
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(SyncAccountSourceState.self, forKey: .state)
        rollbackEnvelope = try c.decodeIfPresent(Data.self, forKey: .rollbackEnvelope)
        var keys: Set<String> = ["state"]
        if case .bootstrapRollback = state.origin {
            guard rollbackEnvelope != nil else { throw SyncAccountRecoveryInventory.Error.unsafeBinding }
            keys.insert("rollbackEnvelope")
        } else if rollbackEnvelope != nil { throw SyncAccountRecoveryInventory.Error.unsafeBinding }
        try SourceEvidenceKey.require(keys, from: decoder)
        let sourceDecoder = try c.superDecoder(forKey: .state)
        try SourceEvidenceKey.require(["authorityID", "generation", "accountIDHash", "accountRoot",
            "accountDevice", "accountInode", "archiveURL", "journalURL", "baselineSHA256", "origin"], from: sourceDecoder)
        let source = try sourceDecoder.container(keyedBy: SourceEvidenceKey.self)
        let origin = try source.superDecoder(forKey: .init(stringValue: "origin")!)
        let originKeys: Set<String>
        switch state.origin {
        case .freshAllocation: originKeys = ["kind", "allocationID"]
        case .bootstrapRollback: originKeys = ["kind", "transactionID", "activeRelativePath", "activeEnvelopeSHA256"]
        case .restoredSelection(_, _, _, _, let deletion):
            originKeys = Set(["kind", "vaultID", "captureID", "envelopeSHA256", "packetSHA256"])
                .union(deletion == nil ? [] : ["deletionSHA256"])
        }
        try SourceEvidenceKey.require(originKeys, from: origin)
        try SyncAccountRecoveryControlFile.validate(state)
    }
}

enum SyncAccountRecoverySourceAuthority: Codable, Equatable, Sendable {
    case archive(relativePath: String, sha256: Data)
    case absent(SyncAccountSourceEvidence)

    private enum Keys: String, CodingKey { case kind, relativePath, sha256, evidence }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "archive":
            try SourceEvidenceKey.require(["kind", "relativePath", "sha256"], from: decoder)
            let sha256 = try c.decode(Data.self, forKey: .sha256)
            guard sha256.count == 32 else { throw SyncAccountRecoveryInventory.Error.unsafeBinding }
            self = .archive(relativePath: try c.decode(String.self, forKey: .relativePath), sha256: sha256)
        case "absent":
            try SourceEvidenceKey.require(["kind", "evidence"], from: decoder)
            self = .absent(try c.decode(SyncAccountSourceEvidence.self, forKey: .evidence))
        default: throw SyncAccountRecoveryInventory.Error.unsafeBinding
        }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .archive(let path, let digest):
            try c.encode("archive", forKey: .kind); try c.encode(path, forKey: .relativePath); try c.encode(digest, forKey: .sha256)
        case .absent(let evidence):
            try c.encode("absent", forKey: .kind); try c.encode(evidence, forKey: .evidence)
        }
    }
}

private struct SourceEvidenceKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    static func require(_ keys: Set<String>, from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Self.self)
        guard Set(c.allKeys.map(\.stringValue)) == keys else { throw SyncAccountRecoveryInventory.Error.unsafeBinding }
    }
}

enum SyncAccountSourceBaseline {
    /// Only portable source proofs join this digest. Complete inventory and
    /// dependency authentication remain the owning transaction's responsibility.
    static func digest(entries: [SyncAccountRecoveryInventory.Entry], accountRoot: URL, journalURL: URL,
                       mutations: [SyncMutation], selectedFiles: [SyncPendingRecoveryPacket.File],
                       deletionLedger: Data?, pendingMarkerVersions: [SyncRecordVersion]) throws -> Data {
        let prefix = accountRoot.path + "/"
        guard accountRoot.isFileURL, journalURL.isFileURL, journalURL.path.hasPrefix(prefix) else {
            throw SyncAccountRecoveryTransaction.Error.invalidAuthority
        }
        let journal = String(journalURL.path.dropFirst(prefix.count))
        let selected = Set(selectedFiles.map(\.relativePath))
        func isJournal(_ path: String) -> Bool {
            // FileSyncMutationJournal locks its parent descriptor (no .lock
            // sibling), and emits these three suffixes plus bounded proof shards.
            if path == journal || [".checkpoint", ".segment", ".migrated"].contains(where: { path == journal + $0 }) { return true }
            let proofPrefix = journal + ".proofs."
            guard path.hasPrefix(proofPrefix) else { return false }
            let suffix = path.dropFirst(proofPrefix.count)
            return suffix.count == 8 && suffix.allSatisfy { $0.isASCII && $0.isNumber }
                && (Int(suffix).map { $0 < 1_000_000 } ?? false)
        }
        let proofs = entries.filter {
            $0.relativePath.hasPrefix("working-set/") || selected.contains($0.relativePath) || isJournal($0.relativePath)
        }.map {
            SyncAccountSourceFileProof(relativePath: $0.relativePath, isDirectory: $0.isDirectory,
                byteCount: $0.byteCount, sha256: $0.sha256)
        }.sorted { $0.relativePath < $1.relativePath }
        struct Projection: Encodable {
            let proofs: [SyncAccountSourceFileProof]
            let mutations: [SyncMutation]
            let deletionLedger: Data?
            let pendingMarkerVersions: [SyncRecordVersion]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Data(SHA256.hash(data: try encoder.encode(Projection(proofs: proofs, mutations: mutations,
            deletionLedger: deletionLedger, pendingMarkerVersions: pendingMarkerVersions))))
    }
}
