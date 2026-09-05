import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

@Suite(.serialized) @MainActor struct SyncDeletedDomainTests {
    @Test func incomingLiveContextMustMatchCurrentArchiveBeforeRetentionChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("incoming-context-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let deletedProject = try StoredProject(name: "Deleted A")
        var liveProject = try StoredProject(name: "Live B")
        let rootID = SyncEntityID(kind: .project, uuid: deletedProject.id)
        let package = try ProjectArchiveSyncMapper.export(archive: .init(version: ProjectArchive.currentVersion,
            projects: [deletedProject]), liveRoot: root, deviceID: "sender")
        let stamp = SyncMutationStamp(logicalRevision: 10, modifiedAt: Date(timeIntervalSince1970: 100), deviceID: "sender")
        let deleted = package.records.map { original -> SyncRecord in
            var record = original
            record.deletedAt = .init(value: stamp.modifiedAt, stamp: stamp)
            if record.id == rootID {
                record.payload.deletionCascade = .init(value: package.records.filter { $0.id != rootID }.map(\.id), stamp: stamp)
            }
            return record
        }
        let before = ProjectArchive(version: ProjectArchive.currentVersion, projects: [liveProject])
        let live = try ProjectArchiveSyncMapper.export(archive: before, liveRoot: root, deviceID: "local")
        let records = deleted + live.records
        let domain = SyncDeletedDomain(rootIDs: [rootID], ownedRecords: deleted,
            supportingParentIDs: [], removedReminders: [:], restorableRecordIDs: Set(deleted.map(\.id)))
        let versions = try deleted.map { try SyncRecordVersion(record: $0) }
        let ledger = try SyncDeletionLedger(root: root.appendingPathComponent("ledger"))
        let id = try ledger.captureIncomingDeleted(domain: domain, exactRemovalVersions: versions,
            attachments: [:], restoreRelativePaths: [:], deletedAt: stamp.modifiedAt,
            currentRecords: records, currentArchive: before, sourceRoots: [root])
        let entries = try ledger.recentlyDeleted()
        let manifest = try Data(contentsOf: ledger.root.appendingPathComponent("ledger.json"))
        let counterID = try #require(liveProject.counters.first?.id)
        let command = WatchCounterCommand(id: UUID(), projectID: liveProject.id, counterID: counterID,
            operation: .increment, createdAt: stamp.modifiedAt)
        let prepared = PreparedWatchCommand(command: command,
            expectedCounterRevision: try #require(liveProject.counters.first?.mutationRevision), expectedCounterValue: 0)
        var watchLedger = ProcessedWatchCommandLedger()
        watchLedger.record(command.id, preparedCommand: prepared, at: stamp.modifiedAt.addingTimeInterval(1))
        #expect(throws: (any Error).self) {
            try ledger.captureIncomingDeleted(domain: domain, exactRemovalVersions: versions,
                attachments: [:], restoreRelativePaths: [:], deletedAt: stamp.modifiedAt,
                currentRecords: records, currentArchive: before, sourceRoots: [root],
                counterReminderContext: .init(processedLedger: watchLedger))
        }
        #expect(try ledger.recentlyDeleted() == entries)
        #expect(try Data(contentsOf: ledger.root.appendingPathComponent("ledger.json")) == manifest)
        _ = liveProject.incrementCounter(id: counterID, now: stamp.modifiedAt.addingTimeInterval(10))
        let current = ProjectArchive(version: ProjectArchive.currentVersion, projects: [liveProject])
        #expect(liveProject.counters.first?.value == 1)
        #expect(throws: (any Error).self) {
            try ledger.captureIncomingDeleted(domain: domain, exactRemovalVersions: versions,
                attachments: [:], restoreRelativePaths: [:], deletedAt: stamp.modifiedAt.addingTimeInterval(50),
                currentRecords: records, currentArchive: current, sourceRoots: [root])
        }
        #expect(try ledger.recentlyDeleted() == entries)
        #expect(try Data(contentsOf: ledger.root.appendingPathComponent("ledger.json")) == manifest)
        #expect(try ledger.recentlyDeleted().first?.id == id)
        let updated = try ProjectArchiveSyncMapper.export(archive: current, liveRoot: root, deviceID: "local")
        #expect(try ledger.captureIncomingDeleted(domain: domain, exactRemovalVersions: versions,
            attachments: [:], restoreRelativePaths: [:], deletedAt: stamp.modifiedAt.addingTimeInterval(50),
            currentRecords: deleted + updated.records, currentArchive: current, sourceRoots: [root]) == id)
        #expect(try ledger.recentlyDeleted().first?.deletedAt == stamp.modifiedAt)
    }

    @Test func incomingMediaRequiresCompleteBoundSourcesAndRejectsRetiredHistorySelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("incoming-media-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try BackupFixture.writeCompleteArchive(to: root)
        let archiveURL = root.appendingPathComponent("projects-v1.json")
        let original = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: archiveURL))
        let package = try ProjectArchiveSyncMapper.export(archive: original, liveRoot: root, deviceID: "sender")
        let stamp = SyncMutationStamp(logicalRevision: 20, modifiedAt: Date(timeIntervalSince1970: 200), deviceID: "sender")
        let deleted = package.records.map { original -> SyncRecord in
            var record = original
            record.deletedAt = .init(value: stamp.modifiedAt, stamp: stamp)
            let children = package.records.filter { item in
                item.relationships.contains { $0.target == record.id && ["project", "owner"].contains($0.role) }
            }.map(\.id)
            if record.id.kind != .attachment && !children.isEmpty {
                record.payload.deletionCascade = .init(value: children, stamp: stamp)
            }
            return record
        }
        let roots = Set(deleted.filter { $0.relationships.isEmpty }.map(\.id))
        let selected = Set(deleted.map(\.id))
        let domain = SyncDeletedDomain(rootIDs: roots, ownedRecords: deleted,
            supportingParentIDs: [], removedReminders: [:], restorableRecordIDs: selected)
        let paths = package.attachments.mapValues { String($0.fileURL.path.dropFirst(root.path.count + 1)) }
        let empty = ProjectArchive(version: ProjectArchive.currentVersion, projects: [])
        try JSONEncoder().encode(empty).write(to: archiveURL)
        let ledger = try SyncDeletionLedger(root: SyncDeletionLedger.root(archiveURL: archiveURL))
        for invalid in ["missing", "hash", "root"] {
            var sources = package.attachments
            let id = try #require(sources.keys.first)
            if invalid == "missing" { sources.removeValue(forKey: id) }
            if invalid == "hash", let source = sources[id] {
                sources[id] = try .init(fileURL: source.fileURL, contentSHA256: Data(repeating: 1, count: 32), byteCount: source.byteCount)
            }
            #expect(throws: (any Error).self) {
                try ledger.captureIncomingDeleted(domain: domain, exactRemovalVersions: deleted.map { try .init(record: $0) },
                    attachments: sources, restoreRelativePaths: paths, deletedAt: stamp.modifiedAt,
                    currentRecords: deleted, currentArchive: empty,
                    sourceRoots: [invalid == "root" ? root.appendingPathComponent("wrong-root") : root])
            }
            #expect(try ledger.recentlyDeleted().isEmpty)
        }
        let originalAttachment = try #require(deleted.first { $0.payload.attachment?.slot.role == "project-photo" })
        let version = try #require(originalAttachment.payload.attachment)
        let retiredVersion = try SyncAttachmentVersion.issuing(slot: version.slot, contentSHA256: version.contentSHA256,
            byteCount: version.byteCount, mediaType: version.mediaType, displayFilename: version.displayFilename)
        let retired = SyncRecord(schemaVersion: originalAttachment.schemaVersion,
            id: .init(kind: .attachment, uuid: retiredVersion.versionID), createdAt: originalAttachment.createdAt,
            entityRevision: originalAttachment.entityRevision,
            payload: .init(fields: originalAttachment.payload.fields, attachment: retiredVersion),
            relationships: originalAttachment.relationships, deletedAt: originalAttachment.deletedAt)
        let retiredRecords = deleted + [retired]
        let corruptSelection = SyncDeletedDomain(rootIDs: roots, ownedRecords: retiredRecords,
            supportingParentIDs: [], removedReminders: [:], restorableRecordIDs: selected.union([retired.id]))
        #expect(throws: (any Error).self) {
            try ledger.captureIncomingDeleted(domain: corruptSelection,
                exactRemovalVersions: retiredRecords.map { try .init(record: $0) }, attachments: package.attachments,
                restoreRelativePaths: paths, deletedAt: stamp.modifiedAt, currentRecords: retiredRecords,
                currentArchive: empty, sourceRoots: [root])
        }
        let id = try ledger.captureIncomingDeleted(domain: domain, exactRemovalVersions: deleted.map { try .init(record: $0) },
            attachments: package.attachments, restoreRelativePaths: paths, deletedAt: stamp.modifiedAt,
            currentRecords: deleted, currentArchive: empty, sourceRoots: [root])
        let entry = try #require(try SyncDeletionLedger(root: ledger.root).recentlyDeleted().first)
        #expect(entry.id == id)
        #expect(entry.files.count == package.attachments.count)
        for proof in entry.files {
            #expect(try Data(contentsOf: ledger.root.appendingPathComponent(proof.retainedRelativePath)) ==
                Data(contentsOf: root.appendingPathComponent(proof.restoreRelativePath)))
        }
    }

    @Test func incomingConcurrentEditPersistsExactDeletedCanonicalAndRestoresAfterReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("incoming-deletion-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try StoredProject(name: "Original")
        let original = ProjectArchive(version: ProjectArchive.currentVersion, projects: [project])
        let package = try ProjectArchiveSyncMapper.export(archive: original, liveRoot: root, deviceID: "sender")
        let stamp = SyncMutationStamp(logicalRevision: 10, modifiedAt: Date(timeIntervalSince1970: 100), deviceID: "sender")
        let rootID = SyncEntityID(kind: .project, uuid: project.id)
        let deleted = package.records.map { original -> SyncRecord in
            var record = original
            record.deletedAt = .init(value: stamp.modifiedAt, stamp: stamp)
            if record.id == rootID {
                record.payload.deletionCascade = .init(value: package.records.filter { $0.id != rootID }.map(\.id), stamp: stamp)
            }
            return record
        }
        let empty = ProjectArchive(version: ProjectArchive.currentVersion, projects: [])
        let archiveURL = root.appendingPathComponent("projects-v1.json")
        try JSONEncoder().encode(empty).write(to: archiveURL)
        let ledgerRoot = SyncDeletionLedger.root(archiveURL: archiveURL)
        let selected = Set(deleted.map(\.id))
        let firstDomain = SyncDeletedDomain(rootIDs: [rootID], ownedRecords: deleted,
            supportingParentIDs: [], removedReminders: [:], restorableRecordIDs: selected)
        let first = try SyncDeletionLedger(root: ledgerRoot).captureIncomingDeleted(domain: firstDomain,
            exactRemovalVersions: deleted.map { try .init(record: $0) }, attachments: [:], restoreRelativePaths: [:],
            deletedAt: stamp.modifiedAt, currentRecords: deleted, currentArchive: empty, sourceRoots: [root])
        var edited = try #require(package.records.first { $0.id == rootID })
        edited.payload.fields["name"] = .init(value: .string("Newest concurrent name"),
            stamp: .init(logicalRevision: 11, modifiedAt: Date(timeIntervalSince1970: 101), deviceID: "editor"))
        let merged = try SyncMergeEngine().merge(local: deleted, remote: [edited], pendingLocal: [])
        let domain = SyncDeletedDomain(rootIDs: [rootID], ownedRecords: merged.records,
            supportingParentIDs: [], removedReminders: [:], restorableRecordIDs: selected)
        let ledger = try SyncDeletionLedger(root: ledgerRoot)
        let repeated = try ledger.captureIncomingDeleted(domain: domain,
            exactRemovalVersions: merged.records.map { try .init(record: $0) }, attachments: [:], restoreRelativePaths: [:],
            deletedAt: stamp.modifiedAt.addingTimeInterval(100), currentRecords: merged.records,
            currentArchive: empty, sourceRoots: [root])
        #expect(repeated == first)
        let entry = try #require(try SyncDeletionLedger(root: ledgerRoot).recentlyDeleted().first)
        #expect(entry.deletedAt == stamp.modifiedAt)
        #expect(Set(entry.domain.ownedRecords.map(\.id)) == selected)
        #expect(entry.domain.ownedRecords.allSatisfy { $0.deletedAt.value != nil })
        #expect(entry.domain.ownedRecords.first { $0.id == rootID } == merged.records.first { $0.id == rootID })
        let replayed = try ledger.captureIncomingDeleted(domain: firstDomain,
            exactRemovalVersions: deleted.map { try .init(record: $0) }, attachments: [:], restoreRelativePaths: [:],
            deletedAt: stamp.modifiedAt, currentRecords: deleted, currentArchive: empty, sourceRoots: [root])
        #expect(replayed == first)
        #expect(try ledger.recentlyDeleted().count == 1)
        #expect(try ledger.recentlyDeleted().first?.domain.ownedRecords.first { $0.id == rootID } ==
            merged.records.first { $0.id == rootID })
        let metadataOnly = SyncDeletedDomain(rootIDs: [rootID],
            ownedRecords: merged.records.filter { $0.id == rootID }, supportingParentIDs: [], removedReminders: [:],
            restorableRecordIDs: [rootID])
        #expect(throws: (any Error).self) {
            try ledger.captureIncomingDeleted(domain: metadataOnly,
                exactRemovalVersions: merged.records.filter { $0.id == rootID }.map { try .init(record: $0) },
                attachments: [:], restoreRelativePaths: [:], deletedAt: stamp.modifiedAt,
                currentRecords: merged.records, currentArchive: empty, sourceRoots: [root])
        }
        #expect(throws: (any Error).self) {
            try ledger.captureIncomingDeleted(domain: domain,
                exactRemovalVersions: deleted.map { try .init(record: $0) }, attachments: [:], restoreRelativePaths: [:],
                deletedAt: stamp.modifiedAt, currentRecords: merged.records, currentArchive: empty, sourceRoots: [root])
        }
        let unrelated = try StoredYarn(name: "Retired unrelated history")
        let otherPackage = try ProjectArchiveSyncMapper.export(archive: .init(version: ProjectArchive.currentVersion,
            projects: [], yarns: [unrelated]), liveRoot: root, deviceID: "other")
        var retired = try #require(otherPackage.records.first)
        retired.deletedAt = .init(value: stamp.modifiedAt, stamp: stamp)
        let unrelatedRecords = merged.records + [retired]
        let unrelatedSelection = SyncDeletedDomain(rootIDs: [rootID], ownedRecords: unrelatedRecords,
            supportingParentIDs: [], removedReminders: [:], restorableRecordIDs: selected.union([retired.id]))
        #expect(throws: (any Error).self) {
            try ledger.captureIncomingDeleted(domain: unrelatedSelection,
                exactRemovalVersions: unrelatedRecords.map { try .init(record: $0) }, attachments: [:], restoreRelativePaths: [:],
                deletedAt: stamp.modifiedAt, currentRecords: unrelatedRecords, currentArchive: empty, sourceRoots: [root])
        }
        #expect(try ledger.recentlyDeleted().first?.id == first)
        let stale = JSONProjectStore(url: archiveURL, syncMutationSink: IncomingDeletionSink())
        let staleStates = Dictionary(uniqueKeysWithValues: deleted.compactMap { record -> (UUID, SyncCounterReminderState)? in
            guard case let .projectCounter(state)? = record.payload.atomicDomain?.value else { return nil }
            return (record.id.uuid, state)
        })
        try stale.hydrateSyncBootstrap(.init(archiveSHA256: Data(SHA256.hash(data: Data(contentsOf: archiveURL))),
            records: deleted, counterStates: staleStates, legacyRecordIDsToDelete: []))
        #expect(throws: (any Error).self) {
            try stale.restoreRecentlyDeleted(id: first, now: stamp.modifiedAt.addingTimeInterval(29 * 24 * 60 * 60))
        }
        #expect(try ledger.recentlyDeleted().first?.id == first)
        let store = JSONProjectStore(url: archiveURL, syncMutationSink: IncomingDeletionSink())
        var newestEdit = edited
        newestEdit.payload.fields["name"] = .init(value: .string("Newer hydrated name"),
            stamp: .init(logicalRevision: 12, modifiedAt: Date(timeIntervalSince1970: 102), deviceID: "editor"))
        let newest = try SyncMergeEngine().merge(local: merged.records, remote: [newestEdit], pendingLocal: []).records
        let states = Dictionary(uniqueKeysWithValues: newest.compactMap { record -> (UUID, SyncCounterReminderState)? in
            guard case let .projectCounter(state)? = record.payload.atomicDomain?.value else { return nil }
            return (record.id.uuid, state)
        })
        try store.hydrateSyncBootstrap(.init(archiveSHA256: Data(SHA256.hash(data: Data(contentsOf: archiveURL))),
            records: newest, counterStates: states, legacyRecordIDsToDelete: []))
        try store.restoreRecentlyDeleted(id: first, now: stamp.modifiedAt.addingTimeInterval(29 * 24 * 60 * 60))
        #expect(store.project(id: project.id)?.name == "Newer hydrated name")
        #expect(store.project(id: project.id)?.counters == project.counters)
    }
}

private struct IncomingDeletionSink: SyncMutationSink {
    func publish(_ mutation: SyncMutation) throws {}
}
