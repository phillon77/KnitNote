import CryptoKit
import Darwin
import Foundation
import Testing
@testable import KnitNoteCore

@Suite(.serialized) struct SyncMutationJournalFinalFixTests {
    @Test(arguments: ["pendingVersioned", "acknowledge", "pending"])
    func oversizedPersistedSourceRejectsBeforeReadingOrAcknowledging(operation: String) throws {
        let fixture = try FinalFixJournalFixture()
        let (bytes, original) = try independentCapAttachment(fixture, byteCount: 100_000_001)
        let attachmentRoot = fixture.directory.appendingPathComponent(".journal.json.attachments")
        try FileManager.default.createDirectory(at: attachmentRoot, withIntermediateDirectories: false)
        let source = try #require(original.attachmentSource)
        let stagedURL = attachmentRoot.appendingPathComponent("\(original.mutationID.uuidString)-\(original.recordID.uuid.uuidString).asset")
        try bytes.write(to: stagedURL)
        let staged = try original.replacingAttachmentSource(.init(fileURL: stagedURL,
            contentSHA256: source.contentSHA256, byteCount: source.byteCount, isJournalStaged: true))
        let segment = try nativeIssuedAttachmentFrame(staged)
        try segment.write(to: fixture.url.appendingPathExtension("segment"))
        let before = try fixture.authorityFingerprint()
        let reads = LockedCounter()
        let io = SyncRegularFileReaderIOCounters()
        let journal = FileSyncMutationJournal(url: fixture.url,
            reader: SyncRegularFileReader(beforeRead: { reads.increment() }, ioCounters: io))
        #expect(throws: SyncMutationJournalError.invalidAttachment) {
            switch operation {
            case "acknowledge": _ = try journal.acknowledgeCurrentVersion(SyncMutationVersionToken(mutation: staged))
            case "pending": _ = try journal.pending()
            default: _ = try journal.pendingVersioned()
            }
        }
        // This fresh fixture has exactly one metadata artifact, the native
        // segment. All counted bytes beyond it would be attachment bytes.
        #expect(reads.value == 1)
        #expect(io.bytesRead - segment.count == 0)
        #expect(try fixture.authorityFingerprint() == before)
        #expect(FileManager.default.fileExists(atPath: stagedURL.path))
    }

    @Test func attachmentAtIndependentFileLimitCanScheduleAndAcknowledge() throws {
        let fixture = try FinalFixJournalFixture()
        let (bytes, original) = try independentCapAttachment(fixture, byteCount: 100_000_000)
        let journal = FileSyncMutationJournal(url: fixture.url)
        try journal.enqueue(original)
        let current = try #require(journal.pendingVersioned().first)
        let staged = try #require(current.mutation.attachmentSource?.fileURL)
        let segment = try Data(contentsOf: fixture.url.appendingPathExtension("segment"))
        // Ongoing valid control: the persisted-input fixture encoder is exactly
        // the actual native writer, including mutation/source/checksum/trailer.
        #expect(segment == (try nativeIssuedAttachmentFrame(current.mutation)))
        #expect(try Data(contentsOf: staged) == bytes)
        let io = SyncRegularFileReaderIOCounters()
        let recovery = FileSyncMutationJournal(url: fixture.url, reader: SyncRegularFileReader(ioCounters: io))
        #expect(throws: SyncMutationJournalError.tooLarge) {
            _ = try recovery.recoverySnapshot(maximumBytes: 100_000_000)
        }
        // The file fits its independent limit, but file plus journal metadata
        // exceeds explicit aggregate recovery capacity before source reading.
        #expect(io.bytesRead - segment.count == 0)
        #expect(try journal.acknowledgeCurrentVersion(current.token) == .acknowledged)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        let reopened = FileSyncMutationJournal(url: fixture.url)
        #expect(try reopened.pendingVersioned().isEmpty)
        #expect(try reopened.acknowledgeCurrentVersion(current.token) == .alreadyAcknowledged)
    }

    @Test func oversizedNewSourceRejectsBeforeReadingOrCopying() throws {
        let fixture = try FinalFixJournalFixture()
        let (bytes, original) = try independentCapAttachment(fixture, byteCount: 100_000_001)
        let reads = LockedCounter()
        let io = SyncRegularFileReaderIOCounters()
        let journal = FileSyncMutationJournal(url: fixture.url,
            reader: SyncRegularFileReader(beforeRead: { reads.increment() }, ioCounters: io))
        #expect(throws: SyncMutationJournalError.invalidAttachment) { try journal.enqueue(original) }
        #expect(reads.value == 0 && io.bytesRead == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.url.appendingPathExtension("segment").path))
        let attachmentRoot = fixture.directory.appendingPathComponent(".journal.json.attachments")
        if FileManager.default.fileExists(atPath: attachmentRoot.path) {
            #expect(try FileManager.default.contentsOfDirectory(atPath: attachmentRoot.path).isEmpty)
        }
        #expect(try Data(contentsOf: #require(original.attachmentSource).fileURL) == bytes)
    }

    @Test func ordinaryVersionedSchedulingAndACKAcceptAggregateMediaAboveJournalEncodingLimit() throws {
        let fixture = try FinalFixJournalFixture()
        var bytes = Data(repeating: 32, count: 40_000_000)
        bytes.replaceSubrange(0..<2, with: [123, 125]) // Valid JSON plus whitespace.
        let source = fixture.directory.appendingPathComponent("large-source.asset")
        try bytes.write(to: source)
        let mutations = try (0..<2).map { _ in
            try attachmentSave(slot: .init(owner: .init(kind: .project, uuid: UUID()),
                role: "project-photo", slotID: "primary"), bytes: bytes, source: source)
        }
        let journal = FileSyncMutationJournal(url: fixture.url)
        try journal.enqueue(mutations)
        // Canonical activation first performs this ordinary validation/migration.
        let pending = try journal.pending()
        #expect(pending.count == 2)
        let staged = pending.compactMap(\.attachmentSource)
        #expect(staged.map(\.byteCount).reduce(0, +) == 80_000_000)
        let segment = fixture.url.appendingPathExtension("segment")
        let before = try Data(contentsOf: segment)
        let readerCounters = SyncRegularFileReaderIOCounters()
        let observed = FileSyncMutationJournal(url: fixture.url,
            reader: SyncRegularFileReader(ioCounters: readerCounters))
        // Explicit recovery capture keeps its aggregate budget and rejects
        // before reading the second file. Ordinary read-only scheduling does not.
        #expect(throws: SyncMutationJournalError.tooLarge) {
            _ = try observed.recoverySnapshot(maximumBytes: 64 * 1_024 * 1_024)
        }
        #expect(readerCounters.bytesRead <= 64 * 1_024 * 1_024)
        #expect(try Data(contentsOf: segment) == before)
        #expect(try observed.recoverySnapshot(maximumBytes: 100_000_000).mutations == pending)
        let versioned = try journal.pendingVersioned()
        #expect(versioned.map(\.mutation) == pending)
        #expect(versioned.map(\.token.journalRevision) == [0, 0])
        #expect(try Data(contentsOf: segment) == before)
        #expect(try journal.acknowledgeCurrentVersion(versioned[0].token) == .acknowledged)
        #expect(!FileManager.default.fileExists(atPath: staged[0].fileURL.path))
        #expect(try Data(contentsOf: staged[1].fileURL) == bytes)
        let reopened = FileSyncMutationJournal(url: fixture.url)
        #expect(try reopened.pendingVersioned() == [versioned[1]])
        #expect(try reopened.acknowledgeCurrentVersion(versioned[0].token) == .alreadyAcknowledged)
        #expect(try reopened.acknowledgeCurrentVersion(versioned[1].token) == .acknowledged)
        #expect(!FileManager.default.fileExists(atPath: staged[1].fileURL.path))
        let fresh = FileSyncMutationJournal(url: fixture.url)
        #expect(try fresh.pending().isEmpty)
        #expect(try fresh.pendingVersioned().isEmpty)
        #expect(try fresh.acknowledgeCurrentVersion(versioned[1].token) == .alreadyAcknowledged)
    }

    @Test func exactVersionedACKRetryRepairsDurabilityAndCompletesCleanup() throws {
        let fixture = try FinalFixJournalFixture()
        let source = fixture.directory.appendingPathComponent("retry-source.asset")
        let bytes = Data("retry cleanup".utf8)
        try bytes.write(to: source)
        let original = try attachmentSave(slot: .init(owner: .init(kind: .project, uuid: UUID()),
            role: "project-photo", slotID: "primary"), bytes: bytes, source: source)
        let journal = FileSyncMutationJournal(url: fixture.url)
        try journal.enqueue(original)
        let current = try #require(journal.pendingVersioned().first)
        let staged = try #require(current.mutation.attachmentSource?.fileURL)
        let interrupted = FileSyncMutationJournal(url: fixture.url, appendFrames: { data, url in
            try appendFinalFixJournalData(data, to: url)
            throw FinalFixWriteThenThrow()
        })
        #expect(throws: FinalFixWriteThenThrow.self) { _ = try interrupted.acknowledgeCurrentVersion(current.token) }
        #expect(FileManager.default.fileExists(atPath: staged.path))
        let reopened = FileSyncMutationJournal(url: fixture.url)
        #expect(try reopened.acknowledgeCurrentVersion(current.token) == .alreadyAcknowledged)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func versionedAttachmentACKRemainsReadableAfterCompactedPendingSourceCleanup() throws {
        let fixture = try FinalFixJournalFixture()
        let source = fixture.directory.appendingPathComponent("versioned-source.asset")
        let bytes = Data("versioned cleanup".utf8)
        try bytes.write(to: source)
        let original = try attachmentSave(slot: .init(owner: .init(kind: .project, uuid: UUID()),
            role: "project-photo", slotID: "primary"), bytes: bytes, source: source)
        let journal = FileSyncMutationJournal(url: fixture.url)
        try journal.enqueue(original)
        // Establish v5 with a different ACK, then compact while this source is pending.
        let other = try projectSave(mutationID: UUID())
        try journal.enqueue(other)
        #expect(try journal.acknowledgeCurrentVersion(SyncMutationVersionToken(mutation: other)) == .acknowledged)
        for _ in 0..<130 {
            let mutation = try projectSave(mutationID: UUID())
            try journal.enqueue(mutation)
            try journal.acknowledge([mutation.identity])
        }
        let current = try #require(journal.pendingVersioned().first)
        let staged = try #require(current.mutation.attachmentSource?.fileURL)
        #expect(try journal.acknowledgeCurrentVersion(current.token) == .acknowledged)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        let reopened = FileSyncMutationJournal(url: fixture.url)
        #expect(try reopened.pendingVersioned().isEmpty)
        #expect(try reopened.acknowledgeCurrentVersion(current.token) == .alreadyAcknowledged)
    }

    @Test(arguments: [false, true])
    func exclusivePendingRejectsMissingOrDifferentRetainedMutationProof(differentPayload: Bool) throws {
        let fixture = try FinalFixJournalFixture()
        let original = try projectSave(mutationID: UUID())
        let journal = FileSyncMutationJournal(url: fixture.url)
        if differentPayload {
            var alteredRecord = try #require(original.savedRecordVersion?.record)
            let stamp = try #require(alteredRecord.payload.fields["name"]?.stamp)
            alteredRecord.payload.fields["name"] = .init(value: .string("Different immutable payload"), stamp: stamp)
            let altered = try SyncMutation.save(recordVersion: .init(record: alteredRecord), mutationID: original.mutationID)
            try journal.enqueue(altered)
            try journal.acknowledge([altered.identity])
        }
        let reopened = FileSyncMutationJournal(url: fixture.url)
        try reopened.withExclusivePending { lease in
            let pending = try lease.pending()
            #expect(pending.isEmpty)
            #expect(throws: SyncMutationJournalError.corrupt) {
                _ = try lease.pending(requiringRetainedProofsFor: [original])
            }
        }
    }

    @Test(arguments: [false, true])
    func exclusivePendingAcceptsRetainedAttachmentProofAfterACKAndByteCleanup(compacted: Bool) throws {
        let fixture = try FinalFixJournalFixture()
        let source = fixture.directory.appendingPathComponent("source.json")
        let bytes = Data("acknowledged immutable bytes".utf8)
        try bytes.write(to: source)
        let original = try attachmentSave(slot: .init(owner: .init(kind: .project, uuid: UUID()),
            role: "project-photo", slotID: "primary"), bytes: bytes, source: source)
        let mutations = [original] + (compacted ? try (0..<127).map { _ in try projectSave(mutationID: UUID()) } : [])
        let journal = FileSyncMutationJournal(url: fixture.url)
        try journal.enqueue(mutations)
        let predecessor = try journal.pending()
        let staged = try #require(predecessor.first?.attachmentSource?.fileURL)
        try journal.acknowledge(Set(mutations.map(\.identity)))
        if compacted {
            #expect(FileManager.default.fileExists(atPath: fixture.url.appendingPathExtension("checkpoint").path))
        }
        try FileManager.default.removeItem(at: source)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        let reopened = FileSyncMutationJournal(url: fixture.url)
        try reopened.withExclusivePending { lease in
            let pending = try lease.pending(requiringRetainedProofsFor: predecessor)
            #expect(pending.isEmpty)
        }
    }

    @Test func saveReplaceRestoreBytesRestartRetainsEachImmutableRecordAndStagedBytes() throws {
        let fixture = try FinalFixJournalFixture()
        let owner = SyncEntityID(kind: .patternUsage, uuid: UUID())
        let slot = SyncAttachmentSlot(owner: owner, role: "usage-markup", slotID: "page:2")
        let source = fixture.directory.appendingPathComponent("mutable-page.json")
        let firstBytes = Data("first markup version".utf8)
        let secondBytes = Data("second markup version".utf8)

        try firstBytes.write(to: source)
        let first = try attachmentSave(slot: slot, bytes: firstBytes, source: source)
        let journal = FileSyncMutationJournal(url: fixture.url)
        try journal.enqueue(first)

        try secondBytes.write(to: source, options: .atomic)
        let second = try attachmentSave(
            slot: slot,
            bytes: secondBytes,
            source: source,
            replacing: try #require(first.savedRecordVersion?.record.payload.attachment?.versionID)
        )
        try journal.enqueue(second)
        try firstBytes.write(to: source, options: .atomic)
        let third = try attachmentSave(
            slot: slot,
            bytes: firstBytes,
            source: source,
            replacing: try #require(second.savedRecordVersion?.record.payload.attachment?.versionID)
        )
        try journal.enqueue(third)
        let savedRecordVersions = try [first, second, third].map {
            try #require($0.savedRecordVersion)
        }

        try FileManager.default.removeItem(at: source)
        let reopened = FileSyncMutationJournal(url: fixture.url)
        let pending = try reopened.pending()

        #expect(pending.count == 3)
        #expect(pending.map(\.intent) == [.save, .save, .save])
        #expect(pending.compactMap(\.savedRecordVersion) == savedRecordVersions)
        #expect(pending[0].savedRecordVersion?.versionID != pending[1].savedRecordVersion?.versionID)
        #expect(pending[1].savedRecordVersion?.record.payload.attachment?.replacesVersionID
            == pending[0].savedRecordVersion?.record.payload.attachment?.versionID)
        #expect(pending[2].savedRecordVersion?.record.payload.attachment?.versionID
            != pending[0].savedRecordVersion?.record.payload.attachment?.versionID)
        #expect(pending[2].savedRecordVersion?.record.payload.attachment?.replacesVersionID
            == pending[1].savedRecordVersion?.record.payload.attachment?.versionID)
        #expect(try pending[0].stagedAttachmentBytes() == firstBytes)
        #expect(try pending[1].stagedAttachmentBytes() == secondBytes)
        #expect(try pending[2].stagedAttachmentBytes() == firstBytes)
    }

    @Test func duplicateMutationIDAfterWriteThenThrowIsIdempotentWithoutSecondFrame() throws {
        let fixture = try FinalFixJournalFixture()
        let mutation = try projectSave(mutationID: UUID())
        let writes = LockedCounter()
        let uncertain = FileSyncMutationJournal(url: fixture.url, appendFrames: { data, url in
            writes.increment()
            try appendFinalFixJournalData(data, to: url)
            throw FinalFixWriteThenThrow()
        })

        #expect(throws: FinalFixWriteThenThrow.self) {
            try uncertain.enqueue(mutation)
        }
        #expect(try uncertain.pending() == [mutation])

        try uncertain.enqueue(mutation)
        #expect(writes.value == 1)
        #expect(try uncertain.pending() == [mutation])
        #expect(try FileSyncMutationJournal(url: fixture.url).pending() == [mutation])
    }

    @Test func attachmentRetryWithOriginalSourceMatchesItsStagedMutationIdentity() throws {
        let fixture = try FinalFixJournalFixture()
        let source = fixture.directory.appendingPathComponent("retry.jpg")
        let bytes = Data("immutable attachment".utf8)
        try bytes.write(to: source)
        let mutationID = UUID()
        let mutation = try attachmentSave(
            slot: .init(
                owner: .init(kind: .project, uuid: UUID()),
                role: "project-photo",
                slotID: "primary"
            ),
            bytes: bytes,
            source: source,
            mutationID: mutationID
        )
        let journal = FileSyncMutationJournal(url: fixture.url)

        try journal.enqueue(mutation)
        try journal.enqueue(mutation)

        let pending = try journal.pending()
        #expect(pending.count == 1)
        #expect(pending.first?.mutationID == mutationID)
        #expect(pending.first?.attachmentSource?.isJournalStaged == true)
        #expect(try pending.first?.stagedAttachmentBytes() == bytes)
    }

    @Test func restartRejectsSameSizedCorruptionOfStagedAttachmentBytes() throws {
        let fixture = try FinalFixJournalFixture()
        let source = fixture.directory.appendingPathComponent("digest-source.jpg")
        let originalBytes = Data("original-bytes".utf8)
        let corruptBytes = Data("corrupted-data".utf8)
        #expect(originalBytes.count == corruptBytes.count)
        try originalBytes.write(to: source)
        let mutation = try attachmentSave(
            slot: .init(
                owner: .init(kind: .project, uuid: UUID()),
                role: "project-photo",
                slotID: "primary"
            ),
            bytes: originalBytes,
            source: source
        )
        let journal = FileSyncMutationJournal(url: fixture.url)
        try journal.enqueue(mutation)
        let stagedURL = try #require(journal.pending().first?.attachmentSource?.fileURL)
        try corruptBytes.write(to: stagedURL)

        #expect(throws: SyncMutationJournalError.invalidAttachment) {
            _ = try FileSyncMutationJournal(url: fixture.url).pending()
        }
    }

    @Test func sameMutationIDWithDifferentIntentIsRejectedWithoutReplacingJournal() throws {
        let fixture = try FinalFixJournalFixture()
        let mutationID = UUID()
        let save = try projectSave(mutationID: mutationID)
        let journal = FileSyncMutationJournal(url: fixture.url)
        try journal.enqueue(save)
        let segmentURL = fixture.url.appendingPathExtension("segment")
        let committedBytes = try Data(contentsOf: segmentURL)

        #expect(throws: SyncMutationJournalError.duplicateMutationID) {
            try journal.enqueue(.delete(save.recordID, mutationID: mutationID))
        }
        #expect(try journal.pending() == [save])
        #expect(try Data(contentsOf: segmentURL) == committedBytes)
    }

    @Test func symlinkJournalIsRejectedWithoutFollowingTarget() throws {
        let fixture = try FinalFixJournalFixture()
        let target = fixture.directory.appendingPathComponent("target.json")
        let targetBytes = Data("private target".utf8)
        try targetBytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.url, withDestinationURL: target)

        #expect(throws: SyncMutationJournalError.unsafeFile) {
            _ = try FileSyncMutationJournal(url: fixture.url).pending()
        }
        #expect(try Data(contentsOf: target) == targetBytes)
    }

    @Test func fifoJournalIsRejectedWithoutBlocking() throws {
        let fixture = try FinalFixJournalFixture()
        #expect(fixture.url.path.withCString { Darwin.mkfifo($0, S_IRUSR | S_IWUSR) } == 0)

        #expect(throws: SyncMutationJournalError.unsafeFile) {
            _ = try FileSyncMutationJournal(url: fixture.url).pending()
        }
    }

    @Test func journalAdapterMapsPathReplacementToUnsafeFile() throws {
        let fixture = try FinalFixJournalFixture()
        let url = fixture.url
        try Data(#"{"version":2,"mutations":[]}"#.utf8).write(to: url)
        let reader = SyncRegularFileReader(beforeOpen: {
            try FileManager.default.removeItem(at: url)
            try Data(#"{"version":2,"mutations":[]}"#.utf8).write(to: url)
        })
        let journal = FileSyncMutationJournal(url: url, reader: reader)

        #expect(throws: SyncMutationJournalError.unsafeFile) {
            _ = try journal.pending()
        }
    }

    @Test(.timeLimit(.minutes(1))) func restartRejectsFifoStagedAttachmentWithoutBlocking() throws {
        let fixture = try FinalFixJournalFixture()
        let source = fixture.directory.appendingPathComponent("source.json")
        let bytes = Data("immutable staged attachment".utf8)
        try bytes.write(to: source)
        let mutation = try attachmentSave(
            slot: .init(
                owner: .init(kind: .project, uuid: UUID()),
                role: "project-photo",
                slotID: "primary"
            ),
            bytes: bytes,
            source: source
        )
        let journal = FileSyncMutationJournal(url: fixture.url)
        try journal.enqueue(mutation)
        let staged = try #require(journal.pending().first?.attachmentSource?.fileURL)
        try FileManager.default.removeItem(at: staged)
        #expect(staged.path.withCString { Darwin.mkfifo($0, S_IRUSR | S_IWUSR) } == 0)

        #expect(throws: SyncMutationJournalError.unsafeFile) {
            _ = try FileSyncMutationJournal(url: fixture.url).pending()
        }
    }

    @Test func oversizedJournalIsRejectedBeforeReadingPayload() throws {
        let fixture = try FinalFixJournalFixture()
        #expect(FileManager.default.createFile(atPath: fixture.url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: fixture.url)
        try handle.truncate(atOffset: UInt64(FileSyncMutationJournal.maximumEncodedBytes + 1))
        try handle.close()

        #expect(throws: SyncMutationJournalError.tooLarge) {
            _ = try FileSyncMutationJournal(url: fixture.url).pending()
        }
    }

    @Test func batchEnqueueAndPartialAcknowledgementEachPersistOnce() throws {
        let fixture = try FinalFixJournalFixture()
        let writes = LockedCounter()
        let journal = FileSyncMutationJournal(url: fixture.url, appendFrames: { data, url in
            writes.increment()
            try appendFinalFixJournalData(data, to: url)
        })
        let mutations = try (0..<2_000).map { index in
            try projectSave(
                recordID: SyncEntityID(
                    kind: .project,
                    uuid: deterministicTestUUID(index)
                ),
                mutationID: deterministicTestUUID(index + 10_000)
            )
        }
        let clock = ContinuousClock()
        let started = clock.now

        try journal.enqueue(mutations)
        try journal.acknowledge(Set(mutations.prefix(1_000).map(\.identity)))

        #expect(writes.value == 2)
        #expect(try journal.pending().count == 1_000)
        #expect(started.duration(to: clock.now) < .seconds(3))
    }

    @Test func restartFinishesStagedAttachmentCleanupAfterDurablePartialAckFailure() throws {
        let fixture = try FinalFixJournalFixture()
        let firstSource = fixture.directory.appendingPathComponent("first-cleanup.json")
        let secondSource = fixture.directory.appendingPathComponent("second-cleanup.json")
        let firstBytes = Data("first cleanup".utf8)
        let secondBytes = Data("second cleanup".utf8)
        try firstBytes.write(to: firstSource)
        try secondBytes.write(to: secondSource)
        let owner = SyncEntityID(kind: .project, uuid: UUID())
        let first = try attachmentSave(
            slot: .init(owner: owner, role: "project-photo", slotID: "first"),
            bytes: firstBytes,
            source: firstSource
        )
        let second = try attachmentSave(
            slot: .init(owner: owner, role: "project-photo", slotID: "second"),
            bytes: secondBytes,
            source: secondSource
        )
        let journal = FileSyncMutationJournal(url: fixture.url)
        try journal.enqueue([first, second])
        let pending = try journal.pending()
        let firstStaged = try #require(pending[0].attachmentSource?.fileURL)
        let secondStaged = try #require(pending[1].attachmentSource?.fileURL)
        let interrupted = FileSyncMutationJournal(url: fixture.url, appendFrames: { data, url in
            try appendFinalFixJournalData(data, to: url)
            throw FinalFixWriteThenThrow()
        })

        #expect(throws: FinalFixWriteThenThrow.self) {
            try interrupted.acknowledge([pending[0].identity])
        }
        #expect(FileManager.default.fileExists(atPath: firstStaged.path))
        #expect(FileManager.default.fileExists(atPath: secondStaged.path))

        let reopened = FileSyncMutationJournal(url: fixture.url)
        #expect(try reopened.pending() == [pending[1]])
        #expect(!FileManager.default.fileExists(atPath: firstStaged.path))
        #expect(FileManager.default.fileExists(atPath: secondStaged.path))
        try reopened.acknowledge([pending[0].identity])
        #expect(!FileManager.default.fileExists(atPath: firstStaged.path))
    }
}

private struct FinalFixWriteThenThrow: Error {}

private func appendFinalFixJournalData(_ data: Data, to destination: URL) throws {
    if !FileManager.default.fileExists(atPath: destination.path) {
        #expect(FileManager.default.createFile(atPath: destination.path, contents: nil))
    }
    let handle = try FileHandle(forWritingTo: destination)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.synchronize()
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    func increment() { lock.withLock { storage += 1 } }
    var value: Int { lock.withLock { storage } }
}

private final class FinalFixJournalFixture {
    let directory: URL
    let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-journal-final-fix-\(UUID().uuidString)",
            isDirectory: true
        )
        url = directory.appendingPathComponent("journal.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func authorityFingerprint() throws -> [String: String] {
        let files = try #require(FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]))
        var result: [String: String] = [:]
        for case let file as URL in files {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            let digest = values.isRegularFile == true
                ? Data(SHA256.hash(data: try Data(contentsOf: file))).base64EncodedString() : "directory"
            result[file.path] = "\(attrs[.systemFileNumber]!)|\(attrs[.size]!)|\(digest)"
        }
        return result
    }
}

private func independentCapAttachment(_ fixture: FinalFixJournalFixture, byteCount: Int) throws -> (Data, SyncMutation) {
    var bytes = Data(repeating: 32, count: byteCount)
    bytes.replaceSubrange(0..<2, with: [123, 125]) // Valid JSON with a real matching digest.
    let source = fixture.directory.appendingPathComponent("independent-cap.json")
    try bytes.write(to: source)
    return (bytes, try attachmentSave(slot: .init(owner: .init(kind: .project, uuid: UUID()),
        role: "project-photo", slotID: "primary"), bytes: bytes, source: source))
}

// Native kind-1 format from c94d109's makeFrame/encodeFrames. Before the cap fix,
// this helper was byte-compared with its actual 100,000,001-byte enqueue output.
// It reconstructs that formerly accepted persisted input without bypassing any
// production guard. The exact 100,000,000-byte control compares it with today's
// actual native writer. Full staged mutation authority, not a fake hash, is used.
private func nativeIssuedAttachmentFrame(_ mutation: SyncMutation) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(mutation)
    var sequence = UInt64(1).bigEndian
    var material = Data([1])
    withUnsafeBytes(of: &sequence) { material.append(contentsOf: $0) }
    material.append(SyncJournalFrameKind.enqueue.rawValue)
    material.append(payload)
    let frame = SyncJournalFrame(sequence: 1, kind: .enqueue, payload: payload,
        checksum: Data(SHA256.hash(data: material)))
    let body = try encoder.encode(frame)
    var length = UInt64(body.count).bigEndian
    var segment = Data()
    withUnsafeBytes(of: &length) { segment.append(contentsOf: $0) }
    segment.append(body)
    withUnsafeBytes(of: &length) { segment.append(contentsOf: $0) }
    segment.append(Data([0x4b, 0x4e, 0x4a, 0x46, 0x52, 0x4d, 0x31, 0x21]))
    return segment
}

private func projectSave(
    recordID: SyncEntityID = SyncEntityID(kind: .project, uuid: UUID()),
    mutationID: UUID
) throws -> SyncMutation {
    let stamp = SyncMutationStamp(
        logicalRevision: 1,
        modifiedAt: Date(timeIntervalSince1970: 1),
        deviceID: "journal-test"
    )
    let record = SyncRecord(
        schemaVersion: 1,
        id: recordID,
        createdAt: Date(timeIntervalSince1970: 0),
        entityRevision: 1,
        payload: SyncRecordPayload(fields: [
            "name": .init(value: .string(recordID.uuid.uuidString), stamp: stamp)
        ]),
        relationships: [],
        deletedAt: .init(value: nil, stamp: stamp)
    )
    return try .save(recordVersion: SyncRecordVersion(record: record), mutationID: mutationID)
}

private func attachmentSave(
    slot: SyncAttachmentSlot,
    bytes: Data,
    source: URL,
    replacing: UUID? = nil,
    mutationID: UUID = UUID()
) throws -> SyncMutation {
    let digest = Data(SHA256.hash(data: bytes))
    let attachment = try SyncAttachmentVersion.issuing(
        slot: slot,
        contentSHA256: digest,
        byteCount: Int64(bytes.count),
        mediaType: "application/json",
        displayFilename: "markup.json",
        replacesVersionID: replacing
    )
    let stamp = SyncMutationStamp(
        logicalRevision: 1,
        modifiedAt: Date(timeIntervalSince1970: 1),
        deviceID: "journal-test"
    )
    let record = SyncRecord(
        schemaVersion: 1,
        id: SyncEntityID(kind: .attachment, uuid: attachment.versionID),
        createdAt: Date(timeIntervalSince1970: 1),
        entityRevision: 1,
        payload: SyncRecordPayload(fields: [:], attachment: attachment),
        relationships: [.init(role: "owner", target: slot.owner)],
        deletedAt: .init(value: nil, stamp: stamp)
    )
    let source = try SyncAttachmentSource(
        fileURL: source,
        contentSHA256: digest,
        byteCount: Int64(bytes.count)
    )
    return try .save(
        recordVersion: SyncRecordVersion(record: record),
        attachmentSource: source,
        mutationID: mutationID
    )
}

private extension SyncMutation {
    func stagedAttachmentBytes() throws -> Data? {
        guard let source = attachmentSource else { return nil }
        #expect(source.isJournalStaged)
        return try Data(contentsOf: source.fileURL)
    }
}

private func deterministicTestUUID(_ value: Int) -> UUID {
    let suffix = String(format: "%012x", value)
    return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
}
