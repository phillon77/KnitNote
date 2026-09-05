import CryptoKit
import Darwin
import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct SyncAccountRecoveryTransactionTests {
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

    @Test func terminalBootstrapAndExactPendingAttachmentAreRecoveredWithoutWholeArchive() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [try StoredProject(name: "bootstrap project")])
        try JSONEncoder().encode(archive).write(to: f.archiveURL)
        let context = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let bootstrap = try SyncBootstrapTransaction(liveRoot: f.paths.workingSet, context: context,
            journalRelativePath: "SyncMetadata/bootstrap-journal", validateContext: { _ in })
        let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: f.paths.workingSet, deviceID: "fixture")
        let prepared = try bootstrap.prepare(local: package, sourceArchive: archive,
            remote: .init(context: context, records: [], attachments: [:], isComplete: true))
        try bootstrap.install(prepared); _ = try bootstrap.commit(prepared)
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
