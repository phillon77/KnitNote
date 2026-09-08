import CryptoKit
import Darwin
import Foundation
import Testing
@testable import KnitNoteCore

@Suite(.serialized) struct SyncBootstrapOwnedJournalTests {
    @Test func prospectiveEnqueueReadsBoundExistingSourceAndRetainsFutureMetadata() throws {
        let f = try OwnedJournalFixture(); defer { f.remove() }
        let bytes = Data("real prospective copy".utf8)
        let source = f.root.appendingPathComponent("actual.asset")
        try bytes.write(to: source)
        let actual = try f.attachment(bytes, source: source)
        let version = actual.recordID.uuid
        let future = f.root.appendingPathComponent("future/Attachments/" + version.uuidString)
        let requested = try actual.replacingAttachmentSource(.init(fileURL: future,
            contentSHA256: actual.attachmentSource!.contentSHA256, byteCount: Int64(bytes.count)))
        let before = try f.files()
        let projection = try f.journal.planOwnedEnqueueProjection([requested], accountRoot: f.root,
            inventoryEntries: f.entries(), preflightSources: [version: actual.attachmentSource!], temporaryID: UUID.init)
        #expect(projection.pendingMutations?.count == 1)
        #expect(projection.pendingMutations?.first?.mutationID == requested.mutationID)
        #expect(projection.pendingMutations?.first?.attachmentSource?.isJournalStaged == true)
        #expect(!FileManager.default.fileExists(atPath: future.path))
        #expect(try f.files() == before)
        #expect(throws: (any Error).self) {
            _ = try f.journal.planOwnedEnqueueProjection([requested], accountRoot: f.root,
                inventoryEntries: f.entries(), preflightSources: [UUID(): actual.attachmentSource!], temporaryID: UUID.init)
        }
        let wrongProof = try SyncAttachmentSource(fileURL: source, contentSHA256: Data(repeating: 1, count: 32),
            byteCount: Int64(bytes.count))
        #expect(throws: SyncMutationJournalError.invalidAttachment) {
            _ = try f.journal.planOwnedEnqueueProjection([requested], accountRoot: f.root,
                inventoryEntries: f.entries(), preflightSources: [version: wrongProof], temporaryID: UUID.init)
        }
        let stagedRequest = try actual.replacingAttachmentSource(.init(fileURL: source,
            contentSHA256: actual.attachmentSource!.contentSHA256, byteCount: Int64(bytes.count), isJournalStaged: true))
        #expect(throws: SyncMutationJournalError.invalidAttachment) {
            _ = try f.journal.planOwnedEnqueueProjection([stagedRequest], accountRoot: f.root,
                inventoryEntries: f.entries(), preflightSources: [version: actual.attachmentSource!], temporaryID: UUID.init)
        }
        let empty = try f.journal.planOwnedEnqueueProjection([], accountRoot: f.root,
            inventoryEntries: f.entries(), preflightSources: [:], temporaryID: UUID.init)
        #expect(empty.pendingMutations == nil)
        #expect(empty.finalJournalFiles == empty.commitProgram.initialJournalFiles)
        #expect(try f.files() == before)
        try f.journal.enqueue(actual)
        #expect(try projection.pendingMutations == f.journal.pending())
        let reopened = FileSyncMutationJournal(url: f.url)
        #expect(try reopened.pending() == projection.pendingMutations)
        for (path, proof) in projection.finalJournalFiles {
            let bytes = try Data(contentsOf: f.root.appendingPathComponent("working-set/" + path))
            #expect(Int64(bytes.count) == proof.byteCount)
            #expect(Data(SHA256.hash(data: bytes)) == proof.sha256)
        }
    }

    @Test func stagedReuseRejectsUnicodeSpellingAliasBeforeReturningTrace() throws {
        let fixture = try OwnedJournalFixture()
        defer { fixture.remove() }
        let directory = fixture.url.deletingLastPathComponent().appendingPathComponent(".pending.json.attachments")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("legacy-é.bin")
        let bytes = Data("same physical source".utf8)
        try bytes.write(to: source)
        let inventory = try fixture.entries()
        let entry = try #require(inventory.first { !$0.isDirectory && $0.relativePath.hasSuffix(".bin") })
        let recordedName = String(entry.relativePath.split(separator: "/").last!)
        let composed = recordedName.precomposedStringWithCanonicalMapping
        let alias = recordedName.utf8.elementsEqual(composed.utf8)
            ? recordedName.decomposedStringWithCanonicalMapping : composed
        #expect(!recordedName.utf8.elementsEqual(alias.utf8))
        let aliasURL = try #require(URL(string: directory.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/" + alias.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!))
        let mutation = try fixture.attachment(bytes, source: source).replacingAttachmentSource(
            .init(fileURL: aliasURL, contentSHA256: Data(SHA256.hash(data: bytes)),
                  byteCount: Int64(bytes.count), isJournalStaged: true))
        #expect(!mutation.attachmentSource!.fileURL.lastPathComponent.utf8.elementsEqual(recordedName.utf8),
            Comment(rawValue: "recorded: \(Array(recordedName.utf8)); source: \(Array(mutation.attachmentSource!.fileURL.lastPathComponent.utf8))"))
        let before = try fixture.files()
        #expect(throws: SyncMutationJournalError.unsafeFile) {
            _ = try fixture.journal.planOwnedEnqueue([mutation], accountRoot: fixture.root,
                inventoryEntries: inventory, temporaryID: UUID.init)
        }
        #expect(try fixture.files() == before)
    }
    @Test func duplicatePreflightPrecedesIncomingPhysicalFailureAsInOrdinaryEnqueue() throws {
        let fixture = try OwnedJournalFixture()
        defer { fixture.remove() }
        let existing = fixture.mutation(1)
        try fixture.journal.enqueue(existing)
        let bytes = Data("expected bytes".utf8)
        let source = fixture.root.appendingPathComponent("missing.asset")
        let incoming = try fixture.attachment(bytes, source: source)
        let conflict = SyncMutation.delete(.init(kind: .project, uuid: UUID()), mutationID: existing.mutationID)
        let before = try fixture.files()
        #expect(throws: SyncMutationJournalError.duplicateMutationID) {
            _ = try fixture.journal.planOwnedEnqueue([incoming, conflict], accountRoot: fixture.root,
                inventoryEntries: fixture.entries(), temporaryID: UUID.init)
        }
        #expect(try fixture.files() == before)
        #expect(throws: SyncMutationJournalError.duplicateMutationID) { try fixture.journal.enqueue([incoming, conflict]) }
        #expect(try fixture.files() == before)
    }
    @Test func stagedReuseReadsBytesEvenWhenEarlierInventoryProofStillMatchesRequest() throws {
        let fixture = try OwnedJournalFixture()
        defer { fixture.remove() }
        let directory = fixture.url.deletingLastPathComponent().appendingPathComponent(".pending.json.attachments")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("retained.bin")
        let bytes = Data("correct bytes".utf8)
        try bytes.write(to: source)
        let mutation = try fixture.attachment(bytes, source: source).replacingAttachmentSource(
            .init(fileURL: source, contentSHA256: Data(SHA256.hash(data: bytes)), byteCount: Int64(bytes.count), isJournalStaged: true))
        let earlier = try fixture.entries()
        try Data("changed bytes".utf8).write(to: source)
        let before = try fixture.files()
        #expect(throws: SyncMutationJournalError.invalidAttachment) {
            _ = try fixture.journal.planOwnedEnqueue([mutation], accountRoot: fixture.root,
                inventoryEntries: earlier, temporaryID: UUID.init)
        }
        #expect(try fixture.files() == before)
        #expect(throws: SyncMutationJournalError.invalidAttachment) { try fixture.journal.enqueue(mutation) }
        #expect(try fixture.files() == before)
    }
    @Test func appendCrossesExactCompactionThresholdAndV1HistoryRollsShards() throws {
        let fixture = try OwnedJournalFixture()
        defer { fixture.remove() }
        try fixture.checkpoint(4)
        let initial = (0..<169).map { fixture.mutation($0) }
        try fixture.journal.enqueue(initial)
        try fixture.journal.acknowledge(Set(initial.prefix(86).map(\.identity)))
        let program = try fixture.journal.planOwnedEnqueue([fixture.mutation(200)], accountRoot: fixture.root,
            inventoryEntries: fixture.entries(), temporaryID: UUID.init)
        let append = try #require(program.operations.firstIndex { if case .appendSegment = $0 { true } else { false } })
        let shard = try #require(program.operations.firstIndex { if case .replace(let path, _, _, _) = $0 { path.hasSuffix("proofs.00000000") } else { false } })
        #expect(append < shard)
        try fixture.compare([fixture.mutation(200)])
        #expect(try Data(contentsOf: fixture.url.appendingPathExtension("segment")).isEmpty)
        try fixture.restore([:])
        let history = (0..<130).map { fixture.mutation($0) }
        try fixture.checkpoint(1, pending: history)
        try fixture.compare([history[0]])
        #expect(try fixture.decodedCheckpoint().proofShardCount == 2)
        #expect(try fixture.journal.pending() == history)
    }
    @Test func unselectedShardsAndAttachmentsRemainInExactInitialMap() throws {
        let fixture = try OwnedJournalFixture()
        defer { fixture.remove() }
        try fixture.checkpoint(4)
        let shard = fixture.url.appendingPathExtension("proofs.100000000")
        try Data("retained unselected shard".utf8).write(to: shard)
        let directory = fixture.url.deletingLastPathComponent().appendingPathComponent(".pending.json.attachments")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("unselected media".utf8).write(to: directory.appendingPathComponent("retained.bin"))
        let program = try fixture.journal.planOwnedEnqueue([fixture.mutation(1)], accountRoot: fixture.root,
            inventoryEntries: fixture.entries(), temporaryID: UUID.init)
        #expect(program.initialJournalFiles["SyncMetadata/pending.json.proofs.100000000"] != nil)
        #expect(program.initialJournalFiles["SyncMetadata/.pending.json.attachments/retained.bin"] != nil)
        try fixture.compare([fixture.mutation(1)])
    }
    @Test func incomingCopyChecksPhysicalBytesButExistingDestinationIsReused() throws {
        let fixture = try OwnedJournalFixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("source.asset")
        let bytes = Data("right source".utf8)
        try bytes.write(to: source)
        let mutation = try fixture.attachment(bytes, source: source)
        try Data("wrong source".utf8).write(to: source)
        let before = try fixture.files()
        #expect(throws: SyncMutationJournalError.invalidAttachment) {
            _ = try fixture.journal.planOwnedEnqueue([mutation], accountRoot: fixture.root,
                inventoryEntries: fixture.entries(), temporaryID: UUID.init)
        }
        #expect(try fixture.files() == before)
        let version = try #require(mutation.savedRecordVersion?.record.payload.attachment?.versionID)
        let directory = fixture.url.deletingLastPathComponent().appendingPathComponent(".pending.json.attachments")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let destination = directory.appendingPathComponent(mutation.mutationID.uuidString + "-" + version.uuidString + ".asset")
        try bytes.write(to: destination)
        let program = try fixture.journal.planOwnedEnqueue([mutation], accountRoot: fixture.root,
            inventoryEntries: fixture.entries(), temporaryID: UUID.init)
        #expect(program.operations.contains { if case .reuse = $0 { true } else { false } })
        #expect(!program.operations.contains { if case .copyAttachment = $0 { true } else { false } })
        try fixture.compare([mutation])
    }
    @Test func rootLevelRequiredSynchronizationFailsBeforeOutputs() throws {
        let fixture = try OwnedJournalFixture()
        defer { fixture.remove() }
        let journal = FileSyncMutationJournal(url: fixture.live.appendingPathComponent("pending.json"))
        let before = try fixture.files()
        #expect(throws: SyncMutationJournalError.unsafeFile) {
            _ = try journal.planOwnedEnqueue([fixture.mutation(1)], accountRoot: fixture.root,
                inventoryEntries: fixture.entries(), temporaryID: UUID.init)
        }
        #expect(try fixture.files() == before)
    }
    @Test(arguments: [1, 2, 3]) func legacyCheckpointWithV5ReceiptUsesProjectedMigratedShards(version: Int) throws {
        let fixture = try OwnedJournalFixture()
        defer { fixture.remove() }
        let original = fixture.mutation(100)
        try fixture.checkpoint(version, pending: [original])
        let token = try #require(fixture.journal.pendingVersioned().first?.token)
        #expect(try fixture.journal.acknowledgeCurrentVersion(token) == .acknowledged)
        #expect(try fixture.decodedCheckpoint().version == version)
        try fixture.compare([fixture.mutation(101)])
        #expect(try fixture.decodedCheckpoint().version == 5)
        #expect(try fixture.journal.acknowledgeCurrentVersion(token) == .alreadyAcknowledged)
    }
    @Test func v5RebaseProofsRemainEffectiveAcrossTraceAndCompaction() throws {
        let fixture = try OwnedJournalFixture()
        defer { fixture.remove() }
        let recordID = SyncEntityID(kind: .project, uuid: UUID())
        func saved(_ name: String, id: UUID) throws -> SyncMutation {
            let stamp = SyncMutationStamp(logicalRevision: 1, modifiedAt: Date(timeIntervalSince1970: 1), deviceID: "owned-test")
            let record = SyncRecord(schemaVersion: 1, id: recordID, createdAt: Date(timeIntervalSince1970: 0), entityRevision: 1,
                payload: .init(fields: ["name": .init(value: .string(name), stamp: stamp)]), relationships: [],
                deletedAt: .init(value: nil, stamp: stamp))
            return try .save(recordVersion: SyncRecordVersion(record: record), mutationID: id)
        }
        let original = try saved("before", id: UUID())
        let changed = try saved("after", id: original.mutationID)
        try fixture.journal.enqueue(original)
        let before = try fixture.journal.pendingVersioned()
        let server = try #require(changed.savedRecordVersion?.record)
        let input = try SyncConflictInput(accountIDHash: String(repeating: "a", count: 64), failedAttemptID: UUID(),
            failedMutation: original, failedVersion: before[0].token, serverRecord: server,
            expectedRecordQueue: [original], expectedVersions: before.map(\.token))
        let transition = try SyncJournalRebaseTransition(transactionID: UUID(), input: input,
            predecessorPendingSHA256: SyncConflictRebaseCoding.pendingDigest(before),
            predecessorRebaseHeadSHA256: fixture.journal.withExclusivePending { try $0.rebaseHistoryHeadSHA256() },
            recordPositions: [0], before: [original], after: [changed], beforeVersions: before.map(\.token),
            afterVersions: [SyncMutationVersionToken(mutation: changed, journalRevision: 1)])
        #expect(try fixture.journal.withExclusivePending { try $0.rebase(transition) })
        let fillers = (0..<130).map { fixture.mutation($0) }
        try fixture.journal.enqueue(fillers)
        try fixture.journal.acknowledge(Set(fillers.map(\.identity)))
        #expect(try fixture.decodedCheckpoint().version == 5)
        #expect(try fixture.decodedCheckpoint().rebaseHistory == [transition])
        let unchanged = try fixture.files()
        #expect(throws: SyncMutationJournalError.duplicateMutationID) {
            _ = try fixture.journal.planOwnedEnqueue([original], accountRoot: fixture.root,
                inventoryEntries: fixture.entries(), temporaryID: UUID.init)
        }
        #expect(try fixture.files() == unchanged)
        try fixture.compare([changed, fixture.mutation(500)])
        #expect(try fixture.journal.pendingVersioned().first?.token.journalRevision == 1)
        #expect(try fixture.journal.acknowledgeCurrentVersion(before[0].token) == .staleVersion)
        #expect(try fixture.journal.acknowledgeCurrentVersion(transition.afterVersions[0]) == .acknowledged)
    }
    @Test func existingNoncanonicalStagedSourceIsReadAndReused() throws {
        let fixture = try OwnedJournalFixture()
        defer { fixture.remove() }
        let directory = fixture.url.deletingLastPathComponent().appendingPathComponent(".pending.json.attachments")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("legacy-é.bin")
        let bytes = Data("legacy staged bytes".utf8)
        try bytes.write(to: source)
        let mutation = try fixture.attachment(bytes, source: source).replacingAttachmentSource(
            .init(fileURL: source, contentSHA256: Data(SHA256.hash(data: bytes)), byteCount: Int64(bytes.count), isJournalStaged: true))
        let program = try fixture.journal.planOwnedEnqueue([mutation], accountRoot: fixture.root,
            inventoryEntries: fixture.entries(), temporaryID: UUID.init)
        #expect(program.initialJournalFiles["SyncMetadata/.pending.json.attachments/legacy-é.bin"] != nil)
        #expect(program.operations.contains { if case .reuse(let path, _) = $0 { path.hasSuffix("legacy-é.bin") } else { false } })
        try fixture.compare([mutation])
    }
    @Test func absentMetadataParentIsAnInstalledPreconditionWithoutCreatingIt() throws {
        let fixture = try OwnedJournalFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent())
        let program = try fixture.journal.planOwnedEnqueue([fixture.mutation(0)], accountRoot: fixture.root,
            inventoryEntries: fixture.entries(), temporaryID: UUID.init)
        #expect(!FileManager.default.fileExists(atPath: fixture.url.deletingLastPathComponent().path))
        #expect(program.initialJournalDirectories == ["SyncMetadata"])
        #expect(program.initialJournalFiles.isEmpty)
        // The composer creates canonical metadata in Staged before commit.
        try FileManager.default.createDirectory(at: fixture.url.deletingLastPathComponent(), withIntermediateDirectories: false)
        try fixture.apply(program)
        #expect(try fixture.journal.pending() == [fixture.mutation(0)])
    }
    @Test func emptyRequestPreservesExistingInitialArtifactsWithoutMigrating() throws {
        let fixture = try OwnedJournalFixture()
        defer { fixture.remove() }
        try fixture.checkpoint(1)
        let before = try fixture.files()
        let program = try fixture.journal.planOwnedEnqueue([], accountRoot: fixture.root,
            inventoryEntries: fixture.entries(), temporaryID: UUID.init)
        #expect(program.initialJournalDirectories == ["SyncMetadata"])
        #expect(program.initialJournalFiles.count == 2)
        #expect(program.operations.isEmpty)
        #expect(try fixture.files() == before)
    }
    @Test func realAttachmentCopyAndPersistedReuseMatchOrdinaryJournal() throws {
        let fixture = try OwnedJournalFixture()
        defer { fixture.remove() }
        let bytes = Data("owned media bytes".utf8)
        let source = fixture.root.appendingPathComponent("source.asset")
        try bytes.write(to: source)
        let mutation = try fixture.attachment(bytes, source: source)
        let version = try #require(mutation.savedRecordVersion?.record.payload.attachment?.versionID)
        try fixture.compare([mutation], sources: [version: source])
        let staged = try #require(fixture.journal.pending().first?.attachmentSource)
        let reused = try SyncMutation.save(recordVersion: #require(mutation.savedRecordVersion),
            attachmentSource: staged, mutationID: UUID())
        try fixture.compare([reused])
        let bad = try SyncMutation.save(recordVersion: #require(mutation.savedRecordVersion),
            attachmentSource: staged, mutationID: UUID())
        try Data("wrong bytes".utf8).write(to: staged.fileURL)
        let inventory = try fixture.entries()
        let before = try fixture.files()
        #expect(throws: (any Error).self) {
            _ = try fixture.journal.planOwnedEnqueue([bad], accountRoot: fixture.root,
                inventoryEntries: inventory, temporaryID: UUID.init)
        }
        #expect(try fixture.files() == before)
    }
    @Test func unresolvedCleanupAdmissionRejectsWithoutTouchingSource() throws {
        let fixture = try OwnedJournalFixture()
        defer { fixture.remove() }
        let bytes = Data("cleanup source".utf8)
        let source = fixture.root.appendingPathComponent("source.asset")
        try bytes.write(to: source)
        let mutation = try fixture.attachment(bytes, source: source)
        try fixture.journal.enqueue(mutation)
        let failing = FileSyncMutationJournal(url: fixture.url, atomicWrite: { data, url in try data.write(to: url) },
            appendFrames: { data, url in
                let prior = try Data(contentsOf: url); try (prior + data).write(to: url)
            }, synchronizeFile: { _ in }, synchronizeDirectory: { _ in },
            removeStagedFile: { _ in throw OwnedJournalFailure.stop }, reader: .init(), counters: .init(),
            coordinatorRegistry: SyncJournalURLCoordinatorRegistry())
        #expect(throws: OwnedJournalFailure.stop) { try failing.acknowledge([mutation.identity]) }
        let before = try fixture.files()
        #expect(throws: SyncMutationJournalError.corrupt) { _ = try fixture.journal.recoverySnapshot() }
        #expect(throws: SyncMutationJournalError.corrupt) {
            _ = try fixture.journal.planOwnedEnqueue([fixture.mutation(0)], accountRoot: fixture.root,
                inventoryEntries: fixture.entries(), temporaryID: UUID.init)
        }
        #expect(try fixture.files() == before)
    }
    @Test(arguments: [1, 2, 3, 4, 5]) func checkpointVersionParity(version: Int) throws {
        let fixture = try OwnedJournalFixture()
        defer { fixture.remove() }
        try fixture.checkpoint(version)
        let requests = [fixture.mutation(12), fixture.mutation(13)]
        try fixture.compare(requests)
        let checkpoint = try fixture.decodedCheckpoint()
        #expect(checkpoint.version == (version == 5 ? 5 : 4))
        let before = try fixture.files()
        let duplicate = try fixture.journal.planOwnedEnqueue(requests, accountRoot: fixture.root,
            inventoryEntries: fixture.entries(), temporaryID: UUID.init)
        #expect(!duplicate.operations.contains { if case .appendSegment = $0 { true } else { false } })
        try fixture.apply(duplicate)
        #expect(try fixture.files() == before)
    }
    @Test func duplicateOnlyCompactsAndRollsProofShardsAtActualThreshold() throws {
        let fixture = try OwnedJournalFixture()
        defer { fixture.remove() }
        try fixture.checkpoint(4)
        let mutations = (0..<170).map { fixture.mutation($0) }
        try fixture.journal.enqueue(mutations)
        let failing = FileSyncMutationJournal(url: fixture.url, atomicWrite: { _, _ in throw OwnedJournalFailure.stop })
        #expect(throws: OwnedJournalFailure.stop) { try failing.acknowledge(Set(mutations.prefix(86).map(\.identity))) }
        let before = try fixture.files()
        let program = try fixture.journal.planOwnedEnqueue([mutations[100]], accountRoot: fixture.root,
            inventoryEntries: fixture.entries(), temporaryID: UUID.init)
        #expect(!program.operations.contains { if case .appendSegment = $0 { true } else { false } })
        #expect(program.operations.contains { if case .replace(let path, _, _, _) = $0 { path.hasSuffix("proofs.00000001") } else { false } })
        try fixture.apply(program)
        let planned = try fixture.files()
        #expect(try Data(contentsOf: fixture.url.appendingPathExtension("segment")).isEmpty)
        #expect(try fixture.journal.pending() == Array(mutations.dropFirst(86)))
        try fixture.restore(before)
        try fixture.journal.enqueue([mutations[100]])
        #expect(try fixture.files() == planned)
    }
    @Test(arguments: ["base", "partial"]) func recoveryAdmissionRejectsWithoutMutation(kind: String) throws {
        let fixture = try OwnedJournalFixture()
        defer { fixture.remove() }
        if kind == "base" { try Data("bad envelope".utf8).write(to: fixture.url) }
        else {
            try fixture.checkpoint(4)
            try Data([0, 0, 0]).write(to: fixture.url.appendingPathExtension("segment"))
        }
        let before = try fixture.files()
        #expect(throws: SyncMutationJournalError.corrupt) { _ = try fixture.journal.recoverySnapshot() }
        #expect(throws: SyncMutationJournalError.corrupt) {
            _ = try fixture.journal.planOwnedEnqueue([fixture.mutation(0)], accountRoot: fixture.root,
                inventoryEntries: fixture.entries(), temporaryID: UUID.init)
        }
        #expect(try fixture.files() == before)
    }
    @Test func appendTraceMatchesOrdinaryBytesAndReopensFIFO() throws {
        let fixture = try OwnedJournalFixture()
        defer { fixture.remove() }
        let requests = (0..<3).map { fixture.mutation($0) }
        let before = try fixture.files()
        let program = try fixture.journal.planOwnedEnqueue(requests, accountRoot: fixture.root,
            inventoryEntries: fixture.entries(), temporaryID: UUID.init)
        #expect(try fixture.files() == before)
        #expect(program.initialJournalDirectories == ["SyncMetadata"])
        #expect(program.operations.contains { if case .appendSegment = $0 { return true }; return false })
        try fixture.apply(program)
        let plannedBytes = try fixture.files()
        #expect(try fixture.journal.pending() == requests)
        try fixture.restore(before)
        try fixture.journal.enqueue(requests)
        #expect(try fixture.files() == plannedBytes)
        try fixture.journal.acknowledge([requests[0].identity])
        #expect(try fixture.journal.pending() == Array(requests.dropFirst()))
    }
    @Test func emptyEnqueueDoesNotCreateJournalArtifacts() throws {
        let fixture = try OwnedJournalFixture()
        defer { fixture.remove() }
        let before = try fixture.files()
        let program = try fixture.journal.planOwnedEnqueue([], accountRoot: fixture.root,
            inventoryEntries: fixture.entries(), temporaryID: UUID.init)
        #expect(program.journalRelativePath == "SyncMetadata/pending.json")
        #expect(program.operations.isEmpty)
        #expect(try fixture.files() == before)
    }
}

private struct OwnedJournalFixture {
    let root: URL
    var live: URL { root.appendingPathComponent("working-set") }
    var url: URL { live.appendingPathComponent("SyncMetadata/pending.json") }
    var journal: FileSyncMutationJournal { FileSyncMutationJournal(url: url) }
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("owned-journal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func checkpoint(_ version: Int, pending: [SyncMutation] = []) throws {
        struct Envelope: Encodable { let version = 1; let checkpoint: Data; let checksum: Data }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(SyncJournalCheckpoint(version: version, throughSequence: 0, pending: pending))
        try encoder.encode(Envelope(checkpoint: payload, checksum: Data(SHA256.hash(data: payload))))
            .write(to: url.appendingPathExtension("checkpoint"))
        try Data().write(to: url.appendingPathExtension("segment"))
    }
    func decodedCheckpoint() throws -> SyncJournalCheckpoint {
        struct Envelope: Decodable { let checkpoint: Data }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url.appendingPathExtension("checkpoint")))
        return try JSONDecoder().decode(SyncJournalCheckpoint.self, from: envelope.checkpoint)
    }
    func compare(_ requests: [SyncMutation], sources: [UUID: URL] = [:]) throws {
        let before = try files()
        let program = try journal.planOwnedEnqueue(requests, accountRoot: root,
            inventoryEntries: entries(), temporaryID: UUID.init)
        #expect(try files() == before)
        try apply(program, sources: sources)
        let expected = try files()
        let pending = try journal.pending()
        try restore(before)
        try journal.enqueue(requests)
        let actual = try files()
        for path in Set(actual.keys).union(expected.keys).sorted() {
            #expect(actual[path] == expected[path], Comment(rawValue: path))
        }
        #expect(try journal.pending() == pending)
    }
    func mutation(_ index: Int) -> SyncMutation {
        .delete(.init(kind: .project, uuid: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!),
                mutationID: UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", index))!)
    }
    func attachment(_ bytes: Data, source: URL) throws -> SyncMutation {
        let owner = SyncEntityID(kind: .project, uuid: UUID())
        let attachment = try SyncAttachmentVersion.issuing(slot: .init(owner: owner, role: "project-photo", slotID: "cover"),
            contentSHA256: Data(SHA256.hash(data: bytes)), byteCount: Int64(bytes.count),
            mediaType: "application/octet-stream", displayFilename: "source.asset")
        let stamp = SyncMutationStamp(logicalRevision: 1, modifiedAt: Date(timeIntervalSince1970: 1), deviceID: "owned-journal-test")
        let record = SyncRecord(schemaVersion: 1, id: .init(kind: .attachment, uuid: attachment.versionID),
            createdAt: Date(timeIntervalSince1970: 0), entityRevision: 1,
            payload: .init(fields: [:], attachment: attachment), relationships: [.init(role: "owner", target: owner)],
            deletedAt: .init(value: nil, stamp: stamp))
        return try .save(recordVersion: SyncRecordVersion(record: record),
            attachmentSource: .init(fileURL: source, contentSHA256: attachment.contentSHA256, byteCount: attachment.byteCount), mutationID: UUID())
    }
    func restore(_ files: [String: Data]) throws {
        try FileManager.default.removeItem(at: live)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for (path, bytes) in files {
            let target = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target)
        }
    }
    func apply(_ program: BootstrapManifestV3.CommitProgram, sources: [UUID: URL] = [:]) throws {
        let digest = Data(SHA256.hash(data: Data("archive fixture".utf8)))
        let original = ["projects-v1.json": BootstrapManifestV3.FileProof(bytes: 15, digest: digest)]
        var installed = original
        for path in program.initialJournalDirectories { installed[path + "/"] = .init(bytes: -1, digest: Data()) }
        for (path, proof) in program.initialJournalFiles { installed[path] = .init(bytes: proof.byteCount, digest: proof.sha256) }
        let manifest = BootstrapManifestV3(id: UUID(), context: .init(accountIDHash: String(repeating: "a", count: 64),
            epoch: UUID(), freezeID: UUID()), livePath: live.path, journalPath: program.journalRelativePath,
            sourceProof: .archive(sha256: digest), original: original, historyHead: nil,
            body: .prepared(.init(installed: installed, mutations: [], preparationSHA256: digest, commitProgram: program,
                originalLiveRoot: .init(device: 1, inode: 2), stagedRoot: .init(device: 1, inode: 3))))
        #expect(try BootstrapManifestV3.decodeEnvelope(manifest.encoded()).body.preparedBody?.commitProgram == program)
        for operation in program.operations {
            switch operation {
            case let .synchronize(path):
                #expect(FileManager.default.fileExists(atPath: live.appendingPathComponent(path).path))
            case let .directory(path):
                try FileManager.default.createDirectory(at: live.appendingPathComponent(path), withIntermediateDirectories: false)
            case let .reuse(path, proof):
                let bytes = try Data(contentsOf: live.appendingPathComponent(path))
                #expect(Int64(bytes.count) == proof.byteCount && Data(SHA256.hash(data: bytes)) == proof.sha256)
            case let .replace(path, old, bytes, id):
                let target = live.appendingPathComponent(path)
                try check(target, proof: old)
                let temporary = target.deletingLastPathComponent().appendingPathComponent("." + target.lastPathComponent + "." + id.uuidString + ".tmp")
                #expect(!FileManager.default.fileExists(atPath: temporary.path))
                try bytes.write(to: temporary)
                #expect(rename(temporary.path, target.path) == 0)
            case let .copyAttachment(path, version, proof, id):
                let source = try #require(sources[version])
                let bytes = try Data(contentsOf: source)
                #expect(Int64(bytes.count) == proof.byteCount && Data(SHA256.hash(data: bytes)) == proof.sha256)
                let target = live.appendingPathComponent(path)
                try check(target, proof: nil)
                let temporary = target.deletingLastPathComponent().appendingPathComponent("." + target.lastPathComponent + "." + id.uuidString + ".tmp")
                try bytes.write(to: temporary)
                #expect(rename(temporary.path, target.path) == 0)
            case let .appendSegment(expected, frames):
                let target = live.appendingPathComponent(program.journalRelativePath + ".segment")
                try check(target, proof: expected)
                let prior = expected == nil ? Data() : try Data(contentsOf: target)
                try (prior + frames).write(to: target)
            }
        }
    }
    func check(_ url: URL, proof: BootstrapManifestV3.OutputProof?) throws {
        if let proof {
            let bytes = try Data(contentsOf: url)
            #expect(Int64(bytes.count) == proof.byteCount && Data(SHA256.hash(data: bytes)) == proof.sha256)
        } else { #expect(!FileManager.default.fileExists(atPath: url.path)) }
    }
    func entries() throws -> [SyncAccountRecoveryInventory.Entry] {
        let urls = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.allObjects as! [URL]
        return try urls.map { rawURL in
            let url = rawURL.resolvingSymlinksInPath()
            var status = stat()
            guard lstat(url.path, &status) == 0 else { throw CocoaError(.fileReadUnknown) }
            let directory = (status.st_mode & S_IFMT) == S_IFDIR
            let bytes = directory ? Data() : try Data(contentsOf: url)
            return .init(relativePath: String(url.path.dropFirst(root.path.count + 1)), isDirectory: directory,
                byteCount: directory ? 0 : Int64(bytes.count), sha256: directory ? Data() : Data(SHA256.hash(data: bytes)),
                device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
        }.sorted { $0.relativePath < $1.relativePath }
    }
    func files() throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: entries().filter { !$0.isDirectory }.map {
            ($0.relativePath, try Data(contentsOf: root.appendingPathComponent($0.relativePath)))
        })
    }
}

private enum OwnedJournalFailure: Error { case stop }
