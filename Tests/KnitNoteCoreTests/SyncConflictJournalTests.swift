import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

@Suite(.serialized) struct SyncConflictJournalTests {
    @Test @MainActor func rebaseReplacesOnlySelectedGlobalSlotsInOneDurableFrame() throws {
        let f = try JournalConflictFixture(); defer { f.remove() }
        let before = try f.journal.pendingVersioned()
        let transition = try f.transition()
        let frames = f.counters.appendedFrameCount
        try f.journal.withExclusivePending { lease in
            #expect(try lease.pendingVersioned() == before)
            try lease.preflightRebase(transition)
            #expect(try lease.rebase(transition))
        }
        let actual = try f.reopen().pendingVersioned()
        #expect(actual.map(\.mutation) == [transition.after[0], before[1].mutation,
            transition.after[1], before[3].mutation, transition.after[2]])
        #expect(actual.map(\.token.journalRevision) == [1, 0, 1, 0, 1])
        #expect(f.counters.appendedFrameCount == frames + 1)
    }

    @Test @MainActor func sameIDsWithDifferentPredecessorLeaveCompleteAuthorityUntouched() throws {
        let f = try JournalConflictFixture(); defer { f.remove() }
        let stale = try f.transition()
        let current = try f.transition()
        #expect(try f.journal.withExclusivePending { try $0.rebase(current) })
        let bytes = try f.authority()
        #expect(try f.journal.withExclusivePending { try $0.rebase(stale) } == false)
        #expect(try f.authority() == bytes)
    }

    @Test @MainActor func oldAndForgedVersionACKsNeverRemoveCurrentOrWriteBytes() throws {
        let f = try JournalConflictFixture(); defer { f.remove() }
        let old = try f.journal.pendingVersioned()[0].token
        let transition = try f.transition()
        #expect(try f.journal.withExclusivePending { try $0.rebase(transition) })
        let bytes = try f.authority()
        #expect(try f.journal.acknowledgeCurrentVersion(old) == .staleVersion)
        #expect(throws: SyncConflictError.missingAuthority) { try f.journal.acknowledge([old.identity]) }
        #expect(try f.authority() == bytes)
        let current = try f.journal.pendingVersioned()[0]
        let forged = try SyncMutationVersionToken(mutation: current.mutation, journalRevision: 9)
        #expect(try f.journal.acknowledgeCurrentVersion(forged) == .staleVersion)
        #expect(try f.journal.acknowledgeCurrentVersion(current.token) == .acknowledged)
        #expect(try f.reopen().acknowledgeCurrentVersion(current.token) == .alreadyAcknowledged)
        #expect(try f.reopen().acknowledgeCurrentVersion(old) == .staleVersion)
    }

    @Test @MainActor func returningToIssuedContentStillRequiresLatestRevision() throws {
        let f = try JournalConflictFixture(); defer { f.remove() }
        let issued = try f.journal.pendingVersioned()
        let changed = try f.transition()
        #expect(try f.journal.withExclusivePending { try $0.rebase(changed) })
        let back = try f.transition(after: [issued[0].mutation, issued[2].mutation, issued[4].mutation])
        #expect(try f.journal.withExclusivePending { try $0.rebase(back) })
        #expect(try f.journal.acknowledgeCurrentVersion(issued[0].token) == .staleVersion)
        #expect(try f.journal.pendingVersioned().map(\.token.journalRevision) == [2, 0, 2, 0, 2])
        let bytes = try f.authority()
        try f.journal.enqueue(issued[0].mutation)
        #expect(try f.authority() == bytes)
    }

    @Test @MainActor func supersededEnqueueIsRejectedAndCurrentDuplicateIsNoOp() throws {
        let f = try JournalConflictFixture(); defer { f.remove() }
        let t = try f.transition()
        #expect(try f.journal.withExclusivePending { try $0.rebase(t) })
        let bytes = try f.authority()
        #expect(throws: SyncMutationJournalError.duplicateMutationID) { try f.journal.enqueue(t.before) }
        try f.journal.enqueue(t.after)
        #expect(try f.authority() == bytes)
    }

    @Test @MainActor func legacyIdentityACKDoesNotInventVersionedReceipt() throws {
        let f = try JournalConflictFixture(); defer { f.remove() }
        let token = try f.journal.pendingVersioned()[0].token
        try f.journal.acknowledge([token.identity])
        #expect(try f.reopen().acknowledgeCurrentVersion(token) == .staleVersion)
    }

    @Test @MainActor func transitionRejectsUnchangedSkippedAndMismatchedAfterTokens() throws {
        let f = try JournalConflictFixture(); defer { f.remove() }
        let t = try f.transition()
        for revision in [UInt64(0), UInt64(2)] {
            let tokens = try t.after.map { try SyncMutationVersionToken(mutation: $0, journalRevision: revision) }
            #expect(throws: SyncConflictError.invalidInput) { try f.transition(tokens: tokens) }
        }
        let wrong = try t.before.map { try SyncMutationVersionToken(mutation: $0, journalRevision: 1) }
        #expect(throws: SyncConflictError.invalidInput) { try f.transition(tokens: wrong) }
    }

    @Test @MainActor func compactionRetainsOrderedHistoryAndExactACKAcrossOrdinarySuccessors() throws {
        let f = try JournalConflictFixture(); defer { f.remove() }
        let first = try f.transition()
        #expect(try f.journal.withExclusivePending { try $0.rebase(first) })
        let second = try f.transition()
        #expect(try f.journal.withExclusivePending { try $0.rebase(second) })
        let token = try f.journal.pendingVersioned()[0].token
        #expect(try f.journal.acknowledgeCurrentVersion(token) == .acknowledged)
        try f.compact()
        #expect(try f.reopen().acknowledgeCurrentVersion(token) == .alreadyAcknowledged)
        #expect(try f.reopen().pendingVersioned().map(\.token.journalRevision) == [0, 2, 0, 2])
        #expect(try f.reopen().withExclusivePending { try $0.retainedRebases(for: first.input) } == [first])
        let checkpoint = try f.checkpoint()
        #expect(checkpoint["version"] as? Int == 5)
        #expect((checkpoint["rebaseHistory"] as? [Any])?.count == 2)
        try f.compact()
        #expect(try f.checkpoint()["version"] as? Int == 5)
        #expect(try f.reopen().acknowledgeCurrentVersion(token) == .alreadyAcknowledged)
    }

    @Test(arguments: ["reverse", "dropFirst", "dropLast", "head", "link"]) @MainActor
    func independentRecordHistoryCannotBeReorderedOrOmitted(damage: String) throws {
        let f = try JournalConflictFixture(); defer { f.remove() }
        let before = try f.journal.pendingVersioned()
        let first = try f.transition(after: [before[0].mutation, before[2].mutation, before[4].mutation])
        #expect(try f.journal.withExclusivePending { try $0.rebase(first) })
        let otherRecord = try #require(before[1].mutation.savedRecordVersion?.record)
        let second = try f.transition(after: [before[1].mutation, before[3].mutation], server: otherRecord)
        #expect(try f.journal.withExclusivePending { try $0.rebase(second) })
        try f.compact()
        var checkpoint = try f.checkpoint()
        try f.writeCheckpoint(checkpoint)
        #expect(try f.reopen().pendingVersioned().map(\.token.journalRevision) == [1, 1, 1, 1, 1])
        var history = try #require(checkpoint["rebaseHistory"] as? [Any])
        switch damage {
        case "reverse": history.reverse()
        case "dropFirst": history.removeFirst()
        case "dropLast": history.removeLast()
        case "head": checkpoint["rebaseHistoryHeadSHA256"] = Data(repeating: 0, count: 32).base64EncodedString()
        default:
            var link = try #require(history[1] as? [String: Any])
            link["predecessorRebaseHeadSHA256"] = Data(repeating: 0, count: 32).base64EncodedString()
            history[1] = link
        }
        checkpoint["rebaseHistory"] = history
        try f.writeCheckpoint(checkpoint)
        let bytes = try f.authority()
        #expect(throws: SyncMutationJournalError.corrupt) { _ = try f.reopen().pendingVersioned() }
        #expect(try f.authority() == bytes)
    }

    @Test @MainActor func changedHistoryHeadIsStaleEvenWhenCompletePendingReturnsUnchanged() throws {
        let f = try JournalConflictFixture(); defer { f.remove() }
        let before = try f.journal.pendingVersioned()
        let stale = try f.transition()
        let record = try #require(before[0].mutation.savedRecordVersion?.record)
        let temporaryRecord = SyncRecord(schemaVersion: record.schemaVersion,
            id: .init(kind: .project, uuid: UUID()), createdAt: record.createdAt,
            entityRevision: record.entityRevision, payload: record.payload,
            relationships: record.relationships, deletedAt: record.deletedAt)
        let temporary = try SyncMutation.save(recordVersion: SyncRecordVersion(record: temporaryRecord), mutationID: UUID())
        try f.journal.enqueue(temporary)
        let transition = try f.transition(after: [temporary], server: temporaryRecord)
        #expect(try f.journal.withExclusivePending { try $0.rebase(transition) })
        #expect(try f.journal.acknowledgeCurrentVersion(transition.afterVersions[0]) == .acknowledged)
        #expect(try f.journal.pendingVersioned() == before)
        let bytes = try f.authority()
        #expect(try f.journal.withExclusivePending { try $0.rebase(stale) } == false)
        #expect(try f.authority() == bytes)
        #expect(try f.journal.withExclusivePending { try $0.rebaseHistoryHeadSHA256() } == transition.integrity)
        try f.compact()
        #expect(try f.reopen().withExclusivePending { try $0.rebaseHistoryHeadSHA256() } == transition.integrity)
        #expect(throws: SyncConflictError.invalidInput) { _ = try f.transition(head: Data(repeating: 0, count: 31)) }
    }

    @Test(arguments: ["reverse", "missing", "collision", "receipt"])
    @MainActor func damagedCompactedAuthorityFailsClosed(damage: String) throws {
        let f = try JournalConflictFixture(); defer { f.remove() }
        let first = try f.transition()
        #expect(try f.journal.withExclusivePending { try $0.rebase(first) })
        let second = try f.transition()
        #expect(try f.journal.withExclusivePending { try $0.rebase(second) })
        #expect(try f.journal.acknowledgeCurrentVersion(second.afterVersions[0]) == .acknowledged)
        try f.compact()
        var checkpoint = try f.checkpoint()
        var history = try #require(checkpoint["rebaseHistory"] as? [[String: Any]])
        switch damage {
        case "reverse": history.reverse()
        case "missing": history.removeFirst()
        case "collision": history.append(history[0])
        default:
            var receipts = try #require(checkpoint["versionedAcknowledgements"] as? [[String: Any]])
            var token = try #require(receipts[0]["token"] as? [String: Any])
            token["journalRevision"] = 0
            receipts[0]["token"] = token
            checkpoint["versionedAcknowledgements"] = receipts
        }
        checkpoint["rebaseHistory"] = history
        try f.writeCheckpoint(checkpoint)
        let bytes = try f.authority()
        #expect(throws: SyncMutationJournalError.corrupt) { _ = try f.reopen().pendingVersioned() }
        #expect(try f.authority() == bytes)
    }

    @Test @MainActor func missingIssuedShardCannotBeReplacedByRebaseHistory() throws {
        let f = try JournalConflictFixture(); defer { f.remove() }
        let transition = try f.transition()
        #expect(try f.journal.withExclusivePending { try $0.rebase(transition) })
        try f.compact()
        let shard = f.url.appendingPathExtension("proofs.00000000")
        try FileManager.default.removeItem(at: shard)
        let bytes = try f.authority()
        #expect(throws: SyncMutationJournalError.corrupt) { _ = try f.reopen().pendingVersioned() }
        #expect(try f.authority() == bytes)
    }

    @Test @MainActor func committedV5CheckpointBeforeRotationReopensWithExactHistoryAndACK() throws {
        let f = try JournalConflictFixture(); defer { f.remove() }
        let transition = try f.transition()
        #expect(try f.journal.withExclusivePending { try $0.rebase(transition) })
        #expect(try f.journal.acknowledgeCurrentVersion(transition.afterVersions[0]) == .acknowledged)
        let interrupted = FileSyncMutationJournal(url: f.url, atomicWrite: { data, location in
            try data.write(to: location, options: .atomic)
            if location.pathExtension == "checkpoint" { throw JournalConflictFault.interrupted }
        })
        #expect(throws: JournalConflictFault.interrupted) { try f.compact(using: interrupted) }
        #expect(try f.reopen().acknowledgeCurrentVersion(transition.afterVersions[0]) == .alreadyAcknowledged)
        #expect(try f.reopen().withExclusivePending { try $0.retainedRebases(for: transition.input) } == [transition])
        #expect(try f.reopen().pendingVersioned().map(\.token.journalRevision) == [0, 1, 0, 1])
    }

    @Test @MainActor func partialFinalRebaseFrameBlocksNewConflictWorkWithoutTruncation() throws {
        let f = try JournalConflictFixture(); defer { f.remove() }
        let transition = try f.transition()
        let before = try Data(contentsOf: f.url.appendingPathExtension("segment"))
        #expect(try f.journal.withExclusivePending { try $0.rebase(transition) })
        let complete = try Data(contentsOf: f.url.appendingPathExtension("segment"))
        try complete.dropLast(7).write(to: f.url.appendingPathExtension("segment"))
        #expect(complete.count > before.count)
        let bytes = try f.authority()
        #expect(throws: SyncMutationJournalError.corrupt) {
            _ = try f.reopen().withExclusivePending { try $0.rebase(transition) }
        }
        #expect(try f.authority() == bytes)
    }

    @Test @MainActor func rolledBackCheckpointCannotAuthorizeLaterRevisionFrame() throws {
        let f = try JournalConflictFixture(); defer { f.remove() }
        let first = try f.transition()
        #expect(try f.journal.withExclusivePending { try $0.rebase(first) })
        try f.compact()
        let checkpoint = try Data(contentsOf: f.url.appendingPathExtension("checkpoint"))
        let second = try f.transition()
        #expect(try f.journal.withExclusivePending { try $0.rebase(second) })
        try f.compact()
        let third = try f.transition()
        #expect(try f.journal.withExclusivePending { try $0.rebase(third) })
        try checkpoint.write(to: f.url.appendingPathExtension("checkpoint"))
        let bytes = try f.authority()
        #expect(throws: SyncMutationJournalError.corrupt) { _ = try f.reopen().pendingVersioned() }
        #expect(try f.authority() == bytes)
    }

    @Test(arguments: [1, 2, 3, 4]) @MainActor func legacyCheckpointRebaseNeverLosesHistoryOnUpgrade(version: Int) throws {
        let f = try JournalConflictFixture(); defer { f.remove() }
        try f.compact()
        var checkpoint = try f.checkpoint()
        checkpoint["version"] = version
        if version == 1 {
            checkpoint["history"] = checkpoint["pending"]; checkpoint["proofShardCount"] = 0
            checkpoint["cleanupCompletion"] = ["completedShardCount": 0, "partialShards": []] as [String: Any]
        }
        if version < 4 { checkpoint.removeValue(forKey: "proofShardRoot") }
        try f.writeCheckpoint(checkpoint)
        let before = try f.reopen().pendingVersioned()
        #expect(before.map(\.token.journalRevision) == [0, 0, 0, 0, 0])
        let transition = try f.transition()
        #expect(try f.reopen().withExclusivePending { try $0.rebase(transition) })
        _ = try f.reopen().pending()
        #expect(try f.reopen().pendingVersioned().map(\.token.journalRevision) == [1, 0, 1, 0, 1])
        #expect(try f.reopen().withExclusivePending { try $0.retainedRebases(for: transition.input) } == [transition])
    }

    @Test @MainActor func attachmentRebaseCannotChangeIssuedImmutableSnapshot() throws {
        let f = try JournalConflictFixture(); defer { f.remove() }
        let remote = try f.base.base.photoBatch(id: UUID())
        var record = try #require(remote.batch.records.first { $0.id.kind == .attachment })
        let source = try #require(remote.attachments[record.id.uuid])
        let original = try SyncMutation.save(recordVersion: SyncRecordVersion(record: record), attachmentSource: source, mutationID: UUID())
        try f.journal.enqueue(original)
        let staged = try #require(f.journal.pendingVersioned().last?.mutation.attachmentSource)
        record.entityRevision += 1
        let after = try SyncMutation.save(recordVersion: SyncRecordVersion(record: record), attachmentSource: staged, mutationID: original.mutationID)
        let transition = try f.transition(after: [after], server: record)
        let bytes = try f.authority()
        #expect(throws: SyncMutationJournalError.corrupt) {
            try f.journal.withExclusivePending { try $0.preflightRebase(transition) }
        }
        #expect(try f.authority() == bytes)
    }

    @Test(arguments: [false, true]) @MainActor func missingRebasedACKReceiptRejectsBeforeCleanup(completed: Bool) throws {
        let f = try JournalConflictFixture(); defer { f.remove() }
        let remote = try f.base.base.photoBatch(id: UUID())
        let record = try #require(remote.batch.records.first { $0.id.kind == .attachment })
        let source = try #require(remote.attachments[record.id.uuid])
        let original = try SyncMutation.save(recordVersion: SyncRecordVersion(record: record), attachmentSource: source, mutationID: UUID())
        try f.journal.enqueue(original)
        let current = try #require(f.journal.pendingVersioned().last?.mutation)
        let staged = try #require(current.attachmentSource?.fileURL)
        let stagedBytes = try Data(contentsOf: staged)
        let transition = try f.transition(after: [current], server: record)
        #expect(try f.journal.withExclusivePending { try $0.rebase(transition) })
        try f.compact()
        if completed {
            #expect(try f.journal.acknowledgeCurrentVersion(transition.afterVersions[0]) == .acknowledged)
            // A valid later segment ACK supplies the receipt before source-byte
            // validation even though the older checkpoint still has pending.
            #expect(try f.reopen().pending().contains { $0.mutationID == original.mutationID } == false)
            try f.compact()
        }
        // The control is a real, freshly loaded journal with valid retained history.
        #expect(try f.reopen().pendingVersioned().contains { $0.mutation.mutationID == original.mutationID } == !completed)
        var checkpoint = try f.checkpoint()
        let encodedPending = try #require(checkpoint["pending"] as? [Any])
        let pending = try JSONDecoder().decode([SyncMutation].self,
            from: JSONSerialization.data(withJSONObject: encodedPending))
        let omitted = pending.filter { $0.mutationID != original.mutationID }
        try #require(omitted.count == 5)
        try #require(pending.count == (completed ? 5 : 6))
        checkpoint["pending"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(omitted))
        checkpoint["versionedAcknowledgements"] = []
        // Recompute only the outer checksum; issued shards, transition integrity,
        // linked history head, and any completed cleanup offsets remain untouched.
        try f.writeCheckpoint(checkpoint)
        let authority = try f.authority()
        #expect(throws: SyncMutationJournalError.corrupt) { _ = try f.reopen().pending() }
        let unchanged = try f.authority() == authority
        #expect(unchanged)
        if completed {
            #expect(!FileManager.default.fileExists(atPath: staged.path))
        } else {
            #expect((try? Data(contentsOf: staged)) == stagedBytes)
        }
    }

    @Test(arguments: [1, 2, 3, 4]) @MainActor func legacyCheckpointExactACKReceiptSurvivesMigration(version: Int) throws {
        let f = try JournalConflictFixture(); defer { f.remove() }
        let remote = try f.base.base.photoBatch(id: UUID())
        let record = try #require(remote.batch.records.first { $0.id.kind == .attachment })
        let source = try #require(remote.attachments[record.id.uuid])
        let original = try SyncMutation.save(recordVersion: SyncRecordVersion(record: record), attachmentSource: source, mutationID: UUID())
        try f.journal.enqueue(original)
        try f.compact()
        var checkpoint = try f.checkpoint()
        checkpoint["version"] = version
        if version == 1 {
            checkpoint["history"] = checkpoint["pending"]; checkpoint["proofShardCount"] = 0
            checkpoint["cleanupCompletion"] = ["completedShardCount": 0, "partialShards": []] as [String: Any]
        }
        if version < 4 { checkpoint.removeValue(forKey: "proofShardRoot") }
        try f.writeCheckpoint(checkpoint)
        let exact = try #require(f.reopen().pendingVersioned().last)
        let staged = try #require(exact.mutation.attachmentSource?.fileURL)
        #expect(exact.token.journalRevision == 0)
        #expect(try f.reopen().acknowledgeCurrentVersion(exact.token) == .acknowledged)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        // Later kind-5 segment replay must establish the receipt before loading
        // source bytes or migrating the older checkpoint.
        #expect(try f.reopen().pending().contains { $0.mutationID == original.mutationID } == false)
        try f.compact(using: f.reopen())
        #expect(try f.checkpoint()["version"] as? Int == 5)
        #expect(try f.reopen().acknowledgeCurrentVersion(exact.token) == .alreadyAcknowledged)
        let wrong = try SyncMutationVersionToken(mutation: exact.mutation, journalRevision: 1)
        let authority = try f.authority()
        #expect(try f.reopen().acknowledgeCurrentVersion(wrong) == .staleVersion)
        #expect(try f.authority() == authority)
    }

    @Test @MainActor func attachmentTombstoneRebaseCleansIssuedBytesAndRetainsHistoryAfterACK() throws {
        let f = try JournalConflictFixture(); defer { f.remove() }
        let remote = try f.base.base.photoBatch(id: UUID())
        var record = try #require(remote.batch.records.first { $0.id.kind == .attachment })
        let source = try #require(remote.attachments[record.id.uuid])
        let original = try SyncMutation.save(recordVersion: SyncRecordVersion(record: record), attachmentSource: source, mutationID: UUID())
        try f.journal.enqueue(original)
        let staged = try #require(f.journal.pendingVersioned().last?.mutation.attachmentSource?.fileURL)
        record.deletedAt = .init(value: Date(timeIntervalSince1970: 2_000_000_200), stamp: record.deletedAt.stamp)
        let after = try SyncMutation.save(recordVersion: SyncRecordVersion(record: record), mutationID: original.mutationID)
        let transition = try f.transition(after: [after], server: record)
        #expect(try f.journal.withExclusivePending { try $0.rebase(transition) })
        #expect(FileManager.default.fileExists(atPath: staged.path))
        #expect(try f.journal.acknowledgeCurrentVersion(transition.afterVersions[0]) == .acknowledged)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        try f.compact()
        #expect(try f.reopen().acknowledgeCurrentVersion(transition.afterVersions[0]) == .alreadyAcknowledged)
        var checkpoint = try f.checkpoint()
        checkpoint["rebaseHistory"] = []
        try f.writeCheckpoint(checkpoint)
        #expect(throws: SyncMutationJournalError.corrupt) { _ = try f.reopen().pendingVersioned() }
    }

    @Test @MainActor func checkpointCannotSubstituteRebasedAttachmentSourceWithEqualBytes() throws {
        let f = try JournalConflictFixture(); defer { f.remove() }
        let remote = try f.base.base.photoBatch(id: UUID())
        let record = try #require(remote.batch.records.first { $0.id.kind == .attachment })
        let source = try #require(remote.attachments[record.id.uuid])
        let original = try SyncMutation.save(recordVersion: SyncRecordVersion(record: record), attachmentSource: source, mutationID: UUID())
        try f.journal.enqueue(original)
        let current = try #require(f.journal.pendingVersioned().last?.mutation)
        let transition = try f.transition(after: [current], server: record)
        #expect(try f.journal.withExclusivePending { try $0.rebase(transition) })
        try f.compact()
        let staged = try #require(current.attachmentSource)
        let alternate = staged.fileURL.deletingLastPathComponent().appendingPathComponent("equal-bytes.asset")
        try FileManager.default.copyItem(at: staged.fileURL, to: alternate)
        let changed = try current.replacingAttachmentSource(.init(fileURL: alternate,
            contentSHA256: staged.contentSHA256, byteCount: staged.byteCount, isJournalStaged: true))
        var checkpoint = try f.checkpoint()
        try f.writeCheckpoint(checkpoint)
        #expect(try f.reopen().pendingVersioned().last?.mutation == current)
        var pending = try #require(checkpoint["pending"] as? [Any])
        pending[pending.count - 1] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(changed))
        checkpoint["pending"] = pending
        try f.writeCheckpoint(checkpoint)
        let bytes = try f.authority()
        #expect(throws: SyncMutationJournalError.corrupt) { _ = try f.reopen().pendingVersioned() }
        #expect(try f.authority() == bytes)
    }

    @Test(.timeLimit(.minutes(3))) @MainActor func projectedHistoryCapacityRejectsBeforeAnyDurableChange() throws {
        let f = try JournalConflictFixture(); defer { f.remove() }
        var record = try f.base.input().serverRecord
        for index in 0..<6 {
            record.payload.fields["large-field-\(index)"] = .init(value: .string(String(repeating: "x", count: 250_000)), stamp: record.deletedAt.stamp)
        }
        var blocked = false
        for _ in 0..<8 {
            let transition = try f.transition(server: record)
            let before = try f.authority()
            let frames = f.counters.appendedFrameCount
            do {
                try f.journal.withExclusivePending { try $0.preflightRebase(transition) }
            } catch SyncMutationJournalError.tooLarge {
                blocked = true
                #expect(try f.authority() == before)
                #expect(f.counters.appendedFrameCount == frames)
                #expect(throws: SyncMutationJournalError.tooLarge) {
                    _ = try f.journal.withExclusivePending { try $0.rebase(transition) }
                }
                #expect(try f.authority() == before)
                let remote = try f.base.base.photoBatch(id: UUID())
                let attachmentRecord = try #require(remote.batch.records.first { $0.id.kind == .attachment })
                let source = try #require(remote.attachments[attachmentRecord.id.uuid])
                let attachment = try SyncMutation.save(recordVersion: SyncRecordVersion(record: attachmentRecord),
                    attachmentSource: source, mutationID: UUID())
                let largeSuccessors = try (0..<20).map { _ in
                    try SyncMutation.save(recordVersion: SyncRecordVersion(record: record), mutationID: UUID())
                }
                #expect(throws: SyncMutationJournalError.tooLarge) {
                    try f.journal.enqueue([attachment] + largeSuccessors)
                }
                let unchanged = try f.authority() == before
                #expect(unchanged)
                break
            }
            #expect(try f.journal.withExclusivePending { try $0.rebase(transition) })
            try f.compact()
        }
        #expect(blocked)
    }
}

@MainActor private struct JournalConflictFixture {
    let base: ConflictRebaseFixture
    let journal: FileSyncMutationJournal
    let counters = SyncJournalIOCounters()
    let url: URL
    init() throws {
        base = try ConflictRebaseFixture()
        url = base.base.root.appendingPathComponent("journal-conflict/pending.json")
        journal = FileSyncMutationJournal(url: url, counters: counters)
        let queue = try base.input().expectedRecordQueue
        let unrelated = try #require(base.base.records.first {
            $0.id.kind == .project && $0.id != queue[0].recordID
        })
        let otherFirst = try SyncMutation.save(recordVersion: SyncRecordVersion(record: unrelated), mutationID: UUID())
        let otherSecond = try SyncMutation.save(recordVersion: SyncRecordVersion(record: unrelated), mutationID: UUID())
        try journal.enqueue([queue[0], otherFirst, queue[1], otherSecond, queue[2]])
    }
    func reopen() -> FileSyncMutationJournal { FileSyncMutationJournal(url: url) }
    func remove() { base.remove() }
    func compact(using supplied: FileSyncMutationJournal? = nil) throws {
        let target = supplied ?? journal
        let unrelated = SyncEntityID(kind: .project, uuid: UUID())
        let mutations = (0..<130).map { _ in SyncMutation.delete(unrelated, mutationID: UUID()) }
        try target.enqueue(mutations)
        try target.acknowledge(Set(mutations.map(\.identity)))
    }
    func checkpoint() throws -> [String: Any] {
        let outer = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathExtension("checkpoint"))) as? [String: Any])
        let encoded = try #require(outer["checkpoint"] as? String)
        let data = try #require(Data(base64Encoded: encoded))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func writeCheckpoint(_ value: [String: Any]) throws {
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let outer: [String: Any] = ["version": 1, "checkpoint": bytes.base64EncodedString(),
            "checksum": Data(SHA256.hash(data: bytes)).base64EncodedString()]
        try JSONSerialization.data(withJSONObject: outer, options: [.sortedKeys]).write(to: url.appendingPathExtension("checkpoint"))
    }
    func authority() throws -> [String: Data] {
        let root = url.deletingLastPathComponent()
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        var result: [String: Data] = [:]
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true { result[file.path + "/"] = Data() }
            if values.isRegularFile == true { result[file.path] = try Data(contentsOf: file) }
        }
        return result
    }
    func transition(after supplied: [SyncMutation]? = nil, server: SyncRecord? = nil, head: Data? = nil,
                    tokens: [SyncMutationVersionToken]? = nil) throws -> SyncJournalRebaseTransition {
        let all = try journal.pendingVersioned()
        let record = try server ?? base.input().serverRecord
        let selected = all.filter { $0.mutation.recordID == record.id }
        let input = try SyncConflictInput(accountIDHash: base.base.account.accountIDHash,
            failedAttemptID: UUID(), failedMutation: selected[0].mutation, failedVersion: selected[0].token,
            serverRecord: record, expectedRecordQueue: selected.map(\.mutation), expectedVersions: selected.map(\.token))
        let after = try supplied ?? selected.map {
            try SyncMutation.save(recordVersion: SyncRecordVersion(record: record), mutationID: $0.mutation.mutationID)
        }
        return try SyncJournalRebaseTransition(transactionID: UUID(), input: input,
            predecessorPendingSHA256: SyncConflictRebaseCoding.pendingDigest(all),
            predecessorRebaseHeadSHA256: head ?? journal.withExclusivePending { try $0.rebaseHistoryHeadSHA256() },
            recordPositions: all.indices.filter { all[$0].mutation.recordID == record.id },
            before: selected.map(\.mutation), after: after, beforeVersions: selected.map(\.token),
            afterVersions: tokens ?? zip(after, selected).map {
                try SyncMutationVersionToken(mutation: $0.0, journalRevision: $0.1.token.journalRevision + 1)
            })
    }
}

private enum JournalConflictFault: Error { case interrupted }
