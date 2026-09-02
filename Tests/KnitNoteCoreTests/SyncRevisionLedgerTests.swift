import Foundation
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

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-revision-ledger-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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
