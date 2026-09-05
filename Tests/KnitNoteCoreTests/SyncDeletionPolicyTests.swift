import Foundation
import Testing
@testable import KnitNoteCore

struct SyncDeletionPolicyTests {
    @Test func malformedFileProofCannotAuthorizePurge() throws {
        let original = try fixture()
        let entry = SyncDeletionEntry(id: original.id, deletedAt: original.deletedAt, domain: original.domain,
            exactRemovalVersions: original.exactRemovalVersions, files: [.init(attachmentVersionID: UUID(),
                restoreRelativePath: "../outside", retainedRelativePath: "other-account/file", byteCount: -1, sha256: Data())])
        #expect(SyncDeletionPolicy.evaluate(now: entry.deletedAt.addingTimeInterval(2592000), records: [entry],
            references: .init(acknowledgedRemovalVersionIDs: Set(entry.exactRemovalVersions.map(\.versionID)))).eligibleEntryIDs.isEmpty)
    }

    @Test(arguments: ["local", "remote", "pending", "transport"]) func purgedReminderRejectsWholeAtomicAggregate(source: String) throws {
        let entry = try fixture()
        var counter = entry.domain.ownedRecords.first { $0.id.kind == .projectCounter }!
        guard case let .projectCounter(state)? = counter.payload.atomicDomain?.value else { Issue.record("Missing aggregate"); return }
        let reminder = KnittingReminder(counterID: counter.id.uuid,
            draft: .oneTime(kind: .increase, target: 10, text: "removed reminder"), createdAt: .now)!
        let marker = DeletionMarker(targetID: .init(kind: .knittingReminder, uuid: reminder.id),
            aggregateParentID: counter.id, removalStamp: entry.exactRemovalVersions.first!.record.deletedAt.stamp,
            removalVersionID: try SyncRecordVersion(record: counter).versionID)
        counter.payload.atomicDomain = .init(value: .projectCounter(.init(counter: state.counter,
            reminders: [reminder], preparedCommand: state.preparedCommand, processedCommandIDs: state.processedCommandIDs,
            processedCommandProofs: state.processedCommandProofs, occurrence: state.occurrence)), stamp: counter.payload.atomicDomain!.stamp)
        let mutation = try SyncMutation.save(recordVersion: .init(record: counter), mutationID: UUID())
        if source == "pending" {
            #expect(throws: SyncMergeError.permanentlyDeleted(counter.id)) {
                try SyncMergeEngine().merge(local: [], remote: [], pendingLocalMutations: [mutation], deletionMarkers: [marker])
            }
        } else {
            #expect(throws: SyncMergeError.permanentlyDeleted(counter.id)) {
                try SyncMergeEngine().merge(local: source == "local" ? [counter] : [],
                    remote: source == "transport" ? [counter, try marker.record()] : source == "remote" ? [counter] : [],
                    pendingLocal: [], deletionMarkers: source == "transport" ? [] : [marker])
            }
        }
        #expect(counter.payload.atomicDomain?.value == mutation.savedRecordVersion?.record.payload.atomicDomain?.value)
    }

    @Test func purgedParentRejectsNewDescendantUUID() throws {
        let entry = try fixture()
        let parent = entry.domain.rootIDs.first!
        let child = entry.domain.ownedRecords.first { $0.id.kind == .projectCounter }!
        let proof = entry.exactRemovalVersions.first { $0.record.id == parent }!
        let marker = DeletionMarker(targetID: parent, removalStamp: proof.record.deletedAt.stamp, removalVersionID: proof.versionID)
        #expect(throws: SyncMergeError.permanentlyDeleted(child.id)) {
            try SyncMergeEngine().merge(local: [], remote: [child], pendingLocal: [], deletionMarkers: [marker])
        }
    }

    @Test func frozenDeleteCannotErasePermanentMarker() throws {
        let entry = try fixture()
        let proof = entry.exactRemovalVersions.first!
        let marker = DeletionMarker(targetID: proof.record.id, removalStamp: proof.record.deletedAt.stamp, removalVersionID: proof.versionID)
        #expect(throws: SyncMergeError.permanentlyDeleted(marker.id)) {
            try SyncMergeEngine().merge(local: [try marker.record()], remote: [],
                pendingLocalMutations: [.delete(marker.id, mutationID: UUID())])
        }
    }

    @Test func purgedLegacyPatternRejectsEmbeddedProjectSnapshot() throws {
        let entry = try fixture()
        var project = entry.domain.ownedRecords.first { $0.id.kind == .project }!
        let pattern = PatternDocument(displayName: "Purged private pattern", kind: .pdf, storedFilename: "private.pdf")
        let stamp = entry.exactRemovalVersions.first!.record.deletedAt.stamp
        guard case let .data(bytes)? = project.payload.fields["domainSnapshot"]?.value else { Issue.record("Missing snapshot"); return }
        var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        object["legacyPatterns"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([pattern]))
        project.payload.fields["domainSnapshot"] = .init(value: .data(try JSONSerialization.data(withJSONObject: object)), stamp: stamp)
        let marker = DeletionMarker(targetID: .init(kind: .pattern, uuid: pattern.id), aggregateParentID: project.id,
            removalStamp: stamp, removalVersionID: entry.exactRemovalVersions.first!.versionID)
        #expect(throws: SyncMergeError.permanentlyDeleted(project.id)) {
            try SyncMergeEngine().merge(local: [], remote: [project], pendingLocal: [], deletionMarkers: [marker])
        }
    }

    @Test(arguments: [29, 30, 31]) func exactAcknowledgementsAndRetentionBoundary(days: Int) throws {
        let entry = try fixture()
        let refs = SyncDeletionReferences(acknowledgedRemovalVersionIDs: Set(entry.exactRemovalVersions.map(\.versionID)))
        let actions = SyncDeletionPolicy.evaluate(now: entry.deletedAt.addingTimeInterval(Double(days) * 86400), records: [entry], references: refs)
        #expect(actions.eligibleEntryIDs == (days >= 30 ? [entry.id] : []))
        #expect(actions.markers.count == (days >= 30 ? entry.domain.ownedRecords.count : 0))
    }

    @Test(arguments: ["missing", "stale", "live", "attachment", "path", "nan", "infinite", "malformed"])
    func unsafeProofOrReferenceRetainsContent(reason: String) throws {
        var entry = try fixture()
        var ack = Set(entry.exactRemovalVersions.map(\.versionID))
        var ids: Set<SyncEntityID> = []
        var attachments: Set<UUID> = []
        var paths: Set<String> = []
        let attachmentID = UUID()
        let path = "\(entry.id.uuidString)/\(attachmentID.uuidString).retained"
        if ["attachment", "path"].contains(reason) {
            entry = .init(id: entry.id, deletedAt: entry.deletedAt, domain: entry.domain,
                exactRemovalVersions: entry.exactRemovalVersions, files: [.init(attachmentVersionID: attachmentID,
                    restoreRelativePath: "Photos/photo.jpg", retainedRelativePath: path, byteCount: 2, sha256: Data(repeating: 1, count: 32))])
        }
        if reason == "missing" { ack.remove(ack.first!) }
        if reason == "stale" { ack = [UUID()] }
        if reason == "live" { ids = entry.domain.rootIDs }
        if reason == "attachment" { attachments = [attachmentID] }
        if reason == "path" { paths = [path] }
        if reason == "malformed" {
            entry = .init(id: entry.id, deletedAt: entry.deletedAt, domain: entry.domain, exactRemovalVersions: [], files: [])
        }
        let now = reason == "nan" ? Date(timeIntervalSinceReferenceDate: .nan) : reason == "infinite"
            ? Date(timeIntervalSinceReferenceDate: .infinity) : entry.deletedAt.addingTimeInterval(2592000)
        let refs = SyncDeletionReferences(acknowledgedRemovalVersionIDs: ack, protectedRecordIDs: ids,
            protectedAttachmentVersionIDs: attachments, protectedLedgerRelativePaths: paths)
        #expect(SyncDeletionPolicy.evaluate(now: now, records: [entry], references: refs).eligibleEntryIDs.isEmpty)
    }

    @Test func markersAreContentFreeAndValidateExactShape() throws {
        let entry = try fixture()
        let refs = SyncDeletionReferences(acknowledgedRemovalVersionIDs: Set(entry.exactRemovalVersions.map(\.versionID)))
        let markers = SyncDeletionPolicy.evaluate(now: entry.deletedAt.addingTimeInterval(2592000), records: [entry], references: refs).markers
        for marker in markers {
            let record = try marker.record()
            #expect(try DeletionMarker(record: SyncRecordVersion(record: record).record) == marker)
            let bytes = try JSONEncoder().encode(record)
            #expect(try DeletionMarker(record: JSONDecoder().decode(SyncRecord.self, from: bytes)) == marker)
            #expect(!String(decoding: bytes, as: UTF8.self).contains("private project name"))
            var invalid = record
            invalid.payload.fields["name"] = .init(value: .string("secret"), stamp: record.deletedAt.stamp)
            #expect(throws: (any Error).self) { try SyncRecordValidator().validate(invalid) }
            invalid = record
            invalid = .init(schemaVersion: 1, id: .init(kind: .deletionMarker, uuid: UUID()), createdAt: record.createdAt,
                entityRevision: record.entityRevision, payload: record.payload, relationships: [], deletedAt: record.deletedAt)
            #expect(throws: (any Error).self) { try SyncRecordValidator().validate(invalid) }
        }
    }

    @Test(arguments: [false, true]) func permanentMarkersRejectRemoteAndFrozenPendingEvenWithHigherStamp(pending: Bool) throws {
        let entry = try fixture()
        let original = entry.domain.ownedRecords.first!
        let proof = entry.exactRemovalVersions.first { $0.record.id == original.id }!
        let marker = DeletionMarker(targetID: original.id, removalStamp: proof.record.deletedAt.stamp, removalVersionID: proof.versionID)
        var newer = original
        newer.deletedAt = .init(value: nil, stamp: .init(logicalRevision: 9999, modifiedAt: .now, deviceID: "offline"))
        if pending {
            let mutation = try SyncMutation.save(recordVersion: .init(record: newer), mutationID: UUID())
            #expect(throws: (any Error).self) {
                try SyncMergeEngine().merge(local: [], remote: [], pendingLocalMutations: [mutation], deletionMarkers: [marker])
            }
        } else {
            #expect(throws: (any Error).self) {
                try SyncMergeEngine().merge(local: [], remote: [newer], pendingLocal: [], deletionMarkers: [marker])
            }
        }
    }

    private func fixture() throws -> SyncDeletionEntry {
        let project = try StoredProject(name: "private project name")
        let owned = Array(try SyncCanonicalPublicationSnapshot(archive: .init(version: ProjectArchive.currentVersion,
            projects: [project]), deviceID: "test").records.values)
        let date = Date(timeIntervalSince1970: 100)
        let versions = try owned.map { original in
            var record = original
            record.deletedAt = .init(value: date, stamp: .init(logicalRevision: 100, modifiedAt: date, deviceID: "test"))
            return try SyncRecordVersion(record: record)
        }
        return .init(id: UUID(), deletedAt: date, domain: .init(rootIDs: [.init(kind: .project, uuid: project.id)],
            ownedRecords: owned, supportingParentIDs: [], removedReminders: [:]), exactRemovalVersions: versions, files: [])
    }
}
