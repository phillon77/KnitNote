import CryptoKit
import Foundation

/// Complete canonical authority, including acknowledged record history. The
/// archive digest binds this authority to one committed domain snapshot.
public struct SyncCanonicalCheckpoint: Codable, Equatable, Sendable {
    private static let legacyFormatVersion = 1
    private static let receiptFormatVersion = 2
    private static let maximumReceiptCount = 4_096

    public let formatVersion: Int
    public let accountIDHash: String
    public let commitID: UUID
    public let archiveSHA256: Data
    public let records: [SyncRecord]
    public let legacyRecordIDsToDelete: Set<SyncEntityID>
    public let remoteBatchReceipts: [SyncRemoteBatchReceipt]
    public static let maximumBytes = 100_000_000

    public init(accountIDHash: String, commitID: UUID, archiveSHA256: Data,
                records: [SyncRecord], legacyRecordIDsToDelete: Set<SyncEntityID>,
                remoteBatchReceipts: [SyncRemoteBatchReceipt] = []) throws {
        try self.init(
            formatVersion: remoteBatchReceipts.isEmpty
                ? Self.legacyFormatVersion : Self.receiptFormatVersion,
            accountIDHash: accountIDHash,
            commitID: commitID,
            archiveSHA256: archiveSHA256,
            records: records,
            legacyRecordIDsToDelete: legacyRecordIDsToDelete,
            remoteBatchReceipts: remoteBatchReceipts
        )
    }

    private init(formatVersion: Int, accountIDHash: String, commitID: UUID,
                 archiveSHA256: Data, records: [SyncRecord],
                 legacyRecordIDsToDelete: Set<SyncEntityID>,
                 remoteBatchReceipts: [SyncRemoteBatchReceipt]) throws {
        self.formatVersion = formatVersion
        self.accountIDHash = accountIDHash
        self.commitID = commitID
        self.archiveSHA256 = archiveSHA256
        self.records = records.sorted { Self.entityLess($0.id, $1.id) }
        self.legacyRecordIDsToDelete = legacyRecordIDsToDelete
        self.remoteBatchReceipts = remoteBatchReceipts.sorted(by: Self.receiptLess)
        _ = try validated()
    }

    public func validated() throws -> Self {
        guard [Self.legacyFormatVersion, Self.receiptFormatVersion].contains(formatVersion),
              accountIDHash.utf8.count == 64,
              accountIDHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              archiveSHA256.count == 32,
              formatVersion != Self.legacyFormatVersion || remoteBatchReceipts.isEmpty,
              remoteBatchReceipts.count <= Self.maximumReceiptCount,
              remoteBatchReceipts == remoteBatchReceipts.sorted(by: Self.receiptLess),
              Set(remoteBatchReceipts.map(Self.receiptKey)).count == remoteBatchReceipts.count else {
            throw SyncPublicationError.corruptTransaction
        }
        let validatedRecords = try SyncRecordValidator().validate(records)
        guard Set(validatedRecords.map(\.id)).count == validatedRecords.count else {
            throw SyncPublicationError.corruptTransaction
        }
        do {
            for receipt in remoteBatchReceipts {
                _ = try receipt.validated(accountIDHash: accountIDHash)
            }
        } catch {
            throw SyncPublicationError.corruptTransaction
        }
        return self
    }

    public func insertingRemoteReceipt(_ receipt: SyncRemoteBatchReceipt) throws -> Self {
        _ = try receipt.validated(accountIDHash: accountIDHash)
        if let existing = remoteBatchReceipts.first(where: {
            Self.receiptKey($0) == Self.receiptKey(receipt)
        }) {
            guard existing == receipt else { throw SyncRemoteBatchError.identityCollision }
            return self
        }
        guard receipt.commitID == commitID else { throw SyncRemoteBatchError.invalidBatch }
        guard remoteBatchReceipts.count < Self.maximumReceiptCount else {
            throw SyncRemoteBatchError.receiptCapacity
        }
        return try Self(
            formatVersion: Self.receiptFormatVersion,
            accountIDHash: accountIDHash,
            commitID: commitID,
            archiveSHA256: archiveSHA256,
            records: records,
            legacyRecordIDsToDelete: legacyRecordIDsToDelete,
            remoteBatchReceipts: remoteBatchReceipts + [receipt]
        ).requiringEncodedCapacity()
    }

    func retiringRemoteReceipt(
        _ identity: SyncRemoteBatchIdentity,
        successorCommitID: UUID
    ) throws -> Self {
        _ = try identity.validated()
        guard identity.accountIDHash == accountIDHash else {
            throw SyncRemoteBatchError.invalidBatch
        }
        let matchingKey = remoteBatchReceipts.filter {
            Self.receiptKey($0) == Self.receiptKey(identity)
        }
        guard let retained = matchingKey.first else {
            throw SyncRemoteBatchError.missingAuthority
        }
        guard retained.identity == identity else {
            throw SyncRemoteBatchError.identityCollision
        }
        return try Self(
            formatVersion: Self.receiptFormatVersion,
            accountIDHash: accountIDHash,
            commitID: successorCommitID,
            archiveSHA256: archiveSHA256,
            records: records,
            legacyRecordIDsToDelete: legacyRecordIDsToDelete,
            remoteBatchReceipts: remoteBatchReceipts.filter { $0 != retained }
        ).requiringEncodedCapacity()
    }

    func successor(
        commitID: UUID,
        archiveSHA256: Data,
        records: [SyncRecord],
        legacyRecordIDsToDelete: Set<SyncEntityID>
    ) throws -> Self {
        try Self(
            formatVersion: formatVersion,
            accountIDHash: accountIDHash,
            commitID: commitID,
            archiveSHA256: archiveSHA256,
            records: records,
            legacyRecordIDsToDelete: legacyRecordIDsToDelete,
            remoteBatchReceipts: remoteBatchReceipts
        ).requiringEncodedCapacity()
    }

    public func encoded() throws -> Data {
        let bytes = try Self.encoder().encode(envelope())
        guard bytes.count <= Self.maximumBytes else { throw SyncRegularFileReadError.tooLarge }
        return bytes
    }

    public init(from decoder: any Decoder) throws {
        let wire = try Wire(from: decoder)
        guard [Self.legacyFormatVersion, Self.receiptFormatVersion].contains(wire.formatVersion),
              wire.formatVersion != Self.legacyFormatVersion || wire.remoteBatchReceipts == nil,
              wire.formatVersion != Self.receiptFormatVersion || wire.remoteBatchReceipts != nil,
              Set(wire.legacyRecordIDsToDelete).count == wire.legacyRecordIDsToDelete.count else {
            throw SyncPublicationError.corruptTransaction
        }
        try self.init(formatVersion: wire.formatVersion, accountIDHash: wire.accountIDHash,
            commitID: wire.commitID, archiveSHA256: wire.archiveSHA256,
            records: wire.records, legacyRecordIDsToDelete: Set(wire.legacyRecordIDsToDelete),
            remoteBatchReceipts: wire.remoteBatchReceipts ?? [])
        guard let integrity = wire.integritySHA256, integrity.count == 64,
              integrity == (try envelope().integritySHA256) else {
            throw SyncPublicationError.corruptTransaction
        }
    }

    public func encode(to encoder: any Encoder) throws {
        // Require the canonical envelope to fit before permitting direct encoding.
        _ = try encoded()
        try envelope().encode(to: encoder)
    }

    private struct Wire: Codable {
        let formatVersion: Int
        let accountIDHash: String
        let commitID: UUID
        let archiveSHA256: Data
        let records: [SyncRecord]
        let legacyRecordIDsToDelete: [SyncEntityID]
        let remoteBatchReceipts: [SyncRemoteBatchReceipt]?
        var integritySHA256: String?
    }

    private func envelope() throws -> Wire {
        _ = try validated()
        var wire = Wire(formatVersion: formatVersion, accountIDHash: accountIDHash,
            commitID: commitID, archiveSHA256: archiveSHA256, records: records,
            legacyRecordIDsToDelete: legacyRecordIDsToDelete.sorted(by: Self.entityLess),
            remoteBatchReceipts: formatVersion == Self.receiptFormatVersion
                ? remoteBatchReceipts : nil)
        // Fixed-width hex avoids digest-dependent base64 slash escaping overhead.
        wire.integritySHA256 = SHA256.hash(data: try Self.encoder().encode(wire))
            .map { String(format: "%02x", $0) }.joined()
        return wire
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder
    }

    // Same kind/UUID ordering used by SyncMergeEngine.
    private static func entityLess(_ lhs: SyncEntityID, _ rhs: SyncEntityID) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.uuid.uuidString < rhs.uuid.uuidString
    }

    private func requiringEncodedCapacity() throws -> Self {
        _ = try encoded()
        return self
    }

    private static func receiptKey(_ receipt: SyncRemoteBatchReceipt) -> String {
        receiptKey(receipt.identity)
    }

    private static func receiptKey(_ identity: SyncRemoteBatchIdentity) -> String {
        identity.accountIDHash + ":" + identity.batchID.uuidString
    }

    private static func receiptLess(
        _ lhs: SyncRemoteBatchReceipt,
        _ rhs: SyncRemoteBatchReceipt
    ) -> Bool {
        receiptKey(lhs) < receiptKey(rhs)
    }
}
