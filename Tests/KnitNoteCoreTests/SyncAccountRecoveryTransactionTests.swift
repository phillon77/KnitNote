import CryptoKit
import Darwin
import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct SyncAccountRecoveryTransactionTests {
    @Test(arguments: ["main", "next"])
    func sourceControlOnlyMutationRejectsSeal(change: String) throws {
        let f = try SourceInventoryFixture(); defer { f.remove() }
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys())
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: f.journal)
        let prepared = try tx.prepare(now: .now)
        let entries = try f.capture().entries
        let mainURL = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        let main = try Data(contentsOf: mainURL)
        guard case .absentSource(let state) = try SyncAccountRecoveryControlFile.decode(main) else { Issue.record("Missing source"); return }
        let changed = try SyncAccountRecoveryControlFile.encode(.absentSource(state), predecessorSHA256: Data(SHA256.hash(data: main)))
        try changed.write(to: change == "main" ? mainURL : mainURL.deletingLastPathComponent().appendingPathComponent("intent-next.json"))
        #expect(try f.capture().entries == entries)
        let before = try f.diskBytes()
        #expect(throws: (any Error).self) { try tx.seal(prepared, now: .now) }
        #expect(try f.diskBytes() == before)
    }

    @Test func freshSourceSealAuthenticatesV2Inventory() throws {
        let f = try SourceInventoryFixture(); defer { f.remove() }
        let keys = TransactionKeys()
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: keys)
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: f.journal)
        #expect(try tx.lifecycleSnapshot(now: .now) == nil)
        let original = try Data(contentsOf: f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json"))
        let receipt = try tx.seal(tx.prepare(now: .now), now: .now)
        let payload = try vault.restore(receipt.vaultID, account: f.account, now: .now)
        let wire = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        #expect(wire["formatVersion"] as? Int == 2)
        let capture = try #require(wire["sourceControl"] as? [String: Any])
        #expect(capture["mainBytes"] as? String == original.base64EncodedString())
        #expect(capture["nextBytes"] is NSNull)
        let selection = try #require(try tx.authenticatedSelection(now: .now))
        guard case .absent(let evidence) = selection.inventory.sourceAuthority else { Issue.record("Missing source evidence"); return }
        guard case .absentSource(let source) = try SyncAccountRecoveryControlFile.decode(original) else { Issue.record("Missing original"); return }
        #expect(evidence.state == source)
        keys.values.removeAll()
        let before = try f.diskBytes()
        #expect(throws: (any Error).self) { try tx.cleanup(receipt) }
        #expect(try f.diskBytes() == before)
    }

    @Test func selectedV2TransitionsPreserveCaptureWhileEdgesChange() throws {
        let f = try SourceInventoryFixture(); defer { f.remove() }
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys())
        let fault = TransactionSyncFault()
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: vault, journal: f.journal, synchronize: fault.sync)
        let mainURL = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        var previous = try Data(contentsOf: mainURL)
        var phases: [SyncAccountRecoveryTransaction.Phase] = []
        fault.onSync = { _ in
            let bytes = try Data(contentsOf: mainURL)
            if bytes != previous {
                guard case .selectedRecovery(let intent, let predecessor) = try SyncAccountRecoveryControlFile.decode(bytes) else { Issue.record("Expected selected v2"); return }
                #expect(predecessor == Data(SHA256.hash(data: previous)))
                phases.append(intent.phase); previous = bytes
            }
        }
        let receipt = try tx.seal(tx.prepare(now: .now), now: .now)
        let payload = try vault.restore(receipt.vaultID, account: f.account, now: .now)
        try tx.cleanup(receipt)
        try tx.restore(vaultID: receipt.vaultID, now: .now)
        #expect(phases == [.sealed, .cleanupStarted, .cleanupComplete, .restoreStarted, .replayComplete])
        #expect(try tx.authenticatedSelection(now: .now)?.receipt == receipt)
        #expect(try vault.restore(receipt.vaultID, account: f.account, now: .now) == payload)
    }

    @Test(arguments: [false, true])
    func legacyOpaqueDerivativeRequiresAuthenticatedOwner(expired: Bool) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let keys = TransactionKeys()
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: keys)
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: f.journal)
        let now = Date.now
        _ = try tx.seal(tx.prepare(now: now), now: now)
        let next = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent-next.json")
        try Data("{\"formatVersion\":1,".utf8).write(to: next)
        if !expired { keys.values.removeAll() }
        let before = try f.diskBytes()
        #expect(throws: (any Error).self) {
            try tx.recoverInterruptedTransition(now: expired ? now.addingTimeInterval(2_592_001) : now)
        }
        #expect(try f.diskBytes() == before)
    }

    @Test(arguments: [false, true], ["delete", "modify", "unchanged"])
    func retainedOldSessionCannotDisappearBeforeCleanupStarted(existingOnly: Bool, change: String) throws {
        let f = try SourceInventoryFixture(); defer { f.remove() }
        // An abandoned session belongs to an earlier process. close() is
        // intentionally allowed to remove only this fixture's current session.
        let oldFile = f.paths.decryptedTemporary.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString.lowercased()).appendingPathComponent("retained")
        try FileManager.default.createDirectory(at: oldFile.deletingLastPathComponent(), withIntermediateDirectories: false)
        try Data([1, 2, 3]).write(to: oldFile)
        try f.storage.close()
        let paths = try existingOnly ? f.storage.openExistingAccount(identity: f.account, validateAccount: {})
            : f.storage.openForVerifiedAccount(identity: f.account, validateAccount: {})
        let vault = SyncRecoveryVault(directory: paths.vault, keychain: TransactionKeys())
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: paths, account: f.account, vault: vault, journal: f.journal)
        let receipt = try tx.seal(tx.prepare(now: .now), now: .now)
        #expect(try tx.authenticatedSelection(now: .now)?.inventory.entries.contains { $0.relativePath.hasSuffix("/retained") } == true)
        if change == "delete" { try FileManager.default.removeItem(at: oldFile) }
        if change == "modify" { try Data([9, 8, 7]).write(to: oldFile) }
        if change != "unchanged" {
            let before = try f.diskBytes()
            #expect(throws: (any Error).self) { try tx.cleanup(receipt) }
            #expect(try f.diskBytes() == before)
        } else {
            try tx.cleanup(receipt)
            #expect(!FileManager.default.fileExists(atPath: oldFile.deletingLastPathComponent().path))
            try tx.restore(vaultID: receipt.vaultID, now: .now)
            #expect(try tx.authenticatedSelection(now: .now)?.phase == .replayComplete)
        }
    }

    @Test func sourceEnvelopeBudgetIncludesOuterBase64BeforeMediaRead() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let journal = try f.makeMissingArchiveRollback(withMedia: true)
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys())
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: journal)
        let receipt = try tx.seal(tx.prepare(now: .now), now: .now)
        let payload = try vault.restore(receipt.vaultID, account: f.account, now: .now)
        let selected = try #require(try tx.authenticatedSelection(now: .now)?.inventory.packet.files.first)
        // Return this isolated fixture to its exact preselection no-main source.
        try FileManager.default.removeItem(at: f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json"))
        let exact = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: vault, journal: journal, maximumBytes: payload.count)
        _ = try exact.prepare(now: .now)
        let source = f.paths.accountRoot.appendingPathComponent(selected.relativePath)
        let before = try f.diskBytes()
        let observed = FileSyncMutationJournal(url: f.paths.mutationJournalURL, reader: SyncRegularFileReader(beforeRead: {
            try Data().write(to: source)
        }))
        let bounded = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: vault, journal: observed, maximumBytes: payload.count - 1)
        #expect(throws: SyncPendingRecoveryPacketError.tooLarge) { try bounded.prepare(now: .now) }
        #expect(try Data(contentsOf: source).isEmpty)
        try selected.bytes.write(to: source)
        #expect(try f.diskBytes() == before)
    }

    @Test func rollbackV2RestoresOnlySelectedMediaDeletionAndCurrentSession() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        let deleted = try f.addDeletion(ledger: ledger, name: "pending deletion", attachment: true)
        let expired = try f.addDeletion(ledger: ledger, name: "expired")
        try ledger.purge(now: Date(timeIntervalSince1970: 2_592_100),
            references: .init(acknowledgedRemovalVersionIDs: Set(expired.versions.map(\.versionID))))
        let native = FileSyncMutationJournal(url: f.paths.mutationJournalURL)
        try native.enqueue(SyncMutation.save(recordVersion: deleted.versions[0], mutationID: UUID()))
        let journal = try f.makeMissingArchiveRollback(withMedia: true)
        let pending = try journal.pending()
        let abandoned = f.paths.decryptedTemporary.deletingLastPathComponent().appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
        try Data("old decoded copy".utf8).write(to: abandoned.appendingPathComponent("copy"))
        try Data("unselected".utf8).write(to: f.paths.quarantine.appendingPathComponent("discard"))
        // The original owner can select a no-control legacy rollback. Its
        // existing generic open gate is outside this source-selector adapter.
        let paths = f.paths
        let vault = SyncRecoveryVault(directory: paths.vault, keychain: TransactionKeys())
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: paths, account: f.account, vault: vault, journal: journal)
        let receipt = try tx.seal(tx.prepare(now: .now), now: .now)
        let captured = try #require(try tx.authenticatedSelection(now: .now)).inventory
        #expect(!captured.packet.files.isEmpty && !captured.deletionFiles.isEmpty && !captured.pendingMarkerVersions.isEmpty)
        #expect(captured.entries.contains { $0.relativePath.hasSuffix("/copy") })
        try tx.cleanup(receipt)
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        try tx.restore(vaultID: receipt.vaultID, now: .now)
        #expect(try journal.pending() == pending)
        for file in captured.packet.files + captured.deletionFiles {
            #expect(try Data(contentsOf: paths.accountRoot.appendingPathComponent(file.relativePath)) == file.bytes)
        }
        try f.storage.withRecoveryOwnership(paths: paths, account: f.account, maximumBytes: 100_000_000) { access in
            let entries = try access.entries()
            let expected = Set((captured.packet.files + captured.deletionFiles).map(\.relativePath))
                .union(["working-set/.sync-deletions/ledger.json", "working-set/SyncMetadata/pending.json.segment"])
            #expect(Set(entries.filter { !$0.isDirectory }.map(\.relativePath)) == expected)
            #expect(entries.filter { $0.relativePath.hasPrefix(".decrypted-temporary/") }.map(\.relativePath) ==
                [".decrypted-temporary/" + paths.decryptedTemporary.lastPathComponent])
        }
        #expect(try tx.authenticatedSelection(now: .now)?.phase == .replayComplete)
    }

    @Test func legacyRollbackReplayCompleteNormalizesOpaqueDerivativeOnlyAfterAuthentication() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let journal = try f.makeMissingArchiveRollback()
        let keys = TransactionKeys()
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: keys)
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: journal)
        let receipt = try tx.seal(tx.prepare(now: .now), now: .now)
        try tx.cleanup(receipt); try tx.restore(vaultID: receipt.vaultID, now: .now)
        let main = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        let next = main.deletingLastPathComponent().appendingPathComponent("intent-next.json")
        let original = try Data(contentsOf: main)
        try Data("opaque legacy derivative".utf8).write(to: next)
        let key = try #require(keys.values[receipt.vaultID])
        keys.values.removeAll()
        let before = try f.diskBytes()
        #expect(throws: (any Error).self) { try tx.restore(vaultID: receipt.vaultID, now: .now) }
        #expect(try f.diskBytes() == before)
        keys.values[receipt.vaultID] = key
        try tx.restore(vaultID: receipt.vaultID, now: .now)
        #expect(try Data(contentsOf: main) == original)
        #expect(!FileManager.default.fileExists(atPath: next.path))
        #expect(try tx.authenticatedSelection(now: .now)?.receipt == receipt)
    }

    @Test(arguments: ["cleanupStarted", "cleanupComplete", "restoreStarted", "replayComplete"], ["beforeRename", "afterRename"])
    func selectedV2PhaseCutsReauthenticateBeforeRetry(phase: String, cut: String) throws {
        let f = try SourceInventoryFixture(); defer { f.remove() }
        try Data([1, 2]).write(to: f.paths.engineState.appendingPathComponent("discard"))
        let keys = TransactionKeys(), fault = TransactionSyncFault()
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: keys)
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: vault, journal: f.journal, synchronize: fault.sync)
        let receipt = try tx.seal(tx.prepare(now: .now), now: .now)
        let payload = try vault.restore(receipt.vaultID, account: f.account, now: .now)
        let restoring = phase == "restoreStarted" || phase == "replayComplete"
        if restoring { try tx.cleanup(receipt) }
        let controlRoot = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1")
        let target = controlRoot.appendingPathComponent(cut == "beforeRename" ? "intent-next.json" : "intent.json")
        fault.onSync = { _ in
            if FileManager.default.fileExists(atPath: target.path),
               case .selectedRecovery(let intent, _) = try SyncAccountRecoveryControlFile.decode(Data(contentsOf: target)),
               intent.phase.rawValue == phase { throw TransactionFailure.injected }
        }
        #expect(throws: TransactionFailure.injected) {
            if restoring { try tx.restore(vaultID: receipt.vaultID, now: .now) }
            else { try tx.cleanup(receipt) }
        }
        fault.onSync = nil
        let key = try #require(keys.values[receipt.vaultID])
        keys.values.removeAll()
        let before = try f.diskBytes()
        #expect(throws: (any Error).self) {
            if restoring { try tx.restore(vaultID: receipt.vaultID, now: .now) }
            else { try tx.cleanup(receipt) }
        }
        #expect(try f.diskBytes() == before)
        keys.values[receipt.vaultID] = key
        if restoring { try tx.restore(vaultID: receipt.vaultID, now: .now) }
        else { try tx.cleanup(receipt) }
        #expect(try tx.authenticatedSelection(now: .now)?.phase == (restoring ? .replayComplete : .cleanupComplete))
        #expect(try vault.restore(receipt.vaultID, account: f.account, now: .now) == payload)
        #expect(!FileManager.default.fileExists(atPath: controlRoot.appendingPathComponent("intent-next.json").path))
    }

    @Test(arguments: ["tornV2", "wrongPredecessor", "mainless"])
    func survivingSourceDerivativeNeverGrantsAuthority(change: String) throws {
        let f = try SourceInventoryFixture(); defer { f.remove() }
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys())
        let fault = TransactionSyncFault()
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: vault, journal: f.journal, synchronize: fault.sync)
        let mainURL = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        let nextURL = mainURL.deletingLastPathComponent().appendingPathComponent("intent-next.json")
        let prepared = try tx.prepare(now: .now)
        fault.onSync = { _ in
            if FileManager.default.fileExists(atPath: nextURL.path) { throw TransactionFailure.injected }
        }
        #expect(throws: TransactionFailure.injected) { try tx.seal(prepared, now: .now) }
        fault.onSync = nil
        if change == "tornV2" { try Data("{\"formatVersion\":2}".utf8).write(to: nextURL) }
        if change == "mainless" { try FileManager.default.removeItem(at: mainURL) }
        if change == "wrongPredecessor" {
            guard case .selectedRecovery(let intent, _) = try SyncAccountRecoveryControlFile.decode(Data(contentsOf: nextURL)) else { Issue.record("Missing selection"); return }
            let wrong = Data(repeating: 5, count: 32)
            try SyncAccountRecoveryControlFile.encode(.selectedRecovery(intent, predecessorSHA256: wrong), predecessorSHA256: wrong).write(to: nextURL)
        }
        let before = try f.diskBytes()
        #expect(throws: (any Error).self) { try tx.prepare(now: .now) }
        #expect(throws: (any Error).self) { try tx.seal(prepared, now: .now) }
        #expect(throws: (any Error).self) { try tx.recoverInterruptedTransition(now: .now) }
        #expect(try f.diskBytes() == before)
    }

    @Test(arguments: ["beforeRename", "afterRename"], [false, true])
    func v2SealFailurePreservesExactSourceAndRequiresCurrentVault(cut: String, removeKey: Bool) throws {
        let f = try SourceInventoryFixture(); defer { f.remove() }
        try Data([1]).write(to: f.paths.engineState.appendingPathComponent("retained"))
        let keys = TransactionKeys(), fault = TransactionSyncFault()
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: keys)
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: vault, journal: f.journal, synchronize: fault.sync)
        let mainURL = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        let nextURL = mainURL.deletingLastPathComponent().appendingPathComponent("intent-next.json")
        let original = try Data(contentsOf: mainURL)
        let prepared = try tx.prepare(now: .now)
        fault.onSync = { _ in
            if cut == "beforeRename" && FileManager.default.fileExists(atPath: nextURL.path) { throw TransactionFailure.injected }
            if cut == "afterRename", try Data(contentsOf: mainURL) != original { throw TransactionFailure.injected }
        }
        #expect(throws: TransactionFailure.injected) { try tx.seal(prepared, now: .now) }
        fault.onSync = nil
        let selectedBytes = try Data(contentsOf: cut == "beforeRename" ? nextURL : mainURL)
        guard case .selectedRecovery(let intent, _) = try SyncAccountRecoveryControlFile.decode(selectedBytes) else { Issue.record("Missing actual selection"); return }
        _ = try vault.restore(intent.vaultID, account: f.account, now: .now)
        if cut == "beforeRename" {
            #expect(try Data(contentsOf: mainURL) == original)
            let before = try f.diskBytes()
            #expect(throws: (any Error).self) { try tx.seal(prepared, now: .now) }
            #expect(try f.diskBytes() == before)
            // A fresh prepared captures the surviving derivative as immutable
            // evidence; only the still-active source authorizes its replacement.
            let receipt = try tx.seal(tx.prepare(now: .now), now: .now)
            let wire = try JSONSerialization.jsonObject(with: vault.restore(receipt.vaultID, account: f.account, now: .now)) as! [String: Any]
            let capture = try #require(wire["sourceControl"] as? [String: Any])
            #expect(capture["nextBytes"] as? String == selectedBytes.base64EncodedString())
        }
        if removeKey {
            keys.values.removeAll()
            let before = try f.diskBytes()
            #expect(throws: (any Error).self) { try tx.recoverInterruptedTransition(now: .now) }
            #expect(try f.diskBytes() == before)
        } else {
            #expect(try tx.recoverInterruptedTransition(now: .now) != nil)
            #expect(try tx.authenticatedSelection(now: .now)?.phase == .cleanupComplete)
        }
    }

    @Test(arguments: ["valid", "tornMain", "mainlessNext"])
    func rollbackInitialVisibleMainRequiresAuthenticatedDurability(cut: String) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let journal = try f.makeMissingArchiveRollback()
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys())
        let fault = TransactionSyncFault()
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: vault, journal: journal, synchronize: fault.sync)
        let mainURL = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        let prepared = try tx.prepare(now: .now)
        fault.onSync = { _ in
            if FileManager.default.fileExists(atPath: mainURL.path) { throw TransactionFailure.injected }
        }
        #expect(throws: TransactionFailure.injected) { try tx.seal(prepared, now: .now) }
        fault.onSync = nil
        let bytes = try Data(contentsOf: mainURL)
        guard case .legacySelection(let intent) = try SyncAccountRecoveryControlFile.decode(bytes) else { Issue.record("Missing bridge"); return }
        _ = try vault.restore(intent.vaultID, account: f.account, now: .now)
        if cut == "tornMain" { try bytes.prefix(bytes.count / 2).write(to: mainURL) }
        if cut == "mainlessNext" { try FileManager.default.moveItem(at: mainURL, to: mainURL.deletingLastPathComponent().appendingPathComponent("intent-next.json")) }
        let before = try f.diskBytes()
        if cut == "valid" {
            fault.failAfter = 1
            #expect(throws: (any Error).self) { try tx.recoverInterruptedTransition(now: .now) }
            #expect(try f.diskBytes() == before)
            fault.failAfter = nil
            #expect(try tx.recoverInterruptedTransition(now: .now)?.vaultID == intent.vaultID)
        } else {
            #expect(throws: (any Error).self) { try tx.recoverInterruptedTransition(now: .now) }
            #expect(try f.diskBytes() == before)
        }
    }

    @Test(arguments: ["unknown", "missingNull", "sourceMismatch", "legacyDowngrade", "wrongInitialEdge"])
    func authenticatedV2EnvelopeRequiresImmutableSourceWitness(tamper: String) throws {
        let f = try SourceInventoryFixture(); defer { f.remove() }
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys())
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: f.journal)
        let receipt = try tx.seal(tx.prepare(now: .now), now: .now)
        let mainURL = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        guard case .selectedRecovery(let original, let predecessor) = try SyncAccountRecoveryControlFile.decode(Data(contentsOf: mainURL)) else { Issue.record("Missing v2"); return }
        var wire = try JSONSerialization.jsonObject(with: vault.restore(receipt.vaultID, account: f.account, now: .now)) as! [String: Any]
        var capture = try #require(wire["sourceControl"] as? [String: Any])
        if tamper == "unknown" { capture["extra"] = NSNull() }
        if tamper == "missingNull" { capture.removeValue(forKey: "nextBytes") }
        if tamper == "sourceMismatch" { capture["mainBytes"] = NSNull() }
        if tamper == "legacyDowngrade" { wire["formatVersion"] = 1; wire.removeValue(forKey: "sourceControl") }
        else { wire["sourceControl"] = capture }
        let payload = try JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys, .withoutEscapingSlashes])
        let id = try vault.seal(payload, account: f.account, now: .now)
        let intent = SyncAccountRecoveryIntent(formatVersion: 1, accountIDHash: original.accountIDHash,
            accountRoot: original.accountRoot, archiveURL: original.archiveURL, journalURL: original.journalURL,
            vaultID: id, captureID: original.captureID, envelopeSHA256: Data(SHA256.hash(data: payload)),
            packetSHA256: original.packetSHA256, inventoryFingerprint: original.inventoryFingerprint, phase: .sealed)
        let edge = tamper == "wrongInitialEdge" ? Data(repeating: 3, count: 32) : predecessor
        try SyncAccountRecoveryControlFile.encode(.selectedRecovery(intent, predecessorSHA256: edge), predecessorSHA256: edge).write(to: mainURL)
        let before = try f.diskBytes()
        #expect(throws: (any Error).self) { try tx.recoverInterruptedTransition(now: .now) }
        #expect(try f.diskBytes() == before)
    }

    @Test(arguments: [false, true], [false, true])
    func interruptedLegacyTransitionReopensForAuthenticatedRecovery(existingOnly: Bool, tornNext: Bool) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let journal = FileSyncMutationJournal(url: f.paths.mutationJournalURL)
        let mutation = SyncMutation.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID())
        try journal.enqueue(mutation)
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys())
        let fault = TransactionSyncFault()
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: vault, journal: journal, synchronize: fault.sync)
        let receipt = try tx.seal(tx.prepare(now: .now), now: .now)
        let controlRoot = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1")
        let mainURL = controlRoot.appendingPathComponent("intent.json")
        let nextURL = controlRoot.appendingPathComponent("intent-next.json")
        let main = try Data(contentsOf: mainURL)
        // Interrupt the actual v1 transition at its first next-file fsync, before rename.
        fault.onSync = { _ in
            if FileManager.default.fileExists(atPath: nextURL.path) { throw TransactionFailure.injected }
        }
        #expect(throws: TransactionFailure.injected) { try tx.cleanup(receipt) }
        fault.onSync = nil
        let completeNext = try Data(contentsOf: nextURL)
        let nextIntent = try JSONDecoder().decode(SyncAccountRecoveryIntent.self, from: completeNext)
        #expect(nextIntent.formatVersion == 1)
        #expect(nextIntent.phase == .cleanupStarted)
        #expect(try Data(contentsOf: mainURL) == main)
        // A crash during write can retain only this bounded prefix of those same bytes.
        if tornNext { try completeNext.prefix(completeNext.count / 2).write(to: nextURL) }
        let next = try Data(contentsOf: nextURL)
        try f.storage.close()
        let beforeOpen = try f.diskBytes()
        let reopened = try existingOnly
            ? f.storage.openExistingAccount(identity: f.account, validateAccount: {})
            : f.storage.openForVerifiedAccount(identity: f.account, validateAccount: {})
        #expect(try f.diskBytes() == beforeOpen)
        try f.storage.withRecoveryOwnership(paths: reopened, account: f.account, maximumBytes: 100_000_000) { access in
            let control = SyncAccountRecoveryControlFile(synchronize: { _ in })
            let observation = try control.observe(access: access)
            #expect(observation.mainBytes == main)
            #expect(observation.nextBytes == next)
            guard case .legacySelection(let intent)? = observation.state else {
                Issue.record("Legacy main must remain authoritative without fresh issuance"); return
            }
            #expect(intent.phase == .sealed)
            #expect(try SyncAccountRecoveryControlFile.encode(.legacySelection(intent), predecessorSHA256: nil) == main)
            // Routing a derivative cannot grant the new helper authority to discard/rebuild it.
            let predecessor = Data(SHA256.hash(data: main))
            #expect(throws: SyncAccountRecoveryTransaction.Error.invalidAuthority) {
                try control.replace(observation, with: .selectedRecovery(intent, predecessorSHA256: predecessor),
                    access: access, validateSource: {})
            }
            #expect(try Data(contentsOf: mainURL) == main)
            #expect(try Data(contentsOf: nextURL) == next)
        }
        let resumed = SyncAccountRecoveryTransaction(storage: f.storage, paths: reopened, account: f.account,
            vault: vault, journal: journal)
        #expect(try resumed.authenticatedSelection(now: .now)?.phase == .sealed)
        try resumed.cleanup(receipt)
        #expect(try resumed.authenticatedSelection(now: .now)?.phase == .cleanupComplete)
        #expect(!FileManager.default.fileExists(atPath: nextURL.path))
        try resumed.restore(vaultID: receipt.vaultID, now: .now)
        #expect(try resumed.authenticatedSelection(now: .now)?.phase == .replayComplete)
        #expect(try journal.pending() == [mutation])
    }

    @Test(arguments: [false, true], ["mainless", "wrongPredecessor", "corruptV2"])
    func newOpenNeverRoutesMainlessOrInvalidV2Derivative(existingOnly: Bool, invalid: String) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let journal = FileSyncMutationJournal(url: f.paths.mutationJournalURL)
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys()), journal: journal)
        _ = try tx.seal(tx.prepare(now: .now), now: .now)
        let controlRoot = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1")
        let mainURL = controlRoot.appendingPathComponent("intent.json")
        let nextURL = controlRoot.appendingPathComponent("intent-next.json")
        let main = try Data(contentsOf: mainURL)
        if invalid == "mainless" {
            try FileManager.default.moveItem(at: mainURL, to: nextURL)
        } else {
            let intent = try JSONDecoder().decode(SyncAccountRecoveryIntent.self, from: main)
            let predecessor = invalid == "wrongPredecessor" ? Data(repeating: 7, count: 32) : Data(SHA256.hash(data: main))
            var next = try SyncAccountRecoveryControlFile.encode(.selectedRecovery(intent, predecessorSHA256: predecessor), predecessorSHA256: predecessor)
            if invalid == "corruptV2" {
                var object = try JSONSerialization.jsonObject(with: next) as! [String: Any]
                object["checksum"] = Data(repeating: 7, count: 32).base64EncodedString()
                next = try JSONSerialization.data(withJSONObject: object)
            }
            try next.write(to: nextURL)
        }
        try f.storage.close()
        let before = try f.diskBytes()
        #expect(throws: (any Error).self) {
            if existingOnly { _ = try f.storage.openExistingAccount(identity: f.account, validateAccount: {}) }
            else { _ = try f.storage.openForVerifiedAccount(identity: f.account, validateAccount: {}) }
        }
        #expect(try f.diskBytes() == before)
    }

    @Test(arguments: [false, true])
    func canonicalCleanupRequiresUnchangedAuthenticatedSelection(changeAfterSeal: Bool) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let canonical = try f.installCanonicalCheckpoint()
        let url = f.paths.workingSet.appendingPathComponent("SyncMetadata/canonical.json")
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys())
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: f.journal)
        let receipt = try tx.seal(tx.prepare(now: .now), now: .now)
        #expect(try Data(contentsOf: url) == canonical.encoded())
        let ciphertext = try f.diskBytes().filter { $0.key.hasPrefix(f.paths.vault.path + "/") }
        #expect(!ciphertext.isEmpty)
        if changeAfterSeal {
            try f.write("working-set/SyncMetadata/.canonical-next.json", Data("partial".utf8))
            let before = try f.diskBytes()
            #expect(throws: (any Error).self) { try tx.cleanup(receipt) }
            #expect(try f.diskBytes() == before)
        } else {
            try tx.cleanup(receipt)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(try tx.authenticatedSelection(now: .now)?.phase == .cleanupComplete)
        }
        #expect(try f.diskBytes().filter { $0.key.hasPrefix(f.paths.vault.path + "/") } == ciphertext)
    }

    @Test(arguments: [false, true]) @MainActor func partialPendingReplayCannotActivateWithoutFullCanonicalAuthority(complete: Bool) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let canonical = try f.installCanonicalCheckpoint()
        let mutations = try canonical.records.map { try SyncMutation.save(recordVersion: .init(record: $0), mutationID: UUID()) }
        try f.journal.enqueue(mutations)
        try f.journal.acknowledge(Set(mutations.dropFirst().map(\.identity)))
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys())
        let failing = FileSyncMutationJournal(url: f.journalURL, appendFrames: { bytes, url in
            try Data(bytes.dropLast(5)).write(to: url)
            throw TransactionFailure.injected
        })
        var transaction: SyncAccountRecoveryTransaction? = .init(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: failing)
        let receipt = try transaction!.seal(transaction!.prepare(now: .now), now: .now)
        try transaction!.cleanup(receipt)
        #expect(throws: (any Error).self) { try transaction!.restore(vaultID: receipt.vaultID, now: .now) }
        transaction = nil
        let ciphertext = try f.diskBytes().filter { $0.key.hasPrefix(f.paths.vault.path + "/") }
        // A torn replay and a completed pending-only replay are both insufficient.
        do {
            let journal = FileSyncMutationJournal(url: f.journalURL)
            if complete {
                let fresh = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: journal)
                try fresh.restore(vaultID: receipt.vaultID, now: .now)
                #expect(try journal.pending() == [mutations[0]])
                #expect(try fresh.authenticatedSelection(now: .now)?.phase == .replayComplete)
            }
            let checkpoints = try SyncCanonicalCheckpointStore(liveRoot: f.paths.workingSet, account: f.account, validateOwnership: {})
            let store = JSONProjectStore(url: f.archiveURL, syncMutationSink: JournalSyncMutationSink(journal: journal))
            #expect(throws: (any Error).self) {
                try store.activateSyncCanonicalState(checkpointStore: checkpoints, bootstrap: nil, attachmentSources: [:])
            }
            #expect(try checkpoints.load() == nil)
            #expect(try f.diskBytes().filter { $0.key.hasPrefix(f.paths.vault.path + "/") } == ciphertext)
        }
    }

    @Test @MainActor func accountBRefusesAccountACanonicalCheckpointWithoutChangingIt() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let checkpoint = try f.installCanonicalCheckpoint()
        let accountB = try SyncAccountIdentity(containerIdentifier: "test", userRecordName: "B")
        let ownerB = SyncAccountStorage(baseURL: f.base.appendingPathComponent("B"))
        let pathsB = try ownerB.open(identity: accountB)
        defer { try? ownerB.close() }
        let checkpoints = try SyncCanonicalCheckpointStore(liveRoot: pathsB.workingSet, account: accountB, validateOwnership: {})
        let url = pathsB.workingSet.appendingPathComponent("SyncMetadata/canonical.json")
        try checkpoint.encoded().write(to: url)
        let bytes = try Data(contentsOf: url)
        let store = JSONProjectStore(url: pathsB.workingSet.appendingPathComponent("projects-v1.json"),
            syncMutationSink: JournalSyncMutationSink(journal: FileSyncMutationJournal(url: pathsB.journal.appendingPathComponent("pending.json"))))
        #expect(throws: (any Error).self) {
            try store.activateSyncCanonicalState(checkpointStore: checkpoints, bootstrap: nil, attachmentSources: [:])
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func runtimeAbsenceBarrierRefusesSelectedIntentAndSyncFailure() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys())
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: f.journal)
        try tx.synchronizeSelectionAbsence(now: .now)
        let faulted = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: f.journal, synchronize: { _ in throw TransactionFailure.injected })
        #expect(throws: (any Error).self) { try faulted.synchronizeSelectionAbsence(now: .now) }
        let sealed = try tx.seal(tx.prepare(now: .now), now: .now)
        #expect(try tx.lifecycleSnapshot(now: .now)?.receipt == sealed)
        #expect(throws: (any Error).self) { try tx.synchronizeSelectionAbsence(now: .now) }
        #expect(try tx.lifecycleSnapshot(now: .now)?.phase == .sealed)
    }
    @Test func legacyStandaloneReminderCannotAuthorizeCleanupOrNativeReplay() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        var project = try StoredProject(name: "legacy")
        try project.addKnittingReminder(counterID: project.mainCounterID,
            draft: .oneTime(kind: .measure, target: 2, text: nil), now: .init(timeIntervalSinceReferenceDate: 100))
        let reminder = project.knittingReminders[0]
        let stamp = SyncMutationStamp(logicalRevision: 0, modifiedAt: reminder.createdAt, deviceID: "legacy")
        let record = SyncRecord(schemaVersion: 1, id: .init(kind: .knittingReminder, uuid: reminder.id), createdAt: reminder.createdAt,
            entityRevision: reminder.mutationRevision, payload: .init(fields: [:], atomicDomain: .init(value: .knittingReminder(reminder), stamp: stamp)),
            relationships: [.init(role: "counter", target: .init(kind: .projectCounter, uuid: reminder.counterID)),
                .init(role: "project", target: .init(kind: .project, uuid: project.id))], deletedAt: .init(value: nil, stamp: stamp))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.userInfo[.encodeLegacyStandaloneReminderForMigration] = true
        let recordData = try encoder.encode(record)
        var idBytes = Array(SHA256.hash(data: recordData).prefix(16))
        idBytes[6] = (idBytes[6] & 0x0f) | 0x50; idBytes[8] = (idBytes[8] & 0x3f) | 0x80
        let versionID = idBytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
        let object: [String: Any] = ["save": ["_0": ["recordVersion": ["versionID": versionID.uuidString,
            "record": try JSONSerialization.jsonObject(with: recordData)], "mutationID": UUID().uuidString]]]
        let mutation = try JSONDecoder().decode(SyncMutation.self, from: JSONSerialization.data(withJSONObject: object))
        _ = try mutation.validatedForJournalLoad()
        let checkpoint = try encoder.encode(SyncJournalCheckpoint(throughSequence: 1, pending: [mutation]))
        try JSONSerialization.data(withJSONObject: ["version": 1, "checkpoint": checkpoint.base64EncodedString(),
            "checksum": Data(SHA256.hash(data: checkpoint)).base64EncodedString()]).write(to: f.journalURL.appendingPathExtension("checkpoint"))
        #expect(try f.journal.recoverySnapshot().mutations == [mutation])
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys()), journal: f.journal)
        let before = try f.diskBytes()
        #expect(throws: (any Error).self) { try f.capture() }
        #expect(throws: (any Error).self) { try tx.prepare(now: .now) }
        #expect(throws: (any Error).self) { try f.journal.preflightRecoveryReplay([mutation], maximumBytes: 100_000_000) }
        #expect(try f.diskBytes() == before)
    }

    @Test func emptyReplayCannotAuthorizeAnUnproducedSegment() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        try Data().write(to: f.journalURL.appendingPathExtension("segment"))
        #expect(throws: (any Error).self) { try f.journal.validateRecoveryReplay([], maximumBytes: 100_000_000) }
    }

    @Test(arguments: ["start", "file", "dependencies", "complete"])
    func interruptedRestoreRevalidatesExactEffectsBeforeRetry(cut: String) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        let selected = try f.addDeletion(ledger: ledger, name: "selected", attachment: true)
        try f.journal.enqueue(SyncMutation.save(recordVersion: selected.versions[0], mutationID: UUID()))
        let expected = try f.journal.pending()
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys()), fault = TransactionSyncFault()
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: f.journal, synchronize: fault.sync)
        let receipt = try tx.seal(tx.prepare(now: .now), now: .now); try tx.cleanup(receipt)
        let intent = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        let retainedFile = try #require(try tx.authenticatedSelection(now: .now)?.inventory.deletionFiles.first)
        let retained = f.paths.accountRoot.appendingPathComponent(retainedFile.relativePath)
        fault.onSync = { _ in
            let phase = try JSONSerialization.jsonObject(with: Data(contentsOf: intent)) as! [String: Any]
            let fail = cut == "start" ? phase["phase"] as? String == "restoreStarted"
                : cut == "file" ? FileManager.default.fileExists(atPath: retained.path)
                : cut == "dependencies" ? FileManager.default.fileExists(atPath: f.ledgerRoot.appendingPathComponent("ledger.json").path)
                : phase["phase"] as? String == "replayComplete"
            if fail { throw TransactionFailure.injected }
        }
        #expect(throws: (any Error).self) { try tx.restore(vaultID: receipt.vaultID, now: .now) }
        if cut == "start" {
            #expect(!FileManager.default.fileExists(atPath: retained.path))
            #expect(!FileManager.default.fileExists(atPath: f.journalURL.appendingPathExtension("segment").path))
        }
        #expect(try vault.restore(receipt.vaultID, account: f.account, now: .now).count > 0)
        fault.onSync = nil
        let fresh = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: FileSyncMutationJournal(url: f.journalURL))
        try fresh.restore(vaultID: receipt.vaultID, now: .now)
        #expect(try f.journal.pending() == expected)
        #expect(try Data(contentsOf: retained) == Data("retained photograph".utf8))
        #expect(try fresh.authenticatedSelection(now: .now)?.phase == .replayComplete)
    }

    @Test(arguments: ["changed", "extra", "newPending", "unknownProof", "symlink", "hardlink"], [false, true])
    func restoreStartedAndCompleteRefuseLaterEffects(change: String, complete: Bool) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        let selected = try f.addDeletion(ledger: ledger, name: "selected", attachment: true)
        try f.journal.enqueue(SyncMutation.save(recordVersion: selected.versions[0], mutationID: UUID()))
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys()), fault = TransactionSyncFault()
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: f.journal, synchronize: fault.sync)
        let receipt = try tx.seal(tx.prepare(now: .now), now: .now); try tx.cleanup(receipt)
        let selectedFile = try #require(try tx.authenticatedSelection(now: .now)?.inventory.deletionFiles.first)
        let selectedURL = f.paths.accountRoot.appendingPathComponent(selectedFile.relativePath)
        if complete { try tx.restore(vaultID: receipt.vaultID, now: .now) }
        else {
            fault.onSync = { _ in if FileManager.default.fileExists(atPath: selectedURL.path) { throw TransactionFailure.injected } }
            #expect(throws: (any Error).self) { try tx.restore(vaultID: receipt.vaultID, now: .now) }
            fault.onSync = nil
        }
        if change == "changed" { try f.write(selectedFile.relativePath, Data("changed photograph!".utf8)) }
        if change == "extra" { try f.write("working-set/later", Data([1])) }
        if change == "newPending" { try f.journal.enqueue(SyncMutation.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID())) }
        if change == "unknownProof" { try f.write("journal/pending.json.proofs.00000000", Data([1])) }
        if change == "symlink" || change == "hardlink" {
            let outside = f.base.appendingPathComponent("same-bytes")
            try Data("retained photograph".utf8).write(to: outside)
            try FileManager.default.removeItem(at: selectedURL)
            if change == "symlink" { try FileManager.default.createSymbolicLink(at: selectedURL, withDestinationURL: outside) }
            else { try FileManager.default.linkItem(at: outside, to: selectedURL) }
        }
        let before = try f.diskBytes()
        #expect(throws: (any Error).self) { try tx.restore(vaultID: receipt.vaultID, now: .now) }
        #expect(throws: (any Error).self) { try tx.consumeRestoredSelection(vaultID: receipt.vaultID, now: .now) }
        #expect(try f.diskBytes() == before)
    }

    @Test(arguments: [false, true])
    func actualJournalAppendInterruptionAndFreshStorageReopen(torn: Bool) throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("restore-reopen-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let account = try SyncAccountIdentity(containerIdentifier: "test", userRecordName: "A"), keys = TransactionKeys()
        var owner: SyncAccountStorage? = SyncAccountStorage(baseURL: base)
        let paths = try owner!.open(identity: account), journalURL = paths.journal.appendingPathComponent("pending.json")
        try Data("archive".utf8).write(to: paths.workingSet.appendingPathComponent("projects-v1.json"))
        let expected = (0..<3).map { _ in SyncMutation.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID()) }
        try FileSyncMutationJournal(url: journalURL).enqueue(expected)
        let vault = SyncRecoveryVault(directory: paths.vault, keychain: keys)
        let failing = FileSyncMutationJournal(url: journalURL, appendFrames: { bytes, url in
            try (torn ? Data(bytes.dropLast(5)) : bytes).write(to: url)
            throw TransactionFailure.injected
        })
        var tx: SyncAccountRecoveryTransaction? = SyncAccountRecoveryTransaction(storage: owner!, paths: paths, account: account, vault: vault, journal: failing)
        let receipt = try tx!.seal(tx!.prepare(now: .now), now: .now); try tx!.cleanup(receipt)
        #expect(throws: (any Error).self) { try tx!.restore(vaultID: receipt.vaultID, now: .now) }
        tx = nil; owner = nil
        let reopened = SyncAccountStorage(baseURL: base), current = try reopened.open(identity: account)
        defer { try? reopened.close() }
        let journal = FileSyncMutationJournal(url: journalURL)
        let fresh = SyncAccountRecoveryTransaction(storage: reopened, paths: current, account: account, vault: vault, journal: journal)
        try fresh.restore(vaultID: receipt.vaultID, now: .now)
        #expect(try journal.pending() == expected)
        #expect(try fresh.consumeRestoredSelection(vaultID: receipt.vaultID, now: .now))
    }

    @Test func consumedIntentAbsenceMustBeSynchronizedBeforeLaterCapture() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let fault = TransactionSyncFault(), vault = SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys())
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: f.journal, synchronize: fault.sync)
        let receipt = try tx.seal(tx.prepare(now: .now), now: .now); try tx.cleanup(receipt)
        try tx.restore(vaultID: receipt.vaultID, now: .now)
        let intent = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        fault.onSync = { _ in if !FileManager.default.fileExists(atPath: intent.path) { throw TransactionFailure.injected } }
        #expect(throws: (any Error).self) { try tx.consumeRestoredSelection(vaultID: receipt.vaultID, now: .now) }
        #expect(!FileManager.default.fileExists(atPath: intent.path))
        try f.storage.close()
        let reopened = SyncAccountStorage(baseURL: f.base), current = try reopened.open(identity: f.account)
        defer { try? reopened.close() }
        let fresh = SyncAccountRecoveryTransaction(storage: reopened, paths: current, account: f.account, vault: vault,
            journal: FileSyncMutationJournal(url: f.journalURL), synchronize: fault.sync)
        #expect(throws: (any Error).self) { try fresh.consumeRestoredSelection(vaultID: receipt.vaultID, now: .now) }
        try Data("later archive".utf8).write(to: f.archiveURL)
        #expect(throws: (any Error).self) { try fresh.prepare(now: .now) }
        fault.onSync = nil
        #expect(!(try fresh.consumeRestoredSelection(vaultID: receipt.vaultID, now: .now)))
        let later = try fresh.seal(fresh.prepare(now: .now), now: .now)
        #expect(throws: (any Error).self) { try fresh.restore(vaultID: receipt.vaultID, now: .now) }
        #expect(try fresh.authenticatedSelection(now: .now)?.receipt == later)
    }

    @Test func restorePreservesPendingAndSelectedDependenciesThenConsumesSelection() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        let selected = try f.addDeletion(ledger: ledger, name: "selected", attachment: true)
        let expired = try f.addDeletion(ledger: ledger, name: "expired")
        try ledger.purge(now: Date(timeIntervalSince1970: 2_592_100), references: .init(acknowledgedRemovalVersionIDs: Set(expired.versions.map(\.versionID))))
        let markers = try ledger.pendingDeletionMarkerVersions()
        try f.journal.enqueue(SyncMutation.save(recordVersion: selected.versions[0], mutationID: UUID()))
        let attachment = try #require(try ledger.recentlyDeleted().first?.domain.ownedRecords.first { $0.id.kind == .attachment })
        let proof = try #require(try ledger.recentlyDeleted().first?.files.first)
        try f.journal.enqueue(SyncMutation.save(recordVersion: SyncRecordVersion(record: attachment), attachmentSource: .init(fileURL: f.ledgerRoot.appendingPathComponent(proof.retainedRelativePath), contentSHA256: proof.sha256, byteCount: proof.byteCount), mutationID: UUID()))
        try f.journal.enqueue(SyncMutation.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID()))
        let pending = try f.journal.pending()
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys())
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: f.journal)
        let receipt = try tx.seal(tx.prepare(now: .now), now: .now)
        try tx.cleanup(receipt)
        try tx.restore(vaultID: receipt.vaultID, now: .now)
        #expect(try f.journal.pending() == pending)
        #expect(try Data(contentsOf: pending.compactMap(\.attachmentSource)[0].fileURL) == Data("retained photograph".utf8))
        #expect(try tx.authenticatedSelection(now: .now)?.phase == .replayComplete)
        try tx.restore(vaultID: receipt.vaultID, now: .now)
        #expect(try f.journal.pending() == pending)
        // Inspect through the read-only exporter so a new normal ledger lock is
        // not itself a later-data effect during exact replay verification.
        let restored = try SyncDeletionLedger.recoveryExport(archiveURL: f.archiveURL, pending: pending, maximumBytes: 100_000_000)
        #expect(restored.pendingMarkerVersions == markers)
        #expect(restored.files.count == 1)
        #expect(try tx.consumeRestoredSelection(vaultID: receipt.vaultID, now: .now))
        #expect(try tx.authenticatedSelection(now: .now) == nil)
        #expect(throws: (any Error).self) { try tx.restore(vaultID: receipt.vaultID, now: .now) }
        try Data("later archive".utf8).write(to: f.archiveURL)
        let later = try tx.seal(tx.prepare(now: .now), now: .now)
        #expect(throws: (any Error).self) { try tx.consumeRestoredSelection(vaultID: receipt.vaultID, now: .now) }
        #expect(try tx.authenticatedSelection(now: .now)?.receipt == later)
    }

    @Test(arguments: ["newFile", "newPending", "unknownJournal", "checkpoint", "wrongVault", "account"])
    func restoreRefusesAdditionalDestinationAuthority(kind: String) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys())
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: f.journal)
        try f.journal.enqueue(SyncMutation.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID()))
        let receipt = try tx.seal(tx.prepare(now: .now), now: .now); try tx.cleanup(receipt)
        if kind == "newFile" { try f.write("working-set/new", Data([1])) }
        if kind == "newPending" { try f.journal.enqueue(SyncMutation.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID())) }
        if kind == "unknownJournal" { try f.write("journal/pending.json.arbitrary", Data([1])) }
        if kind == "checkpoint" { try f.write("journal/pending.json.checkpoint", Data([1])) }
        let before = try f.diskBytes()
        if kind == "account" {
            let other = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: try SyncAccountIdentity(containerIdentifier: "test", userRecordName: "B"), vault: vault, journal: f.journal)
            #expect(throws: (any Error).self) { try other.restore(vaultID: receipt.vaultID, now: .now) }
        } else {
            #expect(throws: (any Error).self) { try tx.restore(vaultID: kind == "wrongVault" ? UUID() : receipt.vaultID, now: .now) }
        }
        #expect(try f.diskBytes() == before)
    }

    @Test func concreteReplayRecognizesOnlyExactNativeSegmentPrefix() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let expected = [SyncMutation.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID()), SyncMutation.delete(.init(kind: .yarn, uuid: UUID()), mutationID: UUID())]
        #expect(throws: (any Error).self) { try f.journal.preflightRecoveryReplay(expected, maximumBytes: 1) }
        #expect(!FileManager.default.fileExists(atPath: f.journalURL.appendingPathExtension("segment").path))
        try f.journal.enqueue(expected)
        let segment = f.journalURL.appendingPathExtension("segment"), bytes = try Data(contentsOf: segment)
        #expect(try f.journal.validateRecoveryReplay(expected, maximumBytes: 100_000_000).complete)
        try bytes.dropLast(5).write(to: segment)
        #expect(!(try f.journal.validateRecoveryReplay(expected, maximumBytes: 100_000_000).complete))
        try f.journal.enqueue(expected)
        #expect(try f.journal.pending() == expected)
        var altered = bytes; altered[altered.count - 1] ^= 1
        try altered.write(to: segment)
        #expect(throws: (any Error).self) { try f.journal.validateRecoveryReplay(expected, maximumBytes: 100_000_000) }
    }
    @Test func ciphertextRetryDurabilityBindsSyncedInode() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let fault = TransactionSyncFault(), keys = TransactionKeys()
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: keys, maximumPayloadBytes: 100_000_000, synchronize: fault.sync)
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: f.journal)
        let receipt = try tx.seal(tx.prepare(now: .now), now: .now)
        let cipher = f.paths.vault.appendingPathComponent(receipt.vaultID.uuidString.lowercased() + ".vault")
        fault.onSync = { _ in
            fault.onSync = nil
            try Data(contentsOf: cipher).write(to: cipher, options: .atomic)
        }
        #expect(throws: (any Error).self) { try tx.cleanup(receipt) }
        #expect(FileManager.default.fileExists(atPath: f.archiveURL.path))
    }

    @Test(arguments: ["format", "account", "root", "archive", "journal", "path", "duplicate", "selectedBytes", "ledger"])
    func authenticatedButInvalidEnvelopeNeverBecomesCleanupAuthority(tamper: String) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        let deleted = try f.addDeletion(ledger: ledger, name: "protected", attachment: true)
        try f.journal.enqueue(SyncMutation.save(recordVersion: deleted.versions[0], mutationID: UUID()))
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys())
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: f.journal)
        let sealed = try tx.seal(tx.prepare(now: .now), now: .now)
        var envelope = try JSONSerialization.jsonObject(with: vault.restore(sealed.vaultID, account: f.account, now: .now)) as! [String: Any]
        var inventory = try JSONSerialization.jsonObject(with: Data(base64Encoded: envelope["inventory"] as! String)!) as! [String: Any]
        switch tamper {
        case "format": envelope["formatVersion"] = 2
        case "account": inventory["accountIDHash"] = String(repeating: "b", count: 64)
        case "root": inventory["accountRoot"] = f.base.absoluteString
        case "archive": inventory["archiveURL"] = f.paths.workingSet.appendingPathComponent("other.json").absoluteString
        case "journal": inventory["journalURL"] = f.paths.journal.appendingPathComponent("other.json").absoluteString
        case "path", "duplicate":
            var entries = inventory["entries"] as! [[String: Any]]
            if tamper == "path" { entries[0]["relativePath"] = "../outside" }
            else { entries.append(entries[0]) }
            inventory["entries"] = entries
            inventory["fingerprint"] = Data(SHA256.hash(data: try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys, .withoutEscapingSlashes]))).base64EncodedString()
        case "selectedBytes":
            var files = inventory["deletionFiles"] as! [[String: Any]]
            files[0]["bytes"] = Data("forged".utf8).base64EncodedString(); inventory["deletionFiles"] = files
        default: inventory["deletionLedger"] = Data("malformed selected ledger".utf8).base64EncodedString()
        }
        envelope["inventory"] = try JSONSerialization.data(withJSONObject: inventory).base64EncodedString()
        let bytes = try JSONSerialization.data(withJSONObject: envelope)
        let fakeID = try vault.seal(bytes, account: f.account, now: .now)
        let intentURL = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        var intent = try JSONSerialization.jsonObject(with: Data(contentsOf: intentURL)) as! [String: Any]
        intent["vaultID"] = fakeID.uuidString
        intent["envelopeSHA256"] = Data(SHA256.hash(data: bytes)).base64EncodedString()
        intent["inventoryFingerprint"] = inventory["fingerprint"]
        try JSONSerialization.data(withJSONObject: intent).write(to: intentURL)
        let original = try f.diskBytes()
        #expect(throws: (any Error).self) { try tx.recoverInterruptedTransition(now: .now) }
        #expect(try f.diskBytes() == original)
    }

    @Test(arguments: ["sealedWrite", "terminalRename"])
    func readableFailedIntentIsResynchronizedOnEveryFreshRetry(cut: String) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let fault = TransactionSyncFault(), vault = SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys())
        func transaction() -> SyncAccountRecoveryTransaction {
            .init(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: f.journal, synchronize: fault.sync)
        }
        let tx = transaction(), prepared = try tx.prepare(now: .now)
        if cut == "sealedWrite" {
            fault.failAfter = 1
            #expect(throws: (any Error).self) { try tx.seal(prepared, now: .now) }
        } else {
            let receipt = try tx.seal(prepared, now: .now)
            let intentURL = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
            fault.onSync = { _ in
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: intentURL)) as! [String: Any]
                if object["phase"] as? String == "cleanupComplete" { throw TransactionFailure.injected }
            }
            #expect(throws: (any Error).self) { try tx.cleanup(receipt) }
            #expect(!FileManager.default.fileExists(atPath: f.archiveURL.path))
        }
        #expect(throws: (any Error).self) { try transaction().recoverInterruptedTransition(now: .now) }
        if cut == "sealedWrite" { #expect(FileManager.default.fileExists(atPath: f.archiveURL.path)) }
        fault.failAfter = nil; fault.onSync = nil
        #expect(try transaction().recoverInterruptedTransition(now: .now) != nil)
        #expect(try transaction().authenticatedSelection(now: .now)?.phase == .cleanupComplete)
    }

    @Test func expiryMissingKeyAndAggregateLimitsPreserveOriginals() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let keys = TransactionKeys(), vault = SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys())
        let small = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: f.journal, maximumBytes: 1)
        #expect(throws: (any Error).self) { try small.prepare(now: .now) }
        let usedVault = SyncRecoveryVault(directory: f.paths.vault, keychain: keys)
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: usedVault, journal: f.journal)
        let now = Date.now, prepared = try tx.prepare(now: .now)
        let receipt = try tx.seal(prepared, now: now)
        #expect(throws: (any Error).self) { try tx.recoverInterruptedTransition(now: now.addingTimeInterval(2_592_000)) }
        keys.values = [:]
        #expect(throws: (any Error).self) { try tx.cleanup(receipt) }
        #expect(FileManager.default.fileExists(atPath: f.archiveURL.path))
    }

    @Test func missingFileBeforeCleanupStartedRefusesRemainingPlaintextDeletion() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys()), journal: f.journal)
        try f.write("staging/original", Data([1]))
        let sealed = try tx.seal(tx.prepare(now: .now), now: .now)
        try FileManager.default.removeItem(at: f.paths.staging.appendingPathComponent("original"))
        #expect(throws: (any Error).self) { try tx.cleanup(sealed) }
        #expect(FileManager.default.fileExists(atPath: f.archiveURL.path))
    }

    @Test func barrierRejectsIdenticalIntentReplacementBeforeFirstUnlink() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let fault = TransactionSyncFault()
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys()), journal: f.journal, synchronize: fault.sync)
        let sealed = try tx.seal(tx.prepare(now: .now), now: .now)
        let intent = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        fault.onSync = { _ in
            fault.onSync = nil
            try Data(contentsOf: intent).write(to: intent, options: .atomic)
        }
        #expect(throws: (any Error).self) { try tx.cleanup(sealed) }
        #expect(FileManager.default.fileExists(atPath: f.archiveURL.path))
    }

    @Test(arguments: [false, true], ["sealed", "unlink", "complete"])
    func freshStorageReopenAcceptsOnlyEmptyOwnedNewSession(extraPlaintext: Bool, cut: String) throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("transaction-reopen-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let account = try SyncAccountIdentity(containerIdentifier: "test", userRecordName: "A"), keys = TransactionKeys()
        var owner: SyncAccountStorage? = SyncAccountStorage(baseURL: base)
        let paths = try owner!.open(identity: account)
        try Data("original".utf8).write(to: paths.workingSet.appendingPathComponent("projects-v1.json"))
        try Data("copy".utf8).write(to: paths.decryptedTemporary.appendingPathComponent("copy"))
        let journal = FileSyncMutationJournal(url: paths.journal.appendingPathComponent("pending.json"))
        let mutation = SyncMutation.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID())
        try journal.enqueue(mutation)
        let vault = SyncRecoveryVault(directory: paths.vault, keychain: keys)
        let fault = TransactionSyncFault(), source = paths.staging.appendingPathComponent("original")
        try Data("pending".utf8).write(to: source)
        var tx: SyncAccountRecoveryTransaction? = SyncAccountRecoveryTransaction(storage: owner!, paths: paths, account: account,
            vault: vault, journal: journal, synchronize: fault.sync)
        let sealed = try tx!.seal(tx!.prepare(now: .now), now: .now)
        if cut == "complete" { try tx!.cleanup(sealed) }
        if cut == "unlink" {
            fault.onSync = { _ in
                if !FileManager.default.fileExists(atPath: source.path) { throw TransactionFailure.injected }
            }
            #expect(throws: (any Error).self) { try tx!.cleanup(sealed) }
            #expect(!FileManager.default.fileExists(atPath: source.path))
        }
        let archiveRemains = FileManager.default.fileExists(atPath: paths.workingSet.appendingPathComponent("projects-v1.json").path)
        tx = nil; owner = nil // Crash: release ownership without close/cleanup.
        let reopened = SyncAccountStorage(baseURL: base)
        let current = try reopened.open(identity: account)
        defer { try? reopened.close() }
        #expect(current.decryptedTemporary != paths.decryptedTemporary)
        let fresh = SyncAccountRecoveryTransaction(storage: reopened, paths: current, account: account, vault: vault, journal: journal)
        if extraPlaintext {
            try Data("new account content".utf8).write(to: current.decryptedTemporary.appendingPathComponent("new"))
            #expect(throws: (any Error).self) { try fresh.recoverInterruptedTransition(now: .now) }
            #expect(FileManager.default.fileExists(atPath: current.workingSet.appendingPathComponent("projects-v1.json").path) == archiveRemains)
        } else {
            #expect(try fresh.recoverInterruptedTransition(now: .now)?.vaultID == sealed.vaultID)
            #expect(try fresh.authenticatedSelection(now: .now)?.inventory.packet.mutations == [mutation])
            #expect(try FileManager.default.contentsOfDirectory(atPath: current.decryptedTemporary.path).isEmpty)
        }
    }

    @Test(arguments: ["unknown", "replace", "symlink"])
    func refusesUnownedControlNamespaceAndPreservesPlaintext(kind: String) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let fault = TransactionSyncFault()
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys()), journal: f.journal, synchronize: fault.sync)
        let receipt = try tx.seal(tx.prepare(now: .now), now: .now)
        let control = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1")
        if kind == "unknown" { try Data([1]).write(to: control.appendingPathComponent("unknown")) }
        else if kind == "symlink" {
            let outside = f.base.appendingPathComponent("control-outside")
            try FileManager.default.moveItem(at: control, to: outside)
            try FileManager.default.createSymbolicLink(at: control, withDestinationURL: outside)
        } else {
            fault.onSync = { _ in
                fault.onSync = nil
                let outside = f.base.appendingPathComponent("control-moved")
                try FileManager.default.moveItem(at: control, to: outside)
                try FileManager.default.copyItem(at: outside, to: control)
            }
        }
        #expect(throws: (any Error).self) { try tx.cleanup(receipt) }
        #expect(FileManager.default.fileExists(atPath: f.archiveURL.path))
    }

    @Test func everyRetryResynchronizesReadableIntentAndSurvivesActualUnlinkCut() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let fault = TransactionSyncFault(), keys = TransactionKeys()
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: keys)
        func transaction() -> SyncAccountRecoveryTransaction {
            .init(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: f.journal, synchronize: fault.sync)
        }
        let tx = transaction(), source = f.paths.staging.appendingPathComponent("original")
        try Data("pending".utf8).write(to: source)
        let sealed = try tx.seal(tx.prepare(now: .now), now: .now)
        fault.failAfter = 1
        #expect(throws: (any Error).self) { try tx.cleanup(sealed) }
        #expect(throws: (any Error).self) { try transaction().recoverInterruptedTransition(now: .now) }
        #expect(FileManager.default.fileExists(atPath: f.archiveURL.path))
        fault.failAfter = nil
        fault.onSync = { _ in
            if !FileManager.default.fileExists(atPath: source.path) { throw TransactionFailure.injected }
        }
        #expect(throws: (any Error).self) { try transaction().recoverInterruptedTransition(now: .now) }
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try vault.restore(sealed.vaultID, account: f.account, now: .now).count > 0)
        fault.onSync = nil
        #expect(try transaction().recoverInterruptedTransition(now: .now)?.vaultID == sealed.vaultID)
        #expect(try transaction().authenticatedSelection(now: .now)?.phase == .cleanupComplete)
    }

    @Test(arguments: ["v1", "v2-committed"])
    func terminalBootstrapAndExactPendingAttachmentAreRecoveredWithoutWholeArchive(_ source: String) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [try StoredProject(name: "bootstrap project")])
        try JSONEncoder().encode(archive).write(to: f.archiveURL)
        let context = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let bootstrap = try SyncBootstrapTransaction(liveRoot: f.paths.workingSet, context: context,
            journalRelativePath: "SyncMetadata/bootstrap-journal", validateContext: { _ in })
        let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: f.paths.workingSet, deviceID: "fixture")
        let prepared: SyncBootstrapPreparation
        if source == "v1" {
            prepared = try bootstrap.prepare(local: package, sourceArchive: archive,
                remote: .init(context: context, records: [], attachments: [:], isComplete: true))
        } else {
            try FileManager.default.removeItem(at: f.archiveURL)
            prepared = try bootstrap.prepareReconstruction(remote: .init(context: context, records: package.records,
                attachments: package.attachments, isComplete: true),
                pendingSnapshot: .init(mutations: [], sourceTreeFingerprint: bootstrap.sourceFingerprint()))
        }
        try bootstrap.install(prepared)
        _ = try bootstrap.commit(prepared)
        let journal = FileSyncMutationJournal(url: f.paths.workingSet.appendingPathComponent("SyncMetadata/bootstrap-journal"))
        let source = f.paths.staging.appendingPathComponent("photo")
        let bytes = Data("exact pending photograph".utf8)
        try bytes.write(to: source)
        let attachment = try SyncAttachmentVersion.issuing(slot: .init(owner: .init(kind: .project, uuid: UUID()), role: "project-photo", slotID: "cover"),
            contentSHA256: Data(SHA256.hash(data: bytes)), byteCount: Int64(bytes.count), mediaType: "image/jpeg", displayFilename: "cover.jpg")
        let stamp = SyncMutationStamp(logicalRevision: 1, modifiedAt: .now, deviceID: "fixture")
        let record = SyncRecord(schemaVersion: 1, id: .init(kind: .attachment, uuid: attachment.versionID), createdAt: stamp.modifiedAt,
            entityRevision: 1, payload: .init(fields: [:], attachment: attachment), relationships: [.init(role: "owner", target: attachment.slot.owner)], deletedAt: .init(value: nil, stamp: stamp))
        try journal.enqueue(SyncMutation.save(recordVersion: SyncRecordVersion(record: record),
            attachmentSource: .init(fileURL: source, contentSHA256: attachment.contentSHA256, byteCount: attachment.byteCount), mutationID: UUID()))
        let pending = try journal.pending()
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys())
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: journal)
        let sealed = try tx.seal(tx.prepare(now: .now), now: .now)
        try tx.cleanup(sealed)
        let selection = try #require(try tx.authenticatedSelection(now: .now))
        #expect(selection.inventory.packet.mutations == pending)
        #expect(selection.inventory.packet.files.map(\.bytes) == [bytes])
        #expect(!selection.inventory.packet.files.contains(where: { $0.relativePath.hasSuffix("projects-v1.json") }))
        #expect(!FileManager.default.fileExists(atPath: f.paths.accountRoot.appendingPathComponent(".KnitNote-SyncBootstrap").path))
    }

    @Test func legacyRollbackFirstSelectionUsesAuthenticatedBridge() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [try StoredProject(name: "Pending reconstruction")])
        try JSONEncoder().encode(archive).write(to: f.archiveURL)
        let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: f.paths.workingSet, deviceID: "fixture")
        let journal = FileSyncMutationJournal(url: f.paths.mutationJournalURL)
        try journal.enqueue(package.records.map { try SyncMutation.save(recordVersion: SyncRecordVersion(record: $0), mutationID: UUID()) })
        let pending = try journal.pending()
        try FileManager.default.removeItem(at: f.archiveURL)
        let original = try f.diskBytes()
        let context = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let bootstrap = try SyncBootstrapTransaction(liveRoot: f.paths.workingSet, context: context, validateContext: { _ in })
        let prepared = try bootstrap.prepareReconstruction(remote: .init(context: context, records: [], attachments: [:], isComplete: true),
            pendingSnapshot: .init(mutations: pending, sourceTreeFingerprint: bootstrap.sourceFingerprint()))
        try bootstrap.install(prepared); try bootstrap.rollback(prepared)
        for (path, bytes) in original { #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes) }
        #expect(!FileManager.default.fileExists(atPath: f.archiveURL.path))
        let before = try f.diskBytes()
        try f.storage.withRecoveryInventory(paths: f.paths, account: f.account, maximumBytes: 100_000_000) { entries in
            try SyncBootstrapTransaction.validateTerminalRecovery(account: f.account, accountRoot: f.paths.accountRoot,
                liveRoot: f.paths.workingSet, journalURL: f.paths.mutationJournalURL, entries: entries)
        }
        #expect(try f.diskBytes() == before)
        // The approved bridge publishes the original selector wire but binds
        // exact missing-archive rollback evidence inside the authenticated vault.
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys())
        let recovery = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: vault, journal: journal)
        let receipt = try recovery.seal(recovery.prepare(now: .now), now: .now)
        let main = try Data(contentsOf: f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json"))
        guard case .legacySelection = try SyncAccountRecoveryControlFile.decode(main) else { Issue.record("Expected v1 bridge"); return }
        let payload = try vault.restore(receipt.vaultID, account: f.account, now: .now)
        let wire = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        #expect(wire["formatVersion"] as? Int == 2)
        let capture = try #require(wire["sourceControl"] as? [String: Any])
        #expect(capture["mainBytes"] is NSNull && capture["nextBytes"] is NSNull)
        try recovery.cleanup(receipt)
        try recovery.restore(vaultID: receipt.vaultID, now: .now)
        #expect(try journal.pending() == pending)
    }

    @Test func staleReceiptCannotReplaceCurrentIntentOrEraseLaterData() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys()), journal: f.journal)
        let old = try tx.seal(tx.prepare(now: .now), now: .now)
        try tx.cleanup(old)
        try Data("later data".utf8).write(to: f.archiveURL)
        #expect(throws: (any Error).self) { try tx.cleanup(old) }
        #expect(throws: (any Error).self) { try tx.prepare(now: .now) }
        let intent = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        let original = try Data(contentsOf: intent)
        var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        object["vaultID"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: object).write(to: intent)
        let changed = try Data(contentsOf: intent)
        #expect(throws: (any Error).self) { try tx.cleanup(old) }
        #expect(try Data(contentsOf: intent) == changed)
        #expect(try Data(contentsOf: f.archiveURL) == Data("later data".utf8))
    }

    @Test func onlyAuthenticatedSealAuthorizesCompletePlaintextCleanupAndClose() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let keys = TransactionKeys()
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: keys)
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: f.journal)
        let mutation = SyncMutation.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID())
        try f.journal.enqueue(mutation)
        try f.write("staging/unsent", Data("source".utf8))
        try Data("temporary".utf8).write(to: f.paths.decryptedTemporary.appendingPathComponent("copy"))
        let before = try f.diskBytes()
        let prepared = try tx.prepare(now: .now)
        #expect(try f.diskBytes() == before)
        let sealed = try tx.seal(prepared, now: .now)
        #expect(try Data(contentsOf: f.archiveURL) == Data("canonical archive".utf8))
        try tx.cleanup(sealed)
        #expect(!FileManager.default.fileExists(atPath: f.archiveURL.path))
        #expect(!FileManager.default.fileExists(atPath: f.paths.staging.appendingPathComponent("unsent").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.paths.decryptedTemporary.path).isEmpty)
        let recovered = try tx.authenticatedSelection(now: .now)
        #expect(recovered?.phase == .cleanupComplete)
        #expect(recovered?.inventory.packet.mutations == [mutation])
        #expect(keys.values[sealed.vaultID] != nil)
        #expect(try vault.restore(sealed.vaultID, account: f.account, now: .now).count > 0)
        try f.storage.close()
    }

    @Test func mutationForeignAccountAndWrongVaultBindingRefuseWithoutDeletion() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let keys = TransactionKeys(), other = try SyncAccountIdentity(containerIdentifier: "test", userRecordName: "B")
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: keys)
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: f.journal)
        let prepared = try tx.prepare(now: .now)
        try f.write("staging/new", Data([1]))
        #expect(throws: (any Error).self) { try tx.seal(prepared, now: .now) }
        let fresh = try tx.prepare(now: .now)
        let receipt = try tx.seal(fresh, now: .now)
        try f.write("staging/new", Data([2]))
        #expect(throws: (any Error).self) { try tx.cleanup(receipt) }
        let foreign = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: other, vault: vault, journal: f.journal)
        #expect(throws: (any Error).self) { try foreign.recoverInterruptedTransition(now: .now) }
        #expect(try Data(contentsOf: f.archiveURL) == Data("canonical archive".utf8))
        let wrong = SyncRecoveryVault(directory: f.paths.quarantine, keychain: keys)
        let unbound = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: wrong, journal: f.journal)
        #expect(throws: (any Error).self) { try unbound.prepare(now: .now) }
    }

    @Test(arguments: ["key", "cipher", "intent", "unlink", "complete"])
    func interruptedCutsRetainPlaintextOrAuthenticatedRecovery(cut: String) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let keys = TransactionKeys(), fault = TransactionSyncFault()
        keys.dropWrites = cut == "key"
        let vault = cut == "cipher"
            ? SyncRecoveryVault(directory: f.paths.vault, keychain: keys, maximumPayloadBytes: 100_000_000, synchronize: { _ in throw TransactionFailure.injected })
            : SyncRecoveryVault(directory: f.paths.vault, keychain: keys)
        let mutation = SyncMutation.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID())
        try f.journal.enqueue(mutation)
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: f.journal, synchronize: fault.sync)
        let prepared = try tx.prepare(now: .now)
        if cut == "key" || cut == "cipher" {
            #expect(throws: (any Error).self) { try tx.seal(prepared, now: .now) }
            #expect(try f.journal.pending() == [mutation])
            #expect(FileManager.default.fileExists(atPath: f.archiveURL.path))
            return
        }
        let sealed = try tx.seal(prepared, now: .now)
        fault.failAfter = cut == "intent" ? 1 : cut == "unlink" ? 4 : nil
        if cut == "complete" { try tx.cleanup(sealed) }
        else { #expect(throws: (any Error).self) { try tx.cleanup(sealed) } }
        #expect(try vault.restore(sealed.vaultID, account: f.account, now: .now).count > 0)
        fault.failAfter = nil
        let fresh = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: f.journal)
        #expect(try fresh.recoverInterruptedTransition(now: .now)?.vaultID == sealed.vaultID)
        #expect(try fresh.authenticatedSelection(now: .now)?.inventory.packet.mutations == [mutation])
        #expect(!FileManager.default.fileExists(atPath: f.archiveURL.path))
        try f.storage.close()
    }

    @Test func pendingDeletionFilesAndMarkerAuthorityRemainInAuthenticatedPayload() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        let selected = try f.addDeletion(ledger: ledger, name: "pending", attachment: true)
        let expired = try f.addDeletion(ledger: ledger, name: "expired")
        try ledger.purge(now: Date(timeIntervalSince1970: 2_592_100), references: .init(acknowledgedRemovalVersionIDs: Set(expired.versions.map(\.versionID))))
        let markers = try ledger.pendingDeletionMarkerVersions()
        try f.journal.enqueue(SyncMutation.save(recordVersion: selected.versions[0], mutationID: UUID()))
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: TransactionKeys())
        let tx = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: f.journal)
        let sealed = try tx.seal(tx.prepare(now: .now), now: .now)
        try tx.cleanup(sealed)
        let payload = try #require(try tx.authenticatedSelection(now: .now)).inventory
        #expect(payload.deletionFiles.map(\.bytes) == [Data("retained photograph".utf8)])
        #expect(payload.pendingMarkerVersions == markers)
        #expect(!markers.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.ledgerRoot.path))
    }
}

private enum TransactionFailure: Error { case injected }
private final class TransactionKeys: SyncRecoveryVaultKeychain, @unchecked Sendable {
    var values: [UUID: Data] = [:]
    var dropWrites = false
    func insert(_ key: Data, for id: UUID) throws { if !dropWrites { values[id] = key } }
    func key(for id: UUID) throws -> Data? { values[id] }
    func remove(for id: UUID) throws { values[id] = nil }
}
private final class TransactionSyncFault: @unchecked Sendable {
    var failAfter: Int?
    var onSync: ((Int32) throws -> Void)?
    func sync(_ fd: Int32) throws {
        try onSync?(fd)
        if let count = failAfter {
            failAfter = count - 1
            if count <= 1 { throw TransactionFailure.injected }
        }
        guard fsync(fd) == 0 else { throw TransactionFailure.injected }
    }
}
