import Foundation

struct SyncDeletedDomain: Codable, Equatable, Sendable {
    let rootIDs: Set<SyncEntityID>
    let ownedRecords: [SyncRecord]
    let supportingParentIDs: Set<SyncEntityID>
    let removedReminders: [UUID: [KnittingReminder]]
    let removedLegacyPatterns: [UUID: [PatternDocument]]
    /// Only the removed owner-to-photo association, never an old owner snapshot.
    let removedPhotoAssociations: [PhotoAssociation]?
    struct PhotoAssociation: Codable, Equatable, Sendable {
        let slot: SyncAttachmentSlot
        let filename: String
    }
    var photoAssociations: [PhotoAssociation] { removedPhotoAssociations ?? [] }
    /// Incoming selections preserve exact deleted canonical records. This set
    /// identifies only records removed by the caller's exact deletion batch;
    /// nil is the backward-compatible local pre-deletion representation.
    let restorableRecordIDs: Set<SyncEntityID>?
    var selectedLiveIDs: Set<SyncEntityID> {
        restorableRecordIDs ?? Set(ownedRecords.filter { $0.deletedAt.value == nil }.map(\.id))
    }

    struct Restoration {
        let records: [SyncRecord]
        let changedIDs: Set<SyncEntityID>
        let restoredAttachmentPredecessors: [UUID: UUID]
    }

    /// This view is validated by the mapper before publication. Only selected
    /// records receive new overlays; supporting aggregates retain current state.
    func restoring(into current: [SyncRecord], now: Date, deviceID: String) throws -> Restoration {
        _ = try SyncRecordValidator().validate(current)
        var records = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        for parent in supportingParentIDs {
            if parent.kind == .pattern, records[parent] == nil {
                // Legacy documents are embedded in the current owning project.
                // Validate exact owner and slot below through the mapper too.
                let owners = try current.filter { $0.id.kind == .project && $0.deletedAt.value == nil }.filter {
                    guard case let .data(data)? = $0.payload.fields["domainSnapshot"]?.value else { return false }
                    return try JSONDecoder().decode(SyncProjectProjection.self, from: data).legacyPatterns.contains { $0.id == parent.uuid }
                }
                guard owners.count == 1 else { throw ProjectArchiveSyncMappingError.missingParent(parent) }
                continue
            }
            guard records[parent]?.deletedAt.value == nil, records[parent] != nil else {
                throw ProjectArchiveSyncMappingError.missingParent(parent)
            }
        }
        let maximum = current.map { max($0.entityRevision, $0.deletedAt.stamp.logicalRevision) }.max() ?? 0
        guard maximum < UInt64.max, now.timeIntervalSinceReferenceDate.isFinite else {
            throw SyncDeletionLedgerError.corrupt
        }
        let stamp = SyncMutationStamp(logicalRevision: maximum + 1, modifiedAt: now, deviceID: deviceID)
        var changed = Set<SyncEntityID>()
        for retained in ownedRecords where retained.id.kind != .attachment && selectedLiveIDs.contains(retained.id) {
            guard var record = records[retained.id], record.deletedAt.value != nil else {
                throw SyncDeletionLedgerError.witnessMismatch
            }
            record.deletedAt = .init(value: nil, stamp: stamp)
            record.payload.deletionCascade = nil
            record.entityRevision = stamp.logicalRevision
            if let atomic = record.payload.atomicDomain {
                record.payload.atomicDomain = .init(value: atomic.value, stamp: stamp)
            }
            records[record.id] = record
            changed.insert(record.id)
        }
        var predecessors: [UUID: UUID] = [:]
        let heads = try SyncAttachmentLineage(records: ownedRecords).headsBySlot.values.flatMap { $0 }
        guard UInt64(heads.count) < UInt64.max - maximum else { throw SyncDeletionLedgerError.corrupt }
        for (index, retained) in heads.enumerated() where selectedLiveIDs.contains(retained.id) {
            guard let predecessor = records[retained.id], predecessor.deletedAt.value != nil,
                  let old = predecessor.payload.attachment, old == retained.payload.attachment else {
                throw SyncDeletionLedgerError.witnessMismatch
            }
            let child = try SyncAttachmentVersion.issuing(slot: old.slot,
                contentSHA256: old.contentSHA256, byteCount: old.byteCount,
                mediaType: old.mediaType, displayFilename: old.displayFilename,
                replacesVersionID: old.versionID)
            // Each slot's heads already have the canonical lineage ordering.
            // Distinct observed revisions preserve its winner after issuance;
            // fresh UUID lexical order must not choose restored user bytes.
            let childStamp = SyncMutationStamp(logicalRevision: maximum + UInt64(index) + 1,
                modifiedAt: now, deviceID: deviceID)
            let record = SyncRecord(schemaVersion: retained.schemaVersion, id: .init(kind: .attachment, uuid: child.versionID),
                createdAt: now, entityRevision: childStamp.logicalRevision,
                payload: .init(fields: retained.payload.fields.mapValues { .init(value: $0.value, stamp: childStamp) }, attachment: child),
                relationships: retained.relationships, deletedAt: .init(value: nil, stamp: childStamp))
            records[record.id] = record
            changed.insert(record.id)
            predecessors[child.versionID] = old.versionID
        }
        var projectReminderIDs: [UUID: [UUID]] = [:]
        for association in photoAssociations {
            let id = association.slot.owner
            guard var record = records[id], record.deletedAt.value == nil,
                  case let .data(data)? = record.payload.fields["domainSnapshot"]?.value,
                  var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SyncDeletionLedgerError.witnessMismatch
            }
            if association.slot.role == "yarn-label-photo" {
                guard var names = object["labelPhotoFilenames"] as? [String],
                      var ids = object["labelPhotoSlotIDs"] as? [String],
                      let slotID = UUID(uuidString: String(association.slot.slotID.dropFirst("label:".count))),
                      !ids.compactMap(UUID.init(uuidString:)).contains(slotID),
                      !names.contains(association.filename), names.count < 2 else {
                    throw SyncDeletionLedgerError.witnessMismatch
                }
                names.append(association.filename); ids.append(slotID.uuidString)
                object["labelPhotoFilenames"] = names; object["labelPhotoSlotIDs"] = ids
            } else {
                guard object["photoFilename"] == nil || object["photoFilename"] is NSNull else {
                    throw SyncDeletionLedgerError.witnessMismatch
                }
                object["photoFilename"] = association.filename
            }
            record.payload.fields["domainSnapshot"] = .init(value: .data(try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)), stamp: stamp)
            record.entityRevision = stamp.logicalRevision
            record.deletedAt = .init(value: nil, stamp: stamp)
            records[id] = record
            changed.insert(id)
        }
        for (counterID, reminders) in removedReminders {
            let id = SyncEntityID(kind: .projectCounter, uuid: counterID)
            guard var record = records[id], record.deletedAt.value == nil,
                  case let .projectCounter(state)? = record.payload.atomicDomain?.value,
                  let project = record.relationships.first(where: { $0.role == "project" })?.target,
                  Set(state.reminders.map(\.id)).isDisjoint(with: reminders.map(\.id)) else {
                throw SyncDeletionLedgerError.witnessMismatch
            }
            let merged = SyncCounterReminderState(counter: state.counter,
                reminders: state.reminders + reminders, preparedCommand: state.preparedCommand,
                processedCommandIDs: state.processedCommandIDs,
                processedCommandProofs: state.processedCommandProofs, occurrence: state.occurrence)
            record.payload.atomicDomain = .init(value: .projectCounter(merged), stamp: stamp)
            record.entityRevision = stamp.logicalRevision
            record.deletedAt = .init(value: nil, stamp: stamp)
            records[id] = record
            changed.insert(id)
            projectReminderIDs[project.uuid, default: []] += reminders.map(\.id)
        }
        for projectID in Set(projectReminderIDs.keys).union(removedLegacyPatterns.keys) {
            let id = SyncEntityID(kind: .project, uuid: projectID)
            guard var record = records[id], record.deletedAt.value == nil,
                  case let .data(data)? = record.payload.fields["domainSnapshot"]?.value,
                  var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SyncDeletionLedgerError.witnessMismatch
            }
            if let added = projectReminderIDs[projectID] {
                guard let order = object["reminderOrder"] as? [String] else { throw SyncDeletionLedgerError.corrupt }
                object["reminderOrder"] = order + added.sorted { $0.uuidString < $1.uuidString }.map(\.uuidString)
            }
            if let added = removedLegacyPatterns[projectID] {
                let projection = try JSONDecoder().decode(SyncProjectProjection.self, from: data)
                guard Set(projection.legacyPatterns.map(\.id)).isDisjoint(with: added.map(\.id)) else {
                    throw SyncDeletionLedgerError.witnessMismatch
                }
                object["legacyPatterns"] = try JSONSerialization.jsonObject(with:
                    JSONEncoder().encode(projection.legacyPatterns + added))
            }
            record.payload.fields["domainSnapshot"] = .init(value: .data(try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)), stamp: stamp)
            record.entityRevision = stamp.logicalRevision
            record.deletedAt = .init(value: nil, stamp: stamp)
            records[id] = record
            changed.insert(id)
        }
        return .init(records: Array(records.values), changedIDs: changed,
            restoredAttachmentPredecessors: predecessors)
    }

    init(rootIDs: Set<SyncEntityID>, ownedRecords: [SyncRecord],
         supportingParentIDs: Set<SyncEntityID>, removedReminders: [UUID: [KnittingReminder]],
         removedLegacyPatterns: [UUID: [PatternDocument]] = [:],
         removedPhotoAssociations: [PhotoAssociation]? = nil,
         restorableRecordIDs: Set<SyncEntityID>? = nil) {
        self.rootIDs = rootIDs
        self.ownedRecords = ownedRecords
        self.supportingParentIDs = supportingParentIDs
        self.removedReminders = removedReminders
        self.removedLegacyPatterns = removedLegacyPatterns
        self.removedPhotoAssociations = removedPhotoAssociations
        self.restorableRecordIDs = restorableRecordIDs
    }

    /// Select only actual removals. Embedded values remain aggregate members;
    /// shared relationships contribute supporting identities, never payloads.
    static func capture(before: [SyncRecord], after: [SyncRecord],
                        beforeArchive: ProjectArchive, afterArchive: ProjectArchive) throws -> Self? {
        let afterByID = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
        let removed = before.filter {
            $0.deletedAt.value == nil && (afterByID[$0.id] == nil || afterByID[$0.id]?.deletedAt.value != nil)
        }
        let removedIDs = Set(removed.map(\.id))
        let removedSlots = Set(removed.compactMap { $0.payload.attachment?.slot })
        let owned = before.filter { removedIDs.contains($0.id) || $0.payload.attachment.map { removedSlots.contains($0.slot) } == true }
        let ownedIDs = Set(owned.map(\.id))
        var reminders: [UUID: [KnittingReminder]] = [:]
        var legacy: [UUID: [PatternDocument]] = [:]
        var photos: [PhotoAssociation] = []
        for project in beforeArchive.projects {
            guard let current = afterArchive.projects.first(where: { $0.id == project.id }) else { continue }
            let currentReminders = Set(current.knittingReminders.map(\.id))
            for reminder in project.knittingReminders where !currentReminders.contains(reminder.id)
                && !ownedIDs.contains(.init(kind: .projectCounter, uuid: reminder.counterID)) {
                reminders[reminder.counterID, default: []].append(reminder)
            }
            let currentPatterns = Set(current.patterns.map(\.id))
            let selected = project.patterns.filter { !currentPatterns.contains($0.id) }
            if !selected.isEmpty { legacy[project.id] = selected }
            if let filename = project.photoFilename, current.photoFilename == nil {
                photos.append(.init(slot: .init(owner: .init(kind: .project, uuid: project.id), role: "project-photo", slotID: "primary"), filename: filename))
            }
        }
        for yarn in beforeArchive.yarns {
            guard let current = afterArchive.yarns.first(where: { $0.id == yarn.id }) else { continue }
            let owner = SyncEntityID(kind: .yarn, uuid: yarn.id)
            if let filename = yarn.photoFilename, current.photoFilename == nil {
                photos.append(.init(slot: .init(owner: owner, role: "yarn-photo", slotID: "primary"), filename: filename))
            }
            for (index, slotID) in yarn.labelPhotoSlotIDs.enumerated() where !current.labelPhotoSlotIDs.contains(slotID) {
                photos.append(.init(slot: .init(owner: owner, role: "yarn-label-photo", slotID: "label:\(slotID.uuidString.lowercased())"), filename: yarn.labelPhotoFilenames[index]))
            }
        }
        guard !owned.isEmpty || !reminders.isEmpty || !legacy.isEmpty else { return nil }
        let legacyIDs = Set(legacy.values.flatMap { $0 }.map { SyncEntityID(kind: .pattern, uuid: $0.id) })
            .union(beforeArchive.projects.filter { ownedIDs.contains(.init(kind: .project, uuid: $0.id)) }
                .flatMap(\.patterns).map { .init(kind: .pattern, uuid: $0.id) })
        let supporting = Set(owned.flatMap(\.relationships).map(\.target))
            .subtracting(ownedIDs).subtracting(legacyIDs)
            .union(reminders.keys.map { .init(kind: .projectCounter, uuid: $0) })
            .union(legacy.keys.map { .init(kind: .project, uuid: $0) })
        var roots = Set(removed.filter { record in
            !record.relationships.contains { ownedIDs.contains($0.target) || legacyIDs.contains($0.target) }
        }.map(\.id))
        roots.formUnion(reminders.keys.map { .init(kind: .projectCounter, uuid: $0) })
        roots.formUnion(legacy.values.flatMap { $0 }.map { .init(kind: .pattern, uuid: $0.id) })
        return .init(rootIDs: roots, ownedRecords: owned, supportingParentIDs: supporting,
                     removedReminders: reminders, removedLegacyPatterns: legacy,
                     removedPhotoAssociations: photos.isEmpty ? nil : photos)
    }
}

struct SyncDeletionFileProof: Codable, Equatable, Sendable {
    let attachmentVersionID: UUID
    let restoreRelativePath: String
    let retainedRelativePath: String
    let byteCount: Int64
    let sha256: Data
}

struct SyncDeletionEntry: Codable, Equatable, Sendable {
    let id: UUID
    let deletedAt: Date
    let domain: SyncDeletedDomain
    let exactRemovalVersions: [SyncRecordVersion]
    let files: [SyncDeletionFileProof]
}
