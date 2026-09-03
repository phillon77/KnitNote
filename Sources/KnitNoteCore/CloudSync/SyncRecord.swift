import CryptoKit
import Foundation

extension CodingUserInfoKey {
    /// Internal-only escape hatch for verifying and retaining already-durable
    /// standalone reminder journal entries while they are migrated. Live
    /// record publication never sets this key.
    static let encodeLegacyStandaloneReminderForMigration = CodingUserInfoKey(
        rawValue: "KnitNoteCore.encodeLegacyStandaloneReminderForMigration"
    )!
}

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
/// reminders and Watch exactly-once metadata travel with their counter so a
/// merge can never assemble a state that did not exist on either device.
public struct SyncProcessedWatchCommandProof: Codable, Equatable, Sendable {
    public let id: UUID
    public let counterID: UUID
    public let rejection: WatchCommandRejection?
    public let commandIdentity: ProcessedWatchCommandIdentity?
    public let preparedCommand: PreparedWatchCommand?
    public let effectProof: ProcessedWatchCommandEffectProof?
    public let processingStamp: SyncMutationStamp?

    public init(
        id: UUID,
        counterID: UUID? = nil,
        rejection: WatchCommandRejection?,
        commandIdentity: ProcessedWatchCommandIdentity? = nil,
        preparedCommand: PreparedWatchCommand?,
        effectProof: ProcessedWatchCommandEffectProof?,
        processingStamp: SyncMutationStamp? = nil
    ) throws {
        guard let resolvedCounterID = counterID
                ?? commandIdentity?.counterID
                ?? preparedCommand?.command.counterID
                ?? effectProof?.counter.id else {
            throw SyncRecordVersionError.corrupt
        }
        self.id = id
        self.counterID = resolvedCounterID
        self.rejection = rejection
        self.commandIdentity = commandIdentity
            ?? preparedCommand.map { ProcessedWatchCommandIdentity($0.command) }
        self.preparedCommand = preparedCommand
        self.effectProof = effectProof
        self.processingStamp = processingStamp
        _ = try validated()
    }

    init?(
        entry: ProcessedWatchCommandLedger.Entry,
        processingDeviceID: String? = nil
    ) throws {
        guard let counterID = entry.commandIdentity?.counterID
                ?? entry.preparedCommand?.command.counterID
                ?? entry.effectProof?.counter.id else { return nil }
        let needsLegacyMissingTargetStamp = entry.rejection == .projectMissing
            || entry.rejection == .counterMissing
        let processingStamp = entry.processingStamp
            ?? (needsLegacyMissingTargetStamp ? processingDeviceID.map {
                SyncMutationStamp(
                    logicalRevision: 0,
                    modifiedAt: entry.processedAt,
                    deviceID: $0
                )
            } : nil)
        try self.init(
            id: entry.id,
            counterID: counterID,
            rejection: entry.rejection,
            commandIdentity: entry.commandIdentity,
            preparedCommand: entry.preparedCommand,
            effectProof: entry.effectProof,
            processingStamp: processingStamp
        )
    }

    func validated() throws -> Self {
        guard (commandIdentity == nil || commandIdentity?.id == id),
              (commandIdentity == nil || commandIdentity?.counterID == counterID),
              (preparedCommand == nil || preparedCommand?.command.id == id),
              (preparedCommand == nil || preparedCommand?.command.counterID == counterID),
              (commandIdentity == nil || preparedCommand == nil
                  || commandIdentity == preparedCommand.map {
                      ProcessedWatchCommandIdentity($0.command)
                  }),
              (effectProof == nil || effectProof?.counter.id == counterID),
              (processingStamp == nil || (
                  processingStamp?.logicalRevision == 0
                      && processingStamp?.deviceID.isEmpty == false
              )) else {
            throw SyncRecordVersionError.corrupt
        }
        if rejection == nil {
            guard preparedCommand != nil, effectProof != nil else {
                throw SyncRecordVersionError.corrupt
            }
        } else {
            guard effectProof == nil,
                  commandIdentity != nil || preparedCommand != nil else {
                throw SyncRecordVersionError.corrupt
            }
        }
        if rejection == .projectMissing || rejection == .counterMissing {
            guard processingStamp != nil else {
                throw SyncRecordVersionError.corrupt
            }
        }
        return self
    }
}

/// Immutable, standalone authority for a Watch rejection whose target no
/// longer exists in the project archive. Accepted effects and rejections that
/// belong to a live counter remain owned by `SyncCounterReminderState`.
public struct SyncOrphanWatchCommandProof: Codable, Equatable, Sendable {
    public let proof: SyncProcessedWatchCommandProof

    public init(proof: SyncProcessedWatchCommandProof) throws {
        guard proof.rejection == .projectMissing || proof.rejection == .counterMissing,
              proof.commandIdentity != nil,
              proof.preparedCommand == nil,
              proof.effectProof == nil,
              proof.processingStamp != nil else {
            throw SyncRecordVersionError.corrupt
        }
        self.proof = try proof.validated()
    }
}

public struct SyncCounterReminderState: Codable, Equatable, Sendable {
    public let counter: ProjectCounter
    public let reminders: [KnittingReminder]
    public let preparedCommand: PreparedWatchCommand?
    public let processedCommandIDs: Set<UUID>
    public let processedCommandProofs: [SyncProcessedWatchCommandProof]
    public let occurrence: Int?

    /// Source-compatible convenience for callers which are already scoped to
    /// a single reminder. Synchronization and validation always use
    /// `reminders`, never this projection.
    public var reminder: KnittingReminder? { reminders.first }

    public init(
        counter: ProjectCounter,
        reminders: [KnittingReminder],
        preparedCommand: PreparedWatchCommand?,
        processedCommandIDs: Set<UUID>,
        processedCommandProofs: [SyncProcessedWatchCommandProof] = [],
        occurrence: Int?
    ) {
        self.counter = counter
        self.reminders = reminders.sorted { $0.id.uuidString < $1.id.uuidString }
        self.preparedCommand = preparedCommand
        self.processedCommandIDs = processedCommandIDs
        self.processedCommandProofs = processedCommandProofs.sorted {
            $0.id.uuidString < $1.id.uuidString
        }
        self.occurrence = occurrence
    }

    public init(
        counter: ProjectCounter,
        reminder: KnittingReminder?,
        preparedCommand: PreparedWatchCommand?,
        processedCommandIDs: Set<UUID>,
        processedCommandProofs: [SyncProcessedWatchCommandProof] = [],
        occurrence: Int?
    ) {
        self.init(
            counter: counter,
            reminders: reminder.map { [$0] } ?? [],
            preparedCommand: preparedCommand,
            processedCommandIDs: processedCommandIDs,
            processedCommandProofs: processedCommandProofs,
            occurrence: occurrence
        )
    }

    private enum CodingKeys: String, CodingKey {
        case counter
        case reminders
        case reminder
        case preparedCommand
        case processedCommandIDs
        case processedCommandProofs
        case occurrence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        counter = try container.decode(ProjectCounter.self, forKey: .counter)
        let decodedReminders: [KnittingReminder]
        if container.contains(.reminders) {
            decodedReminders = try container.decode(
                [KnittingReminder].self,
                forKey: .reminders
            )
        } else {
            decodedReminders = try container.decodeIfPresent(
                KnittingReminder.self,
                forKey: .reminder
            ).map { [$0] } ?? []
        }
        reminders = decodedReminders.sorted { $0.id.uuidString < $1.id.uuidString }
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
        processedCommandProofs = try container.decodeIfPresent(
            [SyncProcessedWatchCommandProof].self,
            forKey: .processedCommandProofs
        ) ?? []
        guard Set(processedCommandProofs.map(\.id)).count == processedCommandProofs.count,
              Set(processedCommandProofs.map(\.id)).isSubset(of: processedCommandIDs) else {
            throw DecodingError.dataCorruptedError(
                forKey: .processedCommandProofs,
                in: container,
                debugDescription: "Processed Watch proofs must be unique and named by the ID set"
            )
        }
        do {
            for proof in processedCommandProofs { _ = try proof.validated() }
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .processedCommandProofs,
                in: container,
                debugDescription: "Invalid processed Watch command proof"
            )
        }
        occurrence = try container.decodeIfPresent(Int.self, forKey: .occurrence)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(counter, forKey: .counter)
        try container.encode(reminders, forKey: .reminders)
        try container.encodeIfPresent(preparedCommand, forKey: .preparedCommand)
        try container.encode(
            processedCommandIDs.sorted { $0.uuidString < $1.uuidString },
            forKey: .processedCommandIDs
        )
        try container.encode(
            processedCommandProofs.sorted { $0.id.uuidString < $1.id.uuidString },
            forKey: .processedCommandProofs
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
    case orphanWatchCommandProof(SyncOrphanWatchCommandProof)

    private enum CodingKeys: String, CodingKey {
        case projectCounter
        case knittingReminder
        case orphanWatchCommandProof
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
        if container.contains(.orphanWatchCommandProof) {
            let value = try container.nestedContainer(
                keyedBy: AssociatedValueKey.self,
                forKey: .orphanWatchCommandProof
            )
            self = .orphanWatchCommandProof(try value.decode(
                SyncOrphanWatchCommandProof.self,
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
            guard encoder.userInfo[.encodeLegacyStandaloneReminderForMigration] as? Bool == true
            else {
                throw EncodingError.invalidValue(
                    reminder,
                    .init(
                        codingPath: encoder.codingPath,
                        debugDescription: "Standalone reminder records are decode-only legacy input"
                    )
                )
            }
            var value = container.nestedContainer(
                keyedBy: AssociatedValueKey.self,
                forKey: .knittingReminder
            )
            try value.encode(reminder, forKey: .value)
        case let .orphanWatchCommandProof(proof):
            var value = container.nestedContainer(
                keyedBy: AssociatedValueKey.self,
                forKey: .orphanWatchCommandProof
            )
            try value.encode(proof, forKey: .value)
        }
    }

    public var mutationRevision: UInt64 {
        switch self {
        case let .projectCounter(state): state.counter.mutationRevision
        case let .knittingReminder(reminder): reminder.mutationRevision
        case .orphanWatchCommandProof: 0
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

    func validatedForLegacyStandaloneReminderJournalMigration() throws -> Self {
        _ = try SyncRecordValidator().validateLegacyStandaloneReminderForMigration(record)
        guard versionID == (try Self.identity(
            for: record,
            allowingLegacyStandaloneReminder: true
        )) else {
            throw SyncRecordVersionError.corrupt
        }
        return self
    }

    private static func identity(
        for record: SyncRecord,
        allowingLegacyStandaloneReminder: Bool = false
    ) throws -> UUID {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if allowingLegacyStandaloneReminder {
            encoder.userInfo[.encodeLegacyStandaloneReminderForMigration] = true
        }
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
