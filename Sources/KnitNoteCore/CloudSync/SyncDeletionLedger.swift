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
    }
    private struct Manifest: Codable {
        let version: Int
        var groups: [Group]
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
                _ = try load()
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
            try validate(domain)
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
            try validateRemovalVersions(versions, domain: entry.domain)
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
            if let expected = publication?.deletionLedgerID,
               !manifest.groups.contains(where: { $0.entry.id == expected && $0.binding?.publicationSHA256 == witness }) {
                throw SyncDeletionLedgerError.witnessMismatch
            }
            var keep: [Group] = []
            var changed = false
            for var group in manifest.groups {
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
            .filter { $0.deletedAt.value == nil }.map { ($0.id.uuid, $0.payload.attachment!) })
    }

    private func validateRemovalVersions(_ versions: [SyncRecordVersion], domain: SyncDeletedDomain) throws {
        let owned = Dictionary(uniqueKeysWithValues: domain.ownedRecords.filter {
            $0.deletedAt.value == nil
        }.map { ($0.id, $0) })
        let expected = Set(owned.keys)
            .union(domain.removedReminders.keys.map { .init(kind: .projectCounter, uuid: $0) })
            .union(domain.removedLegacyPatterns.keys.map { .init(kind: .project, uuid: $0) })
        guard Set(versions.map { $0.record.id }) == expected, versions.count == expected.count else {
            throw SyncDeletionLedgerError.witnessMismatch
        }
        for version in versions {
            let record = try version.validated().record
            if let original = owned[record.id] {
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
            } else { throw SyncDeletionLedgerError.witnessMismatch }
        }
    }

    private func validate(_ domain: SyncDeletedDomain) throws {
        _ = try SyncRecordValidator().validate(domain.ownedRecords)
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

    private func load() throws -> Manifest {
        let data = try read(manifestURL)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard Self.hash(envelope.payload) == envelope.sha256 else { throw SyncDeletionLedgerError.corrupt }
        let manifest = try JSONDecoder().decode(Manifest.self, from: envelope.payload)
        guard manifest.version == 1,
              Set(manifest.groups.map { $0.entry.id }).count == manifest.groups.count else {
            throw SyncDeletionLedgerError.corrupt
        }
        for group in manifest.groups {
            try validate(group.entry.domain)
            guard group.entry.deletedAt.timeIntervalSinceReferenceDate.isFinite,
                  !group.active || (group.binding != nil && group.canceled != true),
                  group.canceled != true || group.binding != nil else { throw SyncDeletionLedgerError.corrupt }
            if let binding = group.binding {
                guard binding.beforeArchiveSHA256.count == 32,
                      binding.afterArchiveSHA256.count == 32,
                      binding.publicationSHA256.count == 32,
                      (binding.beforeArchiveSHA256 != binding.afterArchiveSHA256 || binding.commitBoundary == .artifacts) else {
                    throw SyncDeletionLedgerError.corrupt
                }
                try validateRemovalVersions(group.entry.exactRemovalVersions, domain: group.entry.domain)
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
                _ = try read(file,
                    expected: .init(byteCount: proof.byteCount, sha256: proof.sha256))
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
