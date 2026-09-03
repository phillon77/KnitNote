import Foundation
import Dispatch
import Testing
@testable import KnitNoteCore

struct SyncRevisionLedgerTests {
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
