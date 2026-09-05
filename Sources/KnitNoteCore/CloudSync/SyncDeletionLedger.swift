import CryptoKit
import Darwin
import Foundation

enum SyncDeletionLedgerError: Error {
    case unavailable
    case corrupt
    case unsafePath
    case missingAttachment(UUID)
    case witnessMismatch
    case pendingRepair
}

struct SyncDeletionLedger {
    // POSIX record locks serialize processes, not handles in one process.
    // Keep the in-process gate through lock-file close as well.
    private static let processLock = NSRecursiveLock()
    private struct Binding: Codable {
        let beforeArchiveSHA256: Data
        let afterArchiveSHA256: Data
        let publicationSHA256: Data
        let commitBoundary: SyncPublicationCommitBoundary?
    }
    private struct Group: Codable {
        var entry: SyncDeletionEntry
        var binding: Binding?
        var active: Bool
        var canceled: Bool? = nil
        var restoration: Restoration? = nil
        var incoming: Bool? = nil
    }
    private struct Restoration: Codable {
        let publication: SyncPublicationTransaction
        var phase: String
    }
    private struct Manifest: Codable {
        let version: Int
        var groups: [Group]
        var markers: [DeletionMarker]? = nil
        var pendingMarkerVersions: [SyncRecordVersion]? = nil
        var purgeIntents: [PurgeIntent]? = nil
    }
    private struct PurgeIntent: Codable {
        let entryID: UUID
        let markers: [DeletionMarker]
        let pendingMarkerVersions: [SyncRecordVersion]
        let files: [SyncDeletionFileProof]
    }
    private struct Envelope: Codable {
        let payload: Data
        let sha256: Data
    }

    let root: URL
    static func root(archiveURL: URL) -> URL {
        archiveURL.deletingLastPathComponent().appendingPathComponent(".sync-deletions", isDirectory: true)
    }
    private var manifestURL: URL { root.appendingPathComponent("ledger.json") }
    private let maximumBytes = 100_000_000

    struct RecoveryExport {
        let manifest: Data
        let files: [SyncDeletionFileProof]
        let pendingMarkerVersions: [SyncRecordVersion]
        let knownRetainedPaths: Set<String>
        let terminalSources: [String: SyncAttachmentSource]
    }

    /// No directory creation, lock-file creation, recovery, purge or source write.
    /// Called only inside the account owner's frozen read-only capture boundary.
    private init(readOnlyRoot: URL) { root = readOnlyRoot }

    static func recoveryExport(archiveURL: URL, pending: [SyncMutation],
                               maximumBytes: Int) throws -> RecoveryExport {
        let ledger = Self(readOnlyRoot: root(archiveURL: archiveURL))
        // A current publication file is replay authority, including when its
        // ledger witness says completed/canceled. It must be settled by its owner.
        var status = stat()
        let publication = SyncPublicationTransactionFile(archiveURL: archiveURL).url
        guard lstat(publication.path, &status) != 0, errno == ENOENT else { throw SyncDeletionLedgerError.pendingRepair }
        var manifest = try ledger.load(validateRetainedFiles: false)
        guard (manifest.purgeIntents ?? []).isEmpty else { throw SyncDeletionLedgerError.pendingRepair }
        let known = Set(manifest.groups.flatMap { $0.entry.files.map(\.retainedRelativePath) })
        let versions = pending.compactMap(\.savedRecordVersion)
        var selected: [Group] = []
        var terminalSources: [String: SyncAttachmentSource] = [:]
        for var group in manifest.groups {
            if let restoration = group.restoration {
                if restoration.phase == "completed" || restoration.phase == "canceled" {
                    for mutation in restoration.publication.mutations {
                        guard let source = mutation.attachmentSource else { continue }
                        func posixPath(_ url: URL) -> String {
                            let path = url.path
                            return path.hasPrefix("/var/") || path.hasPrefix("/tmp/") ? "/private" + path : path
                        }
                        let prefix = posixPath(ledger.root) + "/"
                        let path = posixPath(source.fileURL)
                        // Other stores own sources outside this ledger. Inside,
                        // only this exact validated restoration's staging path
                        // and descriptor may classify a historical source.
                        guard path.hasPrefix(prefix) else { continue }
                        let relative = String(path.dropFirst(prefix.count))
                        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                        guard parts.count == 3, parts[0] == group.entry.id.uuidString,
                              parts[1].hasPrefix("restore-"), UUID(uuidString: String(parts[1].dropFirst(8))) != nil,
                              parts[2] == mutation.recordID.uuid.uuidString,
                              terminalSources[relative] == nil || terminalSources[relative] == source else {
                            throw SyncDeletionLedgerError.witnessMismatch
                        }
                        terminalSources[relative] = source
                    }
                }
                switch restoration.phase {
                case "completed": continue
                case "canceled": group.restoration = nil
                default: throw SyncDeletionLedgerError.pendingRepair
                }
            }
            if group.active {
                if group.entry.exactRemovalVersions.contains(where: { versions.contains($0) }) { selected.append(group) }
                continue
            }
            // These are the existing recover(nil publication) terminal rules.
            // An unbound abandoned stage and a canceled operation have no live
            // replay authority. Bound artifact operations cannot be guessed.
            guard let binding = group.binding else { continue }
            if group.canceled == true { continue }
            guard binding.commitBoundary != .artifacts,
                  try Self.hash(ledger.read(archiveURL)) == binding.beforeArchiveSHA256 else {
                throw SyncDeletionLedgerError.pendingRepair
            }
        }
        manifest.groups = selected
        manifest.purgeIntents = []
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(manifest)
        let bytes = try encoder.encode(Envelope(payload: payload, sha256: Self.hash(payload)))
        guard bytes.count <= maximumBytes else { throw SyncAccountRecoveryInventory.Error.tooLarge }
        return .init(manifest: bytes, files: selected.flatMap { $0.entry.files },
            pendingMarkerVersions: manifest.pendingMarkerVersions ?? [], knownRetainedPaths: known,
            terminalSources: terminalSources)
    }

    init(root: URL, afterRootExistenceCheck: () throws -> Void = {}) throws {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        self.root = root.standardizedFileURL
        let existed = FileManager.default.fileExists(atPath: self.root.path)
        try afterRootExistenceCheck()
        try createDirectory(self.root)
        try locked {
            // Another process may have initialized and published the ledger
            // after the root check. Only the locked manifest lookup decides
            // whether creating an empty manifest is still safe.
            var status = stat()
            let result = lstat(manifestURL.path, &status)
            let lookupError = errno
            if result == 0 || existed {
                var manifest = try load()
                try completePurges(&manifest)
            } else {
                guard lookupError == ENOENT else { throw SyncDeletionLedgerError.unavailable }
                try persist(.init(version: 1, groups: []))
            }
        }
    }

    func stage(domain: SyncDeletedDomain, attachments: [UUID: SyncAttachmentSource],
               restoreRelativePaths: [UUID: String], deletedAt: Date) throws -> UUID {
        try locked {
            var manifest = try load()
            try Self.validateDomain(domain)
            let markers = manifest.markers ?? []
            try DeletionMarker.gate(records: domain.ownedRecords, markers: markers)
            let embeddedIDs = Set(domain.removedReminders.values.flatMap { $0 }.map {
                SyncEntityID(kind: .knittingReminder, uuid: $0.id)
            }).union(domain.removedLegacyPatterns.values.flatMap { $0 }.map {
                SyncEntityID(kind: .pattern, uuid: $0.id)
            })
            guard embeddedIDs.isDisjoint(with: markers.map(\.targetID)) else {
                throw SyncDeletionLedgerError.witnessMismatch
            }
            guard deletedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw SyncDeletionLedgerError.corrupt
            }
            let required = try requiredAttachments(domain)
            guard Set(attachments.keys) == Set(required.keys),
                  Set(restoreRelativePaths.keys) == Set(required.keys) else {
                throw SyncDeletionLedgerError.corrupt
            }
            let id = UUID()
            let directory = root.appendingPathComponent(id.uuidString)
            try createDirectory(directory)
            var proofs: [SyncDeletionFileProof] = []
            for versionID in required.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                let version = required[versionID]!
                let source = try attachments[versionID]!.validated()
                guard let destination = restoreRelativePaths[versionID], Self.safePath(destination),
                      source.byteCount == version.byteCount,
                      source.contentSHA256 == version.contentSHA256 else {
                    throw SyncDeletionLedgerError.missingAttachment(versionID)
                }
                // One bounded file at a time. Partial staging is invisible and
                // never changes or takes ownership of the caller's sources.
                let bytes = try read(source.fileURL,
                    expected: .init(byteCount: version.byteCount, sha256: version.contentSHA256))
                let path = "\(id.uuidString)/\(versionID.uuidString).retained"
                guard try SyncDurableFile.createNoClobber(bytes, at: root.appendingPathComponent(path)) else {
                    throw SyncDeletionLedgerError.corrupt
                }
                _ = try read(root.appendingPathComponent(path),
                    expected: .init(byteCount: version.byteCount, sha256: version.contentSHA256))
                proofs.append(.init(attachmentVersionID: versionID,
                    restoreRelativePath: restoreRelativePaths[versionID]!, retainedRelativePath: path,
                    byteCount: version.byteCount, sha256: version.contentSHA256))
            }
            manifest.groups.append(.init(entry: .init(id: id, deletedAt: deletedAt,
                domain: domain, exactRemovalVersions: [], files: proofs), binding: nil, active: false))
            try persist(manifest)
            return id
        }
    }

    func recentlyDeleted() throws -> [SyncDeletionEntry] {
        try locked { try load().groups.filter(\.active).map(\.entry) }
    }

    func deletionMarkers() throws -> [DeletionMarker] {
        try locked { try load().markers ?? [] }
    }

    /// Exact immutable publication queue; a future transport must consume this
    /// authority explicitly. Its absence never acknowledges a removal.
    func pendingDeletionMarkerVersions() throws -> [SyncRecordVersion] {
        try locked { try load().pendingMarkerVersions ?? [] }
    }

    func purge(now: Date, references: SyncDeletionReferences,
               afterIntent: () throws -> Void = {}, afterUnlink: () throws -> Void = {}) throws {
        try locked {
            var manifest = try load()
            // Replay witnesses remain owned until their reviewed publication
            // recovery contract retires them. Do not compact their payloads.
            let entries = manifest.groups.filter { $0.active && $0.restoration == nil }.map(\.entry)
            let actions = SyncDeletionPolicy.evaluate(now: now, records: entries, references: references)
            for entry in entries where actions.eligibleEntryIDs.contains(entry.id) {
                let markers = try SyncDeletionPolicy.markerCandidates(entry)
                let versions = try markers.map { try SyncRecordVersion(record: $0.record()) }
                manifest.purgeIntents = (manifest.purgeIntents ?? []) + [.init(entryID: entry.id,
                    markers: markers, pendingMarkerVersions: versions, files: entry.files)]
                for (marker, version) in zip(markers, versions) {
                    if let prior = manifest.markers?.first(where: { $0.targetID == marker.targetID }), prior != marker {
                        throw SyncDeletionLedgerError.witnessMismatch
                    }
                    if !(manifest.markers ?? []).contains(marker) {
                        manifest.markers = (manifest.markers ?? []) + [marker]
                        manifest.pendingMarkerVersions = (manifest.pendingMarkerVersions ?? []) + [version]
                    }
                }
            }
            guard !actions.eligibleEntryIDs.isEmpty else { return }
            manifest.groups.removeAll { actions.eligibleEntryIDs.contains($0.entry.id) }
            // This atomic replacement removes retained user payloads and
            // commits permanent authority before the first byte is unlinked.
            try persist(manifest)
            try afterIntent()
            try completePurges(&manifest, afterUnlink: afterUnlink)
        }
    }

    private func completePurges(_ manifest: inout Manifest, afterUnlink: () throws -> Void = {}) throws {
        guard !(manifest.purgeIntents ?? []).isEmpty else { return }
        for intent in manifest.purgeIntents ?? [] {
            for proof in intent.files {
                let file = root.appendingPathComponent(proof.retainedRelativePath)
                let parent = try openDirectory(file.deletingLastPathComponent())
                defer { close(parent) }
                var before = stat()
                if fstatat(parent, file.lastPathComponent, &before, AT_SYMLINK_NOFOLLOW) != 0 {
                    guard errno == ENOENT else { throw SyncDeletionLedgerError.unsafePath }
                    guard fsync(parent) == 0 else { throw SyncDeletionLedgerError.unavailable }
                    continue
                }
                _ = try read(file, expected: .init(byteCount: proof.byteCount, sha256: proof.sha256))
                var current = stat()
                guard fstatat(parent, file.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      before.st_dev == current.st_dev, before.st_ino == current.st_ino,
                      (current.st_mode & S_IFMT) == S_IFREG, current.st_nlink == 1,
                      unlinkat(parent, file.lastPathComponent, 0) == 0,
                      fsync(parent) == 0 else { throw SyncDeletionLedgerError.unsafePath }
            }
        }
        try afterUnlink()
        manifest.purgeIntents = []
        try persist(manifest)
    }

    func captureIncomingDeleted(domain: SyncDeletedDomain, exactRemovalVersions: [SyncRecordVersion],
        attachments: [UUID: SyncAttachmentSource], restoreRelativePaths: [UUID: String], deletedAt: Date,
        currentRecords: [SyncRecord], currentArchive: ProjectArchive,
        supportingAttachments: [UUID: SyncAttachmentSource] = [:], sourceRoots: [URL],
        counterReminderContext: SyncCounterReminderMergeContext = .init()) throws -> UUID {
        try Self.validateDomain(domain)
        guard domain.restorableRecordIDs != nil else { throw SyncDeletionLedgerError.corrupt }
        try Self.validateRemovalVersions(exactRemovalVersions, domain: domain)
        _ = try SyncRecordValidator().validate(currentRecords)
        let supplied = Dictionary(uniqueKeysWithValues: currentRecords.map { ($0.id, $0) })
        let selectedAttachments = try requiredAttachments(domain)
        guard domain.ownedRecords.allSatisfy({ supplied[$0.id] == $0 }),
              exactRemovalVersions.allSatisfy({ supplied[$0.record.id] == $0.record }),
              Set(attachments.keys) == Set(selectedAttachments.keys),
              Set(restoreRelativePaths.keys) == Set(selectedAttachments.keys),
              supportingAttachments.allSatisfy({ id, source in
                  let version = supplied[.init(kind: .attachment, uuid: id)]?.payload.attachment
                  return version?.contentSHA256 == source.contentSHA256 && version?.byteCount == source.byteCount
              }) else {
            throw SyncDeletionLedgerError.witnessMismatch
        }
        for source in Array(attachments.values) + Array(supportingAttachments.values) {
            guard sourceRoots.contains(where: { root in
                root.isFileURL && source.fileURL.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
            }) else { throw SyncDeletionLedgerError.unsafePath }
            _ = try read(source.fileURL, expected: .init(byteCount: source.byteCount, sha256: source.contentSHA256))
        }
        try validateIncomingLiveContext(records: currentRecords, archive: currentArchive,
            attachments: supportingAttachments, counterReminderContext: counterReminderContext)
        let prior = try recentlyDeleted().first { $0.domain.rootIDs == domain.rootIDs }
        var selected = domain
        var versions = exactRemovalVersions
        var retainedSources = attachments
        var paths = restoreRelativePaths
        if let prior {
            // Exact removal records, rather than the old pre-delete payload,
            // are the input to the normal field/counter merge policy.
            let oldVersions = Dictionary(uniqueKeysWithValues: prior.exactRemovalVersions.map { ($0.record.id, $0.record) })
            let old = prior.domain.ownedRecords.map { oldVersions[$0.id] ?? $0 }
            let merged = try SyncMergeEngine().merge(local: old, remote: domain.ownedRecords, pendingLocal: [])
            let selectedIDs = prior.domain.selectedLiveIDs.union(domain.selectedLiveIDs)
            guard prior.domain.removedReminders == domain.removedReminders,
                  prior.domain.photoAssociations == domain.photoAssociations,
                  prior.domain.removedLegacyPatterns == domain.removedLegacyPatterns else {
                // Embedded values have no standalone merge authority. Their
                // caller must supply an identical selected removal set.
                throw SyncDeletionLedgerError.witnessMismatch
            }
            selected = .init(rootIDs: domain.rootIDs, ownedRecords: merged.records,
                supportingParentIDs: prior.domain.supportingParentIDs.union(domain.supportingParentIDs),
                removedReminders: domain.removedReminders, removedLegacyPatterns: domain.removedLegacyPatterns,
                removedPhotoAssociations: domain.removedPhotoAssociations,
                restorableRecordIDs: selectedIDs)
            let mergedProofs = try SyncMergeEngine().merge(local: prior.exactRemovalVersions.map(\.record),
                remote: exactRemovalVersions.map(\.record), pendingLocal: [])
            versions = try mergedProofs.records.map { try .init(record: $0) }
            for proof in prior.files where retainedSources[proof.attachmentVersionID] == nil {
                retainedSources[proof.attachmentVersionID] = try .init(fileURL: root.appendingPathComponent(proof.retainedRelativePath),
                    contentSHA256: proof.sha256, byteCount: proof.byteCount)
                paths[proof.attachmentVersionID] = proof.restoreRelativePath
            }
        }
        try Self.validateDomain(selected)
        try Self.validateRemovalVersions(versions, domain: selected)
        let required = try requiredAttachments(selected)
        retainedSources = retainedSources.filter { required[$0.key] != nil }
        paths = paths.filter { required[$0.key] != nil }
        let stagedID = try stage(domain: selected, attachments: retainedSources,
            restoreRelativePaths: paths, deletedAt: min(deletedAt, prior?.deletedAt ?? deletedAt))
        var authority = supplied
        for record in selected.ownedRecords { authority[record.id] = record }
        for version in versions { authority[version.record.id] = version.record }
        let revived = try selected.restoring(into: Array(authority.values), now: deletedAt, deviceID: "incoming-validation")
        var validationSources = supportingAttachments
        for (child, predecessor) in revived.restoredAttachmentPredecessors { validationSources[child] = retainedSources[predecessor] }
        let stagedSources = try stageRestoreSources(id: stagedID, sources: validationSources)
        let materialization = try ProjectArchiveSyncMapper.materialize(records: revived.records,
            attachments: stagedSources, baseArchive: currentArchive)
        let bySlot = Dictionary(uniqueKeysWithValues: materialization.files.map { ($0.version.slot, $0.relativePath) })
        guard required.allSatisfy({ paths[$0.key] == bySlot[$0.value.slot] }) else {
            throw SyncDeletionLedgerError.witnessMismatch
        }
        return try locked {
            var manifest = try load()
            let current = manifest.groups.first { $0.active && $0.entry.domain.rootIDs == domain.rootIDs }
            guard current?.entry == prior,
                  current?.restoration == nil,
                  let stagedIndex = manifest.groups.firstIndex(where: { $0.entry.id == stagedID }) else {
                throw SyncDeletionLedgerError.pendingRepair
            }
            let staged = manifest.groups[stagedIndex].entry
            let id = prior?.id ?? stagedID
            var proofs = staged.files
            if prior != nil {
                proofs = try staged.files.map { proof in
                    let path = "\(id.uuidString)/\(proof.attachmentVersionID.uuidString).retained"
                    let bytes = try read(root.appendingPathComponent(proof.retainedRelativePath),
                        expected: .init(byteCount: proof.byteCount, sha256: proof.sha256))
                    if !(try SyncDurableFile.createNoClobber(bytes, at: root.appendingPathComponent(path))) {
                        _ = try read(root.appendingPathComponent(path), expected: .init(byteCount: proof.byteCount, sha256: proof.sha256))
                    }
                    return .init(attachmentVersionID: proof.attachmentVersionID,
                        restoreRelativePath: proof.restoreRelativePath, retainedRelativePath: path,
                        byteCount: proof.byteCount, sha256: proof.sha256)
                }
            }
            manifest.groups.removeAll { $0.entry.id == stagedID || $0.entry.id == id }
            manifest.groups.append(.init(entry: .init(id: id, deletedAt: staged.deletedAt,
                domain: selected, exactRemovalVersions: versions, files: proofs), binding: nil, active: true, incoming: true))
            try persist(manifest)
            return id
        }
    }

    private func validateIncomingLiveContext(records: [SyncRecord], archive: ProjectArchive,
        attachments: [UUID: SyncAttachmentSource], counterReminderContext: SyncCounterReminderMergeContext) throws {
        // Archive JSON cannot encode prepared/processed Watch authority. The
        // frozen caller supplies that external context when present; use the
        // existing merge validator to reject canonical states that regress it.
        _ = try SyncMergeEngine().merge(local: records, remote: [SyncRecord](), pendingLocal: [],
            counterReminderContext: counterReminderContext)
        let directory = root.appendingPathComponent(".incoming-validation-\(UUID())")
        var staged: [UUID: SyncAttachmentSource] = [:]
        defer {
            if !attachments.isEmpty { try? FileManager.default.removeItem(at: directory) }
        }
        if !attachments.isEmpty { try createDirectory(directory) }
        for (id, source) in attachments {
            let bytes = try read(source.fileURL, expected: .init(byteCount: source.byteCount, sha256: source.contentSHA256))
            let destination = directory.appendingPathComponent(id.uuidString)
            guard try SyncDurableFile.createNoClobber(bytes, at: destination) else { throw SyncDeletionLedgerError.corrupt }
            staged[id] = .init(fileURL: destination, contentSHA256: source.contentSHA256,
                byteCount: source.byteCount, isJournalStaged: true)
        }
        // Validate the unrevived live projection, not the restoration candidate.
        // This precedes all deletion-group staging and manifest changes.
        let projected = try ProjectArchiveSyncMapper.materialize(records: records,
            attachments: staged, baseArchive: archive).archive
        func same<T: Identifiable & Equatable>(_ lhs: [T], _ rhs: [T]) -> Bool where T.ID == UUID {
            lhs.sorted { $0.id.uuidString < $1.id.uuidString } == rhs.sorted { $0.id.uuidString < $1.id.uuidString }
        }
        guard same(projected.projects, archive.projects), same(projected.yarns, archive.yarns),
              same(projected.patternFolders, archive.patternFolders), same(projected.patternAssets, archive.patternAssets),
              same(projected.patterns, archive.patterns), same(projected.patternUsages, archive.patternUsages) else {
            throw SyncDeletionLedgerError.witnessMismatch
        }
    }

    func beginRestore(publication: SyncPublicationTransaction) throws {
        try locked {
            var manifest = try load()
            guard let witness = publication.restorationWitness,
                  let index = manifest.groups.firstIndex(where: { $0.entry.id == witness.entryID }),
                  manifest.groups[index].active, manifest.groups[index].restoration == nil else {
                throw SyncDeletionLedgerError.witnessMismatch
            }
            try validateRestoration(publication, entry: manifest.groups[index].entry)
            manifest.groups[index].restoration = .init(publication: publication, phase: "prepared")
            try persist(manifest)
        }
    }

    func stageRestoreSources(id: UUID, sources: [UUID: SyncAttachmentSource]) throws -> [UUID: SyncAttachmentSource] {
        try locked {
            guard try load().groups.contains(where: { $0.entry.id == id && $0.restoration == nil }) else {
                throw SyncDeletionLedgerError.witnessMismatch
            }
            let directory = root.appendingPathComponent(id.uuidString).appendingPathComponent("restore-\(UUID())")
            try createDirectory(directory)
            var result: [UUID: SyncAttachmentSource] = [:]
            for (versionID, source) in sources {
                let bytes = try read(source.fileURL, expected: .init(byteCount: source.byteCount, sha256: source.contentSHA256))
                let destination = directory.appendingPathComponent(versionID.uuidString)
                guard try SyncDurableFile.createNoClobber(bytes, at: destination) else { throw SyncDeletionLedgerError.corrupt }
                result[versionID] = .init(fileURL: destination, contentSHA256: source.contentSHA256,
                    byteCount: source.byteCount, isJournalStaged: true)
            }
            return result
        }
    }

    func installRestoreFiles(_ files: [ProjectArchiveSyncFile], liveRoot: URL) throws {
        try checkDirectory(liveRoot)
        for file in files {
            guard Self.safePath(file.relativePath) else { throw SyncDeletionLedgerError.unsafePath }
            let destination = liveRoot.appendingPathComponent(file.relativePath)
            // Recursive creation validates every existing ancestor no-follow
            // before any child can be created outside the caller's live root.
            try createDirectory(destination.deletingLastPathComponent())
            let expectation = SyncRegularFileExpectation(byteCount: file.version.byteCount,
                sha256: file.version.contentSHA256)
            let bytes = try read(file.source.fileURL, expected: expectation)
            _ = try SyncDurableFile.createNoClobber(bytes, at: destination)
            _ = try read(destination, expected: expectation)
            let parent = try openDirectory(destination.deletingLastPathComponent())
            defer { close(parent) }
            let descriptor = openat(parent, destination.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw SyncDeletionLedgerError.unsafePath }
            defer { close(descriptor) }
            guard fsync(descriptor) == 0, fsync(parent) == 0 else { throw SyncDeletionLedgerError.unavailable }
        }
    }

    func finishRestore(publication: SyncPublicationTransaction) throws {
        try locked {
            var manifest = try load()
            guard let witness = publication.restorationWitness,
                  let index = manifest.groups.firstIndex(where: { $0.entry.id == witness.entryID }),
                  let restoration = manifest.groups[index].restoration,
                  restoration.publication == publication,
                  ["prepared", "completed"].contains(restoration.phase) else {
                throw SyncDeletionLedgerError.witnessMismatch
            }
            manifest.groups[index].active = false
            manifest.groups[index].restoration?.phase = "completed"
            // Keep both the exact completion witness and all byte copies. A
            // crash before marker reclamation can replay without reactivation.
            try persist(manifest)
        }
    }

    private func validateRestoration(_ publication: SyncPublicationTransaction, entry: SyncDeletionEntry) throws {
        _ = try publication.validated()
        let saved = publication.mutations.compactMap(\.savedRecordVersion?.record)
        guard !saved.isEmpty, saved.count == publication.mutations.count,
              saved.allSatisfy({ $0.deletedAt.value == nil }) else { throw SyncDeletionLedgerError.witnessMismatch }
        let domain = entry.domain
        let counters = Set(domain.removedReminders.keys.map { SyncEntityID(kind: .projectCounter, uuid: $0) })
        let projects = Set(saved.filter { counters.contains($0.id) }.flatMap(\.relationships)
            .filter { $0.role == "project" }.map(\.target))
        let structural = domain.selectedLiveIDs.filter { $0.kind != .attachment }.union(counters)
            .union(domain.photoAssociations.map { $0.slot.owner })
            .union(projects).union(domain.removedLegacyPatterns.keys.map { .init(kind: .project, uuid: $0) })
        guard Set(saved.filter { $0.id.kind != .attachment }.map(\.id)) == structural else {
            throw SyncDeletionLedgerError.witnessMismatch
        }
        let required = try requiredAttachments(domain)
        let children = saved.filter { $0.id.kind == .attachment }
        guard children.count == required.count,
              Set(children.compactMap { $0.payload.attachment?.replacesVersionID }) == Set(required.keys) else {
            throw SyncDeletionLedgerError.witnessMismatch
        }
        for child in children {
            guard let version = child.payload.attachment, let parentID = version.replacesVersionID,
                  let parent = required[parentID], !domain.ownedRecords.contains(where: { $0.id == child.id }),
                  version.slot == parent.slot, version.contentSHA256 == parent.contentSHA256,
                  version.byteCount == parent.byteCount, version.mediaType == parent.mediaType,
                  version.displayFilename == parent.displayFilename else { throw SyncDeletionLedgerError.witnessMismatch }
        }
        for (id, reminders) in domain.removedReminders {
            guard let record = saved.first(where: { $0.id == .init(kind: .projectCounter, uuid: id) }),
                  case let .projectCounter(state)? = record.payload.atomicDomain?.value,
                  reminders.allSatisfy({ state.reminders.contains($0) }) else { throw SyncDeletionLedgerError.witnessMismatch }
        }
        for association in domain.photoAssociations {
            guard let record = saved.first(where: { $0.id == association.slot.owner }),
                  try Self.photoAssociation(association, isPresentIn: record) else {
                throw SyncDeletionLedgerError.witnessMismatch
            }
        }
    }

    func prepare(id: UUID, beforeArchiveSHA256: Data, afterArchiveSHA256: Data,
                 exactRemovalVersions: [SyncRecordVersion], publicationSHA256: Data,
                 commitBoundary: SyncPublicationCommitBoundary = .archive) throws {
        try locked {
            var manifest = try load()
            guard let index = manifest.groups.firstIndex(where: { $0.entry.id == id }),
                  manifest.groups[index].binding == nil,
                  beforeArchiveSHA256.count == 32, afterArchiveSHA256.count == 32,
                  (beforeArchiveSHA256 != afterArchiveSHA256 || commitBoundary == .artifacts), publicationSHA256.count == 32 else {
                throw SyncDeletionLedgerError.witnessMismatch
            }
            let entry = manifest.groups[index].entry
            let versions = try exactRemovalVersions.map { try $0.validated() }
            try Self.validateRemovalVersions(versions, domain: entry.domain)
            manifest.groups[index].entry = .init(id: entry.id, deletedAt: entry.deletedAt,
                domain: entry.domain, exactRemovalVersions: versions, files: entry.files)
            manifest.groups[index].binding = .init(beforeArchiveSHA256: beforeArchiveSHA256,
                afterArchiveSHA256: afterArchiveSHA256, publicationSHA256: publicationSHA256,
                commitBoundary: commitBoundary)
            try persist(manifest)
        }
    }

    func activate(id: UUID, publicationSHA256: Data) throws {
        try locked {
            var manifest = try load()
            guard let index = manifest.groups.firstIndex(where: { $0.entry.id == id }),
                  manifest.groups[index].binding?.publicationSHA256 == publicationSHA256,
                  manifest.groups[index].canceled != true else {
                throw SyncDeletionLedgerError.witnessMismatch
            }
            manifest.groups[index].active = true
            try persist(manifest)
        }
    }

    // Caller has proved archive commit and completed durable sink publication.
    // Matching a hash also handles a restart with no in-memory staged UUID.
    func activate(publication: SyncPublicationTransaction) throws {
        let witness = try Self.publicationFingerprint(publication)
        try locked {
            var manifest = try load()
            var changed = false
            if let expected = publication.deletionLedgerID,
               !manifest.groups.contains(where: { $0.entry.id == expected && $0.binding?.publicationSHA256 == witness }) {
                throw SyncDeletionLedgerError.witnessMismatch
            }
            for index in manifest.groups.indices where manifest.groups[index].binding?.publicationSHA256 == witness {
                try validatePublication(publication, group: manifest.groups[index])
                guard manifest.groups[index].canceled != true else { throw SyncDeletionLedgerError.witnessMismatch }
                manifest.groups[index].active = true
                changed = true
            }
            if changed { try persist(manifest) }
        }
    }

    func recover(archiveSHA256: Data, publication: SyncPublicationTransaction?,
                 publicationStatus: SyncPublicationCommitStatus? = nil) throws {
        try locked {
            var manifest = try load()
            let witness = try publication.map(Self.publicationFingerprint)
            if let expected = publication?.restorationWitness,
               !manifest.groups.contains(where: {
                   $0.entry.id == expected.entryID && $0.restoration?.publication == publication
               }) { throw SyncDeletionLedgerError.witnessMismatch }
            if let expected = publication?.deletionLedgerID,
               !manifest.groups.contains(where: { $0.entry.id == expected && $0.binding?.publicationSHA256 == witness }) {
                throw SyncDeletionLedgerError.witnessMismatch
            }
            var keep: [Group] = []
            var changed = false
            for var group in manifest.groups {
                if var restoration = group.restoration {
                    let own = restoration.publication
                    guard let restoreWitness = own.restorationWitness else { throw SyncDeletionLedgerError.corrupt }
                    let matches = publication == own
                    if restoration.phase == "completed" {
                        keep.append(group)
                        continue
                    }
                    if restoration.phase == "canceled" {
                        if matches {
                            guard publicationStatus == .uncommitted else { throw SyncDeletionLedgerError.pendingRepair }
                        } else { group.restoration = nil; changed = true }
                        keep.append(group)
                        continue
                    }
                    guard publication == nil || matches else { throw SyncDeletionLedgerError.witnessMismatch }
                    if archiveSHA256 == restoreWitness.beforeArchiveSHA256,
                       !matches || publicationStatus == .uncommitted {
                        if matches {
                            restoration.phase = "canceled"
                            group.restoration = restoration
                        } else { group.restoration = nil }
                        changed = true
                    } else {
                        guard matches, publicationStatus == .committed else {
                            throw SyncDeletionLedgerError.pendingRepair
                        }
                    }
                    keep.append(group)
                    continue
                }
                if group.active {
                    if let publication,
                       publication.deletionLedgerID == group.entry.id || witness == group.binding?.publicationSHA256 {
                        try validatePublication(publication, group: group)
                    }
                    keep.append(group)
                    continue
                }
                guard let binding = group.binding else { continue }
                if group.canceled == true {
                    // Keep the exact cancellation witness while its marker
                    // can still be replayed. Absence/a different marker proves
                    // reclamation; no attachment bytes are removed here.
                    if witness == binding.publicationSHA256, let publication {
                        try validatePublication(publication, group: group)
                        guard binding.commitBoundary == .artifacts
                            ? publicationStatus == .uncommitted
                            : archiveSHA256 == binding.beforeArchiveSHA256 else {
                            throw SyncDeletionLedgerError.pendingRepair
                        }
                        keep.append(group)
                    }
                    continue
                }
                if binding.commitBoundary == .artifacts {
                    guard let publication, witness == binding.publicationSHA256 else {
                        throw SyncDeletionLedgerError.pendingRepair
                    }
                    try validatePublication(publication, group: group)
                    switch publicationStatus {
                    case .committed: keep.append(group)
                    case .uncommitted:
                        group.canceled = true
                        changed = true
                        keep.append(group)
                    default: throw SyncDeletionLedgerError.pendingRepair
                    }
                    continue
                }
                if archiveSHA256 == binding.beforeArchiveSHA256 {
                    guard witness == nil || witness == binding.publicationSHA256 else {
                        throw SyncDeletionLedgerError.witnessMismatch
                    }
                    if witness != nil {
                        group.canceled = true
                        changed = true
                        keep.append(group)
                    }
                    continue
                }
                guard archiveSHA256 == binding.afterArchiveSHA256,
                      witness == binding.publicationSHA256,
                      publication?.expectedArchiveSHA256 == binding.afterArchiveSHA256 else {
                    throw SyncDeletionLedgerError.pendingRepair
                }
                try validatePublication(publication!, group: group)
                // Never interpret committed archive bytes as journal durability.
                keep.append(group)
            }
            if changed || keep.count != manifest.groups.count {
                manifest.groups = keep
                try persist(manifest)
            }
        }
    }

    static func publicationFingerprint(_ transaction: SyncPublicationTransaction) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return hash(try encoder.encode(transaction.validated()))
    }

    private func validatePublication(_ publication: SyncPublicationTransaction, group: Group) throws {
        guard let binding = group.binding,
              publication.expectedArchiveSHA256 == binding.afterArchiveSHA256,
              publication.commitBoundary == (binding.commitBoundary ?? .archive),
              try Self.publicationFingerprint(publication) == binding.publicationSHA256 else {
            throw SyncDeletionLedgerError.witnessMismatch
        }
        for version in group.entry.exactRemovalVersions {
            let mutations = publication.mutations.filter { $0.recordID == version.record.id }
            guard mutations.count == 1,
                  case let .save(save) = mutations[0], save.recordVersion == version else {
                throw SyncDeletionLedgerError.witnessMismatch
            }
        }
    }

    private func requiredAttachments(_ domain: SyncDeletedDomain) throws -> [UUID: SyncAttachmentVersion] {
        let lineage = try SyncAttachmentLineage(records: domain.ownedRecords)
        return Dictionary(uniqueKeysWithValues: lineage.headsBySlot.values.flatMap { $0 }
            .filter { domain.selectedLiveIDs.contains($0.id) }.map { ($0.id.uuid, $0.payload.attachment!) })
    }

    static func validateRemovalVersions(_ versions: [SyncRecordVersion], domain: SyncDeletedDomain) throws {
        let owned = Dictionary(uniqueKeysWithValues: domain.ownedRecords.filter {
            domain.selectedLiveIDs.contains($0.id)
        }.map { ($0.id, $0) })
        let expected = Set(owned.keys)
            .union(domain.photoAssociations.map { $0.slot.owner })
            .union(domain.removedReminders.keys.map { .init(kind: .projectCounter, uuid: $0) })
            .union(domain.removedLegacyPatterns.keys.map { .init(kind: .project, uuid: $0) })
        guard Set(versions.map { $0.record.id }) == expected, versions.count == expected.count else {
            throw SyncDeletionLedgerError.witnessMismatch
        }
        for version in versions {
            let record = try version.validated().record
            for association in domain.photoAssociations where association.slot.owner == record.id {
                guard record.deletedAt.value == nil,
                      try !Self.photoAssociation(association, isPresentIn: record, requireVacant: true) else {
                    throw SyncDeletionLedgerError.witnessMismatch
                }
            }
            if let original = owned[record.id] {
                if domain.restorableRecordIDs != nil {
                    guard record == original, record.deletedAt.value != nil else {
                        throw SyncDeletionLedgerError.witnessMismatch
                    }
                    continue
                }
                // Causal allocation can restamp fields, but cannot change the
                // content whose removal this entry promises to recover.
                guard record.deletedAt.value != nil,
                      record.deletedAt.stamp > original.deletedAt.stamp,
                      record.createdAt == original.createdAt,
                      record.relationships == original.relationships,
                      record.payload.fields.mapValues(\.value) == original.payload.fields.mapValues(\.value),
                      record.payload.atomicDomain?.value == original.payload.atomicDomain?.value,
                      record.payload.attachment == original.payload.attachment else {
                    throw SyncDeletionLedgerError.witnessMismatch
                }
            } else if record.id.kind == .projectCounter,
                      let reminders = domain.removedReminders[record.id.uuid] {
                guard record.deletedAt.value == nil,
                      case let .projectCounter(state)? = record.payload.atomicDomain?.value,
                      Set(state.reminders.map(\.id)).isDisjoint(with: reminders.map(\.id)) else {
                    throw SyncDeletionLedgerError.witnessMismatch
                }
            } else if record.id.kind == .project,
                      let patterns = domain.removedLegacyPatterns[record.id.uuid] {
                guard record.deletedAt.value == nil,
                      case let .data(data)? = record.payload.fields["domainSnapshot"]?.value else {
                    throw SyncDeletionLedgerError.witnessMismatch
                }
                let project = try JSONDecoder().decode(SyncProjectProjection.self, from: data)
                guard project.id == record.id.uuid,
                      Set(project.legacyPatterns.map(\.id)).isDisjoint(with: patterns.map(\.id)) else {
                    throw SyncDeletionLedgerError.witnessMismatch
                }
            } else if !domain.photoAssociations.contains(where: { $0.slot.owner == record.id }) {
                throw SyncDeletionLedgerError.witnessMismatch
            }
        }
    }

    private static func photoAssociation(_ association: SyncDeletedDomain.PhotoAssociation,
        isPresentIn record: SyncRecord, requireVacant: Bool = false) throws -> Bool {
        guard case let .data(data)? = record.payload.fields["domainSnapshot"]?.value else {
            throw SyncDeletionLedgerError.witnessMismatch
        }
        if record.id.kind == .project {
            let owner = try JSONDecoder().decode(SyncProjectProjection.self, from: data)
            guard owner.id == record.id.uuid, !requireVacant || owner.photoFilename == nil else {
                throw SyncDeletionLedgerError.witnessMismatch
            }
            return owner.photoFilename == association.filename
        }
        let owner = try JSONDecoder().decode(SyncYarnProjection.self, from: data)
        guard owner.id == record.id.uuid else { throw SyncDeletionLedgerError.witnessMismatch }
        if association.slot.role == "yarn-photo" {
            guard !requireVacant || owner.photoFilename == nil else { throw SyncDeletionLedgerError.witnessMismatch }
            return owner.photoFilename == association.filename
        }
        let id = UUID(uuidString: String(association.slot.slotID.dropFirst("label:".count)))
        if requireVacant {
            guard !owner.labelPhotoFilenames.contains(association.filename),
                  !owner.labelPhotoSlotIDs.contains(where: { $0 == id }) else { throw SyncDeletionLedgerError.witnessMismatch }
        }
        return zip(owner.labelPhotoFilenames, owner.labelPhotoSlotIDs).contains {
            $0 == association.filename && $1 == id
        }
    }

    static func validateDomain(_ domain: SyncDeletedDomain) throws {
        _ = try SyncRecordValidator().validate(domain.ownedRecords)
        var slots = Set<SyncAttachmentSlot>()
        for association in domain.photoAssociations {
            let slot = association.slot
            guard slots.insert(slot).inserted,
                  domain.supportingParentIDs.contains(slot.owner),
                  association.filename == URL(fileURLWithPath: association.filename).lastPathComponent,
                  Self.safePath(association.filename),
                  (slot.role == "project-photo" && slot.owner.kind == .project && slot.slotID == "primary")
                    || (slot.role == "yarn-photo" && slot.owner.kind == .yarn && slot.slotID == "primary")
                    || (slot.role == "yarn-label-photo" && slot.owner.kind == .yarn
                        && slot.slotID.hasPrefix("label:") && UUID(uuidString: String(slot.slotID.dropFirst(6))) != nil),
                  domain.ownedRecords.contains(where: {
                      domain.selectedLiveIDs.contains($0.id) && $0.payload.attachment?.slot == slot
                        && $0.payload.attachment?.displayFilename == association.filename
                  }) else { throw SyncDeletionLedgerError.corrupt }
        }
        var selectedReminderIDs = Set<UUID>()
        for (counterID, reminders) in domain.removedReminders {
            guard !reminders.isEmpty,
                  reminders.allSatisfy({ $0.counterID == counterID && selectedReminderIDs.insert($0.id).inserted }) else {
                throw SyncDeletionLedgerError.corrupt
            }
            // The domain type's decoder validates rule/progress invariants.
            _ = try JSONDecoder().decode([KnittingReminder].self, from: JSONEncoder().encode(reminders))
        }
        var selectedPatternIDs = Set<UUID>()
        for patterns in domain.removedLegacyPatterns.values {
            guard !patterns.isEmpty, patterns.allSatisfy({
                selectedPatternIDs.insert($0.id).inserted && Self.safePath($0.storedFilename)
            }) else { throw SyncDeletionLedgerError.corrupt }
        }
        let owned = Set(domain.ownedRecords.map(\.id))
        if let selected = domain.restorableRecordIDs {
            guard !selected.isEmpty || !domain.removedReminders.isEmpty || !domain.removedLegacyPatterns.isEmpty,
                  selected.isSubset(of: owned),
                  domain.ownedRecords.filter({ selected.contains($0.id) }).allSatisfy({ $0.deletedAt.value != nil }),
                  domain.ownedRecords.filter({ selected.contains($0.id) }).allSatisfy({ record in
                      Set(record.payload.deletionCascade?.value ?? []).isSubset(of: selected)
                  }) else { throw SyncDeletionLedgerError.corrupt }
            var reachable = domain.rootIDs.intersection(selected)
            var priorCount = -1
            while priorCount != reachable.count {
                priorCount = reachable.count
                // Shared-parent deletions remove links/usages without putting
                // them in a parent-owned cascade (e.g. Yarn does not own a
                // project link). Their exact selected relationship proves scope.
                reachable.formUnion(domain.ownedRecords.filter { record in
                    record.id.kind != .attachment && selected.contains(record.id)
                        && record.relationships.contains { reachable.contains($0.target) }
                }.map(\.id))
                for record in domain.ownedRecords where reachable.contains(record.id) {
                    reachable.formUnion(record.payload.deletionCascade?.value ?? [])
                    if record.id.kind == .project,
                       case let .data(data)? = record.payload.fields["domainSnapshot"]?.value {
                        let legacy = try JSONDecoder().decode(SyncProjectProjection.self, from: data)
                        let legacyIDs = Set(legacy.legacyPatterns.map { SyncEntityID(kind: .pattern, uuid: $0.id) })
                        reachable.formUnion(domain.ownedRecords.filter { record in
                            selected.contains(record.id) && record.id.kind == .attachment
                                && record.relationships.contains { legacyIDs.contains($0.target) }
                        }.map(\.id))
                    }
                }
            }
            let embeddedRoots = Set(domain.removedLegacyPatterns.values.flatMap { $0 }.map { SyncEntityID(kind: .pattern, uuid: $0.id) })
            reachable.formUnion(domain.ownedRecords.filter { record in
                selected.contains(record.id) && record.id.kind == .attachment
                    && record.relationships.contains { embeddedRoots.contains($0.target) }
            }.map(\.id))
            guard selected == reachable else { throw SyncDeletionLedgerError.witnessMismatch }
        }
        let reminderParents = Set(domain.removedReminders.keys.map { SyncEntityID(kind: .projectCounter, uuid: $0) })
        let legacyParents = Set(domain.removedLegacyPatterns.keys.map { SyncEntityID(kind: .project, uuid: $0) })
        var legacyIDs = Set(domain.removedLegacyPatterns.values.flatMap { $0 }.map { SyncEntityID(kind: .pattern, uuid: $0.id) })
        for record in domain.ownedRecords where record.id.kind == .project {
            guard case let .data(bytes)? = record.payload.fields["domainSnapshot"]?.value else {
                throw SyncDeletionLedgerError.corrupt
            }
            let project = try JSONDecoder().decode(SyncProjectProjection.self, from: bytes)
            legacyIDs.formUnion(project.legacyPatterns.map { .init(kind: .pattern, uuid: $0.id) })
        }
        guard !domain.rootIDs.isEmpty,
              domain.rootIDs.isSubset(of: owned.union(reminderParents).union(legacyIDs)),
              owned.isDisjoint(with: domain.supportingParentIDs),
              reminderParents.isSubset(of: domain.supportingParentIDs),
              legacyParents.isSubset(of: domain.supportingParentIDs),
              domain.ownedRecords.allSatisfy({ record in
                  record.relationships.allSatisfy { owned.contains($0.target) || domain.supportingParentIDs.contains($0.target) || legacyIDs.contains($0.target) }
              }) else { throw SyncDeletionLedgerError.corrupt }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        try checkDirectory(root)
        return try SyncDurableFile.withExclusiveFileLock(for: manifestURL, body)
    }

    private func load(validateRetainedFiles: Bool = true) throws -> Manifest {
        let data = try read(manifestURL)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard Self.hash(envelope.payload) == envelope.sha256 else { throw SyncDeletionLedgerError.corrupt }
        let manifest = try JSONDecoder().decode(Manifest.self, from: envelope.payload)
        guard manifest.version == 1,
              Set(manifest.groups.map { $0.entry.id }).count == manifest.groups.count else {
            throw SyncDeletionLedgerError.corrupt
        }
        let markers = manifest.markers ?? []
        let pending = manifest.pendingMarkerVersions ?? []
        guard Set(markers.map(\.targetID)).count == markers.count,
              Set(pending.map(\.versionID)).count == pending.count,
              pending.count == markers.count else { throw SyncDeletionLedgerError.corrupt }
        for marker in markers {
            let version = try SyncRecordVersion(record: marker.record())
            guard pending.contains(version) else { throw SyncDeletionLedgerError.witnessMismatch }
        }
        let intents = manifest.purgeIntents ?? []
        guard Set(intents.map(\.entryID)).count == intents.count,
              Set(intents.map(\.entryID)).isDisjoint(with: manifest.groups.map { $0.entry.id }) else {
            throw SyncDeletionLedgerError.corrupt
        }
        for intent in intents {
            guard !intent.markers.isEmpty, intent.markers.allSatisfy({ markers.contains($0) }),
                  intent.pendingMarkerVersions == (try intent.markers.map { try SyncRecordVersion(record: $0.record()) }),
                  intent.pendingMarkerVersions.allSatisfy({ pending.contains($0) }),
                  Set(intent.files.map(\.attachmentVersionID)).count == intent.files.count else {
                throw SyncDeletionLedgerError.witnessMismatch
            }
            for proof in intent.files {
                guard proof.retainedRelativePath == "\(intent.entryID.uuidString)/\(proof.attachmentVersionID.uuidString).retained",
                      Self.safePath(proof.restoreRelativePath), proof.byteCount >= 0,
                      proof.byteCount <= maximumBytes, proof.sha256.count == 32,
                      intent.markers.contains(where: { $0.targetID == .init(kind: .attachment, uuid: proof.attachmentVersionID) }) else {
                    throw SyncDeletionLedgerError.corrupt
                }
            }
        }
        for group in manifest.groups {
            try Self.validateDomain(group.entry.domain)
            guard group.entry.deletedAt.timeIntervalSinceReferenceDate.isFinite,
                  !group.active || ((group.binding != nil || group.incoming == true) && group.canceled != true),
                  group.canceled != true || group.binding != nil else { throw SyncDeletionLedgerError.corrupt }
            if let restoration = group.restoration {
                try validateRestoration(restoration.publication, entry: group.entry)
                guard restoration.publication.restorationWitness?.entryID == group.entry.id,
                      ["prepared", "canceled", "completed"].contains(restoration.phase),
                      group.active == (restoration.phase != "completed") else {
                    throw SyncDeletionLedgerError.corrupt
                }
            }
            if let binding = group.binding {
                guard binding.beforeArchiveSHA256.count == 32,
                      binding.afterArchiveSHA256.count == 32,
                      binding.publicationSHA256.count == 32,
                      (binding.beforeArchiveSHA256 != binding.afterArchiveSHA256 || binding.commitBoundary == .artifacts) else {
                    throw SyncDeletionLedgerError.corrupt
                }
                try Self.validateRemovalVersions(group.entry.exactRemovalVersions, domain: group.entry.domain)
            } else if group.incoming == true {
                guard group.entry.domain.restorableRecordIDs != nil else { throw SyncDeletionLedgerError.corrupt }
                try Self.validateRemovalVersions(group.entry.exactRemovalVersions, domain: group.entry.domain)
            } else if !group.entry.exactRemovalVersions.isEmpty {
                throw SyncDeletionLedgerError.corrupt
            }
            let required = try requiredAttachments(group.entry.domain)
            guard group.entry.files.count == required.count,
                  Set(group.entry.files.map(\.attachmentVersionID)) == Set(required.keys) else {
                throw SyncDeletionLedgerError.corrupt
            }
            for proof in group.entry.files {
                guard let version = required[proof.attachmentVersionID],
                      proof.byteCount == version.byteCount, proof.sha256 == version.contentSHA256,
                      Self.safePath(proof.restoreRelativePath),
                      proof.retainedRelativePath == "\(group.entry.id.uuidString)/\(proof.attachmentVersionID.uuidString).retained" else {
                    throw SyncDeletionLedgerError.corrupt
                }
                let file = root.appendingPathComponent(proof.retainedRelativePath)
                if validateRetainedFiles {
                    _ = try read(file,
                        expected: .init(byteCount: proof.byteCount, sha256: proof.sha256))
                }
            }
        }
        return manifest
    }

    private func persist(_ manifest: Manifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(manifest)
        let data = try encoder.encode(Envelope(payload: payload, sha256: Self.hash(payload)))
        guard data.count <= maximumBytes else { throw SyncDeletionLedgerError.corrupt }
        try SyncDurableFile.write(data, to: manifestURL)
    }

    private func createDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try checkDirectory(url); return }
        try createDirectory(url.deletingLastPathComponent())
        guard mkdir(url.path, S_IRWXU) == 0 else { throw SyncDeletionLedgerError.unsafePath }
        try SyncDurableFile.synchronizeDirectory(url.deletingLastPathComponent())
    }

    private func checkDirectory(_ url: URL) throws {
        close(try openDirectory(url))
    }

    private func openDirectory(_ url: URL) throws -> Int32 {
        var path = url.standardizedFileURL.path
        if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") { path = "/private" + path }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SyncDeletionLedgerError.unsafePath }
        for component in path.split(separator: "/") {
            let next = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { close(descriptor); throw SyncDeletionLedgerError.unsafePath }
            close(descriptor)
            descriptor = next
        }
        return descriptor
    }

    // Bind the final no-follow open to the verified parent descriptor, so no
    // unchecked parent traversal occurs between ancestry validation and read.
    private func read(_ url: URL, expected: SyncRegularFileExpectation? = nil) throws -> Data {
        guard url.isFileURL else { throw SyncDeletionLedgerError.unsafePath }
        let parent = try openDirectory(url.deletingLastPathComponent())
        defer { close(parent) }
        let file = openat(parent, url.lastPathComponent, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw SyncDeletionLedgerError.unsafePath }
        defer { close(file) }
        var before = stat()
        guard fstat(file, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG, before.st_nlink == 1,
              before.st_size >= 0, before.st_size <= maximumBytes,
              expected?.byteCount == nil || expected?.byteCount == Int64(before.st_size) else {
            throw SyncDeletionLedgerError.corrupt
        }
        let limit = Int(before.st_size)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(file, $0.baseAddress, min($0.count, limit - data.count + 1))
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0, count <= limit - data.count else { throw SyncDeletionLedgerError.corrupt }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        var after = stat()
        guard fstat(file, &after) == 0, after.st_nlink == 1,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, data.count == limit,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              expected?.sha256 == nil || expected?.sha256 == Self.hash(data) else {
            throw SyncDeletionLedgerError.corrupt
        }
        return data
    }

    private static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.utf8.contains(0) && path.utf8.count <= 1_024
            && path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func hash(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
}
