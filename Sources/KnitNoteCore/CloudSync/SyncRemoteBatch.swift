import CryptoKit
import Foundation

public struct SyncRemoteBatchIdentity: Codable, Equatable, Sendable {
    public let accountIDHash: String
    public let batchID: UUID
    public let contentSHA256: Data

    func validated() throws -> Self {
        guard accountIDHash.utf8.count == 64,
              accountIDHash.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }),
              contentSHA256.count == SHA256.byteCount else {
            throw SyncRemoteBatchError.invalidBatch
        }
        return self
    }
}

public struct SyncRemoteBatch: Sendable {
    public let identity: SyncRemoteBatchIdentity
    public let records: [SyncRecord]
    public let deletedRecordIDs: [SyncEntityID]

    public init(
        accountIDHash: String,
        batchID: UUID,
        records: [SyncRecord],
        deletedRecordIDs: [SyncEntityID]
    ) throws {
        guard Self.isAccountIDHash(accountIDHash) else {
            throw SyncRemoteBatchError.invalidBatch
        }

        let validatedRecords: [SyncRecord]
        do {
            validatedRecords = try SyncRecordValidator().validate(records)
        } catch {
            throw SyncRemoteBatchError.invalidBatch
        }
        guard Set(validatedRecords.map(\.id)).count == validatedRecords.count,
              Set(deletedRecordIDs).count == deletedRecordIDs.count,
              Set(validatedRecords.map(\.id)).isDisjoint(with: deletedRecordIDs) else {
            throw SyncRemoteBatchError.invalidBatch
        }

        let content = IdentityContent(
            accountIDHash: accountIDHash,
            batchID: batchID,
            records: validatedRecords.sorted { Self.entityLess($0.id, $1.id) },
            deletedRecordIDs: deletedRecordIDs.sorted(by: Self.entityLess)
        )
        let encoded: Data
        do {
            encoded = try Self.encoder().encode(content)
        } catch {
            throw SyncRemoteBatchError.invalidBatch
        }
        guard encoded.count <= SyncCanonicalCheckpoint.maximumBytes else {
            throw SyncRemoteBatchError.invalidBatch
        }

        identity = .init(
            accountIDHash: accountIDHash,
            batchID: batchID,
            contentSHA256: Data(SHA256.hash(data: encoded))
        )
        self.records = validatedRecords
        self.deletedRecordIDs = deletedRecordIDs
    }

    private struct IdentityContent: Codable {
        let accountIDHash: String
        let batchID: UUID
        let records: [SyncRecord]
        let deletedRecordIDs: [SyncEntityID]
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func isAccountIDHash(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }
    }

    private static func entityLess(_ lhs: SyncEntityID, _ rhs: SyncEntityID) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.uuid.uuidString < rhs.uuid.uuidString
    }
}

public struct SyncRemoteBatchReceipt: Codable, Equatable, Sendable {
    public let identity: SyncRemoteBatchIdentity
    public let commitID: UUID
    public let domainChanged: Bool

    func validated(accountIDHash: String) throws -> Self {
        _ = try identity.validated()
        guard identity.accountIDHash == accountIDHash else {
            throw SyncRemoteBatchError.invalidBatch
        }
        return self
    }
}

enum SyncRemoteBatchReceiptAction: String, Codable, Equatable, Sendable {
    case insert
    case retire
}

struct SyncRemoteBatchPredecessorCommitment: Codable, Equatable, Sendable {
    let accountIDHash: String
    let commitID: UUID
    let checkpointSHA256: Data

    init(accountIDHash: String, commitID: UUID, checkpointSHA256: Data) throws {
        self.accountIDHash = accountIDHash
        self.commitID = commitID
        self.checkpointSHA256 = checkpointSHA256
        _ = try validated()
    }

    init(checkpoint: SyncCanonicalCheckpoint) throws {
        try self.init(
            accountIDHash: checkpoint.accountIDHash,
            commitID: checkpoint.commitID,
            checkpointSHA256: Data(SHA256.hash(data: checkpoint.encoded()))
        )
    }

    func validated() throws -> Self {
        _ = try SyncRemoteBatchIdentity(
            accountIDHash: accountIDHash,
            batchID: UUID(),
            contentSHA256: checkpointSHA256
        ).validated()
        return self
    }
}

struct SyncRemoteBatchPublicationSource: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let identity: SyncRemoteBatchIdentity
    let predecessor: SyncRemoteBatchPredecessorCommitment
    let receiptAction: SyncRemoteBatchReceiptAction

    init(
        formatVersion: Int = Self.currentFormatVersion,
        identity: SyncRemoteBatchIdentity,
        predecessor: SyncRemoteBatchPredecessorCommitment,
        receiptAction: SyncRemoteBatchReceiptAction
    ) throws {
        self.formatVersion = formatVersion
        self.identity = identity
        self.predecessor = predecessor
        self.receiptAction = receiptAction
        _ = try validated()
    }

    func validated() throws -> Self {
        guard formatVersion == Self.currentFormatVersion else {
            throw SyncPublicationTransactionFileError.corrupt
        }
        do {
            _ = try identity.validated()
            _ = try predecessor.validated()
        } catch {
            throw SyncPublicationTransactionFileError.corrupt
        }
        guard identity.accountIDHash == predecessor.accountIDHash else {
            throw SyncPublicationTransactionFileError.corrupt
        }
        return self
    }
}

public struct SyncRemoteBatchPreparation: Sendable {}

public enum SyncRemoteBatchCommitResult: Equatable, Sendable {
    case committed(SyncRemoteBatchReceipt)
    case alreadyCommitted(SyncRemoteBatchReceipt)
    case stalePredecessor
}

public enum SyncRemoteBatchError: Error, Equatable, Sendable {
    case invalidBatch
    case identityCollision
    case missingAuthority
    case unprovenDeletion
    case receiptCapacity
    case unsupportedConflictReplacement
}
