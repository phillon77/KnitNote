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

    @Test func invalidLegacyEnvelopeLeavesBytesUntouchedAndCreatesNoNewJournal() throws {
        let fixture = try SegmentedJournalFixture()
        let legacyBytes = Data(#"{"version":2,"mutations":["invalid"]}"#.utf8)
        try legacyBytes.write(to: fixture.url)

        #expect(throws: SyncMutationJournalError.corrupt) {
            _ = try fixture.journal.pending()
        }

        #expect(try Data(contentsOf: fixture.url) == legacyBytes)
        #expect(!FileManager.default.fileExists(atPath: fixture.migratedURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.segmentURL.path))
    }
}

private struct InterruptedCheckpointWrite: Error {}

private final class SegmentedJournalFixture {
    let directory: URL
    let url: URL
    let counters: SyncJournalIOCounters
    let journal: FileSyncMutationJournal

    var checkpointURL: URL { url.appendingPathExtension("checkpoint") }
    var segmentURL: URL { url.appendingPathExtension("segment") }
    var migratedURL: URL { url.appendingPathExtension("migrated") }

    init(failCheckpointWrite: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-journal-segments-\(UUID().uuidString)",
            isDirectory: true
        )
        url = directory.appendingPathComponent("journal.json")
        counters = SyncJournalIOCounters()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let checkpointURL = url.appendingPathExtension("checkpoint")
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
                try data.write(to: destination, options: .atomic)
            }
        )
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func reopened() -> FileSyncMutationJournal {
        FileSyncMutationJournal(url: url)
    }

    func mutation(index: Int) -> SyncMutation {
        let recordID = SyncEntityID(kind: .project, uuid: deterministicUUID(index + 1))
        return .save(recordID, mutationID: deterministicUUID(index + 100_001))
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

    func truncateLastFrame() throws {
        let data = try Data(contentsOf: segmentURL)
        let ranges = try frameBodyRanges(in: data)
        let last = try #require(ranges.last)
        let truncatedCount = last.lowerBound + max(1, last.count / 2)
        try data.prefix(truncatedCount).write(to: segmentURL)
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

private func deterministicUUID(_ value: Int) -> UUID {
    UUID(uuidString: String(
        format: "00000000-0000-0000-0000-%012x",
        value
    ))!
}
