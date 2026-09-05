import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

struct SyncDeletionLedgerTests {
    @Test(arguments: ["intent", "unlink", "complete"]) func purgeIsDurableAndReplaysOnlyExactOwnedPaths(boundary: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try attachmentFixture(root)
        let ledger = try SyncDeletionLedger(root: root.appendingPathComponent("ledger"))
        let date = Date(timeIntervalSince1970: 100)
        let id = try ledger.stage(domain: fixture.domain, attachments: fixture.sources, restoreRelativePaths: fixture.paths, deletedAt: date)
        let versions = try removalVersions(fixture.domain)
        let witness = Data(repeating: 3, count: 32)
        try ledger.prepare(id: id, beforeArchiveSHA256: Data(repeating: 1, count: 32),
            afterArchiveSHA256: Data(repeating: 2, count: 32), exactRemovalVersions: versions, publicationSHA256: witness)
        try ledger.activate(id: id, publicationSHA256: witness)
        let entry = try #require(ledger.recentlyDeleted().first)
        let unrelated = ledger.root.appendingPathComponent("do-not-own.bin")
        try Data("unrelated".utf8).write(to: unrelated)
        let refs = SyncDeletionReferences(acknowledgedRemovalVersionIDs: Set(versions.map(\.versionID)))
        let file = try #require(entry.files.first)
        for protected in [
            SyncDeletionReferences(acknowledgedRemovalVersionIDs: refs.acknowledgedRemovalVersionIDs,
                protectedRecordIDs: [fixture.domain.ownedRecords.first!.id]),
            SyncDeletionReferences(acknowledgedRemovalVersionIDs: refs.acknowledgedRemovalVersionIDs,
                protectedAttachmentVersionIDs: [file.attachmentVersionID]),
            SyncDeletionReferences(acknowledgedRemovalVersionIDs: refs.acknowledgedRemovalVersionIDs,
                protectedLedgerRelativePaths: [file.retainedRelativePath]),
            SyncDeletionReferences(acknowledgedRemovalVersionIDs: [UUID()])
        ] {
            try ledger.purge(now: date.addingTimeInterval(2592000), references: protected)
            #expect(try ledger.recentlyDeleted().map(\.id) == [id])
            #expect(try ledger.deletionMarkers().isEmpty)
            #expect(FileManager.default.fileExists(atPath: ledger.root.appendingPathComponent(file.retainedRelativePath).path))
        }
        do {
            try ledger.purge(now: date.addingTimeInterval(2592000), references: refs,
                afterIntent: { if boundary == "intent" { throw SyncDeletionLedgerError.unavailable } },
                afterUnlink: { if boundary == "unlink" { throw SyncDeletionLedgerError.unavailable } })
            #expect(boundary == "complete")
        } catch { #expect(boundary != "complete") }
        if boundary == "intent" {
            let manifestURL = ledger.root.appendingPathComponent("ledger.json")
            let original = try Data(contentsOf: manifestURL)
            var envelope = try JSONSerialization.jsonObject(with: original) as! [String: Any]
            var payload = try JSONSerialization.jsonObject(with: Data(base64Encoded: envelope["payload"] as! String)!) as! [String: Any]
            var pending = payload["pendingMarkerVersions"] as! [[String: Any]]
            pending[0]["versionID"] = UUID().uuidString
            payload["pendingMarkerVersions"] = pending
            let bytes = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
            envelope["payload"] = bytes.base64EncodedString()
            envelope["sha256"] = Data(SHA256.hash(data: bytes)).base64EncodedString()
            try JSONSerialization.data(withJSONObject: envelope).write(to: manifestURL)
            #expect(throws: (any Error).self) { try SyncDeletionLedger(root: ledger.root) }
            #expect(entry.files.allSatisfy { FileManager.default.fileExists(atPath: ledger.root.appendingPathComponent($0.retainedRelativePath).path) })
            try original.write(to: manifestURL)
        }
        let reopened = try SyncDeletionLedger(root: ledger.root)
        #expect(try reopened.recentlyDeleted().isEmpty)
        #expect(try reopened.deletionMarkers().count >= fixture.domain.ownedRecords.count)
        #expect(try !reopened.pendingDeletionMarkerVersions().isEmpty)
        #expect(entry.files.allSatisfy { !FileManager.default.fileExists(atPath: ledger.root.appendingPathComponent($0.retainedRelativePath).path) })
        #expect(try Data(contentsOf: unrelated) == Data("unrelated".utf8))
        #expect(try fixture.sources.values.allSatisfy { try Data(contentsOf: $0.fileURL).count > 0 })
        let envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: ledger.root.appendingPathComponent("ledger.json"))) as! [String: Any]
        let payload = String(decoding: Data(base64Encoded: envelope["payload"] as! String)!, as: UTF8.self)
        #expect(!payload.contains("Retained project"))
        #expect(!payload.contains("retainedRelativePath"))
        #expect(!payload.contains("contentSHA256"))
        #expect(throws: (any Error).self) {
            try reopened.stage(domain: fixture.domain, attachments: fixture.sources,
                restoreRelativePaths: fixture.paths, deletedAt: .now)
        }
    }

    @Test func initializationPreservesLedgerPublishedAfterRootExistenceCheck() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = try makeDomain()
        let versions = try removalVersions(domain)
        let before = Data(repeating: 1, count: 32)
        let after = Data(repeating: 2, count: 32)
        let witness = Data(repeating: 3, count: 32)
        var ids: [UUID] = []
        let resumed = try SyncDeletionLedger(root: root, afterRootExistenceCheck: {
            // This nested handle installs the same durable authority another
            // process can publish while the first initializer is suspended.
            let publisher = try SyncDeletionLedger(root: root)
            for state in 0..<3 {
                let id = try publisher.stage(domain: domain, attachments: [:], restoreRelativePaths: [:], deletedAt: .now)
                ids.append(id)
                if state > 0 {
                    try publisher.prepare(id: id, beforeArchiveSHA256: before, afterArchiveSHA256: after,
                        exactRemovalVersions: versions, publicationSHA256: witness)
                }
                if state > 1 { try publisher.activate(id: id, publicationSHA256: witness) }
            }
        })
        #expect(try resumed.recentlyDeleted().map(\.id) == [ids[2]])
        try resumed.activate(id: ids[1], publicationSHA256: witness)
        try resumed.prepare(id: ids[0], beforeArchiveSHA256: before, afterArchiveSHA256: after,
            exactRemovalVersions: versions, publicationSHA256: witness)
        try resumed.activate(id: ids[0], publicationSHA256: witness)
        #expect(try Set(SyncDeletionLedger(root: root).recentlyDeleted().map(\.id)) == Set(ids))
    }

    @Test(arguments: [false, true]) func initializationDoesNotReplaceDamagedExistingLedger(missingManifest: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = root.appendingPathComponent("ledger.json")
        let corrupt = Data("damaged existing authority".utf8)
        if !missingManifest { try corrupt.write(to: manifest) }
        #expect(throws: (any Error).self) { _ = try SyncDeletionLedger(root: root) }
        if missingManifest {
            #expect(!FileManager.default.fileExists(atPath: manifest.path))
        } else {
            #expect(try Data(contentsOf: manifest) == corrupt)
        }
    }

    @Test(arguments: [0, 1, 2, 3]) func exactRemovalProofSetIsCheckedOnPrepareAndReload(variant: Int) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try SyncDeletionLedger(root: root)
        let domain = try makeDomain()
        let id = try ledger.stage(domain: domain, attachments: [:], restoreRelativePaths: [:], deletedAt: .now)
        let correct = try removalVersions(domain)
        var invalid = correct
        switch variant {
        case 0: invalid.removeLast()
        case 1: invalid.append(try removalVersions(makeDomain())[0])
        case 2: invalid[0] = try SyncRecordVersion(record: domain.ownedRecords[0])
        default: invalid.append(invalid[0])
        }
        #expect(throws: (any Error).self) {
            try ledger.prepare(id: id, beforeArchiveSHA256: Data(repeating: 1, count: 32),
                afterArchiveSHA256: Data(repeating: 2, count: 32), exactRemovalVersions: invalid,
                publicationSHA256: Data(repeating: 3, count: 32))
        }
        try ledger.prepare(id: id, beforeArchiveSHA256: Data(repeating: 1, count: 32),
            afterArchiveSHA256: Data(repeating: 2, count: 32), exactRemovalVersions: correct,
            publicationSHA256: Data(repeating: 3, count: 32))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(invalid))
        try rewriteFirstGroup(root) { group in
            var entry = group["entry"] as! [String: Any]
            entry["exactRemovalVersions"] = encoded
            group["entry"] = entry
        }
        #expect(throws: (any Error).self) { _ = try SyncDeletionLedger(root: root) }
    }

    @Test(arguments: [0, 1, 2]) func fileProofTamperingFailsBeforePreparation(variant: Int) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try attachmentFixture(root)
        let ledger = try SyncDeletionLedger(root: root.appendingPathComponent("ledger"))
        let id = try ledger.stage(domain: fixture.domain, attachments: fixture.sources,
            restoreRelativePaths: fixture.paths, deletedAt: .now)
        try rewriteFirstGroup(ledger.root) { group in
            var entry = group["entry"] as! [String: Any]
            var files = entry["files"] as! [[String: Any]]
            switch variant {
            case 0: files.removeLast()
            case 1: files.append(files[0])
            default: files[0]["sha256"] = Data(repeating: 8, count: 32).base64EncodedString()
            }
            entry["files"] = files
            group["entry"] = entry
        }
        #expect(throws: (any Error).self) {
            try ledger.prepare(id: id, beforeArchiveSHA256: Data(repeating: 1, count: 32),
                afterArchiveSHA256: Data(repeating: 2, count: 32), exactRemovalVersions: removalVersions(fixture.domain),
                publicationSHA256: Data(repeating: 3, count: 32))
        }
        #expect(throws: (any Error).self) { _ = try SyncDeletionLedger(root: ledger.root) }
    }

    @Test func oversizedSourceAndCorruptManifestFailClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try attachmentFixture(root)
        let source = fixture.sources.values.first!.fileURL
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 100_000_001)
        try handle.close()
        let ledger = try SyncDeletionLedger(root: root.appendingPathComponent("ledger"))
        #expect(throws: (any Error).self) {
            _ = try ledger.stage(domain: fixture.domain, attachments: fixture.sources,
                restoreRelativePaths: fixture.paths, deletedAt: .now)
        }
        try Data("corrupt".utf8).write(to: ledger.root.appendingPathComponent("ledger.json"))
        #expect(throws: (any Error).self) { _ = try SyncDeletionLedger(root: ledger.root) }
    }

    @Test func realWitnessPendingRepairActivationAndReplay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try SyncDeletionLedger(root: root)
        let domain = try makeDomain()
        let id = try ledger.stage(domain: domain, attachments: [:], restoreRelativePaths: [:], deletedAt: .now)
        let versions = try removalVersions(domain)
        let after = Data(repeating: 2, count: 32)
        let transaction = try SyncPublicationTransaction.legacy(expectedArchiveSHA256: after,
            mutations: versions.map { try .save(recordVersion: $0, mutationID: UUID()) })
        let wrong = try SyncPublicationTransaction.legacy(expectedArchiveSHA256: after,
            mutations: versions.map { try .save(recordVersion: $0, mutationID: UUID()) })
        try ledger.prepare(id: id, beforeArchiveSHA256: Data(repeating: 1, count: 32), afterArchiveSHA256: after,
            exactRemovalVersions: versions, publicationSHA256: SyncDeletionLedger.publicationFingerprint(transaction))
        #expect(throws: (any Error).self) { try ledger.recover(archiveSHA256: after, publication: wrong) }
        try ledger.recover(archiveSHA256: after, publication: transaction)
        #expect(try ledger.recentlyDeleted().isEmpty)
        try ledger.activate(publication: transaction)
        try ledger.activate(publication: transaction)
        let reopened = try SyncDeletionLedger(root: root)
        try reopened.recover(archiveSHA256: after, publication: nil)
        #expect(try reopened.recentlyDeleted().count == 1)
        // Once activated, a different publication without this group's claim
        // is independent even when it observes the same archive bytes.
        try reopened.recover(archiveSHA256: after, publication: wrong)
        #expect(try reopened.recentlyDeleted().count == 1)
    }

    @Test(arguments: [0, 1, 2]) func refusesMalformedReminderSelections(variant: Int) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = SyncEntityID(kind: .projectCounter, uuid: UUID())
        let reminder = KnittingReminder(counterID: variant == 0 ? UUID() : parent.uuid,
            draft: .oneTime(kind: .increase, target: 10, text: "text"), createdAt: .now)!
        let reminders = variant == 2 ? [] : (variant == 1 ? [reminder, reminder] : [reminder])
        let domain = SyncDeletedDomain(rootIDs: [parent], ownedRecords: [],
            supportingParentIDs: [parent], removedReminders: [parent.uuid: reminders])
        let ledger = try SyncDeletionLedger(root: root)
        #expect(throws: (any Error).self) {
            _ = try ledger.stage(domain: domain, attachments: [:], restoreRelativePaths: [:], deletedAt: .now)
        }
    }

    @Test func refusesNulRestorePathAndSymlinkAncestor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try attachmentFixture(root.appendingPathComponent("sources"))
        let ledger = try SyncDeletionLedger(root: root.appendingPathComponent("ledger"))
        #expect(throws: (any Error).self) {
            _ = try ledger.stage(domain: fixture.domain, attachments: fixture.sources,
                restoreRelativePaths: fixture.paths.mapValues { _ in "photos/a\0.jpg" }, deletedAt: .now)
        }
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("sources"))
        let sources = try fixture.sources.mapValues {
            try SyncAttachmentSource(fileURL: alias.appendingPathComponent($0.fileURL.lastPathComponent),
                contentSHA256: $0.contentSHA256, byteCount: $0.byteCount)
        }
        #expect(throws: (any Error).self) {
            _ = try ledger.stage(domain: fixture.domain, attachments: sources,
                restoreRelativePaths: fixture.paths, deletedAt: .now)
        }
    }

    @Test func concurrentHeadsSurviveSourceReplacementAndRequireCompleteReloadProofs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try attachmentFixture(root)
        let ledger = try SyncDeletionLedger(root: root.appendingPathComponent("ledger"))
        var missing = fixture.sources
        missing.removeValue(forKey: missing.keys.first!)
        #expect(throws: (any Error).self) {
            _ = try ledger.stage(domain: fixture.domain, attachments: missing,
                restoreRelativePaths: fixture.paths, deletedAt: .now)
        }
        let id = try ledger.stage(domain: fixture.domain, attachments: fixture.sources,
            restoreRelativePaths: fixture.paths, deletedAt: .now)
        for source in fixture.sources.values { try Data("replacement".utf8).write(to: source.fileURL) }
        try ledger.prepare(id: id, beforeArchiveSHA256: Data(repeating: 1, count: 32),
            afterArchiveSHA256: Data(repeating: 2, count: 32), exactRemovalVersions: removalVersions(fixture.domain),
            publicationSHA256: Data(repeating: 3, count: 32))
        try ledger.activate(id: id, publicationSHA256: Data(repeating: 3, count: 32))
        let reopened = try SyncDeletionLedger(root: ledger.root)
        let entry = try #require(reopened.recentlyDeleted().first)
        #expect(entry.files.count == 2)
        #expect(entry.domain.ownedRecords.filter { $0.payload.attachment != nil }.count == 3)
        for proof in entry.files {
            #expect(try Data(contentsOf: ledger.root.appendingPathComponent(proof.retainedRelativePath)) == Data([42]))
        }
        try rewriteFirstGroup(ledger.root) { group in
            var entry = group["entry"] as! [String: Any]
            var files = entry["files"] as! [[String: Any]]
            files.removeLast()
            entry["files"] = files
            group["entry"] = entry
        }
        #expect(throws: (any Error).self) { _ = try SyncDeletionLedger(root: ledger.root) }
    }

    @Test(arguments: [false, true]) func refusesLinkedSources(hardLink: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try attachmentFixture(root)
        let source = fixture.sources.values.first!.fileURL
        let other = root.appendingPathComponent("other")
        if hardLink {
            try FileManager.default.linkItem(at: source, to: other)
        } else {
            try FileManager.default.moveItem(at: source, to: other)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: other)
        }
        let ledger = try SyncDeletionLedger(root: root.appendingPathComponent("ledger"))
        #expect(throws: (any Error).self) {
            _ = try ledger.stage(domain: fixture.domain, attachments: fixture.sources,
                restoreRelativePaths: fixture.paths, deletedAt: .now)
        }
        #expect(try ledger.recentlyDeleted().isEmpty)
    }

    @Test func cooperatingHandlesDoNotLoseStagedGroups() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try SyncDeletionLedger(root: root)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    let ledger = try SyncDeletionLedger(root: root)
                    let domain = try makeDomain()
                    let id = try ledger.stage(domain: domain, attachments: [:], restoreRelativePaths: [:], deletedAt: .now)
                    try ledger.prepare(id: id, beforeArchiveSHA256: Data(repeating: 1, count: 32),
                        afterArchiveSHA256: Data(repeating: 2, count: 32), exactRemovalVersions: removalVersions(domain),
                        publicationSHA256: Data(repeating: 3, count: 32))
                    try ledger.activate(id: id, publicationSHA256: Data(repeating: 3, count: 32))
                }
            }
            try await group.waitForAll()
        }
        #expect(try SyncDeletionLedger(root: root).recentlyDeleted().count == 24)
    }

    @Test func reminderAggregateCannotBeATombstone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeDomain()
        let counter = source.ownedRecords.first { $0.id.kind == .projectCounter }!
        let reminder = KnittingReminder(counterID: counter.id.uuid,
            draft: .oneTime(kind: .increase, target: 10, text: "Keep exact text"), createdAt: .now)!
        let domain = SyncDeletedDomain(rootIDs: [counter.id], ownedRecords: [],
            supportingParentIDs: [counter.id], removedReminders: [counter.id.uuid: [reminder]])
        let ledger = try SyncDeletionLedger(root: root)
        let id = try ledger.stage(domain: domain, attachments: [:], restoreRelativePaths: [:], deletedAt: .now)
        let deletedCounter = try removalVersions(source).first { $0.record.id == counter.id }!
        #expect(throws: (any Error).self) {
            try ledger.prepare(id: id, beforeArchiveSHA256: Data(repeating: 1, count: 32),
                afterArchiveSHA256: Data(repeating: 2, count: 32), exactRemovalVersions: [deletedCounter],
                publicationSHA256: Data(repeating: 3, count: 32))
        }
        try ledger.prepare(id: id, beforeArchiveSHA256: Data(repeating: 1, count: 32),
            afterArchiveSHA256: Data(repeating: 2, count: 32), exactRemovalVersions: [SyncRecordVersion(record: counter)],
            publicationSHA256: Data(repeating: 3, count: 32))
        try ledger.activate(id: id, publicationSHA256: Data(repeating: 3, count: 32))
        #expect(try SyncDeletionLedger(root: root).recentlyDeleted().first?.domain.removedReminders[counter.id.uuid] == [reminder])
    }

    private func attachmentFixture(_ root: URL) throws -> (domain: SyncDeletedDomain, sources: [UUID: SyncAttachmentSource], paths: [UUID: String]) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = try makeDomain()
        let owner = original.rootIDs.first!
        let slot = SyncAttachmentSlot(owner: owner, role: "project-photo", slotID: "cover")
        let bytes = Data([42])
        let hash = Data(SHA256.hash(data: bytes))
        let ancestor = UUID()
        var records = original.ownedRecords
        var sources: [UUID: SyncAttachmentSource] = [:]
        var paths: [UUID: String] = [:]
        for id in [ancestor, UUID(), UUID()] {
            let version = try SyncAttachmentVersion(slot: slot, versionID: id,
                conflictGroupID: SyncAttachmentVersion.conflictGroupID(for: slot),
                contentSHA256: hash, byteCount: 1, mediaType: "image/jpeg", displayFilename: "cover.jpg",
                replacesVersionID: id == ancestor ? nil : ancestor)
            records.append(.init(schemaVersion: 1, id: .init(kind: .attachment, uuid: id),
                createdAt: Date(timeIntervalSince1970: 0), entityRevision: 1,
                payload: .init(fields: [:], attachment: version), relationships: [.init(role: "owner", target: owner)],
                deletedAt: .init(value: nil, stamp: .init(logicalRevision: 1,
                    modifiedAt: Date(timeIntervalSince1970: 1), deviceID: "fixture"))))
            if id != ancestor {
                let file = root.appendingPathComponent(id.uuidString)
                try bytes.write(to: file)
                sources[id] = try .init(fileURL: file, contentSHA256: hash, byteCount: 1)
                paths[id] = "photos/cover.jpg"
            }
        }
        return (.init(rootIDs: original.rootIDs, ownedRecords: records,
            supportingParentIDs: [], removedReminders: [:]), sources, paths)
    }

    @Test func reloadRejectsValidChecksumWithMissingRemovalProofs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try SyncDeletionLedger(root: root)
        let domain = try makeDomain()
        let id = try ledger.stage(domain: domain, attachments: [:], restoreRelativePaths: [:], deletedAt: .now)
        try ledger.prepare(id: id, beforeArchiveSHA256: Data(repeating: 1, count: 32),
            afterArchiveSHA256: Data(repeating: 2, count: 32), exactRemovalVersions: removalVersions(domain),
            publicationSHA256: Data(repeating: 3, count: 32))
        try rewriteFirstGroup(root) { group in
            var entry = group["entry"] as! [String: Any]
            entry["exactRemovalVersions"] = []
            group["entry"] = entry
        }
        #expect(throws: (any Error).self) { _ = try SyncDeletionLedger(root: root) }
    }

    @Test func prepareRejectsTombstoneForDifferentRetainedContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try SyncDeletionLedger(root: root)
        let domain = try makeDomain()
        let id = try ledger.stage(domain: domain, attachments: [:], restoreRelativePaths: [:], deletedAt: .now)
        var versions = try removalVersions(domain)
        let index = versions.firstIndex { $0.record.id.kind == .project }!
        var record = versions[index].record
        record.payload.fields["name"] = .init(value: .string("different retained project"),
            stamp: record.payload.fields["name"]!.stamp)
        versions[index] = try SyncRecordVersion(record: record)
        #expect(throws: (any Error).self) {
            try ledger.prepare(id: id, beforeArchiveSHA256: Data(repeating: 1, count: 32),
                afterArchiveSHA256: Data(repeating: 2, count: 32), exactRemovalVersions: versions,
                publicationSHA256: Data(repeating: 3, count: 32))
        }
    }

    @Test func legacyRemovalUsesLiveProjectAggregateProof() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try SyncDeletionLedger(root: root)
        let project = try StoredProject(name: "Supporting project")
        let parent = SyncEntityID(kind: .project, uuid: project.id)
        let pattern = PatternDocument(displayName: "Removed", kind: .pdf, storedFilename: "removed.pdf")
        let domain = SyncDeletedDomain(rootIDs: [.init(kind: .pattern, uuid: pattern.id)],
            ownedRecords: [], supportingParentIDs: [parent], removedReminders: [:],
            removedLegacyPatterns: [project.id: [pattern]])
        let id = try ledger.stage(domain: domain, attachments: [:], restoreRelativePaths: [:], deletedAt: .now)
        let records = try SyncCanonicalPublicationSnapshot(archive: .init(version: ProjectArchive.currentVersion,
            projects: [project]), deviceID: "fixture").records
        let version = try SyncRecordVersion(record: records[parent]!)
        try ledger.prepare(id: id, beforeArchiveSHA256: Data(repeating: 1, count: 32),
            afterArchiveSHA256: Data(repeating: 2, count: 32), exactRemovalVersions: [version],
            publicationSHA256: Data(repeating: 3, count: 32))
        try ledger.activate(id: id, publicationSHA256: Data(repeating: 3, count: 32))
        #expect(try SyncDeletionLedger(root: root).recentlyDeleted().first?.domain.removedLegacyPatterns[project.id]?.first?.id == pattern.id)
    }

    @Test func realPublicationRejectsUnrelatedVersionsBeforeActivation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try SyncDeletionLedger(root: root)
        let domain = try makeDomain()
        let id = try ledger.stage(domain: domain, attachments: [:], restoreRelativePaths: [:], deletedAt: .now)
        let after = Data(repeating: 2, count: 32)
        let unrelated = try removalVersions(makeDomain()).map {
            try SyncMutation.save(recordVersion: $0, mutationID: UUID())
        }
        let publication = try SyncPublicationTransaction.legacy(expectedArchiveSHA256: after, mutations: unrelated)
        try ledger.prepare(id: id, beforeArchiveSHA256: Data(repeating: 1, count: 32), afterArchiveSHA256: after,
            exactRemovalVersions: removalVersions(domain), publicationSHA256: SyncDeletionLedger.publicationFingerprint(publication))
        #expect(throws: (any Error).self) { try ledger.recover(archiveSHA256: after, publication: publication) }
        #expect(throws: (any Error).self) { try ledger.activate(publication: publication) }
        #expect(try ledger.recentlyDeleted().isEmpty)
    }

    private func rewriteFirstGroup(_ root: URL, edit: (inout [String: Any]) -> Void) throws {
        let file = root.appendingPathComponent("ledger.json")
        var envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let payload = Data(base64Encoded: envelope["payload"] as! String)!
        var manifest = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        var groups = manifest["groups"] as! [[String: Any]]
        edit(&groups[0])
        manifest["groups"] = groups
        let amended = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        envelope["payload"] = amended.base64EncodedString()
        envelope["sha256"] = Data(SHA256.hash(data: amended)).base64EncodedString()
        try JSONSerialization.data(withJSONObject: envelope).write(to: file)
    }

    @Test func activationRequiresExactWitnessAndSurvivesRecreation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try SyncDeletionLedger(root: root)
        let domain = try makeDomain()
        let id = try ledger.stage(domain: domain, attachments: [:], restoreRelativePaths: [:], deletedAt: .now)
        let versions = try removalVersions(domain)
        let before = Data(repeating: 1, count: 32)
        let after = Data(repeating: 2, count: 32)
        let witness = Data(repeating: 3, count: 32)
        try ledger.prepare(id: id, beforeArchiveSHA256: before, afterArchiveSHA256: after,
            exactRemovalVersions: versions, publicationSHA256: witness)
        #expect(try ledger.recentlyDeleted().isEmpty)
        #expect(throws: (any Error).self) { try ledger.activate(id: id, publicationSHA256: before) }
        try ledger.activate(id: id, publicationSHA256: witness)
        let entries = try SyncDeletionLedger(root: root).recentlyDeleted()
        #expect(entries.count == 1)
        #expect(entries.first?.id == id)
        #expect(entries.first?.exactRemovalVersions == versions)
    }

    @Test func uncommittedPreparationNeverBecomesVisible() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try SyncDeletionLedger(root: root)
        let domain = try makeDomain()
        let id = try ledger.stage(domain: domain, attachments: [:], restoreRelativePaths: [:], deletedAt: .now)
        let before = Data(repeating: 1, count: 32)
        try ledger.prepare(id: id, beforeArchiveSHA256: before,
            afterArchiveSHA256: Data(repeating: 2, count: 32),
            exactRemovalVersions: removalVersions(domain), publicationSHA256: Data(repeating: 3, count: 32))
        try ledger.recover(archiveSHA256: before, publication: nil)
        #expect(try ledger.recentlyDeleted().isEmpty)
        #expect(throws: (any Error).self) {
            try ledger.activate(id: id, publicationSHA256: Data(repeating: 3, count: 32))
        }
    }

    @Test func committedPreparationWithoutPublicationFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try SyncDeletionLedger(root: root)
        let domain = try makeDomain()
        let id = try ledger.stage(domain: domain, attachments: [:], restoreRelativePaths: [:], deletedAt: .now)
        let after = Data(repeating: 2, count: 32)
        try ledger.prepare(id: id, beforeArchiveSHA256: Data(repeating: 1, count: 32), afterArchiveSHA256: after,
            exactRemovalVersions: removalVersions(domain), publicationSHA256: Data(repeating: 3, count: 32))
        #expect(throws: (any Error).self) { try ledger.recover(archiveSHA256: after, publication: nil) }
        #expect(try ledger.recentlyDeleted().isEmpty)
    }

    @Test func newLedgerStartsEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try SyncDeletionLedger(root: root)
        #expect(try ledger.recentlyDeleted().isEmpty)
    }

    @Test func stagedDeletionIsInvisibleAcrossRecreation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try SyncDeletionLedger(root: root)
        let project = try StoredProject(name: "Retained project")
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [project])
        let records = try SyncCanonicalPublicationSnapshot(archive: archive, deviceID: "fixture").records
        let domain = SyncDeletedDomain(rootIDs: [.init(kind: .project, uuid: project.id)],
            ownedRecords: Array(records.values), supportingParentIDs: [], removedReminders: [:])
        _ = try ledger.stage(domain: domain, attachments: [:], restoreRelativePaths: [:], deletedAt: .now)
        #expect(try SyncDeletionLedger(root: root).recentlyDeleted().isEmpty)
    }

    private func makeDomain() throws -> SyncDeletedDomain {
        let project = try StoredProject(name: "Retained project")
        let records = try SyncCanonicalPublicationSnapshot(
            archive: .init(version: ProjectArchive.currentVersion, projects: [project]), deviceID: "fixture").records
        return .init(rootIDs: [.init(kind: .project, uuid: project.id)],
            ownedRecords: Array(records.values), supportingParentIDs: [], removedReminders: [:])
    }

    private func removalVersions(_ domain: SyncDeletedDomain) throws -> [SyncRecordVersion] {
        try domain.ownedRecords.map { record in
            var deleted = record
            deleted.deletedAt = .init(value: Date(timeIntervalSince1970: 100),
                stamp: .init(logicalRevision: 100, modifiedAt: Date(timeIntervalSince1970: 100), deviceID: "fixture"))
            return try SyncRecordVersion(record: deleted)
        }
    }
}
