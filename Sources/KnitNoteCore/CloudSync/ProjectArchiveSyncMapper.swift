import CryptoKit
import Foundation

public enum ProjectArchiveSyncMappingError: Error, Equatable, Sendable {
    case unsupportedArchive(Int)
    case invalidDomain(SyncEntityID)
    case missingParent(SyncEntityID)
    case missingAttachment(SyncAttachmentSlot)
    case unstagedAttachment(UUID)
    case unsafePath
}

/// Immutable transaction input. No mutable store is captured by the provider.
public struct SyncExportPackage: SyncRecordProvider, Sendable {
    public let records: [SyncRecord]
    public let attachments: [UUID: SyncAttachmentSource]
    public let possibleDuplicates: [PossibleDuplicate]
    /// Archive auxiliaries with no remote owner. The installer must preserve
    /// both this metadata and its original file paths during replacement.
    public let localOnlyPatternAssets: [PatternAsset]
    public let localOnlyRelativePaths: [String]

    public func record(for id: SyncEntityID) throws -> SyncRecord? {
        records.first { $0.id == id }
    }
}

public struct ProjectArchiveSyncFile: Sendable {
    public let relativePath: String
    public let source: SyncAttachmentSource
    public let version: SyncAttachmentVersion
}

public struct ProjectArchiveSyncMaterialization: Sendable {
    public let archive: ProjectArchive
    public let files: [ProjectArchiveSyncFile]
    /// Keep these exact versions when installing; archive JSON alone cannot
    /// encode Watch proof/processed-ID state or attachment tombstones.
    public let records: [SyncRecord]
    public let counterStates: [UUID: SyncCounterReminderState]
    public let localOnlyRelativePaths: [String]
}

/// Accounting projection only: no URLs, physical verification or install authority.
struct ProjectArchiveSyncUnvalidatedProjection {
    struct File {
        let relativePath: String
        let version: SyncAttachmentVersion
        let proof: SyncBootstrapOutputProof
    }
    let archive: ProjectArchive
    let files: [File]
    let records: [SyncRecord]
    let counterStates: [UUID: SyncCounterReminderState]
    let localOnlyRelativePaths: [String]
}

public enum ProjectArchiveSyncMapper {
    static func projectUnvalidated(records: [SyncRecord],
        attachmentProofs: [UUID: SyncBootstrapOutputProof],
        baseArchive: ProjectArchive) throws -> ProjectArchiveSyncUnvalidatedProjection {
        try project(records: records, baseArchive: baseArchive) { version in
            guard let proof = attachmentProofs[version.versionID] else {
                throw ProjectArchiveSyncMappingError.missingAttachment(version.slot)
            }
            guard proof.byteCount == version.byteCount, proof.sha256 == version.contentSHA256 else {
                throw ProjectArchiveSyncMappingError.invalidDomain(.init(kind: .attachment, uuid: version.versionID))
            }
            return proof
        }
    }

    /// The caller must freeze archive/files and supply the matching publication
    /// cache before export. Disk evidence is read under its existing file lock;
    /// this method does not install data, move source bytes, or publish mutations.
    public static func export(
        archive: ProjectArchive,
        liveRoot: URL,
        deviceID: String,
        reusing cache: SyncPublicationProjectionCache? = nil,
        preparedWatchCommand: PreparedWatchCommand? = nil,
        processedWatchLedger: ProcessedWatchCommandLedger = .init(),
        processedWatchProofs: [SyncProcessedWatchCommandProof] = [],
        issuedAttachmentRecords: [SyncRecord]? = nil
    ) throws -> SyncExportPackage {
        try exportReadingEvidence(archive: archive, liveRoot: liveRoot, deviceID: deviceID, reusing: cache,
            preparedWatchCommand: preparedWatchCommand, processedWatchLedger: processedWatchLedger,
            processedWatchProofs: processedWatchProofs, issuedAttachmentRecords: issuedAttachmentRecords,
            frozenEvidence: nil)
    }

    /// Internal bootstrap seam: the evidence comes from the native read-only
    /// loader under the same storage ownership as the frozen source inventory.
    static func exportFrozenSource(archive: ProjectArchive, liveRoot: URL, deviceID: String,
        preparedWatchCommand: PreparedWatchCommand?, processedWatchLedger: ProcessedWatchCommandLedger,
        evidence: SyncAttachmentPublicationEvidence) throws -> SyncExportPackage {
        try exportReadingEvidence(archive: archive, liveRoot: liveRoot, deviceID: deviceID, reusing: nil,
            preparedWatchCommand: preparedWatchCommand, processedWatchLedger: processedWatchLedger,
            processedWatchProofs: [], issuedAttachmentRecords: nil, frozenEvidence: evidence)
    }

    private static func exportReadingEvidence(archive: ProjectArchive, liveRoot: URL, deviceID: String,
        reusing cache: SyncPublicationProjectionCache?, preparedWatchCommand: PreparedWatchCommand?,
        processedWatchLedger: ProcessedWatchCommandLedger, processedWatchProofs: [SyncProcessedWatchCommandProof],
        issuedAttachmentRecords: [SyncRecord]?, frozenEvidence: SyncAttachmentPublicationEvidence?) throws -> SyncExportPackage {
        guard ProjectArchive.isSupported(version: archive.version) else {
            throw ProjectArchiveSyncMappingError.unsupportedArchive(archive.version)
        }
        try validateArchiveIdentities(archive)
        let root = liveRoot.standardizedFileURL
        let references = try SyncArchiveAttachmentReferences(liveRoot: root).references(in: archive)
        for reference in references { _ = try relativePath(reference.sourceURL, root: root) }
        let evidenceURL = root.appendingPathComponent("SyncMetadata/attachment-versions.json")
        let evidence: SyncAttachmentPublicationEvidence
        if let frozenEvidence { evidence = frozenEvidence }
        else if issuedAttachmentRecords == nil && FileManager.default.fileExists(atPath: evidenceURL.path) {
            evidence = try SyncAttachmentPublicationEvidenceFile(url: evidenceURL).load()
        } else { evidence = .init() }
        let issued = issuedAttachmentRecords ?? evidence.retainedAttachmentRecords
        if issuedAttachmentRecords == nil,
           !Set(evidence.versionsBySlot().values.map(\.versionID)).isSubset(of: Set(issued.map(\.id.uuid))) {
            // A legacy version without its immutable record is not enough
            // authority to recreate or replace that version during export.
            throw SyncPublicationTransactionFileError.corrupt
        }
        _ = try SyncRecordValidator().validate(issued)
        let lineage = try SyncAttachmentLineage(records: issued)
        var versions: [SyncAttachmentSlot: SyncAttachmentVersion] = [:]
        var issuedBySlot: [SyncAttachmentSlot: SyncRecord] = [:]
        for (slot, record) in lineage.resolvedHeadsBySlot() {
            versions[slot] = record.payload.attachment!
            issuedBySlot[slot] = record
        }
        var successorStamps: [SyncAttachmentSlot: SyncMutationStamp] = [:]
        var exhaustedSlots: Set<SyncAttachmentSlot> = []
        for (slot, history) in Dictionary(grouping: issued, by: { $0.payload.attachment!.slot }) {
            let revision = history.map { $0.deletedAt.stamp.logicalRevision }.max()!
            let dates = history.map { $0.deletedAt.stamp.modifiedAt }
            guard revision < UInt64.max, dates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
                exhaustedSlots.insert(slot)
                continue
            }
            successorStamps[slot] = .init(logicalRevision: revision + 1,
                modifiedAt: dates.max()!, deviceID: deviceID)
        }
        // Bootstrap has no issued identity yet. A frozen source produces the
        // same initial issuance on retry; later replacements reuse the durable
        // canonical issuance supplied by the transaction owner.
        let projection = try SyncPublicationProjector(
            deviceID: deviceID,
            preparedWatchCommand: preparedWatchCommand,
            processedWatchLedger: processedWatchLedger,
            processedWatchProofs: processedWatchProofs + evidence.watchCommandProofs,
            reusing: cache,
            attachmentReferences: { candidate in
                try SyncArchiveAttachmentReferences(liveRoot: root).references(in: candidate).map { reference in
                    let compatibleRole: String
                    switch reference.slot.role {
                    case "pattern-markup": compatibleRole = "usage-markup"
                    case "legacy-pattern-markup": compatibleRole = "legacy-markup"
                    default: return reference
                    }
                    let slots = versions.keys.filter {
                        $0.owner == reference.slot.owner && $0.slotID == reference.slot.slotID
                            && [reference.slot.role, compatibleRole].contains($0.role)
                    }
                    // A role is part of an immutable identity. Resolve the
                    // existing owner/page history before any initial issuance.
                    // Parallel aliases remain an explicit repair gate.
                    guard slots.count <= 1 else { throw SyncPublicationError.pendingRepair }
                    return SyncAttachmentReference(slot: slots.first ?? reference.slot,
                        sourceURL: reference.sourceURL, mediaType: reference.mediaType,
                        displayFilename: reference.displayFilename)
                }
            },
            issuedAttachmentVersions: versions,
            issuedAttachmentRecords: issuedBySlot,
            deletedAttachmentVersionIDs: Set(issued.filter { $0.deletedAt.value != nil }.map(\.id.uuid)),
            now: { Date(timeIntervalSinceReferenceDate: 0) },
            makeAttachmentVersionID: { reference, read, parent in
                let stamp = successorStamps[reference.slot]
                return deterministicSyncUUID(kind: .attachment, components: [
                    "archive-bootstrap-v1", deviceID, reference.slot.owner.kind.rawValue,
                    reference.slot.owner.uuid.uuidString, reference.slot.role, reference.slot.slotID,
                    read.sha256.base64EncodedString(), String(read.byteCount), reference.mediaType,
                    reference.displayFilename, parent?.uuidString ?? ""
                ] + (stamp.map { [String($0.logicalRevision), String($0.modifiedAt.timeIntervalSinceReferenceDate)] } ?? []))
            },
            issueUnissuedAttachments: true
        ).project(before: cache?.archive ?? .init(version: archive.version, projects: []), after: archive, manifest: [:])
        var records = projection.cache.records
        for record in (cache.map { Array($0.records.values) } ?? []) where record.deletedAt.value != nil {
            guard records[record.id] == nil else { throw ProjectArchiveSyncMappingError.invalidDomain(record.id) }
            records[record.id] = record
        }
        for record in issued { records[record.id] = record }
        for mutation in projection.mutations {
            if case let .save(save) = mutation, save.recordVersion.record.id.kind == .attachment {
                let record = save.recordVersion.record
                // Keep an issued tombstone exact. A new removal must instead
                // dominate issued history, changing only the deletion overlay
                // and never the immutable attachment snapshot.
                if record.deletedAt.value != nil {
                    if records[record.id]?.deletedAt.value != nil { continue }
                    guard !exhaustedSlots.contains(record.payload.attachment!.slot),
                          let stamp = successorStamps[record.payload.attachment!.slot] else {
                        throw SyncMergeError.corruptAttachmentVersion(record.id.uuid)
                    }
                    var deletion = record
                    deletion.deletedAt = .init(value: stamp.modifiedAt, stamp: stamp)
                    records[record.id] = deletion
                    continue
                }
                guard !exhaustedSlots.contains(record.payload.attachment!.slot) else {
                    throw SyncMergeError.corruptAttachmentVersion(record.id.uuid)
                }
                if let stamp = successorStamps[record.payload.attachment!.slot] {
                    records[record.id] = SyncRecord(schemaVersion: record.schemaVersion, id: record.id,
                        createdAt: stamp.modifiedAt, entityRevision: stamp.logicalRevision,
                        payload: .init(fields: record.payload.fields.mapValues { .init(value: $0.value, stamp: stamp) }, attachment: record.payload.attachment),
                        relationships: record.relationships, deletedAt: .init(value: nil, stamp: stamp))
                } else { records[record.id] = record }
            }
        }
        var attachments: [UUID: SyncAttachmentSource] = [:]
        for attachment in projection.attachments.values {
            let version = attachment.version
            _ = try destination(version, archive: archive)
            let id = SyncEntityID(kind: .attachment, uuid: version.versionID)
            if records[id] == nil { records[id] = issuedBySlot[version.slot] }
            guard records[id]?.payload.attachment == version else {
                throw ProjectArchiveSyncMappingError.invalidDomain(id)
            }
            attachments[version.versionID] = try SyncAttachmentSource(
                fileURL: attachment.reference.sourceURL,
                contentSHA256: version.contentSHA256, byteCount: version.byteCount
            )
        }
        let ordered = records.values.sorted(by: recordLess)
        _ = try SyncRecordValidator().validate(ordered)
        let orphanAssets = localOnlyAssets(in: archive)
        return SyncExportPackage(records: ordered, attachments: attachments,
            possibleDuplicates: PossibleDuplicateDetector.detect(projects: archive.projects),
            localOnlyPatternAssets: orphanAssets,
            localOnlyRelativePaths: try orphanAssets.map(assetPath))
    }

    /// All sources must be staged by the caller. Verification binds every
    /// install intent to the immutable version and rejects symlinks/oversize
    /// files before returning; the eventual installer must reverify on copy.
    public static func materialize(
        records: [SyncRecord],
        attachments: [UUID: SyncAttachmentSource],
        baseArchive: ProjectArchive
    ) throws -> ProjectArchiveSyncMaterialization {
        var admitted: [UUID: SyncAttachmentSource] = [:]
        let projection = try project(records: records, baseArchive: baseArchive) { version in
            let id = version.versionID
            guard let source = attachments[id] else { throw ProjectArchiveSyncMappingError.missingAttachment(version.slot) }
            guard source.isJournalStaged else { throw ProjectArchiveSyncMappingError.unstagedAttachment(id) }
            guard source.contentSHA256 == version.contentSHA256, source.byteCount == version.byteCount else {
                throw ProjectArchiveSyncMappingError.invalidDomain(.init(kind: .attachment, uuid: id))
            }
            _ = try SyncRegularFileReader().read(source.fileURL,
                maximumBytes: SyncPublicationFileLimits.maximumAttachmentBytes,
                expected: .init(byteCount: version.byteCount, sha256: version.contentSHA256))
            admitted[id] = source
            return .init(byteCount: source.byteCount, sha256: source.contentSHA256)
        }
        // Every projected file was admitted at its original physical-read boundary.
        let files = projection.files.map {
            ProjectArchiveSyncFile(relativePath: $0.relativePath, source: admitted[$0.version.versionID]!, version: $0.version)
        }
        return .init(archive: projection.archive, files: files, records: projection.records,
            counterStates: projection.counterStates, localOnlyRelativePaths: projection.localOnlyRelativePaths)
    }

    private static func project(records: [SyncRecord], baseArchive: ProjectArchive,
        attachmentProof: (SyncAttachmentVersion) throws -> SyncBootstrapOutputProof
    ) throws -> ProjectArchiveSyncUnvalidatedProjection {
        guard ProjectArchive.isSupported(version: baseArchive.version) else {
            throw ProjectArchiveSyncMappingError.unsupportedArchive(baseArchive.version)
        }
        _ = try SyncRecordValidator().validate(records)
        let live = records.filter { $0.deletedAt.value == nil }
        let byID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        let legacyPatternIDs = Set(try live.filter { $0.id.kind == .project }.flatMap {
            try decode(SyncProjectProjection.self, record: $0).legacyPatterns.map(\.id)
        })
        for record in live {
            for relationship in record.relationships where byID[relationship.target] == nil {
                guard record.id.kind == .attachment,
                      relationship.target.kind == .pattern,
                      legacyPatternIDs.contains(relationship.target.uuid) else {
                    throw ProjectArchiveSyncMappingError.missingParent(relationship.target)
                }
            }
        }
        var states: [UUID: SyncCounterReminderState] = [:]
        for record in live where record.id.kind == .projectCounter {
            guard case let .projectCounter(state)? = record.payload.atomicDomain?.value else {
                throw ProjectArchiveSyncMappingError.invalidDomain(record.id)
            }
            states[record.id.uuid] = state
        }
        var projects: [StoredProject] = []
        for record in live where record.id.kind == .project {
            let projection = try decode(SyncProjectProjection.self, record: record)
            guard projection.id == record.id.uuid else { throw ProjectArchiveSyncMappingError.invalidDomain(record.id) }
            let counterRecords = live.filter { $0.id.kind == .projectCounter && parent($0, "project") == record.id }
            let counters = try counterRecords.map { item -> ProjectCounter in
                guard let counter = states[item.id.uuid]?.counter else { throw ProjectArchiveSyncMappingError.invalidDomain(item.id) }
                return counter
            }
            let order = projection.counterOrder ?? counters.sorted { $0.defaultOrdinal < $1.defaultOrdinal }.map(\.id)
            guard counters.count == 6, Set(order).count == 6, Set(order) == Set(counters.map(\.id)),
                  Set(counters.map(\.defaultOrdinal)) == Set(1...6),
                  order.contains(projection.selectedCounterID) else { throw ProjectArchiveSyncMappingError.invalidDomain(record.id) }
            let orderedCounters = order.map { id in counters.first { $0.id == id }! }
            // Atomic counter state owns note content; standalone records must
            // resolve uniquely and agree, never override a winning aggregate.
            for noteRecord in live where noteRecord.id.kind == .rowNote && parent(noteRecord, "project") == record.id {
                let note = try decode(RowNote.self, record: noteRecord)
                let owners = counters.filter {
                    deterministicSyncUUID(kind: .rowNote, components: [projection.id.uuidString, $0.id.uuidString, String(note.row)]) == noteRecord.id.uuid
                }
                guard owners.count == 1, owners[0].rowNotes.contains(note) else { throw ProjectArchiveSyncMappingError.invalidDomain(noteRecord.id) }
            }
            let entries = try live.filter { $0.id.kind == .journalEntry && parent($0, "project") == record.id }.map {
                let entry = try decode(ProjectJournalEntry.self, record: $0)
                guard entry.id == $0.id.uuid else { throw ProjectArchiveSyncMappingError.invalidDomain($0.id) }
                return entry
            }
            var object = try dictionary(projection)
            object["patterns"] = object.removeValue(forKey: "legacyPatterns")
            object["updatedAt"] = (projection.updatedAt ?? record.payload.fields["domainSnapshot"]!.stamp.modifiedAt).timeIntervalSinceReferenceDate
            object["counters"] = try jsonValue(orderedCounters)
            let reminders = order.flatMap { states[$0]!.reminders }
            let reminderOrder = projection.reminderOrder ?? reminders.map(\.id)
            guard Set(reminderOrder) == Set(reminders.map(\.id)), reminderOrder.count == reminders.count else { throw ProjectArchiveSyncMappingError.invalidDomain(record.id) }
            object["knittingReminders"] = try jsonValue(reminderOrder.map { id in reminders.first { $0.id == id }! })
            object["journalEntries"] = try jsonValue(entries)
            if case let .string(name)? = record.payload.fields["name"]?.value { object["name"] = name }
            let reconstructed = try decodeObject(StoredProject.self, object)
            guard reconstructed.counters == orderedCounters else {
                throw ProjectArchiveSyncMappingError.invalidDomain(record.id)
            }
            projects.append(reconstructed)
        }
        var yarns: [StoredYarn] = []
        for record in live where record.id.kind == .yarn {
            let projection = try decode(SyncYarnProjection.self, record: record)
            guard projection.id == record.id.uuid else { throw ProjectArchiveSyncMappingError.invalidDomain(record.id) }
            let links = try live.filter { $0.id.kind == .projectYarnLink && parent($0, "yarn") == record.id }.map { link -> UUID in
                let value = try SyncProjectYarnLinkProjection.validated(link,
                    authority: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }))
                guard value.yarnID == projection.id, parent(link, "project")?.uuid == value.projectID else {
                    throw ProjectArchiveSyncMappingError.invalidDomain(link.id)
                }
                return value.projectID
            }
            guard Set(links).count == links.count else { throw ProjectArchiveSyncMappingError.invalidDomain(record.id) }
            var object = try dictionary(projection)
            object["linkedProjectIDs"] = try jsonValue(links)
            // Link-only edits intentionally do not republish yarn metadata.
            // Preserve the local bookkeeping timestamp when the base has one.
            let stamp = record.payload.fields["domainSnapshot"]!.stamp.modifiedAt
            object["updatedAt"] = max(stamp,
                baseArchive.yarns.first(where: { $0.id == projection.id })?.updatedAt ?? stamp
            ).timeIntervalSinceReferenceDate
            if case let .string(name)? = record.payload.fields["name"]?.value { object["name"] = name }
            yarns.append(try decodeObject(StoredYarn.self, object))
        }
        let folders: [PatternFolder] = try domains(live, kind: .patternFolder)
        let patterns: [StoredPattern] = try domains(live, kind: .pattern)
        let usages: [PatternProjectUsage] = try domains(live, kind: .patternUsage)
        for usage in usages {
            let id = SyncEntityID(kind: .patternUsage, uuid: usage.id)
            guard parent(byID[id]!, "project") == .init(kind: .project, uuid: usage.projectID),
                  parent(byID[id]!, "pattern") == .init(kind: .pattern, uuid: usage.patternID) else {
                throw ProjectArchiveSyncMappingError.invalidDomain(id)
            }
        }
        var assets: [UUID: PatternAsset] = [:]
        for pattern in patterns {
            let record = byID[.init(kind: .pattern, uuid: pattern.id)]!
            let asset: PatternAsset
            if record.payload.fields["assetSnapshot"] != nil {
                asset = try decode(PatternAsset.self, record: record, field: "assetSnapshot")
            } else if let existing = baseArchive.patternAssets.first(where: { $0.id == pattern.assetID }) { asset = existing }
            else { throw ProjectArchiveSyncMappingError.invalidDomain(record.id) }
            guard asset.id == pattern.assetID, assets[asset.id].map({ $0 == asset }) ?? true else {
                throw ProjectArchiveSyncMappingError.invalidDomain(record.id)
            }
            assets[asset.id] = asset
        }
        let localAssets = localOnlyAssets(in: baseArchive).filter { assets[$0.id] == nil }
        var archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: projects, yarns: yarns,
            patternFolders: folders, patternAssets: Array(assets.values) + localAssets, patterns: patterns, patternUsages: usages)
        archive.projects.sort { $0.id.uuidString < $1.id.uuidString }
        archive.yarns.sort { $0.id.uuidString < $1.id.uuidString }
        archive.patternAssets.sort { $0.id.uuidString < $1.id.uuidString }
        try validateArchiveIdentities(archive)
        let lineage = try SyncAttachmentLineage(records: records)
        var files: [ProjectArchiveSyncUnvalidatedProjection.File] = []
        var slots: Set<SyncAttachmentSlot> = []
        for (slot, id) in lineage.resolvedLiveVersionIDs() {
            let version = lineage.recordsByVersionID[id]!.payload.attachment!
            // Preserve the ordinary per-slot source checks before destination errors.
            let proof = try attachmentProof(version)
            let path = try destination(version, archive: archive)
            guard !files.contains(where: { $0.relativePath == path && $0.proof.sha256 != proof.sha256 }) else {
                throw ProjectArchiveSyncMappingError.invalidDomain(.init(kind: .attachment, uuid: id))
            }
            files.append(.init(relativePath: path, version: version, proof: proof))
            slots.insert(slot)
        }
        // Enumerate required media without consulting the live filesystem;
        // optional markup pages are represented only by attachment records.
        for slot in requiredSlots(archive) where !slots.contains(slot) {
            throw ProjectArchiveSyncMappingError.missingAttachment(slot)
        }
        return .init(archive: archive, files: files.sorted { $0.relativePath < $1.relativePath },
            records: records, counterStates: states, localOnlyRelativePaths: try localAssets.map(assetPath))
    }

    private static func decode<T: Decodable>(_ type: T.Type, record: SyncRecord, field: String = "domainSnapshot") throws -> T {
        guard case let .data(data)? = record.payload.fields[field]?.value else { throw ProjectArchiveSyncMappingError.invalidDomain(record.id) }
        return try JSONDecoder().decode(type, from: data)
    }
    private static func jsonValue<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed]) }
    private static func dictionary<T: Encodable>(_ value: T) throws -> [String: Any] { try jsonValue(value) as! [String: Any] }
    private static func decodeObject<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }
    private static func parent(_ record: SyncRecord, _ role: String) -> SyncEntityID? { record.relationships.first { $0.role == role }?.target }
    private static func domains<T: Decodable & Identifiable>(_ records: [SyncRecord], kind: SyncEntityKind) throws -> [T] where T.ID == UUID {
        try records.filter { $0.id.kind == kind }.map {
            let value = try decode(T.self, record: $0)
            guard value.id == $0.id.uuid else { throw ProjectArchiveSyncMappingError.invalidDomain($0.id) }
            return value
        }
    }
    private static func recordLess(_ a: SyncRecord, _ b: SyncRecord) -> Bool {
        (a.id.kind.rawValue, a.id.uuid.uuidString) < (b.id.kind.rawValue, b.id.uuid.uuidString)
    }
    private static func localOnlyAssets(in archive: ProjectArchive) -> [PatternAsset] {
        let owned = Set(archive.patterns.map(\.assetID))
        return archive.patternAssets.filter { !owned.contains($0.id) }
    }
    private static func assetPath(_ asset: PatternAsset) throws -> String { "Patterns/Assets/" + (try filename(asset.storedFilename)) }
    private static func filename(_ value: String) throws -> String {
        guard !value.isEmpty, value != ".", value != "..", !value.contains("/"), !value.contains("\\"), !value.contains("\0") else { throw ProjectArchiveSyncMappingError.unsafePath }
        return value
    }
    private static func relativePath(_ url: URL, root: URL) throws -> String {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root.path + "/"), url.resolvingSymlinksInPath().path == path else { throw ProjectArchiveSyncMappingError.unsafePath }
        return String(path.dropFirst(root.path.count + 1))
    }
    private static func validateArchiveIdentities(_ archive: ProjectArchive) throws {
        _ = try PatternLibrarySnapshot(folders: archive.patternFolders, assets: archive.patternAssets,
            patterns: archive.patterns, usages: archive.patternUsages, validProjectIDs: archive.projects.map(\.id)).validated(
                nameContext: .init(locale: Locale(identifier: "en"), reservedNames: []))
        for pattern in archive.patterns {
            if let folderID = pattern.folderID, !archive.patternFolders.contains(where: { $0.id == folderID }) {
                throw ProjectArchiveSyncMappingError.missingParent(.init(kind: .patternFolder, uuid: folderID))
            }
        }
        var ids: Set<SyncEntityID> = []
        func insert(_ id: UUID, _ kind: SyncEntityKind) throws {
            guard ids.insert(.init(kind: kind, uuid: id)).inserted else { throw SyncRecordValidationError.duplicateRecord(.init(kind: kind, uuid: id)) }
        }
        for project in archive.projects {
            try insert(project.id, .project)
            for counter in project.counters { try insert(counter.id, .projectCounter) }
            for entry in project.journalEntries { try insert(entry.id, .journalEntry) }
        }
        for yarn in archive.yarns {
            try insert(yarn.id, .yarn)
            for id in yarn.linkedProjectIDs where !archive.projects.contains(where: { $0.id == id }) { throw ProjectArchiveSyncMappingError.missingParent(.init(kind: .project, uuid: id)) }
        }
    }

    private static func requiredSlots(_ archive: ProjectArchive) -> [SyncAttachmentSlot] {
        var result: [SyncAttachmentSlot] = []
        func add(_ kind: SyncEntityKind, _ id: UUID, _ role: String, _ slot: String = "primary") {
            result.append(.init(owner: .init(kind: kind, uuid: id), role: role, slotID: slot))
        }
        for project in archive.projects {
            if project.photoFilename != nil { add(.project, project.id, "project-photo") }
            for pattern in project.patterns { add(.pattern, pattern.id, "legacy-pattern-source", "project:\(project.id.uuidString)/source") }
            for entry in project.journalEntries { add(.journalEntry, entry.id, "journal-photo"); add(.journalEntry, entry.id, "journal-thumbnail") }
        }
        for yarn in archive.yarns {
            if yarn.photoFilename != nil { add(.yarn, yarn.id, "yarn-photo") }
            for id in yarn.labelPhotoSlotIDs { add(.yarn, yarn.id, "yarn-label-photo", "label:\(id.uuidString.lowercased())") }
        }
        for pattern in archive.patterns { add(.pattern, pattern.id, "pattern-source", "source") }
        return result
    }

    private static func destination(_ version: SyncAttachmentVersion, archive: ProjectArchive) throws -> String {
        let slot = version.slot
        let owner = slot.owner.uuid
        let name = try filename(version.displayFilename)
        func require(_ expected: String?, _ expectedSlot: String = "primary") throws {
            guard expected == name, slot.slotID == expectedSlot else { throw ProjectArchiveSyncMappingError.invalidDomain(.init(kind: .attachment, uuid: version.versionID)) }
        }
        switch slot.role {
        case "project-photo":
            try require(archive.projects.first { $0.id == owner }?.photoFilename)
            return "ProjectPhotos/" + name
        case "yarn-photo":
            try require(archive.yarns.first { $0.id == owner }?.photoFilename)
            return "YarnPhotos/" + name
        case "journal-photo", "journal-thumbnail":
            let entry = archive.projects.flatMap(\.journalEntries).first { $0.id == owner }
            try require(slot.role == "journal-photo" ? entry?.photoFilename : entry?.thumbnailFilename)
            return "ProjectJournalPhotos/" + name
        case "yarn-label-photo":
            guard let yarn = archive.yarns.first(where: { $0.id == owner }),
                  let index = yarn.labelPhotoFilenames.firstIndex(of: name), index < yarn.labelPhotoSlotIDs.count else { throw ProjectArchiveSyncMappingError.unsafePath }
            try require(name, "label:\(yarn.labelPhotoSlotIDs[index].uuidString.lowercased())")
            return "YarnLabelPhotos/" + name
        case "pattern-source":
            guard let pattern = archive.patterns.first(where: { $0.id == owner }),
                  let asset = archive.patternAssets.first(where: { $0.id == pattern.assetID }),
                  asset.byteCount == version.byteCount,
                  asset.sha256.lowercased() == version.contentSHA256.map({ String(format: "%02x", $0) }).joined() else { throw ProjectArchiveSyncMappingError.unsafePath }
            try require(asset.storedFilename, "source")
            return try assetPath(asset)
        case "pattern-markup", "usage-markup":
            guard archive.patternUsages.contains(where: { $0.id == owner }), let page = pageIndex(slot.slotID, prefix: "page:") else { throw ProjectArchiveSyncMappingError.unsafePath }
            try require("\(page).json", "page:\(page)")
            return "Patterns/UsageMarkup/\(owner.uuidString)/\(name)"
        case "legacy-pattern-source", "legacy-pattern-markup", "legacy-markup":
            let matches = archive.projects.filter { $0.patterns.contains(where: { $0.id == owner }) }
            guard matches.count == 1, let project = matches.first,
                  let pattern = project.patterns.first(where: { $0.id == owner }) else { throw ProjectArchiveSyncMappingError.unsafePath }
            if slot.role == "legacy-pattern-source" {
                try require(pattern.storedFilename, "project:\(project.id.uuidString)/source")
                return "Patterns/\(project.id.uuidString)/" + name
            }
            let prefix = "project:\(project.id.uuidString)/page:"
            guard let page = pageIndex(slot.slotID, prefix: prefix) else { throw ProjectArchiveSyncMappingError.unsafePath }
            try require("\(page).json", prefix + String(page))
            return "Patterns/\(project.id.uuidString)/Markup/\(owner.uuidString)/" + name
        default: throw ProjectArchiveSyncMappingError.unsafePath
        }
    }
    private static func pageIndex(_ value: String, prefix: String) -> Int? {
        guard value.hasPrefix(prefix), let page = Int(value.dropFirst(prefix.count)), page >= 0,
              value == prefix + String(page) else { return nil }
        return page
    }
}
