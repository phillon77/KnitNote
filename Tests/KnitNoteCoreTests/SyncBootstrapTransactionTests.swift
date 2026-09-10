import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

struct SyncBootstrapTransactionTests {
    @Test func terminalRollbackEvidenceSurvivesPlaintextCleanupAndRejectsChangedProofs() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let journal = try f.makeMissingArchiveRollback()
        try f.storage.withRecoveryInventory(paths: f.paths, account: f.account, maximumBytes: 100_000_000) { entries in
            let evidence = try #require(try SyncBootstrapTransaction.terminalRecoveryEvidence(account: f.account,
                accountRoot: f.paths.accountRoot, liveRoot: f.paths.workingSet, journalURL: journal.recoveryLocation,
                entries: entries, read: { try Data(contentsOf: f.paths.accountRoot.appendingPathComponent($0)) }))
            #expect(evidence.phase == .rolledBack)
            let embedded: (String) throws -> Data = { path in
                guard path == evidence.activeRelativePath else { throw SyncBootstrapError.corrupt }
                return evidence.activeEnvelope
            }
            #expect(try SyncBootstrapTransaction.terminalRecoveryEvidence(account: f.account, accountRoot: f.paths.accountRoot,
                liveRoot: f.paths.workingSet, journalURL: journal.recoveryLocation, entries: entries, read: embedded) == evidence)
            #expect(throws: (any Error).self) {
                try SyncBootstrapTransaction.terminalRecoveryEvidence(account: f.account, accountRoot: f.paths.accountRoot,
                    liveRoot: f.paths.workingSet, journalURL: journal.recoveryLocation, entries: entries, read: { _ in evidence.activeEnvelope + Data([0]) })
            }
            for prefix in [evidence.activeRelativePath, "working-set/", evidence.activeRelativePath.replacingOccurrences(of: "active.json", with: evidence.transactionID.uuidString + "/Original/")] {
                var changed = entries
                let index = try #require(changed.firstIndex { $0.relativePath.hasPrefix(prefix) && !$0.isDirectory })
                let old = changed[index]
                changed[index] = .init(relativePath: old.relativePath, isDirectory: false, byteCount: old.byteCount,
                    sha256: Data(repeating: 7, count: 32), device: old.device, inode: old.inode)
                #expect(throws: (any Error).self) {
                    try SyncBootstrapTransaction.terminalRecoveryEvidence(account: f.account, accountRoot: f.paths.accountRoot,
                        liveRoot: f.paths.workingSet, journalURL: journal.recoveryLocation, entries: changed, read: embedded)
                }
            }
            let sibling = evidence.activeRelativePath.replacingOccurrences(of: "active.json", with: UUID().uuidString)
            let originalDirectory = evidence.activeRelativePath.replacingOccurrences(of: "active.json", with: evidence.transactionID.uuidString + "/Original")
            #expect(throws: (any Error).self) {
                try SyncBootstrapTransaction.terminalRecoveryEvidence(account: f.account, accountRoot: f.paths.accountRoot,
                    liveRoot: f.paths.workingSet, journalURL: journal.recoveryLocation,
                    entries: entries.filter { $0.relativePath != originalDirectory }, read: embedded)
            }
            let extra = SyncAccountRecoveryInventory.Entry(relativePath: sibling, isDirectory: true, byteCount: 0, sha256: Data(), device: 1, inode: 1)
            #expect(throws: (any Error).self) {
                try SyncBootstrapTransaction.terminalRecoveryEvidence(account: f.account, accountRoot: f.paths.accountRoot,
                    liveRoot: f.paths.workingSet, journalURL: journal.recoveryLocation, entries: entries + [extra], read: embedded)
            }
            let other = try SyncAccountIdentity(containerIdentifier: "test", userRecordName: "wrong")
            #expect(throws: (any Error).self) {
                try SyncBootstrapTransaction.terminalRecoveryEvidence(account: other, accountRoot: f.paths.accountRoot,
                    liveRoot: f.paths.workingSet, journalURL: journal.recoveryLocation, entries: entries, read: embedded)
            }
            #expect(throws: (any Error).self) {
                try SyncBootstrapTransaction.terminalRecoveryEvidence(account: f.account, accountRoot: f.paths.accountRoot,
                    liveRoot: f.paths.workingSet, journalURL: f.journalURL, entries: entries, read: embedded)
            }
        }
    }

    @Test(arguments: [false, true])
    func preparationWireFormatKeepsArchiveV1DistinctFromAbsenceV2(reconstruction: Bool) throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let package = try fixture.export()
        let tx = try fixture.transaction()
        let prepared: SyncBootstrapPreparation
        if reconstruction {
            try FileManager.default.removeItem(at: fixture.live.appendingPathComponent("projects-v1.json"))
            prepared = try tx.prepareReconstruction(remote: .init(context: fixture.context, records: package.records,
                attachments: [:], isComplete: true), pendingSnapshot: .init(mutations: [], sourceTreeFingerprint: tx.sourceFingerprint()))
        } else {
            prepared = try tx.prepare(local: package, sourceArchive: fixture.archive,
                remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true))
        }
        let envelope = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: prepared.accountOwnedRoots[0].appendingPathComponent("active.json"))) as? [String: Any])
        let encoded = try #require(envelope["payload"] as? String)
        let bytes = try #require(Data(base64Encoded: encoded))
        let manifest = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let common = Set(["version", "id", "context", "livePath", "journalPath", "original", "installed", "mutations", "phase"])
        #expect(Set(manifest.keys) == common.union(reconstruction ? ["sourceKind", "sourceTreeFingerprint"] : ["sourceArchiveFingerprint"]))
        #expect(manifest["version"] as? Int == (reconstruction ? 2 : 1))
        try tx.install(prepared)
        let receipt = try tx.commit(prepared)
        let wire = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        #expect(Set(wire.keys) == Set(["transactionID", "accountIDHash"]).union(reconstruction
            ? ["formatVersion", "sourceKind", "sourceTreeFingerprint"] : ["sourceArchiveFingerprint"]))
    }

    @Test(arguments: ["freeze", "appeared-during-prepare", "appeared-before-install", "permission"])
    func reconstructionRevalidatesFreezeAndNoFollowSourceAtBoundaries(_ damage: String) throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let remote = try fixture.export()
        let archiveURL = fixture.live.appendingPathComponent("projects-v1.json")
        try FileManager.default.removeItem(at: archiveURL)
        let original = try treeBytes(fixture.live)
        var triggered = false
        let tx = try SyncBootstrapTransaction(liveRoot: fixture.live, context: fixture.context,
            journalRelativePath: "SyncMetadata/bootstrap-journal", validateContext: { candidate in
                guard candidate == fixture.context else { throw SyncBootstrapError.contextChanged }
                guard !triggered, ["freeze", "appeared-during-prepare"].contains(damage),
                      let paths = FileManager.default.enumerator(at: fixture.root, includingPropertiesForKeys: nil),
                      paths.contains(where: { ($0 as? URL)?.lastPathComponent == "bootstrap-canonical.json" }) else { return }
                triggered = true
                if damage == "freeze" { throw SyncBootstrapError.contextChanged }
                try Data("appeared while frozen".utf8).write(to: archiveURL)
            })
        let fingerprint = try tx.sourceFingerprint()
        if damage == "permission" {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.live.path)
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.live.path) }
        #expect(throws: (any Error).self) {
            let prepared = try tx.prepareReconstruction(remote: .init(context: fixture.context, records: remote.records,
                attachments: [:], isComplete: true), pendingSnapshot: .init(mutations: [], sourceTreeFingerprint: fingerprint))
            if damage == "appeared-before-install" {
                try Data("appeared while frozen".utf8).write(to: archiveURL)
                try tx.install(prepared)
            }
        }
        if damage == "permission" { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.live.path) }
        if damage.hasPrefix("appeared") {
            var expected = original
            expected["projects-v1.json"] = Data("appeared while frozen".utf8)
            #expect(try treeBytes(fixture.live) == expected)
        } else { #expect(try treeBytes(fixture.live) == original) }
        if damage == "freeze" || damage == "appeared-during-prepare" { #expect(triggered) }
    }

    @Test(arguments: ["bytes", "remote-digest", "remote-size"])
    func reconstructionRejectsPendingAttachmentSourceDisagreement(_ damage: String) throws {
        let fixture = try Fixture(completeMedia: true); defer { fixture.remove() }
        let package = try fixture.export()
        let record = try #require(package.records.first { $0.id.kind == .attachment })
        let source = try #require(package.attachments[record.id.uuid])
        let journal = FileSyncMutationJournal(url: fixture.live.appendingPathComponent("SyncMetadata/bootstrap-journal"))
        try journal.enqueue(SyncMutation.save(recordVersion: SyncRecordVersion(record: record), attachmentSource: source, mutationID: UUID()))
        let pending = try journal.pending()
        let pendingSource = try #require(pending.first?.attachmentSource)
        var attachments = package.attachments
        if damage == "bytes" { try Data("changed immutable bytes".utf8).write(to: pendingSource.fileURL) }
        else {
            attachments[record.id.uuid] = try .init(fileURL: source.fileURL,
                contentSHA256: damage == "remote-digest" ? Data(repeating: 7, count: 32) : source.contentSHA256,
                byteCount: damage == "remote-size" ? source.byteCount + 1 : source.byteCount)
        }
        try FileManager.default.removeItem(at: fixture.live.appendingPathComponent("projects-v1.json"))
        let tx = try fixture.transaction()
        let fingerprint = try tx.sourceFingerprint()
        let original = try treeBytes(fixture.live)
        #expect(throws: (any Error).self) {
            try tx.prepareReconstruction(remote: .init(context: fixture.context, records: package.records,
                attachments: attachments, isComplete: true), pendingSnapshot: .init(mutations: pending, sourceTreeFingerprint: fingerprint))
        }
        #expect(try treeBytes(fixture.live) == original)
    }

    @Test(arguments: ["digest", "kind", "mixed"])
    func reconstructedReceiptTamperingRejectsFreshContextRecoveryWithoutWrites(_ damage: String) throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let remote = try fixture.export()
        try FileManager.default.removeItem(at: fixture.live.appendingPathComponent("projects-v1.json"))
        let tx = try fixture.transaction()
        let prepared = try tx.prepareReconstruction(remote: .init(context: fixture.context, records: remote.records,
            attachments: [:], isComplete: true), pendingSnapshot: .init(mutations: [], sourceTreeFingerprint: tx.sourceFingerprint()))
        try tx.install(prepared); _ = try tx.commit(prepared)
        let url = fixture.live.appendingPathComponent("SyncMetadata/bootstrap-receipt.json")
        var receipt = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        if damage == "digest" { receipt["sourceTreeFingerprint"] = Data(repeating: 9, count: 32).base64EncodedString() }
        else if damage == "kind" { receipt["sourceKind"] = "archive" }
        else { receipt["sourceArchiveFingerprint"] = Data(repeating: 9, count: 32).base64EncodedString() }
        try JSONSerialization.data(withJSONObject: receipt).write(to: url)
        let original = try treeBytes(fixture.root)
        let current = SyncBootstrapContext(accountIDHash: fixture.context.accountIDHash, epoch: UUID(), freezeID: UUID())
        let restarted = try SyncBootstrapTransaction(liveRoot: fixture.live, context: current,
            journalRelativePath: "SyncMetadata/bootstrap-journal", validateContext: { candidate in
                guard candidate == current else { throw SyncBootstrapError.contextChanged }
            })
        #expect(throws: (any Error).self) { try restarted.recoverUnderCurrentContext() }
        #expect(try treeBytes(fixture.root) == original)
    }

    @Test(arguments: [false, true])
    func reconstructionReplaysPendingOnlyGraphAndExactMediaFIFO(overlap: Bool) throws {
        let fixture = try Fixture(completeMedia: true); defer { fixture.remove() }
        let package = try fixture.export()
        let journal = FileSyncMutationJournal(url: fixture.live.appendingPathComponent("SyncMetadata/bootstrap-journal"))
        let saves = try package.records.map { record in
            try SyncMutation.save(recordVersion: SyncRecordVersion(record: record),
                attachmentSource: package.attachments[record.id.uuid], mutationID: UUID())
        }
        try journal.enqueue(saves)
        if overlap {
            var editedArchive = fixture.archive
            try editedArchive.projects[0].rename(to: "Pending overlap edit")
            let edited = try ProjectArchiveSyncMapper.export(archive: editedArchive, liveRoot: fixture.live, deviceID: "local")
            var record = try #require(edited.records.first { $0.id.uuid == editedArchive.projects[0].id })
            let stamp = SyncMutationStamp(logicalRevision: 99, modifiedAt: .now, deviceID: "local")
            record.entityRevision = 99
            record.payload.fields = record.payload.fields.mapValues { .init(value: $0.value, stamp: stamp) }
            record.deletedAt = .init(value: nil, stamp: stamp)
            try journal.enqueue(SyncMutation.save(recordVersion: SyncRecordVersion(record: record), mutationID: UUID()))
        }
        let pending = try journal.pending()
        let sourceBytes = try pending.compactMap(\.attachmentSource).map { ($0.fileURL, try Data(contentsOf: $0.fileURL)) }
        let other = try StoredProject(name: "Remote only")
        let otherRecords = try SyncCanonicalPublicationSnapshot(archive: .init(version: 14, projects: [other]), deviceID: "cloud").records.values
        let remoteRecords = overlap ? package.records + otherRecords : []
        try FileManager.default.removeItem(at: fixture.live.appendingPathComponent("projects-v1.json"))
        let original = try treeBytes(fixture.live)
        let tx = try fixture.transaction()
        let prepared = try tx.prepareReconstruction(remote: .init(context: fixture.context, records: remoteRecords,
            attachments: [:], isComplete: true), pendingSnapshot: .init(mutations: pending, sourceTreeFingerprint: tx.sourceFingerprint()))
        #expect(try treeBytes(fixture.live) == original)
        try tx.install(prepared); _ = try tx.commit(prepared)
        let after = try journal.pending()
        #expect(Array(after.prefix(pending.count)) == pending)
        #expect(Set(try fixture.readArchive().projects.map(\.id)) == Set(fixture.archive.projects.map(\.id) + (overlap ? [other.id] : [])))
        if overlap { #expect(try fixture.readArchive().projects.first { $0.id == fixture.archive.projects[0].id }?.name == "Pending overlap edit") }
        // Includes the label photo in addition to the six original media slots.
        #expect(try tx.checkpoint(prepared).records.filter { $0.id.kind == .attachment }.count == 7)
        for (url, bytes) in sourceBytes { #expect(try Data(contentsOf: url) == bytes) }
        try tx.canonicalHandoff(prepared).revalidate()
    }

    @Test(arguments: SyncBootstrapBoundary.allCases)
    func reconstructionEveryBoundaryRestoresExactAbsentTree(_ point: SyncBootstrapBoundary) throws {
        let fixture = try Fixture(completeMedia: true); defer { fixture.remove() }
        let remote = try fixture.export()
        let journal = FileSyncMutationJournal(url: fixture.live.appendingPathComponent("SyncMetadata/bootstrap-journal"))
        let record = try #require(remote.records.first { $0.id.kind == .attachment })
        try journal.enqueue(SyncMutation.save(recordVersion: SyncRecordVersion(record: record),
            attachmentSource: remote.attachments[record.id.uuid], mutationID: UUID()))
        let pending = try journal.pending()
        try FileManager.default.removeItem(at: fixture.live.appendingPathComponent("projects-v1.json"))
        let original = try treeBytes(fixture.live)
        var fired = false
        let tx = try fixture.transaction(boundary: { reached in
            if reached == point && !fired { fired = true; throw SyncBootstrapError.corrupt }
            if fired && reached == .afterRollbackIntent { throw SyncBootstrapError.corrupt }
        })
        do {
            let prepared = try tx.prepareReconstruction(remote: .init(context: fixture.context, records: remote.records,
                attachments: remote.attachments, isComplete: true),
                pendingSnapshot: .init(mutations: pending, sourceTreeFingerprint: tx.sourceFingerprint()))
            try tx.install(prepared)
            if [.afterRollbackIntent, .afterFailedMove, .afterOriginalRestore].contains(point) {
                try tx.rollback(prepared)
            } else { _ = try tx.commit(prepared) }
        } catch {}
        #expect(fired)
        let current = SyncBootstrapContext(accountIDHash: fixture.context.accountIDHash, epoch: UUID(), freezeID: UUID())
        let restarted = try SyncBootstrapTransaction(liveRoot: fixture.live, context: current,
            journalRelativePath: "SyncMetadata/bootstrap-journal", validateContext: { candidate in
                guard candidate == current else { throw SyncBootstrapError.contextChanged }
            })
        #expect(try restarted.recoverUnderCurrentContext() == nil)
        #expect(try treeBytes(fixture.live) == original)
        #expect(try journal.pending() == pending)
    }

    @Test(arguments: ["archive", "directory", "symlink", "incomplete", "context", "fingerprint", "parent", "counter", "media",
        "publication", "canonical", "temporary", "bootstrap", "receipt", "revision"])
    func reconstructionRejectsUnsafeOrIncompleteInputPreservingLive(_ damage: String) throws {
        let fixture = try Fixture(completeMedia: damage == "media"); defer { fixture.remove() }
        let package = try fixture.export()
        let archiveURL = fixture.live.appendingPathComponent("projects-v1.json")
        try FileManager.default.removeItem(at: archiveURL)
        let tx = try fixture.transaction()
        var fingerprint = try tx.sourceFingerprint()
        var records = package.records
        var context = fixture.context
        switch damage {
        case "archive": try Data("appeared".utf8).write(to: archiveURL)
        case "directory": try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: false)
        case "symlink": try FileManager.default.createSymbolicLink(at: archiveURL, withDestinationURL: fixture.root.appendingPathComponent("absent-target"))
        case "context": context = .init(accountIDHash: context.accountIDHash, epoch: UUID(), freezeID: UUID())
        case "fingerprint": fingerprint = Data(repeating: 0, count: 32)
        case "parent": records.removeAll { $0.id.kind == .project }
        case "counter": records.remove(at: try #require(records.firstIndex { $0.id.kind == .projectCounter }))
        case "publication", "canonical", "temporary", "bootstrap", "receipt", "revision":
            let paths = ["publication": ".projects-v1.json.sync-publication.json", "canonical": "SyncMetadata/canonical.json",
                "temporary": "SyncMetadata/.canonical-next.json", "bootstrap": "SyncMetadata/bootstrap-canonical.json",
                "receipt": "SyncMetadata/bootstrap-receipt.json", "revision": "SyncMetadata/revision-ledger.json"]
            let url = fixture.live.appendingPathComponent(paths[damage]!)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("retained authority".utf8).write(to: url)
            fingerprint = try tx.sourceFingerprint()
        default: break
        }
        let original = try treeBytes(fixture.live)
        #expect(throws: (any Error).self) {
            try tx.prepareReconstruction(remote: .init(context: context, records: records,
                attachments: [:], isComplete: damage != "incomplete"),
                pendingSnapshot: .init(mutations: [], sourceTreeFingerprint: fingerprint))
        }
        #expect(try treeBytes(fixture.live) == original)
    }

    @Test(arguments: ["kind", "version", "short", "mixed", "directory", "archive", "tree"])
    func reconstructionManifestRejectsContradictorySourceEvidence(_ damage: String) throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let remote = try fixture.export()
        try FileManager.default.removeItem(at: fixture.live.appendingPathComponent("projects-v1.json"))
        let tx = try fixture.transaction()
        let prepared = try tx.prepareReconstruction(remote: .init(context: fixture.context, records: remote.records,
            attachments: [:], isComplete: true), pendingSnapshot: .init(mutations: [], sourceTreeFingerprint: tx.sourceFingerprint()))
        let manifestURL = prepared.accountOwnedRoots[0].appendingPathComponent("active.json")
        try rewriteManifest(at: manifestURL) { manifest in
            switch damage {
            case "kind": manifest["sourceKind"] = "archive"
            case "version": manifest["version"] = 3
            case "short": manifest["sourceTreeFingerprint"] = Data([1]).base64EncodedString()
            case "mixed": manifest["sourceArchiveFingerprint"] = Data(repeating: 1, count: 32).base64EncodedString()
            case "tree": manifest["sourceTreeFingerprint"] = Data(repeating: 1, count: 32).base64EncodedString()
            default:
                var original = try #require(manifest["original"] as? [String: Any])
                if damage == "archive" {
                    let bytes = Data("contradictory original archive".utf8)
                    original["projects-v1.json"] = ["bytes": bytes.count, "digest": Data(SHA256.hash(data: bytes)).base64EncodedString()]
                    for root in [fixture.live, prepared.originalBackupRoot] { try bytes.write(to: root.appendingPathComponent("projects-v1.json")) }
                } else {
                    original["projects-v1.json/"] = ["bytes": -1, "digest": ""]
                    for root in [fixture.live, prepared.originalBackupRoot] {
                        try FileManager.default.createDirectory(at: root.appendingPathComponent("projects-v1.json"), withIntermediateDirectories: false)
                    }
                }
                manifest["original"] = original
                let encoded = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
                manifest["sourceTreeFingerprint"] = Data(SHA256.hash(data: encoded)).base64EncodedString()
            }
        }
        let before = try treeBytes(fixture.root)
        #expect(throws: (any Error).self) { try tx.install(prepared) }
        #expect(try treeBytes(fixture.root) == before)
    }

    @Test func receiptLiteralLegacyCompatibilityAndStrictV2Discrimination() throws {
        let literal = Data(#"{"transactionID":"11111111-1111-1111-1111-111111111111","accountIDHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","sourceArchiveFingerprint":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}"#.utf8)
        let legacy = try JSONDecoder().decode(SyncBootstrapReceipt.self, from: literal)
        #expect(legacy.sourceProof == .archive(sha256: Data(repeating: 0, count: 32)))
        let encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        #expect(Set(encoded.keys) == Set(["transactionID", "accountIDHash", "sourceArchiveFingerprint"]))
        for damage in ["missing-version", "version-one", "unknown-version", "unknown-kind", "mixed", "short", "null-archive"] {
            var object: [String: Any] = ["transactionID": legacy.transactionID.uuidString, "accountIDHash": legacy.accountIDHash,
                "formatVersion": 2, "sourceKind": "missingArchive", "sourceTreeFingerprint": Data(repeating: 0, count: 32).base64EncodedString()]
            switch damage {
            case "missing-version": object.removeValue(forKey: "formatVersion")
            case "version-one": object["formatVersion"] = 1
            case "unknown-version": object["formatVersion"] = 3
            case "unknown-kind": object["sourceKind"] = "archive"
            case "short": object["sourceTreeFingerprint"] = "AA=="
            case "null-archive": object["sourceArchiveFingerprint"] = NSNull()
            default: object["sourceArchiveFingerprint"] = Data(repeating: 0, count: 32).base64EncodedString()
            }
            #expect(throws: (any Error).self) { try JSONDecoder().decode(SyncBootstrapReceipt.self, from: JSONSerialization.data(withJSONObject: object)) }
        }
    }

    private func rewriteManifest(at url: URL, edit: (inout [String: Any]) throws -> Void) throws {
        var envelope = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let encodedPayload = try #require(envelope["payload"] as? String)
        let payload = try #require(Data(base64Encoded: encodedPayload))
        var manifest = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        try edit(&manifest)
        let changed = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        envelope["payload"] = changed.base64EncodedString()
        envelope["digest"] = Data(SHA256.hash(data: changed)).base64EncodedString()
        try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: url)
    }

    @Test(arguments: [false, true])
    func reconstructionCommitsRealAbsentSourceAndRecoversUnderFreshContext(empty: Bool) throws {
        let fixture = try Fixture(empty: empty); defer { fixture.remove() }
        let remote = try fixture.export()
        try FileManager.default.removeItem(at: fixture.live.appendingPathComponent("projects-v1.json"))
        let original = try treeBytes(fixture.live)
        let transaction = try fixture.transaction()
        let fingerprint = try transaction.sourceFingerprint()
        let preparation = try transaction.prepareReconstruction(
            remote: .init(context: fixture.context, records: remote.records, attachments: remote.attachments, isComplete: true),
            pendingSnapshot: .init(mutations: [], sourceTreeFingerprint: fingerprint))
        #expect(try treeBytes(fixture.live) == original)
        #expect(try treeBytes(preparation.originalBackupRoot) == original)
        try transaction.install(preparation)
        let receipt = try transaction.commit(preparation)
        #expect(receipt.sourceProof == .missingArchive(treeSHA256: fingerprint))
        #expect(receipt.sourceArchiveFingerprint == nil)
        try transaction.canonicalHandoff(preparation).revalidate()
        #expect(try fixture.readArchive().projects == fixture.archive.projects)
        let current = SyncBootstrapContext(accountIDHash: fixture.context.accountIDHash, epoch: UUID(), freezeID: UUID())
        let restarted = try SyncBootstrapTransaction(liveRoot: fixture.live, context: current,
            journalRelativePath: "SyncMetadata/bootstrap-journal", validateContext: { candidate in
                guard candidate == current else { throw SyncBootstrapError.contextChanged }
            })
        try #require(try restarted.recoverUnderCurrentContext()).revalidate()
        let wire = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        #expect(wire["formatVersion"] as? Int == 2)
        #expect(wire["sourceKind"] as? String == "missingArchive")
        #expect(wire["sourceTreeFingerprint"] as? String == fingerprint.base64EncodedString())
        #expect(wire["sourceArchiveFingerprint"] == nil)
    }

    @Test func ordinaryPreparationRejectsMissingArchiveWithoutChangingLiveBytes() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let remote = try fixture.export()
        try FileManager.default.removeItem(at: fixture.live.appendingPathComponent("projects-v1.json"))
        let original = try treeBytes(fixture.live)
        #expect(throws: (any Error).self) {
            try fixture.transaction().prepare(local: remote, sourceArchive: fixture.archive,
                remote: .init(context: fixture.context, records: remote.records, attachments: remote.attachments, isComplete: true))
        }
        #expect(try treeBytes(fixture.live) == original)
    }

    @Test func currentContextRecoveryPreservesCommittedEvidenceAndRevokesRetainedHandoff() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let old = try fixture.transaction()
        let prepared = try old.prepare(local: fixture.export(), sourceArchive: fixture.archive,
            remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true))
        try old.install(prepared)
        let receipt = try old.commit(prepared)
        let current = SyncBootstrapContext(accountIDHash: fixture.context.accountIDHash, epoch: UUID(), freezeID: UUID())
        var frozen = true
        var authority = current
        let restarted = try SyncBootstrapTransaction(liveRoot: fixture.live, context: current,
            journalRelativePath: "SyncMetadata/bootstrap-journal", validateContext: { candidate in
                guard frozen, candidate == current, candidate == authority else { throw SyncBootstrapError.contextChanged }
            })
        let before = try treeBytes(fixture.root)
        #expect(throws: (any Error).self) { try restarted.recoverInterruptedInstallation() }
        #expect(throws: (any Error).self) { try restarted.canonicalHandoff(prepared) }
        for _ in 0..<2 {
            let handoff = try #require(try restarted.recoverUnderCurrentContext())
            #expect(handoff.transactionID == receipt.transactionID)
            #expect(handoff.accountIDHash == receipt.accountIDHash)
            try handoff.revalidate()
            frozen = false
            #expect(throws: SyncBootstrapError.contextChanged) { try handoff.revalidate() }
            #expect(throws: SyncBootstrapError.contextChanged) { try restarted.recoverUnderCurrentContext() }
            frozen = true
            authority = .init(accountIDHash: current.accountIDHash, epoch: UUID(), freezeID: UUID())
            #expect(throws: SyncBootstrapError.contextChanged) { try handoff.revalidate() }
            #expect(throws: SyncBootstrapError.contextChanged) { try restarted.recoverUnderCurrentContext() }
            authority = current
            #expect(try treeBytes(fixture.root) == before)
        }
        #expect(throws: (any Error).self) { try restarted.recoverInterruptedInstallation() }
    }

    @Test(arguments: SyncBootstrapBoundary.allCases)
    func currentContextRecoveryRestoresExactPendingSourcesAndAllowsFreshPrepare(_ point: SyncBootstrapBoundary) throws {
        let fixture = try Fixture(completeMedia: true); defer { fixture.remove() }
        let local = try fixture.export()
        let attachment = try #require(local.records.first { $0.id.kind == .attachment })
        let mutation = try SyncMutation.save(recordVersion: SyncRecordVersion(record: attachment),
            attachmentSource: local.attachments[attachment.id.uuid], mutationID: UUID())
        let journalURL = fixture.live.appendingPathComponent("SyncMetadata/bootstrap-journal")
        try FileSyncMutationJournal(url: journalURL).enqueue([mutation])
        let pending = try FileSyncMutationJournal(url: journalURL).pending()
        let source = try #require(pending.first?.attachmentSource)
        let sourceBytes = try Data(contentsOf: source.fileURL)
        let original = try treeBytes(fixture.live)
        var fired = false
        let old = try fixture.transaction(boundary: { reached in
            if reached == point && !fired { fired = true; throw SyncBootstrapError.corrupt }
            if fired && reached == .afterRollbackIntent { throw SyncBootstrapError.corrupt }
        })
        do {
            let prepared = try old.prepare(local: local, sourceArchive: fixture.archive,
                remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true),
                pendingSnapshot: .init(mutations: pending, sourceTreeFingerprint: try old.sourceFingerprint()))
            try old.install(prepared)
            if [.afterRollbackIntent, .afterFailedMove, .afterOriginalRestore].contains(point) {
                try old.rollback(prepared)
            } else { _ = try old.commit(prepared) }
        } catch {}
        #expect(fired)
        let current = SyncBootstrapContext(accountIDHash: fixture.context.accountIDHash, epoch: UUID(), freezeID: UUID())
        var frozen = true
        let restarted = try SyncBootstrapTransaction(liveRoot: fixture.live, context: current,
            journalRelativePath: "SyncMetadata/bootstrap-journal", validateContext: { candidate in
                guard frozen, candidate == current else { throw SyncBootstrapError.contextChanged }
            })
        let interrupted = try treeBytes(fixture.root)
        #expect(throws: (any Error).self) { try restarted.recoverInterruptedInstallation() }
        frozen = false
        #expect(throws: SyncBootstrapError.contextChanged) { try restarted.recoverUnderCurrentContext() }
        #expect(try treeBytes(fixture.root) == interrupted)
        frozen = true
        #expect(try restarted.recoverUnderCurrentContext() == nil)
        #expect(try treeBytes(fixture.live) == original)
        #expect(try FileSyncMutationJournal(url: journalURL).pending() == pending)
        #expect(try Data(contentsOf: source.fileURL) == sourceBytes)
        #expect(try Data(contentsOf: fixture.live.appendingPathComponent("private-unsent.bin")) == Data([1, 2, 3]))
        #expect(throws: (any Error).self) { try old.recoverInterruptedInstallation() }
        #expect(try restarted.recoverInterruptedInstallation() == nil)
        let restored = try fixture.readArchive()
        let fresh = try restarted.prepare(local: ProjectArchiveSyncMapper.export(archive: restored, liveRoot: fixture.live, deviceID: "local"),
            sourceArchive: restored,
            remote: .init(context: current, records: [], attachments: [:], isComplete: true),
            pendingSnapshot: .init(mutations: pending, sourceTreeFingerprint: try restarted.sourceFingerprint()))
        #expect(try treeBytes(fresh.originalBackupRoot) == original)
        #expect(throws: (any Error).self) { try old.install(fresh) }
        try restarted.install(fresh)
        _ = try restarted.commit(fresh)
    }

    @Test(arguments: ["envelope", "digest", "version", "account", "live", "journal", "relative", "checkpoint", "receipt", "original", "archive", "daily-authority", "symlink"])
    func currentContextRecoveryRejectsCorruptOrForeignSelectedEvidenceWithoutWrites(_ damage: String) throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let old = try fixture.transaction()
        let prepared = try old.prepare(local: fixture.export(), sourceArchive: fixture.archive,
            remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true))
        try old.install(prepared)
        _ = try old.commit(prepared)
        let manifestURL = prepared.accountOwnedRoots[0].appendingPathComponent("active.json")
        switch damage {
        case "envelope": try Data("broken-envelope".utf8).write(to: manifestURL)
        case "digest", "version", "account", "live", "journal", "relative":
            var envelope = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
            let encodedPayload = try #require(envelope["payload"] as? String)
            let payload = try #require(Data(base64Encoded: encodedPayload))
            var manifest = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
            switch damage {
            case "digest": break
            case "version": manifest["version"] = 2
            case "account":
                var context = try #require(manifest["context"] as? [String: Any])
                context["accountIDHash"] = String(repeating: "b", count: 64)
                manifest["context"] = context
            case "live": manifest["livePath"] = fixture.root.appendingPathComponent("Other").path
            case "journal": manifest["journalPath"] = "SyncMetadata/other-journal"
            default:
                var original = try #require(manifest["original"] as? [String: Any])
                original["../outside"] = original["projects-v1.json"]
                manifest["original"] = original
            }
            let changed = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            envelope["payload"] = changed.base64EncodedString()
            envelope["digest"] = (damage == "digest" ? Data(repeating: 0, count: 32) : Data(SHA256.hash(data: changed))).base64EncodedString()
            try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: manifestURL)
        case "checkpoint": try Data("corrupt-checkpoint".utf8).write(to: fixture.live.appendingPathComponent("SyncMetadata/bootstrap-canonical.json"))
        case "receipt": try Data("corrupt-receipt".utf8).write(to: fixture.live.appendingPathComponent("SyncMetadata/bootstrap-receipt.json"))
        case "original": try Data([9]).write(to: prepared.originalBackupRoot.appendingPathComponent("private-unsent.bin"))
        case "archive": try Data("changed-archive".utf8).write(to: fixture.live.appendingPathComponent("projects-v1.json"))
        case "symlink":
            let work = prepared.accountOwnedRoots[0]
            let moved = work.deletingLastPathComponent().appendingPathComponent("Moved")
            try FileManager.default.moveItem(at: work, to: moved)
            try FileManager.default.createSymbolicLink(at: work, withDestinationURL: moved)
        default: try Data([9]).write(to: fixture.live.appendingPathComponent("SyncMetadata/revision-ledger.extra"))
        }
        let before = try treeBytes(fixture.root)
        let current = SyncBootstrapContext(accountIDHash: fixture.context.accountIDHash, epoch: UUID(), freezeID: UUID())
        let restarted = try SyncBootstrapTransaction(liveRoot: fixture.live, context: current,
            journalRelativePath: "SyncMetadata/bootstrap-journal", validateContext: { candidate in
                guard candidate == current else { throw SyncBootstrapError.contextChanged }
            })
        #expect(throws: (any Error).self) { try restarted.recoverUnderCurrentContext() }
        #expect(try treeBytes(fixture.root) == before)
    }

    @Test func currentContextRecoveryAbsenceCreatesNothingAndDoesNotAdoptOtherNamespaces() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let old = try fixture.transaction()
        let prepared = try old.prepare(local: fixture.export(), sourceArchive: fixture.archive,
            remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true))
        try old.install(prepared)
        _ = try old.commit(prepared)
        let otherAccount = SyncBootstrapContext(accountIDHash: String(repeating: "b", count: 64), epoch: UUID(), freezeID: UUID())
        let sameAccount = SyncBootstrapContext(accountIDHash: fixture.context.accountIDHash, epoch: UUID(), freezeID: UUID())
        let before = try treeBytes(fixture.root)
        for (live, context) in [(fixture.live, otherAccount), (fixture.root.appendingPathComponent("MissingLive"), sameAccount)] {
            let transaction = try SyncBootstrapTransaction(liveRoot: live, context: context,
                journalRelativePath: "SyncMetadata/bootstrap-journal", validateContext: { candidate in
                    guard candidate == context else { throw SyncBootstrapError.contextChanged }
                })
            // No selected evidence grants no canonical readiness, even though a
            // different account/live namespace contains a committed transaction.
            #expect(try transaction.recoverUnderCurrentContext() == nil)
            #expect(try treeBytes(fixture.root) == before)
        }
        let wrongJournal = try SyncBootstrapTransaction(liveRoot: fixture.live, context: sameAccount,
            journalRelativePath: "SyncMetadata/other-journal", validateContext: { candidate in
                guard candidate == sameAccount else { throw SyncBootstrapError.contextChanged }
            })
        #expect(throws: (any Error).self) { try wrongJournal.recoverUnderCurrentContext() }
        #expect(try treeBytes(fixture.root) == before)
        let empty = fixture.root.appendingPathComponent("Empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let missing = try SyncBootstrapTransaction(liveRoot: empty.appendingPathComponent("Live"), context: sameAccount,
            validateContext: { candidate in guard candidate == sameAccount else { throw SyncBootstrapError.contextChanged } })
        #expect(try missing.recoverUnderCurrentContext() == nil)
        #expect(try treeBytes(empty).isEmpty)
        let alias = fixture.root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
        let withAlias = try treeBytes(fixture.root)
        #expect(throws: SyncBootstrapError.unsafePath) {
            try SyncBootstrapTransaction(liveRoot: alias.appendingPathComponent("Live"), context: sameAccount,
                validateContext: { candidate in guard candidate == sameAccount else { throw SyncBootstrapError.contextChanged } })
                .recoverUnderCurrentContext()
        }
        #expect(try treeBytes(fixture.root) == withAlias)
    }

    @Test func currentContextRecoveryRevocationDuringRollbackRetainsEvidenceForNextOwner() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let old = try fixture.transaction()
        let prepared = try old.prepare(local: fixture.export(), sourceArchive: fixture.archive,
            remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true))
        let original = try treeBytes(prepared.originalBackupRoot)
        try old.install(prepared)
        let installed = try treeBytes(fixture.live)
        let current = SyncBootstrapContext(accountIDHash: fixture.context.accountIDHash, epoch: UUID(), freezeID: UUID())
        var frozen = true
        var reachedIntent = false
        let restarted = try SyncBootstrapTransaction(liveRoot: fixture.live, context: current,
            journalRelativePath: "SyncMetadata/bootstrap-journal", validateContext: { candidate in
                guard frozen, candidate == current else { throw SyncBootstrapError.contextChanged }
            }, boundary: { reached in
                if reached == .afterRollbackIntent { reachedIntent = true; frozen = false }
            })
        #expect(throws: SyncBootstrapError.contextChanged) { try restarted.recoverUnderCurrentContext() }
        #expect(reachedIntent)
        #expect(try treeBytes(fixture.live) == installed)
        #expect(try treeBytes(prepared.originalBackupRoot) == original)
        let interrupted = try treeBytes(fixture.root)
        #expect(throws: SyncBootstrapError.contextChanged) { try restarted.recoverUnderCurrentContext() }
        #expect(try treeBytes(fixture.root) == interrupted)
        let next = SyncBootstrapContext(accountIDHash: current.accountIDHash, epoch: UUID(), freezeID: UUID())
        let finalOwner = try SyncBootstrapTransaction(liveRoot: fixture.live, context: next,
            journalRelativePath: "SyncMetadata/bootstrap-journal", validateContext: { candidate in
                guard candidate == next else { throw SyncBootstrapError.contextChanged }
            })
        #expect(try finalOwner.recoverUnderCurrentContext() == nil)
        #expect(try treeBytes(fixture.live) == original)
        #expect(try treeBytes(prepared.originalBackupRoot) == original)
        #expect(throws: (any Error).self) { try old.recoverInterruptedInstallation() }
    }

    @Test(arguments: [false, true])
    func currentContextRecoveryDoesNotRebindCorruptTerminalRollback(originalDamaged: Bool) throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let old = try fixture.transaction()
        let prepared = try old.prepare(local: fixture.export(), sourceArchive: fixture.archive,
            remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true))
        try old.install(prepared)
        try old.rollback(prepared)
        let damagedRoot = originalDamaged ? prepared.originalBackupRoot : fixture.live
        try Data([9]).write(to: damagedRoot.appendingPathComponent("private-unsent.bin"))
        let before = try treeBytes(fixture.root)
        let current = SyncBootstrapContext(accountIDHash: fixture.context.accountIDHash, epoch: UUID(), freezeID: UUID())
        let restarted = try SyncBootstrapTransaction(liveRoot: fixture.live, context: current,
            journalRelativePath: "SyncMetadata/bootstrap-journal", validateContext: { candidate in
                guard candidate == current else { throw SyncBootstrapError.contextChanged }
            })
        #expect(throws: (any Error).self) { try restarted.recoverUnderCurrentContext() }
        #expect(try treeBytes(fixture.root) == before)
        #expect(throws: (any Error).self) { try restarted.recoverInterruptedInstallation() }
    }

    private func treeBytes(_ root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        func walk(_ directory: URL, prefix: String) throws {
            for entry in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let relative = prefix + entry.lastPathComponent
                if values.isSymbolicLink == true {
                    result[relative + "@"] = Data(try FileManager.default.destinationOfSymbolicLink(atPath: entry.path).utf8)
                } else if values.isDirectory == true {
                    result[relative + "/"] = Data()
                    try walk(entry, prefix: relative + "/")
                } else { result[relative] = try Data(contentsOf: entry) }
            }
        }
        try walk(root, prefix: "")
        return result
    }

    @Test func canonicalHandoffRequiresCommitAndRevalidatesOriginalReceiptAndFreeze() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var frozen = true
        let transaction = try SyncBootstrapTransaction(liveRoot: fixture.live, context: fixture.context,
            journalRelativePath: "SyncMetadata/bootstrap-journal", validateContext: { candidate in
                guard frozen, candidate == fixture.context else { throw SyncBootstrapError.contextChanged }
            })
        let prepared = try transaction.prepare(local: fixture.export(), sourceArchive: fixture.archive,
            remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true))
        #expect(throws: (any Error).self) { try transaction.canonicalHandoff(prepared) }
        try transaction.install(prepared)
        #expect(throws: (any Error).self) { try transaction.canonicalHandoff(prepared) }
        let receipt = try transaction.commit(prepared)
        let handoff = try transaction.canonicalHandoff(prepared)
        #expect(handoff.transactionID == receipt.transactionID)
        #expect(handoff.accountIDHash == receipt.accountIDHash)
        try handoff.revalidate()
        frozen = false
        #expect(throws: SyncBootstrapError.contextChanged) { try handoff.revalidate() }
        frozen = true
        let receiptURL = fixture.live.appendingPathComponent("SyncMetadata/bootstrap-receipt.json")
        try FileManager.default.removeItem(at: receiptURL)
        #expect(throws: (any Error).self) { try handoff.revalidate() }
        #expect(throws: (any Error).self) { try transaction.canonicalHandoff(prepared) }
    }

    @Test(arguments: ["missing-counter", "rollback"])
    func remoteDeletionCannotBypassAuthorityOrOriginalTreeRollback(mode: String) throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let local = try fixture.export()
        let project = try #require(local.records.first { $0.id.kind == .project })
        let stamp = SyncMutationStamp(logicalRevision: 100, modifiedAt: .now, deviceID: "remote")
        var deleted = local.records.map { value -> SyncRecord in
            var value = value
            value.deletedAt = .init(value: stamp.modifiedAt, stamp: stamp)
            if value.id == project.id {
                value.payload.deletionCascade = .init(value: local.records.filter { $0.id != project.id }.map(\.id), stamp: stamp)
            }
            return value
        }
        let transaction = try fixture.transaction(boundary: { boundary in
            if mode == "rollback" && boundary == .afterJournal { throw SyncBootstrapError.contextChanged }
        })
        let original = try transaction.sourceFingerprint()
        if mode == "missing-counter" {
            deleted.removeAll { $0.id == project.id }
            #expect(throws: (any Error).self) {
                try transaction.prepare(local: local, sourceArchive: fixture.archive,
                    remote: .init(context: fixture.context, records: deleted, attachments: [:], isComplete: true))
            }
        } else {
            let prepared = try transaction.prepare(local: local, sourceArchive: fixture.archive,
                remote: .init(context: fixture.context, records: deleted, attachments: [:], isComplete: true))
            try transaction.install(prepared)
            #expect(try SyncDeletionLedger(root: SyncDeletionLedger.root(archiveURL: fixture.live.appendingPathComponent("projects-v1.json"))).recentlyDeleted().count == 1)
            #expect(throws: (any Error).self) { try transaction.commit(prepared) }
        }
        #expect(try transaction.sourceFingerprint() == original)
        #expect(try fixture.readArchive().projects == fixture.archive.projects)
        #expect(!FileManager.default.fileExists(atPath: fixture.live.appendingPathComponent(".sync-deletions").path))
    }

    @Test(arguments: [false, true]) @MainActor func remoteProjectDeletionIsRetainedBeforeReceiptAndRestoresOnDay29(reconstruction: Bool) throws {
        try verifyRemoteDeletionRetention(localRename: false, reconstruction: reconstruction)
    }

    @Test @MainActor func mergedRemoteDeletionSelectsOnlyItsRealPendingRecoveryDependency() throws {
        try verifyRemoteDeletionRetention(localRename: true)
    }

    @Test @MainActor func remoteDeletionRetainsItsGroupBesideVerifiedLiveProjectMedia() throws {
        try verifyRemoteDeletionRetention(localRename: false, liveMedia: true)
    }

    @MainActor private func verifyRemoteDeletionRetention(localRename: Bool, liveMedia: Bool = false, reconstruction: Bool = false) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let project = try StoredProject(name: "Remote project")
        let original = ProjectArchive(version: ProjectArchive.currentVersion, projects: [project])
        let remoteLive = try ProjectArchiveSyncMapper.export(archive: original, liveRoot: f.paths.workingSet, deviceID: "remote")
        let deletedAt = Date.now
        let stamp = SyncMutationStamp(logicalRevision: 100, modifiedAt: deletedAt, deviceID: "remote")
        let rootID = SyncEntityID(kind: .project, uuid: project.id)
        var remote = remoteLive.records.map { input -> SyncRecord in
            var record = input
            record.deletedAt = .init(value: deletedAt, stamp: stamp)
            if record.id == rootID {
                record.payload.deletionCascade = .init(value: remoteLive.records.filter { $0.id != rootID }.map(\.id), stamp: stamp)
            }
            return record
        }
        var remoteAttachments: [UUID: SyncAttachmentSource] = [:]
        var photo: URL?
        var photoBytes: Data?
        if liveMedia {
            var other = try StoredProject(name: "Unrelated live project")
            let service = ProjectPhotoFileService(directory: f.paths.workingSet.appendingPathComponent("ProjectPhotos"))
            let filename = try service.save(data: BackupFixture.jpegData(red: 0.4), projectID: other.id)
            other.setPhotoFilename(filename)
            photo = service.url(filename: filename)
            photoBytes = try Data(contentsOf: #require(photo))
            let media = try ProjectArchiveSyncMapper.export(archive: .init(version: ProjectArchive.currentVersion, projects: [other]),
                liveRoot: f.paths.workingSet, deviceID: "remote")
            remote += media.records; remoteAttachments = media.attachments
        }
        let journal = FileSyncMutationJournal(url: f.paths.workingSet.appendingPathComponent("SyncMetadata/pending.json"))
        var archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: localRename ? [project] : [])
        try JSONEncoder().encode(archive).write(to: f.archiveURL)
        var cache: SyncPublicationProjectionCache?
        if localRename {
            let data = try Data(contentsOf: f.archiveURL)
            let store = JSONProjectStore(url: f.archiveURL, syncMutationSink: JournalSyncMutationSink(journal: journal))
            let states = Dictionary(uniqueKeysWithValues: remoteLive.records.compactMap { record -> (UUID, SyncCounterReminderState)? in
                guard case let .projectCounter(state)? = record.payload.atomicDomain?.value else { return nil }
                return (record.id.uuid, state)
            })
            try store.hydrateSyncBootstrap(.init(archiveSHA256: Data(SHA256.hash(data: data)), records: remoteLive.records,
                counterStates: states, legacyRecordIDsToDelete: []))
            try store.rename(id: project.id, to: "Locally renamed")
            archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: f.archiveURL))
            cache = .init(archive: archive, records: syncRecords(Dictionary(uniqueKeysWithValues: remoteLive.records.map { ($0.id, $0) }), applying: try journal.pending()))
        }
        let local = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: f.paths.workingSet, deviceID: "local", reusing: cache)
        let context = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let bootstrap = try SyncBootstrapTransaction(liveRoot: f.paths.workingSet, context: context,
            journalRelativePath: "SyncMetadata/pending.json", validateContext: { _ in })
        let pending = try journal.pending()
        let prepared: SyncBootstrapPreparation
        if reconstruction {
            try FileManager.default.removeItem(at: f.archiveURL)
            prepared = try bootstrap.prepareReconstruction(remote: .init(context: context, records: remote,
                attachments: remoteAttachments, isComplete: true),
                pendingSnapshot: .init(mutations: pending, sourceTreeFingerprint: bootstrap.sourceFingerprint()))
        } else {
            prepared = try bootstrap.prepare(local: local, sourceArchive: archive,
                remote: .init(context: context, records: remote, attachments: remoteAttachments, isComplete: true),
                pendingSnapshot: .init(mutations: pending, sourceTreeFingerprint: try bootstrap.sourceFingerprint()))
        }
        try bootstrap.install(prepared)
        let installed = try SyncDeletionLedger(root: f.ledgerRoot).recentlyDeleted()
        #expect(installed.count == 1)
        _ = try bootstrap.commit(prepared)
        let entry = try #require(SyncDeletionLedger(root: f.ledgerRoot).recentlyDeleted().first)
        #expect(entry.domain.rootIDs == [rootID])
        #expect(entry.domain.ownedRecords.count == 7 && entry.exactRemovalVersions.count == 7)
        #expect(entry.files.isEmpty && entry.deletedAt == deletedAt)
        let inventory = try SyncAccountRecoveryInventory.capture(storage: f.storage, paths: f.paths, account: f.account,
            journal: journal, archiveURL: f.archiveURL)
        #expect(inventory.entries.contains { $0.relativePath == "working-set/.sync-deletions/ledger.json" })
        let captured = try #require(inventory.deletionLedger)
        let copy = f.base.appendingPathComponent("selected-ledger")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try captured.write(to: copy.appendingPathComponent("ledger.json"))
        let selected = try SyncDeletionLedger(root: copy).recentlyDeleted()
        #expect(selected.count == (localRename ? 1 : 0))
        if localRename {
            #expect(selected.first == entry)
            #expect(entry.exactRemovalVersions.contains { version in inventory.packet.mutations.contains { $0.savedRecordVersion == version } })
        } else { #expect(inventory.packet.mutations.isEmpty) }
        #expect(inventory.packet.files.isEmpty && inventory.deletionFiles.isEmpty)
        let reopened = JSONProjectStore(url: f.archiveURL, syncMutationSink: JournalSyncMutationSink(journal: journal))
        #expect(try bootstrap.checkpoint(prepared).counterStates.count == (liveMedia ? 12 : 6))
        try reopened.hydrateSyncBootstrap(bootstrap.checkpoint(prepared))
        try reopened.restoreRecentlyDeleted(id: entry.id, now: deletedAt.addingTimeInterval(29 * 86_400))
        #expect(reopened.projects.count == (liveMedia ? 2 : 1))
        let restored = try #require(reopened.projects.first { $0.id == project.id })
        #expect(restored.name == (localRename ? "Locally renamed" : "Remote project"))
        #expect(restored.counters.map(\.id) == project.counters.map(\.id))
        if let photo { #expect(try Data(contentsOf: photo) == photoBytes) }
    }

    @Test func consumedRemoteLegacyReminderHasDurableExactDeleteIntent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var archive = fixture.archive
        let counterID = archive.projects[0].mainCounterID
        try archive.projects[0].addKnittingReminder(counterID: counterID,
            draft: .oneTime(kind: .measure, target: 2, text: nil), now: .init(timeIntervalSinceReferenceDate: 100))
        try JSONEncoder().encode(archive).write(to: fixture.live.appendingPathComponent("projects-v1.json"))
        let reminder = archive.projects[0].knittingReminders[0]
        let stamp = SyncMutationStamp(logicalRevision: 0, modifiedAt: reminder.createdAt, deviceID: "legacy")
        let legacy = SyncRecord(schemaVersion: 1, id: .init(kind: .knittingReminder, uuid: reminder.id),
            createdAt: reminder.createdAt, entityRevision: reminder.mutationRevision,
            payload: .init(fields: [:], atomicDomain: .init(value: .knittingReminder(reminder), stamp: stamp)),
            relationships: [.init(role: "counter", target: .init(kind: .projectCounter, uuid: reminder.counterID))],
            deletedAt: .init(value: nil, stamp: stamp))
        let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: fixture.live, deviceID: "local")
        let transaction = try fixture.transaction()
        let prepared = try transaction.prepare(local: package, sourceArchive: archive,
            remote: .init(context: fixture.context, records: [legacy], attachments: [:], isComplete: true))
        try transaction.install(prepared)
        _ = try transaction.commit(prepared)
        let pending = try FileSyncMutationJournal(url: fixture.live.appendingPathComponent("SyncMetadata/bootstrap-journal")).pending()
        #expect(pending.contains { mutation in
            guard case let .delete(value) = mutation else { return false }; return value.recordID == legacy.id
        })
        #expect(try transaction.checkpoint(prepared).legacyRecordIDsToDelete == [legacy.id])
        #expect(try fixture.readArchive().projects[0].knittingReminders.map(\.id) == [reminder.id])
    }

    @Test(arguments: [false, true])
    func legacyPendingJournalRequiresSemanticRepairWithoutChangingOriginal(reconstruction: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let journal = FileSyncMutationJournal(url: fixture.live.appendingPathComponent("SyncMetadata/bootstrap-journal"))
        let old = SyncMutation.delete(.init(kind: .knittingReminder, uuid: UUID()), mutationID: UUID())
        try journal.enqueue([old])
        let pending = try journal.pending()
        if reconstruction { try FileManager.default.removeItem(at: fixture.live.appendingPathComponent("projects-v1.json")) }
        let transaction = try fixture.transaction()
        let fingerprint = try transaction.sourceFingerprint()
        #expect(throws: SyncPublicationError.pendingRepair) {
            if reconstruction {
                _ = try transaction.prepareReconstruction(remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true),
                    pendingSnapshot: .init(mutations: pending, sourceTreeFingerprint: fingerprint))
            } else {
                _ = try transaction.prepare(local: fixture.export(), sourceArchive: fixture.archive,
                    remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true),
                    pendingSnapshot: .init(mutations: pending, sourceTreeFingerprint: fingerprint))
            }
        }
        #expect(try transaction.sourceFingerprint() == fingerprint)
        #expect(try journal.pending() == pending)
        #expect(!FileManager.default.fileExists(atPath: fixture.live.appendingPathComponent("SyncMetadata/bootstrap-receipt.json").path))
    }
    @Test @MainActor func reopenedStoreAcknowledgesRetainedWatchProofWithoutApplyingAgain() throws {
        let fixture = try Fixture(empty: true)
        defer { fixture.remove() }
        let command = WatchCounterCommand(id: UUID(), projectID: UUID(), counterID: UUID(), operation: .increment, createdAt: .init(timeIntervalSince1970: 40))
        let proof = try SyncProcessedWatchCommandProof(id: command.id, rejection: .projectMissing,
            commandIdentity: .init(command), preparedCommand: nil, effectProof: nil,
            processingStamp: .init(logicalRevision: 0, modifiedAt: .init(timeIntervalSince1970: 41), deviceID: "local"))
        let package = try ProjectArchiveSyncMapper.export(archive: fixture.archive, liveRoot: fixture.live, deviceID: "local", processedWatchProofs: [proof])
        let transaction = try fixture.transaction()
        let prepared = try transaction.prepare(local: package, sourceArchive: fixture.archive,
            remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true))
        try transaction.install(prepared)
        _ = try transaction.commit(prepared)
        let evidence = try SyncAttachmentPublicationEvidenceFile(url: fixture.live.appendingPathComponent("SyncMetadata/attachment-versions.json")).load()
        #expect(evidence.watchCommandProofs == [proof])
        let store = JSONProjectStore(url: fixture.live.appendingPathComponent("projects-v1.json"),
            syncMutationSink: JournalSyncMutationSink(journal: FileSyncMutationJournal(url: fixture.live.appendingPathComponent("SyncMetadata/bootstrap-journal"))))
        try store.hydrateSyncBootstrap(transaction.checkpoint(prepared))
        let acknowledgement = try store.persistedWatchCommandAcknowledgement(for: command, entitlement: .permanentlyUnlocked,
            ledgerURL: fixture.live.appendingPathComponent("Watch/processed.json"), now: .init(timeIntervalSince1970: 50))
        #expect(acknowledgement?.rejection == .projectMissing)
        #expect(store.projects.isEmpty)
    }
    @Test func existingPendingJournalRequiresBoundSnapshotAndPreservesExactSources() throws {
        let fixture = try Fixture(completeMedia: true)
        defer { fixture.remove() }
        let package = try fixture.export()
        let attachment = try #require(package.records.first { $0.id.kind == .attachment })
        let oldMutation = try SyncMutation.save(recordVersion: SyncRecordVersion(record: attachment),
            attachmentSource: package.attachments[attachment.id.uuid], mutationID: UUID())
        let journalURL = fixture.live.appendingPathComponent("SyncMetadata/bootstrap-journal")
        let journal = FileSyncMutationJournal(url: journalURL)
        try journal.enqueue([oldMutation])
        let originalPending = try journal.pending()
        let transaction = try fixture.transaction()
        let remote = SyncBootstrapRemoteSnapshot(context: fixture.context, records: [], attachments: [:], isComplete: true)
        #expect(throws: (any Error).self) { try transaction.prepare(local: package, sourceArchive: fixture.archive, remote: remote) }
        let snapshot = SyncBootstrapPendingSnapshot(mutations: originalPending, sourceTreeFingerprint: try transaction.sourceFingerprint())
        let prepared = try transaction.prepare(local: package, sourceArchive: fixture.archive, remote: remote, pendingSnapshot: snapshot)
        try transaction.install(prepared)
        _ = try transaction.commit(prepared)
        let reopened = try FileSyncMutationJournal(url: journalURL).pending()
        #expect(reopened.contains(originalPending[0]))
        #expect(reopened.count > originalPending.count)
        let source = try #require(originalPending[0].attachmentSource)
        #expect(Data(SHA256.hash(data: try Data(contentsOf: source.fileURL))) == source.contentSHA256)
    }

    @Test func accountMismatchAndRevokedFreezeCannotReplaceLiveData() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transaction = try fixture.transaction()
        let otherContext = SyncBootstrapContext(accountIDHash: String(repeating: "b", count: 64), epoch: UUID(), freezeID: UUID())
        #expect(throws: (any Error).self) {
            try transaction.prepare(local: fixture.export(), sourceArchive: fixture.archive,
                remote: .init(context: otherContext, records: [], attachments: [:], isComplete: true))
        }
        var frozen = true
        let guarded = try SyncBootstrapTransaction(liveRoot: fixture.live, context: fixture.context,
            journalRelativePath: "SyncMetadata/bootstrap-journal", validateContext: { _ in
                guard frozen else { throw SyncBootstrapError.contextChanged }
            })
        let prepared = try guarded.prepare(local: fixture.export(), sourceArchive: fixture.archive,
            remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true))
        frozen = false
        #expect(throws: (any Error).self) { try guarded.install(prepared) }
        #expect(throws: (any Error).self) { try guarded.recoverInterruptedInstallation() }
        #expect(try fixture.readArchive().projects == fixture.archive.projects)
    }

    @Test func corruptManifestAndSymlinkSourcesFailClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let alias = fixture.root.appendingPathComponent("parentAlias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
        #expect(throws: (any Error).self) {
            try SyncBootstrapTransaction(liveRoot: alias.appendingPathComponent("Live"), context: fixture.context,
                journalRelativePath: "SyncMetadata/bootstrap-journal", validateContext: { _ in })
        }
        let transaction = try fixture.transaction()
        let prepared = try transaction.prepare(local: fixture.export(), sourceArchive: fixture.archive,
            remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true))
        let manifest = prepared.accountOwnedRoots[0].appendingPathComponent("active.json")
        try Data("corrupt".utf8).write(to: manifest)
        #expect(throws: (any Error).self) { try transaction.recoverInterruptedInstallation() }
        #expect(try fixture.readArchive().projects == fixture.archive.projects)
        let unsafe = try Fixture()
        defer { unsafe.remove() }
        try FileManager.default.createSymbolicLink(at: unsafe.live.appendingPathComponent("outside"), withDestinationURL: fixture.live)
        #expect(throws: (any Error).self) {
            try unsafe.transaction().prepare(local: unsafe.export(), sourceArchive: unsafe.archive,
                remote: .init(context: unsafe.context, records: [], attachments: [:], isComplete: true))
        }
    }
    @Test(arguments: SyncBootstrapBoundary.allCases) func interruptionsRecoverOriginal(_ point: SyncBootstrapBoundary) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var fired = false
        let transaction = try fixture.transaction(boundary: { current in
            if current == point && !fired { fired = true; throw SyncBootstrapError.corrupt }
            if fired && current == .afterRollbackIntent { throw SyncBootstrapError.corrupt }
        })
        do {
            let prepared = try transaction.prepare(local: fixture.export(), sourceArchive: fixture.archive,
                remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true))
            try transaction.install(prepared)
            if [.afterRollbackIntent, .afterFailedMove, .afterOriginalRestore].contains(point) {
                try transaction.rollback(prepared)
            } else { _ = try transaction.commit(prepared) }
        } catch {}
        #expect(fired)
        let reopened = try fixture.transaction()
        #expect(try reopened.recoverInterruptedInstallation() == nil)
        #expect(try fixture.readArchive().projects == fixture.archive.projects)
        #expect(try Data(contentsOf: fixture.live.appendingPathComponent("private-unsent.bin")) == Data([1, 2, 3]))
    }

    @Test func completeMediaSurvivesSwapAndOriginalStagingRemainsAfterAcknowledgement() throws {
        let fixture = try Fixture(completeMedia: true)
        defer { fixture.remove() }
        let transaction = try fixture.transaction()
        let package = try fixture.export()
        let prepared = try transaction.prepare(local: package, sourceArchive: fixture.archive,
            remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true))
        try transaction.install(prepared)
        _ = try transaction.commit(prepared)
        let journal = FileSyncMutationJournal(url: fixture.live.appendingPathComponent("SyncMetadata/bootstrap-journal"))
        let pending = try journal.pending()
        let sources = pending.compactMap { mutation -> SyncAttachmentSource? in
            guard case let .save(save) = mutation else { return nil }; return save.attachmentSource
        }
        #expect(sources.count == 7)
        for source in sources {
            #expect(Data(SHA256.hash(data: try Data(contentsOf: source.fileURL))) == source.contentSHA256)
        }
        #expect(try transaction.checkpoint(prepared).records.filter { $0.id.kind == .attachment }.count == 7)
        try journal.acknowledge(Set(pending.map(\.identity)))
        for id in package.attachments.keys {
            #expect(FileManager.default.fileExists(atPath: prepared.originalBackupRoot.deletingLastPathComponent().appendingPathComponent("Attachments/\(id.uuidString)").path))
        }
    }

    @Test func emptyLocalAndThreeDeviceUnionPublishOnlyNeededRecords() throws {
        let fixture = try Fixture(empty: true)
        defer { fixture.remove() }
        let first = try StoredProject(name: "One")
        let second = try StoredProject(name: "Two")
        let third = try StoredProject(name: "Three")
        let cloud = try [first, second, third].enumerated().flatMap { index, project in
            try SyncCanonicalPublicationSnapshot(archive: .init(version: 14, projects: [project]), deviceID: "device-\(index)").records.values
        }
        let transaction = try fixture.transaction()
        let prepared = try transaction.prepare(local: fixture.export(), sourceArchive: fixture.archive,
            remote: .init(context: fixture.context, records: cloud, attachments: [:], isComplete: true))
        try transaction.install(prepared)
        _ = try transaction.commit(prepared)
        #expect(Set(try fixture.readArchive().projects.map(\.id)) == Set([first.id, second.id, third.id]))
        #expect(try FileSyncMutationJournal(url: fixture.live.appendingPathComponent("SyncMetadata/bootstrap-journal")).pending().isEmpty)
    }

    @Test @MainActor func reopenedStoreConsumesRemoteRevisionThroughHydration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let local = try fixture.export()
        let remote = local.records.map { original -> SyncRecord in
            guard original.id.kind == .project else { return original }
            var record = original
            let stamp = SyncMutationStamp(logicalRevision: 99, modifiedAt: Date(timeIntervalSinceReferenceDate: 999), deviceID: "cloud")
            record.entityRevision = 99
            record.payload.fields = record.payload.fields.mapValues { .init(value: $0.value, stamp: stamp) }
            record.deletedAt = .init(value: nil, stamp: stamp)
            return record
        }
        let transaction = try fixture.transaction()
        let prepared = try transaction.prepare(local: local, sourceArchive: fixture.archive,
            remote: .init(context: fixture.context, records: remote, attachments: [:], isComplete: true))
        try transaction.install(prepared)
        _ = try transaction.commit(prepared)
        let journal = FileSyncMutationJournal(url: fixture.live.appendingPathComponent("SyncMetadata/bootstrap-journal"))
        let store = JSONProjectStore(url: fixture.live.appendingPathComponent("projects-v1.json"), syncMutationSink: JournalSyncMutationSink(journal: journal))
        #expect(throws: (any Error).self) {
            try store.updateProject(id: fixture.archive.projects[0].id, name: "Blocked", toolType: nil, toolSize: nil, toolNotes: nil, photoChange: .unchanged)
        }
        try store.hydrateSyncBootstrap(transaction.checkpoint(prepared))
        try store.updateProject(id: fixture.archive.projects[0].id, name: "Edited", toolType: nil, toolSize: nil, toolNotes: nil, photoChange: .unchanged)
        let changed = try #require(journal.pending().compactMap(\.savedRecordVersion?.record).last { $0.id.kind == .project })
        #expect(changed.entityRevision > 99)
    }

    @Test func mismatchedExportCannotEraseOriginalDomain() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transaction = try fixture.transaction()
        let empty = try ProjectArchiveSyncMapper.export(archive: .init(version: 14, projects: []), liveRoot: fixture.live, deviceID: "local")
        #expect(throws: (any Error).self) {
            try transaction.prepare(local: empty, sourceArchive: fixture.archive,
                remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true))
        }
        #expect(try fixture.readArchive().projects == fixture.archive.projects)
    }

    @Test func localAndCloudUnionRetainsUUIDsAndDurableJournal() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let other = try StoredProject(name: "Same name")
        let remote = try SyncCanonicalPublicationSnapshot(archive: .init(version: 14, projects: [other]), deviceID: "cloud").records.values
        let transaction = try fixture.transaction()
        let prepared = try transaction.prepare(local: fixture.export(), sourceArchive: fixture.archive,
            remote: .init(context: fixture.context, records: Array(remote), attachments: [:], isComplete: true))
        #expect(try fixture.readArchive().projects.map(\.id) == [fixture.archive.projects[0].id])
        try transaction.install(prepared)
        let receipt = try transaction.commit(prepared)
        #expect(Set(try fixture.readArchive().projects.map(\.id)) == Set([fixture.archive.projects[0].id, other.id]))
        #expect(receipt.accountIDHash == fixture.context.accountIDHash)
        #expect(try transaction.commit(prepared) == receipt)
        let journal = FileSyncMutationJournal(url: fixture.live.appendingPathComponent("SyncMetadata/bootstrap-journal"))
        #expect(try journal.pending().contains { $0.recordID.uuid == fixture.archive.projects[0].id })
        #expect(try Data(contentsOf: prepared.originalBackupRoot.appendingPathComponent("private-unsent.bin")) == Data([1, 2, 3]))
    }

    @Test func incompleteFetchAndChangedSourceNeverInstall() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transaction = try fixture.transaction()
        #expect(throws: (any Error).self) {
            try transaction.prepare(local: fixture.export(), sourceArchive: fixture.archive,
                remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: false))
        }
        let prepared = try transaction.prepare(local: fixture.export(), sourceArchive: fixture.archive,
            remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true))
        try Data([4]).write(to: fixture.live.appendingPathComponent("private-unsent.bin"))
        #expect(throws: (any Error).self) { try transaction.install(prepared) }
        #expect(try Data(contentsOf: fixture.live.appendingPathComponent("private-unsent.bin")) == Data([4]))
    }

    @Test func installationRollbackRestoresEveryOriginalByte() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transaction = try fixture.transaction()
        let prepared = try transaction.prepare(local: fixture.export(), sourceArchive: fixture.archive,
            remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true))
        try transaction.install(prepared)
        try transaction.rollback(prepared)
        #expect(try fixture.readArchive().projects == fixture.archive.projects)
        #expect(try Data(contentsOf: fixture.live.appendingPathComponent("private-unsent.bin")) == Data([1, 2, 3]))
        #expect(!FileManager.default.fileExists(atPath: fixture.live.appendingPathComponent("SyncMetadata/bootstrap-receipt.json").path))
    }

    private struct Fixture {
        let root: URL
        let live: URL
        let archive: ProjectArchive
        let context = SyncBootstrapContext(accountIDHash: String(repeating: "a", count: 64), epoch: UUID(), freezeID: UUID())
        init(completeMedia: Bool = false, empty: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
            live = root.appendingPathComponent("Live")
            try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
            if completeMedia {
                _ = try BackupFixture.writeCompleteArchive(to: live)
                archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: live.appendingPathComponent("projects-v1.json")))
            } else {
                archive = .init(version: 14, projects: empty ? [] : [try StoredProject(name: "Same name")])
                try JSONEncoder().encode(archive).write(to: live.appendingPathComponent("projects-v1.json"))
            }
            try Data([1, 2, 3]).write(to: live.appendingPathComponent("private-unsent.bin"))
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func readArchive() throws -> ProjectArchive { try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: live.appendingPathComponent("projects-v1.json"))) }
        func export() throws -> SyncExportPackage { try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: live, deviceID: "local") }
        func transaction(boundary: @escaping (SyncBootstrapBoundary) throws -> Void = { _ in }) throws -> SyncBootstrapTransaction {
            try .init(liveRoot: live, context: context, journalRelativePath: "SyncMetadata/bootstrap-journal", validateContext: { candidate in
                guard candidate == context else { throw SyncBootstrapError.contextChanged }
            }, boundary: boundary)
        }
    }
}
