import CryptoKit
import Darwin
import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct SyncAccountRecoveryInventoryTests {
    @Test(arguments: [false, true], [false, true])
    func missingArchiveRollbackReopensWithoutControl(existingOnly: Bool, withMedia: Bool) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        if withMedia {
            let deletion = try f.addDeletion(ledger: ledger, name: "Retained before rollback", attachment: true)
            try FileSyncMutationJournal(url: f.paths.mutationJournalURL).enqueue(deletion.versions.map {
                try SyncMutation.save(recordVersion: $0, mutationID: UUID())
            })
        }
        let journal = try f.makeMissingArchiveRollback(withMedia: withMedia)
        let pending = try journal.pending()
        #expect(!pending.isEmpty)
        if withMedia { #expect(pending.contains { $0.attachmentSource != nil }) }
        try f.storage.close() // Ordinary close, not a simulated process crash.
        let before = try f.diskBytes()
        let reopened = SyncAccountStorage(baseURL: f.base); defer { try? reopened.close() }
        let paths = try existingOnly
            ? reopened.openExistingAccount(identity: f.account, validateAccount: {})
            : reopened.openForVerifiedAccount(identity: f.account, validateAccount: {})
        #expect(!FileManager.default.fileExists(atPath: f.archiveURL.path))
        #expect(!FileManager.default.fileExists(atPath: paths.accountRoot.appendingPathComponent(".sealed-recovery-v1").path))
        #expect(try f.diskBytes() == before)
        let captured = try SyncAccountRecoveryInventory.capture(storage: reopened, paths: paths, account: f.account,
            journal: journal, archiveURL: f.archiveURL)
        #expect(captured.packet.mutations == pending)
        if withMedia { #expect(!captured.packet.files.isEmpty); #expect(!captured.deletionFiles.isEmpty) }
        guard case .absent(let evidence) = captured.sourceAuthority else { Issue.record("Expected rollback authority"); return }
        #expect(evidence.rollbackEnvelope != nil)
        #expect(try f.diskBytes() == before)
    }

    @Test(arguments: [false, true], ["empty", "missing-active", "bogus", "digest", "version", "source",
        "prepared", "installed", "rollingBack", "committed", "account", "live", "journal", "namespace",
        "missing-original", "changed-original", "changed-live", "extra-tree", "symlink", "hardlink", "fifo", "main", "next", "top-level"])
    func invalidRollbackCannotAuthorizeStorageReopen(existingOnly: Bool, damage: String) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        _ = try f.makeMissingArchiveRollback()
        try f.storage.close()
        let activePath = try #require(try f.diskBytes().keys.first { $0.hasSuffix("/active.json") })
        let active = URL(fileURLWithPath: activePath)
        if damage == "top-level" {
            try FileManager.default.removeItem(at: f.paths.accountRoot.appendingPathComponent(".KnitNote-SyncBootstrap"))
            try f.write(".KnitNote-SyncBootstrap/active.json", Data("not bootstrap authority".utf8))
        } else if damage == "empty" {
            for path in try f.diskBytes().keys where path.contains("/.KnitNote-SyncBootstrap/") {
                try FileManager.default.removeItem(atPath: path)
            }
        } else if damage == "missing-active" { try FileManager.default.removeItem(at: active) }
        else if damage == "bogus" { try Data("not a manifest".utf8).write(to: active) }
        else if damage == "namespace" {
            try FileManager.default.moveItem(at: active.deletingLastPathComponent(),
                to: active.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("foreign-live"))
        } else if damage == "extra-tree" {
            try FileManager.default.createDirectory(at: active.deletingLastPathComponent().appendingPathComponent("foreign-tree"),
                withIntermediateDirectories: false)
        } else if damage == "symlink" || damage == "hardlink" || damage == "fifo" {
            let unsafe = active.deletingLastPathComponent().appendingPathComponent("unsafe-entry")
            if damage == "symlink" { try FileManager.default.createSymbolicLink(at: unsafe, withDestinationURL: active) }
            else if damage == "hardlink" { try FileManager.default.linkItem(at: active, to: unsafe) }
            else { #expect(mkfifo(unsafe.path, 0o600) == 0) }
        } else if damage == "missing-original" || damage == "changed-original" || damage == "changed-live" {
            let path = try #require(try f.diskBytes().keys.first {
                damage == "changed-live" ? $0 == f.paths.mutationJournalURL.appendingPathExtension("segment").path : $0.contains("/Original/")
            })
            if damage == "missing-original" { try FileManager.default.removeItem(atPath: path) }
            else { try Data("changed proof".utf8).write(to: URL(fileURLWithPath: path)) }
        } else if damage == "main" || damage == "next" {
            try f.write(".sealed-recovery-v1/" + (damage == "main" ? "intent.json" : "intent-next.json"), Data("conflicting control".utf8))
        } else {
            var envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: active)) as! [String: Any]
            var manifest = try JSONSerialization.jsonObject(with: Data(base64Encoded: envelope["payload"] as! String)!) as! [String: Any]
            if damage == "version" { manifest["version"] = 99 }
            else if damage == "source" { manifest["sourceTreeFingerprint"] = Data(repeating: 7, count: 32).base64EncodedString() }
            else if damage == "account" {
                var context = manifest["context"] as! [String: Any]
                context["accountIDHash"] = String(repeating: "b", count: 64); manifest["context"] = context
            } else if damage == "live" { manifest["livePath"] = f.paths.accountRoot.appendingPathComponent("foreign").path }
            else if damage == "journal" { manifest["journalPath"] = "SyncMetadata/foreign.json" }
            else if damage != "digest" { manifest["phase"] = damage }
            let payload = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes])
            envelope["payload"] = payload.base64EncodedString()
            envelope["digest"] = (damage == "digest" ? Data(repeating: 9, count: 32) : Data(SHA256.hash(data: payload))).base64EncodedString()
            try JSONSerialization.data(withJSONObject: envelope).write(to: active)
        }
        // No-control rejection must happen before even a lock file is created.
        if damage != "main", damage != "next" {
            try FileManager.default.removeItem(at: f.paths.accountRoot.appendingPathComponent(".storage-lock"))
        }
        let before = try f.diskBytes()
        let names = try FileManager.default.subpathsOfDirectory(atPath: f.paths.accountRoot.path).sorted()
        let reopened = SyncAccountStorage(baseURL: f.base)
        #expect(throws: (any Error).self) {
            if existingOnly { _ = try reopened.openExistingAccount(identity: f.account, validateAccount: {}) }
            else { _ = try reopened.openForVerifiedAccount(identity: f.account, validateAccount: {}) }
        }
        #expect(try f.diskBytes() == before)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: f.paths.accountRoot.path).sorted() == names)
    }

    @Test(arguments: [false, true])
    func validCommittedMissingArchiveEvidenceIsNotRollbackAdmission(existingOnly: Bool) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        _ = try f.makeMissingArchiveRollback()
        let active = URL(fileURLWithPath: try #require(try f.diskBytes().keys.first { $0.hasSuffix("/active.json") }))
        var envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: active)) as! [String: Any]
        var manifest = try JSONSerialization.jsonObject(with: Data(base64Encoded: envelope["payload"] as! String)!) as! [String: Any]
        manifest["phase"] = "committed"
        let payload = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes])
        envelope["payload"] = payload.base64EncodedString(); envelope["digest"] = Data(SHA256.hash(data: payload)).base64EncodedString()
        try JSONSerialization.data(withJSONObject: envelope).write(to: active)
        let receipt = SyncBootstrapReceipt(transactionID: UUID(uuidString: manifest["id"] as! String)!,
            accountIDHash: f.account.accountIDHash,
            sourceProof: .missingArchive(treeSHA256: Data(base64Encoded: manifest["sourceTreeFingerprint"] as! String)!))
        try JSONEncoder().encode(receipt).write(to: f.paths.workingSet.appendingPathComponent("SyncMetadata/bootstrap-receipt.json"))
        // Establish that this is valid terminal evidence, not merely corrupt JSON.
        try f.storage.withRecoveryInventory(paths: f.paths, account: f.account, maximumBytes: 100_000_000) { entries in
            let evidence = try #require(try SyncBootstrapTransaction.terminalRecoveryEvidence(account: f.account,
                accountRoot: f.paths.accountRoot, liveRoot: f.paths.workingSet, journalURL: f.paths.mutationJournalURL, entries: entries))
            #expect(evidence.phase == .committed)
        }
        try f.storage.close()
        let before = try f.diskBytes()
        let reopened = SyncAccountStorage(baseURL: f.base)
        #expect(throws: (any Error).self) {
            if existingOnly { _ = try reopened.openExistingAccount(identity: f.account, validateAccount: {}) }
            else { _ = try reopened.openForVerifiedAccount(identity: f.account, validateAccount: {}) }
        }
        #expect(try f.diskBytes() == before)
    }

    @Test(arguments: [false, true])
    func rollbackReopenGenerationRejectionPreservesOriginalBytes(existingOnly: Bool) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        _ = try f.makeMissingArchiveRollback(withMedia: true)
        try f.storage.close()
        let before = try f.diskBytes()
        let reopened = SyncAccountStorage(baseURL: f.base)
        var validations = 0
        enum Changed: Error { case generation }
        let validate = {
            validations += 1
            if validations == 2 { throw Changed.generation }
        }
        #expect(throws: Changed.generation) {
            if existingOnly { _ = try reopened.openExistingAccount(identity: f.account, validateAccount: validate) }
            else { _ = try reopened.openForVerifiedAccount(identity: f.account, validateAccount: validate) }
        }
        #expect(validations == 2)
        #expect(try f.diskBytes() == before)
        #expect(!FileManager.default.fileExists(atPath: f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1").path))
    }

    @Test(arguments: [false, true], ["active", "live"])
    func rollbackEvidenceChangedDuringOwnedValidationCannotReturnSession(existingOnly: Bool, change: String) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        _ = try f.makeMissingArchiveRollback()
        try f.storage.close()
        let before = try f.diskBytes()
        let target = change == "active"
            ? URL(fileURLWithPath: try #require(before.keys.first { $0.hasSuffix("/active.json") }))
            : f.paths.mutationJournalURL.appendingPathExtension("segment")
        let injected = Data("concurrent evidence change".utf8)
        final class Cut: @unchecked Sendable { var fired = false }
        let cut = Cut()
        let reopened = SyncAccountStorage(baseURL: f.base, synchronize: { descriptor in
            if !cut.fired { cut.fired = true; try injected.write(to: target) }
            guard fsync(descriptor) == 0 else { throw SyncAccountStorageError.unavailable }
        })
        #expect(throws: (any Error).self) {
            if existingOnly { _ = try reopened.openExistingAccount(identity: f.account, validateAccount: {}) }
            else { _ = try reopened.openForVerifiedAccount(identity: f.account, validateAccount: {}) }
        }
        #expect(cut.fired) // Mutation happens after preflight, with account ownership held.
        var expected = before; expected[target.path] = injected
        #expect(try f.diskBytes() == expected)
        #expect(!FileManager.default.fileExists(atPath: f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1").path))
    }

    @Test func legacyInventoryWireRemainsUnchanged() throws {
        // Literal emitted by the real pre-v2 capture in the behavioral RED run.
        let bytes = Data(#"{"accountIDHash":"819077780f769d0c256ce1b5f4ab944662a6d1b1a01e25217b44319381ce77c9","accountRoot":"file:///private/var/folders/s_/ylqd3gdx2rz79ppmgsw__8qm0000gn/T/recovery-inventory-BF4434E0-69A5-4AC2-BF97-76DA6384B07F/819077780f769d0c256ce1b5f4ab944662a6d1b1a01e25217b44319381ce77c9/","archiveURL":"file:///private/var/folders/s_/ylqd3gdx2rz79ppmgsw__8qm0000gn/T/recovery-inventory-BF4434E0-69A5-4AC2-BF97-76DA6384B07F/819077780f769d0c256ce1b5f4ab944662a6d1b1a01e25217b44319381ce77c9/working-set/projects-v1.json","deletionFiles":[],"entries":[{"byteCount":0,"device":16777234,"inode":348858192,"isDirectory":true,"relativePath":".decrypted-temporary","sha256":""},{"byteCount":0,"device":16777234,"inode":348858194,"isDirectory":true,"relativePath":".decrypted-temporary/88cc2a64-4069-445d-aaad-e33a45561b57","sha256":""},{"byteCount":0,"device":16777234,"inode":348858188,"isDirectory":true,"relativePath":"engine-state","sha256":""},{"byteCount":0,"device":16777234,"inode":348858187,"isDirectory":true,"relativePath":"journal","sha256":""},{"byteCount":0,"device":16777234,"inode":348858190,"isDirectory":true,"relativePath":"quarantine","sha256":""},{"byteCount":0,"device":16777234,"inode":348858189,"isDirectory":true,"relativePath":"staging","sha256":""},{"byteCount":0,"device":16777234,"inode":348858186,"isDirectory":true,"relativePath":"working-set","sha256":""},{"byteCount":17,"device":16777234,"inode":348858195,"isDirectory":false,"relativePath":"working-set/projects-v1.json","sha256":"7gD5EAa40EtyX4+769d+cgerq//lSLpHq78sAvZ7Ask="}],"fingerprint":"l9H0BDwyqFFvSw96UFRMlLge7MnJrb4SkUi0d3jjkUE=","journalURL":"file:///private/var/folders/s_/ylqd3gdx2rz79ppmgsw__8qm0000gn/T/recovery-inventory-BF4434E0-69A5-4AC2-BF97-76DA6384B07F/819077780f769d0c256ce1b5f4ab944662a6d1b1a01e25217b44319381ce77c9/journal/pending.json","packet":{"accountIDHash":"819077780f769d0c256ce1b5f4ab944662a6d1b1a01e25217b44319381ce77c9","accountRoot":"file:///private/var/folders/s_/ylqd3gdx2rz79ppmgsw__8qm0000gn/T/recovery-inventory-BF4434E0-69A5-4AC2-BF97-76DA6384B07F/819077780f769d0c256ce1b5f4ab944662a6d1b1a01e25217b44319381ce77c9/","files":[],"formatVersion":1,"mutations":[]},"pendingMarkerVersions":[]}"#.utf8)
        let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        let root = URL(string: object["accountRoot"] as! String)!
        let paths = SyncAccountStorage.Paths(accountRoot: root, workingSet: root.appendingPathComponent("working-set", isDirectory: true),
            journal: root.appendingPathComponent("journal", isDirectory: true), engineState: root.appendingPathComponent("engine-state"),
            staging: root.appendingPathComponent("staging"), quarantine: root.appendingPathComponent("quarantine"),
            vault: root.appendingPathComponent("vault"), decryptedTemporary: root.appendingPathComponent(".decrypted-temporary"))
        let account = try SyncAccountIdentity(containerIdentifier: "test", userRecordName: "A")
        let inventory = try SyncAccountRecoveryInventory.decodeRecovery(bytes, account: account, paths: paths,
            journalURL: URL(string: object["journalURL"] as! String)!, maximumBytes: 100_000_000)
        #expect(try inventory.encoded() == bytes)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        #expect(inventory.fingerprint == Data(SHA256.hash(data: try encoder.encode(inventory.entries))))
    }

    @Test func freshAllocationCapturesWithoutArchive() throws {
        let f = try SourceInventoryFixture(); defer { f.remove() }
        let before = try f.diskBytes()
        let value = try f.capture()
        #expect(value.packet.mutations.isEmpty)
        #expect(!value.entries.contains { $0.relativePath == "working-set/projects-v1.json" })
        #expect(try f.diskBytes() == before)
    }

    @Test func unknownMissingArchiveCannotCreateInventory() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        try FileManager.default.removeItem(at: f.archiveURL)
        let before = try f.diskBytes()
        #expect(throws: (any Error).self) { try f.capture() }
        #expect(try f.diskBytes() == before)
    }

    @Test func rollbackEvidenceMustMatchEmbeddedInventory() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let journal = try f.makeMissingArchiveRollback()
        let value = try SyncAccountRecoveryInventory.capture(storage: f.storage, paths: f.paths, account: f.account,
            journal: journal, archiveURL: f.archiveURL)
        guard case .absent(let evidence) = value.sourceAuthority else { Issue.record("Missing rollback evidence"); return }
        #expect(evidence.rollbackEnvelope != nil)
        let bytes = try value.encoded()
        for entry in value.entries where !entry.isDirectory {
            try FileManager.default.removeItem(at: f.paths.accountRoot.appendingPathComponent(entry.relativePath))
        }
        let decoded = try SyncAccountRecoveryInventory.decodeRecovery(bytes, account: f.account, paths: f.paths,
            journalURL: journal.recoveryLocation, maximumBytes: 100_000_000)
        #expect(decoded.sourceAuthority == value.sourceAuthority)
        for mutation in ["envelope", "original", "current", "root", "account", "journal"] {
            var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            var authority = object["sourceAuthority"] as! [String: Any]
            var source = authority["evidence"] as! [String: Any]
            var state = source["state"] as! [String: Any]
            if mutation == "envelope" { source["rollbackEnvelope"] = Data("bad".utf8).base64EncodedString() }
            else if mutation == "root" { state["accountInode"] = 1 }
            else if mutation == "account" { state["accountIDHash"] = String(repeating: "b", count: 64) }
            else if mutation == "journal" { state["journalURL"] = f.journalURL.absoluteString }
            else {
                var entries = object["entries"] as! [[String: Any]]
                let index = try #require(entries.firstIndex {
                    ($0["isDirectory"] as? Bool) == false && (mutation == "original"
                        ? ($0["relativePath"] as! String).contains("/Original/")
                        : ($0["relativePath"] as! String).hasPrefix("working-set/"))
                })
                entries[index]["sha256"] = Data(repeating: 9, count: 32).base64EncodedString()
                object["entries"] = entries
            }
            source["state"] = state; authority["evidence"] = source; object["sourceAuthority"] = authority
            let changed = try sourceInventoryJSON(object, refreshFingerprint: true)
            #expect(throws: (any Error).self) {
                try SyncAccountRecoveryInventory.decodeRecovery(changed, account: f.account, paths: f.paths,
                    journalURL: journal.recoveryLocation, maximumBytes: 100_000_000)
            }
        }
    }

    @Test func sourceV2RejectsMixedNullUnknownFields() throws {
        let f = try SourceInventoryFixture(); defer { f.remove() }
        let original = try JSONSerialization.jsonObject(with: f.capture().encoded()) as! [String: Any]
        for path in [["unknown"], ["formatVersion"], ["sourceAuthority"], ["sourceAuthority", "unknown"],
                     ["sourceAuthority", "relativePath"], ["sourceAuthority", "evidence", "rollbackEnvelope"],
                     ["sourceAuthority", "evidence", "state", "origin", "transactionID"]] {
            func change(_ object: [String: Any], _ keys: ArraySlice<String>) -> [String: Any] {
                var result = object; let key = keys.first!
                result[key] = keys.count == 1 ? NSNull() : change(object[key] as! [String: Any], keys.dropFirst())
                return result
            }
            let bytes = try sourceInventoryJSON(change(original, path[...]), refreshFingerprint: true)
            #expect(throws: (any Error).self) {
                try SyncAccountRecoveryInventory.decodeRecovery(bytes, account: f.account, paths: f.paths,
                    journalURL: f.paths.mutationJournalURL, maximumBytes: 100_000_000)
            }
            if path.first == "sourceAuthority" {
                let altered = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
                let authority = try JSONSerialization.data(withJSONObject: altered["sourceAuthority"]!, options: .fragmentsAllowed)
                #expect(throws: (any Error).self) { try JSONDecoder().decode(SyncAccountRecoverySourceAuthority.self, from: authority) }
            }
        }
    }

    @Test func versionedArchiveAuthorityBindsOnlyExactArchiveProof() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let captured = try f.capture()
        let archive = try #require(captured.entries.first { $0.relativePath == "working-set/projects-v1.json" })
        var object = try JSONSerialization.jsonObject(with: captured.encoded()) as! [String: Any]
        object["formatVersion"] = 2
        object["sourceAuthority"] = ["kind": "archive", "relativePath": archive.relativePath, "sha256": archive.sha256.base64EncodedString()]
        let bytes = try sourceInventoryJSON(object, refreshFingerprint: true)
        let decoded = try SyncAccountRecoveryInventory.decodeRecovery(bytes, account: f.account, paths: f.paths,
            journalURL: f.journalURL, maximumBytes: 100_000_000)
        #expect(decoded.sourceAuthority == .archive(relativePath: archive.relativePath, sha256: archive.sha256))
        #expect(try decoded.encoded() == bytes)
        for field in ["sha256", "relativePath", "evidence"] {
            var authority = object["sourceAuthority"] as! [String: Any]
            authority[field] = field == "sha256" ? Data(repeating: 8, count: 32).base64EncodedString()
                : field == "relativePath" ? "staging/not-archive" : NSNull()
            object["sourceAuthority"] = authority
            #expect(throws: (any Error).self) {
                try SyncAccountRecoveryInventory.decodeRecovery(sourceInventoryJSON(object, refreshFingerprint: true),
                    account: f.account, paths: f.paths, journalURL: f.journalURL, maximumBytes: 100_000_000)
            }
        }
    }

    @Test(arguments: ["projects-v1.json", "SyncMetadata/canonical.json", "SyncMetadata/.canonical-next.json",
                      "SyncMetadata/bootstrap-canonical.json", "SyncMetadata/bootstrap-receipt.json",
                      ".projects-v1.json.sync-publication.json"])
    func absentSourceRejectsCanonicalAuthorityDirectories(path: String) throws {
        let f = try SourceInventoryFixture(); defer { f.remove() }
        try FileManager.default.createDirectory(at: f.paths.workingSet.appendingPathComponent(path), withIntermediateDirectories: true)
        let before = try f.diskBytes()
        #expect(throws: (any Error).self) { try f.capture() }
        #expect(try f.diskBytes() == before)
    }

    @Test(arguments: [false, true])
    func completedCaptureRechecksExactControlAndEntries(controlOnly: Bool) throws {
        let f = try SourceInventoryFixture(); defer { f.remove() }
        try f.storage.withRecoveryOwnership(paths: f.paths, account: f.account, maximumBytes: 100_000_000) { access in
            let control = try SyncAccountRecoveryControlFile(synchronize: { _ in }).observe(access: access)
            guard case .absentSource(let source) = control.state else { Issue.record("Missing fresh source"); return }
            let changed = SyncAccountSourceState(authorityID: UUID(), generation: UUID(), accountIDHash: source.accountIDHash,
                accountRoot: source.accountRoot, accountDevice: source.accountDevice, accountInode: source.accountInode,
                archiveURL: source.archiveURL, journalURL: source.journalURL, baselineSHA256: source.baselineSHA256, origin: source.origin)
            let changedBytes = try SyncAccountRecoveryControlFile.encode(.absentSource(changed),
                predecessorSHA256: Data(SHA256.hash(data: try #require(control.mainBytes))))
            var reads = 0
            let observed = SyncAccountStorage.RecoveryAccess(accountDescriptor: access.accountDescriptor,
                controlDescriptor: access.controlDescriptor, entries: {
                    reads += 1
                    if reads == 2 {
                        if controlOnly { try changedBytes.write(to: f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")) }
                        else { try Data("concurrent engine write".utf8).write(to: f.paths.engineState.appendingPathComponent("changed")) }
                    }
                    return try access.entries()
                }, validate: access.validate)
            #expect(throws: (any Error).self) {
                try SyncAccountRecoveryInventory.capture(access: observed, paths: f.paths, account: f.account,
                    journal: f.journal, archiveURL: f.archiveURL, control: control, maximumBytes: 100_000_000)
            }
            #expect(reads == 2)
        }
    }

    @Test func retainedTemporarySessionsAreExactInventoryEntries() throws {
        let f = try SourceInventoryFixture(); defer { f.remove() }
        let retained = ".decrypted-temporary/" + UUID().uuidString.lowercased()
        let folder = f.paths.accountRoot.appendingPathComponent(retained)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("old session".utf8).write(to: folder.appendingPathComponent("copy"))
        let captured = try f.capture()
        #expect(captured.entries.contains { $0.relativePath == retained + "/copy" })
        let bytes = try captured.encoded()
        _ = try SyncAccountRecoveryInventory.decodeRecovery(bytes, account: f.account, paths: f.paths,
            journalURL: f.paths.mutationJournalURL, maximumBytes: 100_000_000)
        var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        var entries = object["entries"] as! [[String: Any]]
        entries.removeAll { $0["relativePath"] as? String == retained }
        object["entries"] = entries
        #expect(throws: (any Error).self) {
            try SyncAccountRecoveryInventory.decodeRecovery(sourceInventoryJSON(object, refreshFingerprint: true),
                account: f.account, paths: f.paths, journalURL: f.paths.mutationJournalURL, maximumBytes: 100_000_000)
        }
        try FileManager.default.createDirectory(at: f.paths.accountRoot.appendingPathComponent(".decrypted-temporary/not-a-session"), withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try f.capture() }
    }

    @Test func sourceEvidenceOverheadRejectsBeforeSelectedMediaRead() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let journal = try f.makeMissingArchiveRollback(withMedia: true)
        let complete = try SyncAccountRecoveryInventory.capture(storage: f.storage, paths: f.paths, account: f.account,
            journal: journal, archiveURL: f.archiveURL)
        let limit = try complete.encoded().count - 1
        let selected = try #require(complete.packet.files.first)
        let source = f.paths.accountRoot.appendingPathComponent(selected.relativePath)
        let media = selected.bytes
        let before = try f.diskBytes()
        // The real journal reader runs after the complete descriptor inventory.
        // Truncate only fixture media while preserving its safe path: a downstream
        // selected-payload read would fail its size proof; metadata must fail first.
        let observed = FileSyncMutationJournal(url: f.paths.mutationJournalURL, reader: SyncRegularFileReader(beforeRead: {
            try Data().write(to: source)
        }))
        #expect(throws: SyncPendingRecoveryPacketError.tooLarge) {
            try SyncAccountRecoveryInventory.capture(storage: f.storage, paths: f.paths, account: f.account,
                journal: observed, archiveURL: f.archiveURL, maximumBytes: limit)
        }
        #expect(try Data(contentsOf: source).isEmpty)
        try media.write(to: source)
        #expect(try f.diskBytes() == before)
        // Evidence alone must also be bounded before its payload is materialized.
        let active = try #require(complete.entries.first { $0.relativePath.hasSuffix("/active.json") })
        let url = f.paths.accountRoot.appendingPathComponent(active.relativePath)
        let original = try Data(contentsOf: url)
        try (original + Data(repeating: 32, count: 2_000_000)).write(to: url)
        #expect(throws: SyncAccountRecoveryInventory.Error.tooLarge) {
            try SyncAccountRecoveryInventory.capture(storage: f.storage, paths: f.paths, account: f.account,
                journal: journal, archiveURL: f.archiveURL, maximumBytes: 1_000_000)
        }
    }

    @Test func inventoryBackedJournalRequiresExactEveryPendingSourceProof() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let journal = try f.makeMissingArchiveRollback(withMedia: true)
        let before = try f.diskBytes()
        let pending = try journal.pending()
        let sources = pending.compactMap(\.attachmentSource)
        #expect(sources.count > 1)
        try f.storage.withRecoveryInventory(paths: f.paths, account: f.account, maximumBytes: 100_000_000) { entries in
            #expect(try journal.recoverySnapshot(accountRoot: f.paths.accountRoot, inventoryEntries: entries,
                maximumBytes: 100_000_000).mutations == pending)
            for source in sources {
                let path = String(source.fileURL.path.dropFirst(f.paths.accountRoot.path.count + 1))
                let index = try #require(entries.firstIndex { $0.relativePath == path })
                for damage in ["missing", "hash", "count", "directory"] {
                    var changed = entries
                    let old = changed[index]
                    if damage == "missing" { changed.remove(at: index) }
                    else {
                        changed[index] = .init(relativePath: path, isDirectory: damage == "directory",
                            byteCount: damage == "count" ? old.byteCount + 1 : old.byteCount,
                            sha256: damage == "hash" ? Data(repeating: 7, count: 32) : old.sha256,
                            device: old.device, inode: old.inode)
                    }
                    #expect(throws: (any Error).self) {
                        try journal.recoverySnapshot(accountRoot: f.paths.accountRoot, inventoryEntries: changed, maximumBytes: 100_000_000)
                    }
                }
            }
        }
        #expect(try f.diskBytes() == before)
    }

    @Test func inventoryBackedJournalPreservesExactACKReclaimedSourceSemantics() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let journal = try f.makeMissingArchiveRollback(withMedia: true)
        let pending = try journal.pending()
        let media = pending.filter { $0.attachmentSource != nil }
        #expect(!media.isEmpty)
        try journal.acknowledge(Set(media.map(\.identity)))
        for mutation in media { #expect(!FileManager.default.fileExists(atPath: mutation.attachmentSource!.fileURL.path)) }
        let expected = try journal.recoverySnapshot().mutations
        let before = try f.diskBytes()
        try f.storage.withRecoveryInventory(paths: f.paths, account: f.account, maximumBytes: 100_000_000) { entries in
            let snapshot = try journal.recoverySnapshot(accountRoot: f.paths.accountRoot, inventoryEntries: entries,
                maximumBytes: 100_000_000)
            #expect(snapshot.mutations == expected)
        }
        #expect(try f.diskBytes() == before)
    }

    private func sourceInventoryJSON(_ input: [String: Any], refreshFingerprint: Bool) throws -> Data {
        var object = input
        if refreshFingerprint {
            let projection = try JSONSerialization.data(withJSONObject: [
                "entries": object["entries"]!, "sourceAuthority": object["sourceAuthority"]!
            ], options: [.sortedKeys, .withoutEscapingSlashes])
            object["fingerprint"] = Data(SHA256.hash(data: projection)).base64EncodedString()
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    @Test func canonicalCandidateDirectoryCannotAuthorizeCleanup() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let url = f.paths.workingSet.appendingPathComponent("SyncMetadata/.canonical-next.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(throws: SyncAccountRecoveryInventory.Error.unresolvedRecovery) { try f.capture() }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func canonicalCheckpointIsBoundButAcknowledgedRecordsStayOutOfPendingPacket() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let canonical = try f.installCanonicalCheckpoint()
        let mutations = try canonical.records.map { try SyncMutation.save(recordVersion: .init(record: $0), mutationID: UUID()) }
        try f.journal.enqueue(mutations)
        try f.journal.acknowledge(Set(mutations.dropFirst().map(\.identity)))
        let inventory = try f.capture()
        let entry = try #require(inventory.entries.first { $0.relativePath == "working-set/SyncMetadata/canonical.json" })
        #expect(entry.sha256 == Data(SHA256.hash(data: try canonical.encoded())))
        #expect(entry.byteCount == Int64(try canonical.encoded().count))
        #expect(inventory.packet.mutations == [mutations[0]])
        #expect(inventory.packet.files.isEmpty)
        #expect(canonical.records.count == 7)
    }

    @Test(arguments: [Data("{\"formatVersion\":".utf8), Data("unresolved candidate".utf8)])
    func canonicalFixedTemporaryRefusesInventoryWithoutChangingBytes(bytes: Data) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        try f.write("working-set/SyncMetadata/.canonical-next.json", bytes)
        let before = try f.diskBytes()
        #expect(throws: SyncAccountRecoveryInventory.Error.unresolvedRecovery) { try f.capture() }
        #expect(try f.diskBytes() == before)
    }

    @Test func capturesExactPendingAndEveryPlaintextRootWithoutChangingFiles() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let mutation = SyncMutation.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID())
        try f.journal.enqueue(mutation)
        try f.write("staging/pending", Data("pending".utf8))
        try f.write("quarantine/retained", Data("retained".utf8))
        try f.write("vault/encrypted.vault", Data("ciphertext".utf8))
        try Data("decoded".utf8).write(to: f.paths.decryptedTemporary.appendingPathComponent("copy"))
        let before = try f.diskBytes()
        let result = try f.capture()
        #expect(result.packet.mutations == [mutation])
        #expect(result.journalURL == f.journalURL)
        let names = Set(result.entries.map(\.relativePath))
        #expect(names.contains("working-set/projects-v1.json"))
        #expect(names.contains("staging/pending"))
        #expect(names.contains("journal/pending.json.segment"))
        #expect(names.contains("quarantine/retained"))
        #expect(names.contains(where: { $0.hasSuffix("/copy") }))
        let excluded = names.filter { $0 == "vault" || $0.hasPrefix("vault/") || $0 == ".storage-lock" || $0 == ".decrypted-temporary/.owner-v1" }
        #expect(excluded.isEmpty)
        #expect(try f.diskBytes() == before)
        #expect(try f.capture().fingerprint == result.fingerprint)
    }

    @Test func partiallyAcknowledgedDeletionRetainsWholeSelectedGroupOnly() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        let selected = try f.addDeletion(ledger: ledger, name: "pending project")
        let acknowledged = try f.addDeletion(ledger: ledger, name: "acknowledged project")
        let all = try (selected.versions + acknowledged.versions).map { try SyncMutation.save(recordVersion: $0, mutationID: UUID()) }
        try f.journal.enqueue(all)
        try f.journal.acknowledge(Set(all.dropFirst().map(\.identity)))
        let before = try f.diskBytes()
        let result = try f.capture()
        #expect(result.packet.mutations == [all[0]])
        let export = try #require(result.deletionLedger)
        let envelope = try JSONSerialization.jsonObject(with: export) as! [String: Any]
        let payload = try JSONSerialization.jsonObject(with: Data(base64Encoded: envelope["payload"] as! String)!) as! [String: Any]
        let groups = payload["groups"] as! [[String: Any]]
        #expect(groups.count == 1)
        let entry = groups[0]["entry"] as! [String: Any]
        #expect(entry["id"] as? String == selected.id.uuidString)
        #expect((entry["exactRemovalVersions"] as! [Any]).count == selected.versions.count)
        #expect(try f.diskBytes() == before)
    }

    @Test func capturesPendingMarkersAndIgnoresValidatedUnboundHistoricalStage() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        let deleted = try f.addDeletion(ledger: ledger, name: "expired")
        try ledger.purge(now: Date(timeIntervalSince1970: 2_592_100), references: .init(acknowledgedRemovalVersionIDs: Set(deleted.versions.map(\.versionID))))
        let markerVersions = try ledger.pendingDeletionMarkerVersions()
        _ = try ledger.stage(domain: f.domain("abandoned stage"), attachments: [:], restoreRelativePaths: [:], deletedAt: .now)
        let before = try f.diskBytes()
        let result = try f.capture()
        #expect(result.pendingMarkerVersions == markerVersions)
        #expect(!markerVersions.isEmpty)
        #expect(result.packet.mutations.isEmpty)
        #expect(try f.diskBytes() == before)
    }

    @Test func refusesBootstrapPublicationAndUnsafeBindingWithoutMutation() throws {
        for name in [".KnitNote-SyncBootstrap/original/data", "working-set/.projects-v1.json.sync-publication.json"] {
            let f = try RecoveryInventoryFixture(); defer { f.remove() }
            try f.write(name, Data("unresolved".utf8))
            let before = try f.diskBytes()
            #expect(throws: (any Error).self) { try f.capture() }
            #expect(try f.diskBytes() == before)
        }
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let before = try f.diskBytes()
        let other = try SyncAccountIdentity(containerIdentifier: "test", userRecordName: "B")
        #expect(throws: (any Error).self) {
            try SyncAccountRecoveryInventory.capture(storage: f.storage, paths: f.paths, account: other,
                journal: f.journal, archiveURL: f.archiveURL)
        }
        #expect(throws: (any Error).self) {
            try SyncAccountRecoveryInventory.capture(storage: f.storage, paths: f.paths, account: f.account,
                journal: FileSyncMutationJournal(url: f.base.appendingPathComponent("outside")), archiveURL: f.archiveURL)
        }
        #expect(try f.diskBytes() == before)
    }

    @Test func aggregateBudgetAndInterruptedJournalRefuseWithoutRepair() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        try f.journal.enqueue(.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID()))
        let before = try f.diskBytes()
        #expect(throws: (any Error).self) { try f.capture(maximumBytes: 1) }
        #expect(try f.diskBytes() == before)
        let segment = f.journalURL.appendingPathExtension("segment")
        var damaged = try Data(contentsOf: segment); damaged.append(contentsOf: [1, 2, 3])
        try damaged.write(to: segment)
        let interrupted = try f.diskBytes()
        #expect(throws: (any Error).self) { try f.capture() }
        #expect(try f.diskBytes() == interrupted)
    }

    @Test(arguments: ["committed", "rolledBack", "prepared", "corrupt", "wrongAccount"])
    func bootstrapTerminalProofIsReadOnlyAndBoundToCurrentAccount(state: String) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [try StoredProject(name: "bootstrap project")])
        try JSONEncoder().encode(archive).write(to: f.archiveURL)
        let context = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let bootstrap = try SyncBootstrapTransaction(liveRoot: f.paths.workingSet, context: context,
            journalRelativePath: "SyncMetadata/bootstrap-journal", validateContext: { _ in })
        let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: f.paths.workingSet, deviceID: "fixture")
        let prepared = try bootstrap.prepare(local: package, sourceArchive: archive,
            remote: .init(context: context, records: [], attachments: [:], isComplete: true))
        if state == "rolledBack" { try bootstrap.rollback(prepared) }
        else if state != "prepared" { try bootstrap.install(prepared); _ = try bootstrap.commit(prepared) }
        if state == "corrupt" {
            try Data("invalid receipt".utf8).write(to: f.paths.workingSet.appendingPathComponent("SyncMetadata/bootstrap-receipt.json"))
        }
        if state == "wrongAccount" {
            let active = prepared.accountOwnedRoots[0].appendingPathComponent("active.json")
            var envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: active)) as! [String: Any]
            var payload = try JSONSerialization.jsonObject(with: Data(base64Encoded: envelope["payload"] as! String)!) as! [String: Any]
            var context = payload["context"] as! [String: Any]; context["accountIDHash"] = String(repeating: "b", count: 64)
            payload["context"] = context
            let bytes = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
            envelope["payload"] = bytes.base64EncodedString(); envelope["digest"] = Data(SHA256.hash(data: bytes)).base64EncodedString()
            try JSONSerialization.data(withJSONObject: envelope).write(to: active)
        }
        let before = try f.diskBytes()
        let journal = FileSyncMutationJournal(url: f.paths.workingSet.appendingPathComponent("SyncMetadata/bootstrap-journal"))
        if ["committed", "rolledBack"].contains(state) {
            let result = try SyncAccountRecoveryInventory.capture(storage: f.storage, paths: f.paths, account: f.account, journal: journal, archiveURL: f.archiveURL)
            #expect(result.entries.contains { $0.relativePath.hasPrefix(".KnitNote-SyncBootstrap/") })
            #expect(state == "rolledBack" || !result.packet.mutations.isEmpty)
        } else if state == "wrongAccount" || state == "prepared" {
            #expect(throws: state == "prepared" ? SyncBootstrapError.invalidPhase : SyncBootstrapError.corrupt) {
                try SyncAccountRecoveryInventory.capture(storage: f.storage, paths: f.paths, account: f.account, journal: journal, archiveURL: f.archiveURL)
            }
        } else {
            #expect(throws: (any Error).self) {
                try SyncAccountRecoveryInventory.capture(storage: f.storage, paths: f.paths, account: f.account, journal: journal, archiveURL: f.archiveURL)
            }
        }
        #expect(try f.diskBytes() == before)
    }

    @Test func excludedVaultStillRequiresNoFollowOwnedDirectory() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let outside = f.base.appendingPathComponent("outside-vault")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let source = outside.appendingPathComponent("important")
        try Data("untouched".utf8).write(to: source)
        try FileManager.default.removeItem(at: f.paths.vault)
        try FileManager.default.createSymbolicLink(at: f.paths.vault, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try f.capture() }
        #expect(try Data(contentsOf: source) == Data("untouched".utf8))
    }

    @Test func selectedRetainedBytesRoundtripAndAggregateLimitIncludesDependencies() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        let selected = try f.addDeletion(ledger: ledger, name: "with photo", attachment: true)
        let mutation = try SyncMutation.save(recordVersion: selected.versions[0], mutationID: UUID())
        try f.journal.enqueue(mutation)
        let before = try f.diskBytes()
        let result = try f.capture()
        #expect(result.packet.mutations == [mutation])
        let file = try #require(result.deletionFiles.first)
        #expect(result.deletionFiles.count == 1)
        #expect(file.bytes == Data("retained photograph".utf8))
        let limit = try result.encoded().count
        #expect(throws: (any Error).self) { try f.capture(maximumBytes: limit - 1) }
        #expect(try f.capture(maximumBytes: limit).encoded(maximumBytes: limit).count == limit)
        #expect(try f.diskBytes() == before)
        let copy = f.base.appendingPathComponent("exported-ledger")
        let relative = String(file.relativePath.dropFirst("working-set/.sync-deletions/".count))
        let target = copy.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file.bytes.write(to: target)
        try #require(result.deletionLedger).write(to: copy.appendingPathComponent("ledger.json"))
        let restored = try SyncDeletionLedger(root: copy)
        #expect(try restored.recentlyDeleted().map(\.id) == [selected.id])
        #expect(try restored.recentlyDeleted().first?.exactRemovalVersions == selected.versions)
    }

    @Test(arguments: ["completed", "canceled", "prepared", "publication"])
    func ledgerRestorationHistoryRequiresTerminalDiskAuthority(state: String) throws {
        // Exercise construction, file encoding, validation and ledger recovery
        // on the native cooperative worker, where nested value copies overflowed.
        #expect(!Thread.isMainThread)
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        let deleted = try f.addDeletion(ledger: ledger, name: "restored project")
        let entry = try #require(ledger.recentlyDeleted().first)
        let mutations = try entry.domain.ownedRecords.map { try SyncMutation.save(recordVersion: SyncRecordVersion(record: $0), mutationID: UUID()) }
        let beforeHash = Data(SHA256.hash(data: try Data(contentsOf: f.archiveURL)))
        let publication = try SyncPublicationTransaction(expectedArchiveSHA256: Data(repeating: 9, count: 32),
            mutations: mutations, revisionReceipts: mutations.map { .init(entityID: $0.recordID, mutationID: $0.mutationID, logicalRevision: 1, deviceID: "fixture") },
            restorationWitness: .init(entryID: deleted.id, attemptID: UUID(), beforeArchiveSHA256: beforeHash))
        let publicationFile = SyncPublicationTransactionFile(archiveURL: f.archiveURL)
        try publicationFile.write(publication)
        #expect(try publicationFile.load() == publication)
        try ledger.beginRestore(publication: publication)
        if state == "completed" || state == "publication" { try ledger.finishRestore(publication: publication) }
        if state == "canceled" {
            try ledger.recover(archiveSHA256: beforeHash, publication: publication, publicationStatus: .uncommitted)
        }
        if state != "publication" { try publicationFile.remove() }
        try f.journal.enqueue(SyncMutation.save(recordVersion: deleted.versions[0], mutationID: UUID()))
        let before = try f.diskBytes()
        if ["completed", "canceled"].contains(state) {
            let result = try f.capture()
            let bytes = try #require(result.deletionLedger)
            let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            let payload = try JSONSerialization.jsonObject(with: Data(base64Encoded: object["payload"] as! String)!) as! [String: Any]
            let groups = payload["groups"] as! [[String: Any]]
            #expect(groups.count == (state == "canceled" ? 1 : 0))
            #expect(groups.first?["restoration"] == nil)
        } else { #expect(throws: (any Error).self) { try f.capture() } }
        #expect(try f.diskBytes() == before)
    }

    @Test func pendingPurgeAndUnknownLedgerFileAreNotRecoveredByCapture() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        let deleted = try f.addDeletion(ledger: ledger, name: "purging", attachment: true)
        do {
            try ledger.purge(now: Date(timeIntervalSince1970: 2_592_100),
                references: .init(acknowledgedRemovalVersionIDs: Set(deleted.versions.map(\.versionID))),
                afterIntent: { throw SyncDeletionLedgerError.unavailable })
            Issue.record("Expected injected interruption")
        } catch {}
        let before = try f.diskBytes()
        #expect(throws: (any Error).self) { try f.capture() }
        #expect(try f.diskBytes() == before)
        let other = try RecoveryInventoryFixture(); defer { other.remove() }
        _ = try SyncDeletionLedger(root: other.ledgerRoot)
        try Data("unknown repair".utf8).write(to: other.ledgerRoot.appendingPathComponent("unknown"))
        let unchanged = try other.diskBytes()
        #expect(throws: (any Error).self) { try other.capture() }
        #expect(try other.diskBytes() == unchanged)
    }

    @Test func concreteSnapshotBoundsJournalReadsAndPreservesStagedAttachmentURLs() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        _ = try f.addDeletion(ledger: ledger, name: "photo", attachment: true)
        let entry = try #require(ledger.recentlyDeleted().first)
        let record = try #require(entry.domain.ownedRecords.first { $0.id.kind == .attachment })
        let proof = try #require(entry.files.first)
        let source = try SyncAttachmentSource(fileURL: f.ledgerRoot.appendingPathComponent(proof.retainedRelativePath), contentSHA256: proof.sha256, byteCount: proof.byteCount)
        try f.journal.enqueue(SyncMutation.save(recordVersion: SyncRecordVersion(record: record), attachmentSource: source, mutationID: UUID()))
        let pending = try f.journal.pending()
        let before = try f.diskBytes()
        #expect(throws: (any Error).self) { try f.journal.recoverySnapshot(maximumBytes: 1) }
        let result = try f.capture()
        #expect(result.packet.mutations == pending)
        #expect(result.packet.files.first?.bytes == Data("retained photograph".utf8))
        #expect(result.packet.mutations.first?.attachmentSource?.fileURL == pending[0].attachmentSource?.fileURL)
        #expect(try f.diskBytes() == before)
    }

    @Test(arguments: ["completed", "canceled", "changedBytes", "unknownPath"])
    func terminalRestorationRecognizesOnlyItsExactStagedSources(state: String) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        let deleted = try f.addDeletion(ledger: ledger, name: "restored photo", attachment: true)
        let entry = try #require(ledger.recentlyDeleted().first)
        let restored = try entry.domain.restoring(into: entry.exactRemovalVersions.map(\.record),
            now: Date(timeIntervalSince1970: 200), deviceID: "fixture")
        let record = try #require(restored.records.first { restored.changedIDs.contains($0.id) && $0.id.kind == .attachment })
        let proof = try #require(entry.files.first)
        let original = try SyncAttachmentSource(fileURL: f.ledgerRoot.appendingPathComponent(proof.retainedRelativePath), contentSHA256: proof.sha256, byteCount: proof.byteCount)
        let staged = try ledger.stageRestoreSources(id: deleted.id, sources: [record.id.uuid: original])
        let mutations = try restored.records.filter { restored.changedIDs.contains($0.id) }.map {
            try SyncMutation.save(recordVersion: SyncRecordVersion(record: $0), attachmentSource: staged[$0.id.uuid], mutationID: UUID())
        }
        let beforeHash = Data(SHA256.hash(data: try Data(contentsOf: f.archiveURL)))
        let publication = try SyncPublicationTransaction(expectedArchiveSHA256: Data(repeating: 9, count: 32), mutations: mutations,
            revisionReceipts: mutations.map { .init(entityID: $0.recordID, mutationID: $0.mutationID, logicalRevision: 101, deviceID: "fixture") },
            restorationWitness: .init(entryID: deleted.id, attemptID: UUID(), beforeArchiveSHA256: beforeHash))
        try ledger.beginRestore(publication: publication)
        if state == "canceled" { try ledger.recover(archiveSHA256: beforeHash, publication: publication, publicationStatus: .uncommitted) }
        else { try ledger.finishRestore(publication: publication) }
        let stagedURL = try #require(staged[record.id.uuid]?.fileURL)
        if state == "changedBytes" { try Data("changed photograph!".utf8).write(to: stagedURL) }
        if state == "unknownPath" {
            try FileManager.default.moveItem(at: stagedURL, to: stagedURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString))
        }
        let before = try f.diskBytes()
        if state == "completed" || state == "canceled" {
            let result = try f.capture()
            #expect(result.packet.files.isEmpty)
            #expect(result.deletionFiles.isEmpty)
            #expect(result.entries.contains { $0.relativePath.contains("/restore-") && !$0.isDirectory })
        } else { #expect(throws: (any Error).self) { try f.capture() } }
        #expect(try f.diskBytes() == before)
    }

    @Test func recoveryAttachmentReadCannotExceedRemainingCaptureBudget() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let bytes = Data(repeating: 42, count: 1_048_576)
        let file = f.paths.staging.appendingPathComponent("large-photo")
        try bytes.write(to: file)
        let owner = SyncEntityID(kind: .project, uuid: UUID())
        let version = try SyncAttachmentVersion.issuing(slot: .init(owner: owner, role: "project-photo", slotID: "cover"),
            contentSHA256: Data(SHA256.hash(data: bytes)), byteCount: Int64(bytes.count), mediaType: "image/jpeg", displayFilename: "cover.jpg")
        let stamp = SyncMutationStamp(logicalRevision: 1, modifiedAt: Date(timeIntervalSince1970: 1), deviceID: "fixture")
        let record = SyncRecord(schemaVersion: 1, id: .init(kind: .attachment, uuid: version.versionID), createdAt: stamp.modifiedAt,
            entityRevision: 1, payload: .init(fields: [:], attachment: version), relationships: [.init(role: "owner", target: owner)],
            deletedAt: .init(value: nil, stamp: stamp))
        try f.journal.enqueue(SyncMutation.save(recordVersion: SyncRecordVersion(record: record),
            attachmentSource: .init(fileURL: file, contentSHA256: version.contentSHA256, byteCount: version.byteCount), mutationID: UUID()))
        let counters = SyncRegularFileReaderIOCounters()
        let observed = FileSyncMutationJournal(url: f.journalURL, reader: SyncRegularFileReader(ioCounters: counters))
        let before = try f.diskBytes()
        let budget = 8_192
        #expect(throws: (any Error).self) {
            try SyncAccountRecoveryInventory.capture(storage: f.storage, paths: f.paths, account: f.account,
                journal: observed, archiveURL: f.archiveURL, maximumBytes: budget)
        }
        // Counters belong to the real regular-file reader, including checkpoint,
        // segment and attachment reads. Streaming inventory uses bounded chunks.
        #expect(counters.bytesRead <= budget)
        #expect(try f.diskBytes() == before)
    }

    @Test(arguments: ["base", "account", "lock", "owner", "temporary", "session", "vault"])
    func finalInventoryRevalidatesPathAndExcludedControlBindings(target: String) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let location: URL
        switch target {
        case "base": location = f.base
        case "account": location = f.paths.accountRoot
        case "lock": location = f.paths.accountRoot.appendingPathComponent(".storage-lock")
        case "owner": location = f.paths.decryptedTemporary.deletingLastPathComponent().appendingPathComponent(".owner-v1")
        case "temporary": location = f.paths.decryptedTemporary.deletingLastPathComponent()
        case "session": location = f.paths.decryptedTemporary
        default: location = f.paths.vault
        }
        let moved = f.base.deletingLastPathComponent().appendingPathComponent("recovery-binding-moved-" + UUID().uuidString)
        let regular = target == "lock" || target == "owner"
        let original = regular ? try Data(contentsOf: location) : nil
        var relocated = false
        defer {
            if relocated {
                try? FileManager.default.removeItem(at: location)
                try? FileManager.default.moveItem(at: moved, to: location)
            }
        }
        #expect(throws: (any Error).self) {
            try f.storage.withRecoveryInventory(paths: f.paths, account: f.account, maximumBytes: 100_000_000) { _ in
                try FileManager.default.moveItem(at: location, to: moved)
                relocated = true
                if let original { try original.write(to: location) }
                else { try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true) }
            }
        }
        #expect(FileManager.default.fileExists(atPath: moved.path))
        if let original { #expect(try Data(contentsOf: moved) == original) }
    }
}

struct SourceInventoryFixture {
    let base: URL
    let account = try! SyncAccountIdentity(containerIdentifier: "test", userRecordName: "source")
    let storage: SyncAccountStorage
    let paths: SyncAccountStorage.Paths
    let journal: FileSyncMutationJournal
    var archiveURL: URL { paths.workingSet.appendingPathComponent("projects-v1.json") }
    init() throws {
        base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("source-inventory-" + UUID().uuidString)
        storage = SyncAccountStorage(baseURL: base)
        paths = try storage.openForVerifiedAccount(identity: account, validateAccount: {})
        journal = FileSyncMutationJournal(url: paths.mutationJournalURL)
    }
    func capture(maximumBytes: Int = 100_000_000) throws -> SyncAccountRecoveryInventory {
        try .capture(storage: storage, paths: paths, account: account, journal: journal, archiveURL: archiveURL, maximumBytes: maximumBytes)
    }
    func diskBytes() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for case let url as URL in FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey])! {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { result[url.path] = try Data(contentsOf: url) }
        }
        return result
    }
    func remove() { try? storage.close(); try? FileManager.default.removeItem(at: base) }
}

struct RecoveryInventoryFixture {
    let base: URL
    let account = try! SyncAccountIdentity(containerIdentifier: "test", userRecordName: "A")
    let storage: SyncAccountStorage
    let paths: SyncAccountStorage.Paths
    let journal: FileSyncMutationJournal
    let journalURL: URL
    var archiveURL: URL { paths.workingSet.appendingPathComponent("projects-v1.json") }
    var ledgerRoot: URL { paths.workingSet.appendingPathComponent(".sync-deletions") }
    init() throws {
        base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("recovery-inventory-" + UUID().uuidString)
        storage = SyncAccountStorage(baseURL: base)
        paths = try storage.open(identity: account)
        journalURL = paths.journal.appendingPathComponent("pending.json")
        journal = FileSyncMutationJournal(url: journalURL)
        try Data("canonical archive".utf8).write(to: paths.workingSet.appendingPathComponent("projects-v1.json"))
    }
    func capture(maximumBytes: Int = 100_000_000) throws -> SyncAccountRecoveryInventory {
        try .capture(storage: storage, paths: paths, account: account, journal: journal, archiveURL: archiveURL, maximumBytes: maximumBytes)
    }
    func makeMissingArchiveRollback(withMedia: Bool = false) throws -> FileSyncMutationJournal {
        if withMedia { _ = try BackupFixture.writeCompleteArchive(to: paths.workingSet) }
        else {
            let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [try StoredProject(name: "Pending reconstruction")])
            try JSONEncoder().encode(archive).write(to: archiveURL)
        }
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: archiveURL))
        let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: paths.workingSet, deviceID: "fixture")
        let native = FileSyncMutationJournal(url: paths.mutationJournalURL)
        try native.enqueue(package.records.map { try SyncMutation.save(recordVersion: SyncRecordVersion(record: $0),
            attachmentSource: package.attachments[$0.id.uuid], mutationID: UUID()) })
        let pending = try native.pending()
        try FileManager.default.removeItem(at: archiveURL)
        let context = SyncBootstrapContext(accountIDHash: account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let bootstrap = try SyncBootstrapTransaction(liveRoot: paths.workingSet, context: context, validateContext: { _ in })
        let prepared = try bootstrap.prepareReconstruction(remote: .init(context: context, records: [], attachments: [:], isComplete: true),
            pendingSnapshot: .init(mutations: pending, sourceTreeFingerprint: bootstrap.sourceFingerprint()))
        try bootstrap.install(prepared); try bootstrap.rollback(prepared)
        return native
    }
    func installCanonicalCheckpoint() throws -> SyncCanonicalCheckpoint {
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [try StoredProject(name: "Canonical account A")])
        let bytes = try JSONEncoder().encode(archive)
        try bytes.write(to: archiveURL)
        let exported = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: paths.workingSet, deviceID: "account-fixture")
        let checkpoint = try SyncCanonicalCheckpoint(accountIDHash: account.accountIDHash, commitID: UUID(),
            archiveSHA256: Data(SHA256.hash(data: bytes)), records: exported.records, legacyRecordIDsToDelete: [])
        let store = try SyncCanonicalCheckpointStore(liveRoot: paths.workingSet, account: account, validateOwnership: {})
        try store.install(checkpoint, replacing: nil)
        return checkpoint
    }
    func write(_ path: String, _ bytes: Data) throws {
        let file = paths.accountRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
    }
    func diskBytes() throws -> [String: Data] {
        let items = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey])!
        var result: [String: Data] = [:]
        for case let url as URL in items where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[url.path] = try Data(contentsOf: url)
        }
        return result
    }
    func domain(_ name: String) throws -> SyncDeletedDomain {
        let project = try StoredProject(name: name)
        let records = try SyncCanonicalPublicationSnapshot(archive: .init(version: ProjectArchive.currentVersion, projects: [project]), deviceID: "fixture").records
        return .init(rootIDs: [.init(kind: .project, uuid: project.id)], ownedRecords: Array(records.values), supportingParentIDs: [], removedReminders: [:])
    }
    func addDeletion(ledger: SyncDeletionLedger, name: String, attachment: Bool = false) throws -> (id: UUID, versions: [SyncRecordVersion]) {
        var domain = try domain(name)
        var sources: [UUID: SyncAttachmentSource] = [:]
        var restorePaths: [UUID: String] = [:]
        if attachment {
            let bytes = Data("retained photograph".utf8)
            let source = paths.staging.appendingPathComponent(UUID().uuidString)
            try bytes.write(to: source)
            let owner = domain.rootIDs.first!
            let version = try SyncAttachmentVersion.issuing(slot: .init(owner: owner, role: "project-photo", slotID: "cover"),
                contentSHA256: Data(SHA256.hash(data: bytes)), byteCount: Int64(bytes.count), mediaType: "image/jpeg", displayFilename: "cover.jpg")
            let stamp = SyncMutationStamp(logicalRevision: 1, modifiedAt: Date(timeIntervalSince1970: 1), deviceID: "fixture")
            let record = SyncRecord(schemaVersion: 1, id: .init(kind: .attachment, uuid: version.versionID), createdAt: stamp.modifiedAt,
                entityRevision: 1, payload: .init(fields: [:], attachment: version), relationships: [.init(role: "owner", target: owner)],
                deletedAt: .init(value: nil, stamp: stamp))
            domain = .init(rootIDs: domain.rootIDs, ownedRecords: domain.ownedRecords + [record], supportingParentIDs: [], removedReminders: [:])
            sources[version.versionID] = try .init(fileURL: source, contentSHA256: version.contentSHA256, byteCount: version.byteCount)
            restorePaths[version.versionID] = "photos/cover.jpg"
        }
        let versions = try domain.ownedRecords.map { record in
            var deleted = record
            deleted.deletedAt = .init(value: Date(timeIntervalSince1970: 100), stamp: .init(logicalRevision: 100, modifiedAt: Date(timeIntervalSince1970: 100), deviceID: "fixture"))
            return try SyncRecordVersion(record: deleted)
        }
        let id = try ledger.stage(domain: domain, attachments: sources, restoreRelativePaths: restorePaths, deletedAt: Date(timeIntervalSince1970: 100))
        let witness = Data(repeating: 3, count: 32)
        try ledger.prepare(id: id, beforeArchiveSHA256: Data(repeating: 1, count: 32), afterArchiveSHA256: Data(repeating: 2, count: 32), exactRemovalVersions: versions, publicationSHA256: witness)
        try ledger.activate(id: id, publicationSHA256: witness)
        return (id, versions)
    }
    func remove() { try? storage.close(); try? FileManager.default.removeItem(at: base) }
}
