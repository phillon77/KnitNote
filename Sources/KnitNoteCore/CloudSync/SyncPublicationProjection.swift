import CryptoKit
import Darwin
import Foundation

public struct SyncAttachmentReference: Equatable, Sendable {
    public let slot: SyncAttachmentSlot
    public let sourceURL: URL
    public let mediaType: String
    public let displayFilename: String

    public init(
        slot: SyncAttachmentSlot,
        sourceURL: URL,
        mediaType: String,
        displayFilename: String
    ) {
        self.slot = slot
        self.sourceURL = sourceURL.standardizedFileURL
        self.mediaType = mediaType
        self.displayFilename = URL(fileURLWithPath: displayFilename).lastPathComponent
    }
}

public struct SyncPublicationProjectionCache: Sendable {
    public let archive: ProjectArchive
    public let records: [SyncEntityID: SyncRecord]

    public init(archive: ProjectArchive, records: [SyncEntityID: SyncRecord]) {
        self.archive = archive
        self.records = records
    }
}

public struct SyncPublicationAttachmentProjection: Sendable {
    public let reference: SyncAttachmentReference
    public let manifestEntry: SyncAttachmentManifestEntry
    public let version: SyncAttachmentVersion
}

public struct SyncPublicationProjection: Sendable {
    public let mutations: [SyncMutation]
    public let attachmentManifest: [String: SyncAttachmentManifestEntry]
    public let observedRevisions: [SyncEntityID: UInt64]
    public let cache: SyncPublicationProjectionCache
    public let attachments: [SyncAttachmentSlot: SyncPublicationAttachmentProjection]
}

public struct SyncPublicationProjector {
    public typealias AttachmentReferences = (ProjectArchive) throws -> [SyncAttachmentReference]

    private let deviceID: String
    private let preparedWatchCommand: PreparedWatchCommand?
    private let processedWatchLedger: ProcessedWatchCommandLedger
    private let processedWatchProofs: [SyncProcessedWatchCommandProof]
    private let reusing: SyncPublicationProjectionCache?
    private let attachmentReferences: AttachmentReferences
    private let issuedAttachmentVersions: [SyncAttachmentSlot: SyncAttachmentVersion]
    private let issuedAttachmentRecords: [SyncAttachmentSlot: SyncRecord]
    private let deletedAttachmentVersionIDs: Set<UUID>
    private let fileReader: any SyncRegularFileReading
    private let now: () -> Date
    private let makeUUID: () -> UUID
    private let makeAttachmentVersionID: ((SyncAttachmentReference, SyncRegularFileRead, UUID?) -> UUID)?
    private let issueUnissuedAttachments: Bool

    public init(
        deviceID: String,
        preparedWatchCommand: PreparedWatchCommand? = nil,
        processedWatchLedger: ProcessedWatchCommandLedger = .init(),
        processedWatchProofs: [SyncProcessedWatchCommandProof] = [],
        reusing: SyncPublicationProjectionCache? = nil,
        attachmentReferences: @escaping AttachmentReferences,
        issuedAttachmentVersions: [SyncAttachmentSlot: SyncAttachmentVersion],
        issuedAttachmentRecords: [SyncAttachmentSlot: SyncRecord] = [:],
        deletedAttachmentVersionIDs: Set<UUID> = [],
        fileReader: any SyncRegularFileReading = SyncRegularFileReader(),
        now: @escaping () -> Date = Date.init,
        makeUUID: @escaping () -> UUID = UUID.init,
        makeAttachmentVersionID: ((SyncAttachmentReference, SyncRegularFileRead, UUID?) -> UUID)? = nil,
        issueUnissuedAttachments: Bool = false
    ) {
        self.deviceID = deviceID
        self.preparedWatchCommand = preparedWatchCommand
        self.processedWatchLedger = processedWatchLedger
        self.processedWatchProofs = processedWatchProofs
        self.reusing = reusing
        self.attachmentReferences = attachmentReferences
        self.issuedAttachmentVersions = issuedAttachmentVersions
        self.issuedAttachmentRecords = issuedAttachmentRecords
        self.deletedAttachmentVersionIDs = deletedAttachmentVersionIDs
        self.fileReader = fileReader
        self.now = now
        self.makeUUID = makeUUID
        self.makeAttachmentVersionID = makeAttachmentVersionID
        self.issueUnissuedAttachments = issueUnissuedAttachments
    }

    public func project(
        before: ProjectArchive,
        after: ProjectArchive,
        manifest: [String: SyncAttachmentManifestEntry]
    ) throws -> SyncPublicationProjection {
        let originalRecords: [SyncEntityID: SyncRecord]
        if let reusing {
            originalRecords = reusing.records
        } else {
            originalRecords = try SyncCanonicalPublicationSnapshot(
                archive: before,
                deviceID: deviceID,
                preparedWatchCommand: preparedWatchCommand,
                processedWatchLedger: processedWatchLedger,
                processedWatchProofs: processedWatchProofs
            ).records
        }
        let originalCache = SyncPublicationProjectionCache(
            archive: before,
            records: originalRecords
        )
        let committedRecords = try SyncCanonicalPublicationSnapshot(
            archive: after,
            deviceID: deviceID,
            preparedWatchCommand: preparedWatchCommand,
            processedWatchLedger: processedWatchLedger,
            processedWatchProofs: processedWatchProofs,
            reusing: originalCache
        ).records
        let attachmentProjection = try projectAttachments(
            before: before,
            after: after,
            manifest: manifest
        )
        return SyncPublicationProjection(
            mutations: try syncMutations(from: originalRecords, to: committedRecords)
                + attachmentProjection.mutations,
            attachmentManifest: attachmentProjection.manifest,
            observedRevisions: originalRecords.mapValues(\.entityRevision),
            cache: .init(archive: after, records: committedRecords),
            attachments: attachmentProjection.attachments
        )
    }

    private func projectAttachments(
        before: ProjectArchive,
        after: ProjectArchive,
        manifest: [String: SyncAttachmentManifestEntry]
    ) throws -> (
        mutations: [SyncMutation],
        manifest: [String: SyncAttachmentManifestEntry],
        attachments: [SyncAttachmentSlot: SyncPublicationAttachmentProjection]
    ) {
        let validatedManifest = try SyncAttachmentManifestStore.dictionary(
            from: SyncAttachmentManifestStore.orderedEntries(manifest)
        )
        let beforeReferences = try validatedReferences(attachmentReferences(before))
        let afterReferences = try validatedReferences(attachmentReferences(after))
        let beforeBySlot = Dictionary(uniqueKeysWithValues: beforeReferences.map {
            ($0.slot, $0)
        })
        let beforeSlots = Set(beforeReferences.map(\.slot))
        let afterSlots = Set(afterReferences.map(\.slot))
        let oldBySlot = Dictionary(uniqueKeysWithValues: validatedManifest.values.map {
            ($0.slot, $0)
        })
        let relevantSlots = beforeSlots.union(afterSlots).union(oldBySlot.keys)
        let issuedBySlot = try issuedAttachmentVersions.reduce(
            into: [SyncAttachmentSlot: SyncAttachmentVersion]()
        ) { result, pair in
            guard relevantSlots.contains(pair.key) else { return }
            let version = try pair.value.validated()
            guard version.slot == pair.key else {
                throw SyncAttachmentManifestError.corrupt
            }
            result[pair.key] = version
        }
        let issuedRecordBySlot = try issuedAttachmentRecords.reduce(
            into: [SyncAttachmentSlot: SyncRecord]()
        ) { result, pair in
            guard relevantSlots.contains(pair.key) else { return }
            let record = try SyncRecordValidator().validate(pair.value)
            guard record.payload.attachment == issuedBySlot[pair.key],
                  record.payload.attachment?.slot == pair.key else {
                throw SyncAttachmentManifestError.corrupt
            }
            result[pair.key] = record
        }

        var changes: [SyncAttachmentManifestChange] = []
        var mutations: [SyncMutation] = []
        var projectedAttachments: [
            SyncAttachmentSlot: SyncPublicationAttachmentProjection
        ] = [:]
        var readsByPath: [String: SyncRegularFileRead] = [:]

        for reference in afterReferences.sorted(by: {
            syncAttachmentSlotIsOrderedBefore($0.slot, $1.slot)
        }) {
            let normalizedPath = reference.sourceURL.standardizedFileURL.path
            let oldEntry = oldBySlot[reference.slot]
            let issued = issuedBySlot[reference.slot]

            // Attachments that predate the publication boundary have no
            // immutable issuance evidence.  They remain local legacy content
            // until a later mutation introduces or replaces that slot; do not
            // manufacture a new remote version merely because the manifest is
            // being introduced. A changed reference in the same semantic slot
            // is a real replacement, however, and must receive a fresh
            // version without guessing a legacy predecessor.
            if !issueUnissuedAttachments,
               oldEntry == nil,
               issued == nil,
               let beforeReference = beforeBySlot[reference.slot],
               beforeReference == reference {
                continue
            }
            let pathStatus = try regularFileStatus(at: reference.sourceURL)

            if let oldEntry, let issued,
               !deletedAttachmentVersionIDs.contains(issued.versionID),
               oldEntry.versionID == issued.versionID,
               oldEntry.contentSHA256 == issued.contentSHA256,
               oldEntry.byteCount == issued.byteCount,
               oldEntry.normalizedPath == normalizedPath,
               oldEntry.device == pathStatus.device,
               oldEntry.inode == pathStatus.inode,
               oldEntry.byteCount == pathStatus.byteCount,
               oldEntry.modificationNanoseconds == pathStatus.modificationNanoseconds {
                projectedAttachments[reference.slot] = .init(
                    reference: reference,
                    manifestEntry: oldEntry,
                    version: issued
                )
                continue
            }

            let read: SyncRegularFileRead
            if let cached = readsByPath[normalizedPath] {
                read = cached
            } else {
                do {
                    read = try fileReader.read(
                        reference.sourceURL,
                        maximumBytes: SyncPublicationFileLimits.maximumAttachmentBytes,
                        expected: nil
                    )
                } catch let error as SyncRegularFileReadError {
                    throw mapRegularFileError(error)
                }
                readsByPath[normalizedPath] = read
            }

            if let oldEntry {
                guard let issued,
                      oldEntry.versionID == issued.versionID,
                      oldEntry.contentSHA256 == issued.contentSHA256,
                      oldEntry.byteCount == issued.byteCount else {
                    throw SyncAttachmentManifestError.corrupt
                }
            }

            let keepsIssuedVersion: Bool
            if let issued, !deletedAttachmentVersionIDs.contains(issued.versionID) {
                let bytesMatch = issued.byteCount == read.byteCount
                    && issued.contentSHA256 == read.sha256
                if let oldEntry {
                    keepsIssuedVersion = bytesMatch
                        && oldEntry.normalizedPath == normalizedPath
                        && oldEntry.device == read.device
                        && oldEntry.inode == read.inode
                } else {
                    // Upgrade/bootstrap: Task 2's durable issued snapshot is
                    // authoritative when the new manifest has not yet existed.
                    keepsIssuedVersion = bytesMatch
                }
            } else {
                keepsIssuedVersion = false
            }

            let version: SyncAttachmentVersion
            if keepsIssuedVersion, let issued {
                version = issued
            } else {
                version = try SyncAttachmentVersion.issuing(
                    slot: reference.slot,
                    contentSHA256: read.sha256,
                    byteCount: read.byteCount,
                    mediaType: reference.mediaType,
                    displayFilename: reference.displayFilename,
                    replacesVersionID: issued?.versionID,
                    versionID: makeAttachmentVersionID?(reference, read, issued?.versionID) ?? makeUUID()
                )
                mutations.append(try saveMutation(
                    version: version,
                    reference: reference,
                    mutationID: makeUUID()
                ))
            }

            let entry = SyncAttachmentManifestEntry(
                normalizedPath: normalizedPath,
                device: read.device,
                inode: read.inode,
                byteCount: read.byteCount,
                modificationNanoseconds: read.modificationNanoseconds,
                contentSHA256: read.sha256,
                slot: reference.slot,
                versionID: version.versionID
            )
            if let oldEntry {
                let oldKey = try SyncAttachmentManifestStore.key(for: oldEntry)
                let newKey = try SyncAttachmentManifestStore.key(for: entry)
                if oldKey != newKey {
                    changes.append(.remove(oldKey))
                }
            }
            changes.append(.upsert(entry))
            projectedAttachments[reference.slot] = .init(
                reference: reference,
                manifestEntry: entry,
                version: version
            )
        }

        let deletedSlots = relevantSlots.subtracting(afterSlots).sorted(
            by: syncAttachmentSlotIsOrderedBefore
        )
        for slot in deletedSlots {
            let oldEntry = oldBySlot[slot]
            let issued = issuedBySlot[slot]
            if let oldEntry {
                guard let issued, issued.versionID == oldEntry.versionID else {
                    throw SyncAttachmentManifestError.corrupt
                }
                changes.append(.remove(try SyncAttachmentManifestStore.key(for: oldEntry)))
            }
            // A before-archive reference without Task 2 issuance evidence is
            // legacy local content. Never invent an attachment delete for it.
            guard issued != nil else { continue }
            guard let issuedRecord = issuedRecordBySlot[slot] else {
                throw SyncAttachmentManifestError.corrupt
            }
            mutations.append(try tombstoneMutation(
                issuedRecord: issuedRecord,
                mutationID: makeUUID(),
                deletedAt: now()
            ))
        }

        let projectedManifest = try SyncAttachmentManifestStore.projection(
            for: validatedManifest,
            changes: changes
        )
        return (mutations, projectedManifest, projectedAttachments)
    }

    private func saveMutation(
        version: SyncAttachmentVersion,
        reference: SyncAttachmentReference,
        mutationID: UUID
    ) throws -> SyncMutation {
        let modifiedAt = now()
        let stamp = SyncMutationStamp(
            logicalRevision: 0,
            modifiedAt: modifiedAt,
            deviceID: deviceID
        )
        let record = SyncRecord(
            schemaVersion: 1,
            id: .init(kind: .attachment, uuid: version.versionID),
            createdAt: modifiedAt,
            entityRevision: 0,
            payload: .init(fields: [
                "role": .init(value: .string(version.slot.role), stamp: stamp),
                "slotID": .init(value: .string(version.slot.slotID), stamp: stamp)
            ], attachment: version),
            relationships: [.init(role: "owner", target: version.slot.owner)],
            deletedAt: .init(value: nil, stamp: stamp)
        )
        return try .save(
            recordVersion: SyncRecordVersion(record: record),
            attachmentSource: try SyncAttachmentSource(
                fileURL: reference.sourceURL,
                contentSHA256: version.contentSHA256,
                byteCount: version.byteCount
            ),
            mutationID: mutationID
        )
    }

    private func tombstoneMutation(
        issuedRecord: SyncRecord,
        mutationID: UUID,
        deletedAt: Date
    ) throws -> SyncMutation {
        var tombstone = issuedRecord
        tombstone.deletedAt = .init(
            value: deletedAt,
            stamp: .init(
                logicalRevision: issuedRecord.deletedAt.stamp.logicalRevision,
                modifiedAt: deletedAt,
                deviceID: deviceID
            )
        )
        return try .save(
            recordVersion: SyncRecordVersion(record: tombstone),
            mutationID: mutationID
        )
    }

    private func validatedReferences(
        _ references: [SyncAttachmentReference]
    ) throws -> [SyncAttachmentReference] {
        var slots: Set<SyncAttachmentSlot> = []
        for reference in references {
            do {
                _ = try reference.slot.validated()
            } catch {
                throw SyncAttachmentManifestError.corrupt
            }
            guard slots.insert(reference.slot).inserted,
                  !reference.mediaType.isEmpty,
                  reference.mediaType.utf8.count <= 256,
                  !reference.displayFilename.isEmpty,
                  reference.displayFilename.utf8.count <= 1_024 else {
                throw SyncAttachmentManifestError.corrupt
            }
        }
        return references
    }

    private func regularFileStatus(at url: URL) throws -> SyncAttachmentFileStatus {
        var status = stat()
        guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0 else {
            throw SyncPublicationTransactionFileError.unavailable
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0,
              status.st_size <= SyncPublicationFileLimits.maximumAttachmentBytes,
              let modificationNanoseconds = modificationNanoseconds(of: status) else {
            throw SyncPublicationTransactionFileError.unsafeFile
        }
        return SyncAttachmentFileStatus(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            byteCount: Int64(status.st_size),
            modificationNanoseconds: modificationNanoseconds
        )
    }

    private func modificationNanoseconds(of status: stat) -> Int64? {
        let seconds = Int64(status.st_mtimespec.tv_sec)
        let nanoseconds = Int64(status.st_mtimespec.tv_nsec)
        let (scaled, scaleOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let (result, addOverflow) = scaled.addingReportingOverflow(nanoseconds)
        return scaleOverflow || addOverflow ? nil : result
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
}

private struct SyncAttachmentFileStatus {
    let device: UInt64
    let inode: UInt64
    let byteCount: Int64
    let modificationNanoseconds: Int64
}

func syncMutations(
    from originalRecords: [SyncEntityID: SyncRecord],
    to committedRecords: [SyncEntityID: SyncRecord]
) throws -> [SyncMutation] {
    let deletedIDs = Set(originalRecords.keys).subtracting(committedRecords.keys)
    let savedIDs = committedRecords.keys.filter {
        originalRecords[$0] != committedRecords[$0]
    }
    let orderedDeletedIDs = deletedIDs.sorted(by: syncEntityIDIsOrderedBefore)
    let orderedSavedIDs = savedIDs.sorted(by: syncEntityIDIsOrderedBefore)
    return orderedDeletedIDs.map { .delete($0, mutationID: UUID()) }
        + (try orderedSavedIDs.map {
            try .save(
                recordVersion: SyncRecordVersion(record: committedRecords[$0]!),
                mutationID: UUID()
            )
        })
}

func syncRecords(
    _ records: [SyncEntityID: SyncRecord],
    applying mutations: [SyncMutation]
) -> [SyncEntityID: SyncRecord] {
    var result = records
    for mutation in mutations {
        switch mutation {
        case let .save(save):
            result[save.recordVersion.record.id] = save.recordVersion.record
        case let .delete(delete):
            result.removeValue(forKey: delete.recordID)
        }
    }
    return result
}

func orphanWatchProofRecords(
    proofs: [SyncProcessedWatchCommandProof],
    archive: ProjectArchive,
    deviceID: String
) throws -> [SyncEntityID: SyncRecord] {
    _ = archive
    _ = deviceID
    var records: [SyncEntityID: SyncRecord] = [:]
    for proof in proofs {
        let orphan = try SyncOrphanWatchCommandProof(proof: proof)
        // Once published, an orphan proof remains the immutable missing-target
        // authority even if a project or counter later reappears.
        guard let identity = orphan.proof.commandIdentity else {
            throw SyncRecordVersionError.corrupt
        }
        guard let stamp = orphan.proof.processingStamp else {
            throw SyncRecordVersionError.corrupt
        }
        let recordID = SyncEntityID(kind: .watchCommandProof, uuid: orphan.proof.id)
        let record = SyncRecord(
            schemaVersion: 1,
            id: recordID,
            createdAt: identity.createdAt,
            entityRevision: 0,
            payload: .init(
                fields: [:],
                atomicDomain: .init(value: .orphanWatchCommandProof(orphan), stamp: stamp)
            ),
            relationships: [],
            deletedAt: .init(value: nil, stamp: stamp)
        )
        if let existing = records[recordID], existing != record {
            throw SyncRecordVersionError.corrupt
        }
        records[recordID] = record
    }
    return records
}

func syncAttachmentSlotIsOrderedBefore(
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

struct SyncCanonicalPublicationSnapshot {
    var records: [SyncEntityID: SyncRecord] = [:]

    init(
        archive: ProjectArchive,
        deviceID: String,
        preparedWatchCommand: PreparedWatchCommand? = nil,
        processedWatchLedger: ProcessedWatchCommandLedger = .init(),
        processedWatchProofs: [SyncProcessedWatchCommandProof] = [],
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
        let ledgerProofs = try processedWatchLedger.entries.compactMap {
            try SyncProcessedWatchCommandProof(
                entry: $0,
                processingDeviceID: deviceID
            )
        }

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
                let cachedState: SyncCounterReminderState?
                if case let .projectCounter(state)? =
                    cache?.records[counterID]?.payload.atomicDomain?.value {
                    cachedState = state
                } else {
                    cachedState = nil
                }
                var proofsByID: [UUID: SyncProcessedWatchCommandProof] = [:]
                for proof in processedWatchProofs
                    + (cachedState?.processedCommandProofs ?? [])
                    + ledgerProofs
                where proof.counterID == counter.id {
                    if let existing = proofsByID[proof.id], existing != proof {
                        throw SyncRecordVersionError.corrupt
                    }
                    proofsByID[proof.id] = proof
                }
                let processedProofs = proofsByID.values.sorted {
                    $0.id.uuidString < $1.id.uuidString
                }
                let processedIDs = Set(processedProofs.map(\.id))
                if !reuse(
                    counterID,
                    when: previousCounters[counter.id] == counter
                        && previousRemindersByCounter[counter.id] == reminders
                        && cachedState?.preparedCommand == prepared
                        && cachedState?.processedCommandIDs == processedIDs
                        && cachedState?.processedCommandProofs == processedProofs
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
                            processedCommandProofs: processedProofs,
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

        let cachedRecords = cache.map { Array($0.records.values) } ?? []
        let retainedOrphanProofs: [SyncProcessedWatchCommandProof] = cachedRecords.compactMap {
            record -> SyncProcessedWatchCommandProof? in
            guard case let .orphanWatchCommandProof(orphan)? =
                record.payload.atomicDomain?.value else { return nil }
            return orphan.proof
        }
        let missingTargetProofs = (processedWatchProofs
            + ledgerProofs
            + retainedOrphanProofs
        ).filter {
            $0.rejection == .projectMissing || $0.rejection == .counterMissing
        }
        for (recordID, record) in try orphanWatchProofRecords(
            proofs: missingTargetProofs,
            archive: archive,
            deviceID: deviceID
        ) {
            if let existing = records[recordID], existing != record {
                throw SyncRecordVersionError.corrupt
            }
            if let cached = cache?.records[recordID],
               cached.deletedAt.value == nil,
               case let .orphanWatchCommandProof(cachedOrphan)? =
                    cached.payload.atomicDomain?.value,
               case let .orphanWatchCommandProof(projectedOrphan)? =
                    record.payload.atomicDomain?.value,
               cachedOrphan.proof == projectedOrphan.proof {
                _ = try SyncRecordVersion(record: cached)
                records[recordID] = cached
            } else {
                records[recordID] = record
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
                    && cache?.records[.init(kind: .pattern, uuid: pattern.id)]?.payload.fields["assetSnapshot"] != nil
                    && cache?.archive.patternAssets.first(where: { $0.id == pattern.assetID })
                        == archive.patternAssets.first(where: { $0.id == pattern.assetID })
            ) { continue }
            try add(
                pattern,
                kind: .pattern,
                id: pattern.id,
                createdAt: pattern.createdAt,
                modifiedAt: pattern.lastOpenedAt ?? pattern.createdAt,
                searchableName: pattern.displayName
            )
            if let asset = archive.patternAssets.first(where: { $0.id == pattern.assetID }) {
                let id = SyncEntityID(kind: .pattern, uuid: pattern.id)
                let stamp = records[id]!.deletedAt.stamp
                records[id]!.payload.fields["assetSnapshot"] = .init(
                    value: .data(try encoder.encode(asset)), stamp: stamp
                )
            }
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

struct SyncProjectProjection: Codable, Equatable {
    let id: UUID
    let name: String
    let createdAt: Date
    let updatedAt: Date?
    let counterOrder: [UUID]?
    let reminderOrder: [UUID]?
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
        updatedAt = project.updatedAt
        counterOrder = project.counters.map(\.id)
        reminderOrder = project.knittingReminders.map(\.id)
        selectedCounterID = project.selectedCounterID
        photoFilename = project.photoFilename
        completedAt = project.completedAt
        toolType = project.toolType
        toolSize = project.toolSize
        toolNotes = project.toolNotes
        legacyPatterns = project.patterns
    }
}

struct SyncYarnProjection: Codable, Equatable {
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

struct SyncProjectYarnLinkProjection: Codable {
    let projectID: UUID
    let yarnID: UUID
}

private func syncEntityIDIsOrderedBefore(_ lhs: SyncEntityID, _ rhs: SyncEntityID) -> Bool {
    (lhs.kind.rawValue, lhs.uuid.uuidString) < (rhs.kind.rawValue, rhs.uuid.uuidString)
}

func deterministicSyncUUID(
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
