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

/// The complete state for one counter-owned synchronization domain. A smart
/// reminder and Watch exactly-once metadata travel with their counter so a
/// merge can never assemble a state that did not exist on either device.
public struct SyncCounterReminderState: Codable, Equatable, Sendable {
    public let counter: ProjectCounter
    public let reminder: KnittingReminder?
    public let preparedCommand: PreparedWatchCommand?
    public let processedCommandIDs: Set<UUID>
    public let occurrence: Int?

    public init(
        counter: ProjectCounter,
        reminder: KnittingReminder?,
        preparedCommand: PreparedWatchCommand?,
        processedCommandIDs: Set<UUID>,
        occurrence: Int?
    ) {
        self.counter = counter
        self.reminder = reminder
        self.preparedCommand = preparedCommand
        self.processedCommandIDs = processedCommandIDs
        self.occurrence = occurrence
    }

    private enum CodingKeys: String, CodingKey {
        case counter
        case reminder
        case preparedCommand
        case processedCommandIDs
        case occurrence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        counter = try container.decode(ProjectCounter.self, forKey: .counter)
        reminder = try container.decodeIfPresent(KnittingReminder.self, forKey: .reminder)
        preparedCommand = try container.decodeIfPresent(
            PreparedWatchCommand.self,
            forKey: .preparedCommand
        )
        let decodedIDs = try container.decode([UUID].self, forKey: .processedCommandIDs)
        processedCommandIDs = Set(decodedIDs)
        guard processedCommandIDs.count == decodedIDs.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .processedCommandIDs,
                in: container,
                debugDescription: "Duplicate processed Watch command ID"
            )
        }
        occurrence = try container.decodeIfPresent(Int.self, forKey: .occurrence)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(counter, forKey: .counter)
        try container.encodeIfPresent(reminder, forKey: .reminder)
        try container.encodeIfPresent(preparedCommand, forKey: .preparedCommand)
        try container.encode(
            processedCommandIDs.sorted { $0.uuidString < $1.uuidString },
            forKey: .processedCommandIDs
        )
        try container.encodeIfPresent(occurrence, forKey: .occurrence)
    }
}

public enum SyncReminderStopOutcome: Equatable, Sendable {
    case persisted(SyncCounterReminderState)
    case noOp(SyncCounterReminderState)

    public var state: SyncCounterReminderState {
        switch self {
        case let .persisted(state), let .noOp(state): state
        }
    }

    public var isPersisted: Bool {
        if case .persisted = self { return true }
        return false
    }

    public var isNoOp: Bool {
        if case .noOp = self { return true }
        return false
    }
}

/// Counter and reminder state is one indivisible domain value. The legacy
/// reminder case remains decodable for migration, but new publication uses a
/// counter record containing `SyncCounterReminderState`.
public enum SyncAtomicDomainValue: Codable, Equatable, Sendable {
    case projectCounter(SyncCounterReminderState)
    case knittingReminder(KnittingReminder)

    private enum CodingKeys: String, CodingKey {
        case projectCounter
        case knittingReminder
    }

    private enum AssociatedValueKey: String, CodingKey {
        case value = "_0"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.projectCounter) {
            let value = try container.nestedContainer(
                keyedBy: AssociatedValueKey.self,
                forKey: .projectCounter
            )
            if let aggregate = try? value.decode(
                SyncCounterReminderState.self,
                forKey: .value
            ) {
                self = .projectCounter(aggregate)
            } else {
                let legacyCounter = try value.decode(ProjectCounter.self, forKey: .value)
                self = .projectCounter(SyncCounterReminderState(
                    counter: legacyCounter,
                    reminder: nil,
                    preparedCommand: nil,
                    processedCommandIDs: [],
                    occurrence: nil
                ))
            }
            return
        }
        if container.contains(.knittingReminder) {
            let value = try container.nestedContainer(
                keyedBy: AssociatedValueKey.self,
                forKey: .knittingReminder
            )
            self = .knittingReminder(try value.decode(
                KnittingReminder.self,
                forKey: .value
            ))
            return
        }
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown atomic synchronization domain"
            )
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .projectCounter(state):
            var value = container.nestedContainer(
                keyedBy: AssociatedValueKey.self,
                forKey: .projectCounter
            )
            try value.encode(state, forKey: .value)
        case let .knittingReminder(reminder):
            var value = container.nestedContainer(
                keyedBy: AssociatedValueKey.self,
                forKey: .knittingReminder
            )
            try value.encode(reminder, forKey: .value)
        }
    }

    public var mutationRevision: UInt64 {
        switch self {
        case let .projectCounter(state): state.counter.mutationRevision
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

/// Immutable attachment metadata. `versionID` is issued once for each save,
/// while `conflictGroupID` is derived only from the slot so concurrent versions
/// can be compared without grouping unrelated label photos or markup pages.
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
        versionID: UUID,
        conflictGroupID: UUID,
        contentSHA256: Data,
        byteCount: Int64,
        mediaType: String,
        displayFilename: String,
        replacesVersionID: UUID? = nil
    ) throws {
        self.slot = try slot.validated()
        self.versionID = versionID
        self.conflictGroupID = conflictGroupID
        self.contentSHA256 = contentSHA256
        self.byteCount = byteCount
        self.mediaType = mediaType
        self.displayFilename = displayFilename
        self.replacesVersionID = replacesVersionID
        try validateMetadata()
    }

    public static func issuing(
        slot: SyncAttachmentSlot,
        contentSHA256: Data,
        byteCount: Int64,
        mediaType: String,
        displayFilename: String,
        replacesVersionID: UUID? = nil,
        versionID: UUID = UUID()
    ) throws -> Self {
        try Self(
            slot: slot,
            versionID: versionID,
            conflictGroupID: try conflictGroupID(for: slot),
            contentSHA256: contentSHA256,
            byteCount: byteCount,
            mediaType: mediaType,
            displayFilename: displayFilename,
            replacesVersionID: replacesVersionID
        )
    }

    public static func conflictGroupID(for slot: SyncAttachmentSlot) throws -> UUID {
        try identity(prefix: "attachment-slot", slot: slot, digest: nil)
    }

    public func validated() throws -> Self {
        _ = try slot.validated()
        try validateMetadata()
        guard conflictGroupID == (try Self.conflictGroupID(for: slot)) else {
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
