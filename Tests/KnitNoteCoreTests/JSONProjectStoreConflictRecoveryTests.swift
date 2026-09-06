import Foundation
import Testing
@testable import KnitNoteCore

@MainActor
struct JSONProjectStoreConflictRecoveryTests {
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
