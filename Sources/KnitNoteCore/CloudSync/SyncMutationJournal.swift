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
                  }),
                  let attachmentSource,
                  attachmentSource.contentSHA256 == attachment.contentSHA256,
                  attachmentSource.byteCount == attachment.byteCount else {
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
    func acknowledge(_ identities: Set<SyncMutationIdentity>) throws
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

struct SyncMutationDuplicateProof: Codable, Equatable, Sendable {
    let mutationID: UUID
    let recordID: SyncEntityID
    let intent: SyncMutationIntent
    let recordVersionSHA256: Data?
    let attachmentContentSHA256: Data?
    let attachmentByteCount: Int64?
}

struct SyncAttachmentCleanupIntent: Codable, Equatable, Hashable, Sendable {
    let mutationID: UUID
    let attachmentVersionID: UUID
}

struct SyncJournalCheckpoint: Codable, Sendable {
    let version: Int
    let throughSequence: UInt64
    let pending: [SyncMutation]
    let proofShardCount: Int
    let cleanupIntents: [SyncAttachmentCleanupIntent]
    let legacyHistory: [SyncMutation]?

    private enum CodingKeys: String, CodingKey {
        case version, throughSequence, pending, proofShardCount, cleanupIntents, history
    }

    init(
        version: Int = 2,
        throughSequence: UInt64,
        pending: [SyncMutation],
        proofShardCount: Int = 0,
        cleanupIntents: [SyncAttachmentCleanupIntent] = []
    ) {
        self.version = version
        self.throughSequence = throughSequence
        self.pending = pending
        self.proofShardCount = proofShardCount
        self.cleanupIntents = cleanupIntents
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
        cleanupIntents = try container.decodeIfPresent(
            [SyncAttachmentCleanupIntent].self,
            forKey: .cleanupIntents
        ) ?? []
        legacyHistory = try container.decodeIfPresent(
            [SyncMutation].self,
            forKey: .history
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(throughSequence, forKey: .throughSequence)
        try container.encode(pending, forKey: .pending)
        try container.encode(proofShardCount, forKey: .proofShardCount)
        try container.encode(cleanupIntents, forKey: .cleanupIntents)
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

    fileprivate func recordAppendedFrames(_ count: Int) {
        storage.lock.withLock { storage.appendedFrameCount += count }
    }

    fileprivate func recordCheckpointRewrite() {
        storage.lock.withLock { storage.fullCheckpointRewriteCount += 1 }
    }

    fileprivate func recordBytesRead(_ count: Int) {
        storage.lock.withLock { storage.bytesRead += count }
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

    private let url: URL
    private let atomicWrite: AtomicWrite
    private let appendFrames: AppendFrames
    private let synchronizeFile: SynchronizeFile
    private let synchronizeDirectory: SynchronizeDirectory
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
            reader: .init(),
            counters: counters
        )
    }

    convenience init(
        url: URL,
        coordinatorRegistry: SyncJournalURLCoordinatorRegistry = .shared,
        synchronizeFile: @escaping SynchronizeFile,
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
                    synchronizeFile: synchronizeFile,
                    synchronizeDirectory: synchronizeDirectory
                )
            },
            synchronizeFile: synchronizeFile,
            synchronizeDirectory: synchronizeDirectory,
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
        reader: SyncRegularFileReader,
        counters: SyncJournalIOCounters,
        coordinatorRegistry: SyncJournalURLCoordinatorRegistry = .shared
    ) {
        self.url = url
        self.atomicWrite = atomicWrite
        self.appendFrames = appendFrames
        self.synchronizeFile = synchronizeFile
        self.synchronizeDirectory = synchronizeDirectory
        self.reader = reader
        self.counters = counters
        self.coordinator = coordinatorRegistry.coordinator(for: url)
    }

    public func enqueue(_ mutations: [SyncMutation]) throws {
        guard !mutations.isEmpty else { return }
        try withJournalCoordination {
            var candidate = try preparedStateLocked()
            var frames: [SyncJournalFrame] = []
            for requested in mutations {
                let requested = try requested.validated()
                let requestedProof = try Self.duplicateProof(for: requested)
                if let existing = candidate.seenByMutationID[requested.mutationID] {
                    guard existing == requestedProof else {
                        throw SyncMutationJournalError.duplicateMutationID
                    }
                    continue
                }
                let staged = try stageAttachmentIfNeeded(for: requested)
                let frame = try makeFrame(
                    sequence: candidate.nextSequence,
                    kind: .enqueue,
                    value: staged
                )
                try apply(frame, to: &candidate)
                frames.append(frame)
            }
            guard !frames.isEmpty else {
                try compactIfNeededLocked()
                return
            }
            try appendReconcilingMemoryLocked(frames, candidate: candidate)
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
        return SyncMutationDuplicateProof(
            mutationID: mutation.mutationID,
            recordID: mutation.recordID,
            intent: mutation.intent,
            recordVersionSHA256: recordVersionSHA256,
            attachmentContentSHA256: mutation.attachmentSource?.contentSHA256,
            attachmentByteCount: mutation.attachmentSource?.byteCount
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
        let attachmentMatchesRecordKind = (proof.attachmentContentSHA256 != nil)
            == (proof.intent == .save && proof.recordID.kind == .attachment)
        guard recordVersionIsValid,
              attachmentIsValid,
              attachmentMatchesRecordKind,
              proof.intent == .save || proof.attachmentContentSHA256 == nil else {
            throw SyncMutationJournalError.corrupt
        }
    }

    public func pending() throws -> [SyncMutation] {
        try withJournalCoordination { try preparedStateLocked().pending }
    }

    public func acknowledge(_ identities: Set<SyncMutationIdentity>) throws {
        guard !identities.isEmpty else { return }
        try withJournalCoordination {
            var candidate = try preparedStateLocked()
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
            reconcileAcknowledgedAttachmentsLocked()
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
        reconcileAcknowledgedAttachmentsLocked()
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

    private func loadSegmentedStateLocked() throws -> LoadedState {
        var checkpoint = SyncJournalCheckpoint(throughSequence: 0, pending: [])
        var totalBytes = 0
        if let checkpointData = try readArtifact(checkpointURL) {
            totalBytes += checkpointData.count
            checkpoint = try decodeCheckpoint(checkpointData)
        }
        guard (checkpoint.version == 1 || checkpoint.version == 2),
              checkpoint.throughSequence < UInt64.max,
              checkpoint.proofShardCount >= 0,
              checkpoint.proofShardCount <= Self.maximumProofShardCount else {
            throw SyncMutationJournalError.corrupt
        }

        var seen: [UUID: SyncMutationDuplicateProof] = [:]
        var unpersistedProofs: [SyncMutationDuplicateProof] = []
        var cleanupIntents = checkpoint.cleanupIntents
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
                guard let shardData = try readArtifact(proofShardURL(index)) else {
                    throw SyncMutationJournalError.corrupt
                }
                let shard = try decodeProofShard(shardData)
                guard shard.index == index,
                      !shard.proofs.isEmpty,
                      shard.proofs.count <= Self.proofShardEntryLimit else {
                    throw SyncMutationJournalError.corrupt
                }
                for proof in shard.proofs {
                    try Self.validateDuplicateProof(proof)
                    guard seen[proof.mutationID] == nil else {
                        throw SyncMutationJournalError.corrupt
                    }
                    seen[proof.mutationID] = proof
                }
            }
        }
        var pending: [SyncMutation] = []
        for mutation in checkpoint.pending {
            let validated = try mutation.validatedForJournalLoad()
            let proof = try Self.duplicateProof(for: validated)
            if let historical = seen[validated.mutationID] {
                guard historical == proof else {
                    throw SyncMutationJournalError.corrupt
                }
            } else {
                seen[validated.mutationID] = proof
                unpersistedProofs.append(proof)
            }
            try validatePersistedAttachmentSource(in: validated)
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
               seenCleanupIntents.insert(cleanup).inserted {
                cleanupIntents.append(cleanup)
            }
        }
        var state = LoadedState(
            pending: pending,
            seenByMutationID: seen,
            proofShardCount: checkpoint.proofShardCount,
            unpersistedProofs: unpersistedProofs,
            cleanupIntents: cleanupIntents,
            nextSequence: checkpoint.throughSequence + 1,
            framesSinceCheckpoint: 0,
            enqueuedOperationCount: 0,
            acknowledgedOperationCount: 0,
            validSegmentByteCount: 0,
            hasPartialFinalFrame: false
        )

        if let segmentData = try readArtifact(segmentURL) {
            totalBytes += segmentData.count
            guard totalBytes <= Self.maximumEncodedBytes else {
                throw SyncMutationJournalError.tooLarge
            }
            try replaySegment(segmentData, after: checkpoint.throughSequence, into: &state)
        }
        for mutation in state.pending {
            try validatePersistedAttachmentSource(in: mutation)
        }
        if checkpoint.version == 1 {
            try replaceLegacyHistoryCheckpointLocked(&state)
        }
        return state
    }

    private func replaceLegacyHistoryCheckpointLocked(_ state: inout LoadedState) throws {
        var proofShardCount = 0
        for chunkStart in stride(
            from: 0,
            to: state.unpersistedProofs.count,
            by: Self.proofShardEntryLimit
        ) {
            let chunkEnd = min(
                chunkStart + Self.proofShardEntryLimit,
                state.unpersistedProofs.count
            )
            try atomicWrite(
                try encodeProofShard(
                    index: proofShardCount,
                    proofs: Array(state.unpersistedProofs[chunkStart..<chunkEnd])
                ),
                proofShardURL(proofShardCount)
            )
            proofShardCount += 1
        }
        let throughSequence = state.nextSequence - 1
        try atomicWrite(try encodeCheckpoint(SyncJournalCheckpoint(
            throughSequence: throughSequence,
            pending: state.pending,
            proofShardCount: proofShardCount,
            cleanupIntents: []
        )), checkpointURL)
        counters.recordCheckpointRewrite()
        try atomicWrite(Data(), segmentURL)
        state.proofShardCount = proofShardCount
        state.unpersistedProofs = []
        state.framesSinceCheckpoint = 0
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
        guard let current = loadedState,
              current.framesSinceCheckpoint >= 256,
              current.acknowledgedOperationCount * 2 >= current.enqueuedOperationCount else {
            return
        }
        let throughSequence = current.nextSequence - 1
        var proofShardCount = current.proofShardCount
        for chunkStart in stride(
            from: 0,
            to: current.unpersistedProofs.count,
            by: Self.proofShardEntryLimit
        ) {
            let chunkEnd = min(
                chunkStart + Self.proofShardEntryLimit,
                current.unpersistedProofs.count
            )
            guard proofShardCount < Self.maximumProofShardCount else {
                throw SyncMutationJournalError.tooLarge
            }
            let proofs = Array(current.unpersistedProofs[chunkStart..<chunkEnd])
            try atomicWrite(
                try encodeProofShard(index: proofShardCount, proofs: proofs),
                proofShardURL(proofShardCount)
            )
            proofShardCount += 1
        }
        let checkpoint = SyncJournalCheckpoint(
            throughSequence: throughSequence,
            pending: current.pending,
            proofShardCount: proofShardCount,
            cleanupIntents: []
        )
        try atomicWrite(try encodeCheckpoint(checkpoint), checkpointURL)
        counters.recordCheckpointRewrite()
        try atomicWrite(Data(), segmentURL)
        loadedState = LoadedState(
            pending: current.pending,
            seenByMutationID: current.seenByMutationID,
            proofShardCount: proofShardCount,
            unpersistedProofs: [],
            cleanupIntents: current.cleanupIntents,
            nextSequence: throughSequence + 1,
            framesSinceCheckpoint: 0,
            enqueuedOperationCount: 0,
            acknowledgedOperationCount: 0,
            validSegmentByteCount: 0,
            hasPartialFinalFrame: false
        )
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
        guard frame.sequence == state.nextSequence else {
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
            if let existing = state.seenByMutationID[mutation.mutationID] {
                guard existing == proof else {
                    throw SyncMutationJournalError.corrupt
                }
            } else {
                state.seenByMutationID[mutation.mutationID] = proof
                state.unpersistedProofs.append(proof)
                state.pending.append(mutation)
            }
            state.enqueuedOperationCount += 1
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
            guard let index = state.pending.firstIndex(where: { $0.identity == identity }) else {
                throw SyncMutationJournalError.corrupt
            }
            if let cleanup = Self.cleanupIntent(for: state.pending[index]),
               !state.cleanupIntents.contains(cleanup) {
                state.cleanupIntents.append(cleanup)
            }
            state.pending.remove(at: index)
            state.acknowledgedOperationCount += 1
        }
        state.framesSinceCheckpoint += 1
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
            ProofShardPayload(version: 1, index: index, proofs: proofs)
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
            let payload = try JSONDecoder().decode(ProofShardPayload.self, from: file.payload)
            guard payload.version == 1 else { throw SyncMutationJournalError.corrupt }
            return payload
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
        for chunkStart in stride(
            from: 0,
            to: proofs.count,
            by: Self.proofShardEntryLimit
        ) {
            let chunkEnd = min(chunkStart + Self.proofShardEntryLimit, proofs.count)
            try atomicWrite(
                try encodeProofShard(
                    index: proofShardCount,
                    proofs: Array(proofs[chunkStart..<chunkEnd])
                ),
                proofShardURL(proofShardCount)
            )
            proofShardCount += 1
        }
        let checkpoint = SyncJournalCheckpoint(
            throughSequence: 0,
            pending: mutations,
            proofShardCount: proofShardCount
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
            unpersistedProofs: [],
            cleanupIntents: [],
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
        return try envelope.mutations.map { mutation in
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

    private func readArtifact(_ artifactURL: URL) throws -> Data? {
        guard try pathExists(artifactURL) else { return nil }
        do {
            let read = try reader.read(
                artifactURL,
                maximumBytes: Self.maximumEncodedBytes
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
        let proofShardCount = loadedState?.proofShardCount ?? 0
        return JournalFingerprint(
            legacy: try artifactFingerprint(url),
            checkpoint: try artifactFingerprint(checkpointURL),
            segment: try artifactFingerprint(segmentURL),
            proofShards: try (0..<proofShardCount).map {
                try artifactFingerprint(proofShardURL($0))
            }
        )
    }

    private func artifactFingerprint(_ artifactURL: URL) throws -> ArtifactFingerprint? {
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
        var unpersistedProofs: [SyncMutationDuplicateProof]
        var cleanupIntents: [SyncAttachmentCleanupIntent]
        var nextSequence: UInt64
        var framesSinceCheckpoint: Int
        var enqueuedOperationCount: Int
        var acknowledgedOperationCount: Int
        var validSegmentByteCount: Int
        var hasPartialFinalFrame: Bool

        static let empty = LoadedState(
            pending: [],
            seenByMutationID: [:],
            proofShardCount: 0,
            unpersistedProofs: [],
            cleanupIntents: [],
            nextSequence: 1,
            framesSinceCheckpoint: 0,
            enqueuedOperationCount: 0,
            acknowledgedOperationCount: 0,
            validSegmentByteCount: 0,
            hasPartialFinalFrame: false
        )
    }

    private struct JournalFingerprint: Equatable {
        let legacy: ArtifactFingerprint?
        let checkpoint: ArtifactFingerprint?
        let segment: ArtifactFingerprint?
        let proofShards: [ArtifactFingerprint?]
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
        guard expectedByteCount >= 0,
              expectedByteCount <= Int64(Int.max) else {
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

    private func removeStagedAttachmentIfUnreferenced(
        _ cleanup: SyncAttachmentCleanupIntent,
        remaining: [SyncMutation]
    ) -> Bool {
        let filename = "\(cleanup.mutationID.uuidString)-\(cleanup.attachmentVersionID.uuidString).asset"
        let root = attachmentsDirectory.standardizedFileURL
        let file = root.appendingPathComponent(filename).standardizedFileURL
        guard !remaining.contains(where: { $0.attachmentSource?.fileURL == file }) else {
            return false
        }
        guard file.deletingLastPathComponent().path == root.path,
              file.path.hasPrefix(root.path + "/"),
              file.resolvingSymlinksInPath().path == file.path else { return false }
        var status = stat()
        let pathResult = file.path.withCString { Darwin.lstat($0, &status) }
        if pathResult != 0 {
            guard errno == ENOENT else { return false }
            do {
                if try pathExists(root) { try synchronizeDirectory(root) }
                return true
            } catch {
                return false
            }
        }
        guard Self.isRegularFile(status),
              file.path.withCString({ Darwin.unlink($0) }) == 0 else { return false }
        do {
            try synchronizeDirectory(root)
            return true
        } catch {
            return false
        }
    }

    private func reconcileAcknowledgedAttachmentsLocked() {
        guard var state = loadedState else { return }
        state.cleanupIntents.removeAll {
            removeStagedAttachmentIfUnreferenced($0, remaining: state.pending)
        }
        loadedState = state
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
