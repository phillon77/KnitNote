import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct SyncMutationJournalTests {
    @Test func journalSurvivesRestartAndAcknowledgesOnlyExactMutation() throws {
        let fixture = try SyncMutationJournalFixture()
        let firstID = SyncEntityID(
            kind: .project,
            uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let secondID = SyncEntityID(
            kind: .yarn,
            uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        let firstMutationID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let secondMutationID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!

        let first = FileSyncMutationJournal(url: fixture.url)
        try first.enqueue(.save(firstID, mutationID: firstMutationID))
        try first.enqueue(.delete(secondID, mutationID: secondMutationID))

        let reopened = FileSyncMutationJournal(url: fixture.url)
        #expect(try reopened.pending() == [
            .save(firstID, mutationID: firstMutationID),
            .delete(secondID, mutationID: secondMutationID)
        ])

        try reopened.acknowledge(recordID: firstID, mutationID: secondMutationID)
        try reopened.acknowledge(recordID: secondID, mutationID: firstMutationID)
        #expect(try reopened.pending().count == 2)

        try reopened.acknowledge(recordID: firstID, mutationID: firstMutationID)
        #expect(try reopened.pending() == [.delete(secondID, mutationID: secondMutationID)])
        #expect(try FileSyncMutationJournal(url: fixture.url).pending() == [
            .delete(secondID, mutationID: secondMutationID)
        ])
    }

    @Test func corruptJournalThrowsWithoutReplacingOriginalBytes() throws {
        let fixture = try SyncMutationJournalFixture()
        let corruptBytes = Data("not a mutation journal".utf8)
        try corruptBytes.write(to: fixture.url)
        let journal = FileSyncMutationJournal(url: fixture.url)
        let recordID = SyncEntityID(kind: .project, uuid: UUID())

        #expect(throws: SyncMutationJournalError.corrupt) {
            _ = try journal.pending()
        }
        #expect(throws: SyncMutationJournalError.corrupt) {
            try journal.enqueue(.save(recordID, mutationID: UUID()))
        }
        #expect(try Data(contentsOf: fixture.url) == corruptBytes)
    }

    @Test func unsupportedEnvelopeVersionIsCorruptAndPreserved() throws {
        let fixture = try SyncMutationJournalFixture()
        let unsupportedBytes = Data(#"{"version":3,"mutations":[]}"#.utf8)
        try unsupportedBytes.write(to: fixture.url)

        #expect(throws: SyncMutationJournalError.corrupt) {
            _ = try FileSyncMutationJournal(url: fixture.url).pending()
        }
        #expect(try Data(contentsOf: fixture.url) == unsupportedBytes)
    }

    @Test func interruptedAcknowledgementKeepsMemoryAndLastCommittedFile() throws {
        let fixture = try SyncMutationJournalFixture()
        let recordID = SyncEntityID(
            kind: .projectCounter,
            uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        )
        let mutationID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let original = SyncMutation.save(recordID, mutationID: mutationID)
        let committed = FileSyncMutationJournal(url: fixture.url)
        try committed.enqueue(original)

        let interrupted = FileSyncMutationJournal(
            url: fixture.url,
            atomicWrite: { _, _ in throw SyncMutationJournalWriteInterruption() }
        )
        #expect(throws: SyncMutationJournalWriteInterruption.self) {
            try interrupted.acknowledge(recordID: recordID, mutationID: mutationID)
        }

        #expect(try interrupted.pending() == [original])
        #expect(try FileSyncMutationJournal(url: fixture.url).pending() == [original])
    }

    @Test func enqueueReconcilesCommittedBytesAfterParentSyncFailure() throws {
        let fixture = try SyncMutationJournalFixture()
        let recordID = SyncEntityID(
            kind: .project,
            uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        )
        let first = SyncMutation.save(
            recordID,
            mutationID: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
        )
        let second = SyncMutation.save(
            recordID,
            mutationID: UUID(uuidString: "10000000-0000-0000-0000-000000000005")!
        )
        let journal = FileSyncMutationJournal(
            url: fixture.url,
            synchronizeDirectory: { _ in throw SyncMutationJournalParentSyncFailure() }
        )

        #expect(throws: SyncMutationJournalParentSyncFailure.self) {
            try journal.enqueue(first)
        }
        #expect(try journal.pending() == [first])

        #expect(throws: SyncMutationJournalParentSyncFailure.self) {
            try journal.enqueue(second)
        }
        #expect(try journal.pending() == [first, second])
        #expect(try FileSyncMutationJournal(url: fixture.url).pending() == [first, second])
    }

    @Test func acknowledgementReconcilesCommittedBytesAfterParentSyncFailure() throws {
        let fixture = try SyncMutationJournalFixture()
        let recordID = SyncEntityID(
            kind: .yarn,
            uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        )
        let originalMutationID = UUID(
            uuidString: "10000000-0000-0000-0000-000000000006"
        )!
        let original = SyncMutation.delete(recordID, mutationID: originalMutationID)
        try FileSyncMutationJournal(url: fixture.url).enqueue(original)

        let journal = FileSyncMutationJournal(
            url: fixture.url,
            synchronizeDirectory: { _ in throw SyncMutationJournalParentSyncFailure() }
        )
        #expect(try journal.pending() == [original])
        #expect(throws: SyncMutationJournalParentSyncFailure.self) {
            try journal.acknowledge(recordID: recordID, mutationID: originalMutationID)
        }
        #expect(try journal.pending().isEmpty)

        let replacement = SyncMutation.save(
            recordID,
            mutationID: UUID(uuidString: "10000000-0000-0000-0000-000000000007")!
        )
        #expect(throws: SyncMutationJournalParentSyncFailure.self) {
            try journal.enqueue(replacement)
        }
        #expect(try journal.pending() == [replacement])
        #expect(try FileSyncMutationJournal(url: fixture.url).pending() == [replacement])
    }
}

private struct SyncMutationJournalWriteInterruption: Error {}
private struct SyncMutationJournalParentSyncFailure: Error {}

private final class SyncMutationJournalFixture {
    let directory: URL
    let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "sync-mutation-journal-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        url = directory.appendingPathComponent("journal.json")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

extension SyncMutation {
    static func save(_ recordID: SyncEntityID, mutationID: UUID) -> SyncMutation {
        let stamp = SyncMutationStamp(
            logicalRevision: 1,
            modifiedAt: Date(timeIntervalSince1970: 1),
            deviceID: "legacy-test-fixture"
        )
        let payload: SyncRecordPayload
        let relationships: [SyncRelationship]
        if recordID.kind == .projectCounter {
            let counter = ProjectCounter(
                id: recordID.uuid,
                defaultOrdinal: 1,
                mutationRevision: 1
            )
            payload = SyncRecordPayload(
                fields: [:],
                atomicDomain: .init(
                    value: .projectCounter(SyncCounterReminderState(
                        counter: counter,
                        reminder: nil,
                        preparedCommand: nil,
                        processedCommandIDs: [],
                        occurrence: nil
                    )),
                    stamp: stamp
                )
            )
            relationships = [.init(
                role: "project",
                target: .init(kind: .project, uuid: UUID())
            )]
        } else {
            payload = SyncRecordPayload(fields: [:])
            relationships = []
        }
        let record = SyncRecord(
            schemaVersion: 1,
            id: recordID,
            createdAt: Date(timeIntervalSince1970: 0),
            entityRevision: 1,
            payload: payload,
            relationships: relationships,
            deletedAt: .init(value: nil, stamp: stamp)
        )
        return try! .save(
            recordVersion: SyncRecordVersion(record: record),
            mutationID: mutationID
        )
    }
}
