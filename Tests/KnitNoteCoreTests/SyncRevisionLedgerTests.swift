import Foundation
import Dispatch
import Testing
@testable import KnitNoteCore

struct SyncRevisionLedgerTests {
    @Test func legacySingleRequestAllocatorGetsCompatibleBatchAdapter() throws {
        let allocator: any SyncRevisionAllocating = LegacySingleRequestAllocator()
        let entity = SyncEntityID(kind: .project, uuid: UUID())
        let requests = [
            SyncRevisionRequest(
                entityID: entity,
                mutationID: UUID(),
                observedRemoteRevision: 4
            ),
            SyncRevisionRequest(
                entityID: entity,
                mutationID: UUID(),
                observedRemoteRevision: 8
            ),
        ]

        let receipts = try allocator.allocate(requests)

        #expect(receipts.map(\.logicalRevision) == [5, 9])
    }

    @Test func batchAllocationUsesOneDurableWriteAndReturnsCausalReceipts() throws {
        let fixture = try RevisionLedgerFixture()
        defer { fixture.remove() }
        let counters = SyncRevisionLedgerIOCounters()
        let ledger = SyncRevisionLedger(
            url: fixture.url,
            deviceID: "installation-A",
            counters: counters
        )
        let entity = SyncEntityID(kind: .project, uuid: UUID())
        let requests = (0..<1_000).map { index in
            SyncRevisionRequest(
                entityID: entity,
                mutationID: UUID(),
                observedRemoteRevision: UInt64(index)
            )
        }

        let receipts = try ledger.allocate(requests)

        #expect(counters.durableWriteCount == 1)
        #expect(receipts.map(\.logicalRevision) == Array(1...1_000).map(UInt64.init))
        #expect(Set(receipts.map(\.mutationID)).count == requests.count)
    }

    @Test func nextBatchCompactsOldReceiptsButPreservesHeadAndRequestedRetry() throws {
        let fixture = try RevisionLedgerFixture()
        defer { fixture.remove() }
        let entity = SyncEntityID(kind: .project, uuid: UUID())
        let firstRequests = (0..<5_000).map { index in
            SyncRevisionRequest(
                entityID: entity,
                mutationID: deterministicLedgerUUID(index),
                observedRemoteRevision: UInt64(index)
            )
        }
        let first = try fixture.ledger.allocate(firstRequests)
        let retried = first[123]
        let nextRequest = SyncRevisionRequest(
            entityID: entity,
            mutationID: UUID(),
            observedRemoteRevision: first.last!.logicalRevision
        )

        let second = try fixture.ledger.allocate([
            firstRequests[123],
            nextRequest,
        ])

        #expect(second[0] == retried)
        #expect(second[1].logicalRevision == first.last!.logicalRevision + 1)
        #expect(try Data(contentsOf: fixture.url).count < 10_000)
    }

    @Test func newMutationIncrementsAndRetryReusesReceipt() throws {
        let fixture = try RevisionLedgerFixture()
        defer { fixture.remove() }
        let ledger = fixture.ledger
        let entity = SyncEntityID(kind: .project, uuid: UUID())
        let firstID = UUID()

        let first = try ledger.allocate(
            for: entity,
            mutationID: firstID,
            observedRemoteRevision: 0
        )
        let retry = try ledger.allocate(
            for: entity,
            mutationID: firstID,
            observedRemoteRevision: 999
        )
        let second = try ledger.allocate(
            for: entity,
            mutationID: UUID(),
            observedRemoteRevision: 25
        )

        #expect(first == retry)
        #expect(second.logicalRevision == 26)
        #expect(second.logicalRevision > first.logicalRevision)
    }

    @Test func restartReusesPersistedReceiptAndAdvancesFromObservedRemoteRevision() throws {
        let fixture = try RevisionLedgerFixture(installationID: "installation-A")
        defer { fixture.remove() }
        let entity = SyncEntityID(kind: .project, uuid: UUID())
        let mutationID = UUID()
        let first = try fixture.ledger.allocate(
            for: entity,
            mutationID: mutationID,
            observedRemoteRevision: 0
        )
        let restarted = SyncRevisionLedger(url: fixture.url, deviceID: "installation-A")
        let retry = try restarted.allocate(
            for: entity,
            mutationID: mutationID,
            observedRemoteRevision: UInt64.max
        )
        let next = try restarted.allocate(
            for: entity,
            mutationID: UUID(),
            observedRemoteRevision: 88
        )

        #expect(retry == first)
        #expect(next.logicalRevision == 89)
    }

    @Test func twoInstallationsAtTheSameArchivePathUseDifferentDeviceIDs() throws {
        let a = try RevisionLedgerFixture(installationID: "A")
        let b = try RevisionLedgerFixture(installationID: "B")
        defer {
            a.remove()
            b.remove()
        }
        let entity = SyncEntityID(kind: .project, uuid: UUID())

        let aReceipt = try a.ledger.allocate(for: entity, mutationID: UUID(), observedRemoteRevision: 0)
        let bReceipt = try b.ledger.allocate(for: entity, mutationID: UUID(), observedRemoteRevision: 0)
        #expect(aReceipt.deviceID != bReceipt.deviceID)
    }

    @Test func maximumRevisionFailsWithoutWritingANewReceipt() throws {
        let fixture = try RevisionLedgerFixture()
        defer { fixture.remove() }
        let entity = SyncEntityID(kind: .project, uuid: UUID())
        let bytesBefore = try? Data(contentsOf: fixture.url)

        #expect(throws: SyncRevisionLedgerError.revisionExhausted) {
            _ = try fixture.ledger.allocate(
                for: entity,
                mutationID: UUID(),
                observedRemoteRevision: .max
            )
        }
        #expect((try? Data(contentsOf: fixture.url)) == bytesBefore)
    }

    @Test func zeroRevisionReceiptAndFloorAreRejectedDuringDecode() throws {
        let fixture = try RevisionLedgerFixture()
        defer { fixture.remove() }
        let entity = SyncEntityID(kind: .project, uuid: UUID())
        let mutationID = UUID()
        let receipt = SyncRevisionReceipt(
            entityID: entity,
            mutationID: mutationID,
            logicalRevision: 0,
            deviceID: "installation-A"
        )
        let bytes = try encodedRevisionLedger(
            receipts: [receipt],
            issued: [.init(entityID: entity, revision: 0)]
        )
        try bytes.write(to: fixture.url)

        #expect(throws: SyncRevisionLedgerError.corrupt) {
            _ = try fixture.ledger.allocate(
                for: entity,
                mutationID: mutationID,
                observedRemoteRevision: 0
            )
        }
        #expect(try Data(contentsOf: fixture.url) == bytes)
    }

    @Test func issuedFloorMustEqualTheGreatestDecodedReceiptForItsEntity() throws {
        let fixture = try RevisionLedgerFixture()
        defer { fixture.remove() }
        let entity = SyncEntityID(kind: .project, uuid: UUID())
        let mutationID = UUID()
        let receipt = SyncRevisionReceipt(
            entityID: entity,
            mutationID: mutationID,
            logicalRevision: 1,
            deviceID: "installation-A"
        )
        let bytes = try encodedRevisionLedger(
            receipts: [receipt],
            issued: [.init(entityID: entity, revision: 2)]
        )
        try bytes.write(to: fixture.url)

        #expect(throws: SyncRevisionLedgerError.corrupt) {
            _ = try fixture.ledger.allocate(
                for: entity,
                mutationID: mutationID,
                observedRemoteRevision: 0
            )
        }
        #expect(try Data(contentsOf: fixture.url) == bytes)
    }

    @Test func duplicateIssuedEntityFailsClosedWithoutReplacingItsOriginalBytes() throws {
        let fixture = try RevisionLedgerFixture()
        defer { fixture.remove() }
        let entity = SyncEntityID(kind: .project, uuid: UUID())
        let receipt = SyncRevisionReceipt(
            entityID: entity,
            mutationID: UUID(),
            logicalRevision: 1,
            deviceID: "installation-A"
        )
        let bytes = try encodedRevisionLedger(
            receipts: [receipt],
            issued: [
                .init(entityID: entity, revision: 1),
                .init(entityID: entity, revision: 1)
            ]
        )
        try bytes.write(to: fixture.url)

        #expect(throws: SyncRevisionLedgerError.corrupt) {
            _ = try fixture.ledger.allocate(
                for: entity,
                mutationID: UUID(),
                observedRemoteRevision: 0
            )
        }
        #expect(try Data(contentsOf: fixture.url) == bytes)
    }

    @Test func separateLedgersAtOneURLRetainBothConcurrentReceipts() throws {
        let fixture = try RevisionLedgerFixture()
        defer { fixture.remove() }
        let entity = SyncEntityID(kind: .project, uuid: UUID())
        let firstMutationID = UUID()
        let secondMutationID = UUID()
        let first = SyncRevisionLedger(url: fixture.url, deviceID: "installation-A")
        let second = SyncRevisionLedger(url: fixture.url, deviceID: "installation-A")
        let results = ConcurrentLedgerResults()
        let group = DispatchGroup()

        for (ledger, mutationID) in [(first, firstMutationID), (second, secondMutationID)] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let receipt = try ledger.allocate(
                        for: entity,
                        mutationID: mutationID,
                        observedRemoteRevision: 0
                    )
                    results.append(receipt)
                } catch {
                    results.append(error)
                }
            }
        }
        group.wait()

        #expect(results.errors.isEmpty)
        #expect(Set(results.receipts.map(\.logicalRevision)).count == 2)
        let restarted = SyncRevisionLedger(url: fixture.url, deviceID: "installation-A")
        for receipt in results.receipts {
            #expect(try restarted.allocate(
                for: entity,
                mutationID: receipt.mutationID,
                observedRemoteRevision: .max
            ) == receipt)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-revision-ledger-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct LegacySingleRequestAllocator: SyncRevisionAllocating {
    func allocate(
        for entityID: SyncEntityID,
        mutationID: UUID,
        observedRemoteRevision: UInt64
    ) throws -> SyncRevisionReceipt {
        SyncRevisionReceipt(
            entityID: entityID,
            mutationID: mutationID,
            logicalRevision: observedRemoteRevision + 1,
            deviceID: "legacy-adapter"
        )
    }
}

private func deterministicLedgerUUID(_ value: Int) -> UUID {
    let suffix = String(format: "%012x", value)
    return UUID(uuidString: "00000000-0000-4000-8000-\(suffix)")!
}

private struct EncodedIssuedRevision: Encodable {
    let entityID: SyncEntityID
    let revision: UInt64
}

private struct EncodedRevisionLedger: Encodable {
    let version: Int
    let deviceID: String
    let receipts: [SyncRevisionReceipt]
    let issuedRevisions: [EncodedIssuedRevision]
}

private func encodedRevisionLedger(
    receipts: [SyncRevisionReceipt],
    issued: [EncodedIssuedRevision]
) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(EncodedRevisionLedger(
        version: 1,
        deviceID: "installation-A",
        receipts: receipts,
        issuedRevisions: issued
    ))
}

private final class ConcurrentLedgerResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storedReceipts: [SyncRevisionReceipt] = []
    private var storedErrors: [String] = []

    var receipts: [SyncRevisionReceipt] {
        lock.lock()
        defer { lock.unlock() }
        return storedReceipts
    }

    var errors: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedErrors
    }

    func append(_ receipt: SyncRevisionReceipt) {
        lock.lock()
        storedReceipts.append(receipt)
        lock.unlock()
    }

    func append(_ error: any Error) {
        lock.lock()
        storedErrors.append(String(describing: error))
        lock.unlock()
    }
}

private final class RevisionLedgerFixture {
    let root: URL
    let url: URL
    let ledger: SyncRevisionLedger

    init(installationID: String = "installation-A") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-revision-ledger-fixture-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appending(path: "sync-revisions.json")
        ledger = SyncRevisionLedger(url: url, deviceID: installationID)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
