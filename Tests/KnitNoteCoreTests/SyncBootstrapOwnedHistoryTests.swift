import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

struct SyncBootstrapOwnedHistoryTests {
    typealias Entry = SyncAccountRecoveryInventory.Entry
    private let account = String(repeating: "a", count: 64)
    private let live = "/private/tmp/history-fixture/working-set"
    private let journal = "SyncMetadata/journal.json"
    private let digest = Data(repeating: 7, count: 32)
    private let oldID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let nextID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let currentID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private var namespace: String { ".KnitNote-SyncBootstrap/\(account)/\(OwnedBootstrapCodec.hex(OwnedBootstrapCodec.hash(Data(live.utf8))))" }
    private func entry(_ path: String, directory: Bool = true, inode: UInt64 = 1) -> Entry {
        .init(relativePath: path, isDirectory: directory, byteCount: directory ? 0 : 1,
              sha256: directory ? Data() : digest, device: 1, inode: inode)
    }
    private func tree(_ id: UUID) -> [Entry] {
        let root = namespace + "/" + id.uuidString
        let base: UInt64 = id == oldID ? 10 : 20
        return [entry(root, inode: base), entry(root + "/Original", inode: base + 1),
                entry(root + "/Original/projects-v1.json", directory: false, inode: base + 2)]
    }
    private func manifest(_ id: UUID, head: BootstrapHistoryRef? = nil, aborted: Bool = true,
                          entries: [Entry]? = nil) -> BootstrapManifestV3 {
        let context = SyncBootstrapContext(accountIDHash: account, epoch: id, freezeID: id)
        let allocation = BootstrapManifestV3.OutputAllocation(transactionID: id, allowedRoles: [.original],
            roleLimits: [.init(role: .original, maximumEntryCount: 10, reservedEncodedProofBytes: 10_000)])
        let prepared = BootstrapManifestV3.PreparedBody(installed: ["projects-v1.json": .init(bytes: 1, digest: digest)],
            mutations: [], preparationSHA256: digest,
            commitProgram: .init(journalRelativePath: journal, initialJournalDirectories: [], initialJournalFiles: [:], operations: []),
            originalLiveRoot: .init(device: 1, inode: 100), stagedRoot: .init(device: 1, inode: 101))
        let body: BootstrapManifestV3.Body = aborted
            ? .abortedPreparation(.init(preparationSHA256: digest, sourceControlSHA256: nil, pendingSnapshotSHA256: digest,
                outputAllocation: allocation, frozenOutputEntries: entries ?? []))
            : .rolledBack(.init(prepared: prepared, frozenTransactionEntries: entries ?? tree(id)))
        return .init(id: id, context: context, livePath: live, journalPath: journal, sourceProof: .archive(sha256: digest),
            original: ["projects-v1.json": .init(bytes: 1, digest: digest)], historyHead: head, body: body)
    }
    private func record(_ terminal: BootstrapManifestV3, entries: [Entry] = [], previous: BootstrapHistoryRef? = nil) throws -> BootstrapHistoryRecordV1 {
        .init(version: 1, accountIDHash: account, livePath: live, journalPath: journal, transactionID: terminal.id,
              terminalEnvelope: try terminal.encoded(), treeEntries: entries, previous: previous)
    }
    private func reference(_ bytes: Data, previous: BootstrapHistoryRef? = nil) -> BootstrapHistoryRef {
        .init(sha256: OwnedBootstrapCodec.hash(bytes), byteCount: Int64(bytes.count),
              recordCount: (previous?.recordCount ?? 0) + 1, chainByteCount: (previous?.chainByteCount ?? 0) + Int64(bytes.count))
    }
    private func supplied(_ bytes: Data) -> SyncBootstrapHistory.SuppliedRecord {
        .init(relativePath: namespace + "/History/" + OwnedBootstrapCodec.hex(OwnedBootstrapCodec.hash(bytes)) + ".json", bytes: bytes)
    }
    private func observations(_ records: [SyncBootstrapHistory.SuppliedRecord], trees: [Entry] = []) -> [Entry] {
        var result = [entry(".KnitNote-SyncBootstrap", inode: 200), entry(".KnitNote-SyncBootstrap/" + account, inode: 201),
                      entry(namespace, inode: 202)] + trees
        if !records.isEmpty {
            result.append(entry(namespace + "/History", inode: 203))
            result += records.enumerated().map { index, record in
                Entry(relativePath: record.relativePath, isDirectory: false, byteCount: Int64(record.bytes.count),
                    sha256: OwnedBootstrapCodec.hash(record.bytes), device: 1, inode: UInt64(300 + index))
            }
        }
        return result.sorted { OwnedBootstrapCodec.pathOrder($0.relativePath, $1.relativePath) }
    }
    private func chain() throws -> (BootstrapManifestV3, [SyncBootstrapHistory.SuppliedRecord], [Entry]) {
        let oldest = try record(manifest(oldID, aborted: false), entries: tree(oldID)).encoded()
        let first = reference(oldest)
        let newest = try record(manifest(nextID, head: first), previous: first).encoded()
        let records = [supplied(newest), supplied(oldest)]
        return (manifest(currentID, head: reference(newest, previous: first)), records, observations(records, trees: tree(oldID)))
    }

    // Losing the iterative traversal or comparing old Original to current live breaks this.
    @Test func validatesTwoPredecessorsRetainingExactHistoricalEnvelopesAndContext() throws {
        let (baseline, records, entries) = try chain()
        let changedSource = Data(repeating: 9, count: 32)
        let current = BootstrapManifestV3(id: baseline.id, context: baseline.context, livePath: baseline.livePath,
            journalPath: baseline.journalPath, sourceProof: .archive(sha256: changedSource),
            original: ["projects-v1.json": .init(bytes: 2, digest: changedSource)], historyHead: baseline.historyHead, body: baseline.body)
        let result = try SyncBootstrapHistory.validate(current: current, records: records, accountEntries: entries)
        #expect(result.map(\.transactionID) == [nextID, oldID])
        let old = try BootstrapManifestV3.decodeEnvelope(result[1].terminalEnvelope)
        #expect(old.context.epoch == oldID)
        #expect(old.context != current.context)
        #expect(old.original != current.original)
        #expect(result[1].treeEntries == tree(oldID))
    }

    @Test func rejectsMissingExtraTamperedRecordsAndFalseTotals() throws {
        let (current, records, entries) = try chain()
        #expect(throws: (any Error).self) { try SyncBootstrapHistory.validate(current: current, records: Array(records.dropLast()), accountEntries: entries) }
        #expect(throws: (any Error).self) { try SyncBootstrapHistory.validate(current: current, records: records + [records[0]], accountEntries: entries) }
        let bad = SyncBootstrapHistory.SuppliedRecord(relativePath: records[1].relativePath, bytes: records[1].bytes + Data([0]))
        #expect(throws: (any Error).self) { try SyncBootstrapHistory.validate(current: current, records: [records[0], bad], accountEntries: entries) }
        let h = try #require(current.historyHead)
        for head in [BootstrapHistoryRef(sha256: h.sha256, byteCount: h.byteCount, recordCount: 3, chainByteCount: h.chainByteCount),
                     .init(sha256: h.sha256, byteCount: h.byteCount + 1, recordCount: 2, chainByteCount: h.chainByteCount),
                     .init(sha256: h.sha256, byteCount: h.byteCount, recordCount: 2, chainByteCount: h.chainByteCount + 1),
                     .init(sha256: h.sha256, byteCount: 0, recordCount: Int.max, chainByteCount: 0)] {
            #expect(throws: (any Error).self) { try SyncBootstrapHistory.validate(current: manifest(currentID, head: head), records: records, accountEntries: entries) }
        }
    }

    @Test func rejectsChangedHistoricalPhysicalProofAndUnknownNamespaceEntries() throws {
        let (current, records, entries) = try chain()
        let old = try #require(entries.firstIndex { $0.relativePath == namespace + "/" + oldID.uuidString })
        var changed = entries
        changed[old] = entry(entries[old].relativePath, inode: 999)
        #expect(throws: (any Error).self) { try SyncBootstrapHistory.validate(current: current, records: records, accountEntries: changed) }
        for path in [namespace + "/" + UUID().uuidString, namespace + "/History/unknown.json",
                     namespace + "/" + nextID.uuidString] {
            let extra = (entries + [entry(path, inode: 999)]).sorted { OwnedBootstrapCodec.pathOrder($0.relativePath, $1.relativePath) }
            #expect(throws: (any Error).self) { try SyncBootstrapHistory.validate(current: current, records: records, accountEntries: extra) }
        }
    }

    @Test func emptyBeforeRootRejectsSubsequentlyAppearingUUIDAndRepeatedCurrentUUID() throws {
        let bytes = try record(manifest(oldID)).encoded(), ref = reference(bytes)
        let records = [supplied(bytes)]
        _ = try SyncBootstrapHistory.validate(current: manifest(currentID, head: ref), records: records, accountEntries: observations(records))
        #expect(throws: (any Error).self) { try SyncBootstrapHistory.validate(current: manifest(currentID, head: ref), records: records,
            accountEntries: observations(records, trees: [entry(namespace + "/" + oldID.uuidString, inode: 999)])) }
        #expect(throws: (any Error).self) { try SyncBootstrapHistory.validate(current: manifest(oldID, head: ref), records: records, accountEntries: observations(records)) }
    }

    @Test func exactAggregateCapAndPerRecordCapAreInclusive() throws {
        let (current, records, entries) = try chain()
        let total = records.reduce(0) { $0 + $1.bytes.count }
        _ = try SyncBootstrapHistory.validate(current: current, records: records, accountEntries: entries, maximumBytes: total)
        #expect(throws: (any Error).self) { try SyncBootstrapHistory.validate(current: current, records: records, accountEntries: entries, maximumBytes: total - 1) }
        let decoded = try BootstrapHistoryRecordV1.decodeEnvelope(records[0].bytes, maximumBytes: records[0].bytes.count)
        #expect(try decoded.encoded(maximumBytes: records[0].bytes.count) == records[0].bytes)
        #expect(throws: (any Error).self) { try BootstrapHistoryRecordV1.decodeEnvelope(records[0].bytes, maximumBytes: records[0].bytes.count - 1) }
        #expect(throws: (any Error).self) { try SyncBootstrapHistory.validate(current: current, records: records, accountEntries: entries, maximumBytes: 100_000_001) }
    }

    private func altered(_ bytes: Data, _ edit: (inout [String: Any]) throws -> Void) throws -> Data {
        let payload = try OwnedBootstrapCodec.envelopePayload(bytes)
        var object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        try edit(&object)
        let changed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try OwnedBootstrapCodec.encode(OwnedBootstrapCodec.Envelope(payload: changed, digest: OwnedBootstrapCodec.hash(changed)))
    }

    @Test func strictRecordShapeTerminalPhaseAndBindingsReject() throws {
        let bytes = try record(manifest(oldID)).encoded()
        for key in ["version", "accountIDHash", "livePath", "journalPath", "transactionID", "terminalEnvelope", "treeEntries", "previous"] {
            let bad = try altered(bytes) { $0[key] = NSNull() }
            #expect(throws: (any Error).self) { try BootstrapHistoryRecordV1.decodeEnvelope(bad) }
        }
        for (key, value) in [("version", 2 as Any), ("accountIDHash", String(repeating: "b", count: 64)),
                             ("livePath", live + "-other"), ("journalPath", "other.json"),
                             ("transactionID", nextID.uuidString), ("unknown", true)] {
            let bad = try altered(bytes) { $0[key] = value }
            #expect(throws: (any Error).self) { try BootstrapHistoryRecordV1.decodeEnvelope(bad) }
        }
        let rolled = manifest(oldID, aborted: false)
        let prepared = try #require(rolled.body.preparedBody)
        for body in [BootstrapManifestV3.Body.prepared(prepared), .installed(prepared), .committed(prepared), .rollingBack(prepared)] {
            var terminal = rolled; terminal.body = body
            #expect(throws: (any Error).self) { try record(terminal, entries: tree(oldID)).encoded() }
        }
        let (_, records, _) = try chain()
        let badLink = try altered(records[0].bytes) { $0.removeValue(forKey: "previous") }
        #expect(throws: (any Error).self) { try BootstrapHistoryRecordV1.decodeEnvelope(badLink) }
    }

    @Test func pendingConnectsExactPreviousToCurrentAndAllowsOnlyAbsentOrCompletePhysicalRecord() throws {
        let (terminal, records, entries) = try chain()
        let ref = try #require(terminal.historyHead)
        let newest = try BootstrapHistoryRecordV1.decodeEnvelope(records[0].bytes)
        var current = manifest(currentID, head: newest.previous)
        current.body = .preparing(.init(sourceControlSHA256: nil, pendingSnapshotSHA256: digest,
            outputAllocation: .init(transactionID: currentID, allowedRoles: [.original], roleLimits: [
                .init(role: .original, maximumEntryCount: 10, reservedEncodedProofBytes: 10_000)]),
            predecessor: .init(record: records[0].bytes, reference: ref)))
        #expect(try SyncBootstrapHistory.validate(current: current, records: records, accountEntries: entries).count == 2)
        let oldOnly = [records[1]]
        #expect(try SyncBootstrapHistory.validate(current: current, records: oldOnly,
            accountEntries: observations(oldOnly, trees: tree(oldID))).count == 2)
        let partial = SyncBootstrapHistory.SuppliedRecord(relativePath: records[0].relativePath, bytes: records[0].bytes.prefix(20))
        #expect(throws: (any Error).self) { try SyncBootstrapHistory.validate(current: current, records: [partial, records[1]], accountEntries: entries) }
        let mismatch = try altered(records[0].bytes) { $0["transactionID"] = currentID.uuidString }
        let mismatchRef = reference(mismatch, previous: newest.previous)
        current.body = .preparing(.init(sourceControlSHA256: nil, pendingSnapshotSHA256: digest,
            outputAllocation: .init(transactionID: currentID, allowedRoles: [.original], roleLimits: [
                .init(role: .original, maximumEntryCount: 10, reservedEncodedProofBytes: 10_000)]),
            predecessor: .init(record: mismatch, reference: mismatchRef)))
        #expect(throws: (any Error).self) { try SyncBootstrapHistory.validate(current: current, records: oldOnly,
            accountEntries: observations(oldOnly, trees: tree(oldID))) }
    }

    @Test(arguments: [false, true])
    func actualLegacyArchiveAndMissingRollbackEnvelopesBecomeStrictHistory(missing: Bool) throws {
        let fixture = try RecoveryInventoryFixture(); defer { fixture.remove() }
        if missing { _ = try fixture.makeMissingArchiveRollback() }
        else {
            let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [])
            try JSONEncoder().encode(archive).write(to: fixture.archiveURL)
            let context = SyncBootstrapContext(accountIDHash: fixture.account.accountIDHash, epoch: UUID(), freezeID: UUID())
            let tx = try SyncBootstrapTransaction(liveRoot: fixture.paths.workingSet, context: context, validateContext: { _ in })
            let local = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: fixture.paths.workingSet, deviceID: "fixture")
            let prepared = try tx.prepare(local: local, sourceArchive: archive,
                remote: .init(context: context, records: [], attachments: [:], isComplete: true))
            try tx.install(prepared); try tx.rollback(prepared)
        }
        let entries = try fixture.storage.withRecoveryInventory(paths: fixture.paths, account: fixture.account, maximumBytes: 100_000_000) { $0 }
            let active = try #require(entries.first { $0.relativePath.hasSuffix("/active.json") })
            let bytes = try Data(contentsOf: fixture.paths.accountRoot.appendingPathComponent(active.relativePath))
            let payload = try #require(JSONSerialization.jsonObject(with: OwnedBootstrapCodec.envelopePayload(bytes)) as? [String: Any])
            let id = try #require(UUID(uuidString: payload["id"] as! String))
            let root = String(active.relativePath.dropLast("active.json".count)) + id.uuidString
            let tree = entries.filter { $0.relativePath == root || $0.relativePath.hasPrefix(root + "/") }
            let value = BootstrapHistoryRecordV1(version: 1, accountIDHash: fixture.account.accountIDHash,
                livePath: payload["livePath"] as! String, journalPath: payload["journalPath"] as! String,
                transactionID: id, terminalEnvelope: bytes, treeEntries: tree, previous: nil)
            let legacy = try SyncBootstrapTransaction.legacyHistorySource(bytes)
            #expect(legacy.livePath == payload["livePath"] as? String)
            let encoded = try value.encoded()
            #expect(try BootstrapHistoryRecordV1.decodeEnvelope(encoded).terminalEnvelope == bytes)
            let damaged = try altered(encoded) { object in
                object["terminalEnvelope"] = try altered(bytes) { $0["phase"] = "committed" }.base64EncodedString()
            }
            #expect(throws: (any Error).self) { try BootstrapHistoryRecordV1.decodeEnvelope(damaged) }
            let mixed = try altered(encoded) { object in
                object["terminalEnvelope"] = try altered(bytes) { $0["historyHead"] = NSNull() }.base64EncodedString()
            }
            #expect(throws: (any Error).self) { try BootstrapHistoryRecordV1.decodeEnvelope(mixed) }
    }

    @Test func pendingCannotSubstituteDifferentOldHeadWithIdenticalTotals() throws {
        let (terminal, records, entries) = try chain()
        let newest = try BootstrapHistoryRecordV1.decodeEnvelope(records[0].bytes)
        let old = try #require(newest.previous)
        let falseHead = BootstrapHistoryRef(sha256: Data(repeating: 99, count: 32), byteCount: old.byteCount,
            recordCount: old.recordCount, chainByteCount: old.chainByteCount)
        var current = manifest(currentID, head: falseHead)
        current.body = .preparing(.init(sourceControlSHA256: nil, pendingSnapshotSHA256: digest,
            outputAllocation: .init(transactionID: currentID, allowedRoles: [.original], roleLimits: [
                .init(role: .original, maximumEntryCount: 10, reservedEncodedProofBytes: 10_000)]),
            predecessor: .init(record: records[0].bytes, reference: try #require(terminal.historyHead))))
        // Bare manifest deliberately checks only envelope and arithmetic.
        _ = try current.encoded()
        #expect(throws: (any Error).self) { try SyncBootstrapHistory.validate(current: current, records: records, accountEntries: entries) }
    }

    @Test func repeatedHistoricalUUIDAndSelfCycleReferenceReject() throws {
        let oldest = try record(manifest(oldID)).encoded(), first = reference(oldest)
        let newest = try record(manifest(oldID, head: first), previous: first).encoded()
        let records = [supplied(newest), supplied(oldest)]
        #expect(throws: (any Error).self) { try SyncBootstrapHistory.validate(current: manifest(currentID, head: reference(newest, previous: first)),
            records: records, accountEntries: observations(records)) }
        let cyclic = try altered(newest) { object in
            var previous = object["previous"] as! [String: Any]
            previous["sha256"] = OwnedBootstrapCodec.hash(newest).base64EncodedString()
            object["previous"] = previous
        }
        #expect(throws: (any Error).self) { try BootstrapHistoryRecordV1.decodeEnvelope(cyclic) }
    }

    @Test func exactUTF8FrozenEntriesAndPhysicalMetadataCannotBeChanged() throws {
        let root = namespace + "/" + oldID.uuidString
        let entries = tree(oldID) + [entry(root + "/Original/\u{e9}", directory: false, inode: 90)]
        let bytes = try record(manifest(oldID, entries: entries), entries: entries).encoded()
        for field in ["relativePath", "device", "inode", "byteCount", "sha256", "unknown"] {
            let bad = try altered(bytes) { object in
                var tree = object["treeEntries"] as! [[String: Any]]
                switch field {
                case "relativePath": tree[3][field] = root + "/Original/e\u{301}"
                case "sha256": tree[3][field] = Data(repeating: 8, count: 32).base64EncodedString()
                case "unknown": tree[3][field] = true
                default: tree[3][field] = 999
                }
                object["treeEntries"] = tree
            }
            #expect(throws: (any Error).self) { try BootstrapHistoryRecordV1.decodeEnvelope(bad) }
        }
        var changed = entries
        changed[3] = entry(root + "/Original/e\u{301}", directory: false, inode: 90)
        let records = [supplied(bytes)]
        #expect(throws: (any Error).self) { try SyncBootstrapHistory.validate(current: manifest(currentID, head: reference(bytes)),
            records: records, accountEntries: observations(records, trees: changed)) }
    }

    @Test func frozenPartialFileKeepsPerFileCapAndCompleteUniqueParentMetadata() throws {
        let root = namespace + "/" + oldID.uuidString
        let partial = Entry(relativePath: root + "/Original/.partial.tmp", isDirectory: false,
            byteCount: 100_000_000, sha256: digest, device: 1, inode: 90)
        let entries = (tree(oldID) + [partial]).sorted { OwnedBootstrapCodec.pathOrder($0.relativePath, $1.relativePath) }
        let value = try record(manifest(oldID, entries: entries), entries: entries)
        let bytes = try value.encoded()
        _ = try BootstrapHistoryRecordV1.decodeEnvelope(bytes)
        for damage in ["oversize", "missing-parent", "duplicate", "alias", "unknown-role", "unsorted", "same-inode"] {
            var damaged = entries
            switch damage {
            case "oversize": damaged[2] = .init(relativePath: partial.relativePath, isDirectory: false,
                byteCount: 100_000_001, sha256: digest, device: 1, inode: 90)
            case "missing-parent": damaged.remove(at: 1)
            case "duplicate": damaged.append(entries[2])
            case "alias": damaged.append(entry(root + "/original", inode: 99))
            case "unknown-role": damaged.append(entry(root + "/Unowned", inode: 99))
            case "unsorted": damaged.swapAt(1, 2)
            default: damaged[2] = .init(relativePath: partial.relativePath, isDirectory: false,
                byteCount: 1, sha256: digest, device: 1, inode: 10)
            }
            #expect(throws: (any Error).self) { try record(manifest(oldID, entries: damaged), entries: damaged).encoded() }
        }
    }

    @Test func linearChainIsBoundedByBytesWithoutInventedRecordCountLimit() throws {
        var head: BootstrapHistoryRef?
        var records: [SyncBootstrapHistory.SuppliedRecord] = []
        var ids: [UUID] = []
        for _ in 0..<129 {
            let id = UUID()
            let bytes = try record(manifest(id, head: head), previous: head).encoded()
            head = reference(bytes, previous: head)
            records.append(supplied(bytes)); ids.append(id)
        }
        let result = try SyncBootstrapHistory.validate(current: manifest(currentID, head: head),
            records: records, accountEntries: observations(records))
        #expect(result.map(\.transactionID) == ids.reversed())
    }

    @Test func recordFilenameAndSuppliedHistoryProofMustMatchExactBytes() throws {
        let (current, records, entries) = try chain()
        let wrongName = SyncBootstrapHistory.SuppliedRecord(relativePath: records[0].relativePath.uppercased(), bytes: records[0].bytes)
        #expect(throws: (any Error).self) { try SyncBootstrapHistory.validate(current: current, records: [wrongName, records[1]], accountEntries: entries) }
        let index = try #require(entries.firstIndex { $0.relativePath == records[0].relativePath })
        for damage in ["missing", "size", "hash", "directory"] {
            var changed = entries
            let old = entries[index]
            if damage == "missing" { changed.remove(at: index) }
            else { changed[index] = .init(relativePath: old.relativePath, isDirectory: damage == "directory",
                byteCount: damage == "size" ? old.byteCount + 1 : old.byteCount,
                sha256: damage == "hash" ? Data(repeating: 8, count: 32) : old.sha256, device: old.device, inode: old.inode) }
            #expect(throws: (any Error).self) { try SyncBootstrapHistory.validate(current: current, records: records, accountEntries: changed) }
        }
    }
}
