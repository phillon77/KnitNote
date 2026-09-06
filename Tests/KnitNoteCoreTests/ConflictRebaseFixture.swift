import Foundation
import CryptoKit
import Darwin
import Testing
@testable import KnitNoteCore

@MainActor
struct ConflictRebaseFixture {
    let base: RemoteBatchFixture

    init(interleave: Bool = false,
        boundary: @escaping (SyncCanonicalPublicationBoundary) throws -> Void = { _ in }) throws {
        base = try RemoteBatchFixture(boundary: boundary)
        try base.acknowledgeBootstrap()
        try base.renameLocally("Local 1")
        if interleave { try renameOther("Other 1") }
        try base.renameLocally("Local 2")
        if interleave { try renameOther("Other 2") }
        try base.renameLocally("Local 3")
    }

    private func renameOther(_ name: String) throws {
        let other = base.store.projects.first { $0.id != base.projectID }!
        try base.store.updateProject(id: other.id, name: name, toolType: nil,
            toolSize: nil, toolNotes: nil, photoChange: .unchanged)
    }

    func input(attemptID: UUID = UUID(), serverRecord suppliedRecord: SyncRecord? = nil) throws -> SyncConflictInput {
        let versioned = try base.journal.pendingVersioned()
            .filter { $0.mutation.recordID == .init(kind: .project, uuid: base.projectID) }
        guard let failed = versioned.first else {
            throw ConflictRebaseFixtureError.missingPendingMutation
        }
        let serverRecord = try suppliedRecord ?? base.renamedBatch("Server", id: UUID()).records[0]
        return try SyncConflictInput(
            accountIDHash: base.account.accountIDHash,
            failedAttemptID: attemptID,
            failedMutation: failed.mutation,
            failedVersion: failed.token,
            serverRecord: serverRecord,
            expectedRecordQueue: versioned.map(\.mutation),
            expectedVersions: versioned.map(\.token)
        )
    }

    func remove() {
        base.remove()
    }
}

private enum ConflictRebaseFixtureError: Error {
    case missingPendingMutation
}

@MainActor
struct ConflictAttachmentFixture {
    let base: RemoteBatchFixture
    let input: SyncConflictInput
    let source: SyncAttachmentSource
    let version: SyncAttachmentVersion

    init(deleted: Bool, relocatedAttempt: Bool = false, history: Bool = false,
        boundary: @escaping (SyncCanonicalPublicationBoundary) throws -> Void = { _ in },
        mediaBoundary: @escaping (SyncDurableFileWriteBoundary) throws -> Void = { _ in }) throws {
        base = try RemoteBatchFixture(boundary: boundary, remoteInstallBoundary: mediaBoundary)
        if history {
            try base.store.updateProject(id: base.projectID, name: "Earlier photo", toolType: nil,
                toolSize: nil, toolNotes: nil, photoChange: .replace(BackupFixture.jpegData(red: 0.8)))
        }
        try base.store.updateProject(id: base.projectID, name: "With photo", toolType: nil,
            toolSize: nil, toolNotes: nil, photoChange: .replace(BackupFixture.jpegData(red: 0.3)))
        let checkpoint = try base.checkpoints.load()!
        let photo = base.root.appendingPathComponent("Live/ProjectPhotos")
            .appendingPathComponent(base.store.project(id: base.projectID)!.photoFilename!)
        let photoBytes = try Data(contentsOf: photo)
        let digest = Data(SHA256.hash(data: photoBytes))
        let matching = checkpoint.records.filter {
            $0.id.kind == .attachment && $0.deletedAt.value == nil
                && $0.payload.attachment?.contentSHA256 == digest
                && $0.payload.attachment?.byteCount == Int64(photoBytes.count)
        }
        #expect(matching.count == 1)
        let original = try #require(matching.first)
        version = original.payload.attachment!
        let retained = base.root.appendingPathComponent("raw-photo.bin")
        try photoBytes.write(to: retained)
        source = try .init(fileURL: retained, contentSHA256: version.contentSHA256, byteCount: version.byteCount)
        try base.acknowledgeBootstrap()
        if deleted { try base.store.delete(id: base.projectID) }
        else {
            try base.journal.enqueue([.save(recordVersion: .init(record: original), attachmentSource: source, mutationID: UUID())])
        }
        let queue = try base.journal.pendingVersioned().filter { $0.mutation.recordID == original.id }
        let failed = queue[0]
        var server = original
        if !deleted {
            server.deletedAt = .init(value: nil, stamp: .init(logicalRevision: 10_000,
                modifiedAt: Date(timeIntervalSince1970: 2_200_000_000), deviceID: "remote-overlay"))
        }
        let attempted = relocatedAttempt ? try SyncMutation.save(recordVersion: failed.mutation.savedRecordVersion!,
            attachmentSource: source, mutationID: failed.mutation.mutationID) : failed.mutation
        input = try .init(accountIDHash: base.account.accountIDHash, failedAttemptID: UUID(),
            failedMutation: attempted, failedVersion: failed.token, serverRecord: server,
            expectedRecordQueue: queue.map(\.mutation), expectedVersions: queue.map(\.token))
    }
}

enum ConflictRecoveryFault: Equatable {
    case none
    case canonical(SyncCanonicalPublicationBoundary)
    case media(SyncDurableFileWriteBoundary)
    case nativeAppendBefore, nativeAppendSync, nativeCheckpointBefore, nativeCheckpointAfter

    static let nativeCases: [Self] = [.nativeAppendBefore, .nativeAppendSync, .nativeCheckpointBefore, .nativeCheckpointAfter]
}

enum ConflictRecoveryInjectedError: Error { case fault }

/// Captures bytes and identity without following links. A whole fixture root
/// includes displaced roots, outside targets, journal shards and staged files.
struct ConflictRecoveryTree: Equatable {
    struct Entry: Equatable {
        let device: Int32
        let inode: UInt64
        let kind: UInt16
        let bytes: Data?
        let link: String?
    }
    let entries: [String: Entry]

    init(_ root: URL) throws {
        var result: [String: Entry] = [:]
        func visit(_ url: URL, relative: String) throws {
            var status = stat()
            guard lstat(url.path, &status) == 0 else { throw CocoaError(.fileReadUnknown) }
            let kind = status.st_mode & S_IFMT
            result[relative] = Entry(device: status.st_dev, inode: status.st_ino, kind: kind,
                bytes: kind == S_IFREG ? try SyncDurableFile.readRegularFile(at: url) : nil,
                link: kind == S_IFLNK ? try FileManager.default.destinationOfSymbolicLink(atPath: url.path) : nil)
            if kind == S_IFDIR {
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try visit(child, relative: relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent)
                }
            }
        }
        try visit(root, relative: "")
        entries = result
    }
}

@MainActor
final class ConflictRebaseRecoveryFixture {
    enum Mode { case rename, rawOnly, overlay }
    final class FaultState: @unchecked Sendable {
        private let lock = NSLock()
        private var isArmed = false
        private var hitCount = 0
        var armed: Bool {
            get { lock.lock(); defer { lock.unlock() }; return isArmed }
            set { lock.lock(); defer { lock.unlock() }; isArmed = newValue }
        }
        var hits: Int { lock.lock(); defer { lock.unlock() }; return hitCount }
        let target: ConflictRecoveryFault
        init(_ target: ConflictRecoveryFault) { self.target = target }
        func reach(_ reached: ConflictRecoveryFault) throws {
            lock.lock(); defer { lock.unlock() }
            if isArmed && reached == target && hitCount == 0 {
                hitCount += 1
                throw ConflictRecoveryInjectedError.fault
            }
        }
    }
    final class Weak<Value: AnyObject> {
        weak var value: Value?
        init(_ value: Value) { self.value = value }
    }
    final class Handles {
        var store: JSONProjectStore?
        var journal: FileSyncMutationJournal?
        var checkpoints: SyncCanonicalCheckpointStore?
        init(store: JSONProjectStore, journal: FileSyncMutationJournal, checkpoints: SyncCanonicalCheckpointStore) {
            self.store = store; self.journal = journal; self.checkpoints = checkpoints
        }
        func dropAndAssertReleased() {
            let storeWitness = Weak(store!), journalWitness = Weak(journal!), checkpointWitness = Weak(checkpoints!)
            store = nil; journal = nil; checkpoints = nil
            #expect(storeWitness.value == nil)
            #expect(journalWitness.value == nil)
            #expect(checkpointWitness.value == nil)
        }
    }

    let base: RemoteBatchFixture
    let input: SyncConflictInput
    let attachmentSources: [UUID: SyncAttachmentSource]
    let preparation: SyncConflictPreparation
    let transaction: SyncPublicationTransaction
    let expectedCheckpoint: SyncCanonicalCheckpoint
    let expectedPending: [SyncVersionedMutation]
    let expectedEvidence: SyncAttachmentPublicationEvidence
    let originalTree: ConflictRecoveryTree
    let originalJournal: RemoteBatchFixture.JournalAuthority
    let predecessor: SyncCanonicalCheckpoint
    let predecessorPending: [SyncVersionedMutation]
    let expectedArchive: Data
    let initialGeneration: UInt64
    let mode: Mode
    let fault: FaultState
    var initial: Handles?
    var stableRecoveredTree: ConflictRecoveryTree?
    var interruptedTree: ConflictRecoveryTree?
    var expectedLaterHistoryHead: Data?
    var notifications: [UUID] = []

    var source: SyncConflictPublicationSource { transaction.conflictSource! }
    var live: URL { base.root.appendingPathComponent("Live") }
    var evidenceFile: SyncAttachmentPublicationEvidenceFile {
        .init(url: live.appendingPathComponent("SyncMetadata/attachment-versions.json"))
    }

    convenience init(boundary: SyncCanonicalPublicationBoundary) throws {
        try self.init(fault: .canonical(boundary))
    }

    init(fault selectedFault: ConflictRecoveryFault, mode: Mode = .rename) throws {
        let fault = FaultState(selectedFault)
        self.fault = fault; self.mode = mode
        let base: RemoteBatchFixture
        let input: SyncConflictInput
        let sources: [UUID: SyncAttachmentSource]
        if mode == .rename {
            let f = try ConflictRebaseFixture(interleave: true,
                boundary: { try fault.reach(.canonical($0)) })
            base = f.base; input = try f.input(); sources = [:]
        } else {
            let f = try ConflictAttachmentFixture(deleted: mode == .rawOnly, history: true,
                boundary: { try fault.reach(.canonical($0)) },
                mediaBoundary: { try fault.reach(.media($0)) })
            base = f.base; input = f.input; sources = [f.version.versionID: f.source]
        }
        self.base = base; self.input = input; attachmentSources = sources
        // Nonempty receipt and Watch authority must survive every recovery.
        let other = try #require(base.store.projects.first { $0.id != base.projectID })
        let command = WatchCounterCommand(id: UUID(), projectID: other.id, counterID: other.counters[0].id,
            operation: .increment, createdAt: Date(timeIntervalSince1970: 1_900_000_000))
        let watchResult = try base.store.applyWatchCommandDurably(command,
            ledgerURL: WatchSyncPaths.processedLedger(in: base.root.appendingPathComponent("Live")),
            preparedCommandURL: WatchSyncPaths.preparedCommand(in: base.root.appendingPathComponent("Live")),
            now: Date(timeIntervalSince1970: 1_900_000_001))
        #expect(watchResult.rejection == nil)
        let receiptPreparation = try base.store.prepareRemoteBatch(base.batch(records: [], id: UUID()), attachmentSources: [:])
        guard case .committed = try base.store.commitRemoteBatch(receiptPreparation) else {
            throw ConflictRecoveryInjectedError.fault
        }
        if selectedFault == .nativeCheckpointBefore || selectedFault == .nativeCheckpointAfter {
            try Self.compact(base.journal)
            let padding = (0..<127).map { _ in SyncMutation.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID()) }
            try base.journal.enqueue(padding)
            try base.journal.acknowledge(Set(padding.map(\.identity)))
            try base.journal.enqueue(.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID()))
        }
        // All constructors run on MainActor. Native faults use existing journal
        // writer injection through an independently constructed initial set.
        var handles = Handles(store: base.store, journal: base.journal, checkpoints: base.checkpoints)
        if ConflictRecoveryFault.nativeCases.contains(selectedFault) {
            base.dropInitialHandles()
            handles.dropAndAssertReleased()
            let journal: FileSyncMutationJournal
            if selectedFault == .nativeAppendBefore {
                journal = FileSyncMutationJournal(url: base.journalURL, appendFrames: { data, destination in
                    try fault.reach(.nativeAppendBefore)
                    let file = try FileHandle(forWritingTo: destination)
                    defer { try? file.close() }
                    try file.seekToEnd(); try file.write(contentsOf: data); try file.synchronize()
                    try SyncDurableFile.synchronizeDirectory(destination.deletingLastPathComponent())
                })
            } else if selectedFault == .nativeAppendSync {
                journal = FileSyncMutationJournal(url: base.journalURL, synchronizeFile: { descriptor in
                    try fault.reach(.nativeAppendSync)
                    guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
                }, synchronizeDirectory: { try SyncDurableFile.synchronizeDirectory($0) })
            } else {
                journal = FileSyncMutationJournal(url: base.journalURL, atomicWrite: { data, destination in
                    if destination.pathExtension == "checkpoint" { try fault.reach(.nativeCheckpointBefore) }
                    try SyncDurableFile.write(data, to: destination)
                    if destination.pathExtension == "checkpoint" { try fault.reach(.nativeCheckpointAfter) }
                })
            }
            handles = try Self.makeHandles(base, journal: journal)
            try handles.store!.activateSyncCanonicalState(checkpointStore: handles.checkpoints!, bootstrap: nil, attachmentSources: [:])
        }
        initial = handles
        initialGeneration = handles.store!.dataGeneration
        predecessor = try #require(try handles.checkpoints!.load())
        predecessorPending = try handles.journal!.pendingVersioned()
        let beforeEvidence = try SyncAttachmentPublicationEvidenceFile(
            url: base.root.appendingPathComponent("Live/SyncMetadata/attachment-versions.json")).load()
        preparation = try handles.store!.prepareConflictRebase(input, attachmentSources: sources)
        transaction = try #require(preparation.transaction)
        let candidate = try #require(transaction.canonicalTransition?.candidate)
        let source = try #require(transaction.conflictSource)
        // Hand-derived complete merge oracle: remote fields win rename/overlay;
        // raw-only live input cannot revive the newer local deletion.
        var expectedRecord: SyncRecord
        if mode == .rawOnly { expectedRecord = try #require(predecessor.records.first { $0.id == input.serverRecord.id }) }
        else {
            expectedRecord = input.serverRecord
            expectedRecord.entityRevision = max(expectedRecord.entityRevision,
                try #require(predecessor.records.first { $0.id == input.serverRecord.id }).entityRevision)
        }
        expectedPending = try predecessorPending.map { old in
            guard old.mutation.recordID == input.serverRecord.id else { return old }
            var queuedRecord = expectedRecord
            if mode == .rename {
                // Each queued immutable save keeps its own entity summary;
                // winning remote field stamps do not promote that summary.
                queuedRecord.entityRevision = max(input.serverRecord.entityRevision,
                    try #require(old.mutation.savedRecordVersion).record.entityRevision)
            }
            let replacement = try SyncMutation.save(recordVersion: .init(record: queuedRecord),
                attachmentSource: old.mutation.attachmentSource, mutationID: old.mutation.mutationID)
            return try .init(mutation: replacement, journalRevision: old.token.journalRevision + 1)
        }
        expectedArchive = source.plan.archive
        expectedCheckpoint = try .init(accountIDHash: predecessor.accountIDHash, commitID: source.transition.transactionID,
            archiveSHA256: Data(SHA256.hash(data: expectedArchive)),
            records: predecessor.records.map { $0.id == expectedRecord.id ? expectedRecord : $0 },
            legacyRecordIDsToDelete: predecessor.legacyRecordIDsToDelete, remoteBatchReceipts: predecessor.remoteBatchReceipts)
        var archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: base.archiveURL))
        if mode == .rename {
            archive.projects[archive.projects.firstIndex { $0.id == base.projectID }!].name = "Server"
            archive.projects.sort { $0.id.uuidString < $1.id.uuidString }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(JSONDecoder().decode(ProjectArchive.self, from: expectedArchive)) == encoder.encode(archive))
        expectedEvidence = try SyncAttachmentPublicationEvidence(versions: beforeEvidence.allVersions,
            deletedVersionIDs: beforeEvidence.deletedVersionIDSet, watchCommandProofs: beforeEvidence.watchCommandProofs,
            attachmentRecords: beforeEvidence.retainedAttachmentRecords.map { $0.id == expectedRecord.id ? expectedRecord : $0 }).validated()
        #expect(candidate == expectedCheckpoint)
        #expect(source.afterPending == expectedPending.map(\.mutation))
        #expect(source.afterVersions == expectedPending.map(\.token))
        #expect(!predecessor.remoteBatchReceipts.isEmpty)
        #expect(!beforeEvidence.watchCommandProofs.isEmpty)
        if mode != .rename { #expect(beforeEvidence.allVersions.count >= 2) }
        originalJournal = try base.journalAuthority()
        originalTree = try ConflictRecoveryTree(base.root)
        handles.store!.onRemoteDomainCommitted = { [weak self] id in self?.notifications.append(id) }
    }

    static func makeHandles(_ base: RemoteBatchFixture, journal supplied: FileSyncMutationJournal? = nil,
        account: SyncAccountIdentity? = nil,
        boundary: @escaping (SyncCanonicalPublicationBoundary) throws -> Void = { _ in }) throws -> Handles {
        let journal = supplied ?? base.freshJournal()
        let checkpoints = try SyncCanonicalCheckpointStore(liveRoot: base.root.appendingPathComponent("Live"),
            account: account ?? base.account, validateOwnership: {})
        let store = JSONProjectStore(url: base.archiveURL,
            backupService: KnitNoteBackupService(liveRoot: base.root.appendingPathComponent("Live"),
                workRoot: base.root.appendingPathComponent("BackupWork")),
            syncCanonicalPublicationBoundary: boundary, syncMutationSink: JournalSyncMutationSink(journal: journal))
        return Handles(store: store, journal: journal, checkpoints: checkpoints)
    }

    func commitExpectingInjectedBoundary() throws {
        fault.armed = true
        #expect(throws: (any Error).self) { try initial!.store!.commitConflictRebase(preparation) }
        #expect(fault.hits == 1)
        #expect(try SyncPublicationTransactionFile(archiveURL: base.archiveURL).load() == transaction)
        #expect(notifications.isEmpty)
        #expect(initial!.store!.dataGeneration == initialGeneration)
        let journalHasRebased: Bool
        switch fault.target {
        case .canonical(.afterIntent), .canonical(.afterArchive), .media, .nativeAppendBefore, .none:
            journalHasRebased = false
        default: journalHasRebased = true
        }
        #expect(try initial!.journal!.pendingVersioned() == (journalHasRebased ? expectedPending : predecessorPending))
        if !journalHasRebased { #expect(try base.journalAuthority() == originalJournal) }
        let installedCheckpoint = fault.target == .canonical(.afterCheckpoint) || fault.target == .canonical(.beforeIntentRemoval)
        #expect(try initial!.checkpoints!.load() == (installedCheckpoint ? expectedCheckpoint : predecessor))
        interruptedTree = try ConflictRecoveryTree(base.root)
    }

    func commitSuccessfully() throws {
        guard case let .committed(result) = try initial!.store!.commitConflictRebase(preparation) else {
            Issue.record("Expected conflict commit"); return
        }
        #expect(result.transactionID == source.transition.transactionID)
        #expect(fault.hits == 0)
        #expect(notifications.isEmpty) // Used for metadata-only overlay.
        #expect(initial!.store!.dataGeneration == initialGeneration)
    }

    func dropInitialHandlesAndAssertReleased() throws {
        base.dropInitialHandles()
        initial!.dropAndAssertReleased()
        initial = nil
    }

    func reopenAndAssertOriginalCandidate(expectedLaterPending: [SyncVersionedMutation]? = nil,
        retry: Bool = true) throws {
        #expect(initial == nil)
        let handles = try Self.makeHandles(base)
        defer { handles.dropAndAssertReleased() }
        var callbacks: [UUID] = []
        handles.store!.onRemoteDomainCommitted = { callbacks.append($0) }
        try handles.store!.activateSyncCanonicalState(checkpointStore: handles.checkpoints!, bootstrap: nil, attachmentSources: [:])
        let generation = handles.store!.dataGeneration
        #expect(try handles.checkpoints!.load() == expectedCheckpoint)
        #expect(try handles.journal!.pendingVersioned() == (expectedLaterPending ?? expectedPending))
        #expect(try handles.journal!.withExclusivePending { try $0.retainedRebases(for: input) } == [source.transition])
        #expect(try handles.journal!.withExclusivePending { try $0.rebaseHistoryHeadSHA256() }
            == (expectedLaterHistoryHead ?? source.transition.integrity))
        if let expectedLaterPending {
            for original in expectedPending where !expectedLaterPending.contains(where: { $0.mutation.identity == original.mutation.identity }) {
                #expect(try handles.journal!.acknowledgeCurrentVersion(original.token) == .alreadyAcknowledged)
            }
        }
        #expect(try evidenceFile.load() == expectedEvidence)
        #expect(try Data(contentsOf: base.archiveURL) == expectedArchive)
        for file in source.plan.files {
            #expect(try Data(contentsOf: live.appendingPathComponent(file.relativePath)) == file.data)
            if mode == .rawOnly {
                #expect(file.relativePath == "SyncMetadata/conflict-source-attachments/" + input.accountIDHash
                    + "/" + file.version.versionID.uuidString.lowercased())
                #expect(handles.store!.project(id: base.projectID) == nil)
            }
        }
        if retry {
            let replay = try handles.store!.prepareConflictRebase(input, attachmentSources: attachmentSources)
            #expect(replay.transaction == nil)
            guard case let .committed(result) = try handles.store!.commitConflictRebase(replay) else {
                Issue.record("Expected original retained resolution"); return
            }
            #expect(result.transactionID == source.transition.transactionID)
            #expect([result.replacement] + result.followingReplacements == source.transition.after)
            #expect(result.versions == source.transition.afterVersions)
        }
        #expect(callbacks.isEmpty)
        #expect(handles.store!.dataGeneration == generation)
        #expect(try SyncPublicationTransactionFile(archiveURL: base.archiveURL).load() == nil)
        let recovered = try ConflictRecoveryTree(base.root)
        var expectedPaths = Set(originalTree.entries.keys)
        if let interruptedTree { expectedPaths.formUnion(interruptedTree.entries.keys) }
        expectedPaths.remove(String(base.publicationIntentURL.path.dropFirst(base.root.path.count + 1)))
        for file in source.plan.files {
            var path = "Live/" + file.relativePath
            while !path.isEmpty {
                expectedPaths.insert(path)
                path = path.split(separator: "/").dropLast().joined(separator: "/")
            }
        }
        #expect(Set(recovered.entries.keys) == expectedPaths)
        if let interruptedTree {
            for file in source.plan.files {
                let path = "Live/" + file.relativePath
                if let installed = interruptedTree.entries[path], installed.bytes == file.data {
                    #expect(recovered.entries[path] == installed)
                }
            }
        }
        // Every preexisting media/source, immutable proof shard and unrelated
        // file must retain both bytes and inode. Mutable authorities are checked
        // as full decoded values above; the complete next reopen is byte-exact.
        for (path, entry) in originalTree.entries {
            let mutable = path == "Live/projects-v1.json" || path == "Live/SyncMetadata/canonical.json"
                || path == "Live/SyncMetadata/attachment-versions.json"
                || path == "Live/SyncMetadata/pending.json.checkpoint" || path == "Live/SyncMetadata/pending.json.segment"
            if !mutable { #expect(recovered.entries[path] == entry, "Retained file: \(path)") }
        }
        if mode != .rename {
            #expect(recovered.entries["Live/projects-v1.json"] == originalTree.entries["Live/projects-v1.json"])
        }
        if let stableRecoveredTree { #expect(recovered == stableRecoveredTree) }
        self.stableRecoveredTree = recovered
    }

    func assertRefusalTwice(account: SyncAccountIdentity? = nil) throws {
        let tree = try ConflictRecoveryTree(base.root)
        let journal = try base.journalAuthority()
        for _ in 0..<2 {
            let handles = try Self.makeHandles(base, account: account)
            #expect(throws: (any Error).self) {
                try handles.store!.activateSyncCanonicalState(checkpointStore: handles.checkpoints!, bootstrap: nil, attachmentSources: [:])
            }
            handles.dropAndAssertReleased()
            #expect(try ConflictRecoveryTree(base.root) == tree)
            #expect(try base.journalAuthority() == journal)
        }
    }

    static func compact(_ journal: FileSyncMutationJournal) throws {
        let padding = (0..<130).map { _ in SyncMutation.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID()) }
        try journal.enqueue(padding)
        try journal.acknowledge(Set(padding.map(\.identity)))
    }

    func remove() { base.remove() }
}
