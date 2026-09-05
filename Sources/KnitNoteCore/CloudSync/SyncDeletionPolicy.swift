import CryptoKit
import Foundation

public struct DeletionMarker: Codable, Equatable, Sendable {
    public let targetID: SyncEntityID
    public let aggregateParentID: SyncEntityID?
    public let removalStamp: SyncMutationStamp
    public let removalVersionID: UUID

    public init(targetID: SyncEntityID, aggregateParentID: SyncEntityID? = nil,
                removalStamp: SyncMutationStamp, removalVersionID: UUID) {
        self.targetID = targetID
        self.aggregateParentID = aggregateParentID
        self.removalStamp = removalStamp
        self.removalVersionID = removalVersionID
    }

    public var id: SyncEntityID {
        let digest = SHA256.hash(data: Data("KnitNote.deletion-marker|\(targetID.kind.rawValue)|\(targetID.uuid.uuidString)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 15) | 80
        bytes[8] = (bytes[8] & 63) | 128
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return .init(kind: .deletionMarker, uuid: uuid)
    }

    func validated() throws -> Self {
        guard targetID.kind != .deletionMarker, targetID.kind != .watchCommandProof,
              removalStamp.modifiedAt.timeIntervalSinceReferenceDate.isFinite,
              removalStamp.logicalRevision > 0, !removalStamp.deviceID.isEmpty,
              removalStamp.deviceID.utf8.count <= 1024 else { throw SyncDeletionLedgerError.corrupt }
        if let parent = aggregateParentID {
            guard (targetID.kind == .knittingReminder && parent.kind == .projectCounter)
                || (targetID.kind == .pattern && parent.kind == .project) else {
                throw SyncDeletionLedgerError.corrupt
            }
        }
        return self
    }

    public func record() throws -> SyncRecord {
        _ = try validated()
        var fields: [String: SyncScalar] = ["targetKind": .string(targetID.kind.rawValue),
            "targetUUID": .uuid(targetID.uuid), "removalVersionID": .uuid(removalVersionID)]
        if let parent = aggregateParentID {
            fields["aggregateParentKind"] = .string(parent.kind.rawValue)
            fields["aggregateParentUUID"] = .uuid(parent.uuid)
        }
        return .init(schemaVersion: 1, id: id, createdAt: removalStamp.modifiedAt,
            entityRevision: removalStamp.logicalRevision,
            payload: .init(fields: fields.mapValues { .init(value: $0, stamp: removalStamp) }),
            relationships: [], deletedAt: .init(value: nil, stamp: removalStamp))
    }

    public init(record: SyncRecord) throws {
        let fields = record.payload.fields
        guard record.id.kind == .deletionMarker,
              case let .string(kind)? = fields["targetKind"]?.value, let kind = SyncEntityKind(rawValue: kind),
              case let .uuid(target)? = fields["targetUUID"]?.value,
              case let .uuid(version)? = fields["removalVersionID"]?.value else { throw SyncDeletionLedgerError.corrupt }
        var parent: SyncEntityID?
        if fields["aggregateParentKind"] != nil || fields["aggregateParentUUID"] != nil {
            guard case let .string(parentKind)? = fields["aggregateParentKind"]?.value,
                  let parentKind = SyncEntityKind(rawValue: parentKind),
                  case let .uuid(parentUUID)? = fields["aggregateParentUUID"]?.value else { throw SyncDeletionLedgerError.corrupt }
            parent = .init(kind: parentKind, uuid: parentUUID)
        }
        self.init(targetID: .init(kind: kind, uuid: target), aggregateParentID: parent,
            removalStamp: record.deletedAt.stamp, removalVersionID: version)
        guard try self.record() == record else { throw SyncDeletionLedgerError.corrupt }
    }

    /// Reject the entire incompatible record, including atomic Watch/counter
    /// state. A fresh timestamp never restores a permanently removed UUID.
    static func gate(records: [SyncRecord], markers: [DeletionMarker]) throws {
        let targets = Set(try markers.map { try $0.validated().targetID })
        guard !targets.isEmpty else { return }
        for record in records where record.id.kind != .deletionMarker {
            if targets.contains(record.id) || record.relationships.contains(where: { targets.contains($0.target) }) {
                throw SyncMergeError.permanentlyDeleted(record.id)
            }
            if case let .projectCounter(state)? = record.payload.atomicDomain?.value,
               state.reminders.contains(where: { targets.contains(.init(kind: .knittingReminder, uuid: $0.id)) }) {
                throw SyncMergeError.permanentlyDeleted(record.id)
            }
            if record.id.kind == .project, case let .data(bytes)? = record.payload.fields["domainSnapshot"]?.value {
                let projection = try JSONDecoder().decode(SyncProjectProjection.self, from: bytes)
                if projection.legacyPatterns.contains(where: { targets.contains(.init(kind: .pattern, uuid: $0.id)) })
                    || (projection.reminderOrder ?? []).contains(where: { targets.contains(.init(kind: .knittingReminder, uuid: $0)) }) {
                    throw SyncMergeError.permanentlyDeleted(record.id)
                }
            }
        }
    }
}

public struct SyncDeletionReferences: Sendable {
    public var acknowledgedRemovalVersionIDs: Set<UUID>
    /// Caller-provided references conservatively protect both target identities
    /// and removal-owning aggregates, preserving the original pending contract.
    public var protectedRecordIDs: Set<SyncEntityID>
    /// Include every frozen pending save/delete record identity, especially the
    /// counter/project that owns an embedded reminder/legacy-pattern removal.
    public var protectedPendingRecordIDs: Set<SyncEntityID>
    public var protectedAttachmentVersionIDs: Set<UUID>
    public var protectedLedgerRelativePaths: Set<String>
    /// Store-derived live relationships protect actual targets without treating
    /// an otherwise live supporting aggregate as pending publication authority.
    var currentLiveRecordIDs: Set<SyncEntityID> = []
    public init(acknowledgedRemovalVersionIDs: Set<UUID>, protectedRecordIDs: Set<SyncEntityID> = [],
                protectedAttachmentVersionIDs: Set<UUID> = [], protectedLedgerRelativePaths: Set<String> = [],
                protectedPendingRecordIDs: Set<SyncEntityID> = []) {
        self.acknowledgedRemovalVersionIDs = acknowledgedRemovalVersionIDs
        self.protectedRecordIDs = protectedRecordIDs
        self.protectedPendingRecordIDs = protectedPendingRecordIDs
        self.protectedAttachmentVersionIDs = protectedAttachmentVersionIDs
        self.protectedLedgerRelativePaths = protectedLedgerRelativePaths
    }
}

struct SyncDeletionActions: Sendable {
    let eligibleEntryIDs: Set<UUID>
    let markers: [DeletionMarker]
}

public enum SyncDeletionPolicy {
    public static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
    public static func retentionDeadline(deletedAt: Date) -> Date { deletedAt.addingTimeInterval(retentionInterval) }

    static func evaluate(now: Date, records: [SyncDeletionEntry], references: SyncDeletionReferences) -> SyncDeletionActions {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return .init(eligibleEntryIDs: [], markers: []) }
        var ids: Set<UUID> = []
        var markers: [DeletionMarker] = []
        let pendingOrExternal = references.protectedPendingRecordIDs.union(references.protectedRecordIDs)
        let protectedTargets = pendingOrExternal.union(references.currentLiveRecordIDs)
        for entry in records {
            guard entry.deletedAt.timeIntervalSinceReferenceDate.isFinite,
                  now >= retentionDeadline(deletedAt: entry.deletedAt),
                  let candidates = try? markerCandidates(entry),
                  !candidates.isEmpty,
                  Set(candidates.map(\.removalVersionID)).isSubset(of: references.acknowledgedRemovalVersionIDs),
                  Set(candidates.map(\.targetID)).isDisjoint(with: protectedTargets),
                  Set(candidates.compactMap(\.aggregateParentID))
                    .union(entry.exactRemovalVersions.map { $0.record.id }).isDisjoint(with: pendingOrExternal),
                  Set(candidates.filter { $0.targetID.kind == .attachment }.map { $0.targetID.uuid })
                    .isDisjoint(with: references.protectedAttachmentVersionIDs),
                  Set(entry.files.map(\.attachmentVersionID)).isDisjoint(with: references.protectedAttachmentVersionIDs),
                  Set(entry.files.map(\.retainedRelativePath)).isDisjoint(with: references.protectedLedgerRelativePaths) else { continue }
            ids.insert(entry.id)
            markers += candidates
        }
        return .init(eligibleEntryIDs: ids, markers: markers)
    }

    static func markerCandidates(_ entry: SyncDeletionEntry) throws -> [DeletionMarker] {
        try SyncDeletionLedger.validateDomain(entry.domain)
        try SyncDeletionLedger.validateRemovalVersions(entry.exactRemovalVersions, domain: entry.domain)
        let required = try SyncAttachmentLineage(records: entry.domain.ownedRecords).headsBySlot.values.flatMap { $0 }
            .filter { entry.domain.selectedLiveIDs.contains($0.id) }
        guard entry.files.count == required.count,
              Set(entry.files.map(\.attachmentVersionID)) == Set(required.map { $0.id.uuid }) else {
            throw SyncDeletionLedgerError.corrupt
        }
        for proof in entry.files {
            guard let version = required.first(where: { $0.id.uuid == proof.attachmentVersionID })?.payload.attachment,
                  version.byteCount == proof.byteCount, version.contentSHA256 == proof.sha256,
                  proof.sha256.count == 32, proof.byteCount >= 0, proof.byteCount <= 100_000_000,
                  proof.retainedRelativePath == "\(entry.id.uuidString)/\(proof.attachmentVersionID.uuidString).retained",
                  !proof.restoreRelativePath.isEmpty, !proof.restoreRelativePath.hasPrefix("/"),
                  !proof.restoreRelativePath.utf8.contains(0), proof.restoreRelativePath.utf8.count <= 1024,
                  proof.restoreRelativePath.split(separator: "/", omittingEmptySubsequences: false)
                    .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw SyncDeletionLedgerError.corrupt }
        }
        let versions = Dictionary(uniqueKeysWithValues: entry.exactRemovalVersions.map { ($0.record.id, $0) })
        var markers: [DeletionMarker] = []
        for record in entry.domain.ownedRecords {
            let proof = try versions[record.id] ?? SyncRecordVersion(record: record)
            guard proof.record.deletedAt.value != nil else { throw SyncDeletionLedgerError.witnessMismatch }
            markers.append(.init(targetID: record.id, removalStamp: proof.record.deletedAt.stamp, removalVersionID: proof.versionID))
            if case let .projectCounter(state)? = record.payload.atomicDomain?.value {
                markers += state.reminders.map { .init(targetID: .init(kind: .knittingReminder, uuid: $0.id),
                    aggregateParentID: record.id, removalStamp: proof.record.deletedAt.stamp, removalVersionID: proof.versionID) }
            }
            if record.id.kind == .project, case let .data(bytes)? = record.payload.fields["domainSnapshot"]?.value {
                let project = try JSONDecoder().decode(SyncProjectProjection.self, from: bytes)
                markers += project.legacyPatterns.map { .init(targetID: .init(kind: .pattern, uuid: $0.id),
                    aggregateParentID: record.id, removalStamp: proof.record.deletedAt.stamp, removalVersionID: proof.versionID) }
            }
        }
        for (counter, reminders) in entry.domain.removedReminders {
            let parent = SyncEntityID(kind: .projectCounter, uuid: counter)
            guard let proof = versions[parent] else { throw SyncDeletionLedgerError.witnessMismatch }
            markers += reminders.map { .init(targetID: .init(kind: .knittingReminder, uuid: $0.id), aggregateParentID: parent,
                removalStamp: proof.record.payload.atomicDomain!.stamp, removalVersionID: proof.versionID) }
        }
        for (project, patterns) in entry.domain.removedLegacyPatterns {
            let parent = SyncEntityID(kind: .project, uuid: project)
            guard let proof = versions[parent], let field = proof.record.payload.fields["domainSnapshot"] else { throw SyncDeletionLedgerError.witnessMismatch }
            markers += patterns.map { .init(targetID: .init(kind: .pattern, uuid: $0.id), aggregateParentID: parent,
                removalStamp: field.stamp, removalVersionID: proof.versionID) }
        }
        return try markers.map { try $0.validated() }
    }
}
