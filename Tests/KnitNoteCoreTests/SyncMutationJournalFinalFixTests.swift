import CryptoKit
import Darwin
import Foundation
import Testing
@testable import KnitNoteCore

@Suite(.serialized) struct SyncMutationJournalFinalFixTests {
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

        try FileManager.default.removeItem(at: source)
        let reopened = FileSyncMutationJournal(url: fixture.url)
        let pending = try reopened.pending()

        #expect(pending.count == 3)
        #expect(pending.map(\.intent) == [.save, .save, .save])
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

    @Test func duplicateMutationIDAfterWriteThenThrowIsIdempotentAndRepersisted() throws {
        let fixture = try FinalFixJournalFixture()
        let mutation = try projectSave(mutationID: UUID())
        let writes = LockedCounter()
        let uncertain = FileSyncMutationJournal(url: fixture.url, atomicWrite: { data, url in
            writes.increment()
            try data.write(to: url, options: .atomic)
            throw FinalFixWriteThenThrow()
        })

        #expect(throws: FinalFixWriteThenThrow.self) {
            try uncertain.enqueue(mutation)
        }
        #expect(try uncertain.pending() == [mutation])

        #expect(throws: FinalFixWriteThenThrow.self) {
            try uncertain.enqueue(mutation)
        }
        #expect(writes.value == 2)
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
        let committedBytes = try Data(contentsOf: fixture.url)

        #expect(throws: SyncMutationJournalError.duplicateMutationID) {
            try journal.enqueue(.delete(save.recordID, mutationID: mutationID))
        }
        #expect(try journal.pending() == [save])
        #expect(try Data(contentsOf: fixture.url) == committedBytes)
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
        let journal = FileSyncMutationJournal(url: fixture.url, atomicWrite: { data, url in
            writes.increment()
            try data.write(to: url, options: .atomic)
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
}

private struct FinalFixWriteThenThrow: Error {}

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
