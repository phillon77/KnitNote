import Foundation
import CryptoKit
import Testing
@testable import KnitNoteCore

@MainActor
struct JSONProjectStoreConflictRecoveryTests {
    // Catches a combined rebase/recovery that loses one immutable save, Watch
    // proof, attachment history, or unrelated FIFO slot despite isolated tests.
    @Test func combinedThreeSavesSixWatchProofsAndMediaRecoverTwice() throws {
        let fault = ConflictRebaseRecoveryFixture.FaultState(.canonical(.afterJournal))
        let media = try ConflictAttachmentFixture(deleted: false, history: true,
            boundary: { try fault.reach(.canonical($0)) })
        let b = media.base; defer { b.remove() }
        try b.acknowledgeBootstrap()
        let live = b.root.appendingPathComponent("Live")
        let other = try #require(b.store.projects.first { $0.id != b.projectID })
        var commands: [WatchCounterCommand] = []
        for index in 1...3 {
            try b.renameLocally("Local \(index)")
            if index < 3 {
                try b.store.updateProject(id: other.id, name: "Other \(index)", toolType: nil,
                    toolSize: nil, toolNotes: nil, photoChange: .unchanged)
            }
            for _ in 0..<2 {
                let command = WatchCounterCommand(projectID: other.id, counterID: other.counters[0].id,
                    operation: .increment, createdAt: Date(timeIntervalSince1970: 1_900_000_000))
                commands.append(command)
                let result = try b.store.applyWatchCommandDurably(command,
                    ledgerURL: WatchSyncPaths.processedLedger(in: live),
                    preparedCommandURL: WatchSyncPaths.preparedCommand(in: live),
                    now: Date(timeIntervalSince1970: 1_900_000_001))
                #expect(result.rejection == nil)
            }
        }
        let receipt = try b.store.prepareRemoteBatch(b.batch(records: [], id: UUID()), attachmentSources: [:])
        guard case .committed = try b.store.commitRemoteBatch(receipt) else { Issue.record("Expected receipt"); return }
        let before = try b.journal.pendingVersioned()
        let id = SyncEntityID(kind: .project, uuid: b.projectID)
        let selected = before.filter { $0.mutation.recordID == id }
        #expect(selected.map { $0.mutation.savedRecordVersion?.record.payload.fields["name"]?.value }
            == [.string("Local 1"), .string("Local 2"), .string("Local 3")])
        let server = try b.renamedBatch("Server", id: UUID()).records[0]
        let input = try SyncConflictInput(accountIDHash: b.account.accountIDHash, failedAttemptID: UUID(),
            failedMutation: selected[0].mutation, failedVersion: selected[0].token, serverRecord: server,
            expectedRecordQueue: selected.map(\.mutation), expectedVersions: selected.map(\.token))
        let predecessor = try #require(try b.checkpoints.load())
        let evidenceFile = SyncAttachmentPublicationEvidenceFile(url: live.appendingPathComponent("SyncMetadata/attachment-versions.json"))
        let evidence = try evidenceFile.load()
        #expect(evidence.watchCommandProofs.count == 6)
        #expect(Set(evidence.watchCommandProofs.map(\.id)) == Set(commands.map(\.id)))
        #expect(evidence.allVersions.count >= 2)
        #expect(!predecessor.remoteBatchReceipts.isEmpty)
        let ledger = try Data(contentsOf: WatchSyncPaths.processedLedger(in: live))
        let expectedPending = try before.map { old -> SyncVersionedMutation in
            guard old.mutation.recordID == id else { return old }
            var record = server
            record.entityRevision = max(server.entityRevision, try #require(old.mutation.savedRecordVersion).record.entityRevision)
            return try .init(mutation: .save(recordVersion: .init(record: record),
                attachmentSource: old.mutation.attachmentSource, mutationID: old.mutation.mutationID), journalRevision: 1)
        }
        var expectedRecord = server
        expectedRecord.entityRevision = max(server.entityRevision, try #require(predecessor.records.first { $0.id == id }).entityRevision)
        var expectedArchive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: b.archiveURL))
        expectedArchive.projects[expectedArchive.projects.firstIndex { $0.id == b.projectID }!].name = "Server"
        expectedArchive.projects.sort { $0.id.uuidString < $1.id.uuidString }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let preparation = try b.store.prepareConflictRebase(input, attachmentSources: [:])
        let transaction = try #require(preparation.transaction)
        let source = try #require(transaction.conflictSource)
        #expect(try encoder.encode(JSONDecoder().decode(ProjectArchive.self, from: source.plan.archive)) == encoder.encode(expectedArchive))
        let checkpoint = try SyncCanonicalCheckpoint(accountIDHash: predecessor.accountIDHash,
            commitID: source.transition.transactionID, archiveSHA256: Data(SHA256.hash(data: source.plan.archive)),
            records: predecessor.records.map { $0.id == id ? expectedRecord : $0 },
            legacyRecordIDsToDelete: predecessor.legacyRecordIDsToDelete, remoteBatchReceipts: predecessor.remoteBatchReceipts)
        #expect(transaction.canonicalTransition?.candidate == checkpoint)
        #expect(source.afterPending == expectedPending.map(\.mutation))
        #expect(source.afterVersions == expectedPending.map(\.token))
        let originalTree = try ConflictRecoveryTree(b.root)
        let initial = ConflictRebaseRecoveryFixture.Handles(store: b.store, journal: b.journal, checkpoints: b.checkpoints)
        fault.armed = true
        #expect(throws: SyncPublicationError.pendingRepair) { try b.store.commitConflictRebase(preparation) }
        #expect(fault.hits == 1)
        #expect(try SyncPublicationTransactionFile(archiveURL: b.archiveURL).load() == transaction)
        #expect(try b.journal.pendingVersioned() == expectedPending)
        #expect(try b.checkpoints.load() == predecessor)
        let interruptedTree = try ConflictRecoveryTree(b.root)
        b.dropInitialHandles(); initial.dropAndAssertReleased()
        var recoveredTree: ConflictRecoveryTree?
        for _ in 0..<2 {
            let handles = try ConflictRebaseRecoveryFixture.makeHandles(b)
            defer { handles.dropAndAssertReleased() }
            try handles.store!.activateSyncCanonicalState(checkpointStore: handles.checkpoints!, bootstrap: nil, attachmentSources: [:])
            #expect(try handles.checkpoints!.load() == checkpoint)
            #expect(try handles.journal!.pendingVersioned() == expectedPending)
            #expect(try handles.journal!.withExclusivePending { try $0.retainedRebases(for: input) } == [source.transition])
            #expect(try handles.journal!.withExclusivePending { try $0.rebaseHistoryHeadSHA256() } == source.transition.integrity)
            #expect(try evidenceFile.load() == evidence)
            #expect(try Data(contentsOf: WatchSyncPaths.processedLedger(in: live)) == ledger)
            #expect(try Data(contentsOf: b.archiveURL) == source.plan.archive)
            #expect(handles.store!.project(id: other.id)?.counters[0].value == other.counters[0].value + 6)
            #expect(try SyncPublicationTransactionFile(archiveURL: b.archiveURL).load() == nil)
            let tree = try ConflictRecoveryTree(b.root)
            var paths = Set(interruptedTree.entries.keys)
            paths.remove(String(b.publicationIntentURL.path.dropFirst(b.root.path.count + 1)))
            #expect(Set(tree.entries.keys) == paths)
            for (path, entry) in originalTree.entries {
                let mutable = ["Live/projects-v1.json", "Live/SyncMetadata/canonical.json",
                    "Live/SyncMetadata/attachment-versions.json", "Live/SyncMetadata/pending.json.checkpoint",
                    "Live/SyncMetadata/pending.json.segment"].contains(path)
                if !mutable { #expect(tree.entries[path] == entry, "Retained file: \(path)") }
            }
            if let recoveredTree { #expect(tree == recoveredTree) }
            recoveredTree = tree
        }
    }

    // Catches replay that regenerates a candidate, loses FIFO/proofs, or keeps
    // any initial/reopened authority handle alive between recovery attempts.
    @Test(arguments: SyncCanonicalPublicationBoundary.allCases)
    func conflictRecoveryRetainsExactCandidateTwice(boundary: SyncCanonicalPublicationBoundary) throws {
        let f = try ConflictRebaseRecoveryFixture(boundary: boundary)
        defer { f.remove() }
        try f.commitExpectingInjectedBoundary()
        try f.dropInitialHandlesAndAssertReleased()
        try f.reopenAndAssertOriginalCandidate()
        try f.reopenAndAssertOriginalCandidate()
    }

    @Test(arguments: SyncDurableFileWriteBoundary.allCases)
    func rawOnlyMediaFaultRetainsOriginalBytesTwice(boundary: SyncDurableFileWriteBoundary) throws {
        let f = try ConflictRebaseRecoveryFixture(fault: .media(boundary), mode: .rawOnly)
        defer { f.remove() }
        try f.commitExpectingInjectedBoundary()
        try f.dropInitialHandlesAndAssertReleased()
        try f.reopenAndAssertOriginalCandidate()
        try f.reopenAndAssertOriginalCandidate()
    }

    @Test(arguments: ConflictRecoveryFault.nativeCases)
    func nativeJournalFaultRetainsOriginalCandidateTwice(fault: ConflictRecoveryFault) throws {
        let f = try ConflictRebaseRecoveryFixture(fault: fault)
        defer { f.remove() }
        try f.commitExpectingInjectedBoundary()
        try f.dropInitialHandlesAndAssertReleased()
        try f.reopenAndAssertOriginalCandidate()
        try f.reopenAndAssertOriginalCandidate()
    }

    @Test(arguments: [false, true])
    func overlayOnlyHistoryPreservesExactArchiveMediaAndProofs(interrupt: Bool) throws {
        let f = try ConflictRebaseRecoveryFixture(fault: interrupt ? .canonical(.afterIntent) : .none,
            mode: .overlay)
        defer { f.remove() }
        if interrupt { try f.commitExpectingInjectedBoundary() }
        else { try f.commitSuccessfully() }
        try f.dropInitialHandlesAndAssertReleased()
        try f.reopenAndAssertOriginalCandidate()
        try f.reopenAndAssertOriginalCandidate()
    }

    enum Refusal: CaseIterable {
        case missingJournal, partialFrame, partialTemporary, unrelatedAppend
        case copiedRoot, archiveSymlink, mediaSymlink, missingProofShard, accountMismatch
    }

    // Catches recovery that treats absent/foreign authority as ACK or rewrites
    // refused evidence. The snapshot includes every displaced original root.
    @Test(arguments: Refusal.allCases)
    func invalidAuthorityIsPreservedAcrossTwoFreshRefusals(refusal: Refusal) throws {
        let f = try ConflictRebaseRecoveryFixture(fault: .canonical(
            refusal == .partialFrame || refusal == .missingProofShard ? .afterJournal : .afterIntent),
            mode: refusal == .mediaSymlink ? .rawOnly : .rename)
        defer { f.remove() }
        try f.commitExpectingInjectedBoundary()
        if refusal == .missingProofShard { try ConflictRebaseRecoveryFixture.compact(f.initial!.journal!) }
        if refusal == .unrelatedAppend {
            try f.initial!.journal!.enqueue(.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID()))
        }
        try f.dropInitialHandlesAndAssertReleased()
        let fm = FileManager.default
        var account: SyncAccountIdentity?
        switch refusal {
        case .missingJournal:
            try displaceJournal(f)
        case .partialFrame:
            let segment = f.base.journalURL.appendingPathExtension("segment")
            let complete = try Data(contentsOf: segment)
            #expect(complete.count > 7)
            try complete.write(to: f.base.root.appendingPathComponent("complete-original-segment"))
            try complete.dropLast(7).write(to: segment)
        case .partialTemporary:
            try Data("{\"formatVersion\":".utf8).write(to: f.live.appendingPathComponent("SyncMetadata/.canonical-next.json"))
        case .unrelatedAppend: break
        case .copiedRoot:
            let displaced = f.base.root.appendingPathComponent("DisplacedLive")
            try fm.moveItem(at: f.live, to: displaced)
            try fm.copyItem(at: displaced, to: f.live)
            #expect(try f.base.journalAuthority(at: displaced) == f.base.journalAuthority())
        case .archiveSymlink:
            let displaced = f.base.root.appendingPathComponent("displaced-archive.json")
            try fm.moveItem(at: f.base.archiveURL, to: displaced)
            try fm.createSymbolicLink(at: f.base.archiveURL, withDestinationURL: displaced)
        case .mediaSymlink:
            let file = try #require(f.source.plan.files.first)
            let target = f.live.appendingPathComponent(file.relativePath)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let outside = f.base.root.appendingPathComponent("outside-media")
            try file.data.write(to: outside)
            try fm.createSymbolicLink(at: target, withDestinationURL: outside)
        case .missingProofShard:
            let shard = try #require(try fm.contentsOfDirectory(at: f.live.appendingPathComponent("SyncMetadata"),
                includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("pending.json.proofs.") })
            try fm.moveItem(at: shard, to: f.base.root.appendingPathComponent("displaced-proof-shard"))
        case .accountMismatch:
            account = try SyncAccountIdentity(containerIdentifier: "test.container", userRecordName: "other-user")
        }
        try f.assertRefusalTwice(account: account)
    }

    enum LaterAuthority: CaseIterable { case exactACK, compaction, localAppend, nativeRebase }

    @Test(arguments: LaterAuthority.allCases)
    func retainedHistoryDistinguishesLegalLaterAuthorityFromLoss(later: LaterAuthority) throws {
        let f = try ConflictRebaseRecoveryFixture(boundary: .afterJournal)
        defer { f.remove() }
        try f.commitExpectingInjectedBoundary()
        let expected = try applyLaterAuthority(f, later: later)
        try f.dropInitialHandlesAndAssertReleased()
        let retry = later == .compaction || later == .localAppend
        try f.reopenAndAssertOriginalCandidate(expectedLaterPending: expected, retry: retry)
        try f.reopenAndAssertOriginalCandidate(expectedLaterPending: expected, retry: retry)
    }

    private func applyLaterAuthority(_ f: ConflictRebaseRecoveryFixture,
        later: LaterAuthority) throws -> [SyncVersionedMutation] {
        let journal = f.initial!.journal!
        var expected = f.expectedPending
        switch later {
        case .exactACK:
            let first = try #require(expected.first { $0.mutation.recordID == f.input.serverRecord.id })
            #expect(try journal.acknowledgeCurrentVersion(first.token) == .acknowledged)
            expected.removeAll { $0.mutation.identity == first.mutation.identity }
        case .compaction:
            try ConflictRebaseRecoveryFixture.compact(journal)
        case .localAppend:
            let appended = SyncMutation.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID())
            try journal.enqueue(appended)
            expected.append(try .init(mutation: appended, journalRevision: 0))
        case .nativeRebase:
            let transition = try successorTransition(f, journal: journal)
            f.expectedLaterHistoryHead = transition.integrity
            #expect(try journal.withExclusivePending { try $0.rebase(transition) })
            expected = try expected.map {
                try .init(mutation: $0.mutation, journalRevision: $0.token.journalRevision
                    + ($0.mutation.recordID == f.input.serverRecord.id ? 1 : 0))
            }
        }
        #expect(try journal.pendingVersioned() == expected)
        f.interruptedTree = try ConflictRecoveryTree(f.base.root)
        return expected
    }

    @Test
    func oldJournalMissingRequiredPredecessorHistoryCannotAuthorizeNewIntent() throws {
        let f = try ConflictRebaseRecoveryFixture(boundary: .afterJournal)
        defer { f.remove() }
        try f.commitExpectingInjectedBoundary()
        try f.dropInitialHandlesAndAssertReleased()
        try f.reopenAndAssertOriginalCandidate()
        // First rebase is now committed. A new intent requires its non-genesis
        // native history head and revision-1 predecessor, not a rolled-back v4.
        let fault = ConflictRebaseRecoveryFixture.FaultState(.canonical(.afterIntent))
        let handles = try ConflictRebaseRecoveryFixture.makeHandles(f.base,
            boundary: { try fault.reach(.canonical($0)) })
        try handles.store!.activateSyncCanonicalState(checkpointStore: handles.checkpoints!, bootstrap: nil, attachmentSources: [:])
        let next = try successorTransition(f, journal: handles.journal!)
        let preparation = try handles.store!.prepareConflictRebase(next.input, attachmentSources: [:])
        let original = try #require(preparation.transaction)
        #expect(original.conflictSource!.transition.predecessorRebaseHeadSHA256 == f.source.transition.integrity)
        fault.armed = true
        #expect(throws: (any Error).self) { try handles.store!.commitConflictRebase(preparation) }
        #expect(fault.hits == 1)
        #expect(try SyncPublicationTransactionFile(archiveURL: f.base.archiveURL).load() == original)
        handles.dropAndAssertReleased()
        try displaceJournal(f)
        for (relative, entry) in f.originalJournal.entries.sorted(by: { $0.key < $1.key }) {
            let location = f.live.appendingPathComponent("SyncMetadata/" + relative)
            switch entry {
            case .directory: try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
            case let .regular(bytes): try bytes.write(to: location)
            case let .symbolicLink(target): try FileManager.default.createSymbolicLink(atPath: location.path, withDestinationPath: target)
            }
        }
        #expect(try f.base.journalAuthority() == f.originalJournal)
        try f.assertRefusalTwice()
    }

    private func displaceJournal(_ f: ConflictRebaseRecoveryFixture) throws {
        let destination = f.base.root.appendingPathComponent("DisplacedJournal")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for file in try FileManager.default.contentsOfDirectory(at: f.live.appendingPathComponent("SyncMetadata"), includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasPrefix("pending.json") || file.lastPathComponent == ".pending.json.attachments" {
            try FileManager.default.moveItem(at: file, to: destination.appendingPathComponent(file.lastPathComponent))
        }
    }

    private func successorTransition(_ f: ConflictRebaseRecoveryFixture,
        journal: FileSyncMutationJournal) throws -> SyncJournalRebaseTransition {
        let all = try journal.pendingVersioned()
        let selected = all.filter { $0.mutation.recordID == f.input.serverRecord.id }
        let first = try #require(selected.first)
        let input = try SyncConflictInput(accountIDHash: f.input.accountIDHash, failedAttemptID: UUID(),
            failedMutation: first.mutation, failedVersion: first.token, serverRecord: f.input.serverRecord,
            expectedRecordQueue: selected.map(\.mutation), expectedVersions: selected.map(\.token))
        return try .init(transactionID: UUID(), input: input,
            predecessorPendingSHA256: SyncConflictRebaseCoding.pendingDigest(all),
            predecessorRebaseHeadSHA256: journal.withExclusivePending { try $0.rebaseHistoryHeadSHA256() },
            recordPositions: all.indices.filter { all[$0].mutation.recordID == input.serverRecord.id },
            before: selected.map(\.mutation), after: selected.map(\.mutation), beforeVersions: selected.map(\.token),
            afterVersions: selected.map { try .init(mutation: $0.mutation, journalRevision: $0.token.journalRevision + 1) })
    }
}
