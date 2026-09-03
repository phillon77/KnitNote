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

    @Test func batchAllocationUsesOneHeadWriteAndBoundedReceiptLookups() throws {
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

        #expect(counters.headLedgerDurableWriteCount == 1)
        #expect(counters.receiptLookupCount <= requests.count + 1)
        #expect(counters.receiptDirectoryEnumerationCount == 0)
        #expect(receipts.map(\.logicalRevision) == Array(1...1_000).map(UInt64.init))
        #expect(Set(receipts.map(\.mutationID)).count == requests.count)
    }

    @Test func nextBatchKeepsCompactHeadsAndPreservesRequestedRetry() throws {
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

    @Test func historicalRetrySurvivesUnrelatedCompactionAndRestart() throws {
        // Contract boundary from the approved design: an unrelated B/C batch
        // and restart must not make A depend on transient in-envelope history.
        let fixture = try RevisionLedgerFixture(installationID: "installation-A")
        defer { fixture.remove() }
        let ledger = fixture.ledger
        let url = fixture.url
        let entity = SyncEntityID(kind: .project, uuid: UUID())
        let aID = UUID()
        let bID = UUID()
        let cID = UUID()

        let a = try ledger.allocate(for: entity, mutationID: aID, observedRemoteRevision: 0)
        _ = try ledger.allocate([
            .init(
                entityID: entity,
                mutationID: bID,
                observedRemoteRevision: a.logicalRevision
            ),
            .init(
                entityID: entity,
                mutationID: cID,
                observedRemoteRevision: a.logicalRevision + 1
            ),
        ])
        let restarted = SyncRevisionLedger(url: url, deviceID: "installation-A")
        let retriedA = try restarted.allocate(
            for: entity,
            mutationID: aID,
            observedRemoteRevision: 9_999
        )

        #expect(retriedA == a)
    }

    @Test func historicalRetryIOIsConstantAfterFiveThousandReceipts() throws {
        // Production break caught: locating an old mutation by scanning or
        // decoding all receipt history makes retry cost grow with the ledger.
        let fixture = try RevisionLedgerFixture(installationID: "installation-A")
        defer { fixture.remove() }
        let entity = SyncEntityID(kind: .project, uuid: UUID())
        let requests = (0..<5_000).map { index in
            SyncRevisionRequest(
                entityID: entity,
                mutationID: deterministicLedgerUUID(index),
                observedRemoteRevision: UInt64(index)
            )
        }
        let receipts = try fixture.ledger.allocate(requests)
        _ = try fixture.ledger.allocate(
            for: entity,
            mutationID: deterministicLedgerUUID(6_000),
            observedRemoteRevision: 5_000
        )
        let expected = receipts[123]
        let historicalRetryCounters = SyncRevisionLedgerIOCounters()
        let restarted = SyncRevisionLedger(
            url: fixture.url,
            deviceID: "installation-A",
            counters: historicalRetryCounters
        )

        let retried = try restarted.allocate(
            for: entity,
            mutationID: expected.mutationID,
            observedRemoteRevision: 99_999
        )

        #expect(retried == expected)
        #expect(historicalRetryCounters.receiptLookupCount <= 2)
        #expect(historicalRetryCounters.receiptDirectoryEnumerationCount == 0)
        #expect(historicalRetryCounters.headLedgerDurableWriteCount == 0)
    }

    @Test func everyAllocationCrashBoundaryRecoversExactReceiptsAndHead() throws {
        let boundaries: [SyncRevisionLedgerDurabilityBoundary] = [
            .afterMarkerSync,
            .afterReceiptFileRename(0),
            .afterReceiptFileRename(1),
            .afterReceiptFileRename(2),
            .afterHeadLedgerSync,
            .beforeMarkerRemoval,
        ]
        for boundary in boundaries {
            let fixture = try RevisionLedgerFixture(installationID: "installation-A")
            defer { fixture.remove() }
            let entity = SyncEntityID(kind: .project, uuid: UUID())
            let ids = [UUID(), UUID(), UUID()]
            let requests = ids.enumerated().map { index, id in
                SyncRevisionRequest(
                    entityID: entity,
                    mutationID: id,
                    observedRemoteRevision: UInt64(index)
                )
            }
            let crashing = SyncRevisionLedger(
                url: fixture.url,
                deviceID: "installation-A",
                counters: SyncRevisionLedgerIOCounters(),
                afterDurabilityBoundary: { reached in
                    if reached == boundary { throw RevisionLedgerInjectedFailure() }
                }
            )

            #expect(throws: RevisionLedgerInjectedFailure.self) {
                _ = try crashing.allocate(requests)
            }

            let restarted = SyncRevisionLedger(
                url: fixture.url,
                deviceID: "installation-A"
            )
            for (index, id) in ids.enumerated() {
                let receipt = try restarted.allocate(
                    for: entity,
                    mutationID: id,
                    observedRemoteRevision: 50_000
                )
                #expect(receipt == SyncRevisionReceipt(
                    entityID: entity,
                    mutationID: id,
                    logicalRevision: UInt64(index + 1),
                    deviceID: "installation-A"
                ))
            }
            let next = try restarted.allocate(
                for: entity,
                mutationID: UUID(),
                observedRemoteRevision: 0
            )
            #expect(next.logicalRevision == 4)
            #expect(FileManager.default.fileExists(atPath: fixture.transactionURL.path) == false)
        }
    }

    @Test func transactionMarkerRejectsDuplicateEntityRevisionReceipts() throws {
        // Production break caught: a tampered marker must not materialize two
        // immutable mutation IDs claiming the same entity revision.
        let fixture = try RevisionLedgerFixture(installationID: "installation-A")
        defer { fixture.remove() }
        let entity = SyncEntityID(kind: .project, uuid: UUID())
        let requests = [
            SyncRevisionRequest(
                entityID: entity,
                mutationID: deterministicLedgerUUID(80_001),
                observedRemoteRevision: 0
            ),
            SyncRevisionRequest(
                entityID: entity,
                mutationID: deterministicLedgerUUID(80_002),
                observedRemoteRevision: 1
            ),
        ]
        let crashing = SyncRevisionLedger(
            url: fixture.url,
            deviceID: "installation-A",
            counters: SyncRevisionLedgerIOCounters(),
            afterDurabilityBoundary: { boundary in
                if boundary == .afterMarkerSync { throw RevisionLedgerInjectedFailure() }
            }
        )
        #expect(throws: RevisionLedgerInjectedFailure.self) {
            _ = try crashing.allocate(requests)
        }
        var marker = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.transactionURL)
        ) as? [String: Any])
        var receiptObjects = try #require(marker["newReceipts"] as? [[String: Any]])
        receiptObjects[1]["logicalRevision"] = receiptObjects[0]["logicalRevision"]
        marker["newReceipts"] = receiptObjects
        let tampered = try JSONSerialization.data(
            withJSONObject: marker,
            options: [.sortedKeys]
        )
        try tampered.write(to: fixture.transactionURL)

        let restarted = SyncRevisionLedger(url: fixture.url, deviceID: "installation-A")
        #expect(throws: SyncRevisionLedgerError.corrupt) {
            _ = try restarted.allocate(requests)
        }
        #expect(try Data(contentsOf: fixture.transactionURL) == tampered)
    }

    @Test func validV1LedgerMigratesToCompactHeadsAndImmutableReceipts() throws {
        let fixture = try RevisionLedgerFixture(installationID: "installation-A")
        defer { fixture.remove() }
        let entity = SyncEntityID(kind: .project, uuid: UUID())
        let receipts = (1...3).map { revision in
            SyncRevisionReceipt(
                entityID: entity,
                mutationID: deterministicLedgerUUID(revision),
                logicalRevision: UInt64(revision),
                deviceID: "installation-A"
            )
        }
        try encodedRevisionLedger(
            receipts: receipts,
            issued: [.init(entityID: entity, revision: 3)]
        ).write(to: fixture.url)

        let retried = try fixture.ledger.allocate(
            for: entity,
            mutationID: receipts[0].mutationID,
            observedRemoteRevision: 9_999
        )

        #expect(retried == receipts[0])
        let migrated = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.url)
        ) as? [String: Any])
        #expect(migrated["version"] as? Int == 2)
        #expect(migrated["receipts"] == nil)
        for receipt in receipts {
            #expect(try Data(contentsOf: fixture.receiptURL(for: receipt.mutationID))
                == encodedReceipt(receipt))
        }
        #expect(FileManager.default.fileExists(atPath: fixture.transactionURL.path) == false)
    }

    @Test func migrationReentryAcceptsIdenticalReceiptAndPreservesV1UntilHeadsSync() throws {
        let fixture = try RevisionLedgerFixture(installationID: "installation-A")
        defer { fixture.remove() }
        let entity = SyncEntityID(kind: .project, uuid: UUID())
        let receipt = SyncRevisionReceipt(
            entityID: entity,
            mutationID: UUID(),
            logicalRevision: 1,
            deviceID: "installation-A"
        )
        let legacyBytes = try encodedRevisionLedger(
            receipts: [receipt],
            issued: [.init(entityID: entity, revision: 1)]
        )
        try legacyBytes.write(to: fixture.url)
        let crashing = SyncRevisionLedger(
            url: fixture.url,
            deviceID: "installation-A",
            counters: SyncRevisionLedgerIOCounters(),
            afterDurabilityBoundary: { boundary in
                if boundary == .afterReceiptFileRename(0) {
                    throw RevisionLedgerInjectedFailure()
                }
            }
        )
        #expect(throws: RevisionLedgerInjectedFailure.self) {
            _ = try crashing.allocate(
                for: entity,
                mutationID: receipt.mutationID,
                observedRemoteRevision: 0
            )
        }
        #expect(try Data(contentsOf: fixture.url) == legacyBytes)

        let restarted = SyncRevisionLedger(url: fixture.url, deviceID: "installation-A")
        #expect(try restarted.allocate(
            for: entity,
            mutationID: receipt.mutationID,
            observedRemoteRevision: 99
        ) == receipt)
        #expect(FileManager.default.fileExists(atPath: fixture.transactionURL.path) == false)
    }

    @Test func divergentReceiptDuringMigrationFailsClosedAndKeepsV1Bytes() throws {
        let fixture = try RevisionLedgerFixture(installationID: "installation-A")
        defer { fixture.remove() }
        let entity = SyncEntityID(kind: .project, uuid: UUID())
        let receipt = SyncRevisionReceipt(
            entityID: entity,
            mutationID: UUID(),
            logicalRevision: 1,
            deviceID: "installation-A"
        )
        let legacyBytes = try encodedRevisionLedger(
            receipts: [receipt],
            issued: [.init(entityID: entity, revision: 1)]
        )
        try legacyBytes.write(to: fixture.url)
        try FileManager.default.createDirectory(
            at: fixture.receiptURL(for: receipt.mutationID).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let divergent = SyncRevisionReceipt(
            entityID: entity,
            mutationID: receipt.mutationID,
            logicalRevision: 2,
            deviceID: "installation-A"
        )
        try encodedReceipt(divergent).write(to: fixture.receiptURL(for: receipt.mutationID))

        #expect(throws: SyncRevisionLedgerError.corrupt) {
            _ = try fixture.ledger.allocate(
                for: entity,
                mutationID: receipt.mutationID,
                observedRemoteRevision: 0
            )
        }
        #expect(try Data(contentsOf: fixture.url) == legacyBytes)
    }

    @Test func changedLegacySourceAfterMigrationMarkerFailsClosed() throws {
        let fixture = try RevisionLedgerFixture(installationID: "installation-A")
        defer { fixture.remove() }
        let entity = SyncEntityID(kind: .project, uuid: UUID())
        let receipt = SyncRevisionReceipt(
            entityID: entity,
            mutationID: UUID(),
            logicalRevision: 1,
            deviceID: "installation-A"
        )
        try encodedRevisionLedger(
            receipts: [receipt],
            issued: [.init(entityID: entity, revision: 1)]
        ).write(to: fixture.url)
        let crashing = SyncRevisionLedger(
            url: fixture.url,
            deviceID: "installation-A",
            counters: SyncRevisionLedgerIOCounters(),
            afterDurabilityBoundary: { boundary in
                if boundary == .afterMarkerSync { throw RevisionLedgerInjectedFailure() }
            }
        )
        #expect(throws: RevisionLedgerInjectedFailure.self) {
            _ = try crashing.allocate(
                for: entity,
                mutationID: receipt.mutationID,
                observedRemoteRevision: 0
            )
        }
        let changedReceipt = SyncRevisionReceipt(
            entityID: entity,
            mutationID: receipt.mutationID,
            logicalRevision: 2,
            deviceID: "installation-A"
        )
        let changedBytes = try encodedRevisionLedger(
            receipts: [changedReceipt],
            issued: [.init(entityID: entity, revision: 2)]
        )
        try changedBytes.write(to: fixture.url)

        let restarted = SyncRevisionLedger(url: fixture.url, deviceID: "installation-A")
        #expect(throws: SyncRevisionLedgerError.corrupt) {
            _ = try restarted.allocate(
                for: entity,
                mutationID: receipt.mutationID,
                observedRemoteRevision: 0
            )
        }
        #expect(try Data(contentsOf: fixture.url) == changedBytes)
    }

    @Test func historicalRetryRemainsPermanentBeyondTheCompactionLag() throws {
        // Production break caught: the v1 compactor happens before appending a
        // batch, so A survives B/C accidentally but disappears on the next
        // unrelated allocation and is assigned a new revision after restart.
        let fixture = try RevisionLedgerFixture(installationID: "installation-A")
        defer { fixture.remove() }
        let entity = SyncEntityID(kind: .project, uuid: UUID())
        let aID = UUID()
        let a = try fixture.ledger.allocate(
            for: entity,
            mutationID: aID,
            observedRemoteRevision: 0
        )
        _ = try fixture.ledger.allocate([
            .init(entityID: entity, mutationID: UUID(), observedRemoteRevision: 1),
            .init(entityID: entity, mutationID: UUID(), observedRemoteRevision: 2),
        ])
        _ = try fixture.ledger.allocate(
            for: entity,
            mutationID: UUID(),
            observedRemoteRevision: 3
        )

        let restarted = SyncRevisionLedger(
            url: fixture.url,
            deviceID: "installation-A"
        )
        let retriedA = try restarted.allocate(
            for: entity,
            mutationID: aID,
            observedRemoteRevision: 9_999
        )

        #expect(retriedA == a)
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

    @Test func separateProcessesAllocateUniqueDurableReceipts() throws {
        // Production break caught: a process-local lock alone lets independent
        // app processes read the same head and install conflicting revisions.
        let fixture = try RevisionLedgerFixture()
        defer { fixture.remove() }
        let repositoryRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let helperSourceURL = fixture.root.appendingPathComponent("LedgerChild.swift")
        let helperExecutableURL = fixture.root.appendingPathComponent("ledger-child")
        let helperSource = #"""
        import Foundation

        @main
        struct LedgerChild {
            static func main() throws {
                let arguments = CommandLine.arguments
                guard arguments.count == 4,
                      let entityUUID = UUID(uuidString: arguments[2]),
                      let mutationUUID = UUID(uuidString: arguments[3]) else {
                    throw NSError(domain: "LedgerChild", code: 64)
                }
                let ledger = SyncRevisionLedger(
                    url: URL(filePath: arguments[1]),
                    deviceID: "installation-A"
                )
                let receipt = try ledger.allocate(
                    for: SyncEntityID(kind: .project, uuid: entityUUID),
                    mutationID: mutationUUID,
                    observedRemoteRevision: 0
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                FileHandle.standardOutput.write(try encoder.encode(receipt))
            }
        }
        """#
        try Data(helperSource.utf8).write(to: helperSourceURL)
        let compilation = Process()
        let compilationErrors = Pipe()
        compilation.executableURL = URL(filePath: "/usr/bin/xcrun")
        compilation.arguments = [
            "swiftc",
            "-parse-as-library",
            repositoryRoot.appendingPathComponent(
                "Sources/KnitNoteCore/CloudSync/SyncIdentity.swift"
            ).path,
            repositoryRoot.appendingPathComponent(
                "Sources/KnitNoteCore/CloudSync/SyncDurableFile.swift"
            ).path,
            repositoryRoot.appendingPathComponent(
                "Sources/KnitNoteCore/CloudSync/SyncRevisionLedger.swift"
            ).path,
            helperSourceURL.path,
            "-o",
            helperExecutableURL.path,
        ]
        compilation.standardError = compilationErrors
        try compilation.run()
        compilation.waitUntilExit()
        let compilerDiagnostic = String(
            decoding: compilationErrors.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        try #require(
            compilation.terminationStatus == 0,
            "Child helper compilation failed: \(compilerDiagnostic)"
        )

        let entity = SyncEntityID(kind: .project, uuid: UUID())
        let mutationIDs = (90_000..<90_004).map(deterministicLedgerUUID)
        var children: [(Process, Pipe)] = []
        for mutationID in mutationIDs {
            let process = Process()
            let output = Pipe()
            process.executableURL = helperExecutableURL
            process.arguments = [
                fixture.url.path,
                entity.uuid.uuidString,
                mutationID.uuidString,
            ]
            process.standardOutput = output
            process.standardError = output
            try process.run()
            children.append((process, output))
        }
        let receipts = try children.map { process, output in
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            try #require(
                process.terminationStatus == 0,
                "Child failed: \(String(decoding: data, as: UTF8.self))"
            )
            return try JSONDecoder().decode(SyncRevisionReceipt.self, from: data)
        }

        #expect(Set(receipts.map(\.logicalRevision)).count == mutationIDs.count)
        #expect(Set(receipts.map(\.mutationID)) == Set(mutationIDs))
        let restarted = SyncRevisionLedger(url: fixture.url, deviceID: "installation-A")
        for receipt in receipts {
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

private struct RevisionLedgerInjectedFailure: Error {}

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

private func encodedReceipt(_ receipt: SyncRevisionReceipt) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(receipt)
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

    var receiptsRootURL: URL {
        url.deletingPathExtension().appendingPathExtension("receipts")
    }

    var transactionURL: URL {
        url.deletingPathExtension().appendingPathExtension("transaction.json")
    }

    init(installationID: String = "installation-A") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-revision-ledger-fixture-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appending(path: "sync-revisions.json")
        ledger = SyncRevisionLedger(url: url, deviceID: installationID)
    }

    func receiptURL(for mutationID: UUID) -> URL {
        let hex = mutationID.uuidString.lowercased()
        return receiptsRootURL
            .appendingPathComponent(String(hex.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(hex).json")
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
