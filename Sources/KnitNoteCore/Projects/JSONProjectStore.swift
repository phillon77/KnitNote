import Combine
import CryptoKit
import Darwin
import Foundation

enum SyncCanonicalPublicationBoundary: CaseIterable {
    case afterIntent, afterArchive, afterJournal, afterCheckpoint, beforeIntentRemoval
}

public struct ProjectArchive: Codable, Sendable {
    public static let minimumSupportedVersion = 1
    public static let patternLibraryIntroducedVersion = 10
    public static let patternFoldersIntroducedVersion = 13

    public static func isSupported(version: Int) -> Bool {
        (minimumSupportedVersion...currentVersion).contains(version)
    }

    public static func supportsPatternLibrary(version: Int) -> Bool {
        isSupported(version: version) && version >= patternLibraryIntroducedVersion
    }

    public let version: Int
    public var projects: [StoredProject]
    public var yarns: [StoredYarn]
    public var patternFolders: [PatternFolder]
    public var patternAssets: [PatternAsset]
    public var patterns: [StoredPattern]
    public var patternUsages: [PatternProjectUsage]

    public init(
        version: Int,
        projects: [StoredProject],
        yarns: [StoredYarn] = [],
        patternFolders: [PatternFolder] = [],
        patternAssets: [PatternAsset] = [],
        patterns: [StoredPattern] = [],
        patternUsages: [PatternProjectUsage] = []
    ) {
        self.version = version
        self.projects = projects
        self.yarns = yarns
        self.patternFolders = patternFolders
        self.patternAssets = patternAssets
        self.patterns = patterns
        self.patternUsages = patternUsages
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case projects
        case yarns
        case patternFolders
        case patternAssets
        case patterns
        case patternUsages
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        projects = try values.decode([StoredProject].self, forKey: .projects)
        yarns = try values.decodeIfPresent([StoredYarn].self, forKey: .yarns) ?? []
        patternFolders = try values.decodeIfPresent(
            [PatternFolder].self,
            forKey: .patternFolders
        ) ?? []
        patternAssets = try values.decodeIfPresent([PatternAsset].self, forKey: .patternAssets) ?? []
        patterns = try values.decodeIfPresent([StoredPattern].self, forKey: .patterns) ?? []
        patternUsages = try values.decodeIfPresent([PatternProjectUsage].self, forKey: .patternUsages) ?? []
    }
}

/// Durable local evidence of the active issued version for each attachment
/// slot. The archive deliberately retains user content only, so this sidecar
/// keeps a restart from minting an ID or guessing a replacement lineage.
struct SyncAttachmentPublicationEvidence: Codable, Equatable {
    fileprivate var storageVersion: Int
    fileprivate var versions: [SyncAttachmentVersion]
    fileprivate var deletedVersionIDs: Set<UUID>
    private(set) var watchCommandProofs: [SyncProcessedWatchCommandProof]
    fileprivate var attachmentRecords: [SyncRecord]

    init(
        versions: [SyncAttachmentVersion] = [],
        deletedVersionIDs: Set<UUID> = [],
        watchCommandProofs: [SyncProcessedWatchCommandProof] = [],
        attachmentRecords: [SyncRecord] = [],
        storageVersion: Int = 2
    ) {
        self.storageVersion = storageVersion
        self.versions = versions
        self.deletedVersionIDs = deletedVersionIDs
        self.watchCommandProofs = watchCommandProofs
        self.attachmentRecords = attachmentRecords
    }

    private enum CodingKeys: String, CodingKey {
        case storageVersion, versions, deletedVersionIDs, watchCommandProofs, attachmentRecords
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storageVersion = try container.decodeIfPresent(Int.self, forKey: .storageVersion) ?? 1
        versions = try container.decodeIfPresent(
            [SyncAttachmentVersion].self, forKey: .versions
        ) ?? []
        deletedVersionIDs = Set(try container.decodeIfPresent(
            [UUID].self, forKey: .deletedVersionIDs
        ) ?? [])
        watchCommandProofs = try container.decodeIfPresent(
            [SyncProcessedWatchCommandProof].self, forKey: .watchCommandProofs
        ) ?? []
        attachmentRecords = try container.decodeIfPresent(
            [SyncRecord].self, forKey: .attachmentRecords
        ) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(storageVersion, forKey: .storageVersion)
        try container.encode(versions, forKey: .versions)
        try container.encode(
            deletedVersionIDs.sorted { $0.uuidString < $1.uuidString },
            forKey: .deletedVersionIDs
        )
        try container.encode(
            watchCommandProofs.sorted { $0.id.uuidString < $1.id.uuidString },
            forKey: .watchCommandProofs
        )
        try container.encode(
            attachmentRecords.sorted { $0.id.uuid.uuidString < $1.id.uuid.uuidString },
            forKey: .attachmentRecords
        )
    }

    var allVersions: [SyncAttachmentVersion] { versions }
    var deletedVersionIDSet: Set<UUID> { deletedVersionIDs }

    func watchCommandProof(
        for command: WatchCounterCommand
    ) throws -> SyncProcessedWatchCommandProof? {
        guard let proof = watchCommandProofs.first(where: { $0.id == command.id }) else {
            return nil
        }
        guard try proof.validated().commandIdentity == ProcessedWatchCommandIdentity(command),
              proof.commandIdentity != nil else {
            throw SyncPublicationTransactionFileError.corrupt
        }
        return proof
    }

    func orphanWatchCommandProof(
        for command: WatchCounterCommand
    ) throws -> SyncProcessedWatchCommandProof? {
        guard let proof = try watchCommandProof(for: command),
              proof.rejection == .projectMissing || proof.rejection == .counterMissing else {
            return nil
        }
        do {
            _ = try SyncOrphanWatchCommandProof(proof: proof)
        } catch {
            throw SyncPublicationTransactionFileError.corrupt
        }
        return proof
    }

    func isDeleted(_ versionID: UUID) -> Bool {
        deletedVersionIDs.contains(versionID)
    }

    func validated() throws -> Self {
        guard storageVersion == 1 || storageVersion == 2 else {
            throw SyncPublicationTransactionFileError.corrupt
        }
        var records: [SyncRecord] = []
        var seenVersionIDs: Set<UUID> = []
        var issuedRecordByVersionID: [UUID: SyncRecord] = [:]
        for record in attachmentRecords {
            let validated: SyncRecord
            do {
                validated = try SyncRecordValidator().validate(record)
            } catch {
                throw SyncPublicationTransactionFileError.corrupt
            }
            guard let attachment = validated.payload.attachment,
                  issuedRecordByVersionID.updateValue(
                    validated,
                    forKey: attachment.versionID
                  ) == nil else {
                throw SyncPublicationTransactionFileError.corrupt
            }
        }
        let stamp = SyncMutationStamp(
            logicalRevision: 0,
            modifiedAt: .distantPast,
            deviceID: "publication-evidence"
        )
        for version in versions {
            _ = try version.validated()
            guard seenVersionIDs.insert(version.versionID).inserted else {
                throw SyncPublicationTransactionFileError.corrupt
            }
            if let issuedRecord = issuedRecordByVersionID[version.versionID] {
                guard issuedRecord.payload.attachment == version else {
                    throw SyncPublicationTransactionFileError.corrupt
                }
                records.append(issuedRecord)
            } else {
                // Version-only evidence is a readable legacy format, but its
                // missing immutable record must never be reconstructed for a
                // new tombstone.
                records.append(SyncRecord(
                    schemaVersion: 1,
                    id: .init(kind: .attachment, uuid: version.versionID),
                    createdAt: .distantPast,
                    entityRevision: 0,
                    payload: .init(fields: [:], attachment: version),
                    relationships: [.init(role: "owner", target: version.slot.owner)],
                    deletedAt: .init(
                        value: deletedVersionIDs.contains(version.versionID)
                            ? .distantPast
                            : nil,
                        stamp: stamp
                    )
                ))
            }
        }
        guard deletedVersionIDs.isSubset(of: seenVersionIDs),
              Set(issuedRecordByVersionID.keys).isSubset(of: seenVersionIDs) else {
            throw SyncPublicationTransactionFileError.corrupt
        }
        let lineage: SyncAttachmentLineage
        do {
            lineage = try SyncAttachmentLineage(records: records)
        } catch {
            throw SyncPublicationTransactionFileError.corrupt
        }
        guard lineage.headsBySlot.values.allSatisfy({ heads in
                  heads.count == 1 || heads.allSatisfy { issuedRecordByVersionID[$0.id.uuid] != nil }
              }),
              Set(watchCommandProofs.map(\.id)).count == watchCommandProofs.count,
              watchCommandProofs.allSatisfy({ (try? $0.validated()) != nil }) else {
            throw SyncPublicationTransactionFileError.corrupt
        }
        return self
    }

    func version(for slot: SyncAttachmentSlot) -> SyncAttachmentVersion? {
        let replaced = Set(versions.compactMap(\.replacesVersionID))
        let heads = versions.filter { $0.slot == slot && !replaced.contains($0.versionID) }
        if heads.count == 1 { return heads[0] }
        guard heads.allSatisfy({ head in attachmentRecords.contains { $0.id.uuid == head.versionID } }),
              let lineage = try? SyncAttachmentLineage(records: attachmentRecords) else { return nil }
        return lineage.resolvedHeadsBySlot()[slot]?.payload.attachment
    }

    func versionID(for slot: SyncAttachmentSlot) -> UUID? {
        version(for: slot)?.versionID
    }

    func versionsBySlot() -> [SyncAttachmentSlot: SyncAttachmentVersion] {
        Dictionary(uniqueKeysWithValues: Set(versions.map(\.slot)).compactMap { slot in
            version(for: slot).map { (slot, $0) }
        })
    }

    func record(for slot: SyncAttachmentSlot) -> SyncRecord? {
        guard let versionID = versionID(for: slot) else { return nil }
        return attachmentRecords.first { $0.id.uuid == versionID }
    }

    func recordsBySlot() -> [SyncAttachmentSlot: SyncRecord] {
        Dictionary(uniqueKeysWithValues: Set(versions.map(\.slot)).compactMap { slot in
            record(for: slot).map { (slot, $0) }
        })
    }

    var retainedAttachmentRecords: [SyncRecord] { attachmentRecords }

    mutating func apply(_ mutations: [SyncMutation]) throws {
        var proofsByID = Dictionary(uniqueKeysWithValues: watchCommandProofs.map {
            ($0.id, $0)
        })
        for mutation in mutations {
            switch mutation {
            case let .save(save):
                let record = save.recordVersion.record
                if let attachment = record.payload.attachment {
                    do {
                        _ = try SyncRecordValidator().validate(record)
                    } catch {
                        throw SyncPublicationTransactionFileError.corrupt
                    }
                    if let existing = versions.first(where: {
                        $0.versionID == attachment.versionID
                    }), existing != attachment {
                        throw SyncPublicationTransactionFileError.corrupt
                    }
                    if let index = attachmentRecords.firstIndex(where: {
                        $0.id.uuid == attachment.versionID
                    }) {
                        let existingRecord = attachmentRecords[index]
                        guard try SyncAttachmentImmutableSnapshot(record: existingRecord).sha256
                                == SyncAttachmentImmutableSnapshot(record: record).sha256 else {
                            throw SyncPublicationTransactionFileError.corrupt
                        }
                        if record.deletedAt.stamp > existingRecord.deletedAt.stamp {
                            attachmentRecords[index] = record
                        } else if record.deletedAt.stamp == existingRecord.deletedAt.stamp,
                                  record.deletedAt.value != existingRecord.deletedAt.value {
                            throw SyncPublicationTransactionFileError.corrupt
                        }
                    } else {
                        attachmentRecords.append(record)
                    }
                    if !versions.contains(where: { $0.versionID == attachment.versionID }) {
                        versions.append(attachment)
                    }
                    if record.deletedAt.value == nil {
                        guard !deletedVersionIDs.contains(attachment.versionID) else {
                            // Restoring a slot always issues a child version.
                            // Reusing a tombstoned immutable version would let a
                            // stale publication resurrect deleted bytes.
                            throw SyncPublicationTransactionFileError.corrupt
                        }
                    } else {
                        deletedVersionIDs.insert(attachment.versionID)
                    }
                }
                if case let .projectCounter(state)? = record.payload.atomicDomain?.value {
                    for proof in state.processedCommandProofs {
                        if let existing = proofsByID[proof.id], existing != proof {
                            throw SyncPublicationTransactionFileError.corrupt
                        }
                        proofsByID[proof.id] = proof
                    }
                }
                if case let .orphanWatchCommandProof(orphan)? =
                    record.payload.atomicDomain?.value {
                    let proof = orphan.proof
                    if let existing = proofsByID[proof.id], existing != proof {
                        throw SyncPublicationTransactionFileError.corrupt
                    }
                    proofsByID[proof.id] = proof
                }
            case let .delete(delete):
                guard delete.recordID.kind != .attachment
                        || versions.contains(where: {
                            $0.versionID == delete.recordID.uuid
                        }) && attachmentRecords.contains(where: {
                            $0.id == delete.recordID
                        }) else {
                    throw SyncPublicationTransactionFileError.corrupt
                }
                if delete.recordID.kind == .attachment {
                    deletedVersionIDs.insert(delete.recordID.uuid)
                }
            }
        }
        watchCommandProofs = proofsByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
        _ = try validated()
    }

    fileprivate mutating func retainWatchCommandProof(
        _ proof: SyncProcessedWatchCommandProof
    ) throws {
        _ = try proof.validated()
        if let existing = watchCommandProofs.first(where: { $0.id == proof.id }) {
            guard existing == proof else {
                throw SyncPublicationTransactionFileError.corrupt
            }
            return
        }
        watchCommandProofs.append(proof)
        watchCommandProofs.sort { $0.id.uuidString < $1.id.uuidString }
    }

    fileprivate func merged(
        with other: SyncAttachmentPublicationEvidence
    ) throws -> SyncAttachmentPublicationEvidence {
        var versionByID = Dictionary(uniqueKeysWithValues: versions.map {
            ($0.versionID, $0)
        })
        for version in other.versions {
            if let existing = versionByID[version.versionID], existing != version {
                throw SyncPublicationTransactionFileError.corrupt
            }
            versionByID[version.versionID] = version
        }

        var recordByID = Dictionary(uniqueKeysWithValues: attachmentRecords.map {
            ($0.id.uuid, $0)
        })
        for record in other.attachmentRecords {
            if let existing = recordByID[record.id.uuid] {
                guard try SyncAttachmentImmutableSnapshot(record: existing).sha256
                        == SyncAttachmentImmutableSnapshot(record: record).sha256 else {
                    throw SyncPublicationTransactionFileError.corrupt
                }
                if record.deletedAt.stamp > existing.deletedAt.stamp {
                    recordByID[record.id.uuid] = record
                } else if record.deletedAt.stamp == existing.deletedAt.stamp,
                          record.deletedAt.value != existing.deletedAt.value {
                    throw SyncPublicationTransactionFileError.corrupt
                }
            } else {
                recordByID[record.id.uuid] = record
            }
        }

        var proofByID = Dictionary(uniqueKeysWithValues: watchCommandProofs.map {
            ($0.id, $0)
        })
        for proof in other.watchCommandProofs {
            if let existing = proofByID[proof.id], existing != proof {
                throw SyncPublicationTransactionFileError.corrupt
            }
            proofByID[proof.id] = proof
        }

        // Restoration of an attachment uses a new child UUID. A newer live
        // overlay cannot clear an existing immutable version's reservation.
        let reserved = deletedVersionIDs.union(other.deletedVersionIDs)
        for record in recordByID.values where record.deletedAt.value == nil && reserved.contains(record.id.uuid) {
            let knownTombstones = (attachmentRecords + other.attachmentRecords).filter {
                $0.id == record.id && $0.deletedAt.value != nil
            }
            if !knownTombstones.isEmpty { throw SyncPublicationTransactionFileError.corrupt }
        }

        return try SyncAttachmentPublicationEvidence(
            versions: Array(versionByID.values),
            deletedVersionIDs: reserved.union(recordByID.values.filter { $0.deletedAt.value != nil }.map(\.id.uuid)),
            watchCommandProofs: Array(proofByID.values),
            attachmentRecords: Array(recordByID.values),
            storageVersion: 2
        ).canonicalized().validated()
    }

    fileprivate func compactedToActiveHeads() throws -> SyncAttachmentPublicationEvidence {
        let validated = try validated()
        let replacedVersionIDs = Set(validated.versions.compactMap(\.replacesVersionID))
        let heads = validated.versions.filter {
            !replacedVersionIDs.contains($0.versionID)
        }
        let headIDs = Set(heads.map(\.versionID))
        return try SyncAttachmentPublicationEvidence(
            versions: heads,
            deletedVersionIDs: validated.deletedVersionIDs.intersection(headIDs),
            watchCommandProofs: [],
            attachmentRecords: validated.attachmentRecords.filter {
                headIDs.contains($0.id.uuid)
            },
            storageVersion: 2
        ).canonicalized().validated()
    }

    fileprivate func canonicalized() -> SyncAttachmentPublicationEvidence {
        let versionByID = Dictionary(uniqueKeysWithValues: versions.map {
            ($0.versionID, $0)
        })
        func depth(of version: SyncAttachmentVersion) -> Int {
            var depth = 0
            var cursor = version.replacesVersionID
            var visited: Set<UUID> = []
            while let id = cursor,
                  visited.insert(id).inserted,
                  let parent = versionByID[id] {
                depth += 1
                cursor = parent.replacesVersionID
            }
            return depth
        }
        return SyncAttachmentPublicationEvidence(
            versions: versions.sorted {
                if $0.slot != $1.slot {
                    return syncAttachmentSlotIsOrderedBefore($0.slot, $1.slot)
                }
                let lhsDepth = depth(of: $0)
                let rhsDepth = depth(of: $1)
                if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
                return $0.versionID.uuidString < $1.versionID.uuidString
            },
            deletedVersionIDs: deletedVersionIDs,
            watchCommandProofs: watchCommandProofs.sorted {
                $0.id.uuidString < $1.id.uuidString
            },
            attachmentRecords: attachmentRecords.sorted {
                $0.id.uuid.uuidString < $1.id.uuid.uuidString
            },
            storageVersion: storageVersion
        )
    }
}

struct SyncPublicationEvidenceIOCountSnapshot: Equatable, Sendable {
    var headReads: Int
    var headWrites: Int
    var watchProofLookups: Int
    var watchProofWrites: Int
    var watchProofDirectoryEnumerations: Int
    var attachmentAuthorityLookups: Int
    var attachmentAuthorityWrites: Int
    var attachmentAuthorityDirectoryEnumerations: Int
}

final class SyncPublicationEvidenceIOCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var values = SyncPublicationEvidenceIOCountSnapshot(
        headReads: 0,
        headWrites: 0,
        watchProofLookups: 0,
        watchProofWrites: 0,
        watchProofDirectoryEnumerations: 0,
        attachmentAuthorityLookups: 0,
        attachmentAuthorityWrites: 0,
        attachmentAuthorityDirectoryEnumerations: 0
    )

    var snapshot: SyncPublicationEvidenceIOCountSnapshot {
        lock.withLock { values }
    }

    func reset() {
        lock.withLock {
            values = SyncPublicationEvidenceIOCountSnapshot(
                headReads: 0,
                headWrites: 0,
                watchProofLookups: 0,
                watchProofWrites: 0,
                watchProofDirectoryEnumerations: 0,
                attachmentAuthorityLookups: 0,
                attachmentAuthorityWrites: 0,
                attachmentAuthorityDirectoryEnumerations: 0
            )
        }
    }

    fileprivate func recordHeadRead() { update(\.headReads) }
    fileprivate func recordHeadWrite() { update(\.headWrites) }
    fileprivate func recordWatchProofLookup() { update(\.watchProofLookups) }
    fileprivate func recordWatchProofWrite() { update(\.watchProofWrites) }
    fileprivate func recordWatchProofDirectoryEnumeration() {
        update(\.watchProofDirectoryEnumerations)
    }
    fileprivate func recordAttachmentAuthorityLookup() {
        update(\.attachmentAuthorityLookups)
    }
    fileprivate func recordAttachmentAuthorityWrite() {
        update(\.attachmentAuthorityWrites)
    }
    fileprivate func recordAttachmentAuthorityDirectoryEnumeration() {
        update(\.attachmentAuthorityDirectoryEnumerations)
    }

    private func update(_ keyPath: WritableKeyPath<SyncPublicationEvidenceIOCountSnapshot, Int>) {
        lock.withLock { values[keyPath: keyPath] += 1 }
    }
}

private struct SyncStoredAttachmentVersionAuthority: Codable {
    let storageVersion: Int
    let version: SyncAttachmentVersion
    let record: SyncRecord?

    init(version: SyncAttachmentVersion, record: SyncRecord?) {
        storageVersion = 1
        self.version = version
        self.record = record
    }

    func validated() throws -> Self {
        guard storageVersion == 1 else {
            throw SyncPublicationTransactionFileError.corrupt
        }
        do {
            _ = try version.validated()
            if let record {
                _ = try SyncRecordValidator().validate(record)
                guard record.payload.attachment == version else {
                    throw SyncPublicationTransactionFileError.corrupt
                }
            }
        } catch let error as SyncPublicationTransactionFileError {
            throw error
        } catch {
            throw SyncPublicationTransactionFileError.corrupt
        }
        return self
    }
}

private struct SyncStoredAttachmentTombstoneAuthority: Codable {
    let storageVersion: Int
    let versionID: UUID
    let record: SyncRecord?

    init(versionID: UUID, record: SyncRecord?) {
        storageVersion = 1
        self.versionID = versionID
        self.record = record
    }

    func validated() throws -> Self {
        guard storageVersion == 1 else {
            throw SyncPublicationTransactionFileError.corrupt
        }
        if let record {
            do {
                _ = try SyncRecordValidator().validate(record)
                guard record.id == .init(kind: .attachment, uuid: versionID),
                      record.payload.attachment?.versionID == versionID,
                      record.deletedAt.value != nil else {
                    throw SyncPublicationTransactionFileError.corrupt
                }
            } catch let error as SyncPublicationTransactionFileError {
                throw error
            } catch {
                throw SyncPublicationTransactionFileError.corrupt
            }
        }
        return self
    }
}

private struct SyncStoredWatchCommandProof: Codable {
    let storageVersion: Int
    let proof: SyncProcessedWatchCommandProof

    init(proof: SyncProcessedWatchCommandProof) {
        storageVersion = 1
        self.proof = proof
    }

    func validated() throws -> Self {
        guard storageVersion == 1 else {
            throw SyncPublicationTransactionFileError.corrupt
        }
        do {
            _ = try proof.validated()
        } catch {
            throw SyncPublicationTransactionFileError.corrupt
        }
        return self
    }
}

struct SyncAttachmentPublicationEvidenceFile {
    private static let maximumEncodedBytes = FileSyncMutationJournal.maximumEncodedBytes
    private static let maximumAuthorityBytes = 16 * 1_024 * 1_024
    private static let maximumWatchProofBytes = 1 * 1_024 * 1_024

    let url: URL
    let beforeDurabilityBoundary: (SyncDurableFileWriteBoundary) throws -> Void
    let reader: any SyncRegularFileReading
    let counters: SyncPublicationEvidenceIOCounters

    init(
        url: URL,
        beforeDurabilityBoundary: @escaping (SyncDurableFileWriteBoundary) throws -> Void = { _ in },
        reader: any SyncRegularFileReading = SyncRegularFileReader(),
        counters: SyncPublicationEvidenceIOCounters = SyncPublicationEvidenceIOCounters()
    ) {
        self.url = url
        self.beforeDurabilityBoundary = beforeDurabilityBoundary
        self.reader = reader
        self.counters = counters
    }

    func load() throws -> SyncAttachmentPublicationEvidence {
        try mappedOperation {
            try SyncDurableFile.withExclusiveFileLock(for: url) {
                let head = try loadHeadForReadUnlocked()
                var authorityByVersionID: [UUID: SyncStoredAttachmentVersionAuthority] = [:]
                var historicalDeletedVersionIDs: Set<UUID> = []
                for authorityURL in try immutableFileURLs(
                    in: attachmentAuthoritiesRootURL,
                    countingWatchProofs: false
                ) {
                    let authority = try readAttachmentAuthority(at: authorityURL)
                    guard authorityByVersionID.updateValue(
                        authority,
                        forKey: authority.version.versionID
                    ) == nil else {
                        throw SyncPublicationTransactionFileError.corrupt
                    }
                }
                var tombstoneByVersionID: [UUID: SyncStoredAttachmentTombstoneAuthority] = [:]
                for tombstoneURL in try immutableFileURLs(
                    in: attachmentTombstonesRootURL,
                    countingWatchProofs: false
                ) {
                    let tombstone = try readAttachmentTombstone(at: tombstoneURL)
                    guard tombstoneByVersionID.updateValue(
                        tombstone,
                        forKey: tombstone.versionID
                    ) == nil else {
                        throw SyncPublicationTransactionFileError.corrupt
                    }
                }
                var historicalRecords: [SyncRecord] = []
                for authority in authorityByVersionID.values {
                    if let tombstone = tombstoneByVersionID[authority.version.versionID] {
                        historicalDeletedVersionIDs.insert(authority.version.versionID)
                        if let tombstoneRecord = tombstone.record {
                            guard let issuedRecord = authority.record,
                                  try SyncAttachmentImmutableSnapshot(record: issuedRecord).sha256
                                    == SyncAttachmentImmutableSnapshot(record: tombstoneRecord)
                                        .sha256 else {
                                throw SyncPublicationTransactionFileError.corrupt
                            }
                            historicalRecords.append(tombstoneRecord)
                        } else if let record = authority.record {
                            historicalRecords.append(record)
                        }
                    } else if let record = authority.record {
                        historicalRecords.append(record)
                        if record.deletedAt.value != nil {
                            throw SyncPublicationTransactionFileError.corrupt
                        }
                    }
                }
                guard tombstoneByVersionID.keys.allSatisfy({
                    authorityByVersionID[$0] != nil
                }) else {
                    throw SyncPublicationTransactionFileError.corrupt
                }
                let history = SyncAttachmentPublicationEvidence(
                    versions: authorityByVersionID.values.map(\.version),
                    deletedVersionIDs: historicalDeletedVersionIDs,
                    attachmentRecords: historicalRecords,
                    storageVersion: 2
                )
                var complete = try head.merged(with: history)
                for proofURL in try immutableFileURLs(
                    in: watchProofsRootURL,
                    countingWatchProofs: true
                ) {
                    try complete.retainWatchCommandProof(readWatchProof(at: proofURL))
                }
                return try complete.canonicalized().validated()
            }
        }
    }

    func watchCommandProof(
        for command: WatchCounterCommand
    ) throws -> SyncProcessedWatchCommandProof? {
        try mappedOperation {
            try SyncDurableFile.withExclusiveFileLock(for: url) {
                let head = try loadHeadForReadUnlocked()
                if let proof = try head.watchCommandProof(for: command) {
                    return proof
                }
                guard let proof = try loadWatchProof(command.id, countLookup: true) else {
                    return nil
                }
                guard proof.commandIdentity == ProcessedWatchCommandIdentity(command),
                      proof.commandIdentity != nil else {
                    throw SyncPublicationTransactionFileError.corrupt
                }
                return proof
            }
        }
    }

    func save(_ evidence: SyncAttachmentPublicationEvidence) throws {
        try mappedOperation {
            try SyncDurableFile.withExclusiveFileLock(for: url) {
                let validated = try evidence.canonicalized().validated()
                let authorities = attachmentAuthorities(in: validated)
                let tombstones = attachmentTombstones(in: validated)
                try preflight(
                    authorities: authorities,
                    tombstones: tombstones,
                    proofs: validated.watchCommandProofs
                )
                for authority in authorities { try install(authority) }
                for tombstone in tombstones { try install(tombstone) }
                for proof in validated.watchCommandProofs { try install(proof) }
                try writeHeadUnlocked(validated.compactedToActiveHeads())
            }
        }
    }

    /// Applies one bounded publication batch. Immutable Watch proofs and
    /// attachment-version authorities are addressed directly by UUID; only
    /// active attachment heads may rewrite the compact sidecar.
    func applying(
        _ mutations: [SyncMutation],
        retaining retainedEvidence: SyncAttachmentPublicationEvidence? = nil,
        validatingOnly: Bool = false
    ) throws -> SyncAttachmentPublicationEvidence {
        try mappedOperation {
            try SyncDurableFile.withExclusiveFileLock(for: url) {
                let head = try loadHeadForReadUnlocked()
                let priorCompactHead = try head.compactedToActiveHeads()
                var candidate = try (retainedEvidence ?? head).merged(with: head)
                var referencedAuthorities: [SyncStoredAttachmentVersionAuthority] = []
                var referencedTombstones: [SyncStoredAttachmentTombstoneAuthority] = []

                for versionID in attachmentVersionIDsReferenced(by: mutations) {
                    let authority = try loadAttachmentAuthority(
                        versionID,
                        countLookup: true
                    )
                    let tombstone = try loadAttachmentTombstone(
                        versionID,
                        countLookup: true
                    )
                    guard tombstone == nil || authority != nil else {
                        throw SyncPublicationTransactionFileError.corrupt
                    }
                    if let authority {
                        referencedAuthorities.append(authority)
                        if let tombstone { referencedTombstones.append(tombstone) }
                        candidate = try candidate.merged(with: evidence(
                            for: authority,
                            tombstone: tombstone
                        ))
                    }
                }
                let batchProofs = try watchProofs(in: mutations)
                for proof in batchProofs {
                    if let existing = try loadWatchProof(proof.id, countLookup: true) {
                        try candidate.retainWatchCommandProof(existing)
                    }
                }

                try candidate.apply(mutations)
                candidate = try candidate.canonicalized().validated()
                let compactHead = try candidate.compactedToActiveHeads()
                let authorities = try mergedAuthorities(
                    mergedAuthorities(
                        attachmentAuthorities(in: head), referencedAuthorities
                    ),
                    attachmentAuthorities(in: mutations)
                )
                let tombstones = try mergedTombstones(
                    mergedTombstones(
                        attachmentTombstones(in: head), referencedTombstones
                    ),
                    attachmentTombstones(in: mutations)
                )
                let allProofs = try mergedProofs(head.watchCommandProofs, batchProofs)
                try preflight(
                    authorities: authorities,
                    tombstones: tombstones,
                    proofs: allProofs
                )
                guard try deterministicEncoder().encode(compactHead).count <= Self.maximumEncodedBytes else {
                    throw SyncPublicationTransactionFileError.corrupt
                }
                if validatingOnly { return candidate }
                for authority in authorities { try install(authority) }
                for tombstone in tombstones { try install(tombstone) }
                for proof in allProofs { try install(proof) }
                if head.storageVersion != 2
                    || !head.watchCommandProofs.isEmpty
                    || head.canonicalized() != priorCompactHead
                    || compactHead != priorCompactHead {
                    try writeHeadUnlocked(compactHead)
                }
                return candidate
            }
        }
    }

    private var attachmentAuthoritiesRootURL: URL {
        url.deletingPathExtension().appendingPathExtension("attachment-records")
    }

    private var attachmentTombstonesRootURL: URL {
        url.deletingPathExtension().appendingPathExtension("attachment-tombstones")
    }

    private var watchProofsRootURL: URL {
        url.deletingPathExtension().appendingPathExtension("watch-proofs")
    }

    private func loadHeadForReadUnlocked() throws -> SyncAttachmentPublicationEvidence {
        let stored = try loadHeadUnlocked()
        let compact = try stored.compactedToActiveHeads()
        let isCurrentCompactHead = stored.storageVersion == 2
            && stored.watchCommandProofs.isEmpty
            && stored.canonicalized() == compact
        if isCurrentCompactHead {
            for authority in attachmentAuthorities(in: compact) {
                guard let existing = try loadAttachmentAuthority(
                    authority.version.versionID,
                    countLookup: true
                ), try authoritiesMatch(existing, authority) else {
                    throw SyncPublicationTransactionFileError.corrupt
                }
                let tombstone = try loadAttachmentTombstone(
                    authority.version.versionID,
                    countLookup: true
                )
                if compact.isDeleted(authority.version.versionID) {
                    guard let tombstone,
                          try tombstoneMatchesAuthority(tombstone, existing) else {
                        throw SyncPublicationTransactionFileError.corrupt
                    }
                } else if tombstone != nil {
                    throw SyncPublicationTransactionFileError.corrupt
                }
            }
        }
        return stored
    }

    private func loadHeadUnlocked() throws -> SyncAttachmentPublicationEvidence {
        guard try pathExists(url) else { return SyncAttachmentPublicationEvidence() }
        counters.recordHeadRead()
        do {
            return try JSONDecoder().decode(
                SyncAttachmentPublicationEvidence.self,
                from: reader.read(
                    url,
                    maximumBytes: Self.maximumEncodedBytes,
                    expected: nil
                ).data
            ).validated()
        } catch let error as SyncRegularFileReadError {
            throw mapRegularFileError(error)
        } catch let error as SyncPublicationTransactionFileError {
            throw error
        } catch {
            throw SyncPublicationTransactionFileError.corrupt
        }
    }

    private func writeHeadUnlocked(_ evidence: SyncAttachmentPublicationEvidence) throws {
        let canonical = try evidence.compactedToActiveHeads()
        let data = try deterministicEncoder().encode(canonical)
        guard data.count <= Self.maximumEncodedBytes else {
            throw SyncPublicationTransactionFileError.corrupt
        }
        try SyncDurableFile.write(
            data,
            to: url,
            beforeBoundary: beforeDurabilityBoundary
        )
        counters.recordHeadWrite()
    }

    private func attachmentAuthorities(
        in evidence: SyncAttachmentPublicationEvidence
    ) -> [SyncStoredAttachmentVersionAuthority] {
        let records = Dictionary(uniqueKeysWithValues: evidence.attachmentRecords.map {
            ($0.id.uuid, $0)
        })
        return evidence.versions.map {
            SyncStoredAttachmentVersionAuthority(
                version: $0,
                record: records[$0.versionID]
            )
        }
    }

    private func attachmentAuthorities(
        in mutations: [SyncMutation]
    ) -> [SyncStoredAttachmentVersionAuthority] {
        var byID: [UUID: SyncStoredAttachmentVersionAuthority] = [:]
        for mutation in mutations {
            guard let record = mutation.savedRecordVersion?.record,
                  let version = record.payload.attachment else { continue }
            let authority = SyncStoredAttachmentVersionAuthority(
                version: version,
                record: record
            )
            if let existing = byID[version.versionID],
               (try? authoritiesMatch(existing, authority)) != true {
                // Collective candidate validation reports the typed failure
                // before this list is persisted.
                continue
            }
            byID[version.versionID] = authority
        }
        return byID.values.sorted {
            $0.version.versionID.uuidString < $1.version.versionID.uuidString
        }
    }

    private func mergedAuthorities(
        _ lhs: [SyncStoredAttachmentVersionAuthority],
        _ rhs: [SyncStoredAttachmentVersionAuthority]
    ) throws -> [SyncStoredAttachmentVersionAuthority] {
        var byID = Dictionary(uniqueKeysWithValues: lhs.map {
            ($0.version.versionID, $0)
        })
        for authority in rhs {
            if let existing = byID[authority.version.versionID],
               try !authoritiesMatch(existing, authority) {
                throw SyncPublicationTransactionFileError.corrupt
            }
            byID[authority.version.versionID] = authority
        }
        return byID.values.sorted {
            $0.version.versionID.uuidString < $1.version.versionID.uuidString
        }
    }

    private func attachmentTombstones(
        in evidence: SyncAttachmentPublicationEvidence
    ) -> [SyncStoredAttachmentTombstoneAuthority] {
        let records = Dictionary(uniqueKeysWithValues: evidence.attachmentRecords.map {
            ($0.id.uuid, $0)
        })
        return evidence.deletedVersionIDs.map {
            SyncStoredAttachmentTombstoneAuthority(
                versionID: $0,
                record: records[$0].flatMap { $0.deletedAt.value == nil ? nil : $0 }
            )
        }.sorted { $0.versionID.uuidString < $1.versionID.uuidString }
    }

    private func attachmentTombstones(
        in mutations: [SyncMutation]
    ) -> [SyncStoredAttachmentTombstoneAuthority] {
        var byID: [UUID: SyncStoredAttachmentTombstoneAuthority] = [:]
        for mutation in mutations where mutation.recordID.kind == .attachment {
            if let record = mutation.savedRecordVersion?.record,
               let version = record.payload.attachment,
               record.deletedAt.value != nil {
                byID[version.versionID] = SyncStoredAttachmentTombstoneAuthority(
                    versionID: version.versionID,
                    record: record
                )
            } else if mutation.savedRecordVersion == nil {
                byID[mutation.recordID.uuid] = SyncStoredAttachmentTombstoneAuthority(
                    versionID: mutation.recordID.uuid,
                    record: nil
                )
            }
        }
        return byID.values.sorted { $0.versionID.uuidString < $1.versionID.uuidString }
    }

    private func mergedTombstones(
        _ lhs: [SyncStoredAttachmentTombstoneAuthority],
        _ rhs: [SyncStoredAttachmentTombstoneAuthority]
    ) throws -> [SyncStoredAttachmentTombstoneAuthority] {
        var byID = Dictionary(uniqueKeysWithValues: lhs.map { ($0.versionID, $0) })
        for tombstone in rhs {
            if let existing = byID[tombstone.versionID] {
                guard try tombstonesMatch(existing, tombstone) else {
                    throw SyncPublicationTransactionFileError.corrupt
                }
            } else {
                byID[tombstone.versionID] = tombstone
            }
        }
        return byID.values.sorted { $0.versionID.uuidString < $1.versionID.uuidString }
    }

    private func mergedProofs(
        _ lhs: [SyncProcessedWatchCommandProof],
        _ rhs: [SyncProcessedWatchCommandProof]
    ) throws -> [SyncProcessedWatchCommandProof] {
        var byID = Dictionary(uniqueKeysWithValues: lhs.map { ($0.id, $0) })
        for proof in rhs {
            if let existing = byID[proof.id], existing != proof {
                throw SyncPublicationTransactionFileError.corrupt
            }
            byID[proof.id] = proof
        }
        return byID.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func attachmentVersionIDsReferenced(
        by mutations: [SyncMutation]
    ) -> [UUID] {
        var ids: Set<UUID> = []
        for mutation in mutations where mutation.recordID.kind == .attachment {
            ids.insert(mutation.recordID.uuid)
            if let predecessor = mutation.savedRecordVersion?.record.payload.attachment?
                .replacesVersionID {
                ids.insert(predecessor)
            }
        }
        return ids.sorted { $0.uuidString < $1.uuidString }
    }

    private func watchProofs(
        in mutations: [SyncMutation]
    ) throws -> [SyncProcessedWatchCommandProof] {
        var byID: [UUID: SyncProcessedWatchCommandProof] = [:]
        for record in mutations.compactMap(\.savedRecordVersion?.record) {
            let proofs: [SyncProcessedWatchCommandProof]
            switch record.payload.atomicDomain?.value {
            case let .projectCounter(state):
                proofs = state.processedCommandProofs
            case let .orphanWatchCommandProof(orphan):
                proofs = [orphan.proof]
            case .knittingReminder, nil:
                proofs = []
            }
            for proof in proofs {
                do { _ = try proof.validated() } catch {
                    throw SyncPublicationTransactionFileError.corrupt
                }
                if let existing = byID[proof.id], existing != proof {
                    throw SyncPublicationTransactionFileError.corrupt
                }
                byID[proof.id] = proof
            }
        }
        return byID.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func preflight(
        authorities: [SyncStoredAttachmentVersionAuthority],
        tombstones: [SyncStoredAttachmentTombstoneAuthority],
        proofs: [SyncProcessedWatchCommandProof]
    ) throws {
        for authority in authorities {
            _ = try authority.validated()
            guard try deterministicEncoder().encode(authority).count
                    <= Self.maximumAuthorityBytes else {
                throw SyncPublicationTransactionFileError.corrupt
            }
            if let existing = try loadAttachmentAuthority(
                authority.version.versionID,
                countLookup: true
            ), try !authoritiesMatch(existing, authority) {
                throw SyncPublicationTransactionFileError.corrupt
            }
        }
        let authorityByID = Dictionary(uniqueKeysWithValues: authorities.map {
            ($0.version.versionID, $0)
        })
        for tombstone in tombstones {
            _ = try tombstone.validated()
            guard let authority = authorityByID[tombstone.versionID],
                  try tombstoneMatchesAuthority(tombstone, authority),
                  try deterministicEncoder().encode(tombstone).count
                    <= Self.maximumAuthorityBytes else {
                throw SyncPublicationTransactionFileError.corrupt
            }
            if let existing = try loadAttachmentTombstone(
                tombstone.versionID,
                countLookup: true
            ), try !tombstonesMatch(existing, tombstone) {
                throw SyncPublicationTransactionFileError.corrupt
            }
        }
        for proof in proofs {
            let stored = try SyncStoredWatchCommandProof(proof: proof).validated()
            guard try deterministicEncoder().encode(stored).count
                    <= Self.maximumWatchProofBytes else {
                throw SyncPublicationTransactionFileError.corrupt
            }
            if let existing = try loadWatchProof(proof.id, countLookup: true),
               existing != proof {
                throw SyncPublicationTransactionFileError.corrupt
            }
        }
    }

    private func install(_ authority: SyncStoredAttachmentVersionAuthority) throws {
        let authority = try authority.validated()
        let destination = attachmentAuthorityURL(authority.version.versionID)
        let data = try deterministicEncoder().encode(authority)
        if let existing = try loadAttachmentAuthority(
            authority.version.versionID,
            countLookup: false
        ) {
            guard try authoritiesMatch(existing, authority) else {
                throw SyncPublicationTransactionFileError.corrupt
            }
            try SyncDurableFile.synchronizeParentDirectory(
                of: destination,
                beforeBoundary: beforeDurabilityBoundary
            )
            return
        }
        try ensureImmutableDirectories(
            for: destination,
            root: attachmentAuthoritiesRootURL
        )
        let created = try SyncDurableFile.createNoClobber(
            data,
            at: destination,
            beforeBoundary: beforeDurabilityBoundary
        )
        if created {
            counters.recordAttachmentAuthorityWrite()
        } else {
            guard let existing = try loadAttachmentAuthority(
                authority.version.versionID,
                countLookup: false
            ), try authoritiesMatch(existing, authority) else {
                throw SyncPublicationTransactionFileError.corrupt
            }
        }
    }

    private func install(_ tombstone: SyncStoredAttachmentTombstoneAuthority) throws {
        let tombstone = try tombstone.validated()
        let destination = attachmentTombstoneURL(tombstone.versionID)
        let data = try deterministicEncoder().encode(tombstone)
        if let existing = try loadAttachmentTombstone(
            tombstone.versionID,
            countLookup: false
        ) {
            guard try tombstonesMatch(existing, tombstone) else {
                throw SyncPublicationTransactionFileError.corrupt
            }
            try SyncDurableFile.synchronizeParentDirectory(
                of: destination,
                beforeBoundary: beforeDurabilityBoundary
            )
            return
        }
        try ensureImmutableDirectories(
            for: destination,
            root: attachmentTombstonesRootURL
        )
        let created = try SyncDurableFile.createNoClobber(
            data,
            at: destination,
            beforeBoundary: beforeDurabilityBoundary
        )
        if created {
            counters.recordAttachmentAuthorityWrite()
        } else {
            guard let existing = try loadAttachmentTombstone(
                tombstone.versionID,
                countLookup: false
            ), try tombstonesMatch(existing, tombstone) else {
                throw SyncPublicationTransactionFileError.corrupt
            }
        }
    }

    private func install(_ proof: SyncProcessedWatchCommandProof) throws {
        let stored = try SyncStoredWatchCommandProof(proof: proof).validated()
        let destination = watchProofURL(proof.id)
        let data = try deterministicEncoder().encode(stored)
        if let existing = try loadWatchProof(proof.id, countLookup: false) {
            guard existing == proof else {
                throw SyncPublicationTransactionFileError.corrupt
            }
            try SyncDurableFile.synchronizeParentDirectory(
                of: destination,
                beforeBoundary: beforeDurabilityBoundary
            )
            return
        }
        try ensureImmutableDirectories(
            for: destination,
            root: watchProofsRootURL
        )
        let created = try SyncDurableFile.createNoClobber(
            data,
            at: destination,
            beforeBoundary: beforeDurabilityBoundary
        )
        if created {
            counters.recordWatchProofWrite()
        } else {
            guard try loadWatchProof(proof.id, countLookup: false) == proof else {
                throw SyncPublicationTransactionFileError.corrupt
            }
        }
    }

    private func loadAttachmentAuthority(
        _ versionID: UUID,
        countLookup: Bool
    ) throws -> SyncStoredAttachmentVersionAuthority? {
        if countLookup { counters.recordAttachmentAuthorityLookup() }
        let destination = attachmentAuthorityURL(versionID)
        guard try pathExists(destination) else { return nil }
        return try readAttachmentAuthority(at: destination)
    }

    private func readAttachmentAuthority(
        at authorityURL: URL
    ) throws -> SyncStoredAttachmentVersionAuthority {
        do {
            let authority = try JSONDecoder().decode(
                SyncStoredAttachmentVersionAuthority.self,
                from: reader.read(
                    authorityURL,
                    maximumBytes: Self.maximumAuthorityBytes,
                    expected: nil
                ).data
            ).validated()
            guard authorityURL.standardizedFileURL
                    == attachmentAuthorityURL(authority.version.versionID)
                        .standardizedFileURL else {
                throw SyncPublicationTransactionFileError.corrupt
            }
            return authority
        } catch let error as SyncRegularFileReadError {
            throw mapRegularFileError(error)
        } catch let error as SyncPublicationTransactionFileError {
            throw error
        } catch {
            throw SyncPublicationTransactionFileError.corrupt
        }
    }

    private func loadAttachmentTombstone(
        _ versionID: UUID,
        countLookup: Bool
    ) throws -> SyncStoredAttachmentTombstoneAuthority? {
        if countLookup { counters.recordAttachmentAuthorityLookup() }
        let destination = attachmentTombstoneURL(versionID)
        guard try pathExists(destination) else { return nil }
        return try readAttachmentTombstone(at: destination)
    }

    private func readAttachmentTombstone(
        at tombstoneURL: URL
    ) throws -> SyncStoredAttachmentTombstoneAuthority {
        do {
            let tombstone = try JSONDecoder().decode(
                SyncStoredAttachmentTombstoneAuthority.self,
                from: reader.read(
                    tombstoneURL,
                    maximumBytes: Self.maximumAuthorityBytes,
                    expected: nil
                ).data
            ).validated()
            guard tombstoneURL.standardizedFileURL
                    == attachmentTombstoneURL(tombstone.versionID).standardizedFileURL else {
                throw SyncPublicationTransactionFileError.corrupt
            }
            return tombstone
        } catch let error as SyncRegularFileReadError {
            throw mapRegularFileError(error)
        } catch let error as SyncPublicationTransactionFileError {
            throw error
        } catch {
            throw SyncPublicationTransactionFileError.corrupt
        }
    }

    private func loadWatchProof(
        _ commandID: UUID,
        countLookup: Bool
    ) throws -> SyncProcessedWatchCommandProof? {
        if countLookup { counters.recordWatchProofLookup() }
        let destination = watchProofURL(commandID)
        guard try pathExists(destination) else { return nil }
        return try readWatchProof(at: destination)
    }

    private func readWatchProof(at proofURL: URL) throws -> SyncProcessedWatchCommandProof {
        do {
            let proof = try JSONDecoder().decode(
                SyncStoredWatchCommandProof.self,
                from: reader.read(
                    proofURL,
                    maximumBytes: Self.maximumWatchProofBytes,
                    expected: nil
                ).data
            ).validated().proof
            guard proofURL.standardizedFileURL
                    == watchProofURL(proof.id).standardizedFileURL else {
                throw SyncPublicationTransactionFileError.corrupt
            }
            return proof
        } catch let error as SyncRegularFileReadError {
            throw mapRegularFileError(error)
        } catch let error as SyncPublicationTransactionFileError {
            throw error
        } catch {
            throw SyncPublicationTransactionFileError.corrupt
        }
    }

    private func authoritiesMatch(
        _ lhs: SyncStoredAttachmentVersionAuthority,
        _ rhs: SyncStoredAttachmentVersionAuthority
    ) throws -> Bool {
        guard lhs.version == rhs.version else { return false }
        switch (lhs.record, rhs.record) {
        case (nil, nil):
            return true
        case let (.some(left), .some(right)):
            return try SyncAttachmentImmutableSnapshot(record: left).sha256
                == SyncAttachmentImmutableSnapshot(record: right).sha256
        case (.none, .some), (.some, .none):
            return false
        }
    }

    private func tombstonesMatch(
        _ lhs: SyncStoredAttachmentTombstoneAuthority,
        _ rhs: SyncStoredAttachmentTombstoneAuthority
    ) throws -> Bool {
        guard lhs.versionID == rhs.versionID else { return false }
        switch (lhs.record, rhs.record) {
        case let (.some(left), .some(right)):
            return try SyncAttachmentImmutableSnapshot(record: left).sha256
                == SyncAttachmentImmutableSnapshot(record: right).sha256
        case (.none, _), (_, .none):
            return true
        }
    }

    private func tombstoneMatchesAuthority(
        _ tombstone: SyncStoredAttachmentTombstoneAuthority,
        _ authority: SyncStoredAttachmentVersionAuthority
    ) throws -> Bool {
        guard tombstone.versionID == authority.version.versionID else { return false }
        guard let tombstoneRecord = tombstone.record else { return true }
        guard let issuedRecord = authority.record else { return false }
        return try SyncAttachmentImmutableSnapshot(record: tombstoneRecord).sha256
            == SyncAttachmentImmutableSnapshot(record: issuedRecord).sha256
    }

    private func evidence(
        for authority: SyncStoredAttachmentVersionAuthority,
        tombstone: SyncStoredAttachmentTombstoneAuthority?
    ) -> SyncAttachmentPublicationEvidence {
        let record = tombstone?.record ?? authority.record
        return SyncAttachmentPublicationEvidence(
            versions: [authority.version],
            deletedVersionIDs: tombstone == nil ? [] : [authority.version.versionID],
            attachmentRecords: record.map { [$0] } ?? []
        )
    }

    private func attachmentAuthorityURL(_ versionID: UUID) -> URL {
        immutableURL(for: versionID, root: attachmentAuthoritiesRootURL)
    }

    private func attachmentTombstoneURL(_ versionID: UUID) -> URL {
        immutableURL(for: versionID, root: attachmentTombstonesRootURL)
    }

    private func watchProofURL(_ commandID: UUID) -> URL {
        immutableURL(for: commandID, root: watchProofsRootURL)
    }

    private func immutableURL(for id: UUID, root: URL) -> URL {
        let name = id.uuidString.lowercased()
        return root
            .appendingPathComponent(String(name.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(name).json", isDirectory: false)
    }

    private func immutableFileURLs(
        in root: URL,
        countingWatchProofs: Bool
    ) throws -> [URL] {
        guard try pathExists(root) else { return [] }
        if countingWatchProofs {
            counters.recordWatchProofDirectoryEnumeration()
        } else {
            counters.recordAttachmentAuthorityDirectoryEnumeration()
        }
        try validateDirectory(root)
        var files: [URL] = []
        for shard in try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard !shard.lastPathComponent.hasPrefix(".") else { continue }
            try validateDirectory(shard)
            for file in try FileManager.default.contentsOfDirectory(
                at: shard,
                includingPropertiesForKeys: nil
            ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard file.pathExtension == "json",
                      !file.lastPathComponent.hasPrefix(".") else {
                    throw SyncPublicationTransactionFileError.corrupt
                }
                files.append(file)
            }
        }
        return files
    }

    private func ensureImmutableDirectories(for destination: URL, root: URL) throws {
        try ensureDirectory(root)
        try ensureDirectory(destination.deletingLastPathComponent())
    }

    private func ensureDirectory(_ directory: URL) throws {
        var status = stat()
        let result = directory.path.withCString { Darwin.lstat($0, &status) }
        if result != 0 {
            guard errno == ENOENT else {
                throw SyncPublicationTransactionFileError.unavailable
            }
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false
                )
                try SyncDurableFile.synchronizeDirectory(
                    directory.deletingLastPathComponent()
                )
            } catch let error as SyncDurableFileError {
                throw mapDurableFileError(error)
            } catch {
                throw SyncPublicationTransactionFileError.unavailable
            }
            guard directory.path.withCString({ Darwin.lstat($0, &status) }) == 0 else {
                throw SyncPublicationTransactionFileError.unavailable
            }
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR else {
            throw SyncPublicationTransactionFileError.unsafeFile
        }
    }

    private func validateDirectory(_ directory: URL) throws {
        var status = stat()
        guard directory.path.withCString({ Darwin.lstat($0, &status) }) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR else {
            throw SyncPublicationTransactionFileError.unsafeFile
        }
    }

    private func pathExists(_ path: URL) throws -> Bool {
        var status = stat()
        let result = path.path.withCString { Darwin.lstat($0, &status) }
        if result == 0 { return true }
        guard errno == ENOENT else {
            throw SyncPublicationTransactionFileError.unavailable
        }
        return false
    }

    private func deterministicEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func mappedOperation<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as SyncPublicationTransactionFileError {
            throw error
        } catch let error as SyncDurableFileError {
            throw mapDurableFileError(error)
        } catch {
            throw error
        }
    }

    private func mapRegularFileError(
        _ error: SyncRegularFileReadError
    ) -> SyncPublicationTransactionFileError {
        switch error {
        case .unsafeFile: .unsafeFile
        case .unavailable: .unavailable
        case .tooLarge, .replaced, .changed, .expectationMismatch: .corrupt
        }
    }

    private func mapDurableFileError(
        _ error: SyncDurableFileError
    ) -> SyncPublicationTransactionFileError {
        switch error {
        case .unsafeFile: .unsafeFile
        case .corrupt: .corrupt
        case .unavailable: .unavailable
        }
    }
}

// Compatibility reference for the pre-extraction structural projector. It is
// deliberately excluded from compilation; SyncCanonicalPublicationSnapshot in
// CloudSync/SyncPublicationProjection.swift is the sole runtime authority.
#if false
private struct SyncPublicationSnapshot {
    var records: [SyncEntityID: SyncRecord] = [:]

    init(
        archive: ProjectArchive,
        deviceID: String,
        preparedWatchCommand: PreparedWatchCommand? = nil,
        processedWatchLedger: ProcessedWatchCommandLedger = .init(),
        reusing cache: SyncPublicationProjectionCache? = nil
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        func reuse(_ id: SyncEntityID, when unchanged: Bool) -> Bool {
            guard unchanged, let record = cache?.records[id] else { return false }
            records[id] = record
            return true
        }

        let previousProjects = Dictionary(uniqueKeysWithValues:
            (cache?.archive.projects ?? []).map { ($0.id, $0) })
        let previousCounters = Dictionary(uniqueKeysWithValues:
            (cache?.archive.projects ?? []).flatMap(\.counters).map { ($0.id, $0) })
        let previousNotes = Dictionary(uniqueKeysWithValues:
            (cache?.archive.projects ?? []).flatMap { project in
                project.counters.flatMap { counter in
                    counter.rowNotes.map { note in
                        (
                            deterministicSyncUUID(
                                kind: .rowNote,
                                components: [
                                    project.id.uuidString,
                                    counter.id.uuidString,
                                    String(note.row)
                                ]
                            ),
                            note
                        )
                    }
                }
            })
        let previousRemindersByCounter = Dictionary(grouping:
            (cache?.archive.projects ?? []).flatMap(\.knittingReminders),
            by: \.counterID
        )
        let previousEntries = Dictionary(uniqueKeysWithValues:
            (cache?.archive.projects ?? []).flatMap(\.journalEntries).map { ($0.id, $0) })
        let previousYarns = Dictionary(uniqueKeysWithValues:
            (cache?.archive.yarns ?? []).map { ($0.id, $0) })
        let previousLinks = Set((cache?.archive.yarns ?? []).flatMap { yarn in
            yarn.linkedProjectIDs.map { projectID in
                deterministicSyncUUID(
                    kind: .projectYarnLink,
                    components: [projectID.uuidString, yarn.id.uuidString]
                )
            }
        })
        let previousFolders = Dictionary(uniqueKeysWithValues:
            (cache?.archive.patternFolders ?? []).map { ($0.id, $0) })
        let previousPatterns = Dictionary(uniqueKeysWithValues:
            (cache?.archive.patterns ?? []).map { ($0.id, $0) })
        let previousUsages = Dictionary(uniqueKeysWithValues:
            (cache?.archive.patternUsages ?? []).map { ($0.id, $0) })

        func add<Value: Encodable>(
            _ value: Value,
            kind: SyncEntityKind,
            id: UUID,
            createdAt: Date,
            modifiedAt: Date,
            logicalRevision: UInt64? = nil,
            relationships: [SyncRelationship] = [],
            searchableName: String? = nil,
            atomicDomain: SyncAtomicDomainValue? = nil
        ) throws {
            let data = try encoder.encode(value)
            let revision = logicalRevision ?? 0
            let stamp = SyncMutationStamp(
                logicalRevision: revision,
                modifiedAt: modifiedAt,
                deviceID: deviceID
            )
            var fields: [String: SyncFieldVersion<SyncScalar>] = atomicDomain == nil
                ? ["domainSnapshot": .init(value: .data(data), stamp: stamp)]
                : [:]
            if let searchableName {
                fields["name"] = .init(value: .string(searchableName), stamp: stamp)
            }
            let recordID = SyncEntityID(kind: kind, uuid: id)
            records[recordID] = SyncRecord(
                schemaVersion: 1,
                id: recordID,
                createdAt: createdAt,
                entityRevision: revision,
                payload: SyncRecordPayload(
                    fields: fields,
                    atomicDomain: atomicDomain.map {
                        .init(value: $0, stamp: stamp)
                    }
                ),
                relationships: relationships,
                deletedAt: .init(value: nil, stamp: stamp)
            )
        }

        for project in archive.projects {
            let projectID = SyncEntityID(kind: .project, uuid: project.id)
            let remindersByCounter = Dictionary(
                grouping: project.knittingReminders,
                by: \.counterID
            )
            if !reuse(
                projectID,
                when: previousProjects[project.id].map(SyncProjectProjection.init)
                    == SyncProjectProjection(project)
            ) {
            try add(
                SyncProjectProjection(project),
                kind: .project,
                id: project.id,
                createdAt: project.createdAt,
                modifiedAt: project.updatedAt,
                searchableName: project.name
            )
            }
            for counter in project.counters {
                let reminders = remindersByCounter[counter.id] ?? []
                let counterID = SyncEntityID(kind: .projectCounter, uuid: counter.id)
                let prepared = preparedWatchCommand.flatMap {
                    $0.command.counterID == counter.id ? $0 : nil
                }
                let processedIDs = Set(processedWatchLedger.entries.compactMap { entry in
                    entry.preparedCommand?.command.counterID == counter.id ? entry.id : nil
                })
                let cachedState: SyncCounterReminderState?
                if case let .projectCounter(state)? =
                    cache?.records[counterID]?.payload.atomicDomain?.value {
                    cachedState = state
                } else {
                    cachedState = nil
                }
                if !reuse(
                    counterID,
                    when: previousCounters[counter.id] == counter
                        && previousRemindersByCounter[counter.id] == reminders
                        && cachedState?.preparedCommand == prepared
                        && cachedState?.processedCommandIDs == processedIDs
                ) {
                    let aggregateRevision = max(
                        counter.mutationRevision,
                        reminders.map(\.mutationRevision).max() ?? 0
                    )
                    try add(
                        counter,
                        kind: .projectCounter,
                        id: counter.id,
                        createdAt: project.createdAt,
                        modifiedAt: Date(
                            timeIntervalSinceReferenceDate: TimeInterval(aggregateRevision)
                        ),
                        logicalRevision: aggregateRevision,
                        relationships: [.init(
                            role: "project",
                            target: .init(kind: .project, uuid: project.id)
                        )],
                        atomicDomain: .projectCounter(SyncCounterReminderState(
                            counter: counter,
                            reminders: reminders,
                            preparedCommand: prepared,
                            processedCommandIDs: processedIDs,
                            occurrence: prepared.flatMap { command in
                                reminders.first { $0.id == command.expectedReminderID }?
                                    .progress.nextOccurrenceIndex
                            }
                        ))
                    )
                }
                for note in counter.rowNotes {
                    let noteID = deterministicSyncUUID(
                        kind: .rowNote,
                        components: [project.id.uuidString, counter.id.uuidString, String(note.row)]
                    )
                    if reuse(
                        .init(kind: .rowNote, uuid: noteID),
                        when: previousNotes[noteID] == note
                    ) { continue }
                    try add(
                        note,
                        kind: .rowNote,
                        id: noteID,
                        createdAt: note.createdAt,
                        modifiedAt: note.updatedAt,
                        relationships: [.init(
                            role: "project",
                            target: .init(kind: .project, uuid: project.id)
                        )]
                    )
                }
            }
            for entry in project.journalEntries {
                if reuse(
                    .init(kind: .journalEntry, uuid: entry.id),
                    when: previousEntries[entry.id] == entry
                ) { continue }
                try add(
                    entry,
                    kind: .journalEntry,
                    id: entry.id,
                    createdAt: entry.createdAt,
                    modifiedAt: project.updatedAt,
                    relationships: [.init(
                        role: "project",
                        target: .init(kind: .project, uuid: project.id)
                    )]
                )
            }
        }

        for yarn in archive.yarns {
            if !reuse(
                .init(kind: .yarn, uuid: yarn.id),
                when: previousYarns[yarn.id].map(SyncYarnProjection.init)
                    == SyncYarnProjection(yarn)
            ) {
            try add(
                SyncYarnProjection(yarn),
                kind: .yarn,
                id: yarn.id,
                createdAt: yarn.createdAt,
                modifiedAt: yarn.updatedAt,
                searchableName: yarn.name
            )
            }
            for projectID in yarn.linkedProjectIDs {
                let link = SyncProjectYarnLinkProjection(
                    projectID: projectID,
                    yarnID: yarn.id
                )
                let linkID = deterministicSyncUUID(
                    kind: .projectYarnLink,
                    components: [projectID.uuidString, yarn.id.uuidString]
                )
                if reuse(
                    .init(kind: .projectYarnLink, uuid: linkID),
                    when: previousLinks.contains(linkID)
                ) { continue }
                try add(
                    link,
                    kind: .projectYarnLink,
                    id: linkID,
                    createdAt: yarn.createdAt,
                    modifiedAt: yarn.updatedAt,
                    relationships: [
                        .init(role: "project", target: .init(kind: .project, uuid: projectID)),
                        .init(role: "yarn", target: .init(kind: .yarn, uuid: yarn.id))
                    ]
                )
            }
        }

        for folder in archive.patternFolders {
            if reuse(
                .init(kind: .patternFolder, uuid: folder.id),
                when: previousFolders[folder.id] == folder
            ) { continue }
            try add(
                folder,
                kind: .patternFolder,
                id: folder.id,
                createdAt: folder.createdAt,
                modifiedAt: folder.createdAt,
                searchableName: folder.displayName
            )
        }
        for pattern in archive.patterns {
            if reuse(
                .init(kind: .pattern, uuid: pattern.id),
                when: previousPatterns[pattern.id] == pattern
            ) { continue }
            try add(
                pattern,
                kind: .pattern,
                id: pattern.id,
                createdAt: pattern.createdAt,
                modifiedAt: pattern.lastOpenedAt ?? pattern.createdAt,
                searchableName: pattern.displayName
            )
        }
        for usage in archive.patternUsages {
            if reuse(
                .init(kind: .patternUsage, uuid: usage.id),
                when: previousUsages[usage.id] == usage
            ) { continue }
            try add(
                usage,
                kind: .patternUsage,
                id: usage.id,
                createdAt: usage.linkedAt,
                modifiedAt: usage.unlinkedAt ?? usage.linkedAt,
                relationships: [
                    .init(role: "project", target: .init(kind: .project, uuid: usage.projectID)),
                    .init(role: "pattern", target: .init(kind: .pattern, uuid: usage.patternID))
                ]
            )
        }
    }
}

private struct SyncProjectProjection: Encodable, Equatable {
    let id: UUID
    let name: String
    let createdAt: Date
    let selectedCounterID: UUID
    let photoFilename: String?
    let completedAt: Date?
    let toolType: ProjectToolType?
    let toolSize: String?
    let toolNotes: String?
    let legacyPatterns: [PatternDocument]

    init(_ project: StoredProject) {
        id = project.id
        name = project.name
        createdAt = project.createdAt
        selectedCounterID = project.selectedCounterID
        photoFilename = project.photoFilename
        completedAt = project.completedAt
        toolType = project.toolType
        toolSize = project.toolSize
        toolNotes = project.toolNotes
        legacyPatterns = project.patterns
    }
}

private struct SyncYarnProjection: Encodable, Equatable {
    let id: UUID
    let name: String
    let photoFilename: String?
    let brand: String?
    let series: String?
    let color: String?
    let colorCode: String?
    let dyeLot: String?
    let ballWeightGrams: Decimal?
    let lengthMeters: Decimal?
    let fiberContent: String?
    let recommendedNeedleMM: YarnMetricRange?
    let recommendedHookMM: YarnMetricRange?
    let labelPhotoFilenames: [String]
    let labelPhotoSlotIDs: [UUID]
    let remainingBalls: Decimal?
    let remainingGrams: Decimal?
    let storageLocation: String?
    let notes: String?
    let createdAt: Date

    init(_ yarn: StoredYarn) {
        id = yarn.id
        name = yarn.name
        photoFilename = yarn.photoFilename
        brand = yarn.brand
        series = yarn.series
        color = yarn.color
        colorCode = yarn.colorCode
        dyeLot = yarn.dyeLot
        ballWeightGrams = yarn.ballWeightGrams
        lengthMeters = yarn.lengthMeters
        fiberContent = yarn.fiberContent
        recommendedNeedleMM = yarn.recommendedNeedleMM
        recommendedHookMM = yarn.recommendedHookMM
        labelPhotoFilenames = yarn.labelPhotoFilenames
        labelPhotoSlotIDs = yarn.labelPhotoSlotIDs
        remainingBalls = yarn.remainingBalls
        remainingGrams = yarn.remainingGrams
        storageLocation = yarn.storageLocation
        notes = yarn.notes
        createdAt = yarn.createdAt
    }
}

private struct SyncProjectYarnLinkProjection: Encodable {
    let projectID: UUID
    let yarnID: UUID
}

private func syncEntityIDIsOrderedBefore(_ lhs: SyncEntityID, _ rhs: SyncEntityID) -> Bool {
    (lhs.kind.rawValue, lhs.uuid.uuidString) < (rhs.kind.rawValue, rhs.uuid.uuidString)
}

private func deterministicSyncUUID(
    kind: SyncEntityKind,
    components: [String]
) -> UUID {
    var bytes = Array(SHA256.hash(
        data: Data(([kind.rawValue] + components).joined(separator: "\u{1F}").utf8)
    ).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}
#endif

// Artifact-only markup commits do not pass through an archive projection. This
// is their single compatibility boundary; all archive-backed attachments use
// SyncPublicationProjector and its incremental manifest authority above.
private func syncAttachmentMutation(
    owner: SyncEntityID,
    role: String,
    slotID: String,
    originalData: Data?,
    committedData: Data?,
    replacesVersion: SyncAttachmentVersion?,
    replacesRecord: SyncRecord?,
    sourceURL: URL,
    mediaType: String,
    displayFilename: String,
    deviceID: String
) throws -> SyncMutation? {
    guard originalData != committedData else { return nil }
    let slot = SyncAttachmentSlot(owner: owner, role: role, slotID: slotID)

    guard let committedData else {
        guard let replacesVersion else { return nil }
        guard var record = replacesRecord,
              record.payload.attachment == replacesVersion else {
            throw SyncPublicationTransactionFileError.corrupt
        }
        let modifiedAt = Date.now
        record.deletedAt = .init(
            value: modifiedAt,
            stamp: .init(
                logicalRevision: record.deletedAt.stamp.logicalRevision,
                modifiedAt: modifiedAt,
                deviceID: deviceID
            )
        )
        return try .save(
            recordVersion: SyncRecordVersion(record: record),
            mutationID: UUID()
        )
    }

    let contentSHA256 = Data(SHA256.hash(data: committedData))
    let attachment = try SyncAttachmentVersion.issuing(
        slot: slot,
        contentSHA256: contentSHA256,
        byteCount: Int64(committedData.count),
        mediaType: mediaType,
        displayFilename: displayFilename,
        replacesVersionID: replacesVersion?.versionID
    )
    let revision: UInt64 = 0
    let modifiedAt = Date.now
    let stamp = SyncMutationStamp(
        logicalRevision: revision,
        modifiedAt: modifiedAt,
        deviceID: deviceID
    )
    let record = SyncRecord(
        schemaVersion: 1,
        id: SyncEntityID(kind: .attachment, uuid: attachment.versionID),
        createdAt: modifiedAt,
        entityRevision: revision,
        payload: SyncRecordPayload(fields: [
            "role": .init(value: .string(role), stamp: stamp),
            "slotID": .init(value: .string(slotID), stamp: stamp),
            "contentSHA256": .init(value: .data(contentSHA256), stamp: stamp),
            "byteCount": .init(value: .integer(Int64(committedData.count)), stamp: stamp),
            "mediaType": .init(value: .string(mediaType), stamp: stamp),
            "displayFilename": .init(value: .string(displayFilename), stamp: stamp)
        ], attachment: attachment),
        relationships: [.init(role: "owner", target: owner)],
        deletedAt: .init(value: nil, stamp: stamp)
    )
    return try .save(
        recordVersion: SyncRecordVersion(record: record),
        attachmentSource: SyncAttachmentSource(
            fileURL: sourceURL,
            contentSHA256: contentSHA256,
            byteCount: Int64(committedData.count)
        ),
        mutationID: UUID()
    )
}

// Disabled compatibility reference for the former full-content attachment
// projector. The manifest-backed projector is the only runtime implementation.
#if false
private struct SyncAttachmentProjection: Equatable {
    let slot: SyncAttachmentSlot
    let sourceURL: URL
    let contentSHA256: Data
    let byteCount: Int64
    let mediaType: String
    let displayFilename: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.slot == rhs.slot
            && lhs.contentSHA256 == rhs.contentSHA256
            && lhs.byteCount == rhs.byteCount
            && lhs.mediaType == rhs.mediaType
    }

}

private struct SyncRegularFileMetadata {
    let contentSHA256: Data
    let byteCount: Int64
}

private func syncRegularFileMetadata(at url: URL) throws -> SyncRegularFileMetadata {
    do {
        let read = try SyncRegularFileReader().read(
            url,
            maximumBytes: 100_000_000
        )
        return SyncRegularFileMetadata(
            contentSHA256: read.sha256,
            byteCount: read.byteCount
        )
    } catch let error as SyncRegularFileReadError {
        switch error {
        case .unsafeFile:
            throw SyncPublicationTransactionFileError.unsafeFile
        case .unavailable:
            throw SyncPublicationTransactionFileError.unavailable
        case .tooLarge, .replaced, .changed, .expectationMismatch:
            throw SyncPublicationTransactionFileError.corrupt
        }
    }
}
#endif

func syncMediaType(for filename: String, fallback: String) -> String {
    switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
    case "jpg", "jpeg": "image/jpeg"
    case "png": "image/png"
    case "heic": "image/heic"
    case "pdf": "application/pdf"
    case "json": "application/json"
    default: fallback
    }
}

public enum ProjectPhotoChange: Sendable {
    case unchanged
    case replace(Data)
    case remove
}

public enum YarnLabelPhotoChange: Sendable {
    case unchanged
    case replace(first: Data?, second: Data?)
    case retainExisting([String])
    case removeAll
}

public extension Notification.Name {
    static let yarnLabelPhotosDidChange = Notification.Name("yarnLabelPhotosDidChange")
}

public enum ProjectStoreError: Error, Equatable, Sendable {
    case unreadableArchive
    case archiveUnavailable
    case invalidYarnProjectLinks
    case patternNotFound
    case staleDataGeneration
    case persistenceFailed
    case accessRestricted
}

public enum ProjectYarnLinkError: Error, Equatable, Sendable {
    case projectNotFound
    case yarnNotFound
    case projectCompleted
}

public enum ProjectDeletionError: Error, Equatable, Sendable {
    case projectCompleted
}

public typealias MutationAuthorizer = @MainActor (FeatureMutation) -> FeatureAccessDecision
public typealias MutationSuccessCommitter = @MainActor (FeatureMutation) -> FeatureAccessDecision

public enum PatternLibraryMutationError: Error, Equatable, Sendable {
    case patternNotFound
    case projectNotFound
    case usageNotFound
    case usageInactive
    case projectCompleted
    case activeLinksExist([UUID])
}

public enum PatternFolderStoreError: Error, Equatable, Sendable {
    case folderNotFound
    case patternNotFound
}

public enum YouTubePatternStoreError: Error, Equatable, Sendable {
    case emptyTitle
}

public struct YouTubePatternAddResult: Equatable, Sendable {
    public enum Resolution: Equatable, Sendable {
        case created
        case existing
    }

    public let resolution: Resolution
    public let patternID: UUID

    public init(resolution: Resolution, patternID: UUID) {
        self.resolution = resolution
        self.patternID = patternID
    }

    public var createdPatternID: UUID? {
        resolution == .created ? patternID : nil
    }

    public var resolvedPatternID: UUID { patternID }
}

/// Counter changes issued from a pattern reader are tied to one active usage,
/// rather than merely to the containing project.
public enum PatternReaderCounterMutation: Sendable {
    case increment
    case reset
    case update(name: String?, value: Int)
    case manage(name: String?, value: Int, reminder: CounterReminderEdit)
    case completeReminder(reminderID: UUID, observedCount: Int)
    case stopReminder(reminderID: UUID)
}

public struct PatternReaderCounterMutationResult: Equatable, Sendable {
    public let generation: UInt64
    public let outcome: CounterMutationOutcome?
}

enum ProjectJournalPhotoReferencePolicy {
    static func unreferencedFilenames(
        requestedFilenames: Set<String>,
        remainingProjects: [StoredProject]
    ) -> Set<String> {
        let referencedFilenames = Set(
            remainingProjects.flatMap(\.journalEntries).flatMap {
                [$0.photoFilename, $0.thumbnailFilename]
            }
        )
        return Set(requestedFilenames.filter(ProjectJournalPhotoFilename.isManaged))
            .subtracting(referencedFilenames)
    }
}

enum PatternLibraryDeletionError: Error, Equatable, Sendable {
    case invalidJournal
    case unsafeTransactionRoot
    case conflictingFiles
}

enum PatternLibraryDeletionPhase: String, Codable, Sendable {
    case staged
    case published
    case committed
}

struct PatternLibraryDeletionItem: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case usageMarkup
        case asset
    }

    let kind: Kind
    let usageID: UUID?
    let asset: PatternAsset?
    let canonicalRelativePath: String
    let stagedFilename: String

    static func usageMarkup(_ usageID: UUID) -> PatternLibraryDeletionItem {
        .init(
            kind: .usageMarkup,
            usageID: usageID,
            asset: nil,
            canonicalRelativePath: "UsageMarkup/\(usageID.uuidString)",
            stagedFilename: "usage-\(usageID.uuidString)"
        )
    }

    static func asset(_ asset: PatternAsset) -> PatternLibraryDeletionItem {
        .init(
            kind: .asset,
            usageID: nil,
            asset: asset,
            canonicalRelativePath: "Assets/\(asset.storedFilename)",
            stagedFilename: "asset-\(asset.id.uuidString)"
        )
    }

    var isValid: Bool {
        switch kind {
        case .usageMarkup:
            guard let usageID, asset == nil else { return false }
            return canonicalRelativePath == "UsageMarkup/\(usageID.uuidString)"
                && stagedFilename == "usage-\(usageID.uuidString)"
        case .asset:
            guard let asset, usageID == nil else { return false }
            return canonicalRelativePath == "Assets/\(asset.storedFilename)"
                && stagedFilename == "asset-\(asset.id.uuidString)"
        }
    }
}

struct PatternLibraryDeletionJournal: Codable, Sendable {
    private struct Payload: Codable {
        let version: Int
        let transactionID: UUID
        let phase: PatternLibraryDeletionPhase
        let items: [PatternLibraryDeletionItem]
    }

    let version: Int
    let transactionID: UUID
    let phase: PatternLibraryDeletionPhase
    let items: [PatternLibraryDeletionItem]
    let integrity: String

    init(
        transactionID: UUID,
        phase: PatternLibraryDeletionPhase,
        items: [PatternLibraryDeletionItem]
    ) throws {
        version = 1
        self.transactionID = transactionID
        self.phase = phase
        self.items = items
        integrity = try Self.integrity(
            for: .init(version: version, transactionID: transactionID, phase: phase, items: items)
        )
    }

    func isValid() throws -> Bool {
        guard version == 1, hasValidStructure else { return false }
        let expectedIntegrity = try Self.integrity(
            for: .init(version: version, transactionID: transactionID, phase: phase, items: items)
        )
        return integrity == expectedIntegrity
    }

    var hasValidStructure: Bool {
        !items.isEmpty
            && Set(items.map(\.stagedFilename)).count == items.count
            && items.allSatisfy(\.isValid)
    }

    func withPhase(_ phase: PatternLibraryDeletionPhase) throws -> PatternLibraryDeletionJournal {
        try .init(transactionID: transactionID, phase: phase, items: items)
    }

    private static func integrity(for payload: Payload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

final class PatternLibraryDeletionTransaction {
    private let markupService: PatternMarkupFileService
    private let fileService: PatternFileService
    private let transactionsRoot: URL
    private let isNoOp: Bool
    private var journal: PatternLibraryDeletionJournal
    private let transactionRoot: URL

    private init(
        root: URL,
        markupService: PatternMarkupFileService,
        fileService: PatternFileService,
        journal: PatternLibraryDeletionJournal,
        isNoOp: Bool = false
    ) throws {
        self.markupService = markupService
        self.fileService = fileService
        self.isNoOp = isNoOp
        transactionsRoot = try Self.validatedTransactionsRoot(root)
        self.journal = journal
        transactionRoot = transactionsRoot
            .appendingPathComponent(journal.transactionID.uuidString, isDirectory: true)
    }

    static func begin(
        root: URL,
        markupService: PatternMarkupFileService,
        usageIDs: [UUID],
        asset: PatternAsset?,
        fileService: PatternFileService
    ) throws -> PatternLibraryDeletionTransaction {
        let items = usageIDs.map(PatternLibraryDeletionItem.usageMarkup)
            + (asset.map { [PatternLibraryDeletionItem.asset($0)] } ?? [])
        return try .init(
            root: root,
            markupService: markupService,
            fileService: fileService,
            journal: try .init(transactionID: UUID(), phase: .staged, items: items),
            isNoOp: items.isEmpty
        )
    }

    func stage() throws {
        guard !isNoOp else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: transactionsRoot, withIntermediateDirectories: true)
        try writeJournal()
        do {
            try manager.createDirectory(at: transactionRoot, withIntermediateDirectories: true)
            for item in journal.items {
                try moveIfPresent(item)
            }
        } catch {
            try rollback()
            throw error
        }
    }

    func publish() throws {
        guard !isNoOp else { return }
        journal = try journal.withPhase(.published)
        try writeJournal()
    }

    func rollback() throws {
        guard !isNoOp else { return }
        let manager = FileManager.default
        for item in journal.items.reversed() {
            let source = try canonicalURL(for: item)
            let staged = stagedURL(for: item)
            guard manager.fileExists(atPath: staged.path) else { continue }
            guard !manager.fileExists(atPath: source.path) else {
                throw PatternLibraryDeletionError.conflictingFiles
            }
            try manager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: staged, to: source)
        }
        if manager.fileExists(atPath: transactionRoot.path) {
            try manager.removeItem(at: transactionRoot)
        }
        try removeJournalAndEmptyRoot()
    }

    func commit() throws {
        guard !isNoOp else { return }
        let manager = FileManager.default
        if manager.fileExists(atPath: transactionRoot.path) {
            try manager.removeItem(at: transactionRoot)
        }
        journal = try journal.withPhase(.committed)
        try writeJournal()
        try removeJournalAndEmptyRoot()
    }

    static func recover(
        root: URL,
        markupService: PatternMarkupFileService,
        fileService: PatternFileService,
        archive: ProjectArchive
    ) throws {
        let transactionsRoot = try validatedTransactionsRoot(root)
        let manager = FileManager.default
        guard manager.fileExists(atPath: transactionsRoot.path) else { return }
        let entries = try manager.contentsOfDirectory(
            at: transactionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        let journalURLs = try entries.compactMap { url -> URL? in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw PatternLibraryDeletionError.invalidJournal
            }
            if values.isDirectory == true {
                guard UUID(uuidString: url.lastPathComponent) != nil else {
                    throw PatternLibraryDeletionError.invalidJournal
                }
                return nil
            }
            guard url.pathExtension == "json",
                  UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                  values.isRegularFile == true else {
                throw PatternLibraryDeletionError.invalidJournal
            }
            return url
        }
        for url in journalURLs {
            let journal: PatternLibraryDeletionJournal
            do {
                journal = try JSONDecoder().decode(PatternLibraryDeletionJournal.self, from: Data(contentsOf: url))
            } catch {
                throw PatternLibraryDeletionError.invalidJournal
            }
            guard try journal.isValid(),
                  journal.transactionID.uuidString == url.deletingPathExtension().lastPathComponent else {
                throw PatternLibraryDeletionError.invalidJournal
            }
            let transaction = try PatternLibraryDeletionTransaction(
                root: root,
                markupService: markupService,
                fileService: fileService,
                journal: journal
            )
            let archiveStillReferencesAnItem = journal.items.contains { item in
                switch item.kind {
                case .usageMarkup:
                    return item.usageID.map { usageID in archive.patternUsages.contains { $0.id == usageID } } ?? false
                case .asset:
                    return item.asset.map { asset in archive.patternAssets.contains { $0.id == asset.id } } ?? false
                }
            }
            if archiveStillReferencesAnItem {
                try transaction.rollback()
            } else {
                try transaction.commit()
            }
        }
        if manager.fileExists(atPath: transactionsRoot.path) {
            let remaining = try manager.contentsOfDirectory(atPath: transactionsRoot.path)
            guard remaining.isEmpty else { throw PatternLibraryDeletionError.invalidJournal }
            try manager.removeItem(at: transactionsRoot)
        }
    }

    private func moveIfPresent(_ item: PatternLibraryDeletionItem) throws {
        let manager = FileManager.default
        let source = try canonicalURL(for: item)
        guard manager.fileExists(atPath: source.path) else { return }
        try manager.moveItem(at: source, to: stagedURL(for: item))
    }

    private func canonicalURL(for item: PatternLibraryDeletionItem) throws -> URL {
        switch item.kind {
        case .usageMarkup:
            guard let usageID = item.usageID else { throw PatternLibraryDeletionError.invalidJournal }
            return try markupService.usageMarkupDirectory(usageID: usageID)
        case .asset:
            guard let asset = item.asset else { throw PatternLibraryDeletionError.invalidJournal }
            return try fileService.assetURL(asset)
        }
    }

    private func stagedURL(for item: PatternLibraryDeletionItem) -> URL {
        transactionRoot.appendingPathComponent(item.stagedFilename, isDirectory: item.kind == .usageMarkup)
    }

    private func writeJournal() throws {
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
    }

    private var journalURL: URL {
        transactionsRoot.appendingPathComponent("\(journal.transactionID.uuidString).json")
    }

    private func removeJournalAndEmptyRoot() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: journalURL.path) {
            try manager.removeItem(at: journalURL)
        }
        if manager.fileExists(atPath: transactionsRoot.path),
           try manager.contentsOfDirectory(atPath: transactionsRoot.path).isEmpty {
            try manager.removeItem(at: transactionsRoot)
        }
    }

    private static func validatedTransactionsRoot(_ root: URL) throws -> URL {
        let canonicalRoot = root.standardizedFileURL
        guard canonicalRoot.resolvingSymlinksInPath().path == canonicalRoot.path else {
            throw PatternLibraryDeletionError.unsafeTransactionRoot
        }
        let transactionsRoot = canonicalRoot
            .appendingPathComponent(".DeletionTransactions", isDirectory: true)
            .standardizedFileURL
        guard transactionsRoot.deletingLastPathComponent().path == canonicalRoot.path,
              transactionsRoot.resolvingSymlinksInPath().path == transactionsRoot.path else {
            throw PatternLibraryDeletionError.unsafeTransactionRoot
        }
        return transactionsRoot
    }

}

@MainActor public final class JSONProjectStore: ObservableObject {
    @Published public private(set) var projects: [StoredProject] = []
    @Published public private(set) var yarns: [StoredYarn] = []
    @Published public private(set) var patternFolders: [PatternFolder] = []
    @Published public private(set) var patternAssets: [PatternAsset] = []
    @Published public private(set) var patterns: [StoredPattern] = []
    @Published public private(set) var patternUsages: [PatternProjectUsage] = []
    @Published public private(set) var loadError: ProjectStoreError?
    @Published public private(set) var isDataOperationInProgress = false
    @Published public private(set) var dataGeneration: UInt64 = 0
    @Published public private(set) var projectCoverGeneration: UInt64 = 0
    @Published public private(set) var syncPublicationError: SyncPublicationError?
    private var url: URL
    private let photoService: ProjectPhotoFileService
    private let yarnPhotoService: YarnPhotoFileService
    private let yarnLabelPhotoService: YarnLabelPhotoFileService
    private let journalPhotoService: ProjectJournalPhotoFileService
    private var patternFileService: PatternFileService?
    private var patternInboxFileService: PatternInboxFileService?
    private var patternPublicationReceiptService: PatternInboxPublicationReceiptService?
    private let patternMarkupFileService: PatternMarkupFileService
    private let patternThumbnailService: PatternThumbnailFileService
    private let afterYouTubeThumbnailStage: @Sendable () async -> Void
    private let patternPDFPageThumbnailURLGenerator: @Sendable (PatternAsset, URL, Int) -> URL?
    private let backupService: KnitNoteBackupService
    private let archiveWrite: @Sendable (Data, URL) throws -> Void
    private let syncMutationSink: any SyncMutationSink
    private var remoteDomainCommitted: ((UUID) -> Void)?
    private let isSyncPublicationEnabled: Bool
    private let syncInstallationID: String?
    private let syncRevisionLedger: SyncRevisionLedger?
    private let syncAttachmentPublicationEvidenceFile: SyncAttachmentPublicationEvidenceFile
    private var syncAttachmentPublicationEvidence: SyncAttachmentPublicationEvidence
    private let syncAttachmentPublicationEvidenceLoadFailed: Bool
    private let syncAttachmentManifestStore: SyncAttachmentManifestStore
    private var syncAttachmentManifest: [String: SyncAttachmentManifestEntry]
    private let syncAttachmentManifestLoadFailed: Bool
    private var syncProjectionCache: SyncPublicationProjectionCache?
    private var syncBootstrapHydrated = false
    private var syncCanonicalCheckpointStore: SyncCanonicalCheckpointStore?
    private var syncCanonicalCheckpoint: SyncCanonicalCheckpoint?
    private var syncCanonicalActivationRequired = false
    private let syncRemoteInstallBeforeDurabilityBoundary: (
        SyncDurableFileWriteBoundary
    ) throws -> Void
    private let syncCanonicalPublicationBoundary: (SyncCanonicalPublicationBoundary) throws -> Void
    private var syncHydratedAttachments: [UUID: SyncRecord] = [:]
    private var syncHydratedAttachmentSources: [UUID: SyncAttachmentSource] = [:]
    private var activePreparedWatchCommand: PreparedWatchCommand?
    private var activeProcessedWatchLedger = ProcessedWatchCommandLedger()
    private let patternStorageLocationsProvider: (() throws -> PatternStorageLocations)?
    private var activeJournalPhotoTransactions = 0
    private var activePatternTransactions = 0
    private let authorizeMutation: MutationAuthorizer
    private let commitSuccessfulMutation: MutationSuccessCommitter
    public private(set) var isSessionWriteRevoked = false
    private var patternFolderNameContext: PatternFolderNameContext?
    private var didDeferLoadForSyncPublication = false

    public func revokeSessionWrites() {
        isSessionWriteRevoked = true
    }

    private func requireSessionWriteAccess() throws {
        guard !isSessionWriteRevoked else {
            throw StoreSessionAccessError.revoked
        }
    }

    public convenience init(
        url: URL,
        photoService: ProjectPhotoFileService? = nil,
        yarnPhotoService: YarnPhotoFileService? = nil,
        yarnLabelPhotoService: YarnLabelPhotoFileService? = nil,
        journalPhotoService: ProjectJournalPhotoFileService? = nil,
        patternFileService: PatternFileService? = nil,
        patternInboxFileService: PatternInboxFileService? = nil,
        patternPublicationReceiptService: PatternInboxPublicationReceiptService? = nil,
        patternMarkupFileService: PatternMarkupFileService? = nil,
        patternThumbnailService: PatternThumbnailFileService? = nil,
        patternFolderNameContext: PatternFolderNameContext? = nil,
        syncMutationSink: any SyncMutationSink = DisabledSyncMutationSink(),
        authorizeMutation: @escaping MutationAuthorizer = { _ in .allow },
        commitSuccessfulMutation: @escaping MutationSuccessCommitter = { _ in .allow }
    ) {
        let liveRoot = url.deletingLastPathComponent()
        let workRoot = liveRoot.deletingLastPathComponent().appendingPathComponent(
            ".KnitNote-BackupWork",
            isDirectory: true
        )
        self.init(
            url: url,
            photoService: photoService,
            yarnPhotoService: yarnPhotoService,
            yarnLabelPhotoService: yarnLabelPhotoService,
            journalPhotoService: journalPhotoService,
            patternFileService: patternFileService,
            patternInboxFileService: patternInboxFileService,
            patternPublicationReceiptService: patternPublicationReceiptService,
            patternMarkupFileService: patternMarkupFileService,
            patternThumbnailService: patternThumbnailService,
            patternFolderNameContext: patternFolderNameContext,
            backupService: KnitNoteBackupService(
                liveRoot: liveRoot,
                workRoot: workRoot,
                patternFolderNameContext: patternFolderNameContext
            ),
            syncMutationSink: syncMutationSink,
            authorizeMutation: authorizeMutation,
            commitSuccessfulMutation: commitSuccessfulMutation
        )
    }

    init(
        url: URL,
        photoService: ProjectPhotoFileService? = nil,
        yarnPhotoService: YarnPhotoFileService? = nil,
        yarnLabelPhotoService: YarnLabelPhotoFileService? = nil,
        journalPhotoService: ProjectJournalPhotoFileService? = nil,
        patternFileService: PatternFileService? = nil,
        patternInboxFileService: PatternInboxFileService? = nil,
        patternPublicationReceiptService: PatternInboxPublicationReceiptService? = nil,
        patternMarkupFileService: PatternMarkupFileService? = nil,
        patternThumbnailService: PatternThumbnailFileService? = nil,
        patternFolderNameContext: PatternFolderNameContext? = nil,
        patternPDFPageThumbnailURLGenerator: (@Sendable (PatternAsset, URL, Int) -> URL?)? = nil,
        afterYouTubeThumbnailStage: @escaping @Sendable () async -> Void = {},
        backupService: KnitNoteBackupService,
        initialLoadError: ProjectStoreError? = nil,
        patternStorageLocationsProvider: (() throws -> PatternStorageLocations)? = nil,
        archiveWrite: @escaping @Sendable (Data, URL) throws -> Void = {
            try $0.write(to: $1, options: .atomic)
        },
        syncAttachmentEvidenceBeforeDurabilityBoundary: @escaping (
            SyncDurableFileWriteBoundary
        ) throws -> Void = { _ in },
        syncRemoteInstallBeforeDurabilityBoundary: @escaping (
            SyncDurableFileWriteBoundary
        ) throws -> Void = { _ in },
        syncCanonicalPublicationBoundary: @escaping (SyncCanonicalPublicationBoundary) throws -> Void = { _ in },
        syncMutationSink: any SyncMutationSink = DisabledSyncMutationSink(),
        authorizeMutation: @escaping MutationAuthorizer = { _ in .allow },
        commitSuccessfulMutation: @escaping MutationSuccessCommitter = { _ in .allow }
    ) {
        self.url = url
        self.syncRemoteInstallBeforeDurabilityBoundary = syncRemoteInstallBeforeDurabilityBoundary
        self.syncCanonicalPublicationBoundary = syncCanonicalPublicationBoundary
        self.photoService = photoService ?? ProjectPhotoFileService(
            directory: url.deletingLastPathComponent().appendingPathComponent("ProjectPhotos", isDirectory: true)
        )
        self.yarnPhotoService = yarnPhotoService ?? YarnPhotoFileService(
            directory: url.deletingLastPathComponent().appendingPathComponent("YarnPhotos", isDirectory: true)
        )
        self.yarnLabelPhotoService = yarnLabelPhotoService ?? YarnLabelPhotoFileService(
            directory: url.deletingLastPathComponent().appendingPathComponent(
                "YarnLabelPhotos",
                isDirectory: true
            )
        )
        self.journalPhotoService = journalPhotoService ?? ProjectJournalPhotoFileService(
            directory: url.deletingLastPathComponent().appendingPathComponent("ProjectJournalPhotos", isDirectory: true)
        )
        self.patternStorageLocationsProvider = patternStorageLocationsProvider
        let fallbackPatternRoot = url.deletingLastPathComponent().appendingPathComponent("Patterns", isDirectory: true)
        self.patternFileService = patternFileService ?? (patternStorageLocationsProvider == nil
            ? PatternFileService(root: fallbackPatternRoot)
            : nil)
        self.patternPublicationReceiptService = patternPublicationReceiptService
            ?? (patternStorageLocationsProvider == nil
                ? PatternInboxPublicationReceiptService(root: fallbackPatternRoot)
                : nil)
        self.patternInboxFileService = patternInboxFileService ?? (patternStorageLocationsProvider == nil
            ? PatternInboxFileService(root: url.deletingLastPathComponent().appendingPathComponent("PatternInbox", isDirectory: true))
            : nil)
        self.patternMarkupFileService = patternMarkupFileService ?? PatternMarkupFileService(
            root: self.patternFileService?.root ?? fallbackPatternRoot
        )
        let liveRoot = url.deletingLastPathComponent()
        let resolvedPatternThumbnailService = patternThumbnailService ?? PatternThumbnailFileService(
            directory: liveRoot.deletingLastPathComponent().appendingPathComponent(
                ".KnitNote-PatternThumbnailCache",
                isDirectory: true
            )
        )
        self.patternThumbnailService = resolvedPatternThumbnailService
        self.afterYouTubeThumbnailStage = afterYouTubeThumbnailStage
        self.patternPDFPageThumbnailURLGenerator = patternPDFPageThumbnailURLGenerator ?? {
            asset,
            sourceURL,
            pageIndex in
            try? resolvedPatternThumbnailService.thumbnailURL(
                asset: asset,
                sourceURL: sourceURL,
                pageIndex: pageIndex
            )
        }
        self.backupService = backupService
        self.archiveWrite = archiveWrite
        self.syncMutationSink = syncMutationSink
        isSyncPublicationEnabled = !(syncMutationSink is DisabledSyncMutationSink)
        let syncMetadataRoot = liveRoot.appendingPathComponent(
            "SyncMetadata",
            isDirectory: true
        )
        if isSyncPublicationEnabled {
            let identityStore = SyncInstallationIdentityStore(
                url: syncMetadataRoot.appendingPathComponent("installation.json")
            )
            let installationID = try? identityStore.loadOrCreate()
            syncInstallationID = installationID
            syncRevisionLedger = installationID.map {
                SyncRevisionLedger(
                    url: syncMetadataRoot.appendingPathComponent("revision-ledger.json"),
                    deviceID: $0
                )
            }
        } else {
            syncInstallationID = nil
            syncRevisionLedger = nil
        }
        let attachmentEvidenceFile = SyncAttachmentPublicationEvidenceFile(
            url: syncMetadataRoot.appendingPathComponent("attachment-versions.json"),
            beforeDurabilityBoundary: syncAttachmentEvidenceBeforeDurabilityBoundary
        )
        syncAttachmentPublicationEvidenceFile = attachmentEvidenceFile
        let attachmentManifestStore = SyncAttachmentManifestStore(
            url: syncMetadataRoot.appendingPathComponent("attachment-manifest.json")
        )
        syncAttachmentManifestStore = attachmentManifestStore
        if isSyncPublicationEnabled {
            do {
                syncAttachmentPublicationEvidence = try attachmentEvidenceFile.load()
                syncAttachmentPublicationEvidenceLoadFailed = false
            } catch {
                syncAttachmentPublicationEvidence = SyncAttachmentPublicationEvidence()
                syncAttachmentPublicationEvidenceLoadFailed = true
            }
            do {
                syncAttachmentManifest = try attachmentManifestStore.load()
                syncAttachmentManifestLoadFailed = false
            } catch {
                syncAttachmentManifest = [:]
                syncAttachmentManifestLoadFailed = true
            }
        } else {
            syncAttachmentPublicationEvidence = SyncAttachmentPublicationEvidence()
            syncAttachmentManifest = [:]
            syncAttachmentPublicationEvidenceLoadFailed = false
            syncAttachmentManifestLoadFailed = false
        }
        self.authorizeMutation = authorizeMutation
        self.commitSuccessfulMutation = commitSuccessfulMutation
        self.patternFolderNameContext = patternFolderNameContext
        reconcileSyncPublicationTransactionAtStartup()
        if isSyncPublicationEnabled,
           (syncAttachmentPublicationEvidenceLoadFailed || syncAttachmentManifestLoadFailed),
           syncPublicationError == nil {
            syncPublicationError = .corruptTransaction
        } else if isSyncPublicationEnabled, syncRevisionLedger == nil, syncPublicationError == nil {
            syncPublicationError = .transactionUnavailable
        }
        if let initialLoadError {
            loadError = initialLoadError
        } else if syncPublicationError != nil {
            didDeferLoadForSyncPublication = true
            loadPendingArchiveReadOnly()
        } else {
            load()
        }
    }

    public static func live(
        syncMutationSink: any SyncMutationSink = DisabledSyncMutationSink(),
        authorizeMutation: @escaping MutationAuthorizer = { _ in .allow },
        commitSuccessfulMutation: @escaping MutationSuccessCommitter = { _ in .allow }
    ) -> JSONProjectStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        do {
            let patternFolderNameContext = try PatternFolderNameContext.shipping()
            return try live(
                baseDirectory: base,
                locations: PatternStorageLocations.live(),
                patternFolderNameContext: patternFolderNameContext,
                syncMutationSink: syncMutationSink,
                authorizeMutation: authorizeMutation,
                commitSuccessfulMutation: commitSuccessfulMutation
            )
        } catch {
            // The normal iOS path never substitutes a private inbox when the App
            // Group is unavailable. Preserve the caller's publication composition
            // so this error branch follows the same enabled/disabled contract.
            let liveRoot = base.appendingPathComponent("KnitNote", isDirectory: true)
            let archiveURL = liveRoot.appendingPathComponent("projects-v1.json")
            let workRoot = base.appendingPathComponent(".KnitNote-BackupWork", isDirectory: true)
            return JSONProjectStore(
                url: archiveURL,
                backupService: KnitNoteBackupService(liveRoot: liveRoot, workRoot: workRoot),
                initialLoadError: .archiveUnavailable,
                patternStorageLocationsProvider: { try PatternStorageLocations.live() },
                syncMutationSink: syncMutationSink,
                authorizeMutation: authorizeMutation,
                commitSuccessfulMutation: commitSuccessfulMutation
            )
        }
    }

    public static func live(
        baseDirectory: URL,
        syncMutationSink: any SyncMutationSink = DisabledSyncMutationSink(),
        authorizeMutation: @escaping MutationAuthorizer = { _ in .allow },
        commitSuccessfulMutation: @escaping MutationSuccessCommitter = { _ in .allow }
    ) -> JSONProjectStore {
        let liveRoot = baseDirectory.appendingPathComponent("KnitNote", isDirectory: true)
        let patternFolderNameContext = try? PatternFolderNameContext.shipping()
        return live(
            baseDirectory: baseDirectory,
            locations: PatternStorageLocations(
                assetRoot: liveRoot.appendingPathComponent("Patterns", isDirectory: true),
                inboxRoot: liveRoot.appendingPathComponent("PatternInbox", isDirectory: true)
            ),
            patternFolderNameContext: patternFolderNameContext,
            syncMutationSink: syncMutationSink,
            authorizeMutation: authorizeMutation,
            commitSuccessfulMutation: commitSuccessfulMutation
        )
    }

    private static func live(
        baseDirectory: URL,
        locations: PatternStorageLocations,
        patternFolderNameContext: PatternFolderNameContext?,
        syncMutationSink: any SyncMutationSink,
        authorizeMutation: @escaping MutationAuthorizer,
        commitSuccessfulMutation: @escaping MutationSuccessCommitter
    ) -> JSONProjectStore {
        let liveRoot = locations.assetRoot.deletingLastPathComponent()
        let archiveURL = liveRoot.appendingPathComponent("projects-v1.json")
        let workRoot = baseDirectory.appendingPathComponent(
            ".KnitNote-BackupWork",
            isDirectory: true
        )
        let backupService = KnitNoteBackupService(
            liveRoot: liveRoot,
            workRoot: workRoot,
            patternFolderNameContext: patternFolderNameContext
        )
        if shouldDeferBackupRecoveryForSyncPublication(archiveURL: archiveURL) {
            return JSONProjectStore(
                url: archiveURL,
                patternFileService: PatternFileService(root: locations.assetRoot),
                patternInboxFileService: PatternInboxFileService(root: locations.inboxRoot),
                patternFolderNameContext: patternFolderNameContext,
                backupService: backupService,
                syncMutationSink: syncMutationSink,
                authorizeMutation: authorizeMutation,
                commitSuccessfulMutation: commitSuccessfulMutation
            )
        }
        do {
            let interruptedInstallation = try backupService.recoverInterruptedReplacement()
            let store = JSONProjectStore(
                url: archiveURL,
                patternFileService: PatternFileService(root: locations.assetRoot),
                patternInboxFileService: PatternInboxFileService(root: locations.inboxRoot),
                patternFolderNameContext: patternFolderNameContext,
                backupService: backupService,
                syncMutationSink: syncMutationSink,
                authorizeMutation: authorizeMutation,
                commitSuccessfulMutation: commitSuccessfulMutation
            )
            guard let interruptedInstallation else { return store }
            if store.loadError == nil {
                backupService.commit(interruptedInstallation)
                return store
            }
            try backupService.rollback(interruptedInstallation)
            return JSONProjectStore(
                url: archiveURL,
                patternFileService: PatternFileService(root: locations.assetRoot),
                patternInboxFileService: PatternInboxFileService(root: locations.inboxRoot),
                patternFolderNameContext: patternFolderNameContext,
                backupService: backupService,
                syncMutationSink: syncMutationSink,
                authorizeMutation: authorizeMutation,
                commitSuccessfulMutation: commitSuccessfulMutation
            )
        } catch {
            return JSONProjectStore(
                url: archiveURL,
                patternFileService: PatternFileService(root: locations.assetRoot),
                patternInboxFileService: PatternInboxFileService(root: locations.inboxRoot),
                patternFolderNameContext: patternFolderNameContext,
                backupService: backupService,
                initialLoadError: .unreadableArchive,
                syncMutationSink: syncMutationSink,
                authorizeMutation: authorizeMutation,
                commitSuccessfulMutation: commitSuccessfulMutation
            )
        }
    }

    private static func shouldDeferBackupRecoveryForSyncPublication(
        archiveURL: URL
    ) -> Bool {
        let transactionFile = SyncPublicationTransactionFile(archiveURL: archiveURL)
        do {
            guard let transaction = try transactionFile.load() else { return false }
            switch try transactionFile.commitStatus(of: transaction, archiveURL: archiveURL) {
            case .committed, .corrupt:
                return true
            case .uncommitted:
                try transactionFile.remove()
                return false
            }
        } catch {
            // Recovery can replace the complete live root, including the marker.
            // Any unreadable or unsafe publication evidence therefore blocks it.
            return true
        }
    }

    public func retryLoad() {
        guard !isSessionWriteRevoked else { return }
        guard loadError != nil else { return }
        reconcileSyncPublicationTransactionAtStartup()
        guard syncPublicationError == nil else { return }
        do {
            try refreshPatternStorageDependencies()
            load()
        } catch {
            loadError = .archiveUnavailable
        }
    }

    public func reloadFromDisk() throws {
        try requireSessionWriteAccess()
        guard !isDataOperationInProgress else {
            throw KnitNoteBackupError.operationInProgress
        }
        reconcileSyncPublicationTransactionAtStartup()
        if syncPublicationError != nil {
            didDeferLoadForSyncPublication = true
        }
        try ensureSyncPublicationReady()
        try reloadFromDiskDuringDataOperation()
    }

    public func repairSyncPublication() throws {
        try requireSessionWriteAccess()
        if syncCanonicalActivationRequired || syncCanonicalCheckpointStore != nil {
            guard let checkpoints = syncCanonicalCheckpointStore else { throw SyncPublicationError.pendingRepair }
            try activateSyncCanonicalState(checkpointStore: checkpoints, bootstrap: nil,
                                           attachmentSources: syncHydratedAttachmentSources)
            return
        }
        guard !syncAttachmentPublicationEvidenceLoadFailed,
              !syncAttachmentManifestLoadFailed else {
            syncPublicationError = .corruptTransaction
            throw SyncPublicationError.corruptTransaction
        }
        let transactionFile = SyncPublicationTransactionFile(archiveURL: url)
        let transaction: SyncPublicationTransaction
        do {
            let loadedTransaction = try transactionFile.load()
            if loadedTransaction?.canonicalTransition != nil {
                syncCanonicalActivationRequired = true
                throw SyncPublicationError.pendingRepair
            }
            try recoverDeletionLedger(publication: loadedTransaction)
            guard let loaded = loadedTransaction else {
                syncPublicationError = nil
                completeDeferredLoadAfterSyncPublicationIfNeeded()
                return
            }
            transaction = loaded
            switch try transactionFile.commitStatus(of: transaction, archiveURL: url) {
            case .committed:
                break
            case .uncommitted:
                try transactionFile.remove()
                syncPublicationError = nil
                completeDeferredLoadAfterSyncPublicationIfNeeded()
                return
            case .corrupt:
                throw SyncPublicationTransactionFileError.corrupt
            }
        } catch {
            let publicationError = syncPublicationError(for: error)
            syncPublicationError = publicationError
            throw publicationError
        }

        guard isSyncPublicationEnabled else {
            syncPublicationError = .sinkUnavailable
            throw SyncPublicationError.sinkUnavailable
        }
        do {
            try publish(transaction, transactionFile: transactionFile)
            syncPublicationError = nil
            completeDeferredLoadAfterSyncPublicationIfNeeded()
        } catch let error as SyncPublicationError {
            syncPublicationError = error
            throw error
        } catch {
            syncPublicationError = .pendingRepair
            throw SyncPublicationError.pendingRepair
        }
    }

    public func exportBackup(appVersion: String) async throws -> URL {
        try beginDataOperation()
        defer { isDataOperationInProgress = false }
        let service = backupService
        return try await Task.detached(priority: .userInitiated) {
            try service.createPackage(appVersion: appVersion)
        }.value
    }

    public func prepareBackupRestore(from packageURL: URL) async throws -> StagedKnitNoteBackup {
        let accessedSecurityScope = packageURL.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                packageURL.stopAccessingSecurityScopedResource()
            }
        }
        let service = backupService
        return try await Task.detached(priority: .userInitiated) {
            try service.stagePackage(at: packageURL)
        }.value
    }

    public func cancelBackupRestore(_ backup: StagedKnitNoteBackup) {
        removeOwnedBackupArtifact(at: backup.root, kind: .stagedRestore)
    }

    public func cleanupBackupArtifact(at url: URL) {
        removeOwnedBackupArtifact(at: url, kind: .exportPackage)
    }

    public func restoreBackup(_ backup: StagedKnitNoteBackup) async throws {
        try requireAccess(.restoreBackup)
        try ensureSyncPublicationReady()
        try beginDataOperation()
        defer { isDataOperationInProgress = false }
        let service = backupService
        let installation = try await Task.detached(priority: .userInitiated) {
            try service.install(backup)
        }.value

        do {
            try reloadFromDiskDuringDataOperation()
        } catch {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try service.rollback(installation)
                }.value
                try reloadFromDiskDuringDataOperation()
            } catch {
                throw KnitNoteBackupError.rollbackFailed
            }
            throw KnitNoteBackupError.installFailedOriginalPreserved
        }
        await Task.detached(priority: .utility) {
            service.commit(installation)
        }.value
        try? patternThumbnailService.deleteAll()
        notifyYarnLabelPhotosDidChange()
        projectCoverGeneration &+= 1
    }
    public func add(name: String) throws { try add(name: name, photoData: nil) }
    public func add(name: String, photoData: Data?) throws {
        var project = try StoredProject(name: name)
        try requireAccess(.createProject)
        var newFilename: String?
        do {
            if let photoData {
                try ensureArchiveAvailable()
                newFilename = try photoService.save(data: photoData, projectID: project.id)
                project.setPhotoFilename(newFilename)
            }
            try persist(projects: projects + [project], yarns: yarns)
        } catch {
            if let newFilename { try? photoService.delete(filename: newFilename) }
            throw error
        }
    }
    public func delete(id: UUID) throws {
        try requireAccess(.deleteProject)
        guard let deletedProject = projects.first(where: { $0.id == id }) else { return }
        guard !deletedProject.isCompleted else {
            throw ProjectDeletionError.projectCompleted
        }
        let filename = deletedProject.photoFilename
        let journalFilenames = Set(deletedProject.journalEntries.flatMap {
            [$0.photoFilename, $0.thumbnailFilename]
        })
        var stagedYarns = yarns
        let now = Date.now
        for index in stagedYarns.indices where stagedYarns[index].linkedProjectIDs.contains(id) {
            stagedYarns[index].setLinkedProjectIDs(
                stagedYarns[index].linkedProjectIDs.subtracting([id]),
                now: now
            )
        }
        let removedUsages = patternUsages.filter { $0.projectID == id }
        let remainingUsages = patternUsages.filter { $0.projectID != id }
        let markupDeleteMutations = try syncUsageMarkupDeleteMutations(
            usageIDs: removedUsages.map(\.id)
        ) + syncLegacyMarkupDeleteMutations(
            projectID: id,
            patternIDs: deletedProject.patterns.map(\.id)
        )
        let files = try requiredPatternFileService()
        let deletion = try PatternLibraryDeletionTransaction.begin(
            root: files.root,
            markupService: patternMarkupFileService,
            usageIDs: removedUsages.map(\.id),
            asset: nil,
            fileService: files
        )
        do {
            try persist(
                projects: projects.filter { $0.id != id },
                yarns: stagedYarns,
                patternUsages: remainingUsages,
                additionalSyncMutations: markupDeleteMutations,
                beforeArchiveWrite: { try deletion.stage() }
            )
        } catch {
            try deletion.rollback()
            throw error
        }
        try deletion.publish()
        try deletion.commit()
        for pattern in deletedProject.patterns {
            try? files.delete(projectID: id, pattern: pattern)
            try? patternMarkupFileService.deleteLegacyMarkup(
                projectID: id,
                patternID: pattern.id
            )
        }
        if let filename { try? photoService.delete(filename: filename) }
        deleteJournalPhotosIfUnreferenced(journalFilenames)
    }
    public func rename(id: UUID, to name: String) throws {
        try requireAccess(.editProject)
        try mutate(id: id) { try $0.rename(to: name) }
    }
    public func markCompleted(projectID: UUID) throws {
        try requireAccess(.completeProject)
        try mutate(id: projectID) { $0.markCompleted() }
    }
    public func resumeProject(projectID: UUID) throws {
        try requireAccess(.resumeProject)
        try mutate(id: projectID) { $0.resume() }
    }
    public func updateProject(
        id: UUID,
        name: String,
        toolType: ProjectToolType?,
        toolSize: String?,
        toolNotes: String?,
        photoChange: ProjectPhotoChange
    ) throws {
        try requireAccess(.editProject)
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let oldFilename = projects[index].photoFilename
        var updated = projects[index]
        try updated.rename(to: name)
        updated.updateToolDetails(type: toolType, size: toolSize, notes: toolNotes)
        var newFilename: String?
        do {
            switch photoChange {
            case .unchanged:
                break
            case let .replace(data):
                try ensureArchiveAvailable()
                newFilename = try photoService.save(data: data, projectID: id)
                updated.setPhotoFilename(newFilename)
            case .remove:
                updated.setPhotoFilename(nil)
            }
            var staged = projects
            staged[index] = updated
            try persist(projects: staged, yarns: yarns)
        } catch {
            if let newFilename { try? photoService.delete(filename: newFilename) }
            throw error
        }
        if let oldFilename, oldFilename != updated.photoFilename {
            try? photoService.delete(filename: oldFilename)
        }
    }
    public func selectCounter(projectID: UUID, counterID: UUID) throws {
        try requireAccess(.changeCounter)
        try mutate(id: projectID) { $0.selectCounter(id: counterID) }
    }
    @discardableResult
    public func incrementCounter(
        projectID: UUID,
        counterID: UUID
    ) throws -> StoredProjectCounterMutationResult? {
        try requireAccess(.changeCounter)
        return try mutateCounter(id: projectID) { $0.incrementCounter(id: counterID) }
    }
    @discardableResult
    public func decrementCounter(
        projectID: UUID,
        counterID: UUID
    ) throws -> StoredProjectCounterMutationResult? {
        try requireAccess(.changeCounter)
        return try mutateCounter(id: projectID) { $0.decrementCounter(id: counterID) }
    }
    @discardableResult
    public func resetCounter(
        projectID: UUID,
        counterID: UUID
    ) throws -> StoredProjectCounterMutationResult? {
        try requireAccess(.changeCounter)
        return try mutateCounter(id: projectID) { $0.resetCounter(id: counterID) }
    }
    @discardableResult
    public func updateCounter(
        projectID: UUID,
        counterID: UUID,
        name: String?,
        value: Int
    ) throws -> StoredProjectCounterMutationResult? {
        try requireAccess(.changeCounter)
        return try mutateCounter(id: projectID) {
            $0.updateCounter(id: counterID, name: name, value: value)
        }
    }
    @discardableResult
    public func manageCounter(
        projectID: UUID,
        counterID: UUID,
        name: String?,
        value: Int,
        reminder: CounterReminderEdit
    ) throws -> StoredProjectCounterMutationResult? {
        try requireAccess(.changeCounter)
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              !projects[projectIndex].isCompleted else { return nil }
        var stagedProjects = projects
        guard let result = stagedProjects[projectIndex].manageCounter(
            id: counterID,
            name: name,
            value: value,
            reminder: reminder
        ) else { return nil }
        try result.validateKnittingReminderEvaluation()
        try persist(projects: stagedProjects, yarns: yarns)
        return result
    }
    public func configureCounterReminder(
        projectID: UUID,
        counterID: UUID,
        draft: CounterReminderDraft
    ) throws {
        try requireAccess(.changeCounter)
        try mutateActiveCounterProject(id: projectID) {
            $0.configureCounterReminderV14(id: counterID, draft: draft)
        }
    }
    public func completeCounterReminder(
        projectID: UUID,
        counterID: UUID,
        reminderID: UUID,
        observedCount: Int
    ) throws {
        try requireAccess(.changeCounter)
        try mutateActiveCounterProject(id: projectID) {
            $0.completeCounterReminder(
                id: counterID,
                reminderID: reminderID,
                observedCount: observedCount
            )
        }
    }
    public func stopCounterReminder(
        projectID: UUID,
        counterID: UUID,
        reminderID: UUID
    ) throws {
        try requireAccess(.changeCounter)
        try mutateActiveCounterProject(id: projectID) {
            $0.stopCounterReminder(id: counterID, reminderID: reminderID)
        }
    }
    @discardableResult
    public func addKnittingReminder(
        projectID: UUID,
        draft: KnittingReminderDraft,
        now: Date = .now
    ) throws -> UUID {
        try requireAccess(.changeCounter)
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else {
            throw PatternLibraryMutationError.projectNotFound
        }
        var staged = projects
        let reminderID = try staged[index].addKnittingReminder(
            counterID: staged[index].mainCounterID,
            draft: draft,
            now: now
        )
        try persist(projects: staged, yarns: yarns)
        return reminderID
    }

    public func updateKnittingReminder(
        projectID: UUID,
        reminderID: UUID,
        observedRevision: UInt64,
        draft: KnittingReminderDraft,
        now: Date = .now
    ) throws {
        try requireAccess(.changeCounter)
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else {
            throw PatternLibraryMutationError.projectNotFound
        }
        var staged = projects
        try staged[index].updateKnittingReminder(
            id: reminderID,
            observedRevision: observedRevision,
            draft: draft,
            now: now
        )
        try persist(projects: staged, yarns: yarns)
    }

    public func applyKnittingReminderAction(
        projectID: UUID,
        reminderID: UUID,
        occurrenceID: UUID?,
        observedRevision: UInt64,
        action: KnittingReminderAction,
        now: Date = .now
    ) throws {
        try requireAccess(.changeCounter)
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else {
            throw PatternLibraryMutationError.projectNotFound
        }
        var staged = projects
        try staged[index].applyKnittingReminderAction(
            id: reminderID,
            occurrenceID: occurrenceID,
            observedRevision: observedRevision,
            action: action,
            now: now
        )
        try persist(projects: staged, yarns: yarns)
    }

    public func deleteKnittingReminder(
        projectID: UUID,
        reminderID: UUID,
        observedRevision: UInt64
    ) throws {
        try requireAccess(.changeCounter)
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else {
            throw PatternLibraryMutationError.projectNotFound
        }
        var staged = projects
        try staged[index].deleteKnittingReminder(
            id: reminderID,
            observedRevision: observedRevision
        )
        try persist(projects: staged, yarns: yarns)
    }

    /// Performs one reader-originated counter mutation and returns the exact
    /// generation published by its successful archive write.
    @discardableResult
    public func mutatePatternReaderCounter(
        usageID: UUID,
        counterID: UUID,
        mutation: PatternReaderCounterMutation,
        expectedDataGeneration: UInt64
    ) throws -> UInt64 {
        try mutatePatternReaderCounterWithOutcome(
            usageID: usageID,
            counterID: counterID,
            mutation: mutation,
            expectedDataGeneration: expectedDataGeneration
        ).generation
    }

    public func mutatePatternReaderCounterWithOutcome(
        usageID: UUID,
        counterID: UUID,
        mutation: PatternReaderCounterMutation,
        expectedDataGeneration: UInt64
    ) throws -> PatternReaderCounterMutationResult {
        try requireAccess(.changeCounter)
        try validateExpectedDataGeneration(expectedDataGeneration)
        let usageIndex = try mutableUsageIndex(usageID: usageID)
        let projectID = patternUsages[usageIndex].projectID
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
            throw PatternLibraryMutationError.projectNotFound
        }
        var stagedProjects = projects
        let result: StoredProjectCounterMutationResult?
        let didAcceptMutation: Bool
        switch mutation {
        case .increment:
            result = stagedProjects[projectIndex].incrementCounter(id: counterID)
            didAcceptMutation = result != nil
        case .reset:
            result = stagedProjects[projectIndex].resetCounter(id: counterID)
            didAcceptMutation = result != nil
        case let .update(name, value):
            result = stagedProjects[projectIndex].updateCounter(
                id: counterID,
                name: name,
                value: value
            )
            didAcceptMutation = result != nil
        case let .manage(name, value, reminder):
            result = stagedProjects[projectIndex].manageCounter(
                id: counterID,
                name: name,
                value: value,
                reminder: reminder
            )
            didAcceptMutation = result != nil
        case let .completeReminder(reminderID, observedCount):
            didAcceptMutation = stagedProjects[projectIndex].completeCounterReminder(
                id: counterID,
                reminderID: reminderID,
                observedCount: observedCount
            )
            result = nil
        case let .stopReminder(reminderID):
            didAcceptMutation = stagedProjects[projectIndex].stopCounterReminder(
                id: counterID,
                reminderID: reminderID
            )
            result = nil
        }
        try result?.validateKnittingReminderEvaluation()
        guard didAcceptMutation else {
            return PatternReaderCounterMutationResult(generation: dataGeneration, outcome: nil)
        }
        stagedProjects[projectIndex].selectCounter(id: counterID)
        try persist(projects: stagedProjects, yarns: yarns)
        return PatternReaderCounterMutationResult(
            generation: dataGeneration,
            outcome: result?.outcome
        )
    }
    public func renameCounter(projectID: UUID, counterID: UUID, name: String?) throws {
        try requireAccess(.changeCounter)
        try mutate(id: projectID) { $0.renameCounter(id: counterID, to: name) }
    }
    public func applyWatchCommand(
        _ command: WatchCounterCommand,
        ledger: inout ProcessedWatchCommandLedger,
        now: Date = .now
    ) throws -> WatchCommandAcknowledgement {
        try ensureSyncPublicationReady()
        try ensureArchiveAvailable()
        if let proof = try durableOrphanWatchCommandProof(
            for: command
        ) {
            try cacheWatchCommandProof(proof, for: command, in: &ledger)
            return try watchAcknowledgement(
                for: command.id,
                rejection: proof.rejection,
                entitlement: .permanentlyUnlocked,
                now: now
            )
        }
        if let processed = ledger.entry(for: command.id) {
            return try watchAcknowledgement(
                for: command.id,
                rejection: processed.rejection,
                entitlement: .permanentlyUnlocked,
                now: now
            )
        }
        guard command.schemaVersion == WatchCounterCommand.currentSchemaVersion,
              command.hasValidPayload else {
            ledger.record(
                command.id,
                rejection: .unsupportedSchema,
                command: command,
                processingStamp: watchCommandProcessingStamp(at: now),
                at: now
            )
            return try watchAcknowledgement(
                for: command.id,
                rejection: .unsupportedSchema,
                entitlement: .permanentlyUnlocked,
                now: now
            )
        }
        try authorizeWatchCounterMutation()
        return try applyAuthorizedWatchCommand(
            command,
            entitlement: .permanentlyUnlocked,
            ledger: &ledger,
            now: now
        )
    }

    public func applyWatchCommand(
        _ command: WatchCounterCommand,
        entitlement: EntitlementSnapshot,
        ledger: inout ProcessedWatchCommandLedger,
        now: Date = .now
    ) throws -> WatchCommandAcknowledgement {
        try ensureSyncPublicationReady()
        try ensureArchiveAvailable()
        if let proof = try durableOrphanWatchCommandProof(
            for: command
        ) {
            try cacheWatchCommandProof(proof, for: command, in: &ledger)
            return try watchAcknowledgement(
                for: command.id,
                rejection: proof.rejection,
                entitlement: entitlement,
                now: now
            )
        }
        if let processed = ledger.entry(for: command.id) {
            return try watchAcknowledgement(
                for: command.id,
                rejection: processed.rejection,
                entitlement: entitlement,
                now: now
            )
        }
        guard command.schemaVersion == WatchCounterCommand.currentSchemaVersion,
              command.hasValidPayload else {
            ledger.record(
                command.id,
                rejection: .unsupportedSchema,
                command: command,
                processingStamp: watchCommandProcessingStamp(at: now),
                at: now
            )
            return try watchAcknowledgement(
                for: command.id,
                rejection: .unsupportedSchema,
                entitlement: entitlement,
                now: now
            )
        }
        do {
            try requireWatchEntitlement(entitlement, now: now)
        } catch ProjectStoreError.accessRestricted {
            try ensureArchiveAvailable()
            ledger.record(
                command.id,
                rejection: .entitlementRequired,
                command: command,
                processingStamp: watchCommandProcessingStamp(at: now),
                at: now
            )
            return try watchAcknowledgement(
                for: command.id,
                rejection: .entitlementRequired,
                entitlement: entitlement,
                now: now
            )
        }
        return try applyAuthorizedWatchCommand(
            command,
            entitlement: entitlement,
            ledger: &ledger,
            now: now
        )
    }

    public func acknowledgeRejectedWatchCommandDurably(
        _ command: WatchCounterCommand,
        rejection: WatchCommandRejection,
        entitlement: EntitlementSnapshot,
        ledgerURL: URL,
        now: Date = .now
    ) throws -> WatchCommandAcknowledgement {
        try ensureSyncPublicationReady()
        if let acknowledgement = try persistedWatchCommandAcknowledgement(
            for: command,
            entitlement: entitlement,
            ledgerURL: ledgerURL,
            now: now
        ) {
            return acknowledgement
        }
        try ensureArchiveAvailable()
        let ledgerFile = AtomicWatchSyncFile<ProcessedWatchCommandLedger>(url: ledgerURL)
        var ledger = try ledgerFile.load() ?? ProcessedWatchCommandLedger()
        let effectiveRejection = command.schemaVersion == WatchCounterCommand.currentSchemaVersion
            && command.hasValidPayload ? rejection : .unsupportedSchema
        ledger.record(
            command.id,
            rejection: effectiveRejection,
            command: command,
            processingStamp: watchCommandProcessingStamp(at: now),
            at: now
        )
        try ledgerFile.save(ledger)
        try publishWatchSyncMetadata(preparedCommand: nil, processedLedger: ledger)
        try ensureMissingTargetWatchProofPublication(for: effectiveRejection)
        return try watchAcknowledgement(
            for: command.id,
            rejection: effectiveRejection,
            entitlement: entitlement,
            now: now
        )
    }

    func persistedWatchCommandAcknowledgement(
        for command: WatchCounterCommand,
        entitlement: EntitlementSnapshot,
        ledgerURL: URL,
        now: Date
    ) throws -> WatchCommandAcknowledgement? {
        // A ledger receipt may have become durable immediately before its
        // aggregate publication was interrupted. Repair that publication
        // before returning the duplicate acknowledgement, so the Watch never
        // observes completion while transferable exactly-once proof is still
        // stranded only in the prunable local ledger.
        if syncPublicationError == .pendingRepair {
            try repairSyncPublication()
        }
        try ensureSyncPublicationReady()
        try ensureArchiveAvailable()
        let ledgerFile = AtomicWatchSyncFile<ProcessedWatchCommandLedger>(url: ledgerURL)
        var ledger = try loadLedgerRecoveringCorruption(from: ledgerFile)
        guard !ledger.requiresFreshHandshake else {
            throw WatchCommandPersistenceError.requiresFreshHandshake
        }
        let durableProof = try durableWatchCommandProof(for: command)
        if let proof = durableProof {
            try cacheWatchCommandProof(proof, for: command, in: &ledger)
            try ledgerFile.save(ledger)
            return try watchAcknowledgement(
                for: command.id,
                rejection: proof.rejection,
                entitlement: entitlement,
                now: now
            )
        }
        guard let processed = ledger.entry(for: command.id) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else {
            ledger.markRequiresFreshHandshake()
            try ledgerFile.save(ledger)
            throw WatchCommandPersistenceError.requiresFreshHandshake
        }
        if isSyncPublicationEnabled, let ledgerProof = try SyncProcessedWatchCommandProof(
            entry: processed,
            processingDeviceID: syncPublicationDeviceID
        ) {
            guard ledgerProof.commandIdentity == ProcessedWatchCommandIdentity(command) else {
                throw SyncPublicationTransactionFileError.corrupt
            }
            try publishWatchSyncMetadata(preparedCommand: nil, processedLedger: ledger)
            try ensureSyncPublicationReady()
            guard try syncAttachmentPublicationEvidence.watchCommandProof(for: command)
                    == ledgerProof else {
                throw SyncPublicationTransactionFileError.corrupt
            }
        }
        return try watchAcknowledgement(
            for: command.id,
            rejection: processed.rejection,
            entitlement: entitlement,
            now: now
        )
    }

    func cacheWatchCommandProof(
        _ proof: SyncProcessedWatchCommandProof,
        for command: WatchCounterCommand,
        in ledger: inout ProcessedWatchCommandLedger
    ) throws {
        guard proof.commandIdentity == ProcessedWatchCommandIdentity(command) else {
            throw SyncPublicationTransactionFileError.corrupt
        }
        if let entry = ledger.entry(for: command.id),
           let existing = try SyncProcessedWatchCommandProof(
                entry: entry,
                processingDeviceID: proof.processingStamp?.deviceID
           ),
           existing != proof {
            throw SyncPublicationTransactionFileError.corrupt
        }
        ledger.record(
            command.id,
            rejection: proof.rejection,
            command: command,
            preparedCommand: proof.preparedCommand,
            effectProof: proof.effectProof,
            processingStamp: proof.processingStamp,
            at: proof.processingStamp?.modifiedAt ?? nowForLegacyWatchProof(proof)
        )
    }

    func durableWatchCommandProof(
        for command: WatchCounterCommand
    ) throws -> SyncProcessedWatchCommandProof? {
        guard isSyncPublicationEnabled else {
            return try syncAttachmentPublicationEvidence.watchCommandProof(for: command)
        }
        let proof = try syncAttachmentPublicationEvidenceFile.watchCommandProof(for: command)
        if let proof {
            try syncAttachmentPublicationEvidence.retainWatchCommandProof(proof)
        }
        return proof
    }

    func durableOrphanWatchCommandProof(
        for command: WatchCounterCommand
    ) throws -> SyncProcessedWatchCommandProof? {
        guard let proof = try durableWatchCommandProof(for: command),
              proof.rejection == .projectMissing || proof.rejection == .counterMissing else {
            return nil
        }
        do {
            _ = try SyncOrphanWatchCommandProof(proof: proof)
        } catch {
            throw SyncPublicationTransactionFileError.corrupt
        }
        return proof
    }

    private func nowForLegacyWatchProof(_ proof: SyncProcessedWatchCommandProof) -> Date {
        proof.commandIdentity?.createdAt ?? .distantPast
    }

    func watchCommandProcessingStamp(at date: Date) -> SyncMutationStamp? {
        guard isSyncPublicationEnabled else { return nil }
        return SyncMutationStamp(
            logicalRevision: 0,
            // Issue the timestamp once in the Watch codec's persisted Double
            // representation. Do not round to integral milliseconds or rewrite
            // retained proofs: their exact immutable identity remains binding.
            modifiedAt: Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000) / 1_000),
            deviceID: syncPublicationDeviceID
        )
    }

    func ensureMissingTargetWatchProofPublication(
        for rejection: WatchCommandRejection?
    ) throws {
        switch rejection {
        case .projectMissing, .counterMissing:
            try ensureSyncPublicationReady()
        default:
            break
        }
    }

    func requireWatchEntitlement(_ entitlement: EntitlementSnapshot, now: Date) throws {
        guard FeatureAccessPolicy.decision(
            for: .changeCounter,
            snapshot: entitlement,
            now: now
        ) == .allow else {
            throw ProjectStoreError.accessRestricted
        }
        guard entitlement.state(at: now) != .trialNotStarted else {
            throw ProjectStoreError.accessRestricted
        }
    }

    func authorizeWatchCounterMutation() throws {
        try requireAccess(.changeCounter)
    }

    func applyAuthorizedWatchCommand(
        _ command: WatchCounterCommand,
        entitlement: EntitlementSnapshot = .permanentlyUnlocked,
        ledger: inout ProcessedWatchCommandLedger,
        now: Date
    ) throws -> WatchCommandAcknowledgement {
        try ensureSyncPublicationReady()
        try ensureArchiveAvailable()
        if let processed = ledger.entry(for: command.id) {
            return try watchAcknowledgement(
                for: command.id,
                rejection: processed.rejection,
                entitlement: entitlement,
                now: now
            )
        }

        let rejection: WatchCommandRejection?
        if command.schemaVersion != WatchCounterCommand.currentSchemaVersion
            || !command.hasValidPayload {
            rejection = .unsupportedSchema
        } else if let project = project(id: command.projectID) {
            if let counter = project.counters.first(where: { $0.id == command.counterID }) {
                if project.isCompleted {
                    rejection = .projectCompleted
                } else {
                    rejection = switch command.operation {
                    case .increment, .decrement, .reset:
                        nil
                    case .completeReminder, .deferReminderOnce, .skipReminder:
                        reminderCommandIsCurrent(
                            command,
                            project: project,
                            counter: counter
                        ) ? nil : .reminderMismatch
                    case .stopReminder:
                        .unsupportedSchema
                    }
                }
            } else {
                rejection = .counterMissing
            }
        } else {
            rejection = .projectMissing
        }

        if let rejection {
            ledger.record(
                command.id,
                rejection: rejection,
                command: command,
                processingStamp: watchCommandProcessingStamp(at: now),
                at: now
            )
            return try watchAcknowledgement(
                for: command.id,
                rejection: rejection,
                entitlement: entitlement,
                now: now
            )
        }

        do {
            try mutate(id: command.projectID) { project in
                switch command.operation {
                case .increment:
                    try project.incrementCounter(id: command.counterID, now: now)?
                        .validateKnittingReminderEvaluation()
                case .decrement:
                    try project.decrementCounter(id: command.counterID, now: now)?
                        .validateKnittingReminderEvaluation()
                case .reset:
                    try project.resetCounter(id: command.counterID, now: now)?
                        .validateKnittingReminderEvaluation()
                case .completeReminder:
                    guard let payload = command.reminderPayload else { return }
                    try project.applyKnittingReminderAction(
                        id: payload.reminderID,
                        occurrenceID: payload.occurrenceID,
                        observedRevision: payload.observedRevision,
                        action: .complete,
                        now: now
                    )
                case .deferReminderOnce:
                    guard let payload = command.reminderPayload else { return }
                    try project.applyKnittingReminderAction(
                        id: payload.reminderID,
                        occurrenceID: payload.occurrenceID,
                        observedRevision: payload.observedRevision,
                        action: .deferOnce,
                        now: now
                    )
                case .skipReminder:
                    guard let payload = command.reminderPayload else { return }
                    try project.applyKnittingReminderAction(
                        id: payload.reminderID,
                        occurrenceID: payload.occurrenceID,
                        observedRevision: payload.observedRevision,
                        action: .skip,
                        now: now
                    )
                case .stopReminder:
                    return
                }
            }
        } catch let error as KnittingReminderMutationError {
            let rejection = watchRejection(for: error)
            ledger.record(
                command.id,
                rejection: rejection,
                command: command,
                processingStamp: watchCommandProcessingStamp(at: now),
                at: now
            )
            return try watchAcknowledgement(
                for: command.id,
                rejection: rejection,
                entitlement: entitlement,
                now: now
            )
        }
        ledger.record(command.id, at: now)
        return try watchAcknowledgement(
            for: command.id,
            rejection: nil,
            entitlement: entitlement,
            now: now
        )
    }

    private func watchRejection(
        for error: KnittingReminderMutationError
    ) -> WatchCommandRejection {
        switch error {
        case .invalidDraft, .staleRevision, .occurrenceNotFound, .alreadyDeferred,
             .invalidAction, .arithmeticOverflow, .revisionExhausted,
             .newReminderRequiresMainCounter, .occurrenceLimitExceeded:
            .reminderMismatch
        }
    }

    func reminderCommandIsCurrent(
        _ command: WatchCounterCommand,
        project: StoredProject,
        counter: ProjectCounter
    ) -> Bool {
        switch command.operation {
        case .completeReminder, .deferReminderOnce, .skipReminder:
            reminderCommandIsCurrent(
                command,
                project: project,
                counter: counter,
                operation: command.operation
            )
        case .increment, .decrement, .reset, .stopReminder:
            false
        }
    }

    func preparedReminderOutcome(
        for command: WatchCounterCommand,
        project: StoredProject,
        counter: ProjectCounter
    ) -> PreparedWatchReminderOutcome? {
        guard let payload = command.reminderPayload,
              let reminder = project.knittingReminders.first(where: {
                  $0.id == payload.reminderID && $0.counterID == counter.id
              }),
              let occurrence = reminder.progress.pending.first(where: {
                  $0.id == payload.occurrenceID
              })
        else { return nil }

        switch command.operation {
        case .completeReminder:
            let (completedCount, overflow) = reminder.progress.completedCount
                .addingReportingOverflow(1)
            guard !overflow else { return nil }
            return PreparedWatchReminderOutcome(
                action: .complete,
                completedCount: completedCount,
                skippedCount: reminder.progress.skippedCount
            )
        case .deferReminderOnce:
            let observedCounterValue = reminder.progress.lastObservedCounterValue
                ?? occurrence.originalTarget
            let (displayAt, overflow) = observedCounterValue.addingReportingOverflow(1)
            guard !overflow else { return nil }
            return PreparedWatchReminderOutcome(
                action: .deferOnce,
                completedCount: reminder.progress.completedCount,
                skippedCount: reminder.progress.skippedCount,
                deferredDisplayAt: displayAt
            )
        case .skipReminder:
            let (skippedCount, overflow) = reminder.progress.skippedCount
                .addingReportingOverflow(1)
            guard !overflow else { return nil }
            return PreparedWatchReminderOutcome(
                action: .skip,
                completedCount: reminder.progress.completedCount,
                skippedCount: skippedCount
            )
        case .increment, .decrement, .reset, .stopReminder:
            return nil
        }
    }

    private func reminderCommandIsCurrent(
        _ command: WatchCounterCommand,
        project: StoredProject,
        counter: ProjectCounter,
        operation: WatchCounterOperation? = nil
    ) -> Bool {
        guard let payload = command.reminderPayload,
              let reminder = project.knittingReminders.first(where: {
                  $0.id == payload.reminderID && $0.counterID == counter.id
              }),
              reminder.state == .active,
              reminder.mutationRevision == payload.observedRevision,
              let occurrence = reminder.visibleOccurrences(at: counter.value).first(where: {
                  $0.id == payload.occurrenceID
              })
        else { return false }
        switch operation ?? command.operation {
        case .completeReminder:
            return true
        case .deferReminderOnce:
            return occurrence.phase == .initial
        case .skipReminder:
            return occurrence.phase == .deferredOnce && !occurrence.awaitsNextUpwardChange
        case .increment, .decrement, .reset, .stopReminder:
            return false
        }
    }
    public func saveNote(projectID: UUID, counterID: UUID, row: Int, text: String) throws {
        try requireAccess(.editNote)
        try mutate(id: projectID) { try $0.saveNote(counterID: counterID, row: row, text: text) }
    }
    public func deleteNote(projectID: UUID, counterID: UUID, row: Int) throws {
        try requireAccess(.editNote)
        try mutate(id: projectID) { $0.deleteNote(counterID: counterID, row: row) }
    }
    public func addPattern(projectID: UUID, pattern: PatternDocument) throws {
        try requireAccess(.importPattern)
        try addPatternWithoutAuthorization(projectID: projectID, pattern: pattern)
    }
    private func addPatternWithoutAuthorization(
        projectID: UUID,
        pattern: PatternDocument
    ) throws {
        try mutate(id: projectID) { $0.addPattern(pattern) }
    }
    public func importPattern(from source: URL, projectID: UUID) async throws -> PatternDocument {
        let access = try preflightAccess(.importPattern)
        try ensureArchiveAvailable()
        guard project(id: projectID) != nil else { throw ProjectStoreError.patternNotFound }
        let service = try requiredPatternFileService()
        _ = try service.inspect(source)
        try commitAccessIfNeeded(access, mutation: .importPattern)
        activePatternTransactions += 1
        defer { activePatternTransactions -= 1 }
        let pattern = try await Task.detached(priority: .userInitiated) {
            try service.importFile(from: source, projectID: projectID)
        }.value
        do {
            try Task.checkCancellation()
            guard project(id: projectID) != nil else { throw ProjectStoreError.patternNotFound }
            try addPatternWithoutAuthorization(projectID: projectID, pattern: pattern)
        } catch {
            try? service.delete(projectID: projectID, pattern: pattern)
            throw error
        }
        return pattern
    }
    public func processPatternInboxItem(
        id: UUID,
        selectingPatternID: UUID? = nil
    ) async throws -> PatternImportOutcome {
        return try await processPatternInboxItem(
            id: id,
            duplicateResolution: selectingPatternID.map(PatternImportDuplicateResolution.existing)
                ?? .automatic
        )
    }

    public func processPatternInboxItem(
        id: UUID,
        duplicateResolution: PatternImportDuplicateResolution
    ) async throws -> PatternImportOutcome {
        let access = try preflightAccess(.importPattern)
        return try await withActivePatternTransaction {
            try await processPatternInboxItemWithoutTransaction(
                id: id,
                duplicateResolution: duplicateResolution,
                access: access
            )
        }
    }

    private func processPatternInboxItemWithoutTransaction(
        id: UUID,
        duplicateResolution: PatternImportDuplicateResolution,
        access: FeatureAccessDecision
    ) async throws -> PatternImportOutcome {
        try ensureArchiveAvailable()
        try await reconcilePublishedPatternInboxItems()
        let inbox = try requiredPatternInboxFileService()
        let files = try requiredPatternFileService()
        guard let item = try inbox.item(id: id) else {
            throw PatternInboxError.itemNotFound
        }
        let capturedGeneration = dataGeneration

        let coordinator = PatternImportCoordinator()
        let prepared = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try coordinator.prepare(item: item, inbox: inbox, fileService: files)
        }.value
        try Task.checkCancellation()

        // A completed detached read may have raced with another published mutation.
        // Resolve from the current arrays either way; this branch makes that contract explicit.
        if dataGeneration != capturedGeneration {
            try ensureArchiveAvailable()
        }
        if let targetProjectID = prepared.item.targetProjectID {
            guard project(id: targetProjectID) != nil else {
                throw ProjectStoreError.patternNotFound
            }
        }
        return try publishPatternImport(
            prepared,
            duplicateResolution: duplicateResolution,
            access: access
        )
    }

    public func pendingPatternInboxItems() async throws -> [PatternInboxItem] {
        try await withActivePatternTransaction {
            try ensureArchiveAvailable()
            try await reconcilePublishedPatternInboxItems()
            let inbox = try requiredPatternInboxFileService()
            return try await Task.detached(priority: .utility) {
                try inbox.items()
            }.value
        }
    }

    public func discardPatternInboxItem(id: UUID) async throws {
        try requireAccess(.importPattern)
        try await withActivePatternTransaction {
            try ensureArchiveAvailable()
            let inbox = try requiredPatternInboxFileService()
            try await Task.detached(priority: .utility) {
                guard let item = try inbox.item(id: id) else { return }
                try inbox.markCommitted(item)
                try inbox.cleanupCommitted(item)
            }.value
        }
    }

    public func importPatternFromLibrary(
        _ source: URL,
        folderID: UUID? = nil,
        now: Date = .now
    ) async throws -> PatternImportOutcome {
        let access = try preflightAccess(.importPattern)
        try ensureArchiveAvailable()
        _ = try requiredPatternFileService().inspect(source)
        try commitAccessIfNeeded(access, mutation: .importPattern)
        return try await enqueuePatternImport(
            source,
            origin: .library,
            targetProjectID: nil,
            targetFolderID: folderID,
            now: now
        )
    }

    @discardableResult
    public func createPatternFolder(
        name: String,
        nameContext: PatternFolderNameContext,
        now: Date = .now
    ) throws -> PatternFolder {
        let displayName = try PatternFolderNamePolicy.validatedName(
            name,
            folders: patternFolders,
            excluding: nil,
            nameContext: nameContext
        )
        let folder = PatternFolder(displayName: displayName, createdAt: now)
        try persist(
            projects: projects,
            yarns: yarns,
            patternFolders: patternFolders + [folder],
            patternFolderNameContext: nameContext
        )
        return folder
    }

    public func renamePatternFolder(
        id: UUID,
        to name: String,
        nameContext: PatternFolderNameContext
    ) throws {
        guard let index = patternFolders.firstIndex(where: { $0.id == id }) else {
            throw PatternFolderStoreError.folderNotFound
        }
        let displayName = try PatternFolderNamePolicy.validatedName(
            name,
            folders: patternFolders,
            excluding: id,
            nameContext: nameContext
        )
        var stagedFolders = patternFolders
        stagedFolders[index].displayName = displayName
        try persist(
            projects: projects,
            yarns: yarns,
            patternFolders: stagedFolders,
            patternFolderNameContext: nameContext
        )
    }

    public func movePattern(id: UUID, toFolderID folderID: UUID?) throws {
        guard let index = patterns.firstIndex(where: { $0.id == id }) else {
            throw PatternFolderStoreError.patternNotFound
        }
        if let folderID, !patternFolders.contains(where: { $0.id == folderID }) {
            throw PatternFolderStoreError.folderNotFound
        }
        guard patterns[index].folderID != folderID else { return }
        var stagedPatterns = patterns
        stagedPatterns[index].folderID = folderID
        try persist(projects: projects, yarns: yarns, patterns: stagedPatterns)
    }

    @discardableResult
    public func deletePatternFolder(id: UUID) throws -> Int {
        guard patternFolders.contains(where: { $0.id == id }) else {
            throw PatternFolderStoreError.folderNotFound
        }
        let movedCount = patterns.count(where: { $0.folderID == id })
        let stagedFolders = patternFolders.filter { $0.id != id }
        let stagedPatterns = patterns.map { pattern in
            guard pattern.folderID == id else { return pattern }
            var pattern = pattern
            pattern.folderID = nil
            return pattern
        }
        try persist(
            projects: projects,
            yarns: yarns,
            patternFolders: stagedFolders,
            patterns: stagedPatterns
        )
        return movedCount
    }

    public func importPatternFromProject(
        _ source: URL,
        projectID: UUID,
        now: Date = .now
    ) async throws -> PatternImportOutcome {
        let access = try preflightAccess(.importPattern)
        guard project(id: projectID) != nil else {
            throw PatternLibraryMutationError.projectNotFound
        }
        try ensureArchiveAvailable()
        _ = try requiredPatternFileService().inspect(source)
        try commitAccessIfNeeded(access, mutation: .importPattern)
        return try await enqueuePatternImport(
            source,
            origin: .project,
            targetProjectID: projectID,
            targetFolderID: nil,
            now: now
        )
    }

    public func addYouTubePattern(
        link: YouTubePatternLink,
        title: String,
        targetProjectID: UUID? = nil,
        targetFolderID: UUID? = nil,
        now: Date = .now
    ) async throws -> YouTubePatternAddResult {
        let access = try preflightAccess(.importPattern)
        return try await withActivePatternTransaction {
            try addYouTubePattern(
                link: link,
                title: title,
                targetProjectID: targetProjectID,
                targetFolderID: targetFolderID,
                now: now,
                access: access
            )
        }
    }

    private func addYouTubePattern(
        link: YouTubePatternLink,
        title: String,
        targetProjectID: UUID?,
        targetFolderID: UUID?,
        now: Date,
        access: FeatureAccessDecision
    ) throws -> YouTubePatternAddResult {
        try ensureArchiveAvailable()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw YouTubePatternStoreError.emptyTitle
        }
        if let targetProjectID, project(id: targetProjectID) == nil {
            throw PatternLibraryMutationError.projectNotFound
        }

        let metadata = YouTubePatternMetadata(link: link)
        let metadataData = try encodedYouTubeMetadata(metadata)
        let metadataSHA256 = SHA256.hash(data: metadataData)
            .map { String(format: "%02x", $0) }
            .joined()
        let files = try requiredPatternFileService()
        let matchingAssets = patternAssets.filter {
            $0.kind == .youtube && $0.sha256 == metadataSHA256
        }
        if let existingPattern = patterns.first(where: { pattern in
            matchingAssets.contains(where: { $0.id == pattern.assetID })
        }) {
            let usages = try addingUsage(
                for: existingPattern.id,
                targetProjectID: targetProjectID,
                to: patternUsages,
                now: now
            )
            if usages != patternUsages {
                try commitAccessIfNeeded(access, mutation: .importPattern)
                try persist(
                    projects: projects,
                    yarns: yarns,
                    patternAssets: patternAssets,
                    patterns: patterns,
                    patternUsages: usages
                )
            }
            return YouTubePatternAddResult(resolution: .existing, patternID: existingPattern.id)
        }

        let reusedAsset = matchingAssets.first
        let assetID = reusedAsset?.id ?? PatternImportCoordinator().deterministicAssetID(for: metadataSHA256)
        let proposedAsset = PatternAsset(
            id: assetID,
            sha256: metadataSHA256,
            kind: .youtube,
            storedFilename: "\(assetID.uuidString).youtube",
            byteCount: Int64(metadataData.count),
            pageCount: nil
        )
        let sidecarURL = try files.assetURL(proposedAsset)
        let sidecarAlreadyExisted = FileManager.default.fileExists(atPath: sidecarURL.path)
        try commitAccessIfNeeded(access, mutation: .importPattern)

        do {
            let asset: PatternAsset
            if let reusedAsset {
                asset = reusedAsset
            } else {
                asset = try files.storeYouTubeMetadata(metadata, assetID: assetID)
            }
            let pattern = StoredPattern(
                assetID: asset.id,
                displayName: trimmedTitle,
                createdAt: now,
                folderID: targetFolderID.flatMap { candidate in
                    patternFolders.contains(where: { $0.id == candidate }) ? candidate : nil
                }
            )
            let usages = try addingUsage(
                for: pattern.id,
                targetProjectID: targetProjectID,
                to: patternUsages,
                now: now
            )
            try persist(
                projects: projects,
                yarns: yarns,
                patternAssets: reusedAsset == nil ? patternAssets + [asset] : patternAssets,
                patterns: patterns + [pattern],
                patternUsages: usages
            )
            return YouTubePatternAddResult(resolution: .created, patternID: pattern.id)
        } catch {
            if reusedAsset == nil, !sidecarAlreadyExisted {
                try? files.deleteAsset(proposedAsset)
            }
            throw error
        }
    }

    private func enqueuePatternImport(
        _ source: URL,
        origin: PatternImportOrigin,
        targetProjectID: UUID?,
        targetFolderID: UUID?,
        now: Date
    ) async throws -> PatternImportOutcome {
        try await withActivePatternTransaction {
            try ensureArchiveAvailable()
            let inbox = try requiredPatternInboxFileService()
            let item = try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try inbox.enqueue(
                    source: source,
                    origin: origin,
                    targetProjectID: targetProjectID,
                    targetFolderID: targetFolderID,
                    now: now
                )
            }.value
            try Task.checkCancellation()
            return try await processPatternInboxItemWithoutTransaction(
                id: item.id,
                duplicateResolution: .automatic,
                access: .allow
            )
        }
    }
    public func deletePattern(projectID: UUID, id: UUID) throws {
        try requireAccess(.editPattern)
        try ensureArchiveAvailable()
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              let pattern = projects[projectIndex].patterns.first(where: { $0.id == id }) else {
            return
        }
        activePatternTransactions += 1
        defer { activePatternTransactions -= 1 }
        let markupDeleteMutations = try syncLegacyMarkupDeleteMutations(
            projectID: projectID,
            patternIDs: [id]
        )
        var staged = projects
        staged[projectIndex].deletePattern(id: id)
        try persist(
            projects: staged,
            yarns: yarns,
            additionalSyncMutations: markupDeleteMutations
        )
        try? requiredPatternFileService().delete(projectID: projectID, pattern: pattern)
        try? patternMarkupFileService.deleteLegacyMarkup(
            projectID: projectID,
            patternID: pattern.id
        )
    }

    @discardableResult
    public func linkPattern(patternID: UUID, to projectID: UUID) throws -> PatternProjectUsage {
        try requireAccess(.linkPattern)
        try ensureArchiveAvailable()
        guard patterns.contains(where: { $0.id == patternID }) else {
            throw PatternLibraryMutationError.patternNotFound
        }
        guard projects.contains(where: { $0.id == projectID }) else {
            throw PatternLibraryMutationError.projectNotFound
        }
        if let index = patternUsages.firstIndex(where: {
            $0.patternID == patternID && $0.projectID == projectID
        }) {
            guard !patternUsages[index].isActive else { return patternUsages[index] }
            var staged = patternUsages
            staged[index].isActive = true
            staged[index].unlinkedAt = nil
            try persist(projects: projects, yarns: yarns, patternUsages: staged)
            return staged[index]
        }
        let nextSortOrder = (patternUsages.filter { $0.projectID == projectID }
            .map(\.sortOrder).max() ?? -1) + 1
        let usage = PatternProjectUsage(
            patternID: patternID,
            projectID: projectID,
            sortOrder: nextSortOrder
        )
        try persist(
            projects: projects,
            yarns: yarns,
            patternUsages: patternUsages + [usage]
        )
        return usage
    }

    public func unlinkPattern(patternID: UUID, from projectID: UUID) throws {
        try requireAccess(.linkPattern)
        try ensureArchiveAvailable()
        guard let index = patternUsages.firstIndex(where: {
            $0.patternID == patternID && $0.projectID == projectID
        }) else {
            return
        }
        guard patternUsages[index].isActive else { return }
        var staged = patternUsages
        staged[index].isActive = false
        staged[index].unlinkedAt = .now
        try persist(projects: projects, yarns: yarns, patternUsages: staged)
    }

    public func deletePatternPermanently(id: UUID) throws {
        try requireAccess(.editPattern)
        try ensureArchiveAvailable()
        guard let pattern = patterns.first(where: { $0.id == id }) else {
            throw PatternLibraryMutationError.patternNotFound
        }
        let usagesToDelete = patternUsages.filter { $0.patternID == id }
        let markupDeleteMutations = try syncUsageMarkupDeleteMutations(
            usageIDs: usagesToDelete.map(\.id)
        )
        let activeProjectIDs = usagesToDelete.filter(\.isActive).map(\.projectID)
            .sorted { $0.uuidString < $1.uuidString }
        guard activeProjectIDs.isEmpty else {
            throw PatternLibraryMutationError.activeLinksExist(activeProjectIDs)
        }
        let assetIsUnreferenced = !patterns.contains { $0.id != id && $0.assetID == pattern.assetID }
        let asset = assetIsUnreferenced
            ? patternAssets.first(where: { $0.id == pattern.assetID })
            : nil
        let files = try requiredPatternFileService()
        let deletion = try PatternLibraryDeletionTransaction.begin(
            root: files.root,
            markupService: patternMarkupFileService,
            usageIDs: usagesToDelete.map(\.id),
            asset: asset,
            fileService: files
        )
        do {
            try persist(
                projects: projects,
                yarns: yarns,
                patternAssets: assetIsUnreferenced
                    ? patternAssets.filter { $0.id != pattern.assetID }
                    : patternAssets,
                patterns: patterns.filter { $0.id != id },
                patternUsages: patternUsages.filter { $0.patternID != id },
                additionalSyncMutations: markupDeleteMutations,
                beforeArchiveWrite: { try deletion.stage() }
            )
        } catch {
            try deletion.rollback()
            throw error
        }
        try deletion.publish()
        try deletion.commit()
        if assetIsUnreferenced, let asset {
            try? patternThumbnailService.delete(assetID: asset.id)
        }
    }

    public func renamePattern(id: UUID, to name: String) throws {
        try requireAccess(.editPattern)
        try ensureArchiveAvailable()
        guard let index = patterns.firstIndex(where: { $0.id == id }) else {
            throw PatternLibraryMutationError.patternNotFound
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var staged = patterns
        staged[index].displayName = trimmed
        try persist(projects: projects, yarns: yarns, patterns: staged)
    }

    public func setPatternNote(id: UUID, note: String?) throws {
        try requireAccess(.editPattern)
        try ensureArchiveAvailable()
        guard let index = patterns.firstIndex(where: { $0.id == id }) else {
            throw PatternLibraryMutationError.patternNotFound
        }
        var staged = patterns
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        staged[index].note = trimmed.isEmpty ? nil : trimmed
        try persist(projects: projects, yarns: yarns, patterns: staged)
    }

    @discardableResult
    public func setPatternPrefersOriginalColorsInDarkMode(
        id: UUID,
        prefersOriginalColors: Bool,
        expectedDataGeneration: UInt64
    ) throws -> UInt64 {
        try ensureArchiveAvailable()
        guard dataGeneration == expectedDataGeneration else {
            throw ProjectStoreError.staleDataGeneration
        }
        guard let index = patterns.firstIndex(where: { $0.id == id }) else {
            throw PatternLibraryMutationError.patternNotFound
        }
        guard patterns[index].prefersOriginalColorsInDarkMode != prefersOriginalColors else {
            return dataGeneration
        }
        var staged = patterns
        staged[index].prefersOriginalColorsInDarkMode = prefersOriginalColors
        try persist(projects: projects, yarns: yarns, patterns: staged)
        return dataGeneration
    }

    public func markPatternOpened(id: UUID, at date: Date = .now) throws {
        try requireAccess(.recordPatternBrowsing)
        try ensureArchiveAvailable()
        guard let index = patterns.firstIndex(where: { $0.id == id }) else {
            throw PatternLibraryMutationError.patternNotFound
        }
        var staged = patterns
        staged[index].lastOpenedAt = date
        try persist(projects: projects, yarns: yarns, patterns: staged)
    }

    public func patternAssetURL(patternID: UUID) throws -> URL {
        try ensureArchiveAvailable()
        guard let pattern = patterns.first(where: { $0.id == patternID }),
              let asset = patternAssets.first(where: { $0.id == pattern.assetID }) else {
            throw PatternLibraryMutationError.patternNotFound
        }
        return try requiredPatternFileService().assetURL(asset)
    }

    public func youtubeLink(patternID: UUID) throws -> YouTubePatternLink {
        try ensureArchiveAvailable()
        guard let pattern = patterns.first(where: { $0.id == patternID }),
              let asset = patternAssets.first(where: { $0.id == pattern.assetID }) else {
            throw PatternLibraryMutationError.patternNotFound
        }
        guard asset.kind == .youtube else {
            throw PatternFileError.invalidContent
        }
        return try requiredPatternFileService().youtubeMetadata(for: asset).validated()
    }

    /// Remote artwork is auxiliary presentation data: the durable YouTube
    /// pattern is saved first, and a cache failure never rolls it back.
    public func cacheYouTubeThumbnail(_ data: Data, patternID: UUID) async {
        guard let pattern = patterns.first(where: { $0.id == patternID }),
              let asset = patternAssets.first(where: { $0.id == pattern.assetID }),
              asset.kind == .youtube else {
            return
        }
        let assetID = asset.id
        let service = patternThumbnailService
        let stagedURL = await Task.detached(priority: .utility) {
            try? service.stageExternalThumbnail(data: data, assetID: assetID)
        }.value
        guard let stagedURL else { return }
        await afterYouTubeThumbnailStage()
        guard
              let currentPattern = patterns.first(where: { $0.id == patternID }),
              currentPattern.assetID == assetID,
              patternAssets.contains(where: { $0.id == assetID && $0.kind == .youtube }) else {
            try? service.discardExternalThumbnailStage(stagedURL)
            return
        }
        do {
            _ = try service.publishExternalThumbnail(stagedURL: stagedURL, assetID: assetID)
        } catch {
            try? service.discardExternalThumbnailStage(stagedURL)
        }
    }

    public func patternThumbnailURL(patternID: UUID) async -> URL? {
        guard loadError == nil,
              let pattern = patterns.first(where: { $0.id == patternID }),
              let asset = patternAssets.first(where: { $0.id == pattern.assetID })
        else { return nil }
        let service = patternThumbnailService
        if asset.kind == .youtube {
            let cachedURL = service.cachedURL(assetID: asset.id)
            return FileManager.default.fileExists(atPath: cachedURL.path) ? cachedURL : nil
        }
        guard let sourceURL = try? requiredPatternFileService().assetURL(asset) else {
            return nil
        }
        return await Task.detached(priority: .utility) {
            try? service.thumbnailURL(asset: asset, sourceURL: sourceURL)
        }.value
    }

    public func patternPDFPageThumbnailURL(
        assetID: UUID,
        pageIndex: Int
    ) async -> URL? {
        guard !Task.isCancelled,
              let asset = patternAssets.first(where: { $0.id == assetID }),
              asset.kind == .pdf,
              let pageCount = asset.pageCount,
              pageIndex >= 0,
              pageIndex < pageCount,
              let sourceURL = try? requiredPatternFileService().assetURL(asset)
        else { return nil }
        let generateThumbnailURL = patternPDFPageThumbnailURLGenerator
        let renderingTask = Task.detached(priority: .utility) { () -> URL? in
            guard !Task.isCancelled else { return nil }
            return generateThumbnailURL(asset, sourceURL, pageIndex)
        }
        let thumbnailURL = await withTaskCancellationHandler {
            await renderingTask.value
        } onCancel: {
            renderingTask.cancel()
        }
        guard !Task.isCancelled,
              let currentAsset = patternAssets.first(where: { $0.id == asset.id }),
              currentAsset.sha256 == asset.sha256,
              currentAsset.kind == asset.kind,
              currentAsset.pageCount == asset.pageCount
        else { return nil }
        return thumbnailURL
    }

    @discardableResult
    public func updatePatternState(
        usageID: UUID,
        state: PatternReadingState,
        expectedDataGeneration: UInt64? = nil
    ) throws -> UInt64 {
        try updatePatternState(
            usageID: usageID,
            state: state,
            expectedDataGeneration: expectedDataGeneration,
            mutation: .editPatternReadingState
        )
    }

    @discardableResult
    public func updatePatternBrowsingState(
        usageID: UUID,
        state: PatternBrowsingState,
        expectedDataGeneration: UInt64? = nil
    ) throws -> UInt64 {
        try requireAccess(.recordPatternBrowsing)
        try validateExpectedDataGeneration(expectedDataGeneration)
        let index = try mutableUsageIndex(usageID: usageID)
        var staged = patternUsages
        staged[index].updateBrowsingState(state)
        try persist(projects: projects, yarns: yarns, patternUsages: staged)
        return dataGeneration
    }

    private func updatePatternState(
        usageID: UUID,
        state: PatternReadingState,
        expectedDataGeneration: UInt64?,
        mutation: FeatureMutation
    ) throws -> UInt64 {
        try requireAccess(mutation)
        try validateExpectedDataGeneration(expectedDataGeneration)
        let index = try mutableUsageIndex(usageID: usageID)
        var staged = patternUsages
        staged[index].updateReadingState(state)
        try persist(projects: projects, yarns: yarns, patternUsages: staged)
        return dataGeneration
    }

    @discardableResult
    public func savePatternPageNote(
        usageID: UUID,
        pageIndex: Int,
        text: String,
        expectedDataGeneration: UInt64? = nil
    ) throws -> UInt64 {
        try requireAccess(.editPatternReadingState)
        try validateExpectedDataGeneration(expectedDataGeneration)
        let index = try mutableUsageIndex(usageID: usageID)
        var staged = patternUsages
        let page = max(0, pageIndex)
        var state = staged[index].readingState
        if state.pageIndex == page {
            state.setPageNote(text)
        } else {
            let existing = state.pageStates[page]
            state.pageStates[page] = PatternPageState(
                horizontalPosition: existing?.horizontalPosition ?? 0.5,
                verticalPosition: existing?.verticalPosition ?? 0.5,
                note: text
            )
        }
        staged[index].updateReadingState(state)
        try persist(projects: projects, yarns: yarns, patternUsages: staged)
        return dataGeneration
    }

    public func loadPatternMarkup(
        usageID: UUID,
        pageIndex: Int
    ) throws -> PatternMarkupDocument {
        guard patternUsages.contains(where: { $0.id == usageID }) else {
            throw PatternLibraryMutationError.usageNotFound
        }
        return try patternMarkupFileService.load(usageID: usageID, pageIndex: pageIndex)
    }

    @discardableResult
    public func savePatternMarkup(
        _ document: PatternMarkupDocument,
        usageID: UUID,
        pageIndex: Int,
        expectedDataGeneration: UInt64
    ) throws -> UInt64 {
        try requireAccess(.editPatternReadingState)
        try validateExpectedDataGeneration(expectedDataGeneration)
        _ = try mutableUsageIndex(usageID: usageID)
        try ensureSyncPublicationReady()
        activePatternTransactions += 1
        defer { activePatternTransactions -= 1 }
        let page = max(0, pageIndex)
        let snapshot = try patternMarkupFileService.snapshot(usageID: usageID, pageIndex: page)
        let pageURL = try patternMarkupFileService.usagePageURL(
            usageID: usageID,
            pageIndex: page
        )
        let encodedPage = try patternMarkupFileService.encodedPageData(document)
        let originalPageData: Data?
        switch snapshot {
        case .missing: originalPageData = nil
        case let .bytes(data): originalPageData = data
        }
        let markupSlot = try canonicalMarkupSlot(owner: .init(kind: .patternUsage, uuid: usageID),
            preferredRole: "usage-markup", compatibleRole: "pattern-markup", slotID: "page:\(page)")
        let mutation = try syncAttachmentMutation(
            owner: markupSlot.owner,
            role: markupSlot.role,
            slotID: markupSlot.slotID,
            originalData: originalPageData,
            committedData: encodedPage,
            replacesVersion: syncAttachmentPublicationEvidence.version(for: markupSlot),
            replacesRecord: syncAttachmentPublicationEvidence.record(for: markupSlot),
            sourceURL: pageURL,
            mediaType: "application/json",
            displayFilename: "\(page).json",
            deviceID: syncPublicationDeviceID
        )
        let evidence = try SyncPublicationArtifactEvidence(
            relativePath: syncArtifactRelativePath(for: pageURL),
            expectedSHA256: encodedPage.map(SyncPublicationTransactionFile.fingerprint(of:))
        )
        let markupService = patternMarkupFileService
        do {
            // The archive write advances a durable shared revision for markup,
            // allowing concurrent readers to use the same optimistic lock.
            try persist(
                projects: projects,
                yarns: yarns,
                patternUsages: patternUsages,
                additionalSyncMutations: mutation.map { [$0] } ?? [],
                syncCommitBoundary: .artifacts,
                additionalArtifactEvidence: [evidence],
                commitArtifacts: {
                    try markupService.save(
                        document,
                        usageID: usageID,
                        pageIndex: page
                    )
                }
            )
        } catch {
            try patternMarkupFileService.restore(snapshot, usageID: usageID, pageIndex: page)
            throw error
        }
        return dataGeneration
    }
    @discardableResult
    public func savePatternPageNote(
        projectID: UUID,
        patternID: UUID,
        pageIndex: Int,
        text: String,
        expectedDataGeneration: UInt64? = nil
    ) throws -> UInt64 {
        try requireAccess(.editPatternReadingState)
        try validateExpectedDataGeneration(expectedDataGeneration)
        try ensureLegacyPatternReaderWriteAllowed(projectID: projectID)
        try mutate(id: projectID) {
            $0.savePatternPageNote(patternID: patternID, pageIndex: pageIndex, text: text)
        }
        return dataGeneration
    }
    public func updatePatternState(projectID: UUID, id: UUID, pageIndex: Int, highlightPosition: Double) throws {
        try requireAccess(.editPatternReadingState)
        try ensureLegacyPatternReaderWriteAllowed(projectID: projectID)
        try mutate(id: projectID) { $0.updatePatternState(id: id, pageIndex: pageIndex, highlightPosition: highlightPosition) }
    }
    @discardableResult
    public func updatePatternState(
        projectID: UUID,
        id: UUID,
        state: PatternReadingState,
        expectedDataGeneration: UInt64? = nil
    ) throws -> UInt64 {
        try updatePatternState(
            projectID: projectID,
            id: id,
            state: state,
            expectedDataGeneration: expectedDataGeneration,
            mutation: .editPatternReadingState
        )
    }

    @discardableResult
    public func updatePatternBrowsingState(
        projectID: UUID,
        id: UUID,
        state: PatternBrowsingState,
        expectedDataGeneration: UInt64? = nil
    ) throws -> UInt64 {
        try requireAccess(.recordPatternBrowsing)
        try validateExpectedDataGeneration(expectedDataGeneration)
        try ensureLegacyPatternReaderWriteAllowed(projectID: projectID)
        try mutate(id: projectID) {
            $0.updatePatternBrowsingState(id: id, state: state)
        }
        return dataGeneration
    }

    private func updatePatternState(
        projectID: UUID,
        id: UUID,
        state: PatternReadingState,
        expectedDataGeneration: UInt64?,
        mutation: FeatureMutation
    ) throws -> UInt64 {
        try requireAccess(mutation)
        try validateExpectedDataGeneration(expectedDataGeneration)
        try ensureLegacyPatternReaderWriteAllowed(projectID: projectID)
        try mutate(id: projectID) { $0.updatePatternState(id: id, state: state) }
        return dataGeneration
    }
    public func patternURL(projectID: UUID, pattern: PatternDocument) -> URL {
        patternFileService?.url(projectID: projectID, pattern: pattern)
            ?? url.deletingLastPathComponent().appendingPathComponent("Patterns", isDirectory: true)
                .appendingPathComponent(projectID.uuidString, isDirectory: true)
                .appendingPathComponent(pattern.storedFilename)
    }
    public func loadPatternMarkup(
        projectID: UUID,
        patternID: UUID,
        pageIndex: Int
    ) throws -> PatternMarkupDocument {
        try patternMarkupFileService.load(
            projectID: projectID,
            patternID: patternID,
            pageIndex: pageIndex
        )
    }
    @discardableResult
    public func savePatternMarkup(
        _ document: PatternMarkupDocument,
        projectID: UUID,
        patternID: UUID,
        pageIndex: Int,
        expectedDataGeneration: UInt64
    ) throws -> UInt64 {
        try requireAccess(.editPatternReadingState)
        try ensureArchiveAvailable()
        try ensureSyncPublicationReady()
        try validateExpectedDataGeneration(expectedDataGeneration)
        guard let project = project(id: projectID),
              project.patterns.contains(where: { $0.id == patternID }) else {
            throw ProjectStoreError.patternNotFound
        }
        guard !project.isCompleted else {
            throw PatternLibraryMutationError.projectCompleted
        }
        activePatternTransactions += 1
        defer { activePatternTransactions -= 1 }
        let page = max(0, pageIndex)
        let snapshot = try patternMarkupFileService.snapshot(
            projectID: projectID,
            patternID: patternID,
            pageIndex: page
        )
        let pageURL = try patternMarkupFileService.legacyPageURL(
            projectID: projectID,
            patternID: patternID,
            pageIndex: page
        )
        let encodedPage = try patternMarkupFileService.encodedPageData(document)
        let originalPageData: Data?
        switch snapshot {
        case .missing: originalPageData = nil
        case let .bytes(data): originalPageData = data
        }
        let markupSlot = try canonicalMarkupSlot(owner: .init(kind: .pattern, uuid: patternID),
            preferredRole: "legacy-markup", compatibleRole: "legacy-pattern-markup",
            slotID: "project:\(projectID.uuidString)/page:\(page)")
        let mutation = try syncAttachmentMutation(
            owner: markupSlot.owner,
            role: markupSlot.role,
            slotID: markupSlot.slotID,
            originalData: originalPageData,
            committedData: encodedPage,
            replacesVersion: syncAttachmentPublicationEvidence.version(for: markupSlot),
            replacesRecord: syncAttachmentPublicationEvidence.record(for: markupSlot),
            sourceURL: pageURL,
            mediaType: "application/json",
            displayFilename: "\(page).json",
            deviceID: syncPublicationDeviceID
        )
        let evidence = try SyncPublicationArtifactEvidence(
            relativePath: syncArtifactRelativePath(for: pageURL),
            expectedSHA256: encodedPage.map(SyncPublicationTransactionFile.fingerprint(of:))
        )
        let archiveData = try Data(contentsOf: url)
        let markupService = patternMarkupFileService
        var mutations = mutation.map { [$0] } ?? []
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: archiveData)
        let retention = try stageSyncDeletion(before: archive, after: archive, mutations: &mutations,
            artifactRemovals: encodedPage == nil ? [evidence.relativePath] : [])
        do {
            try commitArchiveAndPublish(
                data: archiveData,
                mutations: mutations,
                commitBoundary: .artifacts,
                artifactEvidence: [evidence],
                deletionRetention: retention,
                shouldWriteArchive: false,
                commitArtifacts: {
                    try markupService.save(
                        document,
                        projectID: projectID,
                        patternID: patternID,
                        pageIndex: page
                    )
                },
                applyCommittedState: {}
            )
        } catch {
            try patternMarkupFileService.restore(
                snapshot,
                projectID: projectID,
                patternID: patternID,
                pageIndex: page
            )
            throw error
        }
        return dataGeneration
    }
    public func project(id: UUID) -> StoredProject? { projects.first { $0.id == id } }
    public func addJournalEntry(
        projectID: UUID,
        photoData: Data,
        caption: String?,
        createdAt: Date = .now
    ) async throws {
        try requireAccess(.editJournal)
        guard let project = projects.first(where: { $0.id == projectID }) else {
            throw ProjectJournalMutationError.entryNotFound
        }
        guard !project.isCompleted else {
            throw ProjectJournalMutationError.projectCompleted
        }
        try ensureArchiveAvailable()
        try Task.checkCancellation()
        activeJournalPhotoTransactions += 1
        defer {
            activeJournalPhotoTransactions -= 1
            if activeJournalPhotoTransactions == 0 {
                reconcileJournalPhotos()
            }
        }

        let entryID = UUID()
        let service = journalPhotoService
        let processingTask = Task.detached(priority: .userInitiated) {
            try service.save(data: photoData, projectID: projectID, entryID: entryID)
        }
        let files = try await withTaskCancellationHandler {
            try await processingTask.value
        } onCancel: {
            processingTask.cancel()
        }

        do {
            try Task.checkCancellation()
            let entry = try ProjectJournalEntry(
                id: entryID,
                photoFilename: files.photoFilename,
                thumbnailFilename: files.thumbnailFilename,
                caption: caption,
                createdAt: createdAt
            )
            guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
                throw ProjectJournalMutationError.entryNotFound
            }
            guard !projects[projectIndex].isCompleted else {
                throw ProjectJournalMutationError.projectCompleted
            }
            var staged = projects
            try staged[projectIndex].addJournalEntry(entry, now: createdAt)
            try persist(projects: staged, yarns: yarns)
        } catch {
            try? journalPhotoService.delete(files: files)
            throw error
        }
    }
    public func updateJournalCaption(projectID: UUID, entryID: UUID, caption: String?) throws {
        try requireAccess(.editJournal)
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
            throw ProjectJournalMutationError.entryNotFound
        }
        var staged = projects
        try staged[projectIndex].updateJournalCaption(id: entryID, caption: caption)
        try persist(projects: staged, yarns: yarns)
    }
    public func deleteJournalEntry(projectID: UUID, entryID: UUID) throws {
        try requireAccess(.editJournal)
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
            throw ProjectJournalMutationError.entryNotFound
        }
        var staged = projects
        let removed = try staged[projectIndex].deleteJournalEntry(id: entryID)
        try persist(projects: staged, yarns: yarns)
        deleteJournalPhotosIfUnreferenced([
            removed.photoFilename,
            removed.thumbnailFilename,
        ])
    }
    public func addYarn(_ yarn: StoredYarn) throws {
        try addYarn(yarn, photoData: nil)
    }
    public func addYarn(_ yarn: StoredYarn, photoData: Data?) throws {
        try addYarn(yarn, photoData: photoData, labelPhotos: [])
    }
    public func addYarn(
        _ yarn: StoredYarn,
        photoData: Data?,
        labelPhotos: [Data]
    ) throws {
        try requireAccess(.createYarn)
        guard labelPhotos.count <= 2 else {
            throw YarnLabelPhotoFileError.invalidOrdinal
        }
        var yarn = yarn
        try validateYarnProjectChange(
            from: [],
            to: yarn.linkedProjectIDs,
            missingProjectError: ProjectStoreError.invalidYarnProjectLinks
        )
        var newFilename: String?
        var preparedLabels: [PreparedYarnLabelPhoto] = []
        var publishedLabelFilenames: [String] = []
        do {
            if photoData != nil || !labelPhotos.isEmpty {
                try ensureArchiveAvailable()
            }
            if let photoData {
                newFilename = try yarnPhotoService.save(data: photoData, yarnID: yarn.id)
                yarn.setPhotoFilename(newFilename)
            }
            preparedLabels = try prepareLabelPhotos(
                labelPhotos.enumerated().map { ($0.element, $0.offset + 1) },
                yarnID: yarn.id
            )
            publishedLabelFilenames = try publishLabelPhotos(preparedLabels)
            try yarn.setLabelPhotoFilenames(publishedLabelFilenames)
            try persist(projects: projects, yarns: yarns + [yarn])
            if !publishedLabelFilenames.isEmpty {
                notifyYarnLabelPhotosDidChange()
            }
        } catch {
            if let newFilename { try? yarnPhotoService.delete(filename: newFilename) }
            rollbackLabelPhotos(
                prepared: preparedLabels,
                publishedFilenames: publishedLabelFilenames
            )
            throw error
        }
    }
    public func updateYarn(_ yarn: StoredYarn) throws {
        try updateYarn(yarn, photoChange: .unchanged)
    }
    public func updateYarn(_ yarn: StoredYarn, photoChange: YarnPhotoChange) throws {
        try updateYarn(
            yarn,
            photoChange: photoChange,
            labelPhotoChange: .unchanged
        )
    }
    public func updateYarn(
        _ yarn: StoredYarn,
        photoChange: YarnPhotoChange,
        labelPhotoChange: YarnLabelPhotoChange
    ) throws {
        try requireAccess(.editYarn)
        guard let index = yarns.firstIndex(where: { $0.id == yarn.id }) else { return }
        try validateYarnProjectChange(
            from: yarns[index].linkedProjectIDs,
            to: yarn.linkedProjectIDs,
            missingProjectError: ProjectStoreError.invalidYarnProjectLinks
        )
        let oldFilename = yarns[index].photoFilename
        let oldLabelFilenames = yarns[index].labelPhotoFilenames
        var updated = yarn
        var newFilename: String?
        var preparedLabels: [PreparedYarnLabelPhoto] = []
        var publishedLabelFilenames: [String] = []
        do {
            switch photoChange {
            case .unchanged:
                updated.setPhotoFilename(oldFilename, now: updated.updatedAt)
            case let .replace(data):
                try ensureArchiveAvailable()
                newFilename = try yarnPhotoService.save(data: data, yarnID: yarn.id)
                updated.setPhotoFilename(newFilename)
            case .remove:
                updated.setPhotoFilename(nil)
            }
            switch labelPhotoChange {
            case .unchanged:
                try updated.setLabelPhotoFilenames(oldLabelFilenames, now: updated.updatedAt)
            case let .replace(first, second):
                try ensureArchiveAvailable()
                var labelPhotos: [(Data, Int)] = []
                if let first { labelPhotos.append((first, 1)) }
                if let second { labelPhotos.append((second, 2)) }
                preparedLabels = try prepareLabelPhotos(labelPhotos, yarnID: yarn.id)
                publishedLabelFilenames = try publishLabelPhotos(preparedLabels)
                try updated.setLabelPhotoFilenames(publishedLabelFilenames)
            case let .retainExisting(filenames):
                guard Set(filenames).isSubset(of: Set(oldLabelFilenames)) else {
                    throw YarnLabelPhotoFileError.invalidFilename
                }
                try updated.setLabelPhotoFilenames(filenames)
            case .removeAll:
                try updated.setLabelPhotoFilenames([])
            }
            var staged = yarns
            staged[index] = updated
            try persist(projects: projects, yarns: staged)
        } catch {
            if let newFilename { try? yarnPhotoService.delete(filename: newFilename) }
            rollbackLabelPhotos(
                prepared: preparedLabels,
                publishedFilenames: publishedLabelFilenames
            )
            throw error
        }
        if let oldFilename, oldFilename != updated.photoFilename {
            try? yarnPhotoService.delete(filename: oldFilename)
        }
        for filename in oldLabelFilenames where !updated.labelPhotoFilenames.contains(filename) {
            try? yarnLabelPhotoService.delete(filename: filename)
        }
        if oldLabelFilenames != updated.labelPhotoFilenames {
            notifyYarnLabelPhotosDidChange()
        }
    }
    public func deleteYarn(id: UUID) throws {
        try requireAccess(.deleteYarn)
        guard let yarn = yarns.first(where: { $0.id == id }) else { return }
        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        guard yarn.linkedProjectIDs.allSatisfy({ projectsByID[$0]?.isCompleted != true }) else {
            throw ProjectYarnLinkError.projectCompleted
        }
        let filename = yarn.photoFilename
        let labelFilenames = yarn.labelPhotoFilenames
        try persist(projects: projects, yarns: yarns.filter { $0.id != id })
        if let filename { try? yarnPhotoService.delete(filename: filename) }
        for labelFilename in labelFilenames {
            try? yarnLabelPhotoService.delete(filename: labelFilename)
        }
        if !labelFilenames.isEmpty {
            notifyYarnLabelPhotosDidChange()
        }
    }
    public func yarn(id: UUID) -> StoredYarn? { yarns.first { $0.id == id } }
    public func labelPhotoURL(filename: String) -> URL? {
        guard let url = yarnLabelPhotoService.url(filename: filename),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    public func labelPhotoURLs(for yarn: StoredYarn) -> [URL] {
        yarn.labelPhotoFilenames.compactMap(labelPhotoURL(filename:))
    }

    public func yarnLabelPhotoStorageBytes() async throws -> Int64 {
        let service = yarnLabelPhotoService
        return try await Task.detached(priority: .utility) {
            try service.totalStorageBytes()
        }.value
    }

    public func yarns(linkedTo projectID: UUID) -> [StoredYarn] {
        yarns.filter { $0.linkedProjectIDs.contains(projectID) }
    }

    public func setProjectYarns(projectID: UUID, yarnIDs: Set<UUID>) throws {
        try requireAccess(.linkYarn)
        guard let project = project(id: projectID) else {
            throw ProjectYarnLinkError.projectNotFound
        }
        guard !project.isCompleted else {
            throw ProjectYarnLinkError.projectCompleted
        }
        guard yarnIDs.isSubset(of: Set(yarns.map(\.id))) else {
            throw ProjectYarnLinkError.yarnNotFound
        }

        let now = Date.now
        var staged = yarns
        for index in staged.indices {
            var linkedProjectIDs = staged[index].linkedProjectIDs
            if yarnIDs.contains(staged[index].id) {
                linkedProjectIDs.insert(projectID)
            } else {
                linkedProjectIDs.remove(projectID)
            }
            staged[index].setLinkedProjectIDs(linkedProjectIDs, now: now)
        }
        try persist(projects: projects, yarns: staged)
    }

    public func setYarnProjects(yarnID: UUID, projectIDs: Set<UUID>) throws {
        try requireAccess(.linkYarn)
        guard let index = yarns.firstIndex(where: { $0.id == yarnID }) else { return }
        try validateYarnProjectChange(
            from: yarns[index].linkedProjectIDs,
            to: projectIDs,
            missingProjectError: ProjectYarnLinkError.projectNotFound
        )
        var staged = yarns
        staged[index].setLinkedProjectIDs(projectIDs)
        try persist(projects: projects, yarns: staged)
    }

    private func validateYarnProjectChange(
        from originalProjectIDs: Set<UUID>,
        to requestedProjectIDs: Set<UUID>,
        missingProjectError: any Error
    ) throws {
        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        guard requestedProjectIDs.allSatisfy({ projectsByID[$0] != nil }) else {
            throw missingProjectError
        }
        let changedProjectIDs = originalProjectIDs.symmetricDifference(requestedProjectIDs)
        guard changedProjectIDs.allSatisfy({ projectsByID[$0]?.isCompleted != true }) else {
            throw ProjectYarnLinkError.projectCompleted
        }
    }
    public func photoURL(for project: StoredProject) -> URL? { project.photoFilename.map(photoService.url(filename:)) }
    public func projectCoverURL(for project: StoredProject) async -> URL? {
        if let photoURL = photoURL(for: project) {
            return photoURL
        }
        guard let usage = patternUsages
            .filter({ $0.projectID == project.id && $0.isActive })
            .sorted(by: { lhs, rhs in
                lhs.sortOrder == rhs.sortOrder
                    ? lhs.id.uuidString < rhs.id.uuidString
                    : lhs.sortOrder < rhs.sortOrder
            })
            .first,
            let pattern = patterns.first(where: { $0.id == usage.patternID }),
            let asset = patternAssets.first(where: { $0.id == pattern.assetID }),
            let files = patternFileService,
            let sourceURL = try? files.assetURL(asset)
        else { return nil }
        let service = patternThumbnailService
        return await Task.detached(priority: .utility) {
            try? service.thumbnailURL(
                asset: asset,
                sourceURL: sourceURL
            )
        }.value
    }
    public func photoURL(for yarn: StoredYarn) -> URL? { yarn.photoFilename.map(yarnPhotoService.url(filename:)) }
    public func journalPhotoURL(for entry: ProjectJournalEntry) -> URL? {
        journalPhotoService.url(filename: entry.photoFilename)
    }
    public func journalThumbnailURL(for entry: ProjectJournalEntry) -> URL? {
        journalPhotoService.url(filename: entry.thumbnailFilename)
    }

    private func prepareLabelPhotos(
        _ photos: [(data: Data, ordinal: Int)],
        yarnID: UUID
    ) throws -> [PreparedYarnLabelPhoto] {
        var prepared: [PreparedYarnLabelPhoto] = []
        do {
            for photo in photos {
                prepared.append(try yarnLabelPhotoService.prepare(
                    data: photo.data,
                    yarnID: yarnID,
                    ordinal: photo.ordinal
                ))
            }
            return prepared
        } catch {
            for item in prepared { try? yarnLabelPhotoService.rollback(item) }
            throw error
        }
    }

    private func publishLabelPhotos(
        _ prepared: [PreparedYarnLabelPhoto]
    ) throws -> [String] {
        var publishedFilenames: [String] = []
        do {
            for item in prepared {
                try yarnLabelPhotoService.publish(item)
                publishedFilenames.append(item.filename)
            }
            return publishedFilenames
        } catch {
            rollbackLabelPhotos(
                prepared: prepared,
                publishedFilenames: publishedFilenames
            )
            throw error
        }
    }

    private func rollbackLabelPhotos(
        prepared: [PreparedYarnLabelPhoto],
        publishedFilenames: [String]
    ) {
        for item in prepared { try? yarnLabelPhotoService.rollback(item) }
        for filename in publishedFilenames {
            try? yarnLabelPhotoService.delete(filename: filename)
        }
    }

    func watchAcknowledgement(
        for commandID: UUID,
        rejection: WatchCommandRejection?,
        entitlement: EntitlementSnapshot,
        now: Date
    ) throws -> WatchCommandAcknowledgement {
        WatchCommandAcknowledgement(
            commandID: commandID,
            rejection: rejection,
            snapshot: try WatchSnapshotBuilder.make(
                projects: projects,
                entitlement: entitlement,
                locale: .current,
                generatedAt: now
            )
        )
    }
    private func mutate(id: UUID, _ body: (inout StoredProject) throws -> Void) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        var staged = projects
        try body(&staged[index])
        try persist(projects: staged, yarns: yarns)
    }

    private func mutateCounter(
        id: UUID,
        _ body: (inout StoredProject) -> StoredProjectCounterMutationResult?
    ) throws -> StoredProjectCounterMutationResult? {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return nil }
        var staged = projects
        let result = body(&staged[index])
        try result?.validateKnittingReminderEvaluation()
        try persist(projects: staged, yarns: yarns)
        return result
    }

    private func mutateActiveCounterProject(
        id: UUID,
        _ body: (inout StoredProject) -> Bool
    ) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        guard !projects[index].isCompleted else {
            throw PatternLibraryMutationError.projectCompleted
        }
        var staged = projects
        guard body(&staged[index]) else { return }
        try persist(projects: staged, yarns: yarns)
    }

    private func mutableUsageIndex(usageID: UUID) throws -> Int {
        guard let index = patternUsages.firstIndex(where: { $0.id == usageID }) else {
            throw PatternLibraryMutationError.usageNotFound
        }
        guard patternUsages[index].isActive else {
            throw PatternLibraryMutationError.usageInactive
        }
        guard let project = project(id: patternUsages[index].projectID) else {
            throw PatternLibraryMutationError.projectNotFound
        }
        guard !project.isCompleted else {
            throw PatternLibraryMutationError.projectCompleted
        }
        return index
    }

    private func ensureLegacyPatternReaderWriteAllowed(projectID: UUID) throws {
        guard let project = project(id: projectID) else { return }
        guard !project.isCompleted else {
            throw PatternLibraryMutationError.projectCompleted
        }
    }
    private func load() {
        syncProjectionCache = nil
        syncBootstrapHydrated = false
        syncHydratedAttachments = [:]
        syncHydratedAttachmentSources = [:]
        do {
            try refreshPatternStorageDependencies()
        } catch {
            loadError = .archiveUnavailable
            return
        }
        do {
            try PatternLibraryMigrator(
                patternFolderNameContext: patternFolderNameContext
            ).recoverInterruptedMigration(archiveURL: url)
            guard FileManager.default.fileExists(atPath: url.path) else {
                try recoverPatternDeletionArtifacts(
                    archive: ProjectArchive(version: ProjectArchive.currentVersion, projects: [])
                )
                try recoverPatternImportArtifacts(
                    archive: ProjectArchive(version: ProjectArchive.currentVersion, projects: [])
                )
                loadError = nil
                return
            }
            try reloadFromDiskDuringDataOperation()
        } catch let error as ProjectStoreError {
            loadError = error == .archiveUnavailable ? .archiveUnavailable : .unreadableArchive
        } catch {
            loadError = .unreadableArchive
        }
    }

    private func loadPendingArchiveReadOnly() {
        syncProjectionCache = nil
        syncBootstrapHydrated = false
        syncHydratedAttachments = [:]
        syncHydratedAttachmentSources = [:]
        guard FileManager.default.fileExists(atPath: url.path) else {
            loadError = nil
            return
        }
        do {
            let archive = try archiveFromDisk()
            projects = archive.projects.sorted { $0.updatedAt > $1.updatedAt }
            yarns = archive.yarns.sorted { $0.updatedAt > $1.updatedAt }
            patternFolders = archive.patternFolders
            patternAssets = archive.patternAssets
            patterns = archive.patterns
            patternUsages = archive.patternUsages
            dataGeneration &+= 1
            loadError = nil
        } catch {
            loadError = .unreadableArchive
        }
    }

    private func completeDeferredLoadAfterSyncPublicationIfNeeded() {
        guard didDeferLoadForSyncPublication else { return }
        didDeferLoadForSyncPublication = false
        load()
    }

    private func reloadFromDiskDuringDataOperation() throws {
        syncProjectionCache = nil
        syncBootstrapHydrated = false
        syncHydratedAttachments = [:]
        syncHydratedAttachmentSources = [:]
        do {
            try refreshPatternStorageDependencies()
        } catch {
            loadError = .archiveUnavailable
            throw ProjectStoreError.archiveUnavailable
        }
        let decoded: (
            projects: [StoredProject],
            yarns: [StoredYarn],
            patternFolders: [PatternFolder],
            patternAssets: [PatternAsset],
            patterns: [StoredPattern],
            patternUsages: [PatternProjectUsage]
        )
        do {
            let migrator = PatternLibraryMigrator(
                patternFolderNameContext: patternFolderNameContext
            )
            try migrator.recoverInterruptedMigration(archiveURL: url)
            let initialArchive = try archiveFromDisk()
            try recoverPatternDeletionArtifacts(archive: initialArchive)
            try recoverPatternImportArtifacts(archive: initialArchive)
            if initialArchive.version < ProjectArchive.currentVersion {
                try migrator.migrateOnDisk(archiveURL: url)
            } else {
                try migrator.validateCurrentArchive(at: url)
            }
            let archiveAfterPatternMigration = try archiveFromDisk()
            let migratedArchive = try KnittingReminderMigrator.migrate(archiveAfterPatternMigration)
            if KnittingReminderMigrator.needsMigration(archiveAfterPatternMigration) {
                try archiveWrite(try JSONEncoder().encode(migratedArchive), url)
            }
            decoded = try decode(archive: migratedArchive)
        } catch {
            loadError = .unreadableArchive
            throw ProjectStoreError.unreadableArchive
        }
        projects = decoded.projects
        yarns = decoded.yarns
        patternFolders = decoded.patternFolders
        patternAssets = decoded.patternAssets
        patterns = decoded.patterns
        patternUsages = decoded.patternUsages
        dataGeneration &+= 1
        loadError = nil
        reconcileYarnPhotos()
        reconcileYarnLabelPhotos()
        reconcileJournalPhotos()
    }

    private func recoverPatternImportArtifacts(archive: ProjectArchive) throws {
        let files = try requiredPatternFileService()
        let inbox = try requiredPatternInboxFileService()
        let receipts = try requiredPatternPublicationReceiptService()
        let assetJournalItems = try files.recoverImportTransactions(
            referencedAssets: archive.patternAssets,
            inbox: inbox
        )
        let receiptItems = try receipts.recover(
            patterns: archive.patterns,
            usages: archive.patternUsages,
            inbox: inbox
        )
        let publishedInboxItems = assetJournalItems.union(receiptItems)
        let report = try inbox.recover(publishedItemIDs: publishedInboxItems)
        for itemID in report.cleanedCommittedIDs.intersection(publishedInboxItems) {
            try? files.completeImportTransaction(itemID: itemID)
            try? receipts.complete(itemID: itemID)
        }
    }

    private func reconcilePublishedPatternInboxItems() async throws {
        let files = try requiredPatternFileService()
        let inbox = try requiredPatternInboxFileService()
        let receipts = try requiredPatternPublicationReceiptService()
        let capturedAssets = patternAssets
        let capturedPatterns = patterns
        let capturedUsages = patternUsages

        try await Task.detached(priority: .utility) {
            let assetJournalItems = try files.recoverImportTransactions(
                referencedAssets: capturedAssets,
                inbox: inbox
            )
            let receiptItems = try receipts.recover(
                patterns: capturedPatterns,
                usages: capturedUsages,
                inbox: inbox
            )
            let publishedItems = assetJournalItems.union(receiptItems)
            guard !publishedItems.isEmpty else { return }

            let report = try inbox.recover(publishedItemIDs: publishedItems)
            for itemID in report.cleanedCommittedIDs.intersection(publishedItems) {
                try? files.completeImportTransaction(itemID: itemID)
                try? receipts.complete(itemID: itemID)
            }
            let unresolvedPublication = try publishedItems.contains { itemID in
                try inbox.journalVerificationItem(id: itemID) != nil
            }
            guard !unresolvedPublication else {
                throw PatternInboxError.invalidItem
            }
        }.value
    }

    private func recoverPatternDeletionArtifacts(archive: ProjectArchive) throws {
        let files = try requiredPatternFileService()
        try PatternLibraryDeletionTransaction.recover(
            root: files.root,
            markupService: patternMarkupFileService,
            fileService: files,
            archive: archive
        )
    }

    private func archiveFromDisk() throws -> ProjectArchive {
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: url))
        guard ProjectArchive.isSupported(version: archive.version) else {
            throw ProjectStoreError.unreadableArchive
        }
        return archive
    }

    private func decode(archive: ProjectArchive) throws -> (
        projects: [StoredProject],
        yarns: [StoredYarn],
        patternFolders: [PatternFolder],
        patternAssets: [PatternAsset],
        patterns: [StoredPattern],
        patternUsages: [PatternProjectUsage]
    ) {
        guard archive.version == ProjectArchive.currentVersion else {
            throw ProjectStoreError.unreadableArchive
        }
        let loadedProjects = archive.projects.sorted { $0.updatedAt > $1.updatedAt }
        let projectIDs = Set(loadedProjects.map(\.id))
        let loadedYarns = archive.yarns.map { yarn in
            var yarn = yarn
            yarn.setLinkedProjectIDs(
                yarn.linkedProjectIDs.intersection(projectIDs),
                now: yarn.updatedAt
            )
            return yarn
        }.sorted { $0.updatedAt > $1.updatedAt }
        let normalized = try PatternLibrarySnapshot(
            folders: archive.patternFolders,
            assets: archive.patternAssets,
            patterns: archive.patterns,
            usages: archive.patternUsages,
            validProjectIDs: loadedProjects.map(\.id)
        ).validated(nameContext: patternFolderNameContext)
        return (
            loadedProjects,
            loadedYarns,
            normalized.folders,
            archive.patternAssets,
            normalized.patterns,
            archive.patternUsages
        )
    }
    private func publishPatternImport(
        _ prepared: PreparedPatternImport,
        duplicateResolution: PatternImportDuplicateResolution,
        access: FeatureAccessDecision
    ) throws -> PatternImportOutcome {
        let files = try requiredPatternFileService()
        let inbox = try requiredPatternInboxFileService()
        let receipts = try requiredPatternPublicationReceiptService()
        let coordinator = PatternImportCoordinator()
        let matchingAssets = patternAssets.filter { $0.sha256 == prepared.metadata.sha256 }
        let candidatePatterns = patterns.filter { pattern in
            matchingAssets.contains(where: { $0.id == pattern.assetID })
        }
        let destinationFolderID = prepared.item.targetFolderID.flatMap { candidate in
            patternFolders.contains(where: { $0.id == candidate }) ? candidate : nil
        }
        let pattern: StoredPattern
        let outcome: PatternImportOutcome

        if candidatePatterns.isEmpty {
            let assetID = coordinator.deterministicAssetID(for: prepared.metadata.sha256)
            let proposedAsset = PatternAsset(
                id: assetID,
                sha256: prepared.metadata.sha256,
                kind: prepared.metadata.kind,
                storedFilename: "\(assetID.uuidString).\(prepared.metadata.fileExtension)",
                byteCount: prepared.metadata.byteCount,
                pageCount: prepared.metadata.pageCount
            )
            try commitAccessIfNeeded(access, mutation: .importPattern)
            try files.beginImportTransaction(
                item: prepared.item,
                metadata: prepared.metadata,
                asset: proposedAsset
            )
            let asset = try files.installAsset(
                data: prepared.data,
                metadata: prepared.metadata,
                id: assetID,
                transactionID: prepared.item.id
            )
            pattern = StoredPattern(
                assetID: asset.id,
                displayName: displayName(for: prepared.item),
                createdAt: prepared.item.receivedAt,
                folderID: destinationFolderID
            )
            do {
                try receipts.begin(item: prepared.item, pattern: pattern)
                let usages = try addingUsage(
                    for: pattern.id,
                    targetProjectID: prepared.item.targetProjectID,
                    to: patternUsages
                )
                try persist(
                    projects: projects,
                    yarns: yarns,
                    patternAssets: patternAssets + [asset],
                    patterns: patterns + [pattern],
                    patternUsages: usages
                )
            } catch {
                try? receipts.complete(itemID: prepared.item.id)
                try? files.rollbackImportTransaction(itemID: prepared.item.id)
                throw error
            }
            outcome = .created(patternID: pattern.id)
        } else {
            if duplicateResolution == .createNew {
                guard let asset = matchingAssets.first else {
                    throw PatternInboxError.invalidItem
                }
                pattern = StoredPattern(
                    assetID: asset.id,
                    displayName: displayName(for: prepared.item),
                    createdAt: prepared.item.receivedAt,
                    folderID: destinationFolderID
                )
                let usages = try addingUsage(
                    for: pattern.id,
                    targetProjectID: prepared.item.targetProjectID,
                    to: patternUsages
                )
                try commitAccessIfNeeded(access, mutation: .importPattern)
                do {
                    try receipts.begin(item: prepared.item, pattern: pattern)
                    try persist(
                        projects: projects,
                        yarns: yarns,
                        patternAssets: patternAssets,
                        patterns: patterns + [pattern],
                        patternUsages: usages
                    )
                } catch {
                    try? receipts.complete(itemID: prepared.item.id)
                    throw error
                }
                outcome = .created(patternID: pattern.id)
                try commitPublishedPatternInboxItem(
                    prepared.item,
                    inbox: inbox,
                    files: files,
                    receipts: receipts
                )
                return outcome
            }
            let selected: StoredPattern?
            if case let .existing(selectingPatternID) = duplicateResolution {
                selected = candidatePatterns.first { $0.id == selectingPatternID }
                guard selected != nil else { throw PatternInboxError.invalidSelection }
            } else if candidatePatterns.count == 1 {
                selected = candidatePatterns[0]
            } else {
                let originalName = coordinator.normalizedName(
                    URL(fileURLWithPath: prepared.item.originalFilename)
                        .deletingPathExtension()
                        .lastPathComponent
                )
                let named = candidatePatterns.filter {
                    coordinator.normalizedName($0.displayName) == originalName
                }
                selected = named.count == 1 ? named[0] : nil
            }
            guard let selected else {
                return .needsSelection(
                    itemID: prepared.item.id,
                    candidatePatternIDs: candidatePatterns.map(\.id).sorted { $0.uuidString < $1.uuidString }
                )
            }
            pattern = selected
            let usages = try addingUsage(
                for: pattern.id,
                targetProjectID: prepared.item.targetProjectID,
                to: patternUsages
            )
            try commitAccessIfNeeded(access, mutation: .importPattern)
            do {
                try receipts.begin(item: prepared.item, pattern: pattern)
                if usages != patternUsages {
                    try persist(
                        projects: projects,
                        yarns: yarns,
                        patternAssets: patternAssets,
                        patterns: patterns,
                        patternUsages: usages
                    )
                }
            } catch {
                try? receipts.complete(itemID: prepared.item.id)
                throw error
            }
            outcome = .existing(patternID: pattern.id)
        }
        try commitPublishedPatternInboxItem(
            prepared.item,
            inbox: inbox,
            files: files,
            receipts: receipts
        )
        return outcome
    }

    private func commitPublishedPatternInboxItem(
        _ item: PatternInboxItem,
        inbox: PatternInboxFileService,
        files: PatternFileService,
        receipts: PatternInboxPublicationReceiptService
    ) throws {
        // A failed staged -> committed transition remains a visible retryable
        // error. The durable item receipt lets startup finish it by exact itemID
        // without replaying the archive mutation.
        try inbox.markCommitted(item)
        do {
            try inbox.cleanupCommitted(item)
            try receipts.complete(itemID: item.id)
            try files.completeImportTransaction(itemID: item.id)
        } catch {
            // Once the sidecar is committed, cleanup is idempotent post-publication
            // work. Startup recovery keeps both journals until cleanup succeeds.
        }
    }

    private func displayName(for item: PatternInboxItem) -> String {
        let value = URL(fileURLWithPath: item.originalFilename)
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Pattern" : value
    }

    private func encodedYouTubeMetadata(_ metadata: YouTubePatternMetadata) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(metadata)
    }

    private func addingUsage(
        for patternID: UUID,
        targetProjectID: UUID?,
        to existingUsages: [PatternProjectUsage],
        now: Date = .now
    ) throws -> [PatternProjectUsage] {
        guard let targetProjectID else { return existingUsages }
        guard project(id: targetProjectID) != nil else { throw ProjectStoreError.patternNotFound }
        if let index = existingUsages.firstIndex(where: {
            $0.patternID == patternID && $0.projectID == targetProjectID
        }) {
            guard !existingUsages[index].isActive else { return existingUsages }
            var restored = existingUsages
            restored[index].isActive = true
            restored[index].unlinkedAt = nil
            return restored
        }
        let nextSortOrder = (existingUsages.filter { $0.projectID == targetProjectID }
            .map(\.sortOrder).max() ?? -1) + 1
        return existingUsages + [PatternProjectUsage(
            patternID: patternID,
            projectID: targetProjectID,
            linkedAt: now,
            sortOrder: nextSortOrder
        )]
    }

    func withWatchSyncPublicationMetadata<Result>(
        preparedCommand: PreparedWatchCommand?,
        processedLedger: ProcessedWatchCommandLedger,
        _ operation: () throws -> Result
    ) rethrows -> Result {
        let previousPrepared = activePreparedWatchCommand
        let previousLedger = activeProcessedWatchLedger
        activePreparedWatchCommand = preparedCommand
        activeProcessedWatchLedger = processedLedger
        defer {
            activePreparedWatchCommand = previousPrepared
            activeProcessedWatchLedger = previousLedger
        }
        return try operation()
    }

    func publishWatchSyncMetadata(
        preparedCommand: PreparedWatchCommand?,
        processedLedger: ProcessedWatchCommandLedger
    ) throws {
        try ensureSyncPublicationReady()
        if isSyncPublicationEnabled, syncProjectionCache == nil {
            let archive = ProjectArchive(
                version: ProjectArchive.currentVersion,
                projects: projects,
                yarns: yarns,
                patternFolders: patternFolders,
                patternAssets: patternAssets,
                patterns: patterns,
                patternUsages: patternUsages
            )
            syncProjectionCache = SyncPublicationProjectionCache(
                archive: archive,
                records: try SyncCanonicalPublicationSnapshot(
                    archive: archive,
                    deviceID: syncPublicationDeviceID,
                    preparedWatchCommand: activePreparedWatchCommand,
                    processedWatchLedger: activeProcessedWatchLedger,
                    deletionMarkers: try deletionLedger().deletionMarkers()
                ).records
            )
        }
        activePreparedWatchCommand = preparedCommand
        activeProcessedWatchLedger = processedLedger
        guard isSyncPublicationEnabled else { return }

        let archive = ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: projects,
            yarns: yarns,
            patternFolders: patternFolders,
            patternAssets: patternAssets,
            patterns: patterns,
            patternUsages: patternUsages
        )
        let projection = try SyncPublicationProjector(
            deviceID: syncPublicationDeviceID,
            preparedWatchCommand: activePreparedWatchCommand,
            processedWatchLedger: activeProcessedWatchLedger,
            processedWatchProofs: syncAttachmentPublicationEvidence.watchCommandProofs,
            reusing: syncProjectionCache,
            attachmentReferences: { archive in
                try self.syncArchiveAttachmentReferences(in: archive)
            },
            issuedAttachmentVersions: syncAttachmentPublicationEvidence.versionsBySlot(),
            issuedAttachmentRecords: syncAttachmentPublicationEvidence.recordsBySlot(),
            deletedAttachmentVersionIDs: syncAttachmentPublicationEvidence.deletedVersionIDSet,
            deletionMarkers: try deletionLedger().deletionMarkers(),
            allowLinkIncarnationCreation: syncBootstrapHydrated
        ).project(
            before: syncProjectionCache?.archive ?? archive,
            after: archive,
            manifest: syncAttachmentManifest
        )
        let archiveBytes = try Data(contentsOf: url)
        let metadataMutations = projection.mutations.filter { mutation in
            if case .delete = mutation,
               syncProjectionCache?.records[mutation.recordID]?.deletedAt.value != nil { return false }
            return true
        }
        try commitArchiveAndPublish(
            data: archiveBytes,
            mutations: metadataMutations,
            observedRevisions: projection.observedRevisions,
            shouldWriteArchive: false,
            onArchiveCommitted: { publishedMutations in
                self.syncProjectionCache = SyncPublicationProjectionCache(
                    archive: archive,
                    records: syncRecords(
                        (self.syncProjectionCache?.records.filter { $0.value.deletedAt.value != nil } ?? [:])
                            .merging(projection.cache.records, uniquingKeysWith: { _, current in current }),
                        applying: publishedMutations.filter {
                            $0.recordID.kind != .attachment
                        }
                    )
                )
            },
            applyCommittedState: {}
        )
    }

    /// Bootstrap's caller must hold its account/publication freeze through
    /// reopen and hydration. This seeds exact remote revisions rather than
    /// reconstructing them from local archive timestamps. Lifecycle integration
    /// must advance a durable canonical checkpoint after later publications.
    public func hydrateSyncBootstrap(_ checkpoint: SyncBootstrapCheckpoint,
                                     attachmentSources: [UUID: SyncAttachmentSource] = [:]) throws {
        try requireSessionWriteAccess()
        guard isSyncPublicationEnabled, syncPublicationError == nil,
              !syncCanonicalActivationRequired, syncCanonicalCheckpointStore == nil else {
            throw SyncPublicationError.pendingRepair
        }
        let data = try SyncRegularFileReader().read(url, maximumBytes: 100_000_000).data
        guard Data(SHA256.hash(data: data)) == checkpoint.archiveSHA256 else {
            throw SyncBootstrapError.sourceChanged
        }
        let records = try SyncRecordValidator().validate(checkpoint.records)
        let attachments = Dictionary(uniqueKeysWithValues: records.filter { $0.id.kind == .attachment }.map { ($0.id.uuid, $0) })
        for (id, source) in attachmentSources {
            guard let version = attachments[id]?.payload.attachment,
                  source.contentSHA256 == version.contentSHA256,
                  source.byteCount == version.byteCount else { throw SyncBootstrapError.corrupt }
            _ = try source.validated()
        }
        let states = Dictionary(uniqueKeysWithValues: records.compactMap { record -> (UUID, SyncCounterReminderState)? in
            guard case let .projectCounter(state)? = record.payload.atomicDomain?.value else { return nil }
            return (record.id.uuid, state)
        })
        guard states == checkpoint.counterStates else { throw SyncBootstrapError.corrupt }
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: data)
        let hydratedEvidence = try syncAttachmentPublicationEvidence.merged(with: .init(
            versions: attachments.values.compactMap { $0.payload.attachment },
            deletedVersionIDs: Set(attachments.values.filter { $0.deletedAt.value != nil }.map(\.id.uuid)),
            attachmentRecords: Array(attachments.values)))
        syncProjectionCache = .init(archive: archive,
            records: Dictionary(uniqueKeysWithValues: records.filter { $0.id.kind != .attachment }.map { ($0.id, $0) }))
        syncBootstrapHydrated = true
        syncHydratedAttachments = attachments
        syncHydratedAttachmentSources = attachmentSources
        syncAttachmentPublicationEvidence = hydratedEvidence
    }

    /// The caller retains account ownership and its writer freeze for this call
    /// and every subsequent mutation. No archive/journal reconstruction is used.
    public func activateSyncCanonicalState(checkpointStore: SyncCanonicalCheckpointStore,
        bootstrap: SyncCanonicalBootstrapHandoff?, attachmentSources: [UUID: SyncAttachmentSource]) throws {
        try requireSessionWriteAccess()
        guard isSyncPublicationEnabled else { throw SyncPublicationError.sinkUnavailable }
        syncCanonicalActivationRequired = true
        syncPublicationError = .pendingRepair
        do {
            try checkpointStore.validateBinding(liveRoot: url.deletingLastPathComponent())
            guard !syncAttachmentPublicationEvidenceLoadFailed, !syncAttachmentManifestLoadFailed,
                  syncRevisionLedger != nil else { throw SyncPublicationError.corruptTransaction }
            let file = SyncPublicationTransactionFile(archiveURL: url)
            let transaction = try file.load()
            var current = try checkpointStore.load()
            if let journalSink = syncMutationSink as? JournalSyncMutationSink {
                try journalSink.validatePendingAttachmentSources {
                    try checkpointStore.validateBinding(liveRoot: self.url.deletingLastPathComponent())
                }
            }
            if let transaction {
                guard let transition = transaction.canonicalTransition else { throw SyncPublicationError.pendingRepair }
                try checkpointStore.validateBinding(liveRoot: url.deletingLastPathComponent(),
                                                    accountIDHash: transition.candidate.accountIDHash)
                let currentDigest = try current.map { Data(SHA256.hash(data: try $0.encoded())) }
                // A daily marker never replaces lost predecessor authority with
                // bootstrap, even if its candidate archive happens to match.
                guard current != nil,
                      current == transition.candidate || currentDigest == transition.predecessorSHA256 else {
                    throw SyncPublicationError.corruptTransaction
                }
                try validateCanonicalTransition(transaction, current: current)
                if transaction.conflictSource != nil {
                    guard let sink = syncMutationSink as? JournalSyncMutationSink else { throw SyncConflictError.missingAuthority }
                    syncCanonicalCheckpointStore = checkpointStore
                    try sink.withExclusivePending { lease in
                        try validateConflictPending(transaction, lease: lease)
                        try installRemoteCandidate(transaction)
                        try publish(transaction, transactionFile: file, journalLease: lease)
                    }
                    current = transition.candidate
                } else if transaction.remoteSource != nil {
                    guard let sink = syncMutationSink as? JournalSyncMutationSink else { throw SyncRemoteBatchError.missingAuthority }
                    syncCanonicalCheckpointStore = checkpointStore
                    try sink.withExclusivePending { lease in
                        guard transaction.remoteSource?.durablePlan?.journalURL == lease.location else { throw SyncRemoteBatchError.missingAuthority }
                        try validateRemotePending(transaction, lease: lease)
                        try installRemoteCandidate(transaction)
                        try publish(transaction, transactionFile: file, journalLease: lease)
                    }
                    current = transition.candidate
                } else { switch try file.commitStatus(of: transaction, archiveURL: url) {
                case .committed:
                    // Issuance evidence may still need replay, so validate the
                    // candidate media/archive now and require evidence in publish.
                    _ = try verifyCanonical(transition.candidate, sources: attachmentSources, requireEvidence: false)
                    syncCanonicalCheckpointStore = checkpointStore
                    syncHydratedAttachmentSources = attachmentSources
                    try publish(transaction, transactionFile: file)
                    current = transition.candidate
                case .uncommitted:
                    guard let predecessor = current, currentDigest == transition.predecessorSHA256 else {
                        throw SyncPublicationError.corruptTransaction
                    }
                    _ = try verifyCanonical(predecessor, sources: attachmentSources)
                    try checkpointStore.validateBinding(liveRoot: url.deletingLastPathComponent())
                    try recoverDeletionLedger(publication: transaction)
                    try checkpointStore.validateBinding(liveRoot: url.deletingLastPathComponent())
                    try file.remove()
                case .corrupt: throw SyncPublicationError.corruptTransaction
                } }
            }
            if current == nil {
                guard let bootstrap,
                      bootstrap.liveRoot.standardizedFileURL == url.deletingLastPathComponent().standardizedFileURL else {
                    throw SyncPublicationError.pendingRepair
                }
                try checkpointStore.validateBinding(liveRoot: bootstrap.liveRoot, accountIDHash: bootstrap.accountIDHash)
                let candidate = try SyncCanonicalCheckpoint(accountIDHash: bootstrap.accountIDHash,
                    commitID: bootstrap.transactionID, archiveSHA256: bootstrap.checkpoint.archiveSHA256,
                    records: bootstrap.checkpoint.records, legacyRecordIDsToDelete: bootstrap.checkpoint.legacyRecordIDsToDelete)
                _ = try verifyCanonical(candidate, sources: attachmentSources)
                try bootstrap.revalidate()
                try checkpointStore.install(candidate, replacing: nil)
                current = candidate
            }
            guard let current else { throw SyncPublicationError.pendingRepair }
            let verified = try verifyCanonical(current, sources: attachmentSources)
            try checkpointStore.validateBinding(liveRoot: url.deletingLastPathComponent(), accountIDHash: current.accountIDHash)
            // Exact installation also repairs an initial handoff interrupted
            // after rename, and refuses any unproven canonical temporary bytes.
            try checkpointStore.install(current, replacing: Data(SHA256.hash(data: current.encoded())))
            syncCanonicalCheckpointStore = checkpointStore
            try recoverDeletionLedger(publication: nil)
            loadPendingArchiveReadOnly()
            guard loadError == nil else { throw SyncPublicationError.corruptTransaction }
            hydrateCanonical(current, verified: verified)
            didDeferLoadForSyncPublication = false
            syncCanonicalActivationRequired = false
            syncPublicationError = nil
        } catch {
            syncPublicationError = syncPublicationError(for: error)
            throw error
        }
    }

    public func prepareConflictRebase(_ input: SyncConflictInput,
        attachmentSources: [UUID: SyncAttachmentSource]) throws -> SyncConflictPreparation {
        _ = try input.validated()
        let (checkpoints, predecessor, sink) = try remoteBatchAuthority(account: input.accountIDHash)
        return try sink.withExclusivePending { lease in
            let pending = try lease.pendingVersioned()
            let head = try lease.rebaseHistoryHeadSHA256()
            let sourceURLs = attachmentSources.values.map(\.fileURL)
                + (input.failedMutation.attachmentSource.map { [$0.fileURL] } ?? [])
            let authority = try remoteAuthoritySnapshot(additional: sourceURLs)
            let verified = try verifyCanonical(predecessor, sources: syncHydratedAttachmentSources)
            let context = try remoteWatchContext()
            let markers = try SyncDeletionLedger.remoteBatchMarkers(archiveURL: url)
            if let source = input.failedMutation.attachmentSource {
                _ = try SyncRegularFileReader().read(source.fileURL,
                    maximumBytes: SyncCanonicalCheckpoint.maximumBytes,
                    expected: .init(byteCount: source.byteCount, sha256: source.contentSHA256))
            }
            @MainActor func preparation(_ transaction: SyncPublicationTransaction? = nil,
                previous: SyncConflictResolution? = nil) -> SyncConflictPreparation {
                .init(liveRoot: url.deletingLastPathComponent(), input: input, predecessor: predecessor,
                    authority: authority, pending: pending, rebaseHistoryHeadSHA256: head,
                    watchContext: context,
                    transaction: transaction, previousResolution: previous)
            }
            let selected = pending.filter { $0.mutation.recordID == input.serverRecord.id }
            let retained = try lease.retainedRebases(for: input)
            guard let first = selected.first, first.mutation.identity == input.failedMutation.identity else {
                return preparation()
            }
            if let previous = retained.last {
                // A different event's rewrite cannot be authorized by this old
                // failure, even when the mutation identity remains unchanged.
                guard selected.count >= previous.after.count,
                      Array(selected.prefix(previous.after.count)).map(\.mutation) == previous.after,
                      Array(selected.prefix(previous.after.count)).map(\.token) == previous.afterVersions else {
                    return preparation()
                }
                if selected.count == previous.after.count {
                    return preparation(previous: try conflictResolution(previous))
                }
            } else {
                guard first.token == input.failedVersion,
                      selected.map(\.mutation) == input.expectedRecordQueue,
                      selected.map(\.token) == input.expectedVersions else { return preparation() }
            }
            let effectiveInput = try SyncConflictInput(accountIDHash: input.accountIDHash,
                failedAttemptID: input.failedAttemptID, failedMutation: input.failedMutation,
                failedVersion: input.failedVersion, serverRecord: input.serverRecord,
                expectedRecordQueue: selected.map(\.mutation), expectedVersions: selected.map(\.token))
            let replacements = try conflictReplacements(effectiveInput, predecessor: predecessor,
                context: context, markers: markers)
            let records = conflictRecords(predecessor.records, applying: replacements)
            var sources = verified.sources
            for (id, source) in attachmentSources { sources[id] = source }
            let staged = sources.mapValues { SyncAttachmentSource(fileURL: $0.fileURL,
                contentSHA256: $0.contentSHA256, byteCount: $0.byteCount, isJournalStaged: true) }
            let materialized = try ProjectArchiveSyncMapper.materialize(records: records,
                attachments: staged, baseArchive: verified.archive)
            let domainChanged = !syncDeletionArchivesMatch(materialized.archive, verified.archive)
            let archive = domainChanged ? try JSONEncoder().encode(materialized.archive)
                : try SyncRegularFileReader().read(url, maximumBytes: SyncCanonicalCheckpoint.maximumBytes).data
            let evidence = try syncAttachmentPublicationEvidenceFile.load()
            let evidenceByID = Dictionary(uniqueKeysWithValues: evidence.retainedAttachmentRecords.map { ($0.id, $0) })
            var files = try materialized.files.filter { file in
                evidenceByID[.init(kind: .attachment, uuid: file.version.versionID)]
                    != records.first { $0.id == .init(kind: .attachment, uuid: file.version.versionID) }
                    || input.serverRecord.payload.attachment == file.version
            }.map { file in
                SyncRemoteInstallFile(relativePath: file.relativePath, version: file.version,
                    data: try SyncRegularFileReader().read(file.source.fileURL,
                        maximumBytes: SyncCanonicalCheckpoint.maximumBytes,
                        expected: .init(byteCount: file.version.byteCount, sha256: file.version.contentSHA256)).data)
            }
            if input.serverRecord.deletedAt.value == nil, let raw = input.serverRecord.payload.attachment,
               !files.contains(where: { $0.version == raw }) {
                guard let source = sources[raw.versionID], source.byteCount == raw.byteCount,
                      source.contentSHA256 == raw.contentSHA256 else { throw SyncConflictError.missingAuthority }
                files.append(.init(relativePath: "SyncMetadata/conflict-source-attachments/"
                    + input.accountIDHash + "/" + raw.versionID.uuidString.lowercased(), version: raw,
                    data: try SyncRegularFileReader().read(source.fileURL,
                        maximumBytes: SyncCanonicalCheckpoint.maximumBytes,
                        expected: .init(byteCount: raw.byteCount, sha256: raw.contentSHA256)).data))
            }
            files.sort { $0.relativePath < $1.relativePath }
            try preflightConflictFiles(files, authority: authority)
            let commitID = UUID()
            let versions = try zip(replacements, selected).map {
                guard $0.1.token.journalRevision < UInt64.max else { throw SyncConflictError.capacity }
                return try SyncMutationVersionToken(mutation: $0.0, journalRevision: $0.1.token.journalRevision + 1)
            }
            let positions = pending.indices.filter { pending[$0].mutation.recordID == input.serverRecord.id }
            let journalTransition = try SyncJournalRebaseTransition(transactionID: commitID, input: effectiveInput,
                predecessorPendingSHA256: SyncConflictRebaseCoding.pendingDigest(pending),
                predecessorRebaseHeadSHA256: head, recordPositions: positions,
                before: selected.map(\.mutation), after: replacements,
                beforeVersions: selected.map(\.token), afterVersions: versions)
            var afterPending = pending.map(\.mutation), afterVersions = pending.map(\.token)
            for (index, position) in positions.enumerated() {
                afterPending[position] = replacements[index]; afterVersions[position] = versions[index]
            }
            let candidate = try predecessor.successor(commitID: commitID,
                archiveSHA256: Data(SHA256.hash(data: archive)), records: records,
                legacyRecordIDsToDelete: predecessor.legacyRecordIDsToDelete)
            let plan = SyncRemoteBatchDurablePlan(predecessor: predecessor, journalURL: lease.location,
                predecessorEvidence: try JSONEncoder().encode(evidence), authority: authority,
                pending: pending.map(\.mutation), records: [input.serverRecord], deletedRecordIDs: [],
                preparedCommands: context.preparedCommands, processedLedger: context.processedLedger,
                deletionMarkers: markers, archive: archive, files: files)
            let source = try SyncConflictPublicationSource(input: effectiveInput, transition: journalTransition,
                plan: plan, beforePending: pending.map(\.mutation), afterPending: afterPending,
                beforeVersions: pending.map(\.token), afterVersions: afterVersions)
            let transaction = try SyncPublicationTransaction(expectedArchiveSHA256: candidate.archiveSHA256,
                mutations: [], artifactEvidence: files.map { try .init(relativePath: $0.relativePath,
                    expectedSHA256: $0.version.contentSHA256) }, revisionReceipts: [],
                canonicalTransition: .init(predecessorSHA256: Data(SHA256.hash(data: predecessor.encoded())),
                    candidate: candidate), conflictSource: source)
            try preflightConflictTransaction(transaction)
            try lease.preflightRebase(journalTransition)
            try checkpoints.validateBinding(liveRoot: url.deletingLastPathComponent(), accountIDHash: input.accountIDHash)
            guard authority == (try remoteAuthoritySnapshot(additional: sourceURLs)) else {
                throw SyncBootstrapError.sourceChanged
            }
            return preparation(transaction)
        }
    }

    public func commitConflictRebase(_ preparation: SyncConflictPreparation,
        withCommitOwnership: (_ work: () throws -> SyncConflictCommitResult) throws -> SyncConflictCommitResult = { try $0() }
    ) throws -> SyncConflictCommitResult {
        try requireSessionWriteAccess()
        var notifyID: UUID?
        let result = try withCommitOwnership {
            try requireSessionWriteAccess()
            let (_, current, sink) = try remoteBatchAuthority(account: preparation.input.accountIDHash)
            guard preparation.liveRoot == url.deletingLastPathComponent() else { throw SyncConflictError.missingAuthority }
            return try sink.withExclusivePending { lease in
                let root = remoteComparisonURL(preparation.liveRoot)
                let additional = preparation.authority.map { URL(fileURLWithPath: $0.path) }.filter {
                    $0 != root && !$0.path.hasPrefix(root.path + "/")
                }
                guard current == preparation.predecessor,
                      try lease.pendingVersioned() == preparation.pending,
                      try lease.rebaseHistoryHeadSHA256() == preparation.rebaseHistoryHeadSHA256,
                      try remoteAuthoritySnapshot(additional: additional) == preparation.authority else { return .stalePredecessor }
                let context = try remoteWatchContext()
                guard context.preparedCommands == preparation.watchContext.preparedCommands,
                      context.processedLedger == preparation.watchContext.processedLedger else { return .stalePredecessor }
                guard let transaction = preparation.transaction else {
                    return preparation.previousResolution.map(SyncConflictCommitResult.committed) ?? .obsoleteFailure
                }
                guard let source = transaction.conflictSource, source.plan.journalURL == lease.location else {
                    throw SyncConflictError.missingAuthority
                }
                guard context.preparedCommands == source.plan.preparedCommands,
                      context.processedLedger == source.plan.processedLedger else { return .stalePredecessor }
                try preflightConflictTransaction(transaction)
                let file = SyncPublicationTransactionFile(archiveURL: url)
                do {
                    try file.write(transaction, preflightingWith: lease)
                    try syncCanonicalPublicationBoundary(.afterIntent)
                    try installRemoteCandidate(transaction)
                    try syncCanonicalPublicationBoundary(.afterArchive)
                    try publish(transaction, transactionFile: file, journalLease: lease)
                    if source.plan.predecessor.archiveSHA256 != transaction.expectedArchiveSHA256 {
                        guard let checkpoint = syncCanonicalCheckpoint else { throw SyncConflictError.missingAuthority }
                        let verified = try verifyCanonical(checkpoint, sources: [:])
                        loadPendingArchiveReadOnly()
                        guard loadError == nil else { throw SyncPublicationError.corruptTransaction }
                        hydrateCanonical(checkpoint, verified: verified)
                        notifyID = source.transition.transactionID
                    }
                } catch {
                    syncPublicationError = .pendingRepair
                    throw error
                }
                return .committed(try conflictResolution(source.transition))
            }
        }
        if let notifyID { onRemoteDomainCommitted?(notifyID) }
        return result
    }

    private func conflictResolution(_ transition: SyncJournalRebaseTransition) throws -> SyncConflictResolution {
        try .init(transactionID: transition.transactionID, input: transition.input,
            replacement: transition.after[0], followingReplacements: Array(transition.after.dropFirst()),
            versions: transition.afterVersions)
    }

    private func conflictRecords(_ records: [SyncRecord], applying mutations: [SyncMutation]) -> [SyncRecord] {
        var byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        for mutation in mutations {
            if let record = mutation.savedRecordVersion?.record { byID[record.id] = record }
            else { byID.removeValue(forKey: mutation.recordID) }
        }
        return byID.values.sorted {
            $0.id.kind.rawValue == $1.id.kind.rawValue ? $0.id.uuid.uuidString < $1.id.uuid.uuidString
                : $0.id.kind.rawValue < $1.id.kind.rawValue
        }
    }

    private func conflictReplacements(_ input: SyncConflictInput, predecessor: SyncCanonicalCheckpoint,
        context: SyncCounterReminderMergeContext, markers: [DeletionMarker]) throws -> [SyncMutation] {
        let original = predecessor.records.first { $0.id == input.serverRecord.id }
        guard input.serverRecord.deletedAt.value == nil || original?.deletedAt.value != nil else {
            throw SyncRemoteBatchError.unprovenDeletion
        }
        var rolling = input.serverRecord
        var replacements: [SyncMutation] = []
        for mutation in input.expectedRecordQueue {
            switch mutation {
            case let .save(save):
                let full = predecessor.records.filter { $0.id != input.serverRecord.id } + [save.recordVersion.record]
                let merge = try SyncMergeEngine().merge(local: full, remote: [rolling], pendingLocal: [],
                    counterReminderContext: context, deletionMarkers: markers)
                guard merge.legacyRecordIDsToDelete.isSubset(of: predecessor.legacyRecordIDsToDelete),
                      let merged = merge.records.first(where: { $0.id == input.serverRecord.id }),
                      merged.deletedAt.value == nil || original?.deletedAt.value != nil else {
                    throw SyncRemoteBatchError.unprovenDeletion
                }
                rolling = merged
                replacements.append(try .save(recordVersion: .init(record: merged),
                    attachmentSource: merged.deletedAt.value == nil ? save.attachmentSource : nil,
                    mutationID: mutation.mutationID))
            case .delete:
                guard original?.deletedAt.value != nil || (original == nil
                    && predecessor.legacyRecordIDsToDelete.contains(mutation.recordID)) else {
                    throw SyncRemoteBatchError.unprovenDeletion
                }
                replacements.append(mutation)
            }
        }
        return replacements
    }

    private func preflightConflictFiles(_ files: [SyncRemoteInstallFile], authority: [SyncRemoteAuthorityFile]) throws {
        let root = remoteComparisonURL(url.deletingLastPathComponent())
        for file in files {
            let target = root.appendingPathComponent(file.relativePath)
            _ = try SyncPublicationArtifactEvidence(relativePath: file.relativePath, expectedSHA256: file.version.contentSHA256)
            var parent = target.deletingLastPathComponent()
            while parent != root {
                if let proof = authority.first(where: { $0.path == parent.path }), !proof.digest.isEmpty {
                    throw SyncConflictError.missingAuthority
                }
                guard parent.path.hasPrefix(root.path + "/") else { throw SyncConflictError.missingAuthority }
                parent.deleteLastPathComponent()
            }
            if file.relativePath.hasPrefix("SyncMetadata/conflict-source-attachments/"),
               let old = authority.first(where: { $0.path == target.path }),
               old.digest != file.version.contentSHA256 || old.bytes != file.version.byteCount {
                throw SyncConflictError.identityCollision
            }
        }
    }

    private func preflightConflictTransaction(_ transaction: SyncPublicationTransaction) throws {
        try validateCanonicalTransition(transaction, current: syncCanonicalCheckpoint)
        _ = try remoteCandidateEvidence(transaction)
        _ = try syncAttachmentPublicationEvidenceFile.applying(remoteEvidenceUpdates(transaction),
            retaining: syncAttachmentPublicationEvidence, validatingOnly: true)
        guard try SyncConflictRebaseCoding.encoder().encode(transaction).count <= SyncCanonicalCheckpoint.maximumBytes,
              let candidate = transaction.canonicalTransition?.candidate,
              try candidate.encoded().count <= SyncCanonicalCheckpoint.maximumBytes else { throw SyncConflictError.capacity }
    }

    public func prepareRemoteBatch(_ batch: SyncRemoteBatch,
        attachmentSources: [UUID: SyncAttachmentSource]) throws -> SyncRemoteBatchPreparation {
        let (checkpoints, predecessor, sink) = try remoteBatchAuthority(account: batch.identity.accountIDHash)
        return try sink.withExclusivePending { lease in
            let pending = try lease.pending()
            let authority = try remoteAuthoritySnapshot(additional: attachmentSources.values.map(\.fileURL))
            if let receipt = try remoteReceipt(batch.identity, in: predecessor) {
                _ = receipt
                return .init(liveRoot: url.deletingLastPathComponent(), identity: batch.identity,
                    predecessor: predecessor, authority: authority, pending: pending, transaction: nil)
            }
            let verified = try verifyCanonical(predecessor, sources: syncHydratedAttachmentSources)
            let context = try remoteWatchContext()
            let markers = try SyncDeletionLedger.remoteBatchMarkers(archiveURL: url)
            let merge = try remoteMerge(batch: batch, predecessor: predecessor, pending: pending, context: context, markers: markers)
            // Deletion retention is a separate durable authority. Incoming IDs
            // and fresh tombstones alone cannot discard local recoverable media.
            let liveIDs = Set(merge.records.filter { $0.deletedAt.value == nil }.map(\.id))
            guard predecessor.records.filter({ $0.deletedAt.value == nil }).allSatisfy({ liveIDs.contains($0.id) }) else {
                throw SyncRemoteBatchError.unprovenDeletion
            }
            var sources = verified.sources
            for (id, source) in attachmentSources { sources[id] = source }
            let staged = sources.mapValues { SyncAttachmentSource(fileURL: $0.fileURL,
                contentSHA256: $0.contentSHA256, byteCount: $0.byteCount, isJournalStaged: true) }
            let materialized = try ProjectArchiveSyncMapper.materialize(records: merge.records,
                attachments: staged, baseArchive: verified.archive)
            let domainChanged = !syncDeletionArchivesMatch(materialized.archive, verified.archive)
                || materialized.files.contains { file in
                    let old = predecessor.records.first { $0.id == .init(kind: .attachment, uuid: file.version.versionID) }
                    return old?.payload.attachment != file.version
                }
            let archive = domainChanged ? try JSONEncoder().encode(materialized.archive)
                : try SyncRegularFileReader().read(url, maximumBytes: SyncCanonicalCheckpoint.maximumBytes).data
            let oldAttachments = Dictionary(uniqueKeysWithValues: predecessor.records.filter { $0.id.kind == .attachment }.map { ($0.id, $0) })
            let predecessorEvidence = try syncAttachmentPublicationEvidenceFile.load()
            let evidenceAttachments = Dictionary(uniqueKeysWithValues: predecessorEvidence.retainedAttachmentRecords.map { ($0.id.uuid, $0) })
            let candidateAttachments = Dictionary(uniqueKeysWithValues: merge.records.filter { $0.id.kind == .attachment }.map { ($0.id.uuid, $0) })
            let installedIDs = Set(materialized.files.map { $0.version.versionID })
            guard merge.records.filter({ $0.id.kind == .attachment && oldAttachments[$0.id] != $0 && $0.deletedAt.value == nil })
                .allSatisfy({ installedIDs.contains($0.id.uuid) }) else { throw SyncRemoteBatchError.missingAuthority }
            // Evidence persists the complete record, including a newer live
            // deletion overlay even when the immutable media payload is equal.
            let files = try materialized.files.filter {
                evidenceAttachments[$0.version.versionID] != candidateAttachments[$0.version.versionID]
            }.map { file in
                SyncRemoteInstallFile(relativePath: file.relativePath, version: file.version,
                    data: try SyncRegularFileReader().read(file.source.fileURL,
                        maximumBytes: SyncCanonicalCheckpoint.maximumBytes,
                        expected: .init(byteCount: file.version.byteCount, sha256: file.version.contentSHA256)).data)
            }
            let commitID = UUID()
            let receipt = SyncRemoteBatchReceipt(identity: batch.identity, commitID: commitID, domainChanged: domainChanged)
            let candidate = try predecessor.successor(commitID: commitID,
                archiveSHA256: Data(SHA256.hash(data: archive)), records: merge.records,
                legacyRecordIDsToDelete: predecessor.legacyRecordIDsToDelete.union(merge.legacyRecordIDsToDelete)
                    .subtracting(batch.deletedRecordIDs)).insertingRemoteReceipt(receipt)
            let installedSources = Dictionary(uniqueKeysWithValues: materialized.files.map { file in
                (file.version.versionID, SyncAttachmentSource(fileURL: url.deletingLastPathComponent().appendingPathComponent(file.relativePath),
                    contentSHA256: file.version.contentSHA256, byteCount: file.version.byteCount, isJournalStaged: false))
            })
            let mutations = try remoteUploadRecords(batch: batch, predecessor: predecessor, merge: merge, pending: pending).map { record in
                try SyncMutation.save(recordVersion: .init(record: record),
                    attachmentSource: record.id.kind == .attachment && record.deletedAt.value == nil ? installedSources[record.id.uuid] : nil, mutationID: UUID())
            }
            let plan = SyncRemoteBatchDurablePlan(predecessor: predecessor, journalURL: lease.location,
                predecessorEvidence: try JSONEncoder().encode(predecessorEvidence), authority: authority,
                pending: pending, records: batch.records, deletedRecordIDs: batch.deletedRecordIDs,
                preparedCommands: context.preparedCommands, processedLedger: context.processedLedger, deletionMarkers: markers,
                archive: archive, files: files)
            let transaction = try remoteTransaction(identity: batch.identity, plan: plan,
                candidate: candidate, mutations: mutations, action: .insert)
            try checkpoints.validateBinding(liveRoot: url.deletingLastPathComponent(), accountIDHash: batch.identity.accountIDHash)
            guard authority == (try remoteAuthoritySnapshot(additional: attachmentSources.values.map(\.fileURL))) else {
                throw SyncBootstrapError.sourceChanged
            }
            return .init(liveRoot: url.deletingLastPathComponent(), identity: batch.identity,
                predecessor: predecessor, authority: authority, pending: pending, transaction: transaction)
        }
    }

    public func commitRemoteBatch(_ preparation: SyncRemoteBatchPreparation,
        withCommitOwnership: (_ commit: () throws -> SyncRemoteBatchCommitResult) throws -> SyncRemoteBatchCommitResult = { try $0() }
    ) throws -> SyncRemoteBatchCommitResult {
        try requireSessionWriteAccess()
        let result = try withCommitOwnership {
            try requireSessionWriteAccess()
            let (_, current, sink) = try remoteBatchAuthority(account: preparation.identity.accountIDHash)
            guard preparation.liveRoot == url.deletingLastPathComponent() else { throw SyncRemoteBatchError.missingAuthority }
            return try sink.withExclusivePending { lease in
                if let receipt = try remoteReceipt(preparation.identity, in: current) { return .alreadyCommitted(receipt) }
                let additional = preparation.authority.map { URL(fileURLWithPath: $0.path) }.filter {
                    !$0.path.hasPrefix(remoteComparisonURL(preparation.liveRoot).path + "/")
                        && $0 != remoteComparisonURL(preparation.liveRoot)
                }
                guard current == preparation.predecessor, try lease.pending() == preparation.pending,
                      try remoteAuthoritySnapshot(additional: additional) == preparation.authority else { return .stalePredecessor }
                if let plan = preparation.transaction?.remoteSource?.durablePlan {
                    guard plan.journalURL == lease.location else { throw SyncRemoteBatchError.missingAuthority }
                    let context = try remoteWatchContext()
                    guard context.preparedCommands == plan.preparedCommands,
                          context.processedLedger == plan.processedLedger else { return .stalePredecessor }
                }
                guard let transaction = preparation.transaction,
                      let receipt = transaction.canonicalTransition?.candidate.remoteBatchReceipts.first(where: { $0.identity == preparation.identity }) else {
                    throw SyncRemoteBatchError.missingAuthority
                }
                try executeRemoteTransaction(transaction, lease: lease)
                return .committed(receipt)
            }
        }
        if case let .committed(receipt) = result, receipt.domainChanged { onRemoteDomainCommitted?(receipt.commitID) }
        return result
    }

    public var onRemoteDomainCommitted: ((UUID) -> Void)? {
        get { remoteDomainCommitted }
        set { remoteDomainCommitted = newValue }
    }

    public func retireRemoteBatchReceipt(_ identity: SyncRemoteBatchIdentity,
        verifyTransportAcknowledgement: () throws -> Void) throws {
        try requireSessionWriteAccess()
        let (checkpoints, current, sink) = try remoteBatchAuthority(account: identity.accountIDHash)
        try verifyTransportAcknowledgement()
        try requireSessionWriteAccess()
        // A crash can follow canonical retirement but precede the incoming
        // store's retirement marker. Only a validated durable ACK permits this
        // idempotent absence; authority and identity collisions still fail.
        guard try remoteReceipt(identity, in: current) != nil else { return }
        try sink.withExclusivePending { lease in
            let pending = try lease.pending()
            let authority = try remoteAuthoritySnapshot(additional: [])
            let archive = try SyncRegularFileReader().read(url, maximumBytes: SyncCanonicalCheckpoint.maximumBytes).data
            _ = try verifyCanonical(current, sources: syncHydratedAttachmentSources)
            let context = try remoteWatchContext()
            let plan = SyncRemoteBatchDurablePlan(predecessor: current, journalURL: lease.location,
                predecessorEvidence: try JSONEncoder().encode(syncAttachmentPublicationEvidenceFile.load()), authority: authority, pending: pending,
                records: [], deletedRecordIDs: [], preparedCommands: context.preparedCommands,
                processedLedger: context.processedLedger,
                deletionMarkers: try SyncDeletionLedger.remoteBatchMarkers(archiveURL: url), archive: archive, files: [])
            let candidate = try current.retiringRemoteReceipt(identity, successorCommitID: UUID())
            let transaction = try remoteTransaction(identity: identity, plan: plan, candidate: candidate, mutations: [], action: .retire)
            try verifyTransportAcknowledgement()
            try requireSessionWriteAccess()
            try checkpoints.validateBinding(liveRoot: url.deletingLastPathComponent(), accountIDHash: identity.accountIDHash)
            guard try checkpoints.load() == current, try lease.pending() == pending,
                  try remoteAuthoritySnapshot(additional: []) == authority else { throw SyncBootstrapError.sourceChanged }
            try executeRemoteTransaction(transaction, lease: lease)
        }
    }

    private func remoteBatchAuthority(account: String) throws
        -> (SyncCanonicalCheckpointStore, SyncCanonicalCheckpoint, JournalSyncMutationSink) {
        guard !syncCanonicalActivationRequired, syncPublicationError == nil, syncBootstrapHydrated,
              let checkpoints = syncCanonicalCheckpointStore, let current = syncCanonicalCheckpoint,
              let sink = syncMutationSink as? JournalSyncMutationSink else { throw SyncPublicationError.pendingRepair }
        try checkpoints.validateBinding(liveRoot: url.deletingLastPathComponent(), accountIDHash: account)
        guard try checkpoints.load() == current, try SyncPublicationTransactionFile(archiveURL: url).load() == nil else {
            throw SyncPublicationError.pendingRepair
        }
        return (checkpoints, current, sink)
    }

    private func remoteReceipt(_ identity: SyncRemoteBatchIdentity, in checkpoint: SyncCanonicalCheckpoint) throws -> SyncRemoteBatchReceipt? {
        let receipt = checkpoint.remoteBatchReceipts.first { $0.identity.batchID == identity.batchID }
        guard receipt == nil || receipt?.identity == identity else { throw SyncRemoteBatchError.identityCollision }
        return receipt
    }

    private func remoteWatchContext() throws -> SyncCounterReminderMergeContext {
        let root = url.deletingLastPathComponent()
        func read<T: Codable & Sendable>(_ type: T.Type, at path: URL) throws -> T? {
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            return try WatchSyncCodec.decode(type, from: SyncRegularFileReader().read(path,
                maximumBytes: SyncCanonicalCheckpoint.maximumBytes).data)
        }
        let diskPrepared = try read(PreparedWatchCommand.self, at: WatchSyncPaths.preparedCommand(in: root))
        let diskLedger = try read(ProcessedWatchCommandLedger.self, at: WatchSyncPaths.processedLedger(in: root))
        var commands = diskPrepared.map { [$0] } ?? []
        if let activePreparedWatchCommand, !commands.contains(activePreparedWatchCommand) { commands.append(activePreparedWatchCommand) }
        return .init(preparedCommands: commands, processedLedger: diskLedger ?? activeProcessedWatchLedger)
    }

    private func remoteMerge(batch: SyncRemoteBatch, predecessor: SyncCanonicalCheckpoint,
        pending: [SyncMutation], context: SyncCounterReminderMergeContext, markers: [DeletionMarker]) throws -> SyncMergeResult {
        let known = Dictionary(uniqueKeysWithValues: predecessor.records.map { ($0.id, $0) })
        guard batch.records.filter({ $0.deletedAt.value != nil }).allSatisfy({ known[$0.id]?.deletedAt.value != nil }) else {
            throw SyncRemoteBatchError.unprovenDeletion
        }
        guard batch.deletedRecordIDs.allSatisfy({ predecessor.legacyRecordIDsToDelete.contains($0) || known[$0]?.deletedAt.value != nil }) else {
            throw SyncRemoteBatchError.unprovenDeletion
        }
        let merge = try SyncMergeEngine().merge(local: predecessor.records, remote: batch.records,
            pendingLocalMutations: pending, counterReminderContext: context, deletionMarkers: markers)
        // Replacement/conversion of already queued immutable FIFO payloads needs
        // its own transport CAS, which this append-only entry point cannot grant.
        guard merge.mutationsToUpload == pending else { throw SyncRemoteBatchError.unsupportedConflictReplacement }
        return merge
    }

    private func remoteUploadRecords(batch: SyncRemoteBatch, predecessor: SyncCanonicalCheckpoint,
        merge: SyncMergeResult, pending: [SyncMutation]) throws -> [SyncRecord] {
        let touched = Set(batch.records.map(\.id))
        let old = Dictionary(uniqueKeysWithValues: predecessor.records.map { ($0.id, $0) })
        return merge.records.filter { record in
            merge.recordsToUpload.contains(record.id) && (touched.contains(record.id) || old[record.id] != record)
                && !pending.contains { $0.savedRecordVersion?.record == record }
        }
    }

    private func remoteTransaction(identity: SyncRemoteBatchIdentity, plan: SyncRemoteBatchDurablePlan,
        candidate: SyncCanonicalCheckpoint, mutations: [SyncMutation], action: SyncRemoteBatchReceiptAction) throws -> SyncPublicationTransaction {
        let transaction = try SyncPublicationTransaction(expectedArchiveSHA256: candidate.archiveSHA256,
            mutations: mutations, artifactEvidence: plan.files.map {
                try SyncPublicationArtifactEvidence(relativePath: $0.relativePath, expectedSHA256: $0.version.contentSHA256)
            }, revisionReceipts: [], canonicalTransition: .init(
                predecessorSHA256: Data(SHA256.hash(data: plan.predecessor.encoded())), candidate: candidate),
            remoteSource: .init(identity: identity, predecessor: .init(checkpoint: plan.predecessor),
                receiptAction: action, durablePlan: plan))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(transaction).count <= SyncCanonicalCheckpoint.maximumBytes else { throw SyncRegularFileReadError.tooLarge }
        return transaction
    }

    private func executeRemoteTransaction(_ transaction: SyncPublicationTransaction, lease: SyncJournalWriteLease) throws {
        let file = SyncPublicationTransactionFile(archiveURL: url)
        try validateCanonicalTransition(transaction, current: syncCanonicalCheckpoint)
        _ = try remoteCandidateEvidence(transaction)
        try syncCanonicalCheckpointStore?.validateBinding(liveRoot: url.deletingLastPathComponent())
        do {
            try file.write(transaction)
            try syncCanonicalPublicationBoundary(.afterIntent)
            try installRemoteCandidate(transaction)
            try syncCanonicalPublicationBoundary(.afterArchive)
            try publish(transaction, transactionFile: file, journalLease: lease)
            if let checkpoint = syncCanonicalCheckpoint,
               transaction.remoteSource?.receiptAction == .insert,
               checkpoint.remoteBatchReceipts.contains(where: { $0.commitID == checkpoint.commitID && $0.domainChanged }) {
                let verified = try verifyCanonical(checkpoint, sources: [:])
                loadPendingArchiveReadOnly()
                guard loadError == nil else { throw SyncPublicationError.corruptTransaction }
                hydrateCanonical(checkpoint, verified: verified)
            }
        } catch {
            syncPublicationError = .pendingRepair
            throw error
        }
    }

    private func installRemoteCandidate(_ transaction: SyncPublicationTransaction) throws {
        guard let plan = transaction.durableCandidatePlan else { throw SyncRemoteBatchError.missingAuthority }
        let root = remoteComparisonURL(url.deletingLastPathComponent())
        let originalEvidence = try JSONDecoder().decode(SyncAttachmentPublicationEvidence.self, from: plan.predecessorEvidence).validated()
        let expectedEvidence = try remoteCandidateEvidence(transaction)
        let observedEvidence = try syncAttachmentPublicationEvidenceFile.load()
        guard try originalEvidence.merged(with: observedEvidence) == observedEvidence,
              try observedEvidence.merged(with: expectedEvidence) == expectedEvidence else { throw SyncBootstrapError.sourceChanged }
        guard let rootProof = plan.authority.first(where: { $0.path == root.path }) else { throw SyncRemoteBatchError.missingAuthority }
        var rootStatus = stat()
        guard root.path.withCString({ lstat($0, &rootStatus) }) == 0,
              UInt64(rootStatus.st_dev) == rootProof.device, UInt64(rootStatus.st_ino) == rootProof.inode else {
            throw SyncBootstrapError.sourceChanged
        }
        let current = try SyncRegularFileReader().read(url, maximumBytes: SyncCanonicalCheckpoint.maximumBytes).data
        let currentDigest = Data(SHA256.hash(data: current))
        guard currentDigest == plan.predecessor.archiveSHA256 || currentDigest == transaction.expectedArchiveSHA256 else {
            throw SyncBootstrapError.sourceChanged
        }
        let currentAuthority = try remoteAuthoritySnapshot(additional: [])
        let metadata = root.appendingPathComponent("SyncMetadata").path + "/"
        let archivePath = root.appendingPathComponent(url.lastPathComponent).path
        let intent = root.appendingPathComponent(SyncPublicationTransactionFile(archiveURL: url).url.lastPathComponent).path
        let targets = Set(plan.files.map { root.appendingPathComponent($0.relativePath).path })
        if transaction.conflictSource != nil {
            let observed = Dictionary(uniqueKeysWithValues: currentAuthority.map { ($0.path, $0) })
            let retainedTargets = Set(plan.files.filter {
                $0.relativePath.hasPrefix("SyncMetadata/conflict-source-attachments/")
            }.map { root.appendingPathComponent($0.relativePath).path })
            for captured in plan.authority {
                let existingParent = captured.digest.isEmpty
                    && targets.contains(where: { $0.hasPrefix(captured.path + "/") })
                // The writer creates missing parents, but never replaces an
                // existing directory or an already-identical raw-only file.
                // Such replacements therefore cannot be claimed as self-replay.
                if existingParent || retainedTargets.contains(captured.path) {
                    guard observed[captured.path] == captured else { throw SyncBootstrapError.sourceChanged }
                }
            }
        }
        let journal = remoteComparisonURL(plan.journalURL).path
        let journalAttachments = remoteComparisonURL(plan.journalURL.deletingLastPathComponent())
            .appendingPathComponent(".\(plan.journalURL.lastPathComponent).attachments").path
        func isImmutable(_ proof: SyncRemoteAuthorityFile) -> Bool {
            let path = proof.path
            guard path.hasPrefix(root.path + "/") else { return false }
            if path == archivePath || path == intent || targets.contains(path)
                || targets.contains(where: { $0.hasPrefix(path + "/") }) { return false }
            if path == journal || path.hasPrefix(journal + ".")
                || path == journalAttachments || path.hasPrefix(journalAttachments + "/") { return false }
            if path == metadata + "canonical.json" || path == metadata + ".canonical-next.json"
                || path == metadata + "attachment-versions.json"
                || path == metadata + ".attachment-versions.json.lock"
                || ["attachment-versions.attachment-records", "attachment-versions.attachment-tombstones", "attachment-versions.watch-proofs"].contains(where: {
                    path == metadata + $0 || path.hasPrefix(metadata + $0 + "/")
                }) { return false }
            return true
        }
        guard plan.authority.filter(isImmutable) == currentAuthority.filter(isImmutable) else {
            throw SyncBootstrapError.sourceChanged
        }
        // All targets must still be the captured predecessor or an exact copy
        // installed by this intent. Check the entire set before the first write.
        for file in plan.files {
            let target = root.appendingPathComponent(file.relativePath)
            if FileManager.default.fileExists(atPath: target.path) {
                let read = try SyncRegularFileReader().read(target, maximumBytes: SyncCanonicalCheckpoint.maximumBytes)
                let old = plan.authority.first { $0.path == target.path }
                guard read.sha256 == file.version.contentSHA256 || (old?.digest == read.sha256 && old?.inode == read.inode && old?.device == read.device) else {
                    throw SyncBootstrapError.sourceChanged
                }
            } else if plan.authority.contains(where: { $0.path == target.path }) { throw SyncBootstrapError.sourceChanged }
        }
        for file in plan.files {
            try syncCanonicalCheckpointStore?.validateBinding(liveRoot: root)
            let target = root.appendingPathComponent(file.relativePath)
            try validateRemoteInstallParent(target)
            if FileManager.default.fileExists(atPath: target.path),
               try SyncRegularFileReader().read(target, maximumBytes: SyncCanonicalCheckpoint.maximumBytes).sha256 == file.version.contentSHA256 { continue }
            try SyncDurableFile.write(
                file.data,
                to: target,
                beforeBoundary: syncRemoteInstallBeforeDurabilityBoundary
            )
        }
        try syncCanonicalCheckpointStore?.validateBinding(liveRoot: root)
        if current != plan.archive { try archiveWrite(plan.archive, url) }
    }

    private func validateConflictPending(_ transaction: SyncPublicationTransaction, lease: SyncJournalWriteLease) throws {
        guard let source = transaction.conflictSource,
              remoteComparisonURL(source.plan.journalURL) == remoteComparisonURL(lease.location) else {
            throw SyncConflictError.missingAuthority
        }
        let retained = try lease.retainedRebases(for: source.input)
        if retained.contains(source.transition) {
            // Native v5 replay has already validated the ordered rebase chain
            // and exact receipts for every missing rebased version. Requiring
            // both snapshots also refuses a replaced or rolled-back journal.
            _ = try lease.pending(requiringRetainedProofsFor: source.beforePending + source.afterPending)
            _ = try lease.pendingVersioned()
        } else {
            guard try lease.pendingVersioned() == zip(source.beforePending, source.beforeVersions).map({
                try SyncVersionedMutation(mutation: $0.0, token: $0.1)
            }), try lease.rebaseHistoryHeadSHA256() == source.transition.predecessorRebaseHeadSHA256 else {
                throw SyncConflictError.missingAuthority
            }
            try lease.preflightRebase(source.transition)
        }
    }

    private func validateRemotePending(_ transaction: SyncPublicationTransaction, lease: SyncJournalWriteLease) throws {
        guard let plan = transaction.remoteSource?.durablePlan else { throw SyncRemoteBatchError.missingAuthority }
        let pending = try lease.pending(requiringRetainedProofsFor: plan.pending)
        let expected = plan.pending + transaction.mutations
        var cursor = 0
        for mutation in pending {
            guard let index = expected.indices.dropFirst(cursor).first(where: { expected[$0].identity == mutation.identity }) else {
                throw SyncBootstrapError.sourceChanged
            }
            let original = expected[index]
            guard original.intent == mutation.intent, original.savedRecordVersion == mutation.savedRecordVersion,
                  original.attachmentSource?.byteCount == mutation.attachmentSource?.byteCount,
                  original.attachmentSource?.contentSHA256 == mutation.attachmentSource?.contentSHA256,
                  index >= plan.pending.count || original.attachmentSource == mutation.attachmentSource else {
                throw SyncBootstrapError.sourceChanged
            }
            cursor = index + 1
        }
    }

    private func remoteCandidateEvidence(_ transaction: SyncPublicationTransaction) throws -> SyncAttachmentPublicationEvidence {
        guard let plan = transaction.durableCandidatePlan else { throw SyncRemoteBatchError.missingAuthority }
        var evidence = try JSONDecoder().decode(SyncAttachmentPublicationEvidence.self, from: plan.predecessorEvidence).validated()
        try evidence.apply(remoteEvidenceUpdates(transaction))
        return try evidence.canonicalized().validated()
    }

    private func remoteEvidenceUpdates(_ transaction: SyncPublicationTransaction) throws -> [SyncMutation] {
        guard let plan = transaction.durableCandidatePlan, let candidate = transaction.canonicalTransition?.candidate else {
            throw SyncRemoteBatchError.missingAuthority
        }
        let before = try JSONDecoder().decode(SyncAttachmentPublicationEvidence.self, from: plan.predecessorEvidence).validated()
        let old = Dictionary(uniqueKeysWithValues: before.retainedAttachmentRecords.map { ($0.id, $0) })
        return try candidate.records.filter { $0.id.kind != .attachment || old[$0.id] != $0 }.map { record in
            var source: SyncAttachmentSource?
            if let version = record.payload.attachment, record.deletedAt.value == nil {
                guard let file = plan.files.first(where: { $0.version == version }) else { throw SyncRemoteBatchError.missingAuthority }
                source = try .init(fileURL: url.deletingLastPathComponent().appendingPathComponent(file.relativePath),
                    contentSHA256: version.contentSHA256, byteCount: version.byteCount)
            }
            return try SyncMutation.save(recordVersion: .init(record: record), attachmentSource: source, mutationID: record.id.uuid)
        }
    }

    private func validateRemoteInstallParent(_ target: URL) throws {
        let root = remoteComparisonURL(url.deletingLastPathComponent())
        guard target.path.hasPrefix(root.path + "/") else { throw SyncRemoteBatchError.missingAuthority }
        let relative = target.deletingLastPathComponent().path.dropFirst(root.path.count)
        var directory = root
        for component in relative.split(separator: "/") {
            directory.appendPathComponent(String(component))
            var status = stat()
            if directory.path.withCString({ lstat($0, &status) }) != 0 {
                guard errno == ENOENT else { throw SyncRemoteBatchError.missingAuthority }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                guard directory.path.withCString({ lstat($0, &status) }) == 0 else { throw SyncRemoteBatchError.missingAuthority }
            }
            guard (status.st_mode & S_IFMT) == S_IFDIR else { throw SyncRemoteBatchError.missingAuthority }
        }
    }

    private func remoteAuthoritySnapshot(additional: [URL]) throws -> [SyncRemoteAuthorityFile] {
        let root = remoteComparisonURL(url.deletingLastPathComponent())
        var paths: Set<URL> = [root]
        func visit(_ directory: URL) throws {
            for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                guard paths.count < 1_000_000 else { throw SyncRegularFileReadError.tooLarge }
                paths.insert(item)
                var status = stat()
                guard item.path.withCString({ lstat($0, &status) }) == 0 else { throw SyncRemoteBatchError.missingAuthority }
                if (status.st_mode & S_IFMT) == S_IFDIR { try visit(item) }
            }
        }
        try visit(root)
        paths.formUnion(additional.map(remoteComparisonURL))
        return try paths.sorted { $0.path < $1.path }.map { item in
            var status = stat()
            guard item.path.withCString({ lstat($0, &status) }) == 0 else { throw SyncRemoteBatchError.missingAuthority }
            if (status.st_mode & S_IFMT) == S_IFDIR {
                return .init(path: item.path, device: UInt64(status.st_dev), inode: UInt64(status.st_ino), bytes: 0, digest: Data())
            }
            guard !item.lastPathComponent.hasSuffix(".tmp"), item.lastPathComponent != ".canonical-next.json" else {
                throw SyncPublicationError.pendingRepair
            }
            let read = try SyncRegularFileReader().read(item, maximumBytes: SyncCanonicalCheckpoint.maximumBytes)
            return .init(path: item.path, device: read.device, inode: read.inode, bytes: read.byteCount, digest: read.sha256)
        }
    }

    /// Match checkpoint ownership normalization: only the platform /var and
    /// /tmp aliases. Never resolve an arbitrary symlink to weaken file checks.
    private func remoteComparisonURL(_ value: URL) -> URL {
        let path = value.path
        if path == "/var" || path.hasPrefix("/var/") || path == "/tmp" || path.hasPrefix("/tmp/") {
            return URL(fileURLWithPath: "/private" + path)
        }
        return value
    }

    private func verifyCanonical(_ checkpoint: SyncCanonicalCheckpoint,
        sources supplied: [UUID: SyncAttachmentSource], requireEvidence: Bool = true) throws
        -> (archive: ProjectArchive, sources: [UUID: SyncAttachmentSource]) {
        let data = try SyncRegularFileReader().read(url, maximumBytes: SyncCanonicalCheckpoint.maximumBytes).data
        guard Data(SHA256.hash(data: data)) == checkpoint.archiveSHA256 else { throw SyncBootstrapError.sourceChanged }
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: data)
        guard ProjectArchive.isSupported(version: archive.version) else { throw SyncPublicationError.corruptTransaction }
        _ = try checkpoint.validated()
        let attachments = checkpoint.records.filter { $0.id.kind == .attachment }
        if requireEvidence {
            let evidence = try syncAttachmentPublicationEvidenceFile.load()
            let issued = Dictionary(uniqueKeysWithValues: evidence.retainedAttachmentRecords.map { ($0.id, $0) })
            guard attachments.allSatisfy({ issued[$0.id] == $0 }) else { throw SyncPublicationError.corruptTransaction }
        }
        let byID = Dictionary(uniqueKeysWithValues: attachments.map { ($0.id.uuid, $0) })
        var sources = supplied
        for (id, source) in sources {
            guard let version = byID[id]?.payload.attachment,
                  version.contentSHA256 == source.contentSHA256, version.byteCount == source.byteCount else {
                throw SyncPublicationError.corruptTransaction
            }
            // Replaced versions retain their original source identity, even
            // after local media cleanup. All live lineage heads and explicitly
            // staged supplied sources require verified bytes below.
        }
        let references = try syncArchiveAttachmentReferences(in: archive)
        let lineage = try SyncAttachmentLineage(records: checkpoint.records)
        for (slot, id) in lineage.resolvedLiveVersionIDs() {
            let version = byID[id]!.payload.attachment!
            if sources[id] == nil, let reference = references.first(where: { deletionReferenceSlot($0.slot) == deletionReferenceSlot(slot) }) {
                sources[id] = try .init(fileURL: reference.sourceURL, contentSHA256: version.contentSHA256,
                                       byteCount: version.byteCount)
            }
        }
        let liveHeads = Set(lineage.headsBySlot.values.flatMap { $0 }.filter { $0.deletedAt.value == nil }.map(\.id.uuid))
        let requiredSources = liveHeads.union(supplied.filter { $0.value.isJournalStaged }.keys)
        for id in requiredSources {
            guard let source = sources[id], let version = byID[id]?.payload.attachment else {
                throw SyncPublicationError.pendingRepair
            }
            _ = try SyncRegularFileReader().read(source.fileURL, maximumBytes: SyncCanonicalCheckpoint.maximumBytes,
                expected: .init(byteCount: version.byteCount, sha256: version.contentSHA256))
        }
        // Materialization reads every selected source, then its destination is
        // separately checked against the live root; supplied upload bytes alone
        // cannot stand in for a missing or altered live attachment.
        let materializationSources = sources.mapValues {
            SyncAttachmentSource(fileURL: $0.fileURL, contentSHA256: $0.contentSHA256,
                                 byteCount: $0.byteCount, isJournalStaged: true)
        }
        let materialized = try ProjectArchiveSyncMapper.materialize(records: checkpoint.records,
            attachments: materializationSources, baseArchive: archive)
        guard syncDeletionArchivesMatch(materialized.archive, archive) else { throw SyncPublicationError.corruptTransaction }
        for file in materialized.files {
            _ = try SyncRegularFileReader().read(url.deletingLastPathComponent().appendingPathComponent(file.relativePath),
                maximumBytes: SyncCanonicalCheckpoint.maximumBytes,
                expected: .init(byteCount: file.version.byteCount, sha256: file.version.contentSHA256))
        }
        return (archive, sources)
    }

    private func hydrateCanonical(_ checkpoint: SyncCanonicalCheckpoint,
        verified: (archive: ProjectArchive, sources: [UUID: SyncAttachmentSource])) {
        syncCanonicalCheckpoint = checkpoint
        syncProjectionCache = .init(archive: verified.archive,
            records: Dictionary(uniqueKeysWithValues: checkpoint.records.filter { $0.id.kind != .attachment }.map { ($0.id, $0) }))
        syncHydratedAttachments = Dictionary(uniqueKeysWithValues: checkpoint.records.filter { $0.id.kind == .attachment }.map { ($0.id.uuid, $0) })
        syncHydratedAttachmentSources = verified.sources
        syncBootstrapHydrated = true
    }

    private func validateCanonicalTransition(_ transaction: SyncPublicationTransaction,
                                             current: SyncCanonicalCheckpoint?) throws {
        guard let transition = transaction.canonicalTransition, let current else {
            throw SyncPublicationError.corruptTransaction
        }
        if let source = transaction.conflictSource {
            _ = try transaction.validated()
            guard current == source.plan.predecessor || current == transition.candidate,
                  source.transition.after == (try conflictReplacements(source.input,
                    predecessor: source.plan.predecessor,
                    context: .init(preparedCommands: source.plan.preparedCommands,
                        processedLedger: source.plan.processedLedger), markers: source.plan.deletionMarkers)) else {
                throw SyncPublicationError.corruptTransaction
            }
            return
        }
        if let source = transaction.remoteSource {
            try validateRemoteTransition(transaction, source: source, current: current)
            return
        }
        let candidate = Dictionary(uniqueKeysWithValues: transition.candidate.records.map { ($0.id, $0) })
        if current != transition.candidate {
            let expected = syncRecords(Dictionary(uniqueKeysWithValues: current.records.map { ($0.id, $0) }),
                                       applying: transaction.mutations)
            guard expected == candidate,
                  current.legacyRecordIDsToDelete == transition.candidate.legacyRecordIDsToDelete else {
                throw SyncPublicationError.corruptTransaction
            }
        }
        for mutation in transaction.mutations {
            switch mutation {
            case let .save(save):
                guard candidate[mutation.recordID] == save.recordVersion.record else { throw SyncPublicationError.corruptTransaction }
            case .delete:
                guard candidate[mutation.recordID] == nil else { throw SyncPublicationError.corruptTransaction }
            }
        }
    }

    private func validateRemoteTransition(_ transaction: SyncPublicationTransaction,
        source: SyncRemoteBatchPublicationSource, current: SyncCanonicalCheckpoint) throws {
        guard let plan = source.durablePlan, let candidate = transaction.canonicalTransition?.candidate,
              try SyncRemoteBatchPredecessorCommitment(checkpoint: plan.predecessor) == source.predecessor,
              current == plan.predecessor || current == candidate,
              transaction.revisionReceipts.isEmpty,
              Data(SHA256.hash(data: plan.archive)) == candidate.archiveSHA256,
              Set(plan.files.map(\.relativePath)).count == plan.files.count else { throw SyncPublicationError.corruptTransaction }
        for file in plan.files {
            _ = try SyncPublicationArtifactEvidence(relativePath: file.relativePath, expectedSHA256: file.version.contentSHA256)
            guard file.data.count <= SyncCanonicalCheckpoint.maximumBytes,
                  Int64(file.data.count) == file.version.byteCount,
                  Data(SHA256.hash(data: file.data)) == file.version.contentSHA256,
                  candidate.records.contains(where: { $0.payload.attachment == file.version }) else {
                throw SyncPublicationError.corruptTransaction
            }
        }
        switch source.receiptAction {
        case .retire:
            guard transaction.mutations.isEmpty, plan.files.isEmpty, plan.records.isEmpty, plan.deletedRecordIDs.isEmpty,
                  candidate == (try plan.predecessor.retiringRemoteReceipt(source.identity, successorCommitID: candidate.commitID)) else {
                throw SyncPublicationError.corruptTransaction
            }
        case .insert:
            let batch = try SyncRemoteBatch(accountIDHash: source.identity.accountIDHash, batchID: source.identity.batchID,
                records: plan.records, deletedRecordIDs: plan.deletedRecordIDs)
            guard batch.identity == source.identity else { throw SyncPublicationError.corruptTransaction }
            let merge = try remoteMerge(batch: batch, predecessor: plan.predecessor, pending: plan.pending,
                context: .init(preparedCommands: plan.preparedCommands, processedLedger: plan.processedLedger), markers: plan.deletionMarkers)
            guard candidate.records == merge.records,
                  candidate.legacyRecordIDsToDelete == plan.predecessor.legacyRecordIDsToDelete.union(merge.legacyRecordIDsToDelete).subtracting(plan.deletedRecordIDs),
                  let receipt = try remoteReceipt(source.identity, in: candidate),
                  candidate.remoteBatchReceipts == (try plan.predecessor.successor(commitID: candidate.commitID,
                    archiveSHA256: candidate.archiveSHA256, records: candidate.records,
                    legacyRecordIDsToDelete: candidate.legacyRecordIDsToDelete).insertingRemoteReceipt(receipt)).remoteBatchReceipts else {
                throw SyncPublicationError.corruptTransaction
            }
            let expected = try remoteUploadRecords(batch: batch, predecessor: plan.predecessor, merge: merge, pending: plan.pending)
            guard transaction.mutations.compactMap(\.savedRecordVersion).map(\.record) == expected,
                  transaction.mutations.count == expected.count,
                  Set(transaction.mutations.map(\.mutationID)).count == expected.count,
                  Set(transaction.mutations.map(\.mutationID)).isDisjoint(with: Set(plan.pending.map(\.mutationID))) else {
                throw SyncPublicationError.corruptTransaction
            }
        }
    }

    private func persist(
        projects stagedProjects: [StoredProject],
        yarns stagedYarns: [StoredYarn],
        patternFolders stagedPatternFolders: [PatternFolder]? = nil,
        patternAssets stagedPatternAssets: [PatternAsset]? = nil,
        patterns stagedPatterns: [StoredPattern]? = nil,
        patternUsages stagedPatternUsages: [PatternProjectUsage]? = nil,
        patternFolderNameContext stagedPatternFolderNameContext: PatternFolderNameContext? = nil,
        additionalSyncMutations: [SyncMutation] = [],
        syncCommitBoundary: SyncPublicationCommitBoundary = .archive,
        additionalArtifactEvidence: [SyncPublicationArtifactEvidence] = [],
        beforeArchiveWrite: (() throws -> Void)? = nil,
        commitArtifacts: (() throws -> Void)? = nil
    ) throws {
        try ensureArchiveAvailable()
        try ensureSyncPublicationReady()
        let projectIDs = Set(stagedProjects.map(\.id))
        guard stagedYarns.allSatisfy({ $0.linkedProjectIDs.isSubset(of: projectIDs) }) else {
            throw ProjectStoreError.invalidYarnProjectLinks
        }
        do {
            let sortedProjects = stagedProjects.sorted { $0.updatedAt > $1.updatedAt }
            let sortedYarns = stagedYarns.sorted { $0.updatedAt > $1.updatedAt }
            let folders = stagedPatternFolders ?? patternFolders
            let assets = stagedPatternAssets ?? patternAssets
            let libraryPatterns = stagedPatterns ?? patterns
            let usages = stagedPatternUsages ?? patternUsages
            let normalized = try PatternLibrarySnapshot(
                folders: folders,
                assets: assets,
                patterns: libraryPatterns,
                usages: usages,
                validProjectIDs: sortedProjects.map(\.id)
            ).validated(
                nameContext: stagedPatternFolderNameContext ?? patternFolderNameContext
            )
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let committedArchive = ProjectArchive(
                version: ProjectArchive.currentVersion,
                projects: sortedProjects,
                yarns: sortedYarns,
                patternFolders: normalized.folders,
                patternAssets: assets,
                patterns: normalized.patterns,
                patternUsages: usages
            )
            let data = try JSONEncoder().encode(committedArchive)
            let originalArchive = ProjectArchive(
                version: ProjectArchive.currentVersion,
                projects: projects,
                yarns: yarns,
                patternFolders: patternFolders,
                patternAssets: patternAssets,
                patterns: patterns,
                patternUsages: patternUsages
            )
            let publicationProjection: SyncPublicationProjection?
            if isSyncPublicationEnabled {
                // Explicit artifact mutations own their slots and commit bytes
                // after projection. Do not cache or republish the pre-write
                // bytes as that slot's current immutable version.
                let explicitSlots = Set(additionalSyncMutations.compactMap {
                    $0.savedRecordVersion?.record.payload.attachment.map { deletionReferenceSlot($0.slot) }
                })
                publicationProjection = try SyncPublicationProjector(
                    deviceID: syncPublicationDeviceID,
                    preparedWatchCommand: activePreparedWatchCommand,
                    processedWatchLedger: activeProcessedWatchLedger,
                    processedWatchProofs: syncAttachmentPublicationEvidence.watchCommandProofs,
                    reusing: syncProjectionCache,
                    attachmentReferences: { archive in
                        try self.syncArchiveAttachmentReferences(in: archive).filter { !explicitSlots.contains(self.deletionReferenceSlot($0.slot)) }
                    },
                    issuedAttachmentVersions: syncAttachmentPublicationEvidence
                        .versionsBySlot(),
                    issuedAttachmentRecords: syncAttachmentPublicationEvidence
                        .recordsBySlot(),
                    deletedAttachmentVersionIDs: syncAttachmentPublicationEvidence
                        .deletedVersionIDSet,
                    deletionMarkers: try deletionLedger().deletionMarkers(),
                    allowLinkIncarnationCreation: syncBootstrapHydrated
                ).project(
                    before: originalArchive,
                    after: committedArchive,
                    manifest: syncAttachmentManifest.filter { !explicitSlots.contains(deletionReferenceSlot($0.value.slot)) }
                )
            } else {
                publicationProjection = nil
            }
            let archiveMutations = (publicationProjection?.mutations ?? []).filter { mutation in
                // Already-published tombstones are absent from the live archive;
                // that absence is not another user deletion or transport cleanup.
                if case .delete = mutation,
                   syncProjectionCache?.records[mutation.recordID]?.deletedAt.value != nil { return false }
                return true
            }
            var mutations = archiveMutations + (isSyncPublicationEnabled
                ? additionalSyncMutations
                : [])
            let retention = try stageSyncDeletion(before: originalArchive, after: committedArchive,
                mutations: &mutations,
                artifactRemovals: Set(additionalArtifactEvidence.filter { $0.expectedSHA256 == nil }.map(\.relativePath)))
            let automaticArtifactEvidence = isSyncPublicationEnabled
                ? try syncArtifactEvidence(
                    for: archiveMutations,
                    attachments: publicationProjection?.attachments ?? [:]
                )
                : []
            let candidateAttachmentManifest = publicationProjection.flatMap {
                $0.attachmentManifest == syncAttachmentManifest
                    ? nil
                    : $0.attachmentManifest
            }
            try commitArchiveAndPublish(
                data: data,
                mutations: mutations,
                observedRevisions: publicationProjection?.observedRevisions ?? [:],
                commitBoundary: syncCommitBoundary,
                artifactEvidence: automaticArtifactEvidence + additionalArtifactEvidence,
                candidateAttachmentManifest: candidateAttachmentManifest,
                deletionRetention: retention,
                beforeArchiveWrite: beforeArchiveWrite,
                commitArtifacts: commitArtifacts,
                onArchiveCommitted: { publishedMutations in
                    guard let publicationProjection else { return }
                    for record in publishedMutations.compactMap(\.savedRecordVersion?.record) where record.id.kind == .attachment {
                        self.syncHydratedAttachments[record.id.uuid] = record
                    }
                    self.syncProjectionCache = SyncPublicationProjectionCache(
                        archive: committedArchive,
                        records: syncRecords(
                            (self.syncProjectionCache?.records.filter { $0.value.deletedAt.value != nil } ?? [:])
                                .merging(publicationProjection.cache.records, uniquingKeysWith: { _, current in current }),
                            // Attachment records have an immutable versioned
                            // identity and are owned by the manifest plus
                            // durable issuance evidence. The archive snapshot
                            // intentionally contains only structural records;
                            // retaining attachment saves here would make the
                            // next structural persist infer a false delete.
                            applying: publishedMutations.filter {
                                $0.recordID.kind != .attachment
                            }
                        )
                    )
                }
            ) {
                projects = sortedProjects
                yarns = sortedYarns
                patternFolders = normalized.folders
                patternAssets = assets
                patterns = normalized.patterns
                patternUsages = usages
                if let stagedPatternFolderNameContext {
                    patternFolderNameContext = stagedPatternFolderNameContext
                }
                dataGeneration &+= 1
                reconcileYarnPhotos()
                reconcileYarnLabelPhotos()
                reconcileJournalPhotos()
            }
        } catch let error as ProjectStoreError {
            throw error
        } catch let error as SyncPublicationError {
            throw error
        } catch let error as StoreSessionAccessError {
            throw error
        } catch {
            throw ProjectStoreError.persistenceFailed
        }
    }

    private func commitArchiveAndPublish(
        data: Data,
        mutations: [SyncMutation],
        observedRevisions: [SyncEntityID: UInt64] = [:],
        commitBoundary: SyncPublicationCommitBoundary = .archive,
        artifactEvidence: [SyncPublicationArtifactEvidence] = [],
        candidateAttachmentManifest: [String: SyncAttachmentManifestEntry]? = nil,
        deletionRetention: (id: UUID, beforeSHA256: Data, removalIDs: Set<SyncEntityID>)? = nil,
        restorationWitness: SyncRestorationWitness? = nil,
        shouldWriteArchive: Bool = true,
        beforeArchiveWrite: (() throws -> Void)? = nil,
        commitArtifacts: (() throws -> Void)? = nil,
        onArchiveCommitted: (([SyncMutation]) -> Void)? = nil,
        applyCommittedState: () -> Void
    ) throws {
        try requireSessionWriteAccess()
        // Callers checked readiness before staging deletion/restoration work.
        // Re-running ledger recovery here would consume that in-flight stage.
        if syncCanonicalActivationRequired { throw SyncPublicationError.pendingRepair }
        if let error = syncPublicationError { throw error }
        try syncCanonicalCheckpointStore?.validateBinding(liveRoot: url.deletingLastPathComponent())
        if let canonical = syncCanonicalCheckpoint, mutations.isEmpty, candidateAttachmentManifest == nil,
           let cached = syncProjectionCache,
           syncDeletionArchivesMatch(cached.archive, try JSONDecoder().decode(ProjectArchive.self, from: data)) {
            // Read-only status probe: reuse the existing checkpoint, including
            // its commit ID, to prove that artifact-only edits are also no-ops.
            // This probe is never installed or written to the publication file.
            let probe = try SyncPublicationTransaction(expectedArchiveSHA256: canonical.archiveSHA256,
                mutations: [], commitBoundary: commitBoundary, artifactEvidence: artifactEvidence, revisionReceipts: [],
                canonicalTransition: .init(predecessorSHA256: Data(SHA256.hash(data: canonical.encoded())), candidate: canonical))
            if try SyncPublicationTransactionFile(archiveURL: url).commitStatus(of: probe, archiveURL: url) == .committed {
                _ = try verifyCanonical(canonical, sources: syncHydratedAttachmentSources)
                applyCommittedState()
                return
            }
        }
        guard isSyncPublicationEnabled,
              !mutations.isEmpty || candidateAttachmentManifest != nil || syncCanonicalCheckpoint != nil else {
            try beforeArchiveWrite?()
            if shouldWriteArchive {
                try archiveWrite(data, url)
            }
            try commitArtifacts?()
            onArchiveCommitted?(mutations)
            applyCommittedState()
            return
        }

        let causallyStamped: (mutations: [SyncMutation], receipts: [SyncRevisionReceipt])
        do {
            causallyStamped = try allocateCausalRevisions(
                for: mutations,
                observedRevisions: observedRevisions
            )
        } catch {
            let publicationError = syncPublicationError(for: error)
            syncPublicationError = publicationError
            throw publicationError
        }

        let transactionFile = SyncPublicationTransactionFile(archiveURL: url)
        let expectedFingerprint = SyncPublicationTransactionFile.fingerprint(of: data)
        let transaction: SyncPublicationTransaction
        do {
            let transition: SyncCanonicalTransition?
            if let previous = syncCanonicalCheckpoint, let checkpoints = syncCanonicalCheckpointStore {
                try checkpoints.validateBinding(liveRoot: url.deletingLastPathComponent(), accountIDHash: previous.accountIDHash)
                guard try checkpoints.load() == previous else { throw SyncPublicationError.corruptTransaction }
                let records = syncRecords(Dictionary(uniqueKeysWithValues: previous.records.map { ($0.id, $0) }),
                    applying: causallyStamped.mutations)
                let candidate = try previous.successor(
                    commitID: UUID(), archiveSHA256: expectedFingerprint,
                    records: Array(records.values),
                    legacyRecordIDsToDelete: previous.legacyRecordIDsToDelete)
                transition = try .init(predecessorSHA256: Data(SHA256.hash(data: previous.encoded())), candidate: candidate)
            } else { transition = nil }
            transaction = try SyncPublicationTransaction(
                expectedArchiveSHA256: expectedFingerprint,
                mutations: causallyStamped.mutations,
                commitBoundary: commitBoundary,
                artifactEvidence: artifactEvidence,
                revisionReceipts: causallyStamped.receipts,
                candidateAttachmentManifest: try candidateAttachmentManifest.map {
                    try SyncAttachmentManifestStore.orderedEntries($0)
                },
                deletionLedgerID: deletionRetention?.id,
                restorationWitness: restorationWitness,
                canonicalTransition: transition
            )
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard try encoder.encode(transaction).count <= 100_000_000 else { throw SyncPublicationError.corruptTransaction }
            try syncCanonicalCheckpointStore?.validateBinding(liveRoot: url.deletingLastPathComponent())
            if let retention = deletionRetention {
                try deletionLedger().prepare(id: retention.id, beforeArchiveSHA256: retention.beforeSHA256,
                    afterArchiveSHA256: expectedFingerprint,
                    exactRemovalVersions: causallyStamped.mutations.compactMap(\.savedRecordVersion)
                        .filter { retention.removalIDs.contains($0.record.id) },
                    publicationSHA256: SyncDeletionLedger.publicationFingerprint(transaction),
                    commitBoundary: commitBoundary)
            }
            if restorationWitness != nil { try deletionLedger().beginRestore(publication: transaction) }
            try syncCanonicalCheckpointStore?.validateBinding(liveRoot: url.deletingLastPathComponent())
            try transactionFile.write(transaction)
            if transaction.canonicalTransition != nil { try syncCanonicalPublicationBoundary(.afterIntent) }
        } catch {
            let publicationError = syncPublicationError(for: error)
            syncPublicationError = publicationError
            throw publicationError
        }

        var archiveWriteFailure: (any Error)?
        do {
            try syncCanonicalCheckpointStore?.validateBinding(liveRoot: url.deletingLastPathComponent())
            try beforeArchiveWrite?()
            if shouldWriteArchive {
                try syncCanonicalCheckpointStore?.validateBinding(liveRoot: url.deletingLastPathComponent())
                try archiveWrite(data, url)
            }
            try syncCanonicalCheckpointStore?.validateBinding(liveRoot: url.deletingLastPathComponent())
            try commitArtifacts?()
            if transaction.canonicalTransition != nil { try syncCanonicalPublicationBoundary(.afterArchive) }
        } catch {
            archiveWriteFailure = error
        }

        let commitStatus: SyncPublicationCommitStatus
        do {
            commitStatus = try transactionFile.commitStatus(of: transaction, archiveURL: url)
        } catch {
            if archiveWriteFailure == nil {
                applyCommittedState()
                syncPublicationError = .transactionUnavailable
                return
            }
            syncPublicationError = .transactionUnavailable
            throw SyncPublicationError.transactionUnavailable
        }

        guard commitStatus == .committed else {
            if commitStatus == .corrupt {
                // The archive fingerprint proves this archive-backed mutation
                // committed. Preserve that user state and keep the marker
                // fail-closed instead of escaping into legacy rollback paths.
                applyCommittedState()
                syncPublicationError = .corruptTransaction
                return
            }
            do {
                if let canonical = syncCanonicalCheckpoint, let checkpoints = syncCanonicalCheckpointStore {
                    try checkpoints.validateBinding(liveRoot: url.deletingLastPathComponent())
                    guard try checkpoints.load() == canonical else { throw SyncPublicationError.corruptTransaction }
                    _ = try verifyCanonical(canonical, sources: syncHydratedAttachmentSources)
                }
                try recoverDeletionLedger(publication: transaction)
                try syncCanonicalCheckpointStore?.validateBinding(liveRoot: url.deletingLastPathComponent())
                try transactionFile.remove()
            } catch {
                let publicationError = syncPublicationError(for: error)
                syncPublicationError = publicationError
                throw publicationError
            }
            if let archiveWriteFailure {
                throw archiveWriteFailure
            }
            throw ProjectStoreError.persistenceFailed
        }

        if transaction.canonicalTransition == nil { onArchiveCommitted?(causallyStamped.mutations) }
        applyCommittedState()
        if archiveWriteFailure != nil {
            // Matching bytes prove the user state reached the destination, but
            // a writer that throws after rename did not return a durability
            // receipt. Keep the marker and block publication/more mutations
            // until startup or explicit repair revalidates the committed data.
            syncPublicationError = .pendingRepair
            return
        }
        do {
            try publish(transaction, transactionFile: transactionFile)
            syncPublicationError = nil
        } catch {
            // The archive and any referenced files are already the user's committed
            // state. Keep the durable transaction and return success locally; the
            // explicit error blocks every later mutation until repair succeeds.
            syncPublicationError = syncPublicationError(for: error)
        }
    }

    private var syncPublicationDeviceID: String {
        syncInstallationID ?? "sync-installation-unavailable"
    }

    /// The caller must hold its account/journal freeze across this entire
    /// synchronous call and capture every pending record, byte and ledger path
    /// in `references`. Pending aggregate identities (the counter/project owning
    /// an embedded removal) belong in protectedPendingRecordIDs. Existing caller
    /// protectedRecordIDs also conservatively protects those aggregates.
    /// MainActor alone is not that cross-process freeze.
    public func purgeRecentlyDeleted(now: Date, acknowledgedVersions: Set<UUID>,
        references: () throws -> SyncDeletionReferences) throws {
        try requireSessionWriteAccess()
        try ensureArchiveAvailable()
        try ensureSyncPublicationReady()
        guard isSyncPublicationEnabled, syncBootstrapHydrated, let cache = syncProjectionCache else {
            throw SyncPublicationError.pendingRepair
        }
        try beginDataOperation()
        defer { isDataOperationInProgress = false }
        var protected = try references()
        protected.acknowledgedRemovalVersionIDs.formIntersection(acknowledgedVersions)
        let archive = try archiveFromDisk()
        let current = ProjectArchive(version: ProjectArchive.currentVersion, projects: projects, yarns: yarns,
            patternFolders: patternFolders, patternAssets: patternAssets, patterns: patterns, patternUsages: patternUsages)
        guard syncDeletionArchivesMatch(archive, current), syncDeletionArchivesMatch(cache.archive, current) else {
            throw SyncPublicationError.pendingRepair
        }
        var attachments = syncHydratedAttachments
        for record in syncAttachmentPublicationEvidence.retainedAttachmentRecords { attachments[record.id.uuid] = record }
        let canonical = Array(cache.records.values) + Array(attachments.values)
        let live = canonical.filter { $0.deletedAt.value == nil }
        protected.currentLiveRecordIDs.formUnion(live.map(\.id))
        protected.currentLiveRecordIDs.formUnion(live.flatMap { $0.relationships.map(\.target) })
        for record in live {
            if case let .projectCounter(state)? = record.payload.atomicDomain?.value {
                protected.currentLiveRecordIDs.formUnion(state.reminders.map { .init(kind: .knittingReminder, uuid: $0.id) })
            }
            if record.id.kind == .project, case let .data(bytes)? = record.payload.fields["domainSnapshot"]?.value {
                let projection = try JSONDecoder().decode(SyncProjectProjection.self, from: bytes)
                protected.currentLiveRecordIDs.formUnion(projection.legacyPatterns.map { .init(kind: .pattern, uuid: $0.id) })
                protected.currentLiveRecordIDs.formUnion((projection.reminderOrder ?? []).map { .init(kind: .knittingReminder, uuid: $0) })
            }
        }
        protected.protectedAttachmentVersionIDs.formUnion(live.compactMap { $0.payload.attachment?.versionID })
        let ledger = try deletionLedger()
        try ledger.purge(now: now, references: protected)
        let markers = try ledger.deletionMarkers()
        let purged = Set(markers.map(\.targetID))
        syncProjectionCache = .init(archive: cache.archive, records: cache.records.filter { !purged.contains($0.key) })
        syncHydratedAttachments = syncHydratedAttachments.filter { !purged.contains(.init(kind: .attachment, uuid: $0.key)) }
        syncHydratedAttachmentSources = syncHydratedAttachmentSources.filter { !purged.contains(.init(kind: .attachment, uuid: $0.key)) }
    }

    public func restoreRecentlyDeleted(id: UUID, now: Date) throws {
        try requireSessionWriteAccess()
        try ensureArchiveAvailable()
        try ensureSyncPublicationReady()
        guard isSyncPublicationEnabled, syncBootstrapHydrated, let cache = syncProjectionCache else {
            throw SyncPublicationError.pendingRepair
        }
        let bytes = try SyncRegularFileReader().read(url, maximumBytes: 100_000_000).data
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: bytes)
        let current = ProjectArchive(version: ProjectArchive.currentVersion, projects: projects, yarns: yarns,
            patternFolders: patternFolders, patternAssets: patternAssets, patterns: patterns, patternUsages: patternUsages)
        guard syncDeletionArchivesMatch(archive, current), syncDeletionArchivesMatch(cache.archive, current) else {
            throw SyncPublicationError.pendingRepair
        }
        let ledger = try deletionLedger()
        guard let entry = try ledger.recentlyDeleted().first(where: { $0.id == id }),
              now >= entry.deletedAt, now < entry.deletedAt.addingTimeInterval(30 * 24 * 60 * 60) else {
            throw SyncDeletionLedgerError.unavailable
        }
        var attachments = syncHydratedAttachments
        for record in syncAttachmentPublicationEvidence.retainedAttachmentRecords { attachments[record.id.uuid] = record }
        let canonical = Array(cache.records.values) + Array(attachments.values)
        // The archive digest alone cannot distinguish two checkpoints whose
        // live view is equally empty. Retained exact deletion versions are a
        // lower bound: current canonical authority must already dominate them.
        // Normalize the current side with the same cascade policy first;
        // causal parent cascades can legitimately strengthen child overlays.
        let normalizedCurrent = try SyncMergeEngine().merge(local: canonical, remote: [SyncRecord](), pendingLocal: [])
        let currentByID = Dictionary(uniqueKeysWithValues: normalizedCurrent.records.map { ($0.id, $0) })
        let withRetainedAuthority = try SyncMergeEngine().merge(local: canonical,
            remote: entry.exactRemovalVersions.map(\.record), pendingLocal: [])
        guard withRetainedAuthority.records.allSatisfy({ currentByID[$0.id] == $0 }) else {
            throw SyncPublicationError.pendingRepair
        }
        let restoration = try entry.domain.restoring(into: canonical, now: now, deviceID: syncPublicationDeviceID)
        let references = Dictionary(uniqueKeysWithValues: try syncArchiveAttachmentReferences(in: current).map { ($0.slot, $0) })
        let lineage = try SyncAttachmentLineage(records: canonical)
        var sources: [UUID: SyncAttachmentSource] = [:]
        for (slot, record) in lineage.resolvedHeadsBySlot() where record.deletedAt.value == nil {
            let version = record.payload.attachment!
            guard let reference = references[deletionReferenceSlot(slot)] else {
                throw SyncDeletionLedgerError.missingAttachment(record.id.uuid)
            }
            sources[record.id.uuid] = try .init(fileURL: reference.sourceURL,
                contentSHA256: version.contentSHA256, byteCount: version.byteCount)
        }
        for (child, predecessor) in restoration.restoredAttachmentPredecessors {
            guard let proof = entry.files.first(where: { $0.attachmentVersionID == predecessor }) else {
                throw SyncDeletionLedgerError.missingAttachment(predecessor)
            }
            sources[child] = try .init(fileURL: ledger.root.appendingPathComponent(proof.retainedRelativePath),
                contentSHA256: proof.sha256, byteCount: proof.byteCount)
        }
        let staged = try ledger.stageRestoreSources(id: id, sources: sources)
        let materialized = try ProjectArchiveSyncMapper.materialize(records: restoration.records,
            attachments: staged, baseArchive: current)
        let selectedFiles = materialized.files.filter { restoration.changedIDs.contains(.init(kind: .attachment, uuid: $0.version.versionID)) }
        let liveRoot = url.deletingLastPathComponent()
        for file in selectedFiles {
            let destination = liveRoot.appendingPathComponent(file.relativePath)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try SyncRegularFileReader().read(destination, maximumBytes: 100_000_000,
                    expected: .init(byteCount: file.version.byteCount, sha256: file.version.contentSHA256))
            }
        }
        let mutations = try restoration.records.filter { restoration.changedIDs.contains($0.id) }.map { record in
            // Mapper staging is owned by this restore attempt. The mutation
            // journal must make and verify its own durable copy before finish.
            let source = try staged[record.id.uuid].map { source in
                try SyncAttachmentSource(fileURL: source.fileURL,
                    contentSHA256: source.contentSHA256, byteCount: source.byteCount)
            }
            return try SyncMutation.save(recordVersion: SyncRecordVersion(record: record),
                attachmentSource: record.id.kind == .attachment ? source : nil, mutationID: UUID())
        }
        let candidate = materialized.archive
        let data = try JSONEncoder().encode(candidate)
        let evidence = try selectedFiles.map { try SyncPublicationArtifactEvidence(relativePath: $0.relativePath,
            expectedSHA256: $0.version.contentSHA256) }
        try commitArchiveAndPublish(data: data, mutations: mutations,
            commitBoundary: data == bytes ? .artifacts : .archive,
            artifactEvidence: evidence,
            restorationWitness: .init(entryID: id, attemptID: UUID(), beforeArchiveSHA256: Data(SHA256.hash(data: bytes))),
            beforeArchiveWrite: {
                try ledger.installRestoreFiles(selectedFiles, liveRoot: liveRoot)
            },
            onArchiveCommitted: { published in
                self.syncProjectionCache = .init(archive: candidate,
                    records: syncRecords(cache.records, applying: published.filter { $0.recordID.kind != .attachment }))
                for record in published.compactMap(\.savedRecordVersion?.record) where record.id.kind == .attachment {
                    self.syncHydratedAttachments[record.id.uuid] = record
                    self.syncHydratedAttachmentSources[record.id.uuid] = staged[record.id.uuid]
                }
            }, applyCommittedState: {
                self.projects = candidate.projects
                self.yarns = candidate.yarns
                self.patternFolders = candidate.patternFolders
                self.patternAssets = candidate.patternAssets
                self.patterns = candidate.patterns
                self.patternUsages = candidate.patternUsages
                self.dataGeneration &+= 1
            })
    }

    private func deletionLedger() throws -> SyncDeletionLedger {
        try SyncDeletionLedger(root: SyncDeletionLedger.root(archiveURL: url))
    }

    private func recoverDeletionLedger(publication: SyncPublicationTransaction?) throws {
        guard isSyncPublicationEnabled else { return }
        let bytes = FileManager.default.fileExists(atPath: url.path)
            ? try SyncRegularFileReader().read(url, maximumBytes: 100_000_000).data : Data()
        let status = try publication.map { try SyncPublicationTransactionFile(archiveURL: url).commitStatus(of: $0, archiveURL: url) }
        try deletionLedger().recover(archiveSHA256: Data(SHA256.hash(data: bytes)), publication: publication,
                                     publicationStatus: status)
    }

    private func stageSyncDeletion(before: ProjectArchive, after: ProjectArchive,
                                   mutations: inout [SyncMutation], artifactRemovals: Set<String> = []) throws
        -> (id: UUID, beforeSHA256: Data, removalIDs: Set<SyncEntityID>)? {
        guard isSyncPublicationEnabled else { return nil }
        let removedStructural = mutations.contains {
            if case .delete = $0 { return $0.recordID.kind != .attachment }
            return $0.recordID.kind != .attachment && $0.savedRecordVersion?.record.deletedAt.value != nil
        }
        let beforeReferences = try syncArchiveAttachmentReferences(in: before)
        let afterSlots = Set(try syncArchiveAttachmentReferences(in: after).map(\.slot))
        let removedReferences = try beforeReferences.filter {
            if !afterSlots.contains($0.slot) { return true }
            return try artifactRemovals.contains(syncArtifactRelativePath(for: $0.sourceURL))
        }
        let removedEmbedded = before.projects.contains { project in
            guard let current = after.projects.first(where: { $0.id == project.id }) else { return false }
            return !Set(project.knittingReminders.map(\.id)).isSubset(of: Set(current.knittingReminders.map(\.id)))
                || !Set(project.patterns.map(\.id)).isSubset(of: Set(current.patterns.map(\.id)))
        }
        guard removedStructural || removedEmbedded || !removedReferences.isEmpty else { return nil }
        guard syncBootstrapHydrated, let cache = syncProjectionCache,
              syncDeletionArchivesMatch(cache.archive, before) else {
            throw SyncPublicationError.pendingRepair
        }
        let bytes = try SyncRegularFileReader().read(url, maximumBytes: 100_000_000).data
        let disk = try JSONDecoder().decode(ProjectArchive.self, from: bytes)
        guard syncDeletionArchivesMatch(disk, before) else {
            throw SyncPublicationError.pendingRepair
        }
        var attachmentRecords = syncHydratedAttachments
        for record in syncAttachmentPublicationEvidence.retainedAttachmentRecords {
            attachmentRecords[record.id.uuid] = record
        }
        mutations = try mutations.map { mutation in
            guard case let .delete(deletion) = mutation else { return mutation }
            guard var record = cache.records[deletion.recordID] ?? attachmentRecords[deletion.recordID.uuid] else {
                throw SyncPublicationError.pendingRepair
            }
            let revision = max(record.entityRevision, record.deletedAt.stamp.logicalRevision)
            guard revision < UInt64.max else { throw SyncPublicationError.pendingRepair }
            record.deletedAt = .init(value: .now, stamp: .init(logicalRevision: revision + 1,
                modifiedAt: .now, deviceID: syncPublicationDeviceID))
            return try .save(recordVersion: SyncRecordVersion(record: record), mutationID: deletion.mutationID)
        }
        let removedSlots = Set(removedReferences.map(\.slot))
        let selectedAttachments = attachmentRecords.values.filter { $0.payload.attachment.map { removedSlots.contains(deletionReferenceSlot($0.slot)) } == true }
        guard removedSlots.isSubset(of: Set(selectedAttachments.compactMap { $0.payload.attachment.map { deletionReferenceSlot($0.slot) } })) else {
            throw SyncPublicationError.pendingRepair
        }
        // The projector normally emits the selected active head. Removing an
        // entire slot must also publish the exact remaining live lineage records.
        let existingIDs = Set(mutations.map(\.recordID))
        for var record in selectedAttachments where record.deletedAt.value == nil && !existingIDs.contains(record.id) {
            let revision = record.deletedAt.stamp.logicalRevision
            guard revision < UInt64.max else { throw SyncPublicationError.pendingRepair }
            record.deletedAt = .init(value: .now, stamp: .init(logicalRevision: revision + 1,
                modifiedAt: .now, deviceID: syncPublicationDeviceID))
            mutations.append(try .save(recordVersion: SyncRecordVersion(record: record), mutationID: UUID()))
        }
        let original = Array(cache.records.values) + selectedAttachments
        let current = syncRecords(Dictionary(uniqueKeysWithValues: original.map { ($0.id, $0) }), applying: mutations)
        guard let domain = try SyncDeletedDomain.capture(before: original, after: Array(current.values),
                beforeArchive: before, afterArchive: after) else { return nil }
        mutations = try mutations.map { mutation in
            guard case let .save(save) = mutation, save.recordVersion.record.deletedAt.value != nil,
                  save.recordVersion.record.id.kind != .attachment else { return mutation }
            var record = save.recordVersion.record
            let dependents = domain.ownedRecords.filter { child in
                child.id != record.id && child.relationships.contains {
                    $0.target == record.id && ["project", "owner"].contains($0.role)
                }
            }.map(\.id).sorted { ($0.kind.rawValue, $0.uuid.uuidString) < ($1.kind.rawValue, $1.uuid.uuidString) }
            if !dependents.isEmpty {
                record.payload.deletionCascade = .init(value: dependents, stamp: record.deletedAt.stamp)
            }
            return try .save(recordVersion: SyncRecordVersion(record: record), mutationID: save.mutationID)
        }
        let lineage = try SyncAttachmentLineage(records: domain.ownedRecords)
        let resolved = lineage.resolvedHeadsBySlot()
        let references = Dictionary(uniqueKeysWithValues: beforeReferences.map { ($0.slot, $0) })
        // Restore destinations are archive-owned slots even when bytes come
        // from an explicitly supplied frozen journal source.
        let standardReferences = try SyncArchiveAttachmentReferences(liveRoot: url.deletingLastPathComponent()).references(in: before)
        let destinations = Dictionary(uniqueKeysWithValues: standardReferences.map { ($0.slot, $0.sourceURL) })
        var sources: [UUID: SyncAttachmentSource] = [:]
        var paths: [UUID: String] = [:]
        for record in lineage.headsBySlot.values.flatMap({ $0 }) where record.deletedAt.value == nil {
            let version = record.payload.attachment!
            let referenceSlot = deletionReferenceSlot(version.slot)
            guard let destination = destinations[referenceSlot] else { throw SyncDeletionLedgerError.missingAttachment(record.id.uuid) }
            paths[record.id.uuid] = try syncArtifactRelativePath(for: destination)
            if resolved[version.slot]?.id == record.id, let reference = references[referenceSlot] {
                sources[record.id.uuid] = try SyncAttachmentSource(fileURL: reference.sourceURL,
                    contentSHA256: version.contentSHA256, byteCount: version.byteCount)
            } else if let source = syncHydratedAttachmentSources[record.id.uuid] {
                sources[record.id.uuid] = source
            } else { throw SyncDeletionLedgerError.missingAttachment(record.id.uuid) }
        }
        let id = try deletionLedger().stage(domain: domain, attachments: sources,
            restoreRelativePaths: paths, deletedAt: .now)
        let removalIDs = Set(domain.ownedRecords.filter { $0.deletedAt.value == nil }.map(\.id))
            .union(domain.photoAssociations.map { $0.slot.owner })
            .union(domain.removedReminders.keys.map { .init(kind: .projectCounter, uuid: $0) })
            .union(domain.removedLegacyPatterns.keys.map { .init(kind: .project, uuid: $0) })
        return (id, Data(SHA256.hash(data: bytes)), removalIDs)
    }

    private func canonicalMarkupSlot(owner: SyncEntityID, preferredRole: String,
        compatibleRole: String, slotID: String) throws -> SyncAttachmentSlot {
        let slots = Set(syncAttachmentPublicationEvidence.versions.map(\.slot).filter {
            $0.owner == owner && $0.slotID == slotID && [preferredRole, compatibleRole].contains($0.role)
        })
        // Existing parallel aliases are ambiguous histories. Never rewrite
        // immutable roles or guess which one supersedes the other.
        guard slots.count <= 1 else { throw SyncPublicationError.pendingRepair }
        return slots.first ?? .init(owner: owner, role: preferredRole, slotID: slotID)
    }

    private func deletionReferenceSlot(_ slot: SyncAttachmentSlot) -> SyncAttachmentSlot {
        let role: String
        switch slot.role {
        case "usage-markup": role = "pattern-markup"
        case "legacy-markup": role = "legacy-pattern-markup"
        default: role = slot.role
        }
        return .init(owner: slot.owner, role: role, slotID: slot.slotID)
    }

    private func syncDeletionArchivesMatch(_ lhs: ProjectArchive, _ rhs: ProjectArchive) -> Bool {
        lhs.projects.sorted { $0.id.uuidString < $1.id.uuidString } == rhs.projects.sorted { $0.id.uuidString < $1.id.uuidString }
            && lhs.yarns.sorted { $0.id.uuidString < $1.id.uuidString } == rhs.yarns.sorted { $0.id.uuidString < $1.id.uuidString }
            && lhs.patternFolders.sorted { $0.id.uuidString < $1.id.uuidString } == rhs.patternFolders.sorted { $0.id.uuidString < $1.id.uuidString }
            && lhs.patternAssets.sorted { $0.id.uuidString < $1.id.uuidString } == rhs.patternAssets.sorted { $0.id.uuidString < $1.id.uuidString }
            && lhs.patterns.sorted { $0.id.uuidString < $1.id.uuidString } == rhs.patterns.sorted { $0.id.uuidString < $1.id.uuidString }
            && lhs.patternUsages.sorted { $0.id.uuidString < $1.id.uuidString } == rhs.patternUsages.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func allocateCausalRevisions(
        for mutations: [SyncMutation],
        observedRevisions: [SyncEntityID: UInt64]
    ) throws -> (mutations: [SyncMutation], receipts: [SyncRevisionReceipt]) {
        guard let syncRevisionLedger else {
            throw SyncRevisionLedgerError.unavailable
        }
        // Accepted records may carry a field/deletion stamp above the legacy
        // entityRevision summary. Once that canonical state has been observed,
        // the next local edit must advance beyond every causal stamp it owns.
        let canonicalRevisions = Dictionary(uniqueKeysWithValues: (syncCanonicalCheckpoint?.records ?? []).map { record in
            var revision = max(record.entityRevision, record.deletedAt.stamp.logicalRevision)
            for field in record.payload.fields.values { revision = max(revision, field.stamp.logicalRevision) }
            revision = max(revision, record.payload.deletionCascade?.stamp.logicalRevision ?? 0)
            if let atomic = record.payload.atomicDomain {
                revision = max(revision, atomic.stamp.logicalRevision)
                switch atomic.value {
                case let .projectCounter(state):
                    for proof in state.processedCommandProofs {
                        revision = max(revision, proof.processingStamp?.logicalRevision ?? 0)
                    }
                case let .orphanWatchCommandProof(proof):
                    revision = max(revision, proof.proof.processingStamp?.logicalRevision ?? 0)
                case .knittingReminder: break
                }
            }
            return (record.id, revision)
        })
        let receipts = try syncRevisionLedger.allocate(mutations.map { mutation in
            SyncRevisionRequest(
                entityID: mutation.recordID,
                mutationID: mutation.mutationID,
                observedRemoteRevision: max(
                    observedRevisions[mutation.recordID] ?? 0,
                    mutation.savedRecordVersion?.record.entityRevision ?? 0,
                    canonicalRevisions[mutation.recordID] ?? 0
                )
            )
        })
        let stamped = try zip(receipts, mutations).map {
            try applying(receipt: $0.0, to: $0.1)
        }
        return (stamped, receipts)
    }

    private func applying(
        receipt: SyncRevisionReceipt,
        to mutation: SyncMutation
    ) throws -> SyncMutation {
        guard case let .save(save) = mutation else { return mutation }
        var record = save.recordVersion.record
        let stamp = SyncMutationStamp(
            logicalRevision: receipt.logicalRevision,
            modifiedAt: record.deletedAt.stamp.modifiedAt,
            deviceID: receipt.deviceID
        )
        if record.payload.attachment != nil, record.deletedAt.value != nil {
            // The receipt orders the deletion overlay; it must not mint a new
            // immutable attachment snapshot for an already-issued version.
            record.deletedAt = .init(value: record.deletedAt.value, stamp: stamp)
            return try .save(
                recordVersion: SyncRecordVersion(record: record),
                mutationID: save.mutationID
            )
        }
        record.entityRevision = receipt.logicalRevision
        record.payload.fields = record.payload.fields.mapValues {
            .init(value: $0.value, stamp: stamp)
        }
        if let deletionCascade = record.payload.deletionCascade {
            record.payload.deletionCascade = .init(value: deletionCascade.value, stamp: stamp)
        }
        if let atomicDomain = record.payload.atomicDomain {
            record.payload.atomicDomain = .init(value: atomicDomain.value, stamp: stamp)
        }
        record.deletedAt = .init(value: record.deletedAt.value, stamp: stamp)
        return try .save(
            recordVersion: SyncRecordVersion(record: record),
            attachmentSource: save.attachmentSource,
            mutationID: save.mutationID
        )
    }

    private func syncArchiveAttachmentReferences(
        in archive: ProjectArchive
    ) throws -> [SyncAttachmentReference] {
        try SyncArchiveAttachmentReferences(
            photoService: photoService,
            yarnPhotoService: yarnPhotoService,
            yarnLabelPhotoService: yarnLabelPhotoService,
            journalPhotoService: journalPhotoService,
            patternFileService: try requiredPatternFileService(),
            patternMarkupFileService: patternMarkupFileService
        ).references(in: archive)
    }

    // Compatibility reference only. This full-hash-on-every-save path is
    // excluded so SyncPublicationProjector + SyncAttachmentManifestStore is
    // the sole active attachment projection authority.
#if false
    private func syncArchiveAttachmentMutations(
        from original: ProjectArchive,
        to committed: ProjectArchive
    ) throws -> [SyncMutation] {
        var metadataCache: [URL: SyncRegularFileMetadata] = [:]
        let originalAttachments = try syncArchiveAttachments(
            in: original,
            metadataCache: &metadataCache
        )
        let committedAttachments = try syncArchiveAttachments(
            in: committed,
            metadataCache: &metadataCache
        )
        let slots = Set(originalAttachments.keys)
            .union(committedAttachments.keys)
            .sorted(by: syncAttachmentSlotIsOrderedBefore)
        var mutations: [SyncMutation] = []
        mutations.reserveCapacity(slots.count)
        for slot in slots {
            let old = originalAttachments[slot]
            let new = committedAttachments[slot]
            guard old != new else { continue }
            let oldVersionID = syncAttachmentVersionID(for: slot)
            guard let new else {
                if let oldVersionID {
                    mutations.append(.delete(
                        .init(kind: .attachment, uuid: oldVersionID),
                        mutationID: UUID()
                    ))
                }
                continue
            }
            let attachment = try SyncAttachmentVersion.issuing(
                slot: new.slot,
                contentSHA256: new.contentSHA256,
                byteCount: new.byteCount,
                mediaType: new.mediaType,
                displayFilename: new.displayFilename,
                replacesVersionID: oldVersionID
            )
            let revision: UInt64 = 0
            let modifiedAt = Date.now
            let stamp = SyncMutationStamp(
                logicalRevision: revision,
                modifiedAt: modifiedAt,
                deviceID: syncPublicationDeviceID
            )
            let record = SyncRecord(
                schemaVersion: 1,
                id: .init(kind: .attachment, uuid: attachment.versionID),
                createdAt: modifiedAt,
                entityRevision: revision,
                payload: .init(fields: [
                    "role": .init(value: .string(slot.role), stamp: stamp),
                    "slotID": .init(value: .string(slot.slotID), stamp: stamp)
                ], attachment: attachment),
                relationships: [.init(role: "owner", target: slot.owner)],
                deletedAt: .init(value: nil, stamp: stamp)
            )
            mutations.append(try .save(
                recordVersion: SyncRecordVersion(record: record),
                attachmentSource: SyncAttachmentSource(
                    fileURL: new.sourceURL,
                    contentSHA256: new.contentSHA256,
                    byteCount: new.byteCount
                ),
                mutationID: UUID()
            ))
        }
        return mutations
    }

    private func syncArchiveAttachments(
        in archive: ProjectArchive,
        metadataCache: inout [URL: SyncRegularFileMetadata]
    ) throws -> [SyncAttachmentSlot: SyncAttachmentProjection] {
        var result: [SyncAttachmentSlot: SyncAttachmentProjection] = [:]

        func add(
            owner: SyncEntityID,
            role: String,
            slotID: String,
            sourceURL: URL,
            displayFilename: String,
            fallbackMediaType: String
        ) throws {
            let normalizedURL = sourceURL.standardizedFileURL
            let metadata: SyncRegularFileMetadata
            if let cached = metadataCache[normalizedURL] {
                metadata = cached
            } else {
                metadata = try syncRegularFileMetadata(at: normalizedURL)
                metadataCache[normalizedURL] = metadata
            }
            let slot = SyncAttachmentSlot(owner: owner, role: role, slotID: slotID)
            result[slot] = SyncAttachmentProjection(
                slot: slot,
                sourceURL: normalizedURL,
                contentSHA256: metadata.contentSHA256,
                byteCount: metadata.byteCount,
                mediaType: syncMediaType(
                    for: displayFilename,
                    fallback: fallbackMediaType
                ),
                displayFilename: URL(fileURLWithPath: displayFilename).lastPathComponent
            )
        }

        for project in archive.projects {
            let projectOwner = SyncEntityID(kind: .project, uuid: project.id)
            if let filename = project.photoFilename {
                try add(
                    owner: projectOwner,
                    role: "project-photo",
                    slotID: "primary",
                    sourceURL: photoService.url(filename: filename),
                    displayFilename: filename,
                    fallbackMediaType: "image/jpeg"
                )
            }
            for pattern in project.patterns {
                try add(
                    owner: .init(kind: .pattern, uuid: pattern.id),
                    role: "legacy-pattern-source",
                    slotID: "project:\(project.id.uuidString)/source",
                    sourceURL: patternURL(projectID: project.id, pattern: pattern),
                    displayFilename: pattern.storedFilename,
                    fallbackMediaType: "application/octet-stream"
                )
            }
            for entry in project.journalEntries {
                for (role, filename) in [
                    ("journal-photo", entry.photoFilename),
                    ("journal-thumbnail", entry.thumbnailFilename)
                ] {
                    guard let sourceURL = journalPhotoService.url(filename: filename) else {
                        throw SyncPublicationTransactionFileError.corrupt
                    }
                    try add(
                        owner: .init(kind: .journalEntry, uuid: entry.id),
                        role: role,
                        slotID: "primary",
                        sourceURL: sourceURL,
                        displayFilename: filename,
                        fallbackMediaType: "image/jpeg"
                    )
                }
            }
        }
        for yarn in archive.yarns {
            let owner = SyncEntityID(kind: .yarn, uuid: yarn.id)
            if let filename = yarn.photoFilename {
                try add(
                    owner: owner,
                    role: "yarn-photo",
                    slotID: "primary",
                    sourceURL: yarnPhotoService.url(filename: filename),
                    displayFilename: filename,
                    fallbackMediaType: "image/jpeg"
                )
            }
            for (filename, slotID) in zip(yarn.labelPhotoFilenames, yarn.labelPhotoSlotIDs) {
                guard let sourceURL = yarnLabelPhotoService.url(filename: filename) else {
                    throw SyncPublicationTransactionFileError.corrupt
                }
                try add(
                    owner: owner,
                    role: "yarn-label-photo",
                    slotID: "label:\(slotID.uuidString.lowercased())",
                    sourceURL: sourceURL,
                    displayFilename: filename,
                    fallbackMediaType: "image/jpeg"
                )
            }
        }
        if !archive.patterns.isEmpty {
            let assetsByID = Dictionary(uniqueKeysWithValues: archive.patternAssets.map {
                ($0.id, $0)
            })
            let files = try requiredPatternFileService()
            for pattern in archive.patterns {
                guard let asset = assetsByID[pattern.assetID], asset.kind != .youtube else {
                    continue
                }
                try add(
                    owner: .init(kind: .pattern, uuid: pattern.id),
                    role: "pattern-source",
                    slotID: "source",
                    sourceURL: try files.assetURL(asset),
                    displayFilename: asset.storedFilename,
                    fallbackMediaType: "application/octet-stream"
                )
            }
        }
        return result
    }

    private func syncAttachmentSlotIsOrderedBefore(
        _ lhs: SyncAttachmentSlot,
        _ rhs: SyncAttachmentSlot
    ) -> Bool {
        (
            lhs.owner.kind.rawValue,
            lhs.owner.uuid.uuidString,
            lhs.role,
            lhs.slotID
        ) < (
            rhs.owner.kind.rawValue,
            rhs.owner.uuid.uuidString,
            rhs.role,
            rhs.slotID
        )
    }

#endif

    private func syncArtifactEvidence(
        for mutations: [SyncMutation],
        attachments: [SyncAttachmentSlot: SyncPublicationAttachmentProjection]
    ) throws -> [SyncPublicationArtifactEvidence] {
        let attachmentSaves = mutations.compactMap { mutation -> SyncAttachmentVersion? in
            guard mutation.attachmentSource != nil else { return nil }
            return mutation.savedRecordVersion?.record.payload.attachment
        }
        guard !attachmentSaves.isEmpty else { return [] }
        return try attachmentSaves.sorted {
            syncAttachmentSlotIsOrderedBefore($0.slot, $1.slot)
        }.map { version in
            guard let attachment = attachments[version.slot],
                  attachment.version == version,
                  attachment.manifestEntry.contentSHA256 == version.contentSHA256,
                  attachment.manifestEntry.byteCount == version.byteCount else {
                throw SyncPublicationTransactionFileError.corrupt
            }
            let relativePath = try syncArtifactRelativePath(
                for: attachment.reference.sourceURL
            )
            return try SyncPublicationArtifactEvidence(
                relativePath: relativePath,
                expectedSHA256: version.contentSHA256
            )
        }
    }

    private func syncUsageMarkupDeleteMutations(
        usageIDs: [UUID]
    ) throws -> [SyncMutation] {
        guard isSyncPublicationEnabled else { return [] }
        return try usageIDs.sorted { $0.uuidString < $1.uuidString }.flatMap { usageID in
            try patternMarkupFileService.usageMarkupPageIndices(usageID: usageID).compactMap { page in
                let slot = SyncAttachmentSlot(
                    owner: .init(kind: .patternUsage, uuid: usageID),
                    role: "usage-markup",
                    slotID: "page:\(page)"
                )
                guard syncAttachmentVersionID(for: slot) != nil else {
                    return nil
                }
                return try syncAttachmentTombstoneMutation(for: slot)
            }
        }
    }

    private func syncLegacyMarkupDeleteMutations(
        projectID: UUID,
        patternIDs: [UUID]
    ) throws -> [SyncMutation] {
        guard isSyncPublicationEnabled else { return [] }
        return try patternIDs.sorted { $0.uuidString < $1.uuidString }.flatMap { patternID in
            try patternMarkupFileService.legacyMarkupPageIndices(
                projectID: projectID,
                patternID: patternID
            ).compactMap { page in
                let slot = SyncAttachmentSlot(
                    owner: .init(kind: .pattern, uuid: patternID),
                    role: "legacy-markup",
                    slotID: "project:\(projectID.uuidString)/page:\(page)"
                )
                guard syncAttachmentVersionID(for: slot) != nil else {
                    return nil
                }
                return try syncAttachmentTombstoneMutation(for: slot)
            }
        }
    }

    private func syncAttachmentVersionID(for slot: SyncAttachmentSlot) -> UUID? {
        syncAttachmentPublicationEvidence.versionID(for: slot)
    }

    private func syncAttachmentTombstoneMutation(
        for slot: SyncAttachmentSlot,
        mutationID: UUID = UUID(),
        now: Date = .now
    ) throws -> SyncMutation {
        guard var record = syncAttachmentPublicationEvidence.record(for: slot),
              record.payload.attachment?.slot == slot else {
            throw SyncPublicationTransactionFileError.corrupt
        }
        record.deletedAt = .init(
            value: now,
            stamp: .init(
                logicalRevision: record.deletedAt.stamp.logicalRevision,
                modifiedAt: now,
                deviceID: syncPublicationDeviceID
            )
        )
        return try .save(
            recordVersion: SyncRecordVersion(record: record),
            mutationID: mutationID
        )
    }

    private func persistAttachmentPublicationEvidence(for mutations: [SyncMutation]) throws {
        syncAttachmentPublicationEvidence = try syncAttachmentPublicationEvidenceFile
            .applying(mutations, retaining: syncAttachmentPublicationEvidence)
    }

    private func syncArtifactRelativePath(for artifactURL: URL) throws -> String {
        let liveRoot = url.deletingLastPathComponent().standardizedFileURL
        let artifactURL = artifactURL.standardizedFileURL
        guard liveRoot.resolvingSymlinksInPath().path == liveRoot.path,
              artifactURL.path.hasPrefix(liveRoot.path + "/"),
              artifactURL.resolvingSymlinksInPath().path == artifactURL.path else {
            throw SyncPublicationTransactionFileError.unsafeFile
        }
        return String(artifactURL.path.dropFirst(liveRoot.path.count + 1))
    }

    private func publish(
        _ transaction: SyncPublicationTransaction,
        transactionFile: SyncPublicationTransactionFile,
        journalLease: SyncJournalWriteLease? = nil
    ) throws {
        guard isSyncPublicationEnabled else {
            throw SyncPublicationError.sinkUnavailable
        }
        if let transition = transaction.canonicalTransition {
            guard let checkpoints = syncCanonicalCheckpointStore else { throw SyncPublicationError.pendingRepair }
            try checkpoints.validateBinding(liveRoot: url.deletingLastPathComponent(), accountIDHash: transition.candidate.accountIDHash)
            let current = try checkpoints.load()
            let currentDigest = try current.map { Data(SHA256.hash(data: try $0.encoded())) }
            guard current != nil, current == transition.candidate
                || currentDigest == transition.predecessorSHA256 else {
                throw SyncPublicationError.corruptTransaction
            }
            try validateCanonicalTransition(transaction, current: current)
        } else if syncCanonicalCheckpointStore != nil { throw SyncPublicationError.pendingRepair }
        if transaction.conflictSource != nil {
            guard case .committed = try transactionFile.commitStatus(of: transaction, archiveURL: url) else {
                throw SyncPublicationError.corruptTransaction
            }
        }
        do {
            try syncCanonicalCheckpointStore?.validateBinding(liveRoot: url.deletingLastPathComponent())
            if !transaction.revisionReceipts.isEmpty {
                guard let syncRevisionLedger else {
                    throw SyncRevisionLedgerError.unavailable
                }
                // The publication marker deliberately duplicates the bounded
                // receipt batch. Restore that long-term immutable authority
                // before any journal replay can make the publication durable.
                try syncRevisionLedger.restore(transaction.revisionReceipts)
            }
        } catch {
            throw syncPublicationError(for: error)
        }
        do {
            try syncCanonicalCheckpointStore?.validateBinding(liveRoot: url.deletingLastPathComponent())
            if transaction.durableCandidatePlan != nil {
                try persistAttachmentPublicationEvidence(for: remoteEvidenceUpdates(transaction))
            }
            if !transaction.mutations.isEmpty {
                try persistAttachmentPublicationEvidence(for: transaction.mutations)
            }
        } catch {
            throw SyncPublicationError.pendingRepair
        }
        do {
            try syncCanonicalCheckpointStore?.validateBinding(liveRoot: url.deletingLastPathComponent())
            if let source = transaction.conflictSource {
                guard let journalLease else { throw SyncConflictError.missingAuthority }
                try validateConflictPending(transaction, lease: journalLease)
                let replaced = try journalLease.rebase(source.transition)
                if !replaced {
                    guard try journalLease.retainedRebases(for: source.input).contains(source.transition) else {
                        throw SyncConflictError.missingAuthority
                    }
                }
            } else if !transaction.mutations.isEmpty {
                if let journalLease { try journalLease.enqueue(transaction.mutations) }
                else { try syncMutationSink.publish(transaction.mutations) }
            }
            if transaction.canonicalTransition != nil { try syncCanonicalPublicationBoundary(.afterJournal) }
        } catch {
            // The marker covers both the already-durable local authorities and
            // the idempotent journal batch. Retain the whole transaction so a
            // restart retries the exact mutation identities.
            throw SyncPublicationError.pendingRepair
        }
        do {
            if let transition = transaction.canonicalTransition {
                guard let checkpoints = syncCanonicalCheckpointStore else { throw SyncPublicationError.pendingRepair }
                var sources = transaction.durableCandidatePlan == nil ? syncHydratedAttachmentSources : [:]
                for mutation in transaction.mutations {
                    if case let .save(save) = mutation, let source = save.attachmentSource {
                        sources[save.recordVersion.record.id.uuid] = .init(fileURL: source.fileURL,
                            contentSHA256: source.contentSHA256, byteCount: source.byteCount, isJournalStaged: source.isJournalStaged)
                    }
                }
                let verified = try verifyCanonical(transition.candidate, sources: sources)
                try checkpoints.install(transition.candidate, replacing: transition.predecessorSHA256)
                try syncCanonicalPublicationBoundary(.afterCheckpoint)
                hydrateCanonical(transition.candidate, verified: verified)
            }
            try syncCanonicalCheckpointStore?.validateBinding(liveRoot: url.deletingLastPathComponent())
            if let candidate = transaction.candidateAttachmentManifest {
                let manifest = try SyncAttachmentManifestStore.dictionary(from: candidate)
                try syncAttachmentManifestStore.commit(manifest)
                syncAttachmentManifest = manifest
            }
            // Only successful durable sink publication authorizes visibility.
            // Keep the shared witness until the independent ledger acknowledges it.
            if transaction.restorationWitness != nil {
                try syncCanonicalCheckpointStore?.validateBinding(liveRoot: url.deletingLastPathComponent())
                try deletionLedger().finishRestore(publication: transaction)
            } else {
                try syncCanonicalCheckpointStore?.validateBinding(liveRoot: url.deletingLastPathComponent())
                try deletionLedger().activate(publication: transaction)
            }
            if transaction.canonicalTransition != nil { try syncCanonicalPublicationBoundary(.beforeIntentRemoval) }
            try syncCanonicalCheckpointStore?.validateBinding(liveRoot: url.deletingLastPathComponent())
            try transactionFile.remove()
        } catch {
            throw SyncPublicationError.pendingRepair
        }
    }

    private func reconcileSyncPublicationTransactionAtStartup() {
        guard !syncAttachmentPublicationEvidenceLoadFailed,
              !syncAttachmentManifestLoadFailed else {
            syncPublicationError = .corruptTransaction
            return
        }
        let transactionFile = SyncPublicationTransactionFile(archiveURL: url)
        do {
            let loaded = try transactionFile.load()
            if loaded?.canonicalTransition != nil || (isSyncPublicationEnabled &&
                ["canonical.json", ".canonical-next.json"].contains(where: {
                    FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("SyncMetadata/" + $0).path)
                })) {
                syncCanonicalActivationRequired = true
                syncPublicationError = .pendingRepair
                return
            }
            try recoverDeletionLedger(publication: loaded)
            guard let transaction = loaded else {
                syncPublicationError = nil
                return
            }
            switch try transactionFile.commitStatus(of: transaction, archiveURL: url) {
            case .committed:
                syncPublicationError = .pendingRepair
            case .uncommitted:
                try transactionFile.remove()
                syncPublicationError = nil
            case .corrupt:
                syncPublicationError = .corruptTransaction
            }
        } catch {
            syncPublicationError = syncPublicationError(for: error)
        }
    }

    private func ensureSyncPublicationReady() throws {
        try requireSessionWriteAccess()
        if syncCanonicalActivationRequired { throw SyncPublicationError.pendingRepair }
        if isSyncPublicationEnabled, !syncBootstrapHydrated,
           FileManager.default.fileExists(atPath: url.deletingLastPathComponent()
                .appendingPathComponent("SyncMetadata/bootstrap-canonical.json").path) {
            throw SyncPublicationError.pendingRepair
        }
        if isSyncPublicationEnabled, syncRevisionLedger == nil {
            throw SyncPublicationError.transactionUnavailable
        }
        if let syncPublicationError {
            throw syncPublicationError
        }
        if let checkpoints = syncCanonicalCheckpointStore {
            guard syncBootstrapHydrated, let canonical = syncCanonicalCheckpoint else { throw SyncPublicationError.pendingRepair }
            try checkpoints.validateBinding(liveRoot: url.deletingLastPathComponent(), accountIDHash: canonical.accountIDHash)
            guard try checkpoints.load() == canonical else { throw SyncPublicationError.corruptTransaction }
        }
        if isSyncPublicationEnabled {
            do { try recoverDeletionLedger(publication: nil) }
            catch { throw syncPublicationError(for: error) }
        }
    }

    private func syncPublicationError(for error: any Error) -> SyncPublicationError {
        if let error = error as? SyncPublicationError {
            return error
        }
        if let error = error as? SyncPublicationTransactionFileError {
            switch error {
            case .corrupt, .unsafeFile:
                return .corruptTransaction
            case .unavailable:
                return .transactionUnavailable
            }
        }
        if let error = error as? SyncRevisionLedgerError {
            switch error {
            case .corrupt, .unsafeFile: return .corruptTransaction
            case .revisionExhausted, .unavailable: return .transactionUnavailable
            }
        }
        if error is SyncInstallationIdentityError {
            return .transactionUnavailable
        }
        if let error = error as? SyncAttachmentManifestError {
            switch error {
            case .corrupt, .unsafeFile: return .corruptTransaction
            case .unavailable: return .transactionUnavailable
            }
        }
        return .pendingRepair
    }

    private func reconcileYarnPhotos() {
        try? yarnPhotoService.reconcile(
            referencedFilenames: Set(yarns.compactMap(\.photoFilename))
        )
    }

    private func reconcileYarnLabelPhotos() {
        try? yarnLabelPhotoService.reconcile(
            referencedFilenames: Set(yarns.flatMap(\.labelPhotoFilenames))
        )
    }

    private func notifyYarnLabelPhotosDidChange() {
        NotificationCenter.default.post(name: .yarnLabelPhotosDidChange, object: nil)
    }

    private func reconcileJournalPhotos() {
        guard activeJournalPhotoTransactions == 0 else { return }
        try? journalPhotoService.reconcile(
            referencedFilenames: Set(
                projects.flatMap(\.journalEntries).flatMap {
                    [$0.photoFilename, $0.thumbnailFilename]
                }
            )
        )
    }

    private func deleteJournalPhotosIfUnreferenced(_ requestedFilenames: Set<String>) {
        let deletableFilenames = ProjectJournalPhotoReferencePolicy.unreferencedFilenames(
            requestedFilenames: requestedFilenames,
            remainingProjects: projects
        )
        try? journalPhotoService.delete(filenames: deletableFilenames)
    }

    private func ensureArchiveAvailable() throws {
        try ensureSyncPublicationReady()
        guard !isDataOperationInProgress else {
            throw KnitNoteBackupError.operationInProgress
        }
        do {
            try refreshPatternStorageDependencies()
        } catch {
            loadError = .archiveUnavailable
            throw ProjectStoreError.archiveUnavailable
        }
        guard loadError == nil else {
            throw ProjectStoreError.archiveUnavailable
        }
    }

    private func refreshPatternStorageDependencies() throws {
        guard patternFileService == nil
                || patternInboxFileService == nil
                || patternPublicationReceiptService == nil else { return }
        guard let patternStorageLocationsProvider else {
            throw ProjectStoreError.archiveUnavailable
        }
        let locations = try patternStorageLocationsProvider()
        url = locations.assetRoot.deletingLastPathComponent().appendingPathComponent("projects-v1.json")
        patternFileService = PatternFileService(root: locations.assetRoot)
        patternInboxFileService = PatternInboxFileService(root: locations.inboxRoot)
        patternPublicationReceiptService = PatternInboxPublicationReceiptService(
            root: locations.assetRoot
        )
    }

    private func requiredPatternFileService() throws -> PatternFileService {
        try refreshPatternStorageDependencies()
        guard let patternFileService else { throw ProjectStoreError.archiveUnavailable }
        return patternFileService
    }

    private func requiredPatternInboxFileService() throws -> PatternInboxFileService {
        try refreshPatternStorageDependencies()
        guard let patternInboxFileService else { throw ProjectStoreError.archiveUnavailable }
        return patternInboxFileService
    }

    private func requiredPatternPublicationReceiptService() throws
        -> PatternInboxPublicationReceiptService {
        try refreshPatternStorageDependencies()
        guard let patternPublicationReceiptService else {
            throw ProjectStoreError.archiveUnavailable
        }
        return patternPublicationReceiptService
    }

    private func validateExpectedDataGeneration(_ expected: UInt64?) throws {
        try ensureArchiveAvailable()
        guard expected == nil || expected == dataGeneration else {
            throw ProjectStoreError.staleDataGeneration
        }
    }

    private func requireAccess(_ mutation: FeatureMutation) throws {
        let access = try preflightAccess(mutation)
        try commitAccessIfNeeded(access, mutation: mutation)
    }

    private func preflightAccess(_ mutation: FeatureMutation) throws -> FeatureAccessDecision {
        try requireSessionWriteAccess()
        try ensureSyncPublicationReady()
        let decision = authorizeMutation(mutation)
        try requireSessionWriteAccess()
        guard decision != .requiresUnlock else {
            throw ProjectStoreError.accessRestricted
        }
        return decision
    }

    private func commitAccessIfNeeded(
        _ decision: FeatureAccessDecision,
        mutation: FeatureMutation
    ) throws {
        try requireSessionWriteAccess()
        switch decision {
        case .allow:
            return
        case .startTrial:
            try commitSuccessfulAccess(mutation)
        case .requiresUnlock:
            throw ProjectStoreError.accessRestricted
        }
    }

    private func commitSuccessfulAccess(_ mutation: FeatureMutation) throws {
        try requireSessionWriteAccess()
        let decision = commitSuccessfulMutation(mutation)
        try requireSessionWriteAccess()
        guard decision != .requiresUnlock else {
            throw ProjectStoreError.accessRestricted
        }
    }

    private func beginDataOperation() throws {
        try requireSessionWriteAccess()
        guard !isDataOperationInProgress,
              activeJournalPhotoTransactions == 0,
              activePatternTransactions == 0 else {
            throw KnitNoteBackupError.operationInProgress
        }
        isDataOperationInProgress = true
    }

    private func withActivePatternTransaction<Result>(
        _ operation: () async throws -> Result
    ) async rethrows -> Result {
        activePatternTransactions += 1
        defer { activePatternTransactions -= 1 }
        return try await operation()
    }

    private enum OwnedBackupArtifactKind {
        case exportPackage
        case stagedRestore

        func accepts(filename: String) -> Bool {
            switch self {
            case .exportPackage:
                let suffix = ".knitnote-backup"
                guard filename.hasSuffix(suffix) else { return false }
                return UUID(uuidString: String(filename.dropLast(suffix.count))) != nil
            case .stagedRestore:
                let prefix = "Staged-"
                guard filename.hasPrefix(prefix) else { return false }
                return UUID(uuidString: String(filename.dropFirst(prefix.count))) != nil
            }
        }
    }

    private func removeOwnedBackupArtifact(
        at artifact: URL,
        kind: OwnedBackupArtifactKind
    ) {
        let standardizedArtifact = artifact.standardizedFileURL
        guard standardizedArtifact.deletingLastPathComponent().path
                == backupService.workRoot.standardizedFileURL.path,
              kind.accepts(filename: standardizedArtifact.lastPathComponent),
              let workValues = try? backupService.workRoot.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ),
              workValues.isDirectory == true,
              workValues.isSymbolicLink != true,
              let artifactValues = try? standardizedArtifact.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ),
              artifactValues.isDirectory == true,
              artifactValues.isSymbolicLink != true else {
            return
        }
        try? FileManager.default.removeItem(at: standardizedArtifact)
    }
}
