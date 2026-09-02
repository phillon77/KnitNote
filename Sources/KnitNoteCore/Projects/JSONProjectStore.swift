import Combine
import CryptoKit
import Darwin
import Foundation

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

private func syncMutations(
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

private struct SyncPublicationProjectionCache {
    let archive: ProjectArchive
    let records: [SyncEntityID: SyncRecord]
}

private struct SyncPublicationSnapshot {
    var records: [SyncEntityID: SyncRecord] = [:]

    init(
        archive: ProjectArchive,
        deviceID: String,
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
        let previousReminders = Dictionary(uniqueKeysWithValues:
            (cache?.archive.projects ?? []).flatMap(\.knittingReminders).map { ($0.id, $0) })
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
                let counterID = SyncEntityID(kind: .projectCounter, uuid: counter.id)
                if !reuse(counterID, when: previousCounters[counter.id] == counter) {
                try add(
                    counter,
                    kind: .projectCounter,
                    id: counter.id,
                    createdAt: project.createdAt,
                    modifiedAt: Date(
                        timeIntervalSinceReferenceDate: TimeInterval(counter.mutationRevision)
                    ),
                    logicalRevision: counter.mutationRevision,
                    relationships: [.init(
                        role: "project",
                        target: .init(kind: .project, uuid: project.id)
                    )],
                    atomicDomain: .projectCounter(counter)
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
            for reminder in project.knittingReminders {
                if reuse(
                    .init(kind: .knittingReminder, uuid: reminder.id),
                    when: previousReminders[reminder.id] == reminder
                ) { continue }
                try add(
                    reminder,
                    kind: .knittingReminder,
                    id: reminder.id,
                    createdAt: reminder.createdAt,
                    modifiedAt: reminder.createdAt.addingTimeInterval(
                        TimeInterval(reminder.mutationRevision)
                    ),
                    logicalRevision: reminder.mutationRevision,
                    relationships: [
                        .init(
                            role: "project",
                            target: .init(kind: .project, uuid: project.id)
                        ),
                        .init(
                            role: "counter",
                            target: .init(kind: .projectCounter, uuid: reminder.counterID)
                        )
                    ],
                    atomicDomain: .knittingReminder(reminder)
                )
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

private func syncAttachmentMutation(
    owner: SyncEntityID,
    role: String,
    slotID: String,
    originalData: Data?,
    committedData: Data?,
    sourceURL: URL,
    mediaType: String,
    displayFilename: String,
    deviceID: String
) throws -> SyncMutation? {
    guard originalData != committedData else { return nil }
    let slot = SyncAttachmentSlot(owner: owner, role: role, slotID: slotID)
    let originalVersionID: UUID?
    if let originalData {
        originalVersionID = try SyncAttachmentVersion(
            slot: slot,
            contentSHA256: Data(SHA256.hash(data: originalData)),
            byteCount: Int64(originalData.count),
            mediaType: mediaType,
            displayFilename: displayFilename
        ).versionID
    } else {
        originalVersionID = nil
    }

    guard let committedData else {
        guard let originalVersionID else { return nil }
        return .delete(
            SyncEntityID(kind: .attachment, uuid: originalVersionID),
            mutationID: UUID()
        )
    }

    let contentSHA256 = Data(SHA256.hash(data: committedData))
    let attachment = try SyncAttachmentVersion(
        slot: slot,
        contentSHA256: contentSHA256,
        byteCount: Int64(committedData.count),
        mediaType: mediaType,
        displayFilename: displayFilename,
        replacesVersionID: originalVersionID
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

    func version(replacesVersionID: UUID? = nil) throws -> SyncAttachmentVersion {
        try SyncAttachmentVersion(
            slot: slot,
            contentSHA256: contentSHA256,
            byteCount: byteCount,
            mediaType: mediaType,
            displayFilename: displayFilename,
            replacesVersionID: replacesVersionID
        )
    }
}

private struct SyncRegularFileMetadata {
    let contentSHA256: Data
    let byteCount: Int64
}

private func syncRegularFileMetadata(at url: URL) throws -> SyncRegularFileMetadata {
    let descriptor = url.path.withCString {
        Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else {
        throw SyncPublicationTransactionFileError.unavailable
    }
    defer { Darwin.close(descriptor) }
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFREG,
          status.st_size >= 0 else {
        throw SyncPublicationTransactionFileError.unsafeFile
    }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else {
            throw SyncPublicationTransactionFileError.unavailable
        }
        guard count > 0 else { break }
        hasher.update(data: Data(buffer[0..<count]))
    }
    return SyncRegularFileMetadata(
        contentSHA256: Data(hasher.finalize()),
        byteCount: Int64(status.st_size)
    )
}

private func syncMediaType(for filename: String, fallback: String) -> String {
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
    private let isSyncPublicationEnabled: Bool
    private let syncInstallationID: String?
    private let syncRevisionLedger: SyncRevisionLedger?
    private var syncProjectionCache: SyncPublicationProjectionCache?
    private let patternStorageLocationsProvider: (() throws -> PatternStorageLocations)?
    private var activeJournalPhotoTransactions = 0
    private var activePatternTransactions = 0
    private let authorizeMutation: MutationAuthorizer
    private let commitSuccessfulMutation: MutationSuccessCommitter
    private var patternFolderNameContext: PatternFolderNameContext?
    private var didDeferLoadForSyncPublication = false

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
        syncMutationSink: any SyncMutationSink = DisabledSyncMutationSink(),
        authorizeMutation: @escaping MutationAuthorizer = { _ in .allow },
        commitSuccessfulMutation: @escaping MutationSuccessCommitter = { _ in .allow }
    ) {
        self.url = url
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
        self.authorizeMutation = authorizeMutation
        self.commitSuccessfulMutation = commitSuccessfulMutation
        self.patternFolderNameContext = patternFolderNameContext
        reconcileSyncPublicationTransactionAtStartup()
        if isSyncPublicationEnabled, syncRevisionLedger == nil, syncPublicationError == nil {
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
        let transactionFile = SyncPublicationTransactionFile(archiveURL: url)
        let transaction: SyncPublicationTransaction
        do {
            guard let loaded = try transactionFile.load() else {
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
        try deletion.stage()
        do {
            try persist(
                projects: projects.filter { $0.id != id },
                yarns: stagedYarns,
                patternUsages: remainingUsages,
                additionalSyncMutations: markupDeleteMutations
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
            ledger.record(command.id, rejection: .unsupportedSchema, at: now)
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
            ledger.record(command.id, rejection: .unsupportedSchema, at: now)
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
            ledger.record(command.id, rejection: .entitlementRequired, at: now)
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
        ledger.record(command.id, rejection: effectiveRejection, at: now)
        try ledgerFile.save(ledger)
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
        try ensureArchiveAvailable()
        let ledgerFile = AtomicWatchSyncFile<ProcessedWatchCommandLedger>(url: ledgerURL)
        var ledger = try loadLedgerRecoveringCorruption(from: ledgerFile)
        guard !ledger.requiresFreshHandshake else {
            throw WatchCommandPersistenceError.requiresFreshHandshake
        }
        guard let processed = ledger.entry(for: command.id) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else {
            ledger.markRequiresFreshHandshake()
            try ledgerFile.save(ledger)
            throw WatchCommandPersistenceError.requiresFreshHandshake
        }
        return try watchAcknowledgement(
            for: command.id,
            rejection: processed.rejection,
            entitlement: entitlement,
            now: now
        )
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
            ledger.record(command.id, rejection: rejection, at: now)
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
            ledger.record(command.id, rejection: rejection, at: now)
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
        try deletion.stage()
        do {
            try persist(
                projects: projects,
                yarns: yarns,
                patternAssets: assetIsUnreferenced
                    ? patternAssets.filter { $0.id != pattern.assetID }
                    : patternAssets,
                patterns: patterns.filter { $0.id != id },
                patternUsages: patternUsages.filter { $0.patternID != id },
                additionalSyncMutations: markupDeleteMutations
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
        let mutation = try syncAttachmentMutation(
            owner: .init(kind: .patternUsage, uuid: usageID),
            role: "usage-markup",
            slotID: "page:\(page)",
            originalData: originalPageData,
            committedData: encodedPage,
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
        let mutation = try syncAttachmentMutation(
            owner: .init(kind: .pattern, uuid: patternID),
            role: "legacy-markup",
            slotID: "project:\(projectID.uuidString)/page:\(page)",
            originalData: originalPageData,
            committedData: encodedPage,
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
        do {
            try commitArchiveAndPublish(
                data: archiveData,
                mutations: mutation.map { [$0] } ?? [],
                commitBoundary: .artifacts,
                artifactEvidence: [evidence],
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
            let originalProjectionCache: SyncPublicationProjectionCache?
            let committedProjectionCache: SyncPublicationProjectionCache?
            if isSyncPublicationEnabled {
                let originalRecords: [SyncEntityID: SyncRecord]
                if let cached = syncProjectionCache?.records {
                    originalRecords = cached
                } else {
                    originalRecords = try SyncPublicationSnapshot(
                        archive: originalArchive,
                        deviceID: syncPublicationDeviceID
                    ).records
                }
                originalProjectionCache = SyncPublicationProjectionCache(
                    archive: originalArchive,
                    records: originalRecords
                )
                let committedRecords = try SyncPublicationSnapshot(
                    archive: committedArchive,
                    deviceID: syncPublicationDeviceID,
                    reusing: originalProjectionCache
                ).records
                committedProjectionCache = SyncPublicationProjectionCache(
                    archive: committedArchive,
                    records: committedRecords
                )
            } else {
                originalProjectionCache = nil
                committedProjectionCache = nil
            }
            let archiveMutations = isSyncPublicationEnabled
                ? try syncMutations(
                    from: originalProjectionCache!.records,
                    to: committedProjectionCache!.records
                ) + syncArchiveAttachmentMutations(
                    from: originalArchive,
                    to: committedArchive
                )
                : []
            let mutations = archiveMutations + (isSyncPublicationEnabled
                ? additionalSyncMutations
                : [])
            let automaticArtifactEvidence = isSyncPublicationEnabled
                ? try syncArtifactEvidence(
                    for: archiveMutations,
                    committedArchive: committedArchive
                )
                : []
            try commitArchiveAndPublish(
                data: data,
                mutations: mutations,
                commitBoundary: syncCommitBoundary,
                artifactEvidence: automaticArtifactEvidence + additionalArtifactEvidence,
                commitArtifacts: commitArtifacts
            ) {
                projects = sortedProjects
                yarns = sortedYarns
                patternFolders = normalized.folders
                patternAssets = assets
                patterns = normalized.patterns
                patternUsages = usages
                syncProjectionCache = committedProjectionCache
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
        } catch {
            throw ProjectStoreError.persistenceFailed
        }
    }

    private func commitArchiveAndPublish(
        data: Data,
        mutations: [SyncMutation],
        commitBoundary: SyncPublicationCommitBoundary = .archive,
        artifactEvidence: [SyncPublicationArtifactEvidence] = [],
        shouldWriteArchive: Bool = true,
        commitArtifacts: (() throws -> Void)? = nil,
        applyCommittedState: () -> Void
    ) throws {
        guard isSyncPublicationEnabled, !mutations.isEmpty else {
            if shouldWriteArchive {
                try archiveWrite(data, url)
            }
            try commitArtifacts?()
            applyCommittedState()
            return
        }

        let causallyStamped: (mutations: [SyncMutation], receipts: [SyncRevisionReceipt])
        do {
            causallyStamped = try allocateCausalRevisions(for: mutations)
        } catch {
            let publicationError = syncPublicationError(for: error)
            syncPublicationError = publicationError
            throw publicationError
        }

        let transactionFile = SyncPublicationTransactionFile(archiveURL: url)
        let expectedFingerprint = SyncPublicationTransactionFile.fingerprint(of: data)
        let transaction: SyncPublicationTransaction
        do {
            transaction = try SyncPublicationTransaction(
                expectedArchiveSHA256: expectedFingerprint,
                mutations: causallyStamped.mutations,
                commitBoundary: commitBoundary,
                artifactEvidence: artifactEvidence,
                revisionReceipts: causallyStamped.receipts
            )
            try transactionFile.write(transaction)
        } catch {
            let publicationError = syncPublicationError(for: error)
            syncPublicationError = publicationError
            throw publicationError
        }

        var archiveWriteFailure: (any Error)?
        do {
            if shouldWriteArchive {
                try archiveWrite(data, url)
            }
            try commitArtifacts?()
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

    private func allocateCausalRevisions(
        for mutations: [SyncMutation]
    ) throws -> (mutations: [SyncMutation], receipts: [SyncRevisionReceipt]) {
        guard let syncRevisionLedger else {
            throw SyncRevisionLedgerError.unavailable
        }
        var stamped: [SyncMutation] = []
        var receipts: [SyncRevisionReceipt] = []
        stamped.reserveCapacity(mutations.count)
        receipts.reserveCapacity(mutations.count)
        for mutation in mutations {
            let receipt = try syncRevisionLedger.allocate(
                for: mutation.recordID,
                mutationID: mutation.mutationID,
                observedRemoteRevision: 0
            )
            stamped.append(try applying(receipt: receipt, to: mutation))
            receipts.append(receipt)
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
            let oldVersionID = try old?.version().versionID
            guard let new else {
                if let oldVersionID {
                    mutations.append(.delete(
                        .init(kind: .attachment, uuid: oldVersionID),
                        mutationID: UUID()
                    ))
                }
                continue
            }
            let contentVersionID = try new.version().versionID
            let attachment = try new.version(
                replacesVersionID: contentVersionID == oldVersionID ? nil : oldVersionID
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
            for (index, filename) in yarn.labelPhotoFilenames.enumerated() {
                guard let sourceURL = yarnLabelPhotoService.url(filename: filename) else {
                    throw SyncPublicationTransactionFileError.corrupt
                }
                try add(
                    owner: owner,
                    role: "yarn-label-photo",
                    slotID: "label:\(index)",
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

    private func syncArtifactEvidence(
        for mutations: [SyncMutation],
        committedArchive: ProjectArchive
    ) throws -> [SyncPublicationArtifactEvidence] {
        let attachmentSaveIDs = Set(mutations.compactMap { mutation -> SyncEntityID? in
            guard mutation.intent == .save, mutation.recordID.kind == .attachment else {
                return nil
            }
            return mutation.recordID
        })
        guard !attachmentSaveIDs.isEmpty else { return [] }

        let attachmentURLs = try syncAttachmentURLs(in: committedArchive)
        let transactionFile = SyncPublicationTransactionFile(archiveURL: url)
        return try attachmentSaveIDs.sorted(by: syncEntityIDIsOrderedBefore).map { id in
            guard let artifactURL = attachmentURLs[id] else {
                throw SyncPublicationTransactionFileError.corrupt
            }
            let relativePath = try syncArtifactRelativePath(for: artifactURL)
            return try transactionFile.evidenceForExistingArtifact(
                relativePath: relativePath,
                archiveURL: url
            )
        }
    }

    private func syncUsageMarkupDeleteMutations(
        usageIDs: [UUID]
    ) throws -> [SyncMutation] {
        guard isSyncPublicationEnabled else { return [] }
        return try usageIDs.sorted { $0.uuidString < $1.uuidString }.flatMap { usageID in
            try patternMarkupFileService.usageMarkupPageIndices(usageID: usageID).map { page in
                let pageURL = try patternMarkupFileService.usagePageURL(
                    usageID: usageID,
                    pageIndex: page
                )
                let metadata = try syncRegularFileMetadata(at: pageURL)
                let version = try SyncAttachmentVersion(
                    slot: .init(
                        owner: .init(kind: .patternUsage, uuid: usageID),
                        role: "usage-markup",
                        slotID: "page:\(page)"
                    ),
                    contentSHA256: metadata.contentSHA256,
                    byteCount: metadata.byteCount,
                    mediaType: "application/json",
                    displayFilename: "\(page).json"
                )
                return SyncMutation.delete(
                    SyncEntityID(kind: .attachment, uuid: version.versionID),
                    mutationID: UUID()
                )
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
            ).map { page in
                let pageURL = try patternMarkupFileService.legacyPageURL(
                    projectID: projectID,
                    patternID: patternID,
                    pageIndex: page
                )
                let metadata = try syncRegularFileMetadata(at: pageURL)
                let version = try SyncAttachmentVersion(
                    slot: .init(
                        owner: .init(kind: .pattern, uuid: patternID),
                        role: "legacy-markup",
                        slotID: "project:\(projectID.uuidString)/page:\(page)"
                    ),
                    contentSHA256: metadata.contentSHA256,
                    byteCount: metadata.byteCount,
                    mediaType: "application/json",
                    displayFilename: "\(page).json"
                )
                return SyncMutation.delete(
                    SyncEntityID(kind: .attachment, uuid: version.versionID),
                    mutationID: UUID()
                )
            }
        }
    }

    private func syncAttachmentURLs(
        in archive: ProjectArchive
    ) throws -> [SyncEntityID: URL] {
        var metadataCache: [URL: SyncRegularFileMetadata] = [:]
        let attachments = try syncArchiveAttachments(
            in: archive,
            metadataCache: &metadataCache
        )
        return try Dictionary(uniqueKeysWithValues: attachments.values.map { attachment in
            (
                SyncEntityID(
                    kind: .attachment,
                    uuid: try attachment.version().versionID
                ),
                attachment.sourceURL
            )
        })
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
        transactionFile: SyncPublicationTransactionFile
    ) throws {
        guard isSyncPublicationEnabled else {
            throw SyncPublicationError.sinkUnavailable
        }
        do {
            try syncMutationSink.publish(transaction.mutations)
        } catch {
            // Retain the whole transaction. Mutation identity is idempotent, so
            // retrying an accepted prefix is safe and avoids O(n²) suffix
            // rewrites on the main actor.
            throw SyncPublicationError.pendingRepair
        }
        do {
            try transactionFile.remove()
        } catch {
            throw SyncPublicationError.pendingRepair
        }
    }

    private func reconcileSyncPublicationTransactionAtStartup() {
        let transactionFile = SyncPublicationTransactionFile(archiveURL: url)
        do {
            guard let transaction = try transactionFile.load() else {
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
        if isSyncPublicationEnabled, syncRevisionLedger == nil {
            throw SyncPublicationError.transactionUnavailable
        }
        if let syncPublicationError {
            throw syncPublicationError
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
        if error is SyncRevisionLedgerError || error is SyncInstallationIdentityError {
            return .transactionUnavailable
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
        try ensureSyncPublicationReady()
        let decision = authorizeMutation(mutation)
        guard decision != .requiresUnlock else {
            throw ProjectStoreError.accessRestricted
        }
        return decision
    }

    private func commitAccessIfNeeded(
        _ decision: FeatureAccessDecision,
        mutation: FeatureMutation
    ) throws {
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
        guard commitSuccessfulMutation(mutation) != .requiresUnlock else {
            throw ProjectStoreError.accessRestricted
        }
    }

    private func beginDataOperation() throws {
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
