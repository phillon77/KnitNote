import CryptoKit
import Darwin
import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct SyncAccountSourceStateTests {
    @Test(arguments: ["account", "root", "inode", "journal"], [false, true])
    func absenceBarrierRejectsForeignStructuralBindings(change: String, spent: Bool) throws {
        let f = try SourceInventoryFixture(); defer { f.remove() }
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: SyncRecoveryVault(directory: f.paths.vault, keychain: SourceStateKeys()), journal: f.journal)
        let source = try #require(try tx.sourceState(now: .now))
        let root = change == "root" ? f.base.appendingPathComponent("foreign") : source.accountRoot
        let changed = SyncAccountSourceState(authorityID: source.authorityID, generation: source.generation,
            accountIDHash: change == "account" ? String(repeating: "0", count: 64) : source.accountIDHash,
            accountRoot: root, accountDevice: source.accountDevice,
            accountInode: change == "inode" ? source.accountInode + 1 : source.accountInode,
            archiveURL: root.appendingPathComponent("working-set/projects-v1.json"),
            journalURL: change == "journal" ? root.appendingPathComponent("journal/foreign.json") : root.appendingPathComponent("working-set/SyncMetadata/pending.json"),
            baselineSHA256: source.baselineSHA256, origin: source.origin)
        let main = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        let predecessor = Data(SHA256.hash(data: try Data(contentsOf: main)))
        let control: SyncAccountRecoveryControl = spent ? .sourceSpent(changed, transactionID: UUID(), preparedManifestSHA256: Data(repeating: 1, count: 32)) : .absentSource(changed)
        try SyncAccountRecoveryControlFile.encode(control, predecessorSHA256: predecessor).write(to: main)
        let before = try f.diskBytes()
        #expect(throws: (any Error).self) { try tx.synchronizeSelectionAbsence(now: .now) }
        #expect(try f.diskBytes() == before)
    }

    @Test func sourceRoutingRevalidatesBaselineAndNeverReportsSelection() throws {
        let f = try SourceInventoryFixture(); defer { f.remove() }
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: SyncRecoveryVault(directory: f.paths.vault, keychain: SourceStateKeys()), journal: f.journal)
        let source = try #require(try tx.sourceState(now: .now))
        #expect(try tx.lifecycleSnapshot(now: .now) == nil)
        try tx.synchronizeSelectionAbsence(now: .now)
        #expect(try tx.sourceState(now: .now) == source)
        try f.journal.enqueue(SyncMutation.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID()))
        let before = try f.diskBytes()
        #expect(throws: (any Error).self) { try tx.sourceState(now: .now) }
        try tx.synchronizeSelectionAbsence(now: .now)
        #expect(try f.diskBytes() == before)
    }

    @Test func spentSourceIsNotASelectionOrReusableActiveSource() throws {
        let f = try SourceInventoryFixture(); defer { f.remove() }
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: SyncRecoveryVault(directory: f.paths.vault, keychain: SourceStateKeys()), journal: f.journal)
        let source = try #require(try tx.sourceState(now: .now))
        let mainURL = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        let main = try Data(contentsOf: mainURL)
        try SyncAccountRecoveryControlFile.encode(.sourceSpent(source, transactionID: UUID(),
            preparedManifestSHA256: Data(repeating: 9, count: 32)), predecessorSHA256: Data(SHA256.hash(data: main))).write(to: mainURL)
        let before = try f.diskBytes()
        #expect(try tx.lifecycleSnapshot(now: .now) == nil)
        #expect(try tx.recoverInterruptedTransition(now: .now) == nil)
        #expect(try tx.sourceState(now: .now) == nil)
        #expect(throws: (any Error).self) { try tx.prepare(now: .now) }
        #expect(throws: (any Error).self) { try tx.consumeRestoredSelection(vaultID: UUID(), now: .now) }
        try tx.synchronizeSelectionAbsence(now: .now)
        #expect(try f.diskBytes() == before)
    }

    @Test func allSourceOriginsAndSpentControlRoundtripStrictly() throws {
        let f = sourceState()
        let hash = Data(repeating: 8, count: 32)
        let origins: [SyncAccountSourceOrigin] = [
            .restoredSelection(vaultID: UUID(), captureID: UUID(), envelopeSHA256: hash, packetSHA256: hash, deletionSHA256: nil),
            .restoredSelection(vaultID: UUID(), captureID: UUID(), envelopeSHA256: hash, packetSHA256: hash, deletionSHA256: hash),
            .bootstrapRollback(transactionID: UUID(), activeRelativePath: ".KnitNote-SyncBootstrap/account/tree/active.json", activeEnvelopeSHA256: hash)
        ]
        for origin in origins {
            let state = SyncAccountSourceState(authorityID: f.authorityID, generation: f.generation,
                accountIDHash: f.accountIDHash, accountRoot: f.accountRoot, accountDevice: f.accountDevice,
                accountInode: f.accountInode, archiveURL: f.archiveURL, journalURL: f.journalURL,
                baselineSHA256: f.baselineSHA256, origin: origin)
            for control in [SyncAccountRecoveryControl.absentSource(state),
                            .sourceSpent(state, transactionID: UUID(), preparedManifestSHA256: hash)] {
                let bytes = try SyncAccountRecoveryControlFile.encode(control, predecessorSHA256: hash)
                #expect(try SyncAccountRecoveryControlFile.decode(bytes) == control)
                #expect(try SyncAccountRecoveryControlFile.observation(mainBytes: bytes, nextBytes: nil).state == control)
                for field in ["mixed", "nullHash", "badHash"] {
                    var wire = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
                    var payload = try JSONSerialization.jsonObject(with: Data(base64Encoded: wire["payload"] as! String)!) as! [String: Any]
                    var source = payload["source"] as! [String: Any]
                    var altered = source["origin"] as! [String: Any]
                    if field == "mixed" { altered["allocationID"] = UUID().uuidString }
                    else {
                        let key = altered["kind"] as! String == "bootstrapRollback" ? "activeEnvelopeSHA256" : "packetSHA256"
                        altered[key] = field == "nullHash" ? NSNull() : Data([1]).base64EncodedString()
                    }
                    source["origin"] = altered; payload["source"] = source
                    let payloadBytes = try canonicalJSON(payload)
                    wire["payload"] = payloadBytes.base64EncodedString()
                    wire["checksum"] = Data(SHA256.hash(data: try canonicalJSON([
                        "predecessorSHA256": hash.base64EncodedString(), "payload": payloadBytes.base64EncodedString()
                    ]))).base64EncodedString()
                    let invalid = try canonicalJSON(wire)
                    #expect(throws: (any Error).self) { try SyncAccountRecoveryControlFile.observation(mainBytes: invalid, nextBytes: nil) }
                }
            }
        }
    }

    @Test func pendingMarkerOrderAndContentChangeBaseline() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        let a = try f.addDeletion(ledger: ledger, name: "first")
        let b = try f.addDeletion(ledger: ledger, name: "second")
        try ledger.purge(now: Date(timeIntervalSince1970: 2_592_100),
            references: .init(acknowledgedRemovalVersionIDs: Set((a.versions + b.versions).map(\.versionID))))
        let markers = try ledger.pendingDeletionMarkerVersions()
        let first = try #require(markers.first)
        let second = try #require(markers.first { $0 != first })
        func digest(_ markers: [SyncRecordVersion]) throws -> Data {
            try SyncAccountSourceBaseline.digest(entries: [], accountRoot: f.paths.accountRoot,
                journalURL: f.paths.mutationJournalURL, mutations: [], selectedFiles: [], deletionLedger: nil,
                pendingMarkerVersions: markers)
        }
        let original = try digest([first, second])
        #expect(try digest([second, first]) != original)
        #expect(try digest([first, first]) != original)
    }

    @Test func v1IntentBytesStayUnchanged() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: SyncRecoveryVault(directory: f.paths.vault, keychain: SourceStateKeys()), journal: f.journal)
        _ = try tx.seal(tx.prepare(now: .now), now: .now)
        let bytes = try Data(contentsOf: f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json"))
        guard case .legacySelection(let intent) = try SyncAccountRecoveryControlFile.decode(bytes) else {
            Issue.record("v1 selection lost"); return
        }
        #expect(intent.formatVersion == 1)
        #expect(try SyncAccountRecoveryControlFile.encode(.legacySelection(intent), predecessorSHA256: nil) == bytes)
    }

    @Test func v2ControlRejectsUnknownMixedAndNullFields() throws {
        let state = sourceState()
        let bytes = try SyncAccountRecoveryControlFile.encode(.absentSource(state), predecessorSHA256: nil)
        #expect(try SyncAccountRecoveryControlFile.decode(bytes) == .absentSource(state))
        let original = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        for field in ["extra", "payload", "checksum", "predecessorSHA256", "formatVersion"] {
            var object = original
            if field == "predecessorSHA256" { object.removeValue(forKey: field) }
            else { object[field] = NSNull() }
            #expect(throws: (any Error).self) {
                try SyncAccountRecoveryControlFile.decode(JSONSerialization.data(withJSONObject: object))
            }
        }
        for field in ["unknown", "transactionID", "source", "kind"] {
            var object = original
            var payload = try JSONSerialization.jsonObject(with: Data(base64Encoded: object["payload"] as! String)!) as! [String: Any]
            payload[field] = NSNull()
            let payloadBytes = try canonicalJSON(payload)
            object["payload"] = payloadBytes.base64EncodedString()
            object["checksum"] = Data(SHA256.hash(data: try canonicalJSON([
                "predecessorSHA256": NSNull(), "payload": payloadBytes.base64EncodedString()
            ]))).base64EncodedString()
            #expect(throws: (any Error).self) {
                try SyncAccountRecoveryControlFile.decode(JSONSerialization.data(withJSONObject: object))
            }
        }
    }

    @Test func derivativeNeedsExactMainPredecessor() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        try f.storage.withRecoveryOwnership(paths: f.paths, account: f.account, maximumBytes: 100_000_000, createControl: true) { access in
            let root = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1")
            let main = try SyncAccountRecoveryControlFile.encode(.absentSource(sourceState()), predecessorSHA256: nil)
            let wrong = try SyncAccountRecoveryControlFile.encode(.absentSource(sourceState()), predecessorSHA256: Data(repeating: 1, count: 32))
            try wrong.write(to: root.appendingPathComponent("intent-next.json"))
            let control = SyncAccountRecoveryControlFile(synchronize: { _ in })
            #expect(throws: (any Error).self) { try control.observe(access: access) }
            try main.write(to: root.appendingPathComponent("intent.json"))
            #expect(throws: (any Error).self) { try control.observe(access: access) }
            let next = try SyncAccountRecoveryControlFile.encode(.absentSource(sourceState()), predecessorSHA256: Data(SHA256.hash(data: main)))
            try next.write(to: root.appendingPathComponent("intent-next.json"))
            #expect(try control.observe(access: access).mainBytes == main)
        }
    }

    @Test func selectedStateAndEnvelopeMustBindSamePredecessor() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: SyncRecoveryVault(directory: f.paths.vault, keychain: SourceStateKeys()), journal: f.journal)
        _ = try tx.seal(tx.prepare(now: .now), now: .now)
        let old = try Data(contentsOf: f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json"))
        guard case .legacySelection(let intent) = try SyncAccountRecoveryControlFile.decode(old) else {
            Issue.record("Expected v1 selection"); return
        }
        let predecessor = Data(SHA256.hash(data: old))
        let selected = SyncAccountRecoveryControl.selectedRecovery(intent, predecessorSHA256: predecessor)
        let bytes = try SyncAccountRecoveryControlFile.encode(selected, predecessorSHA256: predecessor)
        #expect(try SyncAccountRecoveryControlFile.decode(bytes) == selected)
        #expect(throws: (any Error).self) {
            try SyncAccountRecoveryControlFile.encode(selected, predecessorSHA256: Data(repeating: 1, count: 32))
        }
        var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        let wrong = Data(repeating: 1, count: 32).base64EncodedString()
        object["predecessorSHA256"] = wrong
        object["checksum"] = Data(SHA256.hash(data: try canonicalJSON([
            "predecessorSHA256": wrong, "payload": object["payload"]!
        ]))).base64EncodedString()
        #expect(throws: (any Error).self) {
            try SyncAccountRecoveryControlFile.decode(JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func controlAllowsExact8192ByteReadButRejectsOneByteMore() throws {
        let bytes = try SyncAccountRecoveryControlFile.encode(.absentSource(sourceState()), predecessorSHA256: nil)
        var padded = bytes + Data(repeating: 32, count: 8192 - bytes.count)
        _ = try SyncAccountRecoveryControlFile.decode(padded)
        padded.append(32)
        #expect(throws: SyncAccountRecoveryTransaction.Error.tooLarge) { try SyncAccountRecoveryControlFile.decode(padded) }
    }

    @Test func externalJournalFamilyUsesNativeNamesNotArbitrarySuffixes() throws {
        let root = URL(fileURLWithPath: "/fixture/account")
        let journal = root.appendingPathComponent("journal/pending")
        func digest(_ path: String?) throws -> Data {
            let entries: [SyncAccountRecoveryInventory.Entry] = path.map {
                [.init(relativePath: $0, isDirectory: false, byteCount: 1,
                    sha256: Data(repeating: 1, count: 32), device: 1, inode: 1)]
            } ?? []
            return try SyncAccountSourceBaseline.digest(entries: entries, accountRoot: root, journalURL: journal,
                mutations: [], selectedFiles: [], deletionLedger: nil, pendingMarkerVersions: [])
        }
        let empty = try digest(nil)
        for suffix in ["", ".checkpoint", ".segment", ".migrated", ".proofs.00000000", ".proofs.00999999"] {
            #expect(try digest("journal/pending" + suffix) != empty)
        }
        // Native locking flocks the parent directory; no journal.lock artifact.
        for suffix in [".lock", ".checkpoint.other", ".proofs.01000000", ".proofs.1", ".proofs.00000000.other"] {
            #expect(try digest("journal/pending" + suffix) == empty)
        }
    }

    @Test func portableBaselineBindsFIFOAndSelectedSources() throws {
        let root = URL(fileURLWithPath: "/fixture/account", isDirectory: true)
        let journal = root.appendingPathComponent("journal/pending")
        let a = SyncMutation.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID())
        let b = SyncMutation.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID())
        func entry(_ path: String, _ value: UInt8 = 1, inode: UInt64 = 1) -> SyncAccountRecoveryInventory.Entry {
            .init(relativePath: path, isDirectory: false, byteCount: 1, sha256: Data(repeating: value, count: 32), device: 1, inode: inode)
        }
        let selected = SyncPendingRecoveryPacket.File(relativePath: "staging/selected", byteCount: 1,
            sha256: Data(repeating: 1, count: 32), bytes: Data([1]))
        func digest(_ entries: [SyncAccountRecoveryInventory.Entry], _ mutations: [SyncMutation] = [a, b], ledger: Data? = nil) throws -> Data {
            try SyncAccountSourceBaseline.digest(entries: entries, accountRoot: root, journalURL: journal,
                mutations: mutations, selectedFiles: [selected], deletionLedger: ledger, pendingMarkerVersions: [])
        }
        let entries = [entry("working-set/a"), entry("journal/pending.segment"), entry("staging/selected"), entry("engine-state/unselected")]
        let baseline = try digest(entries)
        #expect(try digest(entries.reversed()) == baseline)
        #expect(try digest(entries.map { entry($0.relativePath, inode: 99) }) == baseline)
        #expect(try digest(Array(entries.dropLast()) + [entry("engine-state/unselected", 2)]) == baseline)
        #expect(try digest(entries, [b, a]) != baseline)
        #expect(try digest(entries, ledger: Data([7])) != baseline)
        for index in 0..<3 {
            var changed = entries; changed[index] = entry(entries[index].relativePath, 2)
            #expect(try digest(changed) != baseline)
        }
    }

    @Test(arguments: [0, 1, 2, 3, 4, 5, 6, 7])
    func replacementRetainsExactPredecessorAcrossDurabilityFaults(failAt: Int) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        try f.storage.withRecoveryOwnership(paths: f.paths, account: f.account, maximumBytes: 100_000_000, createControl: true) { access in
            let mainURL = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
            let oldState = sourceState(), newState = sourceState()
            let old = try SyncAccountRecoveryControlFile.encode(.absentSource(oldState), predecessorSHA256: nil)
            try old.write(to: mainURL)
            let fault = ControlSyncFault(failAt: failAt)
            let control = SyncAccountRecoveryControlFile(synchronize: { try fault.sync($0) })
            let observed = try control.observe(access: access)
            if failAt == 0 {
                let result = try control.replace(observed, with: .absentSource(newState), access: access, validateSource: {})
                #expect(result.state == .absentSource(newState))
                #expect(result.nextBytes == nil)
                let object = try JSONSerialization.jsonObject(with: #require(result.mainBytes)) as! [String: Any]
                #expect(object["predecessorSHA256"] as? String == Data(SHA256.hash(data: old)).base64EncodedString())
            } else {
                #expect(throws: (any Error).self) {
                    try control.replace(observed, with: .absentSource(newState), access: access, validateSource: {})
                }
                let reopened = SyncAccountRecoveryControlFile(synchronize: { fd in
                    guard fsync(fd) == 0 else { throw ControlFailure.injected }
                })
                let result = try reopened.observe(access: access)
                #expect(result.mainBytes == old || result.state == .absentSource(newState))
                try reopened.synchronize(result, access: access)
            }
        }
    }

    @Test(arguments: [false, true]) func replacementChecksSourceAndExactControlAgain(afterNext: Bool) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        try f.storage.withRecoveryOwnership(paths: f.paths, account: f.account, maximumBytes: 100_000_000, createControl: true) { access in
            let mainURL = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
            let old = try SyncAccountRecoveryControlFile.encode(.absentSource(sourceState()), predecessorSHA256: nil)
            try old.write(to: mainURL)
            let control = SyncAccountRecoveryControlFile(synchronize: { _ in })
            let observation = try control.observe(access: access)
            var checks = 0
            #expect(throws: (any Error).self) {
                try control.replace(observation, with: .absentSource(sourceState()), access: access, validateSource: {
                    checks += 1
                    if checks == (afterNext ? 2 : 1) { throw ControlFailure.injected }
                })
            }
            #expect(try Data(contentsOf: mainURL) == old)
            #expect(checks == (afterNext ? 2 : 1))
            let replacement = try SyncAccountRecoveryControlFile.encode(.absentSource(sourceState()), predecessorSHA256: nil)
            try replacement.write(to: mainURL)
            #expect(throws: (any Error).self) {
                try control.replace(observation, with: .absentSource(sourceState()), access: access, validateSource: {})
            }
            #expect(try Data(contentsOf: mainURL) == replacement)
        }
    }

    @Test(arguments: [false, true]) func replacementWriteOrRenameFailurePreservesMain(failRename: Bool) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        try f.storage.withRecoveryOwnership(paths: f.paths, account: f.account, maximumBytes: 100_000_000, createControl: true) { access in
            let directory = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1")
            let main = directory.appendingPathComponent("intent.json")
            let old = try SyncAccountRecoveryControlFile.encode(.absentSource(sourceState()), predecessorSHA256: nil)
            try old.write(to: main)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            let control = SyncAccountRecoveryControlFile(synchronize: { _ in })
            let observed = try control.observe(access: access)
            var checks = 0
            #expect(throws: SyncAccountRecoveryTransaction.Error.unavailable) {
                try control.replace(observed, with: .absentSource(sourceState()), access: access, validateSource: {
                    checks += 1
                    if checks == (failRename ? 2 : 1) {
                        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
                    }
                })
            }
            #expect(try Data(contentsOf: main) == old)
        }
    }

    @Test(arguments: ["symlink", "hardlink", "oversized", "directory"])
    func controlRejectsUnsafeMainWithoutChangingSource(kind: String) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let source = f.paths.workingSet.appendingPathComponent("preserved")
        let bytes = Data("source".utf8); try bytes.write(to: source)
        #expect(throws: (any Error).self) {
            try f.storage.withRecoveryOwnership(paths: f.paths, account: f.account, maximumBytes: 100_000_000, createControl: true) { access in
                let main = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
                if kind == "symlink" { try FileManager.default.createSymbolicLink(at: main, withDestinationURL: source) }
                else if kind == "hardlink" { try FileManager.default.linkItem(at: source, to: main) }
                else if kind == "directory" { try FileManager.default.createDirectory(at: main, withIntermediateDirectories: false) }
                else { try Data(repeating: 1, count: 8193).write(to: main) }
                _ = try SyncAccountRecoveryControlFile(synchronize: { _ in }).observe(access: access)
            }
        }
        #expect(try Data(contentsOf: source) == bytes)
    }

    private func sourceState() -> SyncAccountSourceState {
        let root = URL(fileURLWithPath: "/fixture/account", isDirectory: true)
        return .init(authorityID: UUID(), generation: UUID(), accountIDHash: String(repeating: "a", count: 64),
            accountRoot: root, accountDevice: 1, accountInode: 2,
            archiveURL: root.appendingPathComponent("working-set/projects-v1.json"),
            journalURL: root.appendingPathComponent("working-set/SyncMetadata/pending.json"),
            baselineSHA256: Data(repeating: 1, count: 32), origin: .freshAllocation(allocationID: UUID()))
    }
    private func canonicalJSON(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

private final class SourceStateKeys: SyncRecoveryVaultKeychain, @unchecked Sendable {
    var values: [UUID: Data] = [:]
    func insert(_ key: Data, for id: UUID) throws { values[id] = key }
    func key(for id: UUID) throws -> Data? { values[id] }
    func remove(for id: UUID) throws { values[id] = nil }
}

private enum ControlFailure: Error { case injected }
private final class ControlSyncFault: @unchecked Sendable {
    var count = 0
    let failAt: Int
    init(failAt: Int) { self.failAt = failAt }
    func sync(_ fd: Int32) throws {
        count += 1
        if count == failAt { throw ControlFailure.injected }
        guard fsync(fd) == 0 else { throw ControlFailure.injected }
    }
}
