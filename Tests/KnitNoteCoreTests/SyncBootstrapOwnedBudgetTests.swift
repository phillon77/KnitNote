import Foundation
import Testing
@testable import KnitNoteCore

struct SyncBootstrapOwnedBudgetTests {
    @Test func strictDataOnlyHistoryComposesExactPredecessorAndFullRetryLifetimes() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let p = try f.transaction().plan(f.input())
        let current = try BootstrapManifestV3.decodeEnvelope(p.preparingEnvelope)
        let oldID = UUID()
        guard case let .preparing(initial) = current.body else { Issue.record("missing preparing"); return }
        let allocation = BootstrapManifestV3.OutputAllocation(transactionID: oldID, allowedRoles: [.original],
            roleLimits: [.init(role: .original, maximumEntryCount: 1, reservedEncodedProofBytes: 1_000)])
        let old = BootstrapManifestV3(id: oldID, context: current.context, livePath: current.livePath,
            journalPath: current.journalPath, sourceProof: current.sourceProof, original: current.original,
            historyHead: nil, body: .abortedPreparation(.init(preparationSHA256: Data(repeating: 1, count: 32),
                sourceControlSHA256: initial.sourceControlSHA256, pendingSnapshotSHA256: initial.pendingSnapshotSHA256,
                outputAllocation: allocation, frozenOutputEntries: [])))
        let terminal = try old.encoded()
        let record = BootstrapHistoryRecordV1(version: 1, accountIDHash: current.context.accountIDHash,
            livePath: current.livePath, journalPath: current.journalPath, transactionID: oldID,
            terminalEnvelope: terminal, treeEntries: [], previous: nil)
        let bytes = try record.encoded()
        #expect(try BootstrapHistoryRecordV1.decodeEnvelope(bytes).terminalEnvelope == terminal)
        #expect(try record.prospectiveEnvelopeByteCount(terminalByteCount: terminal.count) >= bytes.count)
        let reference = BootstrapHistoryRef(sha256: OwnedBootstrapCodec.hash(bytes), byteCount: Int64(bytes.count),
            recordCount: 1, chainByteCount: Int64(bytes.count))
        let predecessor = BootstrapManifestV3.PendingHistoryRecord(record: bytes, reference: reference)
        var builder = SyncBootstrapOwnedProgramBuilder()
        try builder.appendHelper(p.actions, step: .publication)
        let namespace = OwnedBootstrapCodec.parent(current.transactionRelativePath)
        let result = try SyncBootstrapRecoveryBudget.compose(inventory: p.initialInventory, control: p.initialControl,
            context: current.context, original: current.original, sourceProof: current.sourceProof,
            builder: builder, reservation: p.reservation, deletion: p.deletion, commit: p.commitProgram,
            mutations: p.mutations, finalPending: p.initialInventory.packet.mutations,
            finalJournalFiles: p.finalJournalFiles,
            namespace: namespace, predecessor: predecessor, pendingSnapshotSHA256: initial.pendingSnapshotSHA256,
            maximumBytes: 100_000_000)
        let planned = try BootstrapManifestV3.decodeEnvelope(result.preparingEnvelope)
        let chain = try SyncBootstrapHistory.validate(current: planned, records: [], accountEntries: [])
        #expect(chain.count == 1)
        #expect(chain[0].terminalEnvelope == terminal)
        #expect(chain[0].treeEntries.isEmpty)
        guard case let .preparing(preparation) = planned.body else { Issue.record("missing preparing"); return }
        #expect(preparation.predecessor?.record == bytes)
        #expect(preparation.predecessor?.reference == reference)
        #expect(result.scenarios.count == 7)
        #expect(result.maximumRecoveryEnvelopeBytes > p.maximumRecoveryEnvelopeBytes)
        #expect(result.scenarios.filter { $0.nextRetryPreparingBytes != nil }.count == 3)
        #expect(try f.source.capture().entries == p.initialInventory.entries)
        #expect(!FileManager.default.fileExists(atPath: f.namespace.path))
        // Exact immutable current record bytes are passed to the real inventory
        // codec, not replaced by maximum-size fake history payload.
        let count = try p.initialInventory.projectedEncodedByteCount(entries: p.initialInventory.entries,
            packetByteCount: p.initialInventory.packet.encoded().count, deletionFiles: [],
            sourceAuthority: p.initialInventory.sourceAuthority,
            bootstrapEvidence: .init(activeEnvelope: terminal, historyRecords: [bytes]))
        #expect(count > bytes.count + terminal.count)
    }

    @Test func deletionProjectionUsesNativeSelectionAndDoesNotRequireUnselectedPayload() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        let selected = try f.addDeletion(ledger: ledger, name: "selected", attachment: true)
        _ = try f.addDeletion(ledger: ledger, name: "unselected", attachment: true)
        let pending = try selected.versions.map { try SyncMutation.save(recordVersion: $0, mutationID: UUID()) }
        let actual = try SyncDeletionLedger.recoveryExport(archiveURL: f.archiveURL, pending: pending, maximumBytes: 100_000_000)
        let frozen = try Data(contentsOf: f.ledgerRoot.appendingPathComponent("ledger.json"))
        let files = Dictionary(uniqueKeysWithValues: actual.files.map {
            ($0.retainedRelativePath, SyncBootstrapOutputProof(byteCount: $0.byteCount, sha256: $0.sha256))
        })
        var archiveReads = 0
        let projected = try SyncDeletionLedger.projectedRecoveryExport(archiveURL: f.archiveURL,
            manifestBytes: frozen, files: files, pending: pending, maximumBytes: 100_000_000,
            archiveSHA256: { archiveReads += 1; throw SyncBootstrapError.corrupt })
        #expect(projected.manifest == actual.manifest)
        #expect(projected.files == actual.files)
        #expect(projected.knownRetainedPaths == actual.knownRetainedPaths)
        #expect(projected.pendingMarkerVersions == actual.pendingMarkerVersions)
        #expect(projected.terminalSources == actual.terminalSources)
        #expect(archiveReads == 0)
        #expect(actual.knownRetainedPaths.count == 2)
        #expect(actual.files.count == 1)
        #expect(throws: (any Error).self) {
            _ = try SyncDeletionLedger.projectedRecoveryExport(archiveURL: f.archiveURL, manifestBytes: frozen,
                files: [:], pending: pending, maximumBytes: 100_000_000, archiveSHA256: { Data() })
        }
    }

    @Test func sharedPendingBaselineBindsDeletionSelectionContentAndOrder() throws {
        let f = try SourceInventoryFixture(); defer { f.remove() }
        let inventory = try f.capture()
        let a = SyncPendingRecoveryPacket.File(relativePath: "staging/a", byteCount: 1,
            sha256: OwnedBootstrapCodec.hash(Data([1])), bytes: Data([1]))
        let b = SyncPendingRecoveryPacket.File(relativePath: "staging/b", byteCount: 1,
            sha256: OwnedBootstrapCodec.hash(Data([2])), bytes: Data([2]))
        func entries(_ files: [SyncPendingRecoveryPacket.File]) -> [SyncAccountRecoveryInventory.Entry] {
            inventory.entries + files.enumerated().map { index, file in
                .init(relativePath: file.relativePath, isDirectory: false, byteCount: file.byteCount,
                    sha256: file.sha256, device: 1, inode: UInt64(index + 1))
            }
        }
        let recordA = try SyncRecordVersion(record: SyncCanonicalPublicationSnapshot(
            archive: .init(version: ProjectArchive.currentVersion, projects: [try StoredProject(name: "a")]),
            deviceID: "fixture").records.values.first!)
        let recordB = try SyncRecordVersion(record: SyncCanonicalPublicationSnapshot(
            archive: .init(version: ProjectArchive.currentVersion, projects: [try StoredProject(name: "b")]),
            deviceID: "fixture").records.values.first!)
        func digest(_ files: [SyncPendingRecoveryPacket.File], ledger: Data = Data([1]),
                    markers: [SyncRecordVersion] = [recordA, recordB],
                    sourceFiles: [SyncPendingRecoveryPacket.File] = [a, b]) throws -> Data {
            try SyncAccountSourceBaseline.digest(entries: entries(sourceFiles), accountRoot: inventory.accountRoot,
                journalURL: inventory.journalURL, mutations: [], selectedFiles: files,
                deletionLedger: ledger, pendingMarkerVersions: markers)
        }
        let baseline = try digest([a, b])
        #expect(try digest([a]) != baseline)
        #expect(try digest([a, b], ledger: Data([2])) != baseline)
        #expect(try digest([a, b], markers: [recordB, recordA]) != baseline)
        let changed = SyncPendingRecoveryPacket.File(relativePath: a.relativePath, byteCount: 1,
            sha256: OwnedBootstrapCodec.hash(Data([3])), bytes: Data([3]))
        #expect(try digest([changed, b], sourceFiles: [changed, b]) != baseline)
        // Newly owned outputs are not part of the shared portable source domain.
        let futureEntries = entries([a, b]) + [.init(relativePath: ".KnitNote-SyncBootstrap/new-output",
            isDirectory: false, byteCount: 1, sha256: a.sha256, device: 1, inode: 1)]
        #expect(try SyncAccountSourceBaseline.digest(entries: futureEntries, accountRoot: inventory.accountRoot,
            journalURL: inventory.journalURL, mutations: [], selectedFiles: [a, b],
            deletionLedger: Data([1]), pendingMarkerVersions: [recordA, recordB]) == baseline)
    }

    @Test func escapedFutureDataBoundMatchesActualWorstCaseCodec() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for count in 0...16 {
            let actual = try encoder.encode(Data(repeating: 255, count: count)).count - 2
            #expect(try SyncBootstrapRecoveryBudget.escapedBase64Maximum(count) == actual)
        }
        #expect(throws: (any Error).self) { try SyncBootstrapRecoveryBudget.escapedBase64Maximum(Int.max) }
        #expect(throws: (any Error).self) { try SyncBootstrapRecoveryBudget.escapedBase64Maximum(-1) }
        #expect(try SyncBootstrapRecoveryBudget.escapedBase64Maximum(37_500_000) == 100_000_000)
        #expect(throws: (any Error).self) { try SyncBootstrapRecoveryBudget.escapedBase64Maximum(37_500_001) }
        #expect(try SyncBootstrapRecoveryBudget.base64Bytes(75_000_000) == 100_000_000)
        #expect(throws: (any Error).self) { try SyncBootstrapRecoveryBudget.base64Bytes(75_000_001) }
    }

    @Test func prospectiveOuterEnvelopeUsesRealCodecAndBase64Padding() throws {
        let capture = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let session = ".decrypted-temporary/00000000-0000-0000-0000-000000000002"
        let control = SyncAccountControlObservation(mainBytes: Data([255, 0, 1]), nextBytes: nil, state: nil)
        for count in 0...7 {
            let object: [String: Any] = ["formatVersion": 2, "captureID": capture.uuidString,
                "accountDevice": UInt64.max, "accountInode": UInt64.max,
                "temporarySession": session, "packetSHA256": Data(repeating: 0, count: 32).base64EncodedString(),
                "inventory": Data(repeating: 255, count: count).base64EncodedString(),
                "sourceControl": ["mainBytes": control.mainBytes!.base64EncodedString(), "nextBytes": NSNull()]]
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            #expect(try SyncAccountRecoveryTransaction.projectedEnvelopeByteCount(inventoryByteCount: count,
                captureID: capture, accountDevice: UInt64.max, accountInode: UInt64.max,
                temporarySession: session, control: control) == bytes.count)
        }
    }

    @Test func prospectiveInventoryUsesActualLegacyAndV2Codecs() throws {
        let f = try SourceInventoryFixture(); defer { f.remove() }
        let inventory = try f.capture()
        let actual = try inventory.encoded()
        let count = try inventory.projectedEncodedByteCount(entries: inventory.entries,
            packetByteCount: inventory.packet.encoded().count, deletionFiles: inventory.deletionFiles,
            sourceAuthority: inventory.sourceAuthority, bootstrapEvidence: nil)
        #expect(count == actual.count)
        let terminal = Data("exact terminal / escaped ".utf8)
        let history = [Data("history one".utf8), Data("history two".utf8)]
        let evidence = SyncAccountRecoveryInventory.BootstrapEvidence(activeEnvelope: terminal, historyRecords: history)
        var object = try #require(JSONSerialization.jsonObject(with: actual) as? [String: Any])
        object["bootstrapEvidence"] = ["activeEnvelope": terminal.base64EncodedString(),
            "historyRecords": history.map { $0.base64EncodedString() }]
        let expected = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        #expect(try inventory.projectedEncodedByteCount(entries: inventory.entries,
            packetByteCount: inventory.packet.encoded().count, deletionFiles: inventory.deletionFiles,
            sourceAuthority: inventory.sourceAuthority, bootstrapEvidence: evidence) == expected.count)
        #expect(throws: (any Error).self) {
            _ = try SyncAccountRecoveryInventory.decodeRecovery(expected, account: f.account,
                paths: f.paths, journalURL: f.paths.mutationJournalURL, maximumBytes: 100_000_000)
        }
    }

    @Test func inventoryAllowanceRoundsDownAtBase64Boundaries() throws {
        for (limit, overhead, expected) in [(100, 100, 0), (101, 100, 0), (103, 100, 0),
            (104, 100, 3), (107, 100, 3), (108, 100, 6), (0, 0, 0),
            (100_000_000, 0, 75_000_000)] {
            #expect(try SyncBootstrapRecoveryBudget.inventoryAllowance(
                maximumEnvelopeBytes: limit, fixedOverheadBytes: overhead) == expected)
        }
    }

    @Test func rejectsInvalidOrUnaffordableEnvelopeWithoutOverflow() {
        for (limit, overhead) in [(-1, 0), (100_000_001, 0), (Int.max, 0), (0, -1),
            (0, Int.min), (99, 100), (100, Int.max)] {
            #expect(throws: SyncAccountRecoveryTransaction.Error.tooLarge) {
                try SyncBootstrapRecoveryBudget.inventoryAllowance(
                    maximumEnvelopeBytes: limit, fixedOverheadBytes: overhead)
            }
        }
    }

    @Test func allowanceFitsActualEncodingButOneMoreByteDoesNot() throws {
        struct Envelope: Encodable { let inventory: Data; let path: String }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let path = "history/引號\"與斜線\\"
        let overhead = try encoder.encode(Envelope(inventory: Data(), path: path)).count
        for remaining in 0...16 {
            let limit = overhead + remaining
            let allowed = try SyncBootstrapRecoveryBudget.inventoryAllowance(
                maximumEnvelopeBytes: limit, fixedOverheadBytes: overhead)
            for byte: UInt8 in [0, 255] {
                #expect(try encoder.encode(Envelope(inventory: Data(repeating: byte, count: allowed), path: path)).count <= limit)
                #expect(try encoder.encode(Envelope(inventory: Data(repeating: byte, count: allowed + 1), path: path)).count > limit)
            }
        }
    }
}
