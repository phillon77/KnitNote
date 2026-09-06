import CryptoKit
import Darwin
import Foundation

@_silgen_name("flock")
private func syncJournalFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

public enum SyncMutationIntent: String, Codable, Equatable, Sendable {
    case save
    case delete
}

public struct SyncMutationIdentity: Codable, Equatable, Hashable, Sendable {
    public let recordID: SyncEntityID
    public let mutationID: UUID

    public init(recordID: SyncEntityID, mutationID: UUID) {
        self.recordID = recordID
        self.mutationID = mutationID
    }
}

public struct SyncAttachmentSource: Codable, Equatable, Sendable {
    public let fileURL: URL
    public let contentSHA256: Data
    public let byteCount: Int64
    public let isJournalStaged: Bool

    public init(fileURL: URL, contentSHA256: Data, byteCount: Int64) throws {
        self.init(
            fileURL: fileURL,
            contentSHA256: contentSHA256,
            byteCount: byteCount,
            isJournalStaged: false
        )
        _ = try validated()
    }

    init(fileURL: URL, contentSHA256: Data, byteCount: Int64, isJournalStaged: Bool) {
        self.fileURL = fileURL
        self.contentSHA256 = contentSHA256
        self.byteCount = byteCount
        self.isJournalStaged = isJournalStaged
    }

    func validated() throws -> Self {
        guard fileURL.isFileURL,
              contentSHA256.count == SHA256.byteCount,
              byteCount >= 0 else {
            throw SyncMutationJournalError.invalidAttachment
        }
        return self
    }
}

public struct SyncSaveMutation: Codable, Equatable, Sendable {
    public let recordVersion: SyncRecordVersion
    public let attachmentSource: SyncAttachmentSource?
    public let mutationID: UUID

    public init(
        recordVersion: SyncRecordVersion,
        attachmentSource: SyncAttachmentSource? = nil,
        mutationID: UUID
    ) throws {
        self.recordVersion = try recordVersion.validated()
        self.attachmentSource = try attachmentSource?.validated()
        self.mutationID = mutationID
        try validateAttachmentBinding()
    }

    func replacingAttachmentSource(_ source: SyncAttachmentSource?) throws -> Self {
        try Self(
            recordVersion: recordVersion,
            attachmentSource: source,
            mutationID: mutationID
        )
    }

    func validated() throws -> Self {
        _ = try recordVersion.validated()
        _ = try attachmentSource?.validated()
        try validateAttachmentBinding()
        return self
    }

    func validatedForJournalLoad() throws -> Self {
        if recordVersion.record.id.kind == .knittingReminder {
            _ = try recordVersion.validatedForLegacyStandaloneReminderJournalMigration()
            _ = try attachmentSource?.validated()
            try validateAttachmentBinding()
            return self
        }
        return try validated()
    }

    private func validateAttachmentBinding() throws {
        let record = recordVersion.record
        if record.id.kind == .attachment {
            guard let attachment = try record.payload.attachment?.validated(),
                  record.id.uuid == attachment.versionID,
                  record.relationships.contains(where: {
                      $0.role == "owner" && $0.target == attachment.slot.owner
                  }) else {
                throw SyncMutationJournalError.invalidAttachment
            }
            if record.deletedAt.value == nil {
                guard let attachmentSource,
                      attachmentSource.contentSHA256 == attachment.contentSHA256,
                      attachmentSource.byteCount == attachment.byteCount else {
                    throw SyncMutationJournalError.invalidAttachment
                }
            } else if attachmentSource != nil {
                throw SyncMutationJournalError.invalidAttachment
            }
        } else if record.payload.attachment != nil || attachmentSource != nil {
            throw SyncMutationJournalError.invalidAttachment
        }
    }
}

public struct SyncDeleteMutation: Codable, Equatable, Sendable {
    public let recordID: SyncEntityID
    public let mutationID: UUID

    public init(recordID: SyncEntityID, mutationID: UUID) {
        self.recordID = recordID
        self.mutationID = mutationID
    }
}

public enum SyncMutation: Codable, Equatable, Sendable {
    case save(SyncSaveMutation)
    case delete(SyncDeleteMutation)

    public static func save(
        recordVersion: SyncRecordVersion,
        attachmentSource: SyncAttachmentSource? = nil,
        mutationID: UUID
    ) throws -> Self {
        .save(try SyncSaveMutation(
            recordVersion: recordVersion,
            attachmentSource: attachmentSource,
            mutationID: mutationID
        ))
    }

    public static func delete(_ recordID: SyncEntityID, mutationID: UUID) -> Self {
        .delete(SyncDeleteMutation(recordID: recordID, mutationID: mutationID))
    }

    public var recordID: SyncEntityID {
        switch self {
        case let .save(save): save.recordVersion.record.id
        case let .delete(delete): delete.recordID
        }
    }

    public var mutationID: UUID {
        switch self {
        case let .save(save): save.mutationID
        case let .delete(delete): delete.mutationID
        }
    }

    public var identity: SyncMutationIdentity {
        SyncMutationIdentity(recordID: recordID, mutationID: mutationID)
    }

    public var intent: SyncMutationIntent {
        switch self {
        case .save: .save
        case .delete: .delete
        }
    }

    public var savedRecordVersion: SyncRecordVersion? {
        guard case let .save(save) = self else { return nil }
        return save.recordVersion
    }

    public var attachmentSource: SyncAttachmentSource? {
        guard case let .save(save) = self else { return nil }
        return save.attachmentSource
    }

    func replacingAttachmentSource(_ source: SyncAttachmentSource?) throws -> Self {
        guard case let .save(save) = self else { return self }
        return .save(try save.replacingAttachmentSource(source))
    }

    func validated() throws -> Self {
        switch self {
        case let .save(save): return .save(try save.validated())
        case .delete: return self
        }
    }

    func validatedForJournalLoad() throws -> Self {
        switch self {
        case let .save(save): return .save(try save.validatedForJournalLoad())
        case .delete: return self
        }
    }
}

final class SyncJournalWriteLease {
    let location: URL
    private var active = true
    private let thread = pthread_self()
    private let readPending: ([SyncMutation]) throws -> [SyncMutation]
    private let append: ([SyncMutation]) throws -> Void
    private let readVersioned: () throws -> [SyncVersionedMutation]
    private let readRebaseHead: () throws -> Data
    private let preflight: (SyncJournalRebaseTransition) throws -> Void
    private let replace: (SyncJournalRebaseTransition) throws -> Bool
    private let retained: (SyncConflictInput) throws -> [SyncJournalRebaseTransition]

    fileprivate init(location: URL, pending: @escaping ([SyncMutation]) throws -> [SyncMutation],
                     enqueue: @escaping ([SyncMutation]) throws -> Void,
                     pendingVersioned: @escaping () throws -> [SyncVersionedMutation],
                     rebaseHistoryHeadSHA256: @escaping () throws -> Data,
                     preflightRebase: @escaping (SyncJournalRebaseTransition) throws -> Void,
                     rebase: @escaping (SyncJournalRebaseTransition) throws -> Bool,
                     retainedRebases: @escaping (SyncConflictInput) throws -> [SyncJournalRebaseTransition]) {
        self.location = location; readPending = pending; append = enqueue
        readVersioned = pendingVersioned; preflight = preflightRebase
        readRebaseHead = rebaseHistoryHeadSHA256
        replace = rebase; retained = retainedRebases
    }
    fileprivate func invalidate() { active = false }
    private func validateLifetime() throws {
        guard pthread_equal(thread, pthread_self()) != 0, active else {
            throw SyncMutationJournalError.corrupt
        }
    }
    func pending() throws -> [SyncMutation] { try pending(requiringRetainedProofsFor: []) }
    /// Absence from pending counts as an ACK only while the native journal
    /// still retains the exact immutable mutation proof from the predecessor.
    func pending(requiringRetainedProofsFor mutations: [SyncMutation]) throws -> [SyncMutation] {
        try validateLifetime()
        return try readPending(mutations)
    }
    func enqueue(_ mutations: [SyncMutation]) throws { try validateLifetime(); try append(mutations) }
    func pendingVersioned() throws -> [SyncVersionedMutation] { try validateLifetime(); return try readVersioned() }
    func rebaseHistoryHeadSHA256() throws -> Data { try validateLifetime(); return try readRebaseHead() }
    func preflightRebase(_ transition: SyncJournalRebaseTransition) throws { try validateLifetime(); try preflight(transition) }
    func rebase(_ transition: SyncJournalRebaseTransition) throws -> Bool { try validateLifetime(); return try replace(transition) }
    func retainedRebases(for input: SyncConflictInput) throws -> [SyncJournalRebaseTransition] {
        try validateLifetime(); return try retained(input)
    }
}

public enum SyncMutationJournalError: Error, Equatable, Sendable {
    case corrupt
    case unsafeFile
    case tooLarge
    case duplicateMutationID
    case invalidAttachment
}

public protocol SyncMutationJournalProtocol: Sendable {
    func enqueue(_ mutations: [SyncMutation]) throws
    func pending() throws -> [SyncMutation]
    func pendingVersioned() throws -> [SyncVersionedMutation]
    func acknowledge(_ identities: Set<SyncMutationIdentity>) throws
    func acknowledgeCurrentVersion(_ token: SyncMutationVersionToken) throws -> SyncVersionedAcknowledgementResult
}

public extension SyncMutationJournalProtocol {
    func enqueue(_ mutation: SyncMutation) throws {
        try enqueue([mutation])
    }

    func acknowledge(recordID: SyncEntityID, mutationID: UUID) throws {
        try acknowledge([SyncMutationIdentity(recordID: recordID, mutationID: mutationID)])
    }
}

enum SyncJournalFrameKind: UInt8, Codable, Sendable {
    case enqueue = 1
    case acknowledge = 2
    case cleanupCompletion = 3
    case rebase = 4
    case versionedAcknowledgement = 5
}

struct SyncJournalFrame: Codable, Sendable {
    let sequence: UInt64
    let kind: SyncJournalFrameKind
    let payload: Data
    let checksum: Data

    private enum CodingKeys: String, CodingKey {
        case version, sequence, kind, payload, checksum
    }

    init(
        sequence: UInt64,
        kind: SyncJournalFrameKind,
        payload: Data,
        checksum: Data
    ) {
        self.sequence = sequence
        self.kind = kind
        self.payload = payload
        self.checksum = checksum
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported sync journal frame version"
            )
        }
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        kind = try container.decode(SyncJournalFrameKind.self, forKey: .kind)
        payload = try container.decode(Data.self, forKey: .payload)
        checksum = try container.decode(Data.self, forKey: .checksum)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(kind, forKey: .kind)
        try container.encode(payload, forKey: .payload)
        try container.encode(checksum, forKey: .checksum)
    }
}

enum SyncMutationAttachmentEvidenceState: String, Codable, Equatable, Sendable {
    case canonicalSnapshotV2
    case opaqueV1
}

struct SyncMutationDuplicateProof: Codable, Equatable, Sendable {
    let mutationID: UUID
    let recordID: SyncEntityID
    let intent: SyncMutationIntent
    let recordVersionSHA256: Data?
    let attachmentContentSHA256: Data?
    let attachmentByteCount: Int64?
    let attachmentImmutableSnapshotSHA256: Data?
    let attachmentEvidenceState: SyncMutationAttachmentEvidenceState?
    let attachmentVersion: SyncAttachmentVersion?
    let attachmentWasDeleted: Bool?

    func asOpaqueV1AttachmentAuthority() -> Self {
        guard recordID.kind == .attachment else { return self }
        return Self(
            mutationID: mutationID,
            recordID: recordID,
            intent: intent,
            recordVersionSHA256: recordVersionSHA256,
            attachmentContentSHA256: attachmentContentSHA256,
            attachmentByteCount: attachmentByteCount,
            attachmentImmutableSnapshotSHA256: nil,
            attachmentEvidenceState: .opaqueV1,
            attachmentVersion: nil,
            attachmentWasDeleted: nil
        )
    }
}

struct SyncAttachmentCleanupIntent: Codable, Equatable, Hashable, Sendable {
    let mutationID: UUID
    let attachmentVersionID: UUID
}

struct SyncCleanupShardCompletion: Codable, Equatable, Sendable {
    let shardIndex: Int
    var completedOffsets: Data
}

struct SyncCleanupCompletion: Codable, Equatable, Sendable {
    var completedShardCount: Int
    var partialShards: [SyncCleanupShardCompletion]

    static let empty = SyncCleanupCompletion(
        completedShardCount: 0,
        partialShards: []
    )
}

struct SyncJournalCheckpoint: Codable, Sendable {
    static let emptyProofShardRoot = Data(SHA256.hash(data: Data()))

    let version: Int
    let throughSequence: UInt64
    let pending: [SyncMutation]
    let proofShardCount: Int
    let proofShardRoot: Data?
    let cleanupIntents: [SyncAttachmentCleanupIntent]
    let cleanupCompletion: SyncCleanupCompletion
    let legacyHistory: [SyncMutation]?
    let rebaseHistory: [SyncJournalRebaseTransition]
    let rebaseHistoryHeadSHA256: Data
    let versionedAcknowledgements: [SyncVersionedMutation]

    private enum CodingKeys: String, CodingKey {
        case version, throughSequence, pending, proofShardCount, proofShardRoot, cleanupIntents
        case cleanupCompletion, history, rebaseHistory, rebaseHistoryHeadSHA256, versionedAcknowledgements
    }

    init(
        version: Int = 4,
        throughSequence: UInt64,
        pending: [SyncMutation],
        proofShardCount: Int = 0,
        proofShardRoot: Data? = SyncJournalCheckpoint.emptyProofShardRoot,
        cleanupIntents: [SyncAttachmentCleanupIntent] = [],
        cleanupCompletion: SyncCleanupCompletion = .empty,
        rebaseHistory: [SyncJournalRebaseTransition] = [],
        rebaseHistoryHeadSHA256: Data = SyncConflictRebaseCoding.emptyRebaseHistoryHeadSHA256,
        versionedAcknowledgements: [SyncVersionedMutation] = []
    ) {
        self.version = version
        self.throughSequence = throughSequence
        self.pending = pending
        self.proofShardCount = proofShardCount
        self.proofShardRoot = proofShardRoot
        self.cleanupIntents = cleanupIntents
        self.cleanupCompletion = cleanupCompletion
        self.rebaseHistory = rebaseHistory
        self.rebaseHistoryHeadSHA256 = rebaseHistoryHeadSHA256
        self.versionedAcknowledgements = versionedAcknowledgements
        legacyHistory = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        throughSequence = try container.decode(UInt64.self, forKey: .throughSequence)
        pending = try container.decode([SyncMutation].self, forKey: .pending)
        proofShardCount = try container.decodeIfPresent(
            Int.self,
            forKey: .proofShardCount
        ) ?? 0
        proofShardRoot = try container.decodeIfPresent(Data.self, forKey: .proofShardRoot)
        cleanupIntents = try container.decodeIfPresent(
            [SyncAttachmentCleanupIntent].self,
            forKey: .cleanupIntents
        ) ?? []
        cleanupCompletion = try container.decodeIfPresent(
            SyncCleanupCompletion.self,
            forKey: .cleanupCompletion
        ) ?? .empty
        legacyHistory = try container.decodeIfPresent(
            [SyncMutation].self,
            forKey: .history
        )
        if version == 5 {
            rebaseHistory = try container.decode([SyncJournalRebaseTransition].self, forKey: .rebaseHistory)
            rebaseHistoryHeadSHA256 = try container.decode(Data.self, forKey: .rebaseHistoryHeadSHA256)
            versionedAcknowledgements = try container.decode([SyncVersionedMutation].self, forKey: .versionedAcknowledgements)
        } else {
            guard !container.contains(.rebaseHistory), !container.contains(.rebaseHistoryHeadSHA256),
                  !container.contains(.versionedAcknowledgements) else {
                throw SyncMutationJournalError.corrupt
            }
            rebaseHistory = []; versionedAcknowledgements = []
            rebaseHistoryHeadSHA256 = SyncConflictRebaseCoding.emptyRebaseHistoryHeadSHA256
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(throughSequence, forKey: .throughSequence)
        try container.encode(pending, forKey: .pending)
        try container.encode(proofShardCount, forKey: .proofShardCount)
        try container.encodeIfPresent(proofShardRoot, forKey: .proofShardRoot)
        try container.encode(cleanupIntents, forKey: .cleanupIntents)
        try container.encode(cleanupCompletion, forKey: .cleanupCompletion)
        if version == 5 {
            try container.encode(rebaseHistory, forKey: .rebaseHistory)
            try container.encode(rebaseHistoryHeadSHA256, forKey: .rebaseHistoryHeadSHA256)
            try container.encode(versionedAcknowledgements, forKey: .versionedAcknowledgements)
        } else if !rebaseHistory.isEmpty || !versionedAcknowledgements.isEmpty {
            throw SyncMutationJournalError.corrupt
        }
    }
}

final class SyncJournalURLCoordinator: @unchecked Sendable {
    let lock = NSLock()
    var requiresDurabilityRepair = true
}

final class SyncJournalURLCoordinatorRegistry: @unchecked Sendable {
    static let shared = SyncJournalURLCoordinatorRegistry()

    private let lock = NSLock()
    private var coordinators: [String: SyncJournalURLCoordinator] = [:]

    func coordinator(for url: URL) -> SyncJournalURLCoordinator {
        let key = url.standardizedFileURL.path
        return lock.withLock {
            if let existing = coordinators[key] { return existing }
            let created = SyncJournalURLCoordinator()
            coordinators[key] = created
            return created
        }
    }
}

struct SyncJournalIOCounters: Sendable {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var appendedFrameCount = 0
        var fullCheckpointRewriteCount = 0
        var bytesRead = 0
        var metadataReadCount = 0
        var cleanupCompletionShardProbeCount = 0
        var cleanupCompletionShardUpdateCount = 0
        var cleanupCompletionSortCount = 0
    }

    private let storage = Storage()

    var appendedFrameCount: Int {
        storage.lock.withLock { storage.appendedFrameCount }
    }

    var fullCheckpointRewriteCount: Int {
        storage.lock.withLock { storage.fullCheckpointRewriteCount }
    }

    var bytesRead: Int {
        storage.lock.withLock { storage.bytesRead }
    }

    var metadataReadCount: Int {
        storage.lock.withLock { storage.metadataReadCount }
    }

    var cleanupCompletionShardProbeCount: Int {
        storage.lock.withLock { storage.cleanupCompletionShardProbeCount }
    }

    var cleanupCompletionShardUpdateCount: Int {
        storage.lock.withLock { storage.cleanupCompletionShardUpdateCount }
    }

    var cleanupCompletionSortCount: Int {
        storage.lock.withLock { storage.cleanupCompletionSortCount }
    }

    fileprivate func recordAppendedFrames(_ count: Int) {
        storage.lock.withLock { storage.appendedFrameCount += count }
    }

    fileprivate func recordCheckpointRewrite() {
        storage.lock.withLock { storage.fullCheckpointRewriteCount += 1 }
    }

    fileprivate func recordBytesRead(_ count: Int) {
        storage.lock.withLock { storage.bytesRead += count }
    }

    fileprivate func recordMetadataRead() {
        storage.lock.withLock { storage.metadataReadCount += 1 }
    }

    fileprivate func recordCleanupCompletionShardProbe() {
        storage.lock.withLock { storage.cleanupCompletionShardProbeCount += 1 }
    }

    fileprivate func recordCleanupCompletionShardUpdate() {
        storage.lock.withLock { storage.cleanupCompletionShardUpdateCount += 1 }
    }

    fileprivate func recordCleanupCompletionSort() {
        storage.lock.withLock { storage.cleanupCompletionSortCount += 1 }
    }
}

public final class FileSyncMutationJournal: SyncMutationJournalProtocol, @unchecked Sendable {
    public static let maximumEncodedBytes = 64 * 1_024 * 1_024
    private static let proofShardEntryLimit = 128
    private static let maximumProofShardCount = 1_000_000
    private static let frameTrailerMagic = Data([
        0x4b, 0x4e, 0x4a, 0x46, 0x52, 0x4d, 0x31, 0x21
    ])
    private static let frameTrailerByteCount = MemoryLayout<UInt64>.size + 8

    typealias AtomicWrite = @Sendable (Data, URL) throws -> Void
    typealias AppendFrames = @Sendable (Data, URL) throws -> Void
    typealias SynchronizeFile = @Sendable (Int32) throws -> Void
    typealias SynchronizeDirectory = @Sendable (URL) throws -> Void
    typealias RemoveStagedFile = @Sendable (URL) throws -> Void

    private let url: URL
    private let atomicWrite: AtomicWrite
    private let appendFrames: AppendFrames
    private let synchronizeFile: SynchronizeFile
    private let synchronizeDirectory: SynchronizeDirectory
    private let removeStagedFile: RemoveStagedFile
    private let reader: SyncRegularFileReader
    private let counters: SyncJournalIOCounters
    private let coordinator: SyncJournalURLCoordinator
    private var loadedState: LoadedState?
    private var loadedFingerprint: JournalFingerprint?

    private var checkpointURL: URL { url.appendingPathExtension("checkpoint") }
    private var segmentURL: URL { url.appendingPathExtension("segment") }
    private var migratedURL: URL { url.appendingPathExtension("migrated") }

    private func proofShardURL(_ index: Int) -> URL {
        URL(
            fileURLWithPath: String(
                format: "%@.proofs.%08d",
                url.path,
                index
            )
        )
    }

    private var attachmentsDirectory: URL {
        url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).attachments",
            isDirectory: true
        )
    }

    public convenience init(url: URL) {
        self.init(
            url: url,
            reader: .init(),
            counters: SyncJournalIOCounters(),
            synchronizeDirectory: Self.defaultSynchronizeDirectory
        )
    }

    convenience init(url: URL, counters: SyncJournalIOCounters) {
        self.init(
            url: url,
            reader: .init(),
            counters: counters,
            synchronizeDirectory: Self.defaultSynchronizeDirectory
        )
    }

    convenience init(url: URL, synchronizeDirectory: @escaping SynchronizeDirectory) {
        self.init(
            url: url,
            reader: .init(),
            counters: SyncJournalIOCounters(),
            synchronizeDirectory: synchronizeDirectory
        )
    }

    convenience init(url: URL, reader: SyncRegularFileReader) {
        self.init(
            url: url,
            reader: reader,
            counters: SyncJournalIOCounters(),
            synchronizeDirectory: Self.defaultSynchronizeDirectory
        )
    }

    private convenience init(
        url: URL,
        reader: SyncRegularFileReader,
        counters: SyncJournalIOCounters,
        synchronizeDirectory: @escaping SynchronizeDirectory
    ) {
        self.init(
            url: url,
            atomicWrite: { data, destination in
                try Self.defaultAtomicWrite(
                    data,
                    to: destination,
                    synchronizeDirectory: synchronizeDirectory
                )
            },
            appendFrames: { data, destination in
                try Self.defaultAppendFrames(
                    data,
                    to: destination,
                    synchronizeFile: Self.defaultSynchronizeFile,
                    synchronizeDirectory: synchronizeDirectory
                )
            },
            synchronizeFile: Self.defaultSynchronizeFile,
            synchronizeDirectory: synchronizeDirectory,
            removeStagedFile: Self.defaultRemoveStagedFile,
            reader: reader,
            counters: counters
        )
    }

    convenience init(url: URL, atomicWrite: @escaping AtomicWrite) {
        self.init(
            url: url,
            counters: SyncJournalIOCounters(),
            atomicWrite: atomicWrite
        )
    }

    convenience init(
        url: URL,
        counters: SyncJournalIOCounters,
        atomicWrite: @escaping AtomicWrite
    ) {
        self.init(
            url: url,
            atomicWrite: atomicWrite,
            appendFrames: { data, destination in
                try Self.defaultAppendFrames(
                    data,
                    to: destination,
                    synchronizeFile: Self.defaultSynchronizeFile,
                    synchronizeDirectory: Self.defaultSynchronizeDirectory
                )
            },
            synchronizeFile: Self.defaultSynchronizeFile,
            synchronizeDirectory: Self.defaultSynchronizeDirectory,
            removeStagedFile: Self.defaultRemoveStagedFile,
            reader: .init(),
            counters: counters
        )
    }

    convenience init(
        url: URL,
        counters: SyncJournalIOCounters = SyncJournalIOCounters(),
        appendFrames: @escaping AppendFrames
    ) {
        self.init(
            url: url,
            atomicWrite: { data, destination in
                try Self.defaultAtomicWrite(
                    data,
                    to: destination,
                    synchronizeDirectory: Self.defaultSynchronizeDirectory
                )
            },
            appendFrames: appendFrames,
            synchronizeFile: Self.defaultSynchronizeFile,
            synchronizeDirectory: Self.defaultSynchronizeDirectory,
            removeStagedFile: Self.defaultRemoveStagedFile,
            reader: .init(),
            counters: counters
        )
    }

    convenience init(
        url: URL,
        coordinatorRegistry: SyncJournalURLCoordinatorRegistry = .shared,
        synchronizeFile: @escaping SynchronizeFile,
        synchronizeDirectory: @escaping SynchronizeDirectory,
        removeStagedFile: @escaping RemoveStagedFile = FileSyncMutationJournal.defaultRemoveStagedFile
    ) {
        self.init(
            url: url,
            atomicWrite: { data, destination in
                try Self.defaultAtomicWrite(
                    data,
                    to: destination,
                    synchronizeDirectory: synchronizeDirectory
                )
            },
            appendFrames: { data, destination in
                try Self.defaultAppendFrames(
                    data,
                    to: destination,
                    synchronizeFile: synchronizeFile,
                    synchronizeDirectory: synchronizeDirectory
                )
            },
            synchronizeFile: synchronizeFile,
            synchronizeDirectory: synchronizeDirectory,
            removeStagedFile: removeStagedFile,
            reader: .init(),
            counters: SyncJournalIOCounters(),
            coordinatorRegistry: coordinatorRegistry
        )
    }

    init(
        url: URL,
        atomicWrite: @escaping AtomicWrite,
        reader: SyncRegularFileReader
    ) {
        self.url = url
        self.atomicWrite = atomicWrite
        self.appendFrames = { data, destination in
            try Self.defaultAppendFrames(
                data,
                to: destination,
                synchronizeFile: Self.defaultSynchronizeFile,
                synchronizeDirectory: Self.defaultSynchronizeDirectory
            )
        }
        self.synchronizeFile = Self.defaultSynchronizeFile
        self.synchronizeDirectory = Self.defaultSynchronizeDirectory
        self.removeStagedFile = Self.defaultRemoveStagedFile
        self.reader = reader
        self.counters = SyncJournalIOCounters()
        self.coordinator = SyncJournalURLCoordinatorRegistry.shared.coordinator(for: url)
    }

    init(
        url: URL,
        atomicWrite: @escaping AtomicWrite,
        appendFrames: @escaping AppendFrames,
        synchronizeFile: @escaping SynchronizeFile,
        synchronizeDirectory: @escaping SynchronizeDirectory,
        removeStagedFile: @escaping RemoveStagedFile = FileSyncMutationJournal.defaultRemoveStagedFile,
        reader: SyncRegularFileReader,
        counters: SyncJournalIOCounters,
        coordinatorRegistry: SyncJournalURLCoordinatorRegistry = .shared
    ) {
        self.url = url
        self.atomicWrite = atomicWrite
        self.appendFrames = appendFrames
        self.synchronizeFile = synchronizeFile
        self.synchronizeDirectory = synchronizeDirectory
        self.removeStagedFile = removeStagedFile
        self.reader = reader
        self.counters = counters
        self.coordinator = coordinatorRegistry.coordinator(for: url)
    }

    public func enqueue(_ mutations: [SyncMutation]) throws {
        guard !mutations.isEmpty else { return }
        try withJournalCoordination { try enqueueLocked(mutations) }
    }

    private func enqueueLocked(_ mutations: [SyncMutation]) throws {
        guard !mutations.isEmpty else { return }
            var candidate = try preparedStateLocked()
            let validatedRequests = try mutations.map { try $0.validated() }
            var preflightProofs = candidate.proofsByShard.flatMap { $0 }
                + candidate.unpersistedProofs
                + (try candidate.rebaseHistory.flatMap(\.after).map(Self.duplicateProof(for:)))
            for requested in validatedRequests {
                let requestedProof = try Self.duplicateProof(for: requested)
                if let existing = effectiveProof(for: requested.mutationID, in: candidate) {
                    guard Self.proofsMatch(existing, requestedProof) else {
                        throw SyncMutationJournalError.duplicateMutationID
                    }
                } else {
                    preflightProofs.append(requestedProof)
                }
            }
            try Self.validateAttachmentLineage(
                proofs: preflightProofs,
                failure: .invalidAttachment
            )
            var frames: [SyncJournalFrame] = []
            var staging: [SyncMutation] = []
            for requested in validatedRequests {
                let requestedProof = try Self.duplicateProof(for: requested)
                if let existing = effectiveProof(for: requested.mutationID, in: candidate) {
                    guard Self.proofsMatch(existing, requestedProof) else {
                        throw SyncMutationJournalError.duplicateMutationID
                    }
                    continue
                }
                let staged = try stagedAttachmentMetadata(for: requested)
                let frame = try makeFrame(
                    sequence: candidate.nextSequence,
                    kind: .enqueue,
                    value: staged
                )
                try apply(frame, to: &candidate)
                frames.append(frame)
                staging.append(requested)
            }
            guard !frames.isEmpty else {
                try compactIfNeededLocked()
                return
            }
            if candidate.usesCheckpointV5 { try preflightConflictPersistence(candidate, frames: frames) }
            for requested in staging { _ = try stageAttachmentIfNeeded(for: requested) }
            try appendReconcilingMemoryLocked(frames, candidate: candidate)
    }

    /// Lock order: account ownership, process coordinator, journal parent flock,
    /// then publication/checkpoint/evidence locks. Never reenter a public journal API.
    func withExclusivePending<T>(_ body: (SyncJournalWriteLease) throws -> T) throws -> T {
        try withJournalCoordination {
            let lease = SyncJournalWriteLease(location: url, pending: { requiredMutations in
                guard !(try self.pathExists(self.url)) else { throw SyncMutationJournalError.corrupt }
                let state = try self.loadSegmentedStateLocked(readOnly: true)
                guard !state.hasPartialFinalFrame, state.cleanupIntentsByMutationID.isEmpty else {
                    throw SyncMutationJournalError.corrupt
                }
                for mutation in requiredMutations {
                    let expected = try Self.duplicateProof(for: mutation.validatedForJournalLoad())
                    let proofs = [state.seenByMutationID[mutation.mutationID]].compactMap { $0 }
                        + (try state.rebaseHistory.flatMap(\.after).filter { $0.mutationID == mutation.mutationID }
                            .map(Self.duplicateProof(for:)))
                    guard proofs.contains(where: { Self.proofsMatch($0, expected) }) else { throw SyncMutationJournalError.corrupt }
                }
                return state.pending
            }, enqueue: { try self.enqueueLocked($0) }, pendingVersioned: {
                try self.versionedPending(in: self.conflictStateLocked())
            }, rebaseHistoryHeadSHA256: {
                try self.conflictStateLocked().rebaseHistoryHeadSHA256
            }, preflightRebase: {
                guard let candidate = try self.rebaseCandidate($0, state: self.conflictStateLocked()) else {
                    throw SyncConflictError.missingAuthority
                }
                try self.preflightConflictPersistence(candidate.state, frames: [candidate.frame])
            }, rebase: { transition in
                guard let candidate = try self.rebaseCandidate(transition, state: self.conflictStateLocked()) else { return false }
                try self.preflightConflictPersistence(candidate.state, frames: [candidate.frame])
                for mutation in transition.after { try self.validatePersistedAttachmentSource(in: mutation) }
                try self.repairDurabilityIfNeededLocked(candidate.state)
                try self.appendReconcilingMemoryLocked([candidate.frame], candidate: candidate.state)
                return true
            }, retainedRebases: { input in
                _ = try input.validated()
                return try self.conflictStateLocked().rebaseHistory.filter {
                    $0.input.accountIDHash == input.accountIDHash && $0.input.failedAttemptID == input.failedAttemptID
                        && $0.input.failedMutation == input.failedMutation && $0.input.failedVersion == input.failedVersion
                        && $0.input.serverRecord == input.serverRecord
                }
            })
            defer { lease.invalidate() }
            return try body(lease)
        }
    }

    private static func duplicateProof(
        for mutation: SyncMutation
    ) throws -> SyncMutationDuplicateProof {
        let recordVersionSHA256: Data?
        if let recordVersion = mutation.savedRecordVersion {
            let encoded = try deterministicEncoder(
                allowLegacyReminder: true
            ).encode(recordVersion)
            recordVersionSHA256 = Data(SHA256.hash(data: encoded))
        } else {
            recordVersionSHA256 = nil
        }
        let attachmentRecord = mutation.savedRecordVersion?.record.payload.attachment == nil
            ? nil
            : mutation.savedRecordVersion?.record
        let attachmentImmutableSnapshotSHA256 = try attachmentRecord.map {
            try SyncAttachmentImmutableSnapshot(record: $0).sha256
        }
        let attachmentEvidenceState: SyncMutationAttachmentEvidenceState? = if attachmentRecord != nil {
            .canonicalSnapshotV2
        } else if mutation.recordID.kind == .attachment {
            // A bare delete names a version without carrying the immutable
            // snapshot. Reserve that version as opaque authority regardless
            // of whether it came from a legacy envelope, checkpoint, segment,
            // or a newly enqueued mutation.
            .opaqueV1
        } else {
            nil
        }
        return SyncMutationDuplicateProof(
            mutationID: mutation.mutationID,
            recordID: mutation.recordID,
            intent: mutation.intent,
            recordVersionSHA256: recordVersionSHA256,
            attachmentContentSHA256: mutation.attachmentSource?.contentSHA256,
            attachmentByteCount: mutation.attachmentSource?.byteCount,
            attachmentImmutableSnapshotSHA256: attachmentImmutableSnapshotSHA256,
            attachmentEvidenceState: attachmentEvidenceState,
            attachmentVersion: mutation.savedRecordVersion?.record.payload.attachment,
            attachmentWasDeleted: mutation.savedRecordVersion?.record.payload.attachment == nil
                ? nil
                : mutation.savedRecordVersion?.record.deletedAt.value != nil
        )
    }

    private static func validateDuplicateProof(
        _ proof: SyncMutationDuplicateProof
    ) throws {
        let recordVersionIsValid = proof.intent == .save
            ? proof.recordVersionSHA256?.count == SHA256.byteCount
            : proof.recordVersionSHA256 == nil
        let attachmentIsValid: Bool
        switch (proof.attachmentContentSHA256, proof.attachmentByteCount) {
        case (nil, nil):
            attachmentIsValid = true
        case let (.some(digest), .some(byteCount)):
            attachmentIsValid = digest.count == SHA256.byteCount && byteCount >= 0
        default:
            attachmentIsValid = false
        }
        let isAttachmentSave = proof.intent == .save && proof.recordID.kind == .attachment
        let attachmentMatchesRecordKind: Bool
        switch proof.attachmentEvidenceState {
        case .canonicalSnapshotV2:
            guard let version = proof.attachmentVersion,
                  let wasDeleted = proof.attachmentWasDeleted else {
                throw SyncMutationJournalError.corrupt
            }
            attachmentMatchesRecordKind = proof.intent == .save
                && proof.recordID.kind == .attachment
                && version.versionID == proof.recordID.uuid
                && proof.attachmentImmutableSnapshotSHA256?.count == SHA256.byteCount
                && (wasDeleted
                    ? proof.attachmentContentSHA256 == nil
                    : proof.attachmentContentSHA256 == version.contentSHA256
                        && proof.attachmentByteCount == version.byteCount)
        case .opaqueV1:
            attachmentMatchesRecordKind = proof.recordID.kind == .attachment
                && proof.attachmentImmutableSnapshotSHA256 == nil
                && proof.attachmentVersion == nil
                && proof.attachmentWasDeleted == nil
        case nil:
            attachmentMatchesRecordKind = !isAttachmentSave
                && proof.attachmentImmutableSnapshotSHA256 == nil
                && proof.attachmentVersion == nil
                && proof.attachmentWasDeleted == nil
                && proof.attachmentContentSHA256 == nil
                && proof.attachmentByteCount == nil
        }
        guard recordVersionIsValid,
              attachmentIsValid,
              attachmentMatchesRecordKind,
              proof.intent == .save || proof.attachmentContentSHA256 == nil else {
            throw SyncMutationJournalError.corrupt
        }
    }

    private static func proofsMatch(
        _ lhs: SyncMutationDuplicateProof,
        _ rhs: SyncMutationDuplicateProof
    ) -> Bool {
        guard lhs.mutationID == rhs.mutationID,
              lhs.recordID == rhs.recordID,
              lhs.intent == rhs.intent,
              lhs.recordVersionSHA256 == rhs.recordVersionSHA256,
              lhs.attachmentContentSHA256 == rhs.attachmentContentSHA256,
              lhs.attachmentByteCount == rhs.attachmentByteCount else { return false }
        if lhs.attachmentEvidenceState == .opaqueV1
            || rhs.attachmentEvidenceState == .opaqueV1 {
            return true
        }
        return lhs.attachmentEvidenceState == rhs.attachmentEvidenceState
            && lhs.attachmentImmutableSnapshotSHA256
                == rhs.attachmentImmutableSnapshotSHA256
            && lhs.attachmentVersion == rhs.attachmentVersion
            && lhs.attachmentWasDeleted == rhs.attachmentWasDeleted
    }

    private static func validateAttachmentLineage(
        proofs: [SyncMutationDuplicateProof],
        failure: SyncMutationJournalError
    ) throws {
        let opaqueVersionIDs = Set(proofs.compactMap { proof in
            proof.attachmentEvidenceState == .opaqueV1 ? proof.recordID.uuid : nil
        })
        var attachmentVersionByVersionID: [UUID: SyncAttachmentVersion] = [:]
        var canonicalDigestByVersionID: [UUID: Data] = [:]
        for proof in proofs where proof.attachmentEvidenceState == .canonicalSnapshotV2 {
            guard let version = proof.attachmentVersion,
                  let digest = proof.attachmentImmutableSnapshotSHA256 else {
                throw SyncMutationJournalError.corrupt
            }
            guard !opaqueVersionIDs.contains(version.versionID),
                  version.replacesVersionID.map({ !opaqueVersionIDs.contains($0) }) ?? true else {
                throw SyncMutationJournalError.corrupt
            }
            if let existing = attachmentVersionByVersionID[version.versionID],
               existing != version {
                throw failure
            }
            if let existing = canonicalDigestByVersionID[version.versionID],
               existing != digest {
                throw SyncMutationJournalError.corrupt
            }
            attachmentVersionByVersionID[version.versionID] = version
            canonicalDigestByVersionID[version.versionID] = digest
        }

        var records: [SyncRecord] = []
        let stamp = SyncMutationStamp(
            logicalRevision: 0,
            modifiedAt: .distantPast,
            deviceID: "journal-proof"
        )
        for proof in proofs where proof.attachmentEvidenceState == .canonicalSnapshotV2 {
            guard let version = proof.attachmentVersion else { continue }
            records.append(SyncRecord(
                schemaVersion: 1,
                id: .init(kind: .attachment, uuid: version.versionID),
                createdAt: .distantPast,
                entityRevision: 0,
                payload: .init(fields: [:], attachment: version),
                relationships: [.init(role: "owner", target: version.slot.owner)],
                deletedAt: .init(
                    value: proof.attachmentWasDeleted == true ? .distantPast : nil,
                    stamp: stamp
                )
            ))
        }
        var tombstonedVersionIDs: Set<UUID> = []
        for proof in proofs where proof.attachmentEvidenceState == .canonicalSnapshotV2 {
            guard let version = proof.attachmentVersion else { continue }
            if proof.attachmentWasDeleted == true {
                tombstonedVersionIDs.insert(version.versionID)
            } else if tombstonedVersionIDs.contains(version.versionID) {
                throw failure
            }
        }
        do {
            _ = try SyncAttachmentLineage(records: records)
        } catch {
            throw failure
        }
    }

    public func pending() throws -> [SyncMutation] {
        try withJournalCoordination { try preparedStateLocked().pending }
    }

    public func pendingVersioned() throws -> [SyncVersionedMutation] {
        try withJournalCoordination { try versionedPending(in: conflictStateLocked()) }
    }

    /// Conflict decisions are pure reads until exact authority and all projected
    /// sizes pass. Incomplete tails must be recovered by their original writer.
    private func conflictStateLocked() throws -> LoadedState {
        guard !(try pathExists(url)) else { throw SyncConflictError.missingAuthority }
        let state = try loadSegmentedStateLocked(readOnly: true)
        guard !state.hasPartialFinalFrame else { throw SyncMutationJournalError.corrupt }
        loadedState = state
        return state
    }

    private func effectiveProof(for id: UUID, in state: LoadedState) -> SyncMutationDuplicateProof? {
        state.rebasedProofs[id] ?? state.seenByMutationID[id]
    }

    private func versionedPending(in state: LoadedState) throws -> [SyncVersionedMutation] {
        try state.pending.map {
            try SyncVersionedMutation(mutation: $0, journalRevision: state.revisions[$0.mutationID] ?? 0)
        }
    }

    private func rebaseCandidate(_ transition: SyncJournalRebaseTransition, state: LoadedState) throws
        -> (state: LoadedState, frame: SyncJournalFrame)? {
        _ = try transition.validated()
        if let retained = state.rebaseHistory.first(where: { $0.transactionID == transition.transactionID }) {
            guard retained == transition else { throw SyncConflictError.identityCollision }
            return nil
        }
        let current = try versionedPending(in: state)
        guard state.rebaseHistoryHeadSHA256 == transition.predecessorRebaseHeadSHA256,
              try SyncConflictRebaseCoding.pendingDigest(current) == transition.predecessorPendingSHA256,
              current.indices.filter({ current[$0].mutation.recordID == transition.input.serverRecord.id }) == transition.recordPositions,
              transition.recordPositions.allSatisfy({ current.indices.contains($0) }),
              transition.recordPositions.map({ current[$0].mutation }) == transition.before,
              transition.recordPositions.map({ current[$0].token }) == transition.beforeVersions else { return nil }
        let frame = try makeFrame(sequence: state.nextSequence, kind: .rebase, value: transition)
        var candidate = state
        try apply(frame, to: &candidate)
        return (candidate, frame)
    }

    /// Reconstruct effective authority without altering issued immutable shards.
    /// Always run before pending/ACK/cleanup checks, even for completed offsets.
    private func applyRebaseHistory(_ transition: SyncJournalRebaseTransition, to state: inout LoadedState) throws {
        _ = try transition.validated()
        guard transition.predecessorRebaseHeadSHA256 == state.rebaseHistoryHeadSHA256,
              !state.rebaseHistory.contains(where: { $0.transactionID == transition.transactionID }) else {
            throw SyncMutationJournalError.corrupt
        }
        for index in transition.before.indices {
            let before = transition.before[index]
            let after = transition.after[index]
            guard state.versionedAcknowledgements[before.mutationID] == nil,
                  let prior = effectiveProof(for: before.mutationID, in: state),
                  Self.proofsMatch(prior, try Self.duplicateProof(for: before)),
                  state.rebasedMutations[before.mutationID].map({ $0 == before }) ?? true,
                  transition.beforeVersions[index].journalRevision == (state.revisions[before.mutationID] ?? 0),
                  after.attachmentSource == nil || after.attachmentSource == before.attachmentSource else {
                throw SyncMutationJournalError.corrupt
            }
            state.rebasedProofs[after.mutationID] = try Self.duplicateProof(for: after)
            state.rebasedMutations[after.mutationID] = after
            state.revisions[after.mutationID] = transition.afterVersions[index].journalRevision
        }
        state.rebaseHistory.append(transition)
        state.usesCheckpointV5 = true
        try Self.validateAttachmentLineage(
            proofs: state.proofsByShard.flatMap { $0 } + state.unpersistedProofs
                + (try state.rebaseHistory.flatMap(\.after).map(Self.duplicateProof(for:))), failure: .corrupt)
    }

    private func validateVersionedReceipts(in state: LoadedState) throws {
        let pendingIDs = Set(state.pending.map(\.mutationID))
        // Issued proof plus absence (even a completed cleanup offset) cannot
        // authorize removal of a rebased version. Require its exact receipt;
        // checkpoint pending may instead be removed by a later kind-5 frame.
        for id in state.rebasedMutations.keys where !pendingIDs.contains(id) {
            guard state.versionedAcknowledgements[id] != nil else {
                throw SyncMutationJournalError.corrupt
            }
        }
        for (id, receipt) in state.versionedAcknowledgements {
            guard id == receipt.mutation.mutationID, !pendingIDs.contains(id),
                  let proof = effectiveProof(for: id, in: state),
                  Self.proofsMatch(proof, try Self.duplicateProof(for: receipt.mutation)),
                  state.rebasedMutations[id].map({ $0 == receipt.mutation }) ?? true,
                  receipt.token == (try SyncMutationVersionToken(mutation: receipt.mutation,
                    journalRevision: state.revisions[id] ?? 0)) else {
                throw SyncMutationJournalError.corrupt
            }
        }
    }

    /// Size both the append state and the eventual compacted checkpoint before
    /// any durable intent. Project new shards in memory with their exact roots.
    private func preflightConflictPersistence(_ state: LoadedState, frames: [SyncJournalFrame]) throws {
        var projected = state
        var shardBytes = 0
        for index in 0..<state.proofShardCount {
            guard let data = try readArtifact(proofShardURL(index), maximumBytes: Self.maximumEncodedBytes) else {
                throw SyncMutationJournalError.corrupt
            }
            shardBytes += data.count
            guard shardBytes <= Self.maximumEncodedBytes else { throw SyncMutationJournalError.tooLarge }
        }
        for start in stride(from: 0, to: state.unpersistedProofs.count, by: Self.proofShardEntryLimit) {
            guard projected.proofShardCount < Self.maximumProofShardCount else { throw SyncMutationJournalError.tooLarge }
            let proofs = Array(state.unpersistedProofs[start..<min(start + Self.proofShardEntryLimit, state.unpersistedProofs.count)])
            let data = try encodeProofShard(index: projected.proofShardCount, proofs: proofs)
            shardBytes += data.count
            guard shardBytes <= Self.maximumEncodedBytes else { throw SyncMutationJournalError.tooLarge }
            for (offset, proof) in proofs.enumerated() {
                projected.proofLocationsByMutationID[proof.mutationID] = .init(shardIndex: projected.proofShardCount, offset: offset)
            }
            projected.proofShardRoot = Self.proofShardRoot(appending: data, index: projected.proofShardCount, to: projected.proofShardRoot)
            projected.proofsByShard.append(proofs)
            projected.proofShardCount += 1
        }
        for id in state.cleanupCompletion.completedUnpersistedMutationIDs {
            guard let location = projected.proofLocationsByMutationID[id] else { throw SyncMutationJournalError.corrupt }
            Self.markCleanupCompleted(location, completion: &projected.cleanupCompletion, counters: SyncJournalIOCounters())
        }
        projected.cleanupCompletion.completedUnpersistedMutationIDs = []
        let checkpoint = try encodeCheckpoint(conflictCheckpoint(for: projected))
        let appended = try encodeFrames(frames)
        let existingCheckpointBytes = try readArtifact(checkpointURL, maximumBytes: Self.maximumEncodedBytes)?.count ?? 0
        guard checkpoint.count <= Self.maximumEncodedBytes - shardBytes,
              state.validSegmentByteCount <= Self.maximumEncodedBytes - appended.count,
              checkpoint.count + shardBytes <= Self.maximumEncodedBytes - state.validSegmentByteCount - appended.count,
              existingCheckpointBytes + shardBytes <= Self.maximumEncodedBytes - state.validSegmentByteCount - appended.count else {
            throw SyncMutationJournalError.tooLarge
        }
    }

    private func conflictCheckpoint(for state: LoadedState) throws -> SyncJournalCheckpoint {
        SyncJournalCheckpoint(version: state.usesCheckpointV5 ? 5 : 4,
            throughSequence: state.nextSequence - 1, pending: state.pending,
            proofShardCount: state.proofShardCount, proofShardRoot: state.proofShardRoot,
            cleanupCompletion: try checkpointCleanupCompletion(from: state.cleanupCompletion),
            rebaseHistory: state.rebaseHistory,
            rebaseHistoryHeadSHA256: state.rebaseHistoryHeadSHA256,
            versionedAcknowledgements: state.versionedAcknowledgements.values.sorted {
                Self.identityPrecedes($0.mutation.identity, $1.mutation.identity)
            })
    }

    public func acknowledgeCurrentVersion(_ token: SyncMutationVersionToken) throws -> SyncVersionedAcknowledgementResult {
        try withJournalCoordination {
            var state = try conflictStateLocked()
            guard let current = try versionedPending(in: state).first(where: { $0.mutation.identity == token.identity }) else {
                guard state.versionedAcknowledgements[token.identity.mutationID]?.token == token else { return .staleVersion }
                try repairDurabilityIfNeededLocked(state)
                try reconcileAcknowledgedAttachmentsLocked()
                return .alreadyAcknowledged
            }
            guard current.token == token else { return .staleVersion }
            let frame = try makeFrame(sequence: state.nextSequence, kind: .versionedAcknowledgement, value: token)
            try apply(frame, to: &state)
            try preflightConflictPersistence(state, frames: [frame])
            try repairDurabilityIfNeededLocked(state)
            try appendReconcilingMemoryLocked([frame], candidate: state)
            try reconcileAcknowledgedAttachmentsLocked()
            return .acknowledged
        }
    }

    /// Only used while the caller retains exclusive account ownership/freeze.
    /// No parent creation, legacy migration, durability repair or acknowledged
    /// source reclamation occurs here. The concrete URL binds replay ownership.
    func recoverySnapshot(maximumBytes: Int = 100_000_000) throws -> (url: URL, mutations: [SyncMutation]) {
        try coordinator.lock.withLock {
            guard maximumBytes >= 0, maximumBytes <= 100_000_000 else { throw SyncMutationJournalError.tooLarge }
            guard !(try pathExists(url)) else { throw SyncMutationJournalError.corrupt }
            let state = try loadSegmentedStateLocked(readOnly: true, maximumReadBytes: maximumBytes)
            guard !state.hasPartialFinalFrame,
                  state.cleanupIntentsByMutationID.isEmpty else { throw SyncMutationJournalError.corrupt }
            return (url, state.pending)
        }
    }

    var recoveryLocation: URL { url }

    /// Read-only representability/size gate before a sealed packet may authorize
    /// removal. Uses the native enqueue encoder; never migrates legacy records.
    func preflightRecoveryReplay(_ mutations: [SyncMutation], maximumBytes: Int) throws {
        _ = try recoveryReplayFrames(mutations, maximumBytes: maximumBytes)
    }

    private func recoveryReplayFrames(_ mutations: [SyncMutation], maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0, maximumBytes <= 100_000_000 else { throw SyncMutationJournalError.tooLarge }
        let limit = min(maximumBytes, Self.maximumEncodedBytes)
        var expected = Data(), identities = Set<UUID>()
        for (index, mutation) in mutations.enumerated() {
            _ = try mutation.validated()
            guard identities.insert(mutation.mutationID).inserted else { throw SyncMutationJournalError.duplicateMutationID }
            let frame = try encodeFrames([makeFrame(sequence: UInt64(index + 1), kind: .enqueue, value: mutation)])
            guard frame.count <= limit - expected.count else { throw SyncMutationJournalError.tooLarge }
            expected.append(frame)
        }
        try Self.validateAttachmentLineage(proofs: mutations.map { try Self.duplicateProof(for: $0) }, failure: .invalidAttachment)
        return expected
    }

    /// The account owner retains its freeze throughout installation and replay.
    /// An empty journal replayed only by enqueue cannot compact: compaction also
    /// requires acknowledgements. Its sole generated artifact is this segment.
    /// Compare native encoded frames, including any interrupted final append,
    /// before allowing the normal journal to truncate/retry a proven suffix.
    func validateRecoveryReplay(_ mutations: [SyncMutation], maximumBytes: Int) throws
        -> (complete: Bool, segment: URL?) {
        try coordinator.lock.withLock {
            guard maximumBytes >= 0, maximumBytes <= 100_000_000,
                  !(try pathExists(url)), !(try pathExists(checkpointURL)),
                  !(try pathExists(migratedURL)) else { throw SyncMutationJournalError.corrupt }
            let expected = try recoveryReplayFrames(mutations, maximumBytes: maximumBytes)
            let existing = try readArtifact(segmentURL, maximumBytes: min(maximumBytes, Self.maximumEncodedBytes))
            guard !mutations.isEmpty || existing == nil else { throw SyncMutationJournalError.corrupt }
            let bytes = existing ?? Data()
            guard bytes.count <= expected.count, expected.starts(with: bytes) else { throw SyncMutationJournalError.corrupt }
            let state = try loadSegmentedStateLocked(readOnly: true, maximumReadBytes: maximumBytes)
            guard state.pending == Array(mutations.prefix(state.pending.count)),
                  state.seenByMutationID.count == state.pending.count,
                  state.cleanupIntentsByMutationID.isEmpty, state.proofShardCount == 0,
                  state.acknowledgedOperationCount == 0 else { throw SyncMutationJournalError.corrupt }
            return (bytes == expected, existing == nil ? nil : segmentURL)
        }
    }

    public func acknowledge(_ identities: Set<SyncMutationIdentity>) throws {
        guard !identities.isEmpty else { return }
        try withJournalCoordination {
            var candidate = try preparedStateLocked()
            guard !identities.contains(where: { candidate.revisions[$0.mutationID] != nil }) else {
                throw SyncConflictError.missingAuthority
            }
            let removed = candidate.pending.filter { identities.contains($0.identity) }
            guard !removed.isEmpty else {
                try compactIfNeededLocked()
                return
            }
            let sortedIdentities = removed.map(\.identity).sorted(by: Self.identityPrecedes)
            var frames: [SyncJournalFrame] = []
            for identity in sortedIdentities {
                let frame = try makeFrame(
                    sequence: candidate.nextSequence,
                    kind: .acknowledge,
                    value: identity
                )
                try apply(frame, to: &candidate)
                frames.append(frame)
            }
            try appendReconcilingMemoryLocked(frames, candidate: candidate)
            try reconcileAcknowledgedAttachmentsLocked()
        }
    }

    private static func identityPrecedes(
        _ lhs: SyncMutationIdentity,
        _ rhs: SyncMutationIdentity
    ) -> Bool {
        let left = (
            lhs.recordID.kind.rawValue,
            lhs.recordID.uuid.uuidString,
            lhs.mutationID.uuidString
        )
        let right = (
            rhs.recordID.kind.rawValue,
            rhs.recordID.uuid.uuidString,
            rhs.mutationID.uuidString
        )
        return left < right
    }

    private func withJournalCoordination<Result>(
        _ operation: () throws -> Result
    ) throws -> Result {
        try coordinator.lock.withLock {
            try withParentDirectoryLock {
                let fingerprint = try journalFingerprintLocked()
                if loadedFingerprint != fingerprint {
                    loadedState = nil
                    loadedFingerprint = nil
                    coordinator.requiresDurabilityRepair = true
                }
                do {
                    let result = try operation()
                    loadedFingerprint = try journalFingerprintLocked()
                    return result
                } catch {
                    loadedState = nil
                    loadedFingerprint = nil
                    throw error
                }
            }
        }
    }

    private func preparedStateLocked() throws -> LoadedState {
        let state = try stateLocked()
        try repairDurabilityIfNeededLocked(state)
        try reconcileAcknowledgedAttachmentsLocked()
        return try stateLocked()
    }

    private func stateLocked() throws -> LoadedState {
        if let loadedState { return loadedState }
        let state = try loadStateLocked()
        loadedState = state
        return state
    }

    private func loadStateLocked() throws -> LoadedState {
        let hasCheckpoint = try pathExists(checkpointURL)
        let hasSegment = try pathExists(segmentURL)
        if hasCheckpoint || hasSegment {
            let state = try loadSegmentedStateLocked()
            if try pathExists(url) {
                try finishInterruptedLegacyMigrationLocked(matching: state.pending)
            }
            return state
        }
        guard try pathExists(url) else { return .empty }
        return try migrateLegacyEnvelopeLocked()
    }

    private func loadSegmentedStateLocked(readOnly: Bool = false,
                                         maximumReadBytes: Int? = nil) throws -> LoadedState {
        // Nonmutating journal reads retain the encoded-authority bound. Only
        // explicit recovery capture also reserves media against a total budget.
        var remainingEncoded = Self.maximumEncodedBytes
        var remaining = maximumReadBytes
        func readSnapshotArtifact(_ location: URL) throws -> Data? {
            let limit = readOnly ? min(remainingEncoded, remaining ?? Self.maximumEncodedBytes) : Self.maximumEncodedBytes
            let bytes = try readArtifact(location, maximumBytes: limit)
            if readOnly {
                remainingEncoded -= bytes?.count ?? 0
                if let budget = remaining { remaining = budget - (bytes?.count ?? 0) }
            }
            return bytes
        }
        var verifiedRecoverySources: [URL: SyncAttachmentSource] = [:]
        func validateSource(_ mutation: SyncMutation) throws {
            if readOnly, let budget = remaining, let source = mutation.attachmentSource {
                if let previous = verifiedRecoverySources[source.fileURL] {
                    guard previous == source else { throw SyncMutationJournalError.invalidAttachment }
                    return
                }
                // Source validation materializes Data, so reserve its bytes from
                // the same remaining budget BEFORE entering that reader. A
                // checkpoint source repeated after segment replay is read once.
                guard source.byteCount >= 0, source.byteCount <= Int64(budget) else {
                    throw SyncMutationJournalError.tooLarge
                }
                remaining = budget - Int(source.byteCount)
                try validatePersistedAttachmentSource(in: mutation)
                verifiedRecoverySources[source.fileURL] = source
            } else {
                try validatePersistedAttachmentSource(in: mutation)
            }
        }
        var checkpoint = SyncJournalCheckpoint(throughSequence: 0, pending: [])
        var totalBytes = 0
        if let checkpointData = try readSnapshotArtifact(checkpointURL) {
            totalBytes += checkpointData.count
            checkpoint = try decodeCheckpoint(checkpointData)
        }
        guard (1...5).contains(checkpoint.version),
              checkpoint.throughSequence < UInt64.max,
              checkpoint.proofShardCount >= 0,
              checkpoint.proofShardCount <= Self.maximumProofShardCount,
              checkpoint.version < 4 || checkpoint.proofShardRoot?.count == SHA256.byteCount else {
            throw SyncMutationJournalError.corrupt
        }
        let cleanupCompletion = try cleanupCompletionState(
            from: checkpoint.cleanupCompletion
        )

        var seen: [UUID: SyncMutationDuplicateProof] = [:]
        var unpersistedProofs: [SyncMutationDuplicateProof] = []
        var cleanupIntents = checkpoint.cleanupIntents
        var proofLocations: [UUID: ProofLocation] = [:]
        var proofsByShard: [[SyncMutationDuplicateProof]] = []
        var proofShardRoot = SyncJournalCheckpoint.emptyProofShardRoot
        if checkpoint.version == 1 {
            let history = checkpoint.legacyHistory ?? checkpoint.pending
            let pendingIDs = Set(checkpoint.pending.map(\.mutationID))
            for mutation in history {
                let validated = try mutation.validatedForJournalLoad()
                let proof = try Self.duplicateProof(for: validated)
                guard seen[proof.mutationID] == nil else {
                    throw SyncMutationJournalError.corrupt
                }
                seen[proof.mutationID] = proof
                unpersistedProofs.append(proof)
                if !pendingIDs.contains(validated.mutationID),
                   let cleanup = Self.cleanupIntent(for: validated) {
                    cleanupIntents.append(cleanup)
                }
            }
        } else {
            for index in 0..<checkpoint.proofShardCount {
                guard let shardData = try readSnapshotArtifact(proofShardURL(index)) else {
                    throw SyncMutationJournalError.corrupt
                }
                proofShardRoot = Self.proofShardRoot(
                    appending: shardData,
                    index: index,
                    to: proofShardRoot
                )
                let shard = try decodeProofShard(shardData)
                guard shard.index == index,
                      !shard.proofs.isEmpty,
                      shard.proofs.count <= Self.proofShardEntryLimit else {
                    throw SyncMutationJournalError.corrupt
                }
                proofsByShard.append(shard.proofs)
                for (offset, proof) in shard.proofs.enumerated() {
                    try Self.validateDuplicateProof(proof)
                    guard seen[proof.mutationID] == nil else {
                        throw SyncMutationJournalError.corrupt
                    }
                    seen[proof.mutationID] = proof
                    proofLocations[proof.mutationID] = ProofLocation(
                        shardIndex: index,
                        offset: offset
                    )
                }
            }
            if checkpoint.version >= 4, checkpoint.proofShardRoot != proofShardRoot {
                throw SyncMutationJournalError.corrupt
            }
        }
        var historyState = LoadedState.empty
        historyState.seenByMutationID = seen
        historyState.proofsByShard = proofsByShard
        historyState.unpersistedProofs = unpersistedProofs
        for transition in checkpoint.rebaseHistory { try applyRebaseHistory(transition, to: &historyState) }
        guard checkpoint.rebaseHistoryHeadSHA256 == historyState.rebaseHistoryHeadSHA256 else {
            throw SyncMutationJournalError.corrupt
        }
        var pending: [SyncMutation] = []
        var uniquePendingIDs = Set<UUID>()
        for mutation in checkpoint.pending {
            let validated = try mutation.validatedForJournalLoad()
            let proof = try Self.duplicateProof(for: validated)
            guard uniquePendingIDs.insert(validated.mutationID).inserted else { throw SyncMutationJournalError.corrupt }
            guard historyState.rebasedMutations[validated.mutationID].map({ $0 == validated }) ?? true else {
                throw SyncMutationJournalError.corrupt
            }
            if let historical = historyState.rebasedProofs[validated.mutationID] ?? seen[validated.mutationID] {
                guard Self.proofsMatch(historical, proof) else {
                    throw SyncMutationJournalError.corrupt
                }
            } else {
                guard checkpoint.version < 5 else { throw SyncMutationJournalError.corrupt }
                seen[validated.mutationID] = proof
                unpersistedProofs.append(proof)
            }
            // Frames may durably ACK this checkpoint entry and remove its
            // staged bytes. Verify only the effective pending sources below,
            // after replay has validated that exact ACK authority.
            pending.append(validated)
        }
        var seenCleanupIntents = Set<SyncAttachmentCleanupIntent>()
        for cleanup in cleanupIntents {
            guard seenCleanupIntents.insert(cleanup).inserted,
                  let proof = seen[cleanup.mutationID],
                  Self.cleanupIntent(for: proof) == cleanup else {
                throw SyncMutationJournalError.corrupt
            }
        }
        let pendingIDs = Set(pending.map(\.mutationID))
        for proof in seen.values
        where !pendingIDs.contains(proof.mutationID) {
            if let cleanup = Self.cleanupIntent(for: proof),
               !Self.isCleanupCompleted(
                   proofLocations[proof.mutationID],
                   completion: cleanupCompletion,
                   counters: counters
               ),
               seenCleanupIntents.insert(cleanup).inserted {
                cleanupIntents.append(cleanup)
            }
        }
        var state = LoadedState(
            pending: pending,
            seenByMutationID: seen,
            proofShardCount: checkpoint.proofShardCount,
            proofShardRoot: proofShardRoot,
            unpersistedProofs: unpersistedProofs,
            proofLocationsByMutationID: proofLocations,
            proofsByShard: proofsByShard,
            cleanupIntentsByMutationID: Dictionary(
                uniqueKeysWithValues: cleanupIntents.map { ($0.mutationID, $0) }
            ),
            cleanupCompletion: cleanupCompletion,
            nextSequence: checkpoint.throughSequence + 1,
            framesSinceCheckpoint: 0,
            enqueuedOperationCount: 0,
            acknowledgedOperationCount: 0,
            validSegmentByteCount: 0,
            hasPartialFinalFrame: false
        )
        state.rebaseHistory = historyState.rebaseHistory
        state.rebasedProofs = historyState.rebasedProofs
        state.rebasedMutations = historyState.rebasedMutations
        state.revisions = historyState.revisions
        state.usesCheckpointV5 = checkpoint.version == 5
        var previousReceiptIdentity: SyncMutationIdentity?
        for receipt in checkpoint.versionedAcknowledgements {
            let identity = receipt.mutation.identity
            guard state.versionedAcknowledgements[identity.mutationID] == nil,
                  previousReceiptIdentity.map({ Self.identityPrecedes($0, identity) }) ?? true else {
                throw SyncMutationJournalError.corrupt
            }
            state.versionedAcknowledgements[identity.mutationID] = receipt
            previousReceiptIdentity = identity
        }
        try validateVersionedReceipts(in: state)

        if let segmentData = try readSnapshotArtifact(segmentURL) {
            totalBytes += segmentData.count
            guard totalBytes <= Self.maximumEncodedBytes else {
                throw SyncMutationJournalError.tooLarge
            }
            try replaySegment(segmentData, after: checkpoint.throughSequence, into: &state)
        }
        try Self.validateAttachmentLineage(
            proofs: state.proofsByShard.flatMap { $0 } + state.unpersistedProofs
                + (try state.rebaseHistory.flatMap(\.after).map(Self.duplicateProof(for:))),
            failure: .corrupt
        )
        for mutation in state.pending {
            try validateSource(mutation)
        }
        try validateVersionedReceipts(in: state)
        try validateCleanupCompletion(in: state)
        if readOnly { return state }
        if checkpoint.version == 1 {
            try replaceLegacyHistoryCheckpointLocked(&state)
        } else if checkpoint.version < 4 {
            // Upgrade older segmented layouts only after every referenced shard
            // and replayed frame has passed collective validation.
            try persistCheckpointLocked(&state)
        }
        return state
    }

    private func replaceLegacyHistoryCheckpointLocked(_ state: inout LoadedState) throws {
        if state.usesCheckpointV5 { try preflightConflictPersistence(state, frames: []) }
        let persistedProofs = state.unpersistedProofs
        var proofShardCount = 0
        var proofShardRoot = SyncJournalCheckpoint.emptyProofShardRoot
        for chunkStart in stride(
            from: 0,
            to: persistedProofs.count,
            by: Self.proofShardEntryLimit
        ) {
            let chunkEnd = min(
                chunkStart + Self.proofShardEntryLimit,
                persistedProofs.count
            )
            let shardData = try encodeProofShard(
                index: proofShardCount,
                proofs: Array(persistedProofs[chunkStart..<chunkEnd])
            )
            try atomicWrite(shardData, proofShardURL(proofShardCount))
            proofShardRoot = Self.proofShardRoot(
                appending: shardData,
                index: proofShardCount,
                to: proofShardRoot
            )
            proofShardCount += 1
        }
        let throughSequence = state.nextSequence - 1
        try atomicWrite(try encodeCheckpoint(SyncJournalCheckpoint(
            version: state.usesCheckpointV5 ? 5 : 4,
            throughSequence: throughSequence,
            pending: state.pending,
            proofShardCount: proofShardCount,
            proofShardRoot: proofShardRoot,
            cleanupIntents: [],
            rebaseHistory: state.rebaseHistory,
            rebaseHistoryHeadSHA256: state.rebaseHistoryHeadSHA256,
            versionedAcknowledgements: state.versionedAcknowledgements.values.sorted {
                Self.identityPrecedes($0.mutation.identity, $1.mutation.identity)
            }
        )), checkpointURL)
        counters.recordCheckpointRewrite()
        try atomicWrite(Data(), segmentURL)
        state.proofShardCount = proofShardCount
        state.proofShardRoot = proofShardRoot
        state.unpersistedProofs = []
        state.proofsByShard = stride(
            from: 0,
            to: persistedProofs.count,
            by: Self.proofShardEntryLimit
        ).map {
            Array(persistedProofs[$0..<min($0 + Self.proofShardEntryLimit, persistedProofs.count)])
        }
        state.proofLocationsByMutationID = [:]
        for (index, proof) in persistedProofs.enumerated() {
            let shardIndex = index / Self.proofShardEntryLimit
            let offset = index % Self.proofShardEntryLimit
            state.proofLocationsByMutationID[proof.mutationID] = ProofLocation(
                shardIndex: shardIndex,
                offset: offset
            )
        }
        state.framesSinceCheckpoint = 0
        state.cleanupCompletion.completedUnpersistedMutationIDs = []
        state.enqueuedOperationCount = 0
        state.acknowledgedOperationCount = 0
        state.validSegmentByteCount = 0
        state.hasPartialFinalFrame = false
    }

    private func replaySegment(
        _ data: Data,
        after checkpointSequence: UInt64,
        into state: inout LoadedState
    ) throws {
        var offset = 0
        var lastFrameSequence: UInt64?
        while offset < data.count {
            let frameStart = offset
            guard data.count - offset >= MemoryLayout<UInt64>.size else {
                state.validSegmentByteCount = frameStart
                state.hasPartialFinalFrame = true
                return
            }
            let bodyLength = data[offset..<(offset + 8)].reduce(UInt64(0)) {
                ($0 << 8) | UInt64($1)
            }
            guard bodyLength > 0, bodyLength <= UInt64(Self.maximumEncodedBytes) else {
                throw SyncMutationJournalError.corrupt
            }
            offset += 8
            guard bodyLength <= UInt64(data.count - offset) else {
                if Self.hasCommittedTrailer(in: data, frameStart: frameStart) {
                    throw SyncMutationJournalError.corrupt
                }
                state.validSegmentByteCount = frameStart
                state.hasPartialFinalFrame = true
                return
            }
            let bodyEnd = offset + Int(bodyLength)
            guard data.count - bodyEnd >= Self.frameTrailerByteCount else {
                state.validSegmentByteCount = frameStart
                state.hasPartialFinalFrame = true
                return
            }
            let frame: SyncJournalFrame
            do {
                frame = try JSONDecoder().decode(
                    SyncJournalFrame.self,
                    from: Data(data[offset..<bodyEnd])
                )
            } catch {
                throw SyncMutationJournalError.corrupt
            }
            let trailerLength = data[bodyEnd..<(bodyEnd + 8)].reduce(UInt64(0)) {
                ($0 << 8) | UInt64($1)
            }
            let magicStart = bodyEnd + 8
            let magicEnd = magicStart + Self.frameTrailerMagic.count
            guard trailerLength == bodyLength,
                  data[magicStart..<magicEnd] == Self.frameTrailerMagic else {
                throw SyncMutationJournalError.corrupt
            }
            offset = magicEnd
            state.validSegmentByteCount = offset
            guard frame.checksum == Self.checksum(
                sequence: frame.sequence,
                kind: frame.kind,
                payload: frame.payload
            ) else {
                throw SyncMutationJournalError.corrupt
            }
            guard frame.sequence > 0, frame.sequence < UInt64.max else {
                throw SyncMutationJournalError.corrupt
            }
            if let lastFrameSequence {
                guard frame.sequence == lastFrameSequence + 1 else {
                    throw SyncMutationJournalError.corrupt
                }
            }
            lastFrameSequence = frame.sequence
            if frame.sequence <= checkpointSequence { continue }
            try apply(frame, to: &state)
        }
    }

    private func appendReconcilingMemoryLocked(
        _ frames: [SyncJournalFrame],
        candidate: LoadedState
    ) throws {
        var appendWasAttempted = false
        do {
            if candidate.usesCheckpointV5 { try preflightConflictPersistence(candidate, frames: frames) }
            let encoded = try encodeFrames(frames)
            let current = try stateLocked()
            if current.hasPartialFinalFrame {
                try truncateSegment(to: current.validSegmentByteCount)
            }
            guard current.validSegmentByteCount <= Self.maximumEncodedBytes - encoded.count else {
                throw SyncMutationJournalError.tooLarge
            }
            appendWasAttempted = true
            try appendFrames(encoded, segmentURL)
            coordinator.requiresDurabilityRepair = false
            counters.recordAppendedFrames(frames.count)
            var committed = candidate
            committed.validSegmentByteCount = current.validSegmentByteCount + encoded.count
            committed.hasPartialFinalFrame = false
            loadedState = committed
            try compactIfNeededLocked()
        } catch {
            let persistenceError = error
            if appendWasAttempted {
                coordinator.requiresDurabilityRepair = true
            }
            loadedState = try? loadStateLocked()
            throw persistenceError
        }
    }

    private func repairDurabilityIfNeededLocked(_ state: LoadedState) throws {
        guard coordinator.requiresDurabilityRepair else { return }
        var synchronizedArtifact = false
        for index in 0..<state.proofShardCount {
            guard try synchronizeArtifactIfPresent(proofShardURL(index)) else {
                throw SyncMutationJournalError.corrupt
            }
            synchronizedArtifact = true
        }
        let checkpointExists = try synchronizeArtifactIfPresent(checkpointURL)
        let segmentExists = try synchronizeArtifactIfPresent(segmentURL)
        if synchronizedArtifact || checkpointExists || segmentExists {
            try synchronizeDirectory(segmentURL.deletingLastPathComponent())
        }
        coordinator.requiresDurabilityRepair = false
    }

    private func synchronizeArtifactIfPresent(_ artifactURL: URL) throws -> Bool {
        var pathStatus = stat()
        let pathResult = artifactURL.path.withCString { Darwin.lstat($0, &pathStatus) }
        if pathResult != 0 {
            guard errno == ENOENT else { throw currentPOSIXError() }
            return false
        }
        guard Self.isRegularFile(pathStatus) else {
            throw SyncMutationJournalError.unsafeFile
        }
        let descriptor = artifactURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw SyncMutationJournalError.unsafeFile }
            throw currentPOSIXError()
        }
        defer { Darwin.close(descriptor) }

        var openedStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0,
              Self.isRegularFile(openedStatus),
              pathStatus.st_dev == openedStatus.st_dev,
              pathStatus.st_ino == openedStatus.st_ino else {
            throw SyncMutationJournalError.unsafeFile
        }
        try synchronizeFile(descriptor)
        return true
    }

    private func compactIfNeededLocked() throws {
        guard var current = loadedState,
              current.framesSinceCheckpoint >= 256,
              current.acknowledgedOperationCount * 2 >= current.enqueuedOperationCount else {
            return
        }
        try persistCheckpointLocked(&current)
    }

    private func publishUnpersistedProofShardsLocked(
        _ state: inout LoadedState
    ) throws {
        for chunkStart in stride(
            from: 0,
            to: state.unpersistedProofs.count,
            by: Self.proofShardEntryLimit
        ) {
            let chunkEnd = min(
                chunkStart + Self.proofShardEntryLimit,
                state.unpersistedProofs.count
            )
            guard state.proofShardCount < Self.maximumProofShardCount else {
                throw SyncMutationJournalError.tooLarge
            }
            let proofs = Array(state.unpersistedProofs[chunkStart..<chunkEnd])
            let shardIndex = state.proofShardCount
            let shardData = try encodeProofShard(index: shardIndex, proofs: proofs)
            try atomicWrite(shardData, proofShardURL(shardIndex))
            state.proofShardRoot = Self.proofShardRoot(
                appending: shardData,
                index: shardIndex,
                to: state.proofShardRoot
            )
            for (offset, proof) in proofs.enumerated() {
                state.proofLocationsByMutationID[proof.mutationID] = ProofLocation(
                    shardIndex: shardIndex,
                    offset: offset
                )
            }
            state.proofsByShard.append(proofs)
            state.proofShardCount += 1
        }
        state.unpersistedProofs = []
        for mutationID in state.cleanupCompletion.completedUnpersistedMutationIDs {
            guard let location = state.proofLocationsByMutationID[mutationID],
                  let proof = state.seenByMutationID[mutationID],
                  Self.cleanupIntent(for: proof) != nil else {
                throw SyncMutationJournalError.corrupt
            }
            Self.markCleanupCompleted(
                location,
                completion: &state.cleanupCompletion,
                counters: counters
            )
        }
        state.cleanupCompletion.completedUnpersistedMutationIDs = []
    }

    private func persistCheckpointLocked(_ state: inout LoadedState) throws {
        if state.usesCheckpointV5 { try preflightConflictPersistence(state, frames: []) }
        try publishUnpersistedProofShardsLocked(&state)
        normalizeCleanupCompletion(in: &state)
        let throughSequence = state.nextSequence - 1
        let checkpoint = try conflictCheckpoint(for: state)
        try atomicWrite(try encodeCheckpoint(checkpoint), checkpointURL)
        counters.recordCheckpointRewrite()
        try atomicWrite(Data(), segmentURL)
        state.nextSequence = throughSequence + 1
        state.framesSinceCheckpoint = 0
        state.enqueuedOperationCount = 0
        state.acknowledgedOperationCount = 0
        state.validSegmentByteCount = 0
        state.hasPartialFinalFrame = false
        loadedState = state
    }

    private func makeFrame<Value: Encodable>(
        sequence: UInt64,
        kind: SyncJournalFrameKind,
        value: Value
    ) throws -> SyncJournalFrame {
        let payload = try Self.deterministicEncoder().encode(value)
        return SyncJournalFrame(
            sequence: sequence,
            kind: kind,
            payload: payload,
            checksum: Self.checksum(sequence: sequence, kind: kind, payload: payload)
        )
    }

    private func apply(_ frame: SyncJournalFrame, to state: inout LoadedState) throws {
        guard frame.sequence == state.nextSequence, state.nextSequence < UInt64.max else {
            throw SyncMutationJournalError.corrupt
        }
        switch frame.kind {
        case .enqueue:
            let mutation: SyncMutation
            do {
                mutation = try JSONDecoder().decode(SyncMutation.self, from: frame.payload)
                    .validatedForJournalLoad()
            } catch let error as SyncMutationJournalError {
                throw error
            } catch {
                throw SyncMutationJournalError.corrupt
            }
            let proof = try Self.duplicateProof(for: mutation)
            if let existing = effectiveProof(for: mutation.mutationID, in: state) {
                guard Self.proofsMatch(existing, proof) else {
                    throw SyncMutationJournalError.corrupt
                }
            } else {
                state.seenByMutationID[mutation.mutationID] = proof
                state.unpersistedProofs.append(proof)
                state.pending.append(mutation)
            }
            state.enqueuedOperationCount += 1
            state.framesSinceCheckpoint += 1
        case .acknowledge:
            let identity: SyncMutationIdentity
            do {
                identity = try JSONDecoder().decode(
                    SyncMutationIdentity.self,
                    from: frame.payload
                )
            } catch {
                throw SyncMutationJournalError.corrupt
            }
            guard state.revisions[identity.mutationID] == nil,
                  let index = state.pending.firstIndex(where: { $0.identity == identity }) else {
                throw SyncMutationJournalError.corrupt
            }
            if let cleanup = Self.cleanupIntent(for: state.pending[index]) {
                if let existing = state.cleanupIntentsByMutationID[cleanup.mutationID] {
                    guard existing == cleanup else {
                        throw SyncMutationJournalError.corrupt
                    }
                } else {
                    state.cleanupIntentsByMutationID[cleanup.mutationID] = cleanup
                }
            }
            state.pending.remove(at: index)
            state.acknowledgedOperationCount += 1
            state.framesSinceCheckpoint += 1
        case .rebase:
            let transition: SyncJournalRebaseTransition
            do { transition = try JSONDecoder().decode(SyncJournalRebaseTransition.self, from: frame.payload) }
            catch { throw SyncMutationJournalError.corrupt }
            let current = try versionedPending(in: state)
            guard try SyncConflictRebaseCoding.pendingDigest(current) == transition.predecessorPendingSHA256,
                  current.indices.filter({ current[$0].mutation.recordID == transition.input.serverRecord.id }) == transition.recordPositions,
                  transition.recordPositions.allSatisfy({ current.indices.contains($0) }),
                  transition.recordPositions.map({ current[$0].mutation }) == transition.before,
                  transition.recordPositions.map({ current[$0].token }) == transition.beforeVersions else {
                throw SyncMutationJournalError.corrupt
            }
            try applyRebaseHistory(transition, to: &state)
            for (index, position) in transition.recordPositions.enumerated() {
                state.pending[position] = transition.after[index]
            }
            state.framesSinceCheckpoint += 1
        case .versionedAcknowledgement:
            let token: SyncMutationVersionToken
            do { token = try JSONDecoder().decode(SyncMutationVersionToken.self, from: frame.payload) }
            catch { throw SyncMutationJournalError.corrupt }
            guard let index = state.pending.firstIndex(where: { $0.identity == token.identity }),
                  token == (try SyncMutationVersionToken(mutation: state.pending[index],
                    journalRevision: state.revisions[token.identity.mutationID] ?? 0)),
                  state.versionedAcknowledgements[token.identity.mutationID] == nil else {
                throw SyncMutationJournalError.corrupt
            }
            let current = try SyncVersionedMutation(mutation: state.pending[index], token: token)
            state.versionedAcknowledgements[token.identity.mutationID] = current
            // The issued proof retains the staged-file obligation even when
            // a rebase adds a tombstone whose effective payload has no source.
            if let issued = state.seenByMutationID[token.identity.mutationID],
               let cleanup = Self.cleanupIntent(for: issued) {
                state.cleanupIntentsByMutationID[cleanup.mutationID] = cleanup
            }
            state.pending.remove(at: index)
            state.usesCheckpointV5 = true
            state.acknowledgedOperationCount += 1
            state.framesSinceCheckpoint += 1
        case .cleanupCompletion:
            let cleanups: [SyncAttachmentCleanupIntent]
            do {
                cleanups = try JSONDecoder().decode(
                    [SyncAttachmentCleanupIntent].self,
                    from: frame.payload
                )
            } catch {
                throw SyncMutationJournalError.corrupt
            }
            guard !cleanups.isEmpty else { throw SyncMutationJournalError.corrupt }
            var seenCleanups = Set<SyncAttachmentCleanupIntent>()
            let pendingIDs = Set(state.pending.map(\.mutationID))
            let pendingFiles = pendingCleanupFileURLs(state.pending)
            for cleanup in cleanups {
                guard seenCleanups.insert(cleanup).inserted,
                      state.cleanupIntentsByMutationID[cleanup.mutationID] == cleanup,
                      let proof = state.seenByMutationID[cleanup.mutationID],
                      Self.cleanupIntent(for: proof) == cleanup,
                      !pendingIDs.contains(cleanup.mutationID),
                      !pendingSharesCleanupFile(proof, pendingFiles: pendingFiles),
                      !isCleanupCompleted(cleanup, in: state) else {
                    throw SyncMutationJournalError.corrupt
                }
                if let location = state.proofLocationsByMutationID[cleanup.mutationID] {
                    Self.markCleanupCompleted(
                        location,
                        completion: &state.cleanupCompletion,
                        counters: counters
                    )
                } else {
                    state.cleanupCompletion.completedUnpersistedMutationIDs.insert(
                        cleanup.mutationID
                    )
                }
            }
            for cleanup in cleanups {
                state.cleanupIntentsByMutationID.removeValue(forKey: cleanup.mutationID)
            }
        }
        state.nextSequence += 1
    }

    private func encodeFrames(_ frames: [SyncJournalFrame]) throws -> Data {
        let encoder = Self.deterministicEncoder()
        var result = Data()
        for frame in frames {
            let body = try encoder.encode(frame)
            guard body.count <= Self.maximumEncodedBytes else {
                throw SyncMutationJournalError.tooLarge
            }
            var length = UInt64(body.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(body)
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(Self.frameTrailerMagic)
        }
        return result
    }

    private static func hasCommittedTrailer(in data: Data, frameStart: Int) -> Bool {
        let bodyStart = frameStart + MemoryLayout<UInt64>.size
        var searchStart = bodyStart + MemoryLayout<UInt64>.size
        while searchStart <= data.count - frameTrailerMagic.count,
              let magicRange = data.range(
                  of: frameTrailerMagic,
                  options: [],
                  in: searchStart..<data.count
              ) {
            let lengthStart = magicRange.lowerBound - MemoryLayout<UInt64>.size
            if lengthStart >= bodyStart {
                let recordedLength = data[lengthStart..<magicRange.lowerBound].reduce(UInt64(0)) {
                    ($0 << 8) | UInt64($1)
                }
                if recordedLength <= UInt64(Int.max),
                   bodyStart + Int(recordedLength) == lengthStart {
                    return true
                }
            }
            searchStart = magicRange.lowerBound + 1
        }
        return false
    }

    private static func checksum(
        sequence: UInt64,
        kind: SyncJournalFrameKind,
        payload: Data
    ) -> Data {
        var material = Data()
        material.append(1)
        var sequence = sequence.bigEndian
        withUnsafeBytes(of: &sequence) { material.append(contentsOf: $0) }
        material.append(kind.rawValue)
        material.append(payload)
        return Data(SHA256.hash(data: material))
    }

    /// Append-only hash-chain root for immutable acknowledged-proof shards.
    /// The checkpoint is the mutable manifest: hot-path freshness checks stat
    /// only it, while every cold load verifies all referenced shard bytes back
    /// to this root.
    private static func proofShardRoot(
        appending shardData: Data,
        index: Int,
        to priorRoot: Data
    ) -> Data {
        var material = Data("KnitNote.SyncMutationJournal.ProofShardRoot.v1".utf8)
        material.append(priorRoot)
        var encodedIndex = UInt64(index).bigEndian
        withUnsafeBytes(of: &encodedIndex) { material.append(contentsOf: $0) }
        material.append(Data(SHA256.hash(data: shardData)))
        return Data(SHA256.hash(data: material))
    }

    private func encodeCheckpoint(_ checkpoint: SyncJournalCheckpoint) throws -> Data {
        let checkpointData = try Self.deterministicEncoder(
            allowLegacyReminder: true
        ).encode(checkpoint)
        let file = CheckpointFile(
            version: 1,
            checkpoint: checkpointData,
            checksum: Data(SHA256.hash(data: checkpointData))
        )
        let data = try Self.deterministicEncoder().encode(file)
        guard data.count <= Self.maximumEncodedBytes else {
            throw SyncMutationJournalError.tooLarge
        }
        return data
    }

    private func decodeCheckpoint(_ data: Data) throws -> SyncJournalCheckpoint {
        do {
            let file = try JSONDecoder().decode(CheckpointFile.self, from: data)
            guard file.version == 1,
                  file.checksum == Data(SHA256.hash(data: file.checkpoint)) else {
                throw SyncMutationJournalError.corrupt
            }
            return try JSONDecoder().decode(SyncJournalCheckpoint.self, from: file.checkpoint)
        } catch let error as SyncMutationJournalError {
            throw error
        } catch {
            throw SyncMutationJournalError.corrupt
        }
    }

    private func encodeProofShard(
        index: Int,
        proofs: [SyncMutationDuplicateProof]
    ) throws -> Data {
        guard !proofs.isEmpty,
              proofs.count <= Self.proofShardEntryLimit else {
            throw SyncMutationJournalError.corrupt
        }
        let payload = try Self.deterministicEncoder().encode(
            ProofShardPayload(version: 2, index: index, proofs: proofs)
        )
        let data = try Self.deterministicEncoder().encode(ProofShardFile(
            version: 1,
            payload: payload,
            checksum: Data(SHA256.hash(data: payload))
        ))
        guard data.count <= Self.maximumEncodedBytes else {
            throw SyncMutationJournalError.tooLarge
        }
        return data
    }

    private func decodeProofShard(_ data: Data) throws -> ProofShardPayload {
        do {
            let file = try JSONDecoder().decode(ProofShardFile.self, from: data)
            guard file.version == 1,
                  file.checksum == Data(SHA256.hash(data: file.payload)) else {
                throw SyncMutationJournalError.corrupt
            }
            let decoded = try JSONDecoder().decode(ProofShardPayload.self, from: file.payload)
            guard (1...2).contains(decoded.version) else {
                throw SyncMutationJournalError.corrupt
            }
            if decoded.version == 1 {
                return ProofShardPayload(
                    version: decoded.version,
                    index: decoded.index,
                    proofs: decoded.proofs.map { $0.asOpaqueV1AttachmentAuthority() }
                )
            }
            return decoded
        } catch let error as SyncMutationJournalError {
            throw error
        } catch {
            throw SyncMutationJournalError.corrupt
        }
    }

    private static func deterministicEncoder(allowLegacyReminder: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if allowLegacyReminder {
            encoder.userInfo[.encodeLegacyStandaloneReminderForMigration] = true
        }
        return encoder
    }

    private func migrateLegacyEnvelopeLocked() throws -> LoadedState {
        guard let legacyData = try readArtifact(url) else { return .empty }
        let mutations = try decodeAndValidateLegacyEnvelope(legacyData)
        let proofs = try mutations.map(Self.duplicateProof(for:))
        var proofShardCount = 0
        var proofShardRoot = SyncJournalCheckpoint.emptyProofShardRoot
        for chunkStart in stride(
            from: 0,
            to: proofs.count,
            by: Self.proofShardEntryLimit
        ) {
            let chunkEnd = min(chunkStart + Self.proofShardEntryLimit, proofs.count)
            let shardData = try encodeProofShard(
                index: proofShardCount,
                proofs: Array(proofs[chunkStart..<chunkEnd])
            )
            try atomicWrite(shardData, proofShardURL(proofShardCount))
            proofShardRoot = Self.proofShardRoot(
                appending: shardData,
                index: proofShardCount,
                to: proofShardRoot
            )
            proofShardCount += 1
        }
        let checkpoint = SyncJournalCheckpoint(
            throughSequence: 0,
            pending: mutations,
            proofShardCount: proofShardCount,
            proofShardRoot: proofShardRoot
        )
        try atomicWrite(try encodeCheckpoint(checkpoint), checkpointURL)
        counters.recordCheckpointRewrite()
        try atomicWrite(Data(), segmentURL)
        try retainMigratedLegacyEnvelope()
        return LoadedState(
            pending: mutations,
            seenByMutationID: Dictionary(
                uniqueKeysWithValues: proofs.map { ($0.mutationID, $0) }
            ),
            proofShardCount: proofShardCount,
            proofShardRoot: proofShardRoot,
            unpersistedProofs: [],
            proofLocationsByMutationID: Dictionary(
                uniqueKeysWithValues: proofs.enumerated().map {
                    ($0.element.mutationID, ProofLocation(
                        shardIndex: $0.offset / Self.proofShardEntryLimit,
                        offset: $0.offset % Self.proofShardEntryLimit
                    ))
                }
            ),
            proofsByShard: stride(
                from: 0,
                to: proofs.count,
                by: Self.proofShardEntryLimit
            ).map {
                Array(proofs[$0..<min($0 + Self.proofShardEntryLimit, proofs.count)])
            },
            cleanupIntentsByMutationID: [:],
            cleanupCompletion: .empty,
            nextSequence: 1,
            framesSinceCheckpoint: 0,
            enqueuedOperationCount: 0,
            acknowledgedOperationCount: 0,
            validSegmentByteCount: 0,
            hasPartialFinalFrame: false
        )
    }

    private func finishInterruptedLegacyMigrationLocked(matching pending: [SyncMutation]) throws {
        guard let legacyData = try readArtifact(url) else { return }
        let legacyMutations = try decodeAndValidateLegacyEnvelope(legacyData)
        guard legacyMutations == pending else { throw SyncMutationJournalError.corrupt }
        if !(try pathExists(segmentURL)) { try atomicWrite(Data(), segmentURL) }
        try retainMigratedLegacyEnvelope()
    }

    private func decodeAndValidateLegacyEnvelope(_ data: Data) throws -> [SyncMutation] {
        let envelope: LegacyEnvelope
        do {
            envelope = try JSONDecoder().decode(LegacyEnvelope.self, from: data)
        } catch {
            throw SyncMutationJournalError.corrupt
        }
        guard envelope.version == LegacyEnvelope.currentVersion else {
            throw SyncMutationJournalError.corrupt
        }
        var seenMutationIDs = Set<UUID>()
        let mutations = try envelope.mutations.map { mutation in
            do {
                let validated = try mutation.validatedForJournalLoad()
                guard seenMutationIDs.insert(validated.mutationID).inserted else {
                    throw SyncMutationJournalError.corrupt
                }
                try validatePersistedAttachmentSource(in: validated)
                return validated
            } catch let error as SyncMutationJournalError {
                switch error {
                case .unsafeFile, .tooLarge:
                    throw error
                case .corrupt, .duplicateMutationID, .invalidAttachment:
                    throw SyncMutationJournalError.corrupt
                }
            } catch {
                throw SyncMutationJournalError.corrupt
            }
        }
        try Self.validateAttachmentLineage(
            proofs: try mutations.map(Self.duplicateProof(for:)),
            failure: .corrupt
        )
        return mutations
    }

    private func retainMigratedLegacyEnvelope() throws {
        guard !(try pathExists(migratedURL)) else {
            throw SyncMutationJournalError.corrupt
        }
        let result = url.path.withCString { source in
            migratedURL.path.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard result == 0 else { throw currentPOSIXError() }
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    private func readArtifact(_ artifactURL: URL, maximumBytes: Int = FileSyncMutationJournal.maximumEncodedBytes) throws -> Data? {
        guard try pathExists(artifactURL) else { return nil }
        do {
            let read = try reader.read(
                artifactURL,
                maximumBytes: maximumBytes
            )
            counters.recordBytesRead(read.data.count)
            return read.data
        } catch let error as SyncRegularFileReadError {
            switch error {
            case .unsafeFile, .replaced:
                throw SyncMutationJournalError.unsafeFile
            case .tooLarge:
                throw SyncMutationJournalError.tooLarge
            case .unavailable, .changed, .expectationMismatch:
                throw SyncMutationJournalError.corrupt
            }
        }
    }

    private func pathExists(_ artifactURL: URL) throws -> Bool {
        var status = stat()
        let result = artifactURL.path.withCString { Darwin.lstat($0, &status) }
        if result == 0 { return true }
        guard errno == ENOENT else { throw currentPOSIXError() }
        return false
    }

    private func journalFingerprintLocked() throws -> JournalFingerprint {
        // Immutable proof shards are integrity-bound and enumerated by the
        // durable checkpoint. Only mutable roots participate in the hot-path
        // freshness fingerprint; a checkpoint change forces a full reload and
        // proof-shard verification.
        return JournalFingerprint(
            legacy: try artifactFingerprint(url),
            checkpoint: try artifactFingerprint(checkpointURL),
            segment: try artifactFingerprint(segmentURL)
        )
    }

    private func artifactFingerprint(_ artifactURL: URL) throws -> ArtifactFingerprint? {
        counters.recordMetadataRead()
        var status = stat()
        let result = artifactURL.path.withCString { Darwin.lstat($0, &status) }
        if result != 0 {
            guard errno == ENOENT else { throw currentPOSIXError() }
            return nil
        }
        return ArtifactFingerprint(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            mode: UInt32(status.st_mode),
            size: Int64(status.st_size),
            modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            changedSeconds: Int64(status.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(status.st_ctimespec.tv_nsec)
        )
    }

    private func withParentDirectoryLock<Result>(
        _ operation: () throws -> Result
    ) throws -> Result {
        let parent = url.deletingLastPathComponent()
        var pathStatus = stat()
        var pathResult = parent.path.withCString { Darwin.lstat($0, &pathStatus) }
        if pathResult != 0, errno == ENOENT {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
            pathResult = parent.path.withCString { Darwin.lstat($0, &pathStatus) }
        }
        guard pathResult == 0,
              (pathStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw SyncMutationJournalError.unsafeFile
        }
        let descriptor = parent.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw SyncMutationJournalError.unsafeFile }
            throw currentPOSIXError()
        }
        defer { Darwin.close(descriptor) }
        try setParentDirectoryLock(descriptor, operation: LOCK_EX)
        defer { try? setParentDirectoryLock(descriptor, operation: LOCK_UN) }

        var openedStatus = stat()
        var lockedPathStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0,
              (openedStatus.st_mode & S_IFMT) == S_IFDIR,
              parent.path.withCString({ Darwin.lstat($0, &lockedPathStatus) }) == 0,
              (lockedPathStatus.st_mode & S_IFMT) == S_IFDIR,
              openedStatus.st_dev == lockedPathStatus.st_dev,
              openedStatus.st_ino == lockedPathStatus.st_ino,
              pathStatus.st_dev == openedStatus.st_dev,
              pathStatus.st_ino == openedStatus.st_ino else {
            throw SyncMutationJournalError.unsafeFile
        }
        return try operation()
    }

    private func setParentDirectoryLock(_ descriptor: Int32, operation: Int32) throws {
        while syncJournalFlock(descriptor, operation) != 0 {
            guard errno == EINTR else { throw currentPOSIXError() }
        }
    }

    private func truncateSegment(to byteCount: Int) throws {
        var pathStatus = stat()
        guard segmentURL.path.withCString({ Darwin.lstat($0, &pathStatus) }) == 0,
              Self.isRegularFile(pathStatus) else {
            throw SyncMutationJournalError.unsafeFile
        }
        let descriptor = segmentURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              Self.isRegularFile(status),
              pathStatus.st_dev == status.st_dev,
              pathStatus.st_ino == status.st_ino else {
            throw SyncMutationJournalError.unsafeFile
        }
        guard Darwin.ftruncate(descriptor, off_t(byteCount)) == 0,
              Darwin.fsync(descriptor) == 0 else {
            throw currentPOSIXError()
        }
    }

    private struct LoadedState {
        var pending: [SyncMutation]
        var seenByMutationID: [UUID: SyncMutationDuplicateProof]
        var proofShardCount: Int
        var proofShardRoot: Data
        var unpersistedProofs: [SyncMutationDuplicateProof]
        var proofLocationsByMutationID: [UUID: ProofLocation]
        var proofsByShard: [[SyncMutationDuplicateProof]]
        var cleanupIntentsByMutationID: [UUID: SyncAttachmentCleanupIntent]
        var cleanupCompletion: CleanupCompletionState
        var nextSequence: UInt64
        var framesSinceCheckpoint: Int
        var enqueuedOperationCount: Int
        var acknowledgedOperationCount: Int
        var validSegmentByteCount: Int
        var hasPartialFinalFrame: Bool
        var rebaseHistory: [SyncJournalRebaseTransition] = []
        var rebasedProofs: [UUID: SyncMutationDuplicateProof] = [:]
        var rebasedMutations: [UUID: SyncMutation] = [:]
        var revisions: [UUID: UInt64] = [:]
        var versionedAcknowledgements: [UUID: SyncVersionedMutation] = [:]
        var usesCheckpointV5 = false
        var rebaseHistoryHeadSHA256: Data {
            rebaseHistory.last?.integrity ?? SyncConflictRebaseCoding.emptyRebaseHistoryHeadSHA256
        }

        static let empty = LoadedState(
            pending: [],
            seenByMutationID: [:],
            proofShardCount: 0,
            proofShardRoot: SyncJournalCheckpoint.emptyProofShardRoot,
            unpersistedProofs: [],
            proofLocationsByMutationID: [:],
            proofsByShard: [],
            cleanupIntentsByMutationID: [:],
            cleanupCompletion: .empty,
            nextSequence: 1,
            framesSinceCheckpoint: 0,
            enqueuedOperationCount: 0,
            acknowledgedOperationCount: 0,
            validSegmentByteCount: 0,
            hasPartialFinalFrame: false
        )
    }

    private struct ProofLocation: Hashable {
        let shardIndex: Int
        let offset: Int
    }

    private struct CleanupCompletionState {
        var completedShardCount: Int
        var partialShardsByIndex: [Int: Data]
        var completedUnpersistedMutationIDs: Set<UUID>

        static let empty = CleanupCompletionState(
            completedShardCount: 0,
            partialShardsByIndex: [:],
            completedUnpersistedMutationIDs: []
        )
    }

    private static let cleanupCompletionByteCount = proofShardEntryLimit / 8

    private func cleanupCompletionState(
        from persisted: SyncCleanupCompletion
    ) throws -> CleanupCompletionState {
        var partialShardsByIndex: [Int: Data] = [:]
        var previousShardIndex: Int?
        for partial in persisted.partialShards {
            guard partial.completedOffsets.count == Self.cleanupCompletionByteCount,
                  previousShardIndex.map({ $0 < partial.shardIndex }) ?? true,
                  partialShardsByIndex.updateValue(
                      partial.completedOffsets,
                      forKey: partial.shardIndex
                  ) == nil else {
                throw SyncMutationJournalError.corrupt
            }
            previousShardIndex = partial.shardIndex
        }
        return CleanupCompletionState(
            completedShardCount: persisted.completedShardCount,
            partialShardsByIndex: partialShardsByIndex,
            completedUnpersistedMutationIDs: []
        )
    }

    private func checkpointCleanupCompletion(
        from completion: CleanupCompletionState
    ) throws -> SyncCleanupCompletion {
        guard completion.completedUnpersistedMutationIDs.isEmpty else {
            throw SyncMutationJournalError.corrupt
        }
        counters.recordCleanupCompletionSort()
        let partialShards = completion.partialShardsByIndex.keys.sorted().map {
            SyncCleanupShardCompletion(
                shardIndex: $0,
                completedOffsets: completion.partialShardsByIndex[$0]!
            )
        }
        return SyncCleanupCompletion(
            completedShardCount: completion.completedShardCount,
            partialShards: partialShards
        )
    }

    private static func isCleanupCompleted(
        _ location: ProofLocation?,
        completion: CleanupCompletionState,
        counters: SyncJournalIOCounters? = nil
    ) -> Bool {
        guard let location else { return false }
        if location.shardIndex < completion.completedShardCount { return true }
        counters?.recordCleanupCompletionShardProbe()
        guard let completedOffsets = completion.partialShardsByIndex[location.shardIndex],
              completedOffsets.count == cleanupCompletionByteCount else {
            return false
        }
        let byte = completedOffsets[location.offset / 8]
        return byte & UInt8(1 << (location.offset % 8)) != 0
    }

    private func isCleanupCompleted(
        _ cleanup: SyncAttachmentCleanupIntent,
        in state: LoadedState
    ) -> Bool {
        state.cleanupCompletion.completedUnpersistedMutationIDs.contains(cleanup.mutationID)
            || Self.isCleanupCompleted(
                state.proofLocationsByMutationID[cleanup.mutationID],
                completion: state.cleanupCompletion,
                counters: counters
            )
    }

    private static func markCleanupCompleted(
        _ location: ProofLocation,
        completion: inout CleanupCompletionState,
        counters: SyncJournalIOCounters? = nil
    ) {
        guard location.shardIndex >= completion.completedShardCount else { return }
        counters?.recordCleanupCompletionShardProbe()
        var bytes = [UInt8](
            completion.partialShardsByIndex[location.shardIndex]
                ?? Data(repeating: 0, count: cleanupCompletionByteCount)
        )
        bytes[location.offset / 8] |= UInt8(1 << (location.offset % 8))
        completion.partialShardsByIndex[location.shardIndex] = Data(bytes)
        counters?.recordCleanupCompletionShardUpdate()
    }

    private func validateCleanupCompletion(in state: LoadedState) throws {
        let completion = state.cleanupCompletion
        guard state.proofsByShard.count == state.proofShardCount,
              completion.completedShardCount >= 0,
              completion.completedShardCount <= state.proofShardCount else {
            throw SyncMutationJournalError.corrupt
        }
        let pendingIDs = Set(state.pending.map(\.mutationID))
        let pendingFiles = pendingCleanupFileURLs(state.pending)
        for mutationID in completion.completedUnpersistedMutationIDs {
            guard state.proofLocationsByMutationID[mutationID] == nil,
                  let proof = state.seenByMutationID[mutationID],
                  Self.cleanupIntent(for: proof) != nil,
                  !pendingIDs.contains(mutationID),
                  !pendingSharesCleanupFile(proof, pendingFiles: pendingFiles) else {
                throw SyncMutationJournalError.corrupt
            }
        }
        for shardIndex in 0..<completion.completedShardCount {
            // Frontier invariant: every attachment proof in every crossed immutable
            // shard is complete, and no crossed proof may still be pending/shared.
            for proof in state.proofsByShard[shardIndex]
            where Self.cleanupIntent(for: proof) != nil {
                guard !pendingIDs.contains(proof.mutationID),
                      !pendingSharesCleanupFile(proof, pendingFiles: pendingFiles) else {
                    throw SyncMutationJournalError.corrupt
                }
            }
        }
        for (shardIndex, completedOffsets) in completion.partialShardsByIndex {
            guard shardIndex >= completion.completedShardCount,
                  shardIndex < state.proofShardCount,
                  completedOffsets.count == Self.cleanupCompletionByteCount else {
                throw SyncMutationJournalError.corrupt
            }
            let proofs = state.proofsByShard[shardIndex]
            for offset in 0..<(Self.cleanupCompletionByteCount * 8)
            where completedOffsets[offset / 8] & UInt8(1 << (offset % 8)) != 0 {
                guard offset < proofs.count,
                      Self.cleanupIntent(for: proofs[offset]) != nil,
                      !pendingIDs.contains(proofs[offset].mutationID),
                      !pendingSharesCleanupFile(
                          proofs[offset],
                          pendingFiles: pendingFiles
                      ) else {
                    throw SyncMutationJournalError.corrupt
                }
            }
        }
    }

    private func normalizeCleanupCompletion(in state: inout LoadedState) {
        let pendingFiles = pendingCleanupFileURLs(state.pending)
        while state.cleanupCompletion.completedShardCount < state.proofShardCount {
            let shardIndex = state.cleanupCompletion.completedShardCount
            let proofs = state.proofsByShard[shardIndex]
            let canAdvance = proofs.enumerated().allSatisfy { offset, proof in
                guard Self.cleanupIntent(for: proof) != nil else { return true }
                let location = ProofLocation(shardIndex: shardIndex, offset: offset)
                return Self.isCleanupCompleted(
                    location,
                    completion: state.cleanupCompletion,
                    counters: counters
                ) && !pendingSharesCleanupFile(proof, pendingFiles: pendingFiles)
            }
            guard canAdvance else { break }
            state.cleanupCompletion.partialShardsByIndex.removeValue(forKey: shardIndex)
            state.cleanupCompletion.completedShardCount += 1
        }
        state.cleanupCompletion.partialShardsByIndex = state.cleanupCompletion
            .partialShardsByIndex.filter {
                $0.key >= state.cleanupCompletion.completedShardCount
            }
    }

    private func pendingCleanupFileURLs(_ pending: [SyncMutation]) -> Set<URL> {
        Set(pending.compactMap {
            $0.attachmentSource?.fileURL.standardizedFileURL
        })
    }

    private func pendingSharesCleanupFile(
        _ proof: SyncMutationDuplicateProof,
        pendingFiles: Set<URL>
    ) -> Bool {
        guard let cleanup = Self.cleanupIntent(for: proof) else { return false }
        let expected = cleanupFileURL(
            cleanup,
            root: attachmentsDirectory.standardizedFileURL
        )
        return pendingFiles.contains(expected)
    }

    private struct JournalFingerprint: Equatable {
        let legacy: ArtifactFingerprint?
        let checkpoint: ArtifactFingerprint?
        let segment: ArtifactFingerprint?
    }

    private struct ArtifactFingerprint: Equatable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
    }

    private struct CheckpointFile: Codable {
        let version: Int
        let checkpoint: Data
        let checksum: Data
    }

    private struct ProofShardPayload: Codable {
        let version: Int
        let index: Int
        let proofs: [SyncMutationDuplicateProof]
    }

    private struct ProofShardFile: Codable {
        let version: Int
        let payload: Data
        let checksum: Data
    }

    private struct LegacyEnvelope: Codable {
        static let currentVersion = 2
        let version: Int
        let mutations: [SyncMutation]
    }

    /// Determines the exact staged authority without creating a directory or
    /// copying bytes, so projected v5 capacity is checked before staging.
    private func stagedAttachmentMetadata(for mutation: SyncMutation) throws -> SyncMutation {
        guard let source = mutation.attachmentSource, !source.isJournalStaged else { return mutation }
        let versionID = try requiredAttachmentVersionID(in: mutation)
        let destination = attachmentsDirectory.appendingPathComponent(
            "\(mutation.mutationID.uuidString)-\(versionID.uuidString).asset", isDirectory: false)
        return try mutation.replacingAttachmentSource(.init(fileURL: destination,
            contentSHA256: source.contentSHA256, byteCount: source.byteCount, isJournalStaged: true))
    }

    private func stageAttachmentIfNeeded(for mutation: SyncMutation) throws -> SyncMutation {
        guard let source = mutation.attachmentSource else { return mutation }
        if source.isJournalStaged {
            try validatePersistedAttachmentSource(in: mutation)
            return mutation
        }

        try ensureSafeAttachmentsDirectory()
        let versionID = try requiredAttachmentVersionID(in: mutation)
        let destination = attachmentsDirectory.appendingPathComponent(
            "\(mutation.mutationID.uuidString)-\(versionID.uuidString).asset",
            isDirectory: false
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try verifyRegularFile(
                at: destination,
                expectedByteCount: source.byteCount,
                expectedSHA256: source.contentSHA256
            )
        } else {
            try copyAttachmentAtomically(from: source, to: destination)
        }
        let staged = SyncAttachmentSource(
            fileURL: destination,
            contentSHA256: source.contentSHA256,
            byteCount: source.byteCount,
            isJournalStaged: true
        )
        return try mutation.replacingAttachmentSource(staged)
    }

    private func requiredAttachmentVersionID(in mutation: SyncMutation) throws -> UUID {
        guard let version = mutation.savedRecordVersion?.record.payload.attachment else {
            throw SyncMutationJournalError.invalidAttachment
        }
        return version.versionID
    }

    private func validatePersistedAttachmentSource(in mutation: SyncMutation) throws {
        guard let source = mutation.attachmentSource else { return }
        guard source.isJournalStaged else {
            throw SyncMutationJournalError.invalidAttachment
        }
        let root = attachmentsDirectory.standardizedFileURL
        let file = source.fileURL.standardizedFileURL
        guard file.deletingLastPathComponent().path == root.path,
              file.path.hasPrefix(root.path + "/"),
              file.resolvingSymlinksInPath().path == file.path else {
            throw SyncMutationJournalError.unsafeFile
        }
        try verifyRegularFile(
            at: file,
            expectedByteCount: source.byteCount,
            expectedSHA256: source.contentSHA256
        )
    }

    private func ensureSafeAttachmentsDirectory() throws {
        let parent = attachmentsDirectory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var status = stat()
        let result = attachmentsDirectory.path.withCString { Darwin.lstat($0, &status) }
        if result == 0 {
            guard (status.st_mode & S_IFMT) == S_IFDIR else {
                throw SyncMutationJournalError.unsafeFile
            }
            return
        }
        guard errno == ENOENT else { throw currentPOSIXError() }
        try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: false)
        try Self.defaultSynchronizeDirectory(parent)
    }

    private func copyAttachmentAtomically(
        from source: SyncAttachmentSource,
        to destination: URL
    ) throws {
        let sourceData = try readVerifiedAttachment(
            at: source.fileURL,
            expectedByteCount: source.byteCount,
            expectedSHA256: source.contentSHA256
        )

        let temporary = attachmentsDirectory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let destinationDescriptor = try Self.openNewFile(at: temporary)
        var temporaryExists = true
        defer {
            Darwin.close(destinationDescriptor)
            if temporaryExists { _ = temporary.path.withCString { Darwin.unlink($0) } }
        }

        try Self.write(sourceData, to: destinationDescriptor)
        guard Darwin.fsync(destinationDescriptor) == 0 else { throw currentPOSIXError() }
        guard temporary.path.withCString({ sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }) == 0 else {
            throw currentPOSIXError()
        }
        temporaryExists = false
        try Self.defaultSynchronizeDirectory(attachmentsDirectory)
    }

    private func verifyRegularFile(
        at file: URL,
        expectedByteCount: Int64,
        expectedSHA256: Data
    ) throws {
        _ = try readVerifiedAttachment(
            at: file,
            expectedByteCount: expectedByteCount,
            expectedSHA256: expectedSHA256
        )
    }

    private func readVerifiedAttachment(
        at file: URL,
        expectedByteCount: Int64,
        expectedSHA256: Data
    ) throws -> Data {
        // A caller's declared length cannot enlarge the independent file limit.
        guard expectedByteCount >= 0,
              expectedByteCount <= Int64(Int.max),
              expectedByteCount <= Int64(SyncPublicationFileLimits.maximumAttachmentBytes) else {
            throw SyncMutationJournalError.invalidAttachment
        }
        do {
            return try reader.read(
                file,
                maximumBytes: Int(expectedByteCount),
                expected: .init(byteCount: expectedByteCount, sha256: expectedSHA256)
            ).data
        } catch let error as SyncRegularFileReadError {
            switch error {
            case .unsafeFile:
                throw SyncMutationJournalError.unsafeFile
            case .unavailable, .tooLarge, .replaced, .changed, .expectationMismatch:
                throw SyncMutationJournalError.invalidAttachment
            }
        }
    }

    private static func cleanupIntent(
        for mutation: SyncMutation
    ) -> SyncAttachmentCleanupIntent? {
        guard mutation.attachmentSource?.isJournalStaged == true,
              mutation.recordID.kind == .attachment else { return nil }
        return SyncAttachmentCleanupIntent(
            mutationID: mutation.mutationID,
            attachmentVersionID: mutation.recordID.uuid
        )
    }

    private static func cleanupIntent(
        for proof: SyncMutationDuplicateProof
    ) -> SyncAttachmentCleanupIntent? {
        guard proof.intent == .save,
              proof.recordID.kind == .attachment,
              proof.attachmentContentSHA256 != nil else { return nil }
        return SyncAttachmentCleanupIntent(
            mutationID: proof.mutationID,
            attachmentVersionID: proof.recordID.uuid
        )
    }

    private func cleanupFileURL(
        _ cleanup: SyncAttachmentCleanupIntent,
        root: URL
    ) -> URL {
        let filename = "\(cleanup.mutationID.uuidString)-\(cleanup.attachmentVersionID.uuidString).asset"
        return root.appendingPathComponent(filename).standardizedFileURL
    }

    private func removeStagedAttachmentForBatch(
        _ cleanup: SyncAttachmentCleanupIntent,
        remaining: [SyncMutation]
    ) throws -> Bool {
        let root = attachmentsDirectory.standardizedFileURL
        let file = cleanupFileURL(cleanup, root: root)
        guard !remaining.contains(where: {
            $0.attachmentSource?.fileURL.standardizedFileURL == file
        }) else { return false }
        guard file.deletingLastPathComponent().path == root.path,
              file.path.hasPrefix(root.path + "/"),
              file.resolvingSymlinksInPath().path == file.path else {
            throw SyncMutationJournalError.unsafeFile
        }
        var status = stat()
        let pathResult = file.path.withCString { Darwin.lstat($0, &status) }
        if pathResult != 0 {
            guard errno == ENOENT else { throw currentPOSIXError() }
            return true
        }
        guard Self.isRegularFile(status) else {
            throw SyncMutationJournalError.unsafeFile
        }
        try removeStagedFile(file)
        return true
    }

    private func reconcileAcknowledgedAttachmentsLocked() throws {
        guard var state = loadedState else { return }
        guard !state.cleanupIntentsByMutationID.isEmpty else { return }

        var completed: [SyncAttachmentCleanupIntent] = []
        var retained: [UUID: SyncAttachmentCleanupIntent] = [:]
        var firstRemovalError: Error?
        for cleanup in state.cleanupIntentsByMutationID.values {
            guard let proof = state.seenByMutationID[cleanup.mutationID],
                  Self.cleanupIntent(for: proof) == cleanup else {
                throw SyncMutationJournalError.corrupt
            }
            if isCleanupCompleted(cleanup, in: state) {
                continue
            }
            do {
                if try removeStagedAttachmentForBatch(cleanup, remaining: state.pending) {
                    completed.append(cleanup)
                } else {
                    retained[cleanup.mutationID] = cleanup
                }
            } catch {
                if firstRemovalError == nil { firstRemovalError = error }
                retained[cleanup.mutationID] = cleanup
            }
        }

        if !completed.isEmpty {
            let root = attachmentsDirectory.standardizedFileURL
            try synchronizeDirectory(try pathExists(root) ? root : root.deletingLastPathComponent())
            let durableCleanups = completed.sorted(by: Self.cleanupIntentPrecedes)
            let frame = try makeFrame(
                sequence: state.nextSequence,
                kind: .cleanupCompletion,
                value: durableCleanups
            )
            var candidate = state
            try apply(frame, to: &candidate)
            candidate.cleanupIntentsByMutationID = retained
            // Completion is appended only after every successful/absent unlink and the
            // shared attachment-directory barrier. A failed append intentionally retries.
            try appendReconcilingMemoryLocked([frame], candidate: candidate)
        } else {
            state.cleanupIntentsByMutationID = retained
            loadedState = state
        }
        if let firstRemovalError { throw firstRemovalError }
    }

    private static func cleanupIntentPrecedes(
        _ lhs: SyncAttachmentCleanupIntent,
        _ rhs: SyncAttachmentCleanupIntent
    ) -> Bool {
        let left = (lhs.mutationID.uuidString, lhs.attachmentVersionID.uuidString)
        let right = (rhs.mutationID.uuidString, rhs.attachmentVersionID.uuidString)
        return left < right
    }

    private static func defaultRemoveStagedFile(_ file: URL) throws {
        guard file.path.withCString({ Darwin.unlink($0) }) == 0 else {
            throw currentPOSIXError()
        }
    }

    private static func defaultAppendFrames(
        _ data: Data,
        to destination: URL,
        synchronizeFile: SynchronizeFile,
        synchronizeDirectory: SynchronizeDirectory
    ) throws {
        guard !data.isEmpty, data.count <= maximumEncodedBytes else {
            throw SyncMutationJournalError.tooLarge
        }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var pathStatus = stat()
        let pathResult = destination.path.withCString { Darwin.lstat($0, &pathStatus) }
        let existed = pathResult == 0
        if existed, !isRegularFile(pathStatus) {
            throw SyncMutationJournalError.unsafeFile
        }
        if !existed, errno != ENOENT { throw currentPOSIXError() }

        let descriptor = destination.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw SyncMutationJournalError.unsafeFile }
            throw currentPOSIXError()
        }
        defer { Darwin.close(descriptor) }

        var openedStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0 else {
            throw currentPOSIXError()
        }
        guard isRegularFile(openedStatus) else {
            throw SyncMutationJournalError.unsafeFile
        }
        if existed {
            guard pathStatus.st_dev == openedStatus.st_dev,
                  pathStatus.st_ino == openedStatus.st_ino else {
                throw SyncMutationJournalError.unsafeFile
            }
        }
        guard openedStatus.st_size >= 0,
              openedStatus.st_size <= off_t(maximumEncodedBytes - data.count) else {
            throw SyncMutationJournalError.tooLarge
        }

        try write(data, to: descriptor)
        try synchronizeFile(descriptor)
        if !existed { try synchronizeDirectory(parent) }
    }

    private static func defaultAtomicWrite(
        _ data: Data,
        to destination: URL,
        synchronizeDirectory: SynchronizeDirectory
    ) throws {
        guard data.count <= maximumEncodedBytes else {
            throw SyncMutationJournalError.tooLarge
        }
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        var liveStatus = stat()
        let liveResult = destination.path.withCString { Darwin.lstat($0, &liveStatus) }
        if liveResult == 0, !isRegularFile(liveStatus) {
            throw SyncMutationJournalError.unsafeFile
        }
        if liveResult != 0, errno != ENOENT { throw currentPOSIXError() }

        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        var temporaryExists = false
        defer { if temporaryExists { try? fileManager.removeItem(at: temporary) } }

        let descriptor = try openNewFile(at: temporary)
        temporaryExists = true
        do {
            defer { Darwin.close(descriptor) }
            try write(data, to: descriptor)
            guard Darwin.fsync(descriptor) == 0 else { throw currentPOSIXError() }
        }

        let renameResult = temporary.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard renameResult == 0 else { throw currentPOSIXError() }
        temporaryExists = false
        try synchronizeDirectory(parent)
    }

    private static func openNewFile(at url: URL) throws -> Int32 {
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else { throw currentPOSIXError() }
        return descriptor
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var writtenByteCount = 0
            while writtenByteCount < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: writtenByteCount),
                    bytes.count - writtenByteCount
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw currentPOSIXError() }
                writtenByteCount += result
            }
        }
    }

    private static func defaultSynchronizeFile(_ descriptor: Int32) throws {
        guard Darwin.fsync(descriptor) == 0 else { throw currentPOSIXError() }
    }

    private static func defaultSynchronizeDirectory(_ directory: URL) throws {
        let descriptor = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw currentPOSIXError() }
    }

    private static func isRegularFile(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == S_IFREG
    }

    private func currentPOSIXError() -> POSIXError { Self.currentPOSIXError() }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
