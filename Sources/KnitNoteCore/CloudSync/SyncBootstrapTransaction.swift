import CryptoKit
import Darwin
import Foundation

public enum SyncBootstrapError: Error, Equatable {
    case contextChanged, incompleteFetch, sourceChanged, unsafePath, corrupt, invalidPhase, alreadyCommitted
}

/// The caller owns the store/engine freeze. Its validator must reject a released
/// freeze or changed account epoch, including during recovery before reopening.
public struct SyncBootstrapContext: Codable, Equatable, Sendable {
    public let accountIDHash: String
    public let epoch: UUID
    public let freezeID: UUID
    public init(accountIDHash: String, epoch: UUID, freezeID: UUID) {
        self.accountIDHash = accountIDHash; self.epoch = epoch; self.freezeID = freezeID
    }
}

public struct SyncBootstrapRemoteSnapshot: Sendable {
    public let context: SyncBootstrapContext
    public let records: [SyncRecord]
    public let attachments: [UUID: SyncAttachmentSource]
    public let isComplete: Bool
    public init(context: SyncBootstrapContext, records: [SyncRecord], attachments: [UUID: SyncAttachmentSource], isComplete: Bool) {
        self.context = context; self.records = records; self.attachments = attachments; self.isComplete = isComplete
    }
}

public struct SyncBootstrapReceipt: Codable, Equatable, Sendable {
    public let transactionID: UUID
    public let accountIDHash: String
    public let sourceArchiveFingerprint: Data
}

/// Capture pending() and then sourceFingerprint() while the same caller-owned
/// freeze is held. A cloned journal cannot reinterpret its absolute source URLs.
public struct SyncBootstrapPendingSnapshot: Sendable {
    public let mutations: [SyncMutation]
    public let sourceTreeFingerprint: Data
    public init(mutations: [SyncMutation], sourceTreeFingerprint: Data) {
        self.mutations = mutations; self.sourceTreeFingerprint = sourceTreeFingerprint
    }
}

/// Durable exact state, consumed through JSONProjectStore.hydrateSyncBootstrap.
/// Daily publication must advance a canonical checkpoint before app lifecycle
/// integration enables edits; this initial checkpoint is archive-bound.
public struct SyncBootstrapCheckpoint: Codable, Sendable {
    public let archiveSHA256: Data
    public let records: [SyncRecord]
    public let counterStates: [UUID: SyncCounterReminderState]
    /// Transport cleanup authority, not a request to delete the canonical
    /// reminder from its counter aggregate during a later merge.
    public let legacyRecordIDsToDelete: Set<SyncEntityID>
}

public struct SyncBootstrapPreparation: Sendable {
    public let transactionID: UUID
    public let originalBackupRoot: URL
    /// Task 5 must seal/remove these account-owned plaintext roots on signout.
    /// Retained uploads require exact durable ack authority before reclamation.
    public let accountOwnedRoots: [URL]
}

enum SyncBootstrapBoundary: CaseIterable {
    case afterPrepared, afterLiveMove, afterStagedMove, afterInstalled
    case afterJournal, afterReceipt, afterRollbackIntent, afterFailedMove, afterOriginalRestore
}

/// Core-only bootstrap. No CloudKit/network, account service, UI, or automatic
/// publication. All operations run while the caller's freeze remains held.
public final class SyncBootstrapTransaction {
    private enum Phase: String, Codable { case prepared, installed, committed, rollingBack, rolledBack }
    private struct FileProof: Codable, Equatable { let bytes: Int64; let digest: Data }
    private struct Manifest: Codable {
        let version: Int
        let id: UUID
        let context: SyncBootstrapContext
        let livePath: String
        let journalPath: String
        let sourceArchiveFingerprint: Data
        let original: [String: FileProof]
        let installed: [String: FileProof]
        let mutations: [SyncMutation]
        var phase: Phase
    }
    private struct Envelope: Codable { let payload: Data; let digest: Data }
    private let live: URL
    private let work: URL
    private let context: SyncBootstrapContext
    private let journalPath: String
    private let validateContext: (SyncBootstrapContext) throws -> Void
    private let boundary: (SyncBootstrapBoundary) throws -> Void
    private let patternFolderNameContext: PatternFolderNameContext?
    private let fileManager = FileManager.default
    private let reader = SyncRegularFileReader()
    private let maximumFileBytes = 100_000_000
    private var activeURL: URL { work.appendingPathComponent("active.json") }

    /// Read-only terminal validation for frozen account recovery. This uses the
    /// existing manifest/receipt format, never runs installation or rollback.
    /// Every byte remains in the caller's complete plaintext inventory.
    static func validateTerminalRecovery(account: SyncAccountIdentity, accountRoot: URL,
                                         liveRoot: URL, journalURL: URL,
                                         entries: [SyncAccountRecoveryInventory.Entry]) throws {
        let prefix = ".KnitNote-SyncBootstrap/"
        let owned = entries.filter { $0.relativePath.hasPrefix(prefix) && !$0.isDirectory }
        guard !owned.isEmpty else { return }
        let live = liveRoot.standardizedFileURL
        let liveKey = hash(Data(live.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let namespace = prefix + account.accountIDHash + "/" + liveKey + "/"
        let activePath = namespace + "active.json"
        guard owned.contains(where: { $0.relativePath == activePath }) else { throw SyncBootstrapError.corrupt }
        func read(_ path: String) throws -> Data {
            guard let proof = entries.first(where: { $0.relativePath == path && !$0.isDirectory }),
                  proof.byteCount >= 0, proof.byteCount <= 100_000_000 else { throw SyncBootstrapError.corrupt }
            let value = try SyncRegularFileReader().read(accountRoot.appendingPathComponent(path),
                maximumBytes: Int(proof.byteCount), expected: .init(byteCount: proof.byteCount, sha256: proof.sha256))
            guard value.device == proof.device, value.inode == proof.inode else { throw SyncBootstrapError.unsafePath }
            return value.data
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: read(activePath))
        guard hash(envelope.payload) == envelope.digest else { throw SyncBootstrapError.corrupt }
        let manifest = try JSONDecoder().decode(Manifest.self, from: envelope.payload)
        func posixPath(_ url: URL) -> String {
            let path = url.path
            return path.hasPrefix("/var/") || path.hasPrefix("/tmp/") ? "/private" + path : path
        }
        guard manifest.version == 1, manifest.context.accountIDHash == account.accountIDHash,
              manifest.livePath == live.path, safeRelativePath(manifest.journalPath),
              posixPath(live.appendingPathComponent(manifest.journalPath)) == posixPath(journalURL),
              manifest.original.keys.allSatisfy(safeRelativePath), manifest.installed.keys.allSatisfy(safeRelativePath),
              manifest.sourceArchiveFingerprint.count == 32,
              manifest.original["projects-v1.json"]?.digest == manifest.sourceArchiveFingerprint,
              manifest.phase == .committed || manifest.phase == .rolledBack else { throw SyncBootstrapError.invalidPhase }
        let transactionPrefix = namespace + manifest.id.uuidString + "/"
        guard owned.allSatisfy({ $0.relativePath == activePath || $0.relativePath.hasPrefix(transactionPrefix) }) else {
            throw SyncBootstrapError.corrupt
        }
        func proofs(under path: String) -> [String: FileProof] {
            var result: [String: FileProof] = [:]
            for entry in entries where entry.relativePath.hasPrefix(path) {
                let relative = String(entry.relativePath.dropFirst(path.count)) + (entry.isDirectory ? "/" : "")
                result[relative] = .init(bytes: entry.isDirectory ? -1 : entry.byteCount, digest: entry.sha256)
            }
            return result
        }
        guard proofs(under: transactionPrefix + "Original/") == manifest.original else { throw SyncBootstrapError.corrupt }
        if manifest.phase == .committed {
            let receipt = try JSONDecoder().decode(SyncBootstrapReceipt.self,
                from: read("working-set/SyncMetadata/bootstrap-receipt.json"))
            guard receipt.transactionID == manifest.id, receipt.accountIDHash == account.accountIDHash,
                  receipt.sourceArchiveFingerprint == manifest.sourceArchiveFingerprint else { throw SyncBootstrapError.corrupt }
        } else {
            guard proofs(under: "working-set/") == manifest.original else { throw SyncBootstrapError.sourceChanged }
        }
    }

    public convenience init(liveRoot: URL, context: SyncBootstrapContext, journalRelativePath: String,
        patternFolderNameContext: PatternFolderNameContext? = nil,
        validateContext: @escaping (SyncBootstrapContext) throws -> Void) throws {
        try self.init(liveRoot: liveRoot, context: context, journalRelativePath: journalRelativePath,
            patternFolderNameContext: patternFolderNameContext, validateContext: validateContext, boundary: { _ in })
    }

    init(liveRoot: URL, context: SyncBootstrapContext, journalRelativePath: String,
        patternFolderNameContext: PatternFolderNameContext? = nil,
        validateContext: @escaping (SyncBootstrapContext) throws -> Void,
        boundary: @escaping (SyncBootstrapBoundary) throws -> Void) throws {
        guard context.accountIDHash.count == 64,
              context.accountIDHash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              Self.safeRelativePath(journalRelativePath), liveRoot.isFileURL else { throw SyncBootstrapError.unsafePath }
        let parent = liveRoot.deletingLastPathComponent().standardizedFileURL
        live = parent.appendingPathComponent(liveRoot.lastPathComponent, isDirectory: true)
        let liveKey = Self.hash(Data(live.path.utf8)).map { String(format: "%02x", $0) }.joined()
        work = parent.appendingPathComponent(".KnitNote-SyncBootstrap", isDirectory: true)
            .appendingPathComponent(context.accountIDHash, isDirectory: true).appendingPathComponent(liveKey, isDirectory: true)
        self.context = context; journalPath = journalRelativePath
        self.validateContext = validateContext; self.boundary = boundary
        self.patternFolderNameContext = patternFolderNameContext
        try validateContext(context)
        if exists(live) { try checkDirectory(live) } else { try checkDirectory(parent) }
    }

    public func prepare(local: SyncExportPackage, sourceArchive: ProjectArchive,
        remote: SyncBootstrapRemoteSnapshot,
        pendingSnapshot: SyncBootstrapPendingSnapshot? = nil,
        counterReminderContext: SyncCounterReminderMergeContext = .init()) throws -> SyncBootstrapPreparation {
        try checkContext()
        guard remote.context == context else { throw SyncBootstrapError.contextChanged }
        guard remote.isComplete else { throw SyncBootstrapError.incompleteFetch }
        guard pendingSnapshot?.mutations.contains(where: { $0.recordID.kind == .knittingReminder }) != true else {
            // The journal has no semantic rebase receipt. Never counterfeit an
            // acknowledgement or retain a stale save that can republish the old
            // standalone authority beside its converted counter mutation.
            throw SyncPublicationError.pendingRepair
        }
        try createDirectory(work)
        if exists(activeURL) {
            let previous = try loadManifest()
            guard previous.phase == .rolledBack else {
                throw previous.phase == .committed ? SyncBootstrapError.alreadyCommitted : SyncBootstrapError.invalidPhase
            }
        }
        let sourceData = try read(live.appendingPathComponent("projects-v1.json"))
        guard !exists(SyncPublicationTransactionFile(archiveURL: live.appendingPathComponent("projects-v1.json")).url) else {
            throw SyncPublicationError.pendingRepair
        }
        guard try Self.sameArchive(JSONDecoder().decode(ProjectArchive.self, from: sourceData), sourceArchive) else { throw SyncBootstrapError.sourceChanged }
        let id = UUID()
        // Use one generated, bound directory identity in the persisted manifest.
        let transactionDirectory = transactionRoot(id)
        try createDirectory(transactionDirectory)
        let originalRoot = transactionDirectory.appendingPathComponent("Original")
        let stage = transactionDirectory.appendingPathComponent("Staged")
        let original = try inventory(live)
        let journalComponents = journalPath.split(separator: "/").map(String.init)
        let hiddenJournalPrefix = (journalComponents.dropLast() + ["." + journalComponents.last!]).joined(separator: "/")
        let journalExists = original.keys.contains {
            $0 == journalPath || $0.hasPrefix(journalPath + ".") || $0.hasPrefix(hiddenJournalPrefix)
        }
        let originalFingerprint = Self.hash(try Self.encode(original))
        guard original[journalPath + "/"] == nil,
              (!journalExists && pendingSnapshot == nil) || pendingSnapshot?.sourceTreeFingerprint == originalFingerprint else {
            throw SyncBootstrapError.sourceChanged
        }
        try copyTree(live, to: originalRoot, proofs: original)
        guard try inventory(live) == original else { throw SyncBootstrapError.sourceChanged }
        try copyTree(originalRoot, to: stage, proofs: original)
        // Public backup validation reuses archive/domain and media validators;
        // the full-tree copy above additionally preserves all sync/journal data.
        _ = try KnitNoteBackupService(liveRoot: originalRoot,
            workRoot: transactionDirectory.appendingPathComponent("ValidationOriginal"),
            patternFolderNameContext: patternFolderNameContext).createPackage(appVersion: "bootstrap")
        let sources = try stagedSources(local.attachments, remote.attachments, root: transactionDirectory)
        let localRoundtrip = try ProjectArchiveSyncMapper.materialize(records: local.records, attachments: sources, baseArchive: sourceArchive)
        guard Self.sameArchive(localRoundtrip.archive, sourceArchive, checkingVersion: false) else { throw SyncBootstrapError.sourceChanged }
        let pending = pendingSnapshot?.mutations ?? []
        let merged = try SyncMergeEngine().merge(local: local.records, remote: remote.records,
            pendingLocalMutations: pending, counterReminderContext: counterReminderContext)
        let result = try ProjectArchiveSyncMapper.materialize(records: merged.records, attachments: sources, baseArchive: sourceArchive)
        for file in result.files {
            try write(verifiedSource(file.source), to: stage.appendingPathComponent(file.relativePath))
        }
        let archiveData = try Self.encode(result.archive)
        try write(archiveData, to: stage.appendingPathComponent("projects-v1.json"))
        let checkpoint = SyncBootstrapCheckpoint(archiveSHA256: Self.hash(archiveData), records: result.records,
            counterStates: result.counterStates, legacyRecordIDsToDelete: merged.legacyRecordIDsToDelete)
        try write(Self.encode(checkpoint), to: stage.appendingPathComponent("SyncMetadata/bootstrap-canonical.json"))
        let attachmentRecords = result.records.filter { $0.id.kind == .attachment }
        let proofs = result.records.compactMap { record -> SyncProcessedWatchCommandProof? in
            guard case let .orphanWatchCommandProof(orphan)? = record.payload.atomicDomain?.value else { return nil }; return orphan.proof
        } + result.counterStates.values.flatMap(\.processedCommandProofs)
        let uniqueProofs = Dictionary(grouping: proofs, by: \.id)
        guard uniqueProofs.values.allSatisfy({ values in values.allSatisfy { $0 == values.first } }) else { throw SyncBootstrapError.corrupt }
        try SyncAttachmentPublicationEvidenceFile(url: stage.appendingPathComponent("SyncMetadata/attachment-versions.json")).save(.init(
            versions: attachmentRecords.compactMap(\.payload.attachment),
            deletedVersionIDs: Set(attachmentRecords.filter { $0.deletedAt.value != nil }.map(\.id.uuid)),
            watchCommandProofs: uniqueProofs.values.compactMap(\.first), attachmentRecords: attachmentRecords))
        _ = try KnitNoteBackupService(liveRoot: stage,
            workRoot: transactionDirectory.appendingPathComponent("ValidationMerged"),
            patternFolderNameContext: patternFolderNameContext).createPackage(appVersion: "bootstrap")
        var mutations = merged.mutationsToUpload
        for record in merged.records where merged.recordsToUpload.contains(record.id) {
            let version = try SyncRecordVersion(record: record)
            guard !mutations.contains(where: { $0.savedRecordVersion == version }) else { continue }
            let mutationID = deterministicSyncUUID(kind: record.id.kind,
                components: ["bootstrap-mutation-v1", context.accountIDHash, context.epoch.uuidString,
                    version.versionID.uuidString])
            let source = record.id.kind == .attachment && record.deletedAt.value == nil ? sources[record.id.uuid] : nil
            mutations.append(try .save(recordVersion: version,
                attachmentSource: try source.map { try .init(fileURL: $0.fileURL, contentSHA256: $0.contentSHA256, byteCount: $0.byteCount) },
                mutationID: mutationID))
        }
        for legacyID in merged.legacyRecordIDsToDelete.sorted(by: { $0.uuid.uuidString < $1.uuid.uuidString }) {
            mutations.append(.delete(legacyID, mutationID: deterministicSyncUUID(kind: legacyID.kind,
                components: ["bootstrap-legacy-cleanup-v1", context.accountIDHash, context.epoch.uuidString, legacyID.uuid.uuidString])))
        }
        let installed = try inventory(stage)
        guard try inventory(live) == original else { throw SyncBootstrapError.sourceChanged }
        try checkContext()
        let manifest = Manifest(version: 1, id: id, context: context, livePath: live.path, journalPath: journalPath,
            sourceArchiveFingerprint: Self.hash(sourceData), original: original, installed: installed, mutations: mutations, phase: .prepared)
        try persist(manifest)
        try boundary(.afterPrepared)
        return preparation(manifest)
    }

    public func install(_ prepared: SyncBootstrapPreparation) throws {
        var manifest = try boundManifest(prepared)
        guard manifest.phase == .prepared else { throw SyncBootstrapError.invalidPhase }
        let root = transactionRoot(manifest.id)
        guard try inventory(live) == manifest.original,
              try inventory(root.appendingPathComponent("Original")) == manifest.original,
              try inventory(root.appendingPathComponent("Staged")) == manifest.installed else { throw SyncBootstrapError.sourceChanged }
        try checkContext()
        do {
            try move(live, to: root.appendingPathComponent("Displaced"))
            try boundary(.afterLiveMove)
            try checkContext()
            try move(root.appendingPathComponent("Staged"), to: live)
            try boundary(.afterStagedMove)
            manifest.phase = .installed
            try persist(manifest)
            try boundary(.afterInstalled)
        } catch {
            try rollback(prepared)
            throw error
        }
    }

    public func commit(_ prepared: SyncBootstrapPreparation) throws -> SyncBootstrapReceipt {
        var manifest = try boundManifest(prepared)
        if manifest.phase == .committed { return try readReceipt(manifest) }
        guard manifest.phase == .installed, try inventory(live) == manifest.installed else { throw SyncBootstrapError.invalidPhase }
        do {
            try checkContext()
            try FileSyncMutationJournal(url: live.appendingPathComponent(journalPath)).enqueue(manifest.mutations)
            try boundary(.afterJournal)
            let receipt = SyncBootstrapReceipt(transactionID: manifest.id, accountIDHash: context.accountIDHash,
                sourceArchiveFingerprint: manifest.sourceArchiveFingerprint)
            try write(Self.encode(receipt), to: live.appendingPathComponent("SyncMetadata/bootstrap-receipt.json"))
            try boundary(.afterReceipt)
            try checkContext()
            manifest.phase = .committed
            try persist(manifest)
            return receipt
        } catch {
            try rollback(prepared)
            throw error
        }
    }

    public func rollback(_ prepared: SyncBootstrapPreparation) throws {
        var manifest = try boundManifest(prepared)
        guard manifest.phase != .committed else { throw SyncBootstrapError.alreadyCommitted }
        if manifest.phase == .rolledBack { return }
        let root = transactionRoot(manifest.id)
        guard try inventory(root.appendingPathComponent("Original")) == manifest.original else { throw SyncBootstrapError.corrupt }
        manifest.phase = .rollingBack
        try persist(manifest)
        try boundary(.afterRollbackIntent)
        let displaced = root.appendingPathComponent("Displaced")
        if exists(displaced) {
            guard try inventory(displaced) == manifest.original else { throw SyncBootstrapError.corrupt }
            if exists(live) {
                try move(live, to: root.appendingPathComponent("Failed"))
                try boundary(.afterFailedMove)
            }
            try checkContext()
            try move(displaced, to: live)
            try boundary(.afterOriginalRestore)
        }
        guard try inventory(live) == manifest.original else { throw SyncBootstrapError.sourceChanged }
        manifest.phase = .rolledBack
        try persist(manifest)
    }

    public func recoverInterruptedInstallation() throws -> SyncBootstrapReceipt? {
        try checkContext()
        guard exists(activeURL) else { return nil }
        let manifest = try loadManifest()
        if manifest.phase == .committed { return try readReceipt(manifest) }
        if manifest.phase != .rolledBack { try rollback(preparation(manifest)) }
        return nil
    }

    public func sourceFingerprint() throws -> Data {
        try checkContext()
        return Self.hash(try Self.encode(inventory(live)))
    }

    public func checkpoint(_ prepared: SyncBootstrapPreparation) throws -> SyncBootstrapCheckpoint {
        let manifest = try boundManifest(prepared)
        guard manifest.phase == .installed || manifest.phase == .committed else { throw SyncBootstrapError.invalidPhase }
        let checkpointData = try read(live.appendingPathComponent("SyncMetadata/bootstrap-canonical.json"))
        guard Self.hash(checkpointData) == manifest.installed["SyncMetadata/bootstrap-canonical.json"]?.digest else { throw SyncBootstrapError.corrupt }
        let checkpoint = try JSONDecoder().decode(SyncBootstrapCheckpoint.self, from: checkpointData)
        guard Self.hash(try read(live.appendingPathComponent("projects-v1.json"))) == checkpoint.archiveSHA256 else { throw SyncBootstrapError.sourceChanged }
        _ = try SyncRecordValidator().validate(checkpoint.records)
        return checkpoint
    }

    private func stagedSources(_ local: [UUID: SyncAttachmentSource], _ remote: [UUID: SyncAttachmentSource], root: URL) throws -> [UUID: SyncAttachmentSource] {
        var combined = local
        for (id, source) in remote {
            if let prior = combined[id], prior.contentSHA256 != source.contentSHA256 || prior.byteCount != source.byteCount { throw SyncBootstrapError.corrupt }
            combined[id] = source
        }
        var result: [UUID: SyncAttachmentSource] = [:]
        for (id, source) in combined {
            let destination = root.appendingPathComponent("Attachments/\(id.uuidString)")
            try write(verifiedSource(source), to: destination)
            result[id] = .init(fileURL: destination, contentSHA256: source.contentSHA256, byteCount: source.byteCount, isJournalStaged: true)
        }
        return result
    }

    private func verifiedSource(_ source: SyncAttachmentSource) throws -> Data {
        try checkDirectory(source.fileURL.deletingLastPathComponent().standardizedFileURL)
        return try reader.read(source.fileURL, maximumBytes: maximumFileBytes,
            expected: .init(byteCount: source.byteCount, sha256: source.contentSHA256)).data
    }
    private func preparation(_ manifest: Manifest) -> SyncBootstrapPreparation {
        .init(transactionID: manifest.id, originalBackupRoot: transactionRoot(manifest.id).appendingPathComponent("Original"), accountOwnedRoots: [work])
    }
    private func transactionRoot(_ id: UUID) -> URL { work.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func boundManifest(_ prepared: SyncBootstrapPreparation) throws -> Manifest {
        try checkContext()
        let manifest = try loadManifest()
        guard manifest.id == prepared.transactionID else { throw SyncBootstrapError.corrupt }
        return manifest
    }
    private func checkContext() throws { try validateContext(context) }
    private func persist(_ manifest: Manifest) throws {
        try checkContext()
        let data = try Self.encode(manifest)
        try write(Self.encode(Envelope(payload: data, digest: Self.hash(data))), to: activeURL)
    }
    private func loadManifest() throws -> Manifest {
        let envelope = try JSONDecoder().decode(Envelope.self, from: read(activeURL))
        guard Self.hash(envelope.payload) == envelope.digest else { throw SyncBootstrapError.corrupt }
        let manifest = try JSONDecoder().decode(Manifest.self, from: envelope.payload)
        guard manifest.version == 1, manifest.context == context, manifest.livePath == live.path,
              manifest.journalPath == journalPath,
              manifest.original.keys.allSatisfy(Self.safeRelativePath), manifest.installed.keys.allSatisfy(Self.safeRelativePath) else { throw SyncBootstrapError.corrupt }
        return manifest
    }
    private func readReceipt(_ manifest: Manifest) throws -> SyncBootstrapReceipt {
        let receipt = try JSONDecoder().decode(SyncBootstrapReceipt.self, from: read(live.appendingPathComponent("SyncMetadata/bootstrap-receipt.json")))
        guard receipt.transactionID == manifest.id, receipt.accountIDHash == context.accountIDHash,
              receipt.sourceArchiveFingerprint == manifest.sourceArchiveFingerprint else { throw SyncBootstrapError.corrupt }
        return receipt
    }

    private func inventory(_ root: URL) throws -> [String: FileProof] {
        try checkDirectory(root)
        var result: [String: FileProof] = [:]
        var total: Int64 = 0
        func walk(_ directory: URL, prefix: String) throws {
            try checkDirectory(directory)
            for entry in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let relative = prefix + entry.lastPathComponent
                guard Self.safeRelativePath(relative) else { throw SyncBootstrapError.unsafePath }
                var status = stat()
                guard lstat(entry.path, &status) == 0 else { throw SyncBootstrapError.corrupt }
                if (status.st_mode & S_IFMT) == S_IFDIR {
                    result[relative + "/"] = .init(bytes: -1, digest: Data())
                    try walk(entry, prefix: relative + "/")
                } else {
                    let value = try reader.read(entry, maximumBytes: maximumFileBytes)
                    total += value.byteCount
                    guard total <= 2_000_000_000, result.count < 100_000 else { throw SyncBootstrapError.corrupt }
                    result[relative] = .init(bytes: value.byteCount, digest: value.sha256)
                }
            }
        }
        try walk(root, prefix: "")
        return result
    }
    private func copyTree(_ source: URL, to destination: URL, proofs: [String: FileProof]) throws {
        try createDirectory(destination)
        for (relative, proof) in proofs.sorted(by: { $0.key < $1.key }) {
            if proof.bytes == -1 { try createDirectory(destination.appendingPathComponent(relative)); continue }
            try checkDirectory(source.appendingPathComponent(relative).deletingLastPathComponent())
            let data = try reader.read(source.appendingPathComponent(relative), maximumBytes: maximumFileBytes,
                expected: .init(byteCount: proof.bytes, sha256: proof.digest)).data
            try write(data, to: destination.appendingPathComponent(relative))
        }
        guard try inventory(destination) == proofs else { throw SyncBootstrapError.corrupt }
    }
    private func move(_ source: URL, to destination: URL) throws {
        try checkContext(); try checkDirectory(source); try checkDirectory(destination.deletingLastPathComponent())
        guard !exists(destination) else { throw SyncBootstrapError.corrupt }
        guard rename(source.path, destination.path) == 0 else { throw SyncBootstrapError.corrupt }
        try SyncDurableFile.synchronizeDirectory(source.deletingLastPathComponent())
        try SyncDurableFile.synchronizeDirectory(destination.deletingLastPathComponent())
    }
    private func exists(_ url: URL) -> Bool { var status = stat(); return lstat(url.path, &status) == 0 }
    private func read(_ url: URL) throws -> Data {
        try checkDirectory(url.deletingLastPathComponent())
        return try reader.read(url, maximumBytes: maximumFileBytes).data
    }
    private func write(_ data: Data, to url: URL) throws {
        try createDirectory(url.deletingLastPathComponent())
        if exists(url) { _ = try read(url) }
        try SyncDurableFile.write(data, to: url)
    }
    private func createDirectory(_ url: URL) throws {
        if exists(url) { try checkDirectory(url); return }
        try createDirectory(url.deletingLastPathComponent())
        guard mkdir(url.path, S_IRWXU) == 0 else { throw SyncBootstrapError.unsafePath }
        try SyncDurableFile.synchronizeDirectory(url.deletingLastPathComponent())
    }
    /// Cooperative app sandbox: reject unsafe existing ancestry and no-follow
    /// open each directory. This is not a hostile same-user syscall-swap model.
    private func checkDirectory(_ url: URL) throws {
        var path = url.standardizedFileURL.path
        // macOS system aliases; other symlink ancestors remain rejected.
        if path.hasPrefix("/var/") { path = "/private" + path }
        if path.hasPrefix("/tmp/") { path = "/private" + path }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SyncBootstrapError.unsafePath }
        defer { close(descriptor) }
        for component in path.split(separator: "/") {
            let next = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw SyncBootstrapError.unsafePath }
            close(descriptor); descriptor = next
        }
    }
    private static func safeRelativePath(_ path: String) -> Bool {
        let candidate = path.hasSuffix("/") ? String(path.dropLast()) : path
        return !candidate.isEmpty && candidate.utf8.count <= 1_024 && !candidate.hasPrefix("/")
            && candidate.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func hash(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    private static func sameArchive(_ lhs: ProjectArchive, _ rhs: ProjectArchive, checkingVersion: Bool = true) -> Bool {
        func equal<T: Identifiable & Equatable>(_ lhs: [T], _ rhs: [T]) -> Bool where T.ID == UUID {
            lhs.sorted { $0.id.uuidString < $1.id.uuidString } == rhs.sorted { $0.id.uuidString < $1.id.uuidString }
        }
        return (!checkingVersion || lhs.version == rhs.version) && equal(lhs.projects, rhs.projects) && equal(lhs.yarns, rhs.yarns)
            && equal(lhs.patternFolders, rhs.patternFolders) && equal(lhs.patternAssets, rhs.patternAssets)
            && equal(lhs.patterns, rhs.patterns) && equal(lhs.patternUsages, rhs.patternUsages)
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
}
