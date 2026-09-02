import Darwin
import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

@Suite(.serialized) struct SyncMutationJournalSegmentTests {
    @Test func twoThousandSequentialOperationsDoNotRewriteEverySuffix() throws {
        let fixture = try SegmentedJournalFixture()
        for index in 0..<2_000 {
            let mutation = fixture.mutation(index: index)
            try fixture.journal.enqueue(mutation)
            try fixture.journal.acknowledge([mutation.identity])
        }

        #expect(fixture.counters.appendedFrameCount == 4_000)
        #expect(fixture.counters.fullCheckpointRewriteCount < 20)
        #expect(try fixture.reopened().pending().isEmpty)
    }

    @Test(.timeLimit(.minutes(3)))
    func twoThousandSequentialAttachmentAcknowledgementsStayIncrementalAndCompact() throws {
        let fixture = try SegmentedJournalFixture()
        let source = fixture.directory.appendingPathComponent("sequential-cleanup-source.asset")
        let bytes = Data("sequential cleanup bytes".utf8)
        try bytes.write(to: source)
        let operationCount = 2_000
        var firstMutation: SyncMutation?

        for index in 0..<operationCount {
            let mutation = try fixture.attachmentMutation(index: index, bytes: bytes, source: source)
            if firstMutation == nil { firstMutation = mutation }
            try fixture.journal.enqueue(mutation)
            try fixture.journal.acknowledge([mutation.identity])
        }

        #expect(fixture.counters.appendedFrameCount == operationCount * 3)
        #expect(fixture.counters.fullCheckpointRewriteCount == 15)
        #expect(fixture.counters.fullCheckpointRewriteCount < 20)
        let expectedShardCount = (operationCount + 127) / 128
        let proofShardCount = try fixture.proofShardURLs().count
        #expect(proofShardCount == expectedShardCount - 1)

        let restartIO = CleanupFailureController(journalURL: fixture.url)
        let reopened = fixture.cleanupJournal(restartIO)
        #expect(try reopened.pending().isEmpty)
        #expect(restartIO.unlinkAttemptCount == 0)
        #expect(restartIO.attachmentDirectorySyncCount == 0)

        let original = try #require(firstMutation)
        let segmentBeforeRetry = try Data(contentsOf: fixture.segmentURL)
        try reopened.enqueue(original)
        #expect(try reopened.pending().isEmpty)
        #expect(try Data(contentsOf: fixture.segmentURL) == segmentBeforeRetry)
        #expect(throws: SyncMutationJournalError.duplicateMutationID) {
            try reopened.enqueue(.delete(
                original.recordID,
                mutationID: original.mutationID
            ))
        }
        #expect(try Data(contentsOf: fixture.segmentURL) == segmentBeforeRetry)
    }

    @Test func truncatedFinalFramePreservesEarlierPendingMutations() throws {
        let fixture = try SegmentedJournalFixture()
        let first = fixture.mutation(index: 1)
        let second = fixture.mutation(index: 2)
        try fixture.journal.enqueue([first, second])

        try fixture.truncateLastFrame()

        #expect(try fixture.reopened().pending() == [first])
    }

    @Test func checksumCorruptionInCommittedFrameIsRejected() throws {
        let fixture = try SegmentedJournalFixture()
        try fixture.journal.enqueue([
            fixture.mutation(index: 1),
            fixture.mutation(index: 2)
        ])
        try fixture.replaceFirstFrameChecksum(with: Data(repeating: 0, count: 32))

        #expect(throws: SyncMutationJournalError.corrupt) {
            _ = try fixture.reopened().pending()
        }
    }

    @Test func corruptedCommittedLengthCannotMasqueradeAsPartialFinalAppend() throws {
        let fixture = try SegmentedJournalFixture()
        try fixture.journal.enqueue([
            fixture.mutation(index: 1),
            fixture.mutation(index: 2)
        ])
        try fixture.replaceFirstFrameLengthWithRemainingFileSize()

        #expect(throws: SyncMutationJournalError.corrupt) {
            _ = try fixture.reopened().pending()
        }
    }

    @Test func interruptedCheckpointReplacementReplaysCommittedSegment() throws {
        let fixture = try SegmentedJournalFixture(failCheckpointWrite: true)
        let initial = (0..<128).map(fixture.mutation(index:))
        try fixture.journal.enqueue(initial)
        try fixture.journal.acknowledge(Set(initial.prefix(127).map(\.identity)))
        let unacknowledged = fixture.mutation(index: 1_000)

        #expect(throws: InterruptedCheckpointWrite.self) {
            try fixture.journal.enqueue(unacknowledged)
        }

        #expect(try fixture.reopened().pending() == [initial[127], unacknowledged])
    }

    @Test func duplicateIdenticalMutationIsAcceptedWithoutAppendingAnotherFrame() throws {
        let fixture = try SegmentedJournalFixture()
        let mutation = fixture.mutation(index: 1)
        try fixture.journal.enqueue(mutation)
        let appended = fixture.counters.appendedFrameCount

        try fixture.journal.enqueue(mutation)

        #expect(fixture.counters.appendedFrameCount == appended)
        #expect(try fixture.reopened().pending() == [mutation])
    }

    @Test func duplicateDivergentMutationIsRejectedWithoutChangingCommittedFrames() throws {
        let fixture = try SegmentedJournalFixture()
        let original = fixture.mutation(index: 1)
        try fixture.journal.enqueue(original)
        let divergent = SyncMutation.delete(
            original.recordID,
            mutationID: original.mutationID
        )
        let segmentBytes = try Data(contentsOf: fixture.segmentURL)

        #expect(throws: SyncMutationJournalError.duplicateMutationID) {
            try fixture.journal.enqueue(divergent)
        }

        #expect(try Data(contentsOf: fixture.segmentURL) == segmentBytes)
        #expect(try fixture.reopened().pending() == [original])
    }

    @Test func acknowledgedIdenticalMutationRemainsIdempotentAfterCheckpointRestart() throws {
        let fixture = try SegmentedJournalFixture()
        let mutations = (0..<128).map(fixture.mutation(index:))
        try fixture.journal.enqueue(mutations)
        try fixture.journal.acknowledge(Set(mutations.map(\.identity)))
        let counters = SyncJournalIOCounters()
        let reopened = FileSyncMutationJournal(url: fixture.url, counters: counters)

        try reopened.enqueue(mutations[0])

        #expect(try reopened.pending().isEmpty)
        #expect(counters.appendedFrameCount == 0)
    }

    @Test func acknowledgedDivergentMutationIsRejectedAfterCheckpointRestart() throws {
        let fixture = try SegmentedJournalFixture()
        let mutations = (0..<128).map(fixture.mutation(index:))
        try fixture.journal.enqueue(mutations)
        try fixture.journal.acknowledge(Set(mutations.map(\.identity)))
        let divergent = SyncMutation.delete(
            mutations[0].recordID,
            mutationID: mutations[0].mutationID
        )
        let reopened = fixture.reopened()

        #expect(throws: SyncMutationJournalError.duplicateMutationID) {
            try reopened.enqueue(divergent)
        }
        #expect(try reopened.pending().isEmpty)
    }

    @Test func twoInstancesRefreshBeforeEveryMutation() throws {
        let fixture = try SegmentedJournalFixture()
        let first = fixture.reopened()
        let second = fixture.reopened()
        #expect(try first.pending().isEmpty)
        #expect(try second.pending().isEmpty)
        let firstMutation = fixture.mutation(index: 1)
        let secondMutation = fixture.mutation(index: 2)

        try first.enqueue(firstMutation)
        try second.enqueue(secondMutation)

        #expect(try fixture.reopened().pending() == [firstMutation, secondMutation])
    }

    @Test func twoInstancesConcurrentlyEnqueueAcknowledgeAndCompactWithoutLostFrames() throws {
        let fixture = try SegmentedJournalFixture()
        let journals = [fixture.reopened(), fixture.reopened()]
        let mutations = (0..<300).map(fixture.mutation(index:))
        let errors = ConcurrentJournalErrors()
        DispatchQueue.concurrentPerform(iterations: mutations.count) { index in
            do {
                try journals[index % journals.count].enqueue(mutations[index])
            } catch {
                errors.record(error)
            }
        }
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            do {
                try journals[index % journals.count].acknowledge([mutations[index].identity])
            } catch {
                errors.record(error)
            }
        }

        #expect(errors.values.isEmpty)
        let expected = Set(mutations.dropFirst(200).map(\.identity))
        #expect(Set(try fixture.reopened().pending().map(\.identity)) == expected)
    }

    @Test func independentCoordinatorRegistriesSerializeThroughParentDirectoryLock() throws {
        let fixture = try SegmentedJournalFixture()
        let journals = (0..<2).map { _ in
            FileSyncMutationJournal(
                url: fixture.url,
                coordinatorRegistry: SyncJournalURLCoordinatorRegistry(),
                synchronizeFile: synchronizeJournalTestFile,
                synchronizeDirectory: synchronizeJournalTestDirectory
            )
        }
        let mutations = (0..<200).map(fixture.mutation(index:))
        let errors = ConcurrentJournalErrors()

        DispatchQueue.concurrentPerform(iterations: mutations.count) { index in
            do {
                try journals[index % journals.count].enqueue(mutations[index])
            } catch {
                errors.record(error)
            }
        }

        #expect(errors.values.isEmpty)
        #expect(Set(try fixture.reopened().pending().map(\.identity)) == Set(
            mutations.map(\.identity)
        ))
    }

    @Test func fileSyncFailureAfterAppendRequiresIdenticalRetryRepair() throws {
        let fixture = try SegmentedJournalFixture()
        let synchronizer = FailOnceJournalSynchronizer(failure: FileSyncFailure())
        let journal = FileSyncMutationJournal(
            url: fixture.url,
            synchronizeFile: synchronizer.synchronizeFile,
            synchronizeDirectory: synchronizeJournalTestDirectory
        )
        let mutation = fixture.mutation(index: 1)

        #expect(throws: FileSyncFailure.self) {
            try journal.enqueue(mutation)
        }
        try journal.enqueue(mutation)

        #expect(synchronizer.attempts >= 2)
        #expect(try fixture.reopened().pending() == [mutation])
    }

    @Test func directorySyncFailureAfterAppendRequiresIdenticalRetryRepair() throws {
        let fixture = try SegmentedJournalFixture()
        let synchronizer = FailOnceJournalSynchronizer(failure: DirectorySyncFailure())
        let journal = FileSyncMutationJournal(
            url: fixture.url,
            synchronizeFile: synchronizeJournalTestFile,
            synchronizeDirectory: synchronizer.synchronizeDirectory
        )
        let mutation = fixture.mutation(index: 1)

        #expect(throws: DirectorySyncFailure.self) {
            try journal.enqueue(mutation)
        }
        try journal.enqueue(mutation)

        #expect(synchronizer.attempts >= 2)
        #expect(try fixture.reopened().pending() == [mutation])
    }

    @Test func independentCoordinatorRepairsExternalFileSyncFailureBeforeRetry() throws {
        let fixture = try SegmentedJournalFixture()
        let writerSync = FailOnceJournalSynchronizer(failure: FileSyncFailure())
        let repair = JournalRepairRecorder()
        let writer = FileSyncMutationJournal(
            url: fixture.url,
            coordinatorRegistry: SyncJournalURLCoordinatorRegistry(),
            synchronizeFile: writerSync.synchronizeFile,
            synchronizeDirectory: synchronizeJournalTestDirectory
        )
        let reader = FileSyncMutationJournal(
            url: fixture.url,
            coordinatorRegistry: SyncJournalURLCoordinatorRegistry(),
            synchronizeFile: repair.synchronizeFile,
            synchronizeDirectory: repair.synchronizeDirectory
        )
        let mutation = fixture.mutation(index: 11)
        #expect(try reader.pending().isEmpty)

        #expect(throws: FileSyncFailure.self) {
            try writer.enqueue(mutation)
        }
        try reader.enqueue(mutation)

        #expect(repair.fileSyncCount >= 1)
        #expect(repair.directorySyncCount >= 1)
        #expect(try fixture.reopened().pending() == [mutation])
    }

    @Test func independentCoordinatorRepairsExternalDirectorySyncFailureBeforeRetry() throws {
        let fixture = try SegmentedJournalFixture()
        let writerSync = FailOnceJournalSynchronizer(failure: DirectorySyncFailure())
        let repair = JournalRepairRecorder()
        let writer = FileSyncMutationJournal(
            url: fixture.url,
            coordinatorRegistry: SyncJournalURLCoordinatorRegistry(),
            synchronizeFile: synchronizeJournalTestFile,
            synchronizeDirectory: writerSync.synchronizeDirectory
        )
        let reader = FileSyncMutationJournal(
            url: fixture.url,
            coordinatorRegistry: SyncJournalURLCoordinatorRegistry(),
            synchronizeFile: repair.synchronizeFile,
            synchronizeDirectory: repair.synchronizeDirectory
        )
        let mutation = fixture.mutation(index: 12)
        #expect(try reader.pending().isEmpty)

        #expect(throws: DirectorySyncFailure.self) {
            try writer.enqueue(mutation)
        }
        try reader.enqueue(mutation)

        #expect(repair.fileSyncCount >= 1)
        #expect(repair.directorySyncCount >= 1)
        #expect(try fixture.reopened().pending() == [mutation])
    }

    @Test func restartInstrumentationCountsOnlyJournalBytesRead() throws {
        let fixture = try SegmentedJournalFixture()
        let mutations = [fixture.mutation(index: 1), fixture.mutation(index: 2)]
        try fixture.journal.enqueue(mutations)
        let counters = SyncJournalIOCounters()
        let reopened = FileSyncMutationJournal(url: fixture.url, counters: counters)

        #expect(try reopened.pending() == mutations)
        #expect(counters.bytesRead == (try Data(contentsOf: fixture.segmentURL).count))
    }

    @Test func legacyVersionTwoEnvelopeMigratesAfterValidationAndRetainsEvidence() throws {
        let fixture = try SegmentedJournalFixture()
        let mutation = fixture.mutation(index: 7)
        let legacyBytes = try fixture.legacyEnvelope([mutation])
        try legacyBytes.write(to: fixture.url)

        #expect(try fixture.journal.pending() == [mutation])
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(try Data(contentsOf: fixture.migratedURL) == legacyBytes)
        #expect(FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.segmentURL.path))
        #expect(try fixture.reopened().pending() == [mutation])
    }

    @Test func migrationInterruptedAfterCheckpointFinishesOnRestart() throws {
        let fixture = try SegmentedJournalFixture(failSegmentRotationAfterCheckpoint: true)
        let mutation = fixture.mutation(index: 9)
        let legacyBytes = try fixture.legacyEnvelope([mutation])
        try legacyBytes.write(to: fixture.url)

        #expect(throws: InterruptedSegmentRotation.self) {
            _ = try fixture.journal.pending()
        }

        #expect(try Data(contentsOf: fixture.url) == legacyBytes)
        #expect(FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
        #expect(try fixture.reopened().pending() == [mutation])
        #expect(try Data(contentsOf: fixture.migratedURL) == legacyBytes)
    }

    @Test func twoInstancesConcurrentlyFinishOneLegacyMigration() throws {
        let fixture = try SegmentedJournalFixture()
        let mutation = fixture.mutation(index: 10)
        let legacyBytes = try fixture.legacyEnvelope([mutation])
        try legacyBytes.write(to: fixture.url)
        let journals = [fixture.reopened(), fixture.reopened()]
        let results = ConcurrentJournalResults()
        DispatchQueue.concurrentPerform(iterations: journals.count) { index in
            do {
                results.record(try journals[index].pending())
            } catch {
                results.record(error)
            }
        }

        #expect(results.errors.isEmpty)
        #expect(results.mutations == [[mutation], [mutation]])
        #expect(try Data(contentsOf: fixture.migratedURL) == legacyBytes)
    }

    @Test func checkpointCommittedBeforeSegmentRotationReplaysOnRestart() throws {
        let fixture = try SegmentedJournalFixture(failSegmentRotationAfterCheckpoint: true)
        let mutations = (0..<128).map(fixture.mutation(index:))
        try fixture.journal.enqueue(mutations)

        #expect(throws: InterruptedSegmentRotation.self) {
            try fixture.journal.acknowledge(Set(mutations.map(\.identity)))
        }

        #expect(try fixture.reopened().pending().isEmpty)
    }

    @Test func acknowledgedHistoryUsesCompactBoundedProofShardsAndKeepsOperating() throws {
        let fixture = try SegmentedJournalFixture()
        let marker = "UNIQUE-HISTORY-PAYLOAD-" + String(repeating: "payload", count: 600)
        var mutations = try (0..<299).map {
            try fixture.largeMutation(index: $0, marker: marker)
        }
        let source = fixture.directory.appendingPathComponent("private-source-name.asset")
        let bytes = Data("private attachment bytes".utf8)
        try bytes.write(to: source)
        let attachment = try fixture.attachmentMutation(index: 299, bytes: bytes, source: source)
        mutations.append(attachment)

        try fixture.journal.enqueue(mutations)
        let stagedName = try #require(
            fixture.journal.pending().last?.attachmentSource?.fileURL.lastPathComponent
        )
        try fixture.journal.acknowledge(Set(mutations.map(\.identity)))

        let proofURLs = try fixture.proofShardURLs()
        #expect(proofURLs.count >= 3)
        #expect(try Data(contentsOf: fixture.checkpointURL).count < 128 * 1_024)
        #expect(try proofURLs.allSatisfy {
            try Data(contentsOf: $0).count < 128 * 1_024
        })
        let persistedEvidence = try fixture.expandedPersistedProofEvidence(proofURLs: proofURLs)
        #expect(persistedEvidence.range(of: Data(marker.utf8)) == nil)
        #expect(persistedEvidence.range(of: Data(stagedName.utf8)) == nil)

        let reopened = fixture.reopened()
        try reopened.enqueue(mutations[0])
        #expect(try reopened.pending().isEmpty)
        #expect(throws: SyncMutationJournalError.duplicateMutationID) {
            try reopened.enqueue(.delete(
                mutations[0].recordID,
                mutationID: mutations[0].mutationID
            ))
        }
        let next = try fixture.largeMutation(index: 900, marker: "continued")
        try reopened.enqueue(next)
        try reopened.acknowledge([next.identity])
        #expect(try fixture.reopened().pending().isEmpty)
    }

    @Test func acknowledgedAttachmentCleanupBatchesDirectorySyncAndDoesNotReplayAfterRestart() throws {
        let fixture = try SegmentedJournalFixture()
        let source = fixture.directory.appendingPathComponent("cleanup-source.asset")
        let bytes = Data("batched cleanup bytes".utf8)
        try bytes.write(to: source)
        let mutations = try (0..<300).map {
            try fixture.attachmentMutation(index: $0, bytes: bytes, source: source)
        }
        let firstSyncs = AttachmentDirectorySyncRecorder(journalURL: fixture.url)
        let journal = FileSyncMutationJournal(
            url: fixture.url,
            coordinatorRegistry: SyncJournalURLCoordinatorRegistry(),
            synchronizeFile: synchronizeJournalTestFile,
            synchronizeDirectory: firstSyncs.synchronizeDirectory
        )

        try journal.enqueue(mutations)
        try journal.acknowledge(Set(mutations.map(\.identity)))

        #expect(firstSyncs.attachmentDirectorySyncCount == 1)
        let restartSyncs = AttachmentDirectorySyncRecorder(journalURL: fixture.url)
        let reopened = FileSyncMutationJournal(
            url: fixture.url,
            coordinatorRegistry: SyncJournalURLCoordinatorRegistry(),
            synchronizeFile: synchronizeJournalTestFile,
            synchronizeDirectory: restartSyncs.synchronizeDirectory
        )
        #expect(try reopened.pending().isEmpty)
        #expect(restartSyncs.attachmentDirectorySyncCount == 0)
    }

    @Test func partialCleanupBatchPersistsSuccessesAndRetriesOnlyFailedUnlink() throws {
        let fixture = try SegmentedJournalFixture()
        let source = fixture.directory.appendingPathComponent("partial-cleanup-source.asset")
        let bytes = Data("partial cleanup bytes".utf8)
        try bytes.write(to: source)
        let mutations = try (0..<3).map {
            try fixture.attachmentMutation(index: $0, bytes: bytes, source: source)
        }
        let cleanupIO = CleanupFailureController(
            journalURL: fixture.url,
            failingUnlinkAttempt: 2
        )
        let journal = fixture.cleanupJournal(cleanupIO)
        try journal.enqueue(mutations)
        let staged = try journal.pending().compactMap(\.attachmentSource?.fileURL)

        #expect(throws: CleanupUnlinkFailure.self) {
            try journal.acknowledge(Set(mutations.map(\.identity)))
        }
        #expect(staged.filter { FileManager.default.fileExists(atPath: $0.path) }.count == 1)
        let failedStaged = try #require(cleanupIO.failedUnlinkFile)
        #expect(FileManager.default.fileExists(atPath: failedStaged.path))
        #expect(cleanupIO.attachmentDirectorySyncCount == 1)

        let retryIO = CleanupFailureController(journalURL: fixture.url)
        #expect(try fixture.cleanupJournal(retryIO).pending().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: failedStaged.path))
        #expect(retryIO.unlinkAttemptCount == 1)
        #expect(retryIO.attachmentDirectorySyncCount == 1)
        let finalIO = CleanupFailureController(journalURL: fixture.url)
        #expect(try fixture.cleanupJournal(finalIO).pending().isEmpty)
        #expect(finalIO.unlinkAttemptCount == 0)
        #expect(finalIO.attachmentDirectorySyncCount == 0)
    }

    @Test func cleanupDirectorySyncFailureRetriesBeforePersistingCompletion() throws {
        let fixture = try SegmentedJournalFixture()
        let source = fixture.directory.appendingPathComponent("dirsync-cleanup-source.asset")
        let bytes = Data("directory sync cleanup bytes".utf8)
        try bytes.write(to: source)
        let mutations = try (0..<4).map {
            try fixture.attachmentMutation(index: $0, bytes: bytes, source: source)
        }
        let failingIO = CleanupFailureController(
            journalURL: fixture.url,
            failAttachmentDirectorySyncOnce: true
        )
        let journal = fixture.cleanupJournal(failingIO)
        try journal.enqueue(mutations)
        let staged = try journal.pending().compactMap(\.attachmentSource?.fileURL)

        #expect(throws: DirectorySyncFailure.self) {
            try journal.acknowledge(Set(mutations.map(\.identity)))
        }
        #expect(staged.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })

        let retryIO = CleanupFailureController(journalURL: fixture.url)
        #expect(try fixture.cleanupJournal(retryIO).pending().isEmpty)
        #expect(retryIO.unlinkAttemptCount == 0)
        #expect(retryIO.attachmentDirectorySyncCount == 1)
        let finalIO = CleanupFailureController(journalURL: fixture.url)
        #expect(try fixture.cleanupJournal(finalIO).pending().isEmpty)
        #expect(finalIO.attachmentDirectorySyncCount == 0)
    }

    @Test func cleanupCompletionFrameFailureRetriesAbsentFilesThenDurablyStops() throws {
        let fixture = try SegmentedJournalFixture()
        let source = fixture.directory.appendingPathComponent("completion-cleanup-source.asset")
        let bytes = Data("completion cleanup bytes".utf8)
        try bytes.write(to: source)
        let mutations = try (0..<4).map {
            try fixture.attachmentMutation(index: $0, bytes: bytes, source: source)
        }
        let cleanupIO = CleanupFailureController(journalURL: fixture.url)
        let completionAppender = FailOnceCleanupCompletionAppender(writeBeforeThrow: false)
        let journal = fixture.cleanupJournal(
            cleanupIO,
            appendFrames: completionAppender.appendFrames
        )
        try journal.enqueue(mutations)
        let staged = try journal.pending().compactMap(\.attachmentSource?.fileURL)

        #expect(throws: CleanupCompletionAppendFailure.self) {
            try journal.acknowledge(Set(mutations.map(\.identity)))
        }
        #expect(staged.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })

        let retryIO = CleanupFailureController(journalURL: fixture.url)
        #expect(try fixture.cleanupJournal(retryIO).pending().isEmpty)
        #expect(retryIO.unlinkAttemptCount == 0)
        #expect(retryIO.attachmentDirectorySyncCount == 1)
        let finalIO = CleanupFailureController(journalURL: fixture.url)
        #expect(try fixture.cleanupJournal(finalIO).pending().isEmpty)
        #expect(finalIO.attachmentDirectorySyncCount == 0)
    }

    @Test func committedCleanupCompletionFrameSurvivesReportedAppendFailureWithoutReplay() throws {
        let fixture = try SegmentedJournalFixture()
        let source = fixture.directory.appendingPathComponent("committed-completion-source.asset")
        let bytes = Data("committed completion bytes".utf8)
        try bytes.write(to: source)
        let mutation = try fixture.attachmentMutation(index: 1, bytes: bytes, source: source)
        let cleanupIO = CleanupFailureController(journalURL: fixture.url)
        let completionAppender = FailOnceCleanupCompletionAppender(writeBeforeThrow: true)
        let journal = fixture.cleanupJournal(
            cleanupIO,
            appendFrames: completionAppender.appendFrames
        )
        try journal.enqueue(mutation)
        let staged = try #require(
            journal.pending().first?.attachmentSource?.fileURL
        )

        #expect(throws: CleanupCompletionAppendFailure.self) {
            try journal.acknowledge([mutation.identity])
        }
        #expect(!FileManager.default.fileExists(atPath: staged.path))

        let restartIO = CleanupFailureController(journalURL: fixture.url)
        #expect(try fixture.cleanupJournal(restartIO).pending().isEmpty)
        #expect(restartIO.unlinkAttemptCount == 0)
        #expect(restartIO.attachmentDirectorySyncCount == 0)
    }

    @Test func cleanupRetriesAfterCheckpointCommitsBeforeSegmentRotation() throws {
        let fixture = try SegmentedJournalFixture(failSegmentRotationAfterCheckpoint: true)
        let source = fixture.directory.appendingPathComponent("rotation-cleanup-source.asset")
        let bytes = Data("rotation cleanup bytes".utf8)
        try bytes.write(to: source)
        let mutations = try (0..<128).map {
            try fixture.attachmentMutation(index: $0, bytes: bytes, source: source)
        }
        try fixture.journal.enqueue(mutations)
        let staged = try fixture.journal.pending().compactMap(\.attachmentSource?.fileURL)

        #expect(throws: InterruptedSegmentRotation.self) {
            try fixture.journal.acknowledge(Set(mutations.map(\.identity)))
        }
        #expect(staged.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        let retryIO = CleanupFailureController(journalURL: fixture.url)
        #expect(try fixture.cleanupJournal(retryIO).pending().isEmpty)
        #expect(retryIO.unlinkAttemptCount == mutations.count)
        #expect(retryIO.attachmentDirectorySyncCount == 1)
        let finalIO = CleanupFailureController(journalURL: fixture.url)
        #expect(try fixture.cleanupJournal(finalIO).pending().isEmpty)
        #expect(finalIO.unlinkAttemptCount == 0)
        #expect(finalIO.attachmentDirectorySyncCount == 0)
    }

    @Test func sparseCleanupMapSurvivesUntilPendingEarlierShardAllowsFrontierAdvance() throws {
        let fixture = try SegmentedJournalFixture()
        let source = fixture.directory.appendingPathComponent("sparse-cleanup-source.asset")
        let bytes = Data("sparse cleanup bytes".utf8)
        try bytes.write(to: source)
        let mutations = try (0..<129).map {
            try fixture.attachmentMutation(index: $0, bytes: bytes, source: source)
        }
        let firstIO = CleanupFailureController(journalURL: fixture.url)
        let journal = fixture.cleanupJournal(firstIO)
        try journal.enqueue(mutations)

        try journal.acknowledge([mutations[128].identity])
        #expect(firstIO.attachmentDirectorySyncCount == 1)
        let sparseRestartIO = CleanupFailureController(journalURL: fixture.url)
        let reopened = fixture.cleanupJournal(sparseRestartIO)
        #expect(try reopened.pending().count == 128)
        #expect(sparseRestartIO.attachmentDirectorySyncCount == 0)

        try reopened.acknowledge(Set(mutations.prefix(128).map(\.identity)))
        #expect(sparseRestartIO.attachmentDirectorySyncCount == 1)
        let finalIO = CleanupFailureController(journalURL: fixture.url)
        #expect(try fixture.cleanupJournal(finalIO).pending().isEmpty)
        #expect(finalIO.attachmentDirectorySyncCount == 0)
    }

    @Test(.timeLimit(.minutes(3)))
    func manyLaterCleanupShardsBehindOnePendingAttachmentStayLinear() throws {
        let fixture = try SegmentedJournalFixture()
        let source = fixture.directory.appendingPathComponent("linear-sparse-cleanup-source.asset")
        let bytes = Data("linear sparse cleanup bytes".utf8)
        try bytes.write(to: source)
        let mutationCount = 4_096
        let shardCount = mutationCount / 128
        let mutations = try (0..<mutationCount).map {
            try fixture.attachmentMutation(index: $0, bytes: bytes, source: source)
        }
        let counters = SyncJournalIOCounters()
        let cleanupIO = CleanupFailureController(journalURL: fixture.url)
        let journal = fixture.cleanupJournal(cleanupIO, counters: counters)

        try journal.enqueue(mutations)
        try journal.acknowledge(Set(mutations.dropFirst().map(\.identity)))

        #expect(try fixture.proofShardURLs().count == shardCount)
        let pending = try journal.pending()
        #expect(pending.count == 1)
        #expect(pending.first?.identity == mutations[0].identity)
        #expect(cleanupIO.attachmentDirectorySyncCount == 1)
        #expect(counters.cleanupCompletionShardUpdateCount == mutationCount - 1)
        #expect(
            counters.cleanupCompletionShardProbeCount
                <= (mutationCount - 1) * 3 + shardCount
        )
        #expect(counters.cleanupCompletionSortCount == 1)

        let restartCounters = SyncJournalIOCounters()
        let restartIO = CleanupFailureController(journalURL: fixture.url)
        let reopened = fixture.cleanupJournal(
            restartIO,
            counters: restartCounters
        )
        let restartedPending = try reopened.pending()
        #expect(restartedPending.count == 1)
        #expect(restartedPending.first?.identity == mutations[0].identity)
        #expect(restartIO.unlinkAttemptCount == 0)
        #expect(restartIO.attachmentDirectorySyncCount == 0)
        #expect(restartCounters.cleanupCompletionShardUpdateCount == mutationCount - 1)
        #expect(restartCounters.cleanupCompletionShardProbeCount <= (mutationCount - 1) * 3)
        #expect(restartCounters.cleanupCompletionSortCount == 0)

        let probesBeforeFrontierAdvance = restartCounters.cleanupCompletionShardProbeCount
        let updatesBeforeFrontierAdvance = restartCounters.cleanupCompletionShardUpdateCount
        try reopened.acknowledge([mutations[0].identity])
        for index in 0..<128 {
            let mutation = fixture.mutation(index: 1_000_000 + index)
            try reopened.enqueue(mutation)
            try reopened.acknowledge([mutation.identity])
        }

        #expect(restartCounters.cleanupCompletionSortCount == 1)
        #expect(
            restartCounters.cleanupCompletionShardUpdateCount
                - updatesBeforeFrontierAdvance == 1
        )
        #expect(
            restartCounters.cleanupCompletionShardProbeCount
                - probesBeforeFrontierAdvance <= mutationCount + 8
        )
        let finalIO = CleanupFailureController(journalURL: fixture.url)
        #expect(try fixture.cleanupJournal(finalIO).pending().isEmpty)
        #expect(finalIO.unlinkAttemptCount == 0)
        #expect(finalIO.attachmentDirectorySyncCount == 0)
    }

    @Test func interruptedProofShardPublicationLeavesSegmentReplayable() throws {
        let fixture = try SegmentedJournalFixture(failProofShardWrite: true)
        let mutations = (0..<128).map(fixture.mutation(index:))
        try fixture.journal.enqueue(mutations)

        #expect(throws: InterruptedProofShardWrite.self) {
            try fixture.journal.acknowledge(Set(mutations.map(\.identity)))
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
        let reopened = fixture.reopened()
        #expect(try reopened.pending().isEmpty)
        try reopened.enqueue(mutations[0])
        #expect(try reopened.pending().isEmpty)
    }

    @Test func referencedPartialProofShardFailsClosed() throws {
        let fixture = try SegmentedJournalFixture()
        let mutations = (0..<128).map(fixture.mutation(index:))
        try fixture.journal.enqueue(mutations)
        try fixture.journal.acknowledge(Set(mutations.map(\.identity)))
        let shard = try #require(fixture.proofShardURLs().first)
        let bytes = try Data(contentsOf: shard)
        try bytes.prefix(max(1, bytes.count / 2)).write(to: shard)

        #expect(throws: SyncMutationJournalError.corrupt) {
            _ = try fixture.reopened().pending()
        }
    }

    @Test func partialLengthPrefixAndPartialTrailerOnlyDiscardFinalFrame() throws {
        let prefixFixture = try SegmentedJournalFixture()
        let prefixMutations = [prefixFixture.mutation(index: 1), prefixFixture.mutation(index: 2)]
        try prefixFixture.journal.enqueue(prefixMutations)
        try prefixFixture.truncateLastFrameToPartialPrefix()
        #expect(try prefixFixture.reopened().pending() == [prefixMutations[0]])

        let trailerFixture = try SegmentedJournalFixture()
        let trailerMutations = [
            trailerFixture.mutation(index: 3),
            trailerFixture.mutation(index: 4)
        ]
        try trailerFixture.journal.enqueue(trailerMutations)
        try trailerFixture.truncateLastFrameToPartialTrailer()
        #expect(try trailerFixture.reopened().pending() == [trailerMutations[0]])
    }

    @Test func invalidLegacyEnvelopeLeavesBytesUntouchedAndCreatesNoNewJournal() throws {
        let fixture = try SegmentedJournalFixture()
        let legacyBytes = Data(#"{"version":2,"mutations":["invalid"]}"#.utf8)
        try legacyBytes.write(to: fixture.url)
        let inventoryBefore = try fixture.directoryInventory()

        #expect(throws: SyncMutationJournalError.corrupt) {
            _ = try fixture.journal.pending()
        }

        #expect(try Data(contentsOf: fixture.url) == legacyBytes)
        #expect(try fixture.directoryInventory() == inventoryBefore)
        #expect(!FileManager.default.fileExists(atPath: fixture.migratedURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.segmentURL.path))
    }
}

private struct InterruptedCheckpointWrite: Error {}
private struct InterruptedSegmentRotation: Error {}
private struct InterruptedProofShardWrite: Error {}
private struct FileSyncFailure: Error {}
private struct DirectorySyncFailure: Error {}
private struct CleanupUnlinkFailure: Error {}
private struct CleanupCompletionAppendFailure: Error {}

private final class SegmentedJournalFixture {
    let directory: URL
    let url: URL
    let counters: SyncJournalIOCounters
    let journal: FileSyncMutationJournal

    var checkpointURL: URL { url.appendingPathExtension("checkpoint") }
    var segmentURL: URL { url.appendingPathExtension("segment") }
    var migratedURL: URL { url.appendingPathExtension("migrated") }

    init(
        failCheckpointWrite: Bool = false,
        failSegmentRotationAfterCheckpoint: Bool = false,
        failProofShardWrite: Bool = false
    ) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-journal-segments-\(UUID().uuidString)",
            isDirectory: true
        )
        url = directory.appendingPathComponent("journal.json")
        counters = SyncJournalIOCounters()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let checkpointURL = url.appendingPathExtension("checkpoint")
        let segmentURL = url.appendingPathExtension("segment")
        journal = FileSyncMutationJournal(
            url: url,
            counters: counters,
            atomicWrite: { data, destination in
                if failCheckpointWrite, destination == checkpointURL {
                    try data.write(
                        to: destination.appendingPathExtension("interrupted"),
                        options: .withoutOverwriting
                    )
                    throw InterruptedCheckpointWrite()
                }
                if failSegmentRotationAfterCheckpoint,
                   destination == segmentURL,
                   FileManager.default.fileExists(atPath: checkpointURL.path) {
                    throw InterruptedSegmentRotation()
                }
                if failProofShardWrite,
                   destination.lastPathComponent.contains(".proofs.") {
                    try data.prefix(max(1, data.count / 2)).write(
                        to: destination.appendingPathExtension("interrupted"),
                        options: .withoutOverwriting
                    )
                    throw InterruptedProofShardWrite()
                }
                try data.write(to: destination, options: .atomic)
            }
        )
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func reopened() -> FileSyncMutationJournal {
        FileSyncMutationJournal(url: url)
    }

    func cleanupJournal(
        _ cleanupIO: CleanupFailureController,
        atomicWrite: FileSyncMutationJournal.AtomicWrite? = nil,
        appendFrames: @escaping FileSyncMutationJournal.AppendFrames = appendSegmentJournalData,
        counters: SyncJournalIOCounters = SyncJournalIOCounters()
    ) -> FileSyncMutationJournal {
        FileSyncMutationJournal(
            url: url,
            atomicWrite: atomicWrite ?? { data, destination in
                try data.write(to: destination, options: .atomic)
            },
            appendFrames: appendFrames,
            synchronizeFile: synchronizeJournalTestFile,
            synchronizeDirectory: cleanupIO.synchronizeDirectory,
            removeStagedFile: cleanupIO.removeStagedFile,
            reader: .init(),
            counters: counters,
            coordinatorRegistry: SyncJournalURLCoordinatorRegistry()
        )
    }

    func mutation(index: Int) -> SyncMutation {
        let recordID = SyncEntityID(kind: .project, uuid: deterministicUUID(index + 1))
        return .save(recordID, mutationID: deterministicUUID(index + 100_001))
    }

    func largeMutation(index: Int, marker: String) throws -> SyncMutation {
        let recordID = SyncEntityID(kind: .project, uuid: deterministicUUID(index + 1))
        let mutationID = deterministicUUID(index + 100_001)
        let stamp = SyncMutationStamp(
            logicalRevision: 1,
            modifiedAt: Date(timeIntervalSince1970: 1),
            deviceID: "segmented-proof-test"
        )
        let record = SyncRecord(
            schemaVersion: 1,
            id: recordID,
            createdAt: Date(timeIntervalSince1970: 0),
            entityRevision: 1,
            payload: SyncRecordPayload(fields: [
                "name": .init(value: .string("\(marker)-\(index)"), stamp: stamp)
            ]),
            relationships: [],
            deletedAt: .init(value: nil, stamp: stamp)
        )
        return try .save(
            recordVersion: SyncRecordVersion(record: record),
            mutationID: mutationID
        )
    }

    func attachmentMutation(index: Int, bytes: Data, source: URL) throws -> SyncMutation {
        let owner = SyncEntityID(kind: .project, uuid: deterministicUUID(index + 10_000))
        let slot = SyncAttachmentSlot(owner: owner, role: "project-photo", slotID: "cover")
        let attachment = try SyncAttachmentVersion.issuing(
            slot: slot,
            contentSHA256: Data(SHA256.hash(data: bytes)),
            byteCount: Int64(bytes.count),
            mediaType: "application/octet-stream",
            displayFilename: "private-source-name.asset"
        )
        let stamp = SyncMutationStamp(
            logicalRevision: 1,
            modifiedAt: Date(timeIntervalSince1970: 1),
            deviceID: "segmented-proof-test"
        )
        let record = SyncRecord(
            schemaVersion: 1,
            id: SyncEntityID(kind: .attachment, uuid: attachment.versionID),
            createdAt: Date(timeIntervalSince1970: 0),
            entityRevision: 1,
            payload: SyncRecordPayload(fields: [:], attachment: attachment),
            relationships: [.init(role: "owner", target: owner)],
            deletedAt: .init(value: nil, stamp: stamp)
        )
        return try .save(
            recordVersion: SyncRecordVersion(record: record),
            attachmentSource: SyncAttachmentSource(
                fileURL: source,
                contentSHA256: Data(SHA256.hash(data: bytes)),
                byteCount: Int64(bytes.count)
            ),
            mutationID: deterministicUUID(index + 100_001)
        )
    }

    func legacyEnvelope(_ mutations: [SyncMutation]) throws -> Data {
        struct LegacyEnvelope: Encodable {
            let version = 2
            let mutations: [SyncMutation]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.userInfo[.encodeLegacyStandaloneReminderForMigration] = true
        return try encoder.encode(LegacyEnvelope(mutations: mutations))
    }

    func directoryInventory() throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).sorted()
    }

    func proofShardURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".proofs.")
            && !$0.lastPathComponent.hasSuffix(".interrupted")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func expandedPersistedProofEvidence(proofURLs: [URL]) throws -> Data {
        let urls = [checkpointURL] + proofURLs
        return try urls.reduce(into: Data()) { evidence, artifactURL in
            evidence.append(try expandedJSONEvidence(Data(contentsOf: artifactURL)))
        }
    }

    private func expandedJSONEvidence(_ data: Data) throws -> Data {
        var evidence = data
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return evidence }
        func appendDecodedStrings(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                dictionary.values.forEach(appendDecodedStrings)
            } else if let array = value as? [Any] {
                array.forEach(appendDecodedStrings)
            } else if let string = value as? String,
                      let decoded = Data(base64Encoded: string),
                      !decoded.isEmpty {
                evidence.append(decoded)
                if let nested = try? JSONSerialization.jsonObject(with: decoded) {
                    appendDecodedStrings(nested)
                }
            }
        }
        appendDecodedStrings(object)
        return evidence
    }

    func truncateLastFrame() throws {
        let data = try Data(contentsOf: segmentURL)
        let ranges = try frameBodyRanges(in: data)
        let last = try #require(ranges.last)
        let truncatedCount = last.lowerBound + max(1, last.count / 2)
        try data.prefix(truncatedCount).write(to: segmentURL)
    }

    func truncateLastFrameToPartialPrefix() throws {
        let data = try Data(contentsOf: segmentURL)
        let last = try #require(frameBodyRanges(in: data).last)
        try data.prefix(last.lowerBound - 4).write(to: segmentURL)
    }

    func truncateLastFrameToPartialTrailer() throws {
        let data = try Data(contentsOf: segmentURL)
        let last = try #require(frameBodyRanges(in: data).last)
        try data.prefix(last.upperBound + 12).write(to: segmentURL)
    }

    func replaceFirstFrameChecksum(with checksum: Data) throws {
        var data = try Data(contentsOf: segmentURL)
        let firstRange = try #require(frameBodyRanges(in: data).first)
        let decoder = JSONDecoder()
        let frame = try decoder.decode(SyncJournalFrame.self, from: data[firstRange])
        let replacement = SyncJournalFrame(
            sequence: frame.sequence,
            kind: frame.kind,
            payload: frame.payload,
            checksum: checksum
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let replacementBytes = try encoder.encode(replacement)
        var replacementFrame = Data()
        var length = UInt64(replacementBytes.count).bigEndian
        withUnsafeBytes(of: &length) { replacementFrame.append(contentsOf: $0) }
        replacementFrame.append(replacementBytes)
        withUnsafeBytes(of: &length) { replacementFrame.append(contentsOf: $0) }
        replacementFrame.append(frameTrailerMagic)
        data.replaceSubrange(
            (firstRange.lowerBound - 8)..<(firstRange.upperBound + 16),
            with: replacementFrame
        )
        try data.write(to: segmentURL)
    }

    func replaceFirstFrameLengthWithRemainingFileSize() throws {
        var data = try Data(contentsOf: segmentURL)
        var corruptLength = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &corruptLength) { bytes in
            data.replaceSubrange(0..<8, with: bytes)
        }
        try data.write(to: segmentURL)
    }

    private func frameBodyRanges(in data: Data) throws -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var offset = 0
        while offset < data.count {
            guard data.count - offset >= MemoryLayout<UInt64>.size else {
                throw SyncMutationJournalError.corrupt
            }
            let length = data[offset..<(offset + 8)].reduce(UInt64(0)) {
                ($0 << 8) | UInt64($1)
            }
            let bodyStart = offset + 8
            let bodyEnd = bodyStart + Int(length)
            let trailerEnd = bodyEnd + 16
            guard trailerEnd <= data.count,
                  data[(bodyEnd + 8)..<trailerEnd] == frameTrailerMagic else {
                throw SyncMutationJournalError.corrupt
            }
            ranges.append(bodyStart..<bodyEnd)
            offset = trailerEnd
        }
        return ranges
    }

    private var frameTrailerMagic: Data {
        Data([0x4b, 0x4e, 0x4a, 0x46, 0x52, 0x4d, 0x31, 0x21])
    }
}

private final class ConcurrentJournalErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Error] = []
    func record(_ error: Error) { lock.withLock { storage.append(error) } }
    var values: [Error] { lock.withLock { storage } }
}

private final class ConcurrentJournalResults: @unchecked Sendable {
    private let lock = NSLock()
    private var mutationStorage: [[SyncMutation]] = []
    private var errorStorage: [Error] = []
    func record(_ mutations: [SyncMutation]) { lock.withLock { mutationStorage.append(mutations) } }
    func record(_ error: Error) { lock.withLock { errorStorage.append(error) } }
    var mutations: [[SyncMutation]] { lock.withLock { mutationStorage } }
    var errors: [Error] { lock.withLock { errorStorage } }
}

private final class FailOnceJournalSynchronizer: @unchecked Sendable {
    private let lock = NSLock()
    private let failure: Error
    private var attemptStorage = 0

    init(failure: Error) { self.failure = failure }

    func synchronizeFile(_ descriptor: Int32) throws {
        let shouldFail = lock.withLock { () -> Bool in
            attemptStorage += 1
            return attemptStorage == 1
        }
        if shouldFail { throw failure }
        try synchronizeJournalTestFile(descriptor)
    }

    func synchronizeDirectory(_ directory: URL) throws {
        let shouldFail = lock.withLock { () -> Bool in
            attemptStorage += 1
            return attemptStorage == 1
        }
        if shouldFail { throw failure }
        try synchronizeJournalTestDirectory(directory)
    }

    var attempts: Int { lock.withLock { attemptStorage } }
}

private final class JournalRepairRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var fileSyncStorage = 0
    private var directorySyncStorage = 0

    func synchronizeFile(_ descriptor: Int32) throws {
        lock.withLock { fileSyncStorage += 1 }
        try synchronizeJournalTestFile(descriptor)
    }

    func synchronizeDirectory(_ directory: URL) throws {
        lock.withLock { directorySyncStorage += 1 }
        try synchronizeJournalTestDirectory(directory)
    }

    var fileSyncCount: Int { lock.withLock { fileSyncStorage } }
    var directorySyncCount: Int { lock.withLock { directorySyncStorage } }
}

private final class AttachmentDirectorySyncRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let attachmentsDirectory: URL
    private var attachmentDirectorySyncStorage = 0

    init(journalURL: URL) {
        attachmentsDirectory = journalURL.deletingLastPathComponent().appendingPathComponent(
            ".\(journalURL.lastPathComponent).attachments",
            isDirectory: true
        ).standardizedFileURL
    }

    func synchronizeDirectory(_ directory: URL) throws {
        if directory.standardizedFileURL == attachmentsDirectory {
            lock.withLock { attachmentDirectorySyncStorage += 1 }
        }
        try synchronizeJournalTestDirectory(directory)
    }

    var attachmentDirectorySyncCount: Int {
        lock.withLock { attachmentDirectorySyncStorage }
    }
}

private final class CleanupFailureController: @unchecked Sendable {
    private let lock = NSLock()
    private let attachmentsDirectory: URL
    private let failingUnlinkAttempt: Int?
    private var shouldFailAttachmentDirectorySync: Bool
    private var unlinkAttemptStorage = 0
    private var attachmentDirectorySyncStorage = 0
    private var failedUnlinkFileStorage: URL?

    init(
        journalURL: URL,
        failingUnlinkAttempt: Int? = nil,
        failAttachmentDirectorySyncOnce: Bool = false
    ) {
        attachmentsDirectory = journalURL.deletingLastPathComponent().appendingPathComponent(
            ".\(journalURL.lastPathComponent).attachments",
            isDirectory: true
        ).standardizedFileURL
        self.failingUnlinkAttempt = failingUnlinkAttempt
        shouldFailAttachmentDirectorySync = failAttachmentDirectorySyncOnce
    }

    func removeStagedFile(_ file: URL) throws {
        let attempt = lock.withLock { () -> Int in
            unlinkAttemptStorage += 1
            return unlinkAttemptStorage
        }
        if attempt == failingUnlinkAttempt {
            lock.withLock { failedUnlinkFileStorage = file }
            throw CleanupUnlinkFailure()
        }
        guard file.path.withCString({ Darwin.unlink($0) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func synchronizeDirectory(_ directory: URL) throws {
        let isAttachmentDirectory = directory.standardizedFileURL == attachmentsDirectory
        let shouldFail = lock.withLock { () -> Bool in
            guard isAttachmentDirectory else { return false }
            attachmentDirectorySyncStorage += 1
            if shouldFailAttachmentDirectorySync {
                shouldFailAttachmentDirectorySync = false
                return true
            }
            return false
        }
        if shouldFail { throw DirectorySyncFailure() }
        try synchronizeJournalTestDirectory(directory)
    }

    var unlinkAttemptCount: Int { lock.withLock { unlinkAttemptStorage } }
    var failedUnlinkFile: URL? { lock.withLock { failedUnlinkFileStorage } }
    var attachmentDirectorySyncCount: Int {
        lock.withLock { attachmentDirectorySyncStorage }
    }
}

private final class FailOnceCleanupCompletionAppender: @unchecked Sendable {
    private let lock = NSLock()
    private let writeBeforeThrow: Bool
    private var appendAttempt = 0

    init(writeBeforeThrow: Bool) { self.writeBeforeThrow = writeBeforeThrow }

    func appendFrames(_ data: Data, _ destination: URL) throws {
        let fail = lock.withLock { () -> Bool in
            appendAttempt += 1
            return appendAttempt == 3
        }
        if fail {
            if writeBeforeThrow {
                try appendSegmentJournalData(data, to: destination)
            }
            throw CleanupCompletionAppendFailure()
        }
        try appendSegmentJournalData(data, to: destination)
    }
}

private func appendSegmentJournalData(_ data: Data, to destination: URL) throws {
    if !FileManager.default.fileExists(atPath: destination.path) {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw POSIXError(.EIO)
        }
    }
    let handle = try FileHandle(forWritingTo: destination)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.synchronize()
}

private func synchronizeJournalTestFile(_ descriptor: Int32) throws {
    guard Darwin.fsync(descriptor) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private func synchronizeJournalTestDirectory(_ directory: URL) throws {
    let descriptor = directory.path.withCString {
        Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { Darwin.close(descriptor) }
    try synchronizeJournalTestFile(descriptor)
}

private func deterministicUUID(_ value: Int) -> UUID {
    UUID(uuidString: String(
        format: "00000000-0000-0000-0000-%012x",
        value
    ))!
}
