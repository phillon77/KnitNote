import CryptoKit
import Foundation

/// Complete canonical authority, including acknowledged record history. The
/// archive digest binds this authority to one committed domain snapshot.
public struct SyncCanonicalCheckpoint: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let accountIDHash: String
    public let commitID: UUID
    public let archiveSHA256: Data
    public let records: [SyncRecord]
    public let legacyRecordIDsToDelete: Set<SyncEntityID>
    public static let maximumBytes = 100_000_000

    public init(accountIDHash: String, commitID: UUID, archiveSHA256: Data,
                records: [SyncRecord], legacyRecordIDsToDelete: Set<SyncEntityID>) throws {
        formatVersion = 1
        self.accountIDHash = accountIDHash
        self.commitID = commitID
        self.archiveSHA256 = archiveSHA256
        self.records = records.sorted { Self.entityLess($0.id, $1.id) }
        self.legacyRecordIDsToDelete = legacyRecordIDsToDelete
        _ = try validated()
    }

    public func validated() throws -> Self {
        guard formatVersion == 1, accountIDHash.utf8.count == 64,
              accountIDHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              archiveSHA256.count == 32 else { throw SyncPublicationError.corruptTransaction }
        let validatedRecords = try SyncRecordValidator().validate(records)
        guard Set(validatedRecords.map(\.id)).count == validatedRecords.count else {
            throw SyncPublicationError.corruptTransaction
        }
        return self
    }

    public func encoded() throws -> Data {
        let bytes = try Self.encoder().encode(envelope())
        guard bytes.count <= Self.maximumBytes else { throw SyncRegularFileReadError.tooLarge }
        return bytes
    }

    public init(from decoder: any Decoder) throws {
        let wire = try Wire(from: decoder)
        guard wire.formatVersion == 1,
              Set(wire.legacyRecordIDsToDelete).count == wire.legacyRecordIDsToDelete.count else {
            throw SyncPublicationError.corruptTransaction
        }
        try self.init(accountIDHash: wire.accountIDHash, commitID: wire.commitID,
            archiveSHA256: wire.archiveSHA256, records: wire.records,
            legacyRecordIDsToDelete: Set(wire.legacyRecordIDsToDelete))
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
        var integritySHA256: String?
    }

    private func envelope() throws -> Wire {
        _ = try validated()
        var wire = Wire(formatVersion: formatVersion, accountIDHash: accountIDHash,
            commitID: commitID, archiveSHA256: archiveSHA256, records: records,
            legacyRecordIDsToDelete: legacyRecordIDsToDelete.sorted(by: Self.entityLess))
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
}
