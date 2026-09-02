import CryptoKit
import Foundation

public enum SyncScalar: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case decimal(Double)
    case boolean(Bool)
    case date(Date)
    case uuid(UUID)
    case data(Data)

    var byteCount: Int {
        switch self {
        case let .string(value):
            value.lengthOfBytes(using: .utf8)
        case let .data(value):
            value.count
        case .integer, .decimal, .boolean, .date, .uuid:
            0
        }
    }
}

public struct SyncRecordPayload: Codable, Equatable, Sendable {
    public var fields: [String: SyncFieldVersion<SyncScalar>]
    /// Versioned as one value and paired with the winning `deletedAt` stamp.
    /// A restore therefore replaces a prior cascade with an explicit empty set
    /// instead of unioning old deletion intent forever.
    public var deletionCascade: SyncFieldVersion<[SyncEntityID]>?
    public var atomicDomain: SyncFieldVersion<SyncAtomicDomainValue>?
    public var attachment: SyncAttachmentVersion?

    /// Source-compatible read access for Phase 1 callers. New records must set
    /// `deletionCascade` explicitly so its stamp can be validated.
    public var deletedRelatedEntityIDs: [SyncEntityID] {
        get { deletionCascade?.value ?? [] }
        set {
            deletionCascade = newValue.isEmpty ? nil : .init(
                value: newValue,
                stamp: Self.legacyUnversionedDeletionStamp
            )
        }
    }

    public init(
        fields: [String: SyncFieldVersion<SyncScalar>],
        deletedRelatedEntityIDs: [SyncEntityID] = [],
        deletionCascade: SyncFieldVersion<[SyncEntityID]>? = nil,
        atomicDomain: SyncFieldVersion<SyncAtomicDomainValue>? = nil,
        attachment: SyncAttachmentVersion? = nil
    ) {
        self.fields = fields
        self.deletionCascade = deletionCascade ?? (deletedRelatedEntityIDs.isEmpty
            ? nil
            : .init(
                value: deletedRelatedEntityIDs,
                stamp: Self.legacyUnversionedDeletionStamp
            ))
        self.atomicDomain = atomicDomain
        self.attachment = attachment
    }

    private static let legacyUnversionedDeletionStamp = SyncMutationStamp(
        logicalRevision: 0,
        modifiedAt: .distantPast,
        deviceID: "legacy-unversioned-deletion"
    )
}

/// Counter and reminder state is one indivisible domain value. These values
/// deliberately do not participate in generic per-field LWW merging.
public enum SyncAtomicDomainValue: Codable, Equatable, Sendable {
    case projectCounter(ProjectCounter)
    case knittingReminder(KnittingReminder)

    public var mutationRevision: UInt64 {
        switch self {
        case let .projectCounter(counter): counter.mutationRevision
        case let .knittingReminder(reminder): reminder.mutationRevision
        }
    }
}

public enum SyncAttachmentVersionError: Error, Equatable, Sendable {
    case invalidSlot
    case invalidMetadata
    case invalidIdentity
}

/// Stable semantic location of an attachment. The slot does not change when
/// its bytes are replaced; each byte version receives a separate version ID.
public struct SyncAttachmentSlot: Codable, Equatable, Hashable, Sendable {
    public let owner: SyncEntityID
    public let role: String
    public let slotID: String

    public init(owner: SyncEntityID, role: String, slotID: String) {
        self.owner = owner
        self.role = role
        self.slotID = slotID
    }

    func validated() throws -> Self {
        guard !role.isEmpty,
              !slotID.isEmpty,
              role.utf8.count <= 128,
              slotID.utf8.count <= 512 else {
            throw SyncAttachmentVersionError.invalidSlot
        }
        return self
    }
}

/// Immutable attachment metadata. `versionID` is derived from the semantic
/// slot and the content digest, while `conflictGroupID` is derived only from
/// the slot so concurrent versions can be compared without grouping unrelated
/// label photos or markup pages.
public struct SyncAttachmentVersion: Codable, Equatable, Sendable {
    public let slot: SyncAttachmentSlot
    public let versionID: UUID
    public let conflictGroupID: UUID
    public let contentSHA256: Data
    public let byteCount: Int64
    public let mediaType: String
    public let displayFilename: String
    public let replacesVersionID: UUID?

    public init(
        slot: SyncAttachmentSlot,
        contentSHA256: Data,
        byteCount: Int64,
        mediaType: String,
        displayFilename: String,
        replacesVersionID: UUID? = nil
    ) throws {
        self.slot = try slot.validated()
        self.contentSHA256 = contentSHA256
        self.byteCount = byteCount
        self.mediaType = mediaType
        self.displayFilename = displayFilename
        self.replacesVersionID = replacesVersionID
        versionID = try Self.identity(prefix: "attachment-version", slot: slot, digest: contentSHA256)
        conflictGroupID = try Self.identity(prefix: "attachment-slot", slot: slot, digest: nil)
        try validateMetadata()
    }

    public func validated() throws -> Self {
        _ = try slot.validated()
        try validateMetadata()
        guard versionID == (try Self.identity(
            prefix: "attachment-version",
            slot: slot,
            digest: contentSHA256
        )), conflictGroupID == (try Self.identity(
            prefix: "attachment-slot",
            slot: slot,
            digest: nil
        )) else {
            throw SyncAttachmentVersionError.invalidIdentity
        }
        return self
    }

    private func validateMetadata() throws {
        guard contentSHA256.count == SHA256.byteCount,
              byteCount >= 0,
              !mediaType.isEmpty,
              mediaType.utf8.count <= 256,
              !displayFilename.isEmpty,
              displayFilename.utf8.count <= 1_024,
              displayFilename == URL(fileURLWithPath: displayFilename).lastPathComponent,
              replacesVersionID != versionID else {
            throw SyncAttachmentVersionError.invalidMetadata
        }
    }

    private static func identity(
        prefix: String,
        slot: SyncAttachmentSlot,
        digest: Data?
    ) throws -> UUID {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var bytes = Data(prefix.utf8)
        bytes.append(0)
        bytes.append(try encoder.encode(slot.validated()))
        if let digest {
            bytes.append(0)
            bytes.append(digest)
        }
        return uuid(from: Data(SHA256.hash(data: bytes)))
    }
}

public enum SyncRecordVersionError: Error, Equatable, Sendable {
    case corrupt
}

/// Canonical immutable record snapshot bound to a save mutation.
public struct SyncRecordVersion: Codable, Equatable, Sendable {
    public let versionID: UUID
    public let record: SyncRecord

    public init(record: SyncRecord) throws {
        self.record = try SyncRecordValidator().validate(record)
        versionID = try Self.identity(for: self.record)
    }

    public func validated() throws -> Self {
        _ = try SyncRecordValidator().validate(record)
        guard versionID == (try Self.identity(for: record)) else {
            throw SyncRecordVersionError.corrupt
        }
        return self
    }

    private static func identity(for record: SyncRecord) throws -> UUID {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return uuid(from: Data(SHA256.hash(data: try encoder.encode(record))))
    }
}

private func uuid(from digest: Data) -> UUID {
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

public struct SyncRelationship: Codable, Equatable, Sendable {
    public let role: String
    public let target: SyncEntityID

    public init(role: String, target: SyncEntityID) {
        self.role = role
        self.target = target
    }
}

public struct SyncRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: SyncEntityID
    public let createdAt: Date
    public var entityRevision: UInt64
    public var payload: SyncRecordPayload
    public var relationships: [SyncRelationship]
    public var deletedAt: SyncFieldVersion<Date?>

    public init(
        schemaVersion: Int,
        id: SyncEntityID,
        createdAt: Date,
        entityRevision: UInt64,
        payload: SyncRecordPayload,
        relationships: [SyncRelationship],
        deletedAt: SyncFieldVersion<Date?>
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.entityRevision = entityRevision
        self.payload = payload
        self.relationships = relationships
        self.deletedAt = deletedAt
    }
}
