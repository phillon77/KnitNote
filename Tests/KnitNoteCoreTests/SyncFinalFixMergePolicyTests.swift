import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct SyncFinalFixMergePolicyTests {
    @Test func attachmentLineageCannotReplaceItsOwnContentVersion() throws {
        let slot = SyncAttachmentSlot(
            owner: .init(kind: .project, uuid: UUID()),
            role: "project-photo",
            slotID: "primary"
        )
        let bytes = Data("same-version".utf8)
        let digest = Data(SHA256.hash(data: bytes))
        let version = try SyncAttachmentVersion.issuing(
            slot: slot,
            contentSHA256: digest,
            byteCount: Int64(bytes.count),
            mediaType: "image/jpeg",
            displayFilename: "photo.jpg"
        )

        #expect(throws: SyncAttachmentVersionError.invalidMetadata) {
            try SyncAttachmentVersion.issuing(
                slot: slot,
                contentSHA256: digest,
                byteCount: Int64(bytes.count),
                mediaType: "image/jpeg",
                displayFilename: "photo.jpg",
                replacesVersionID: version.versionID,
                versionID: version.versionID
            )
        }
    }

    @Test func distinctAttachmentSlotsAndSequentialVersionsDoNotConflict() throws {
        let owner = SyncEntityID(kind: .yarn, uuid: UUID())
        let firstLabel = try attachmentRecord(owner: owner, slotID: "label:0", bytes: Data("front".utf8))
        let secondLabel = try attachmentRecord(owner: owner, slotID: "label:1", bytes: Data("back".utf8))

        let separate = try SyncMergeEngine().merge(
            local: [firstLabel],
            remote: [secondLabel],
            pendingLocal: []
        )
        #expect(separate.conflicts.isEmpty)

        let replacement = try attachmentRecord(
            owner: owner,
            slotID: "label:0",
            bytes: Data("replacement".utf8),
            replaces: firstLabel.id.uuid
        )
        let sequential = try SyncMergeEngine().merge(
            local: [firstLabel],
            remote: [replacement],
            pendingLocal: []
        )
        #expect(sequential.conflicts.isEmpty)
        #expect(sequential.resolvedAttachmentVersionIDs[firstLabel.payload.attachment!.slot]
            == replacement.id.uuid)
    }

    @Test func concurrentAttachmentHeadsSurfaceConflictAndResolveByCausalStamp() throws {
        let owner = SyncEntityID(kind: .yarn, uuid: UUID())
        let root = try attachmentRecord(
            owner: owner, slotID: "label:stable", bytes: Data("root".utf8)
        )
        let olderFork = try attachmentRecord(
            owner: owner, slotID: "label:stable", bytes: Data("older".utf8),
            replaces: root.id.uuid, revision: 2, modifiedAt: 2, deviceID: "older"
        )
        let newerFork = try attachmentRecord(
            owner: owner, slotID: "label:stable", bytes: Data("newer".utf8),
            replaces: root.id.uuid, revision: 3, modifiedAt: 3, deviceID: "newer"
        )

        let result = try SyncMergeEngine().merge(
            local: [root, olderFork], remote: [newerFork], pendingLocal: []
        )

        #expect(result.conflicts == [
            .attachmentVersions(
                owner: owner,
                role: "yarn-label-photo",
                ids: [olderFork.id, newerFork.id].sorted(by: entityLess)
            )
        ])
        #expect(result.resolvedAttachmentVersionIDs[root.payload.attachment!.slot]
            == newerFork.id.uuid)
    }

    @Test func deletingLatestAttachmentHeadDoesNotResurrectItsAncestor() throws {
        let owner = SyncEntityID(kind: .yarn, uuid: UUID())
        let root = try attachmentRecord(
            owner: owner, slotID: "label:stable", bytes: Data("root".utf8)
        )
        let replacement = try attachmentRecord(
            owner: owner, slotID: "label:stable", bytes: Data("replacement".utf8),
            replaces: root.id.uuid, revision: 2, modifiedAt: 2, deviceID: "replacement",
            deleted: true
        )

        let result = try SyncMergeEngine().merge(
            local: [root], remote: [replacement], pendingLocal: []
        )

        #expect(result.conflicts.isEmpty)
        #expect(result.resolvedAttachmentVersionIDs[root.payload.attachment!.slot] == nil)
    }

    @Test func legacyPendingAttachmentDeleteBecomesDurableTombstone() throws {
        let owner = SyncEntityID(kind: .yarn, uuid: UUID())
        let root = try attachmentRecord(
            owner: owner, slotID: "label:stable", bytes: Data("root".utf8)
        )
        let replacement = try attachmentRecord(
            owner: owner, slotID: "label:stable", bytes: Data("replacement".utf8),
            replaces: root.id.uuid, revision: 2, modifiedAt: 2, deviceID: "replacement"
        )
        let mutationID = UUID()

        let result = try SyncMergeEngine().merge(
            local: [root, replacement],
            remote: [],
            pendingLocalMutations: [.delete(replacement.id, mutationID: mutationID)]
        )

        let uploaded = try #require(result.mutationsToUpload.first)
        let tombstone = try #require(uploaded.savedRecordVersion?.record)
        #expect(result.mutationsToUpload.count == 1)
        #expect(uploaded.mutationID == mutationID)
        #expect(tombstone.id == replacement.id)
        #expect(tombstone.payload.attachment == replacement.payload.attachment)
        #expect(tombstone.deletedAt.value != nil)
        #expect(result.resolvedAttachmentVersionIDs[root.payload.attachment!.slot] == nil)
    }

    @Test func atomicCounterMergeRejectsStaleRevisionEvenWhenItsClockIsNewer() throws {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let current = ProjectCounter(
            id: counterID,
            defaultOrdinal: 1,
            value: 12,
            mutationRevision: 8
        )
        let stale = ProjectCounter(
            id: counterID,
            defaultOrdinal: 1,
            value: 3,
            mutationRevision: 7
        )
        let currentRecord = atomicCounterRecord(
            current,
            project: projectID,
            modifiedAt: Date(timeIntervalSince1970: 10),
            deviceID: "local"
        )
        let staleRecord = atomicCounterRecord(
            stale,
            project: projectID,
            modifiedAt: Date(timeIntervalSince1970: 9_999),
            deviceID: "remote"
        )

        let result = try SyncMergeEngine().merge(
            local: [currentRecord],
            remote: [staleRecord],
            pendingLocal: []
        )

        #expect(result.records.single.atomicCounter == current)
        #expect(result.records.single.entityRevision == 8)
    }

    @Test func concurrentAbsoluteCounterAssignmentsChooseByStampAndSurfaceConflict() throws {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let local = atomicCounterRecord(
            ProjectCounter(
                id: counterID,
                defaultOrdinal: 1,
                value: 12,
                mutationRevision: 8
            ),
            project: projectID,
            modifiedAt: Date(timeIntervalSince1970: 10),
            deviceID: "local"
        )
        let remote = atomicCounterRecord(
            ProjectCounter(
                id: counterID,
                defaultOrdinal: 1,
                value: 30,
                mutationRevision: 8
            ),
            project: projectID,
            modifiedAt: Date(timeIntervalSince1970: 20),
            deviceID: "remote"
        )

        let result = try SyncMergeEngine().merge(
            local: [local],
            remote: [remote],
            pendingLocal: []
        )

        let entity = SyncEntityID(kind: .projectCounter, uuid: counterID)
        #expect(result.records.single.atomicCounter?.value == 30)
        #expect(result.conflicts == [
            .counterValues(entity: entity, revision: 8, values: [12, 30])
        ])
    }

    @Test func reminderOccurrenceStateFollowsTheNewerAggregateStamp() throws {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = UUID()
        let base = try #require(KnittingReminder(
            id: UUID(),
            counterID: counterID,
            draft: .oneTime(kind: .cable, target: 1, text: "Cable"),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let triggered = try base.applying(.trigger(through: 1))
        let occurrence = try #require(triggered.progress.pending.first)
        let completed = try triggered.applying(.complete(
            occurrenceID: occurrence.id,
            observedRevision: triggered.mutationRevision
        ))
        let deferred = try triggered.applying(.deferOnce(
            occurrenceID: occurrence.id,
            observedRevision: triggered.mutationRevision
        ))
        #expect(completed.mutationRevision == deferred.mutationRevision)

        let result = try SyncMergeEngine().merge(
            local: [atomicReminderRecord(
                deferred,
                project: projectID,
                modifiedAt: Date(timeIntervalSince1970: 100),
                deviceID: "defer-device"
            )],
            remote: [atomicReminderRecord(
                completed,
                project: projectID,
                modifiedAt: Date(timeIntervalSince1970: 2),
                deviceID: "complete-device"
            )],
            pendingLocal: []
        )

        #expect(result.records.single.atomicReminder == deferred)
        #expect(result.records.single.atomicReminder?.progress.pending.first?.phase == .deferredOnce)
    }

    @Test func processedWatchCommandCannotMergeBackToItsPreparedPreMutationState() throws {
        let projectID = UUID()
        let projectEntity = SyncEntityID(kind: .project, uuid: projectID)
        let counterID = UUID()
        let command = WatchCounterCommand(
            id: UUID(),
            projectID: projectID,
            counterID: counterID,
            operation: .increment,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let prepared = PreparedWatchCommand(
            command: command,
            expectedCounterRevision: 4,
            expectedCounterValue: 9
        )
        var ledger = ProcessedWatchCommandLedger()
        ledger.record(
            command.id,
            preparedCommand: prepared,
            effectProof: .init(counter: ProjectCounter(
                id: counterID,
                defaultOrdinal: 1,
                value: 10,
                mutationRevision: 5
            )),
            at: Date(timeIntervalSince1970: 2)
        )
        let stale = atomicCounterRecord(
            ProjectCounter(
                id: counterID,
                defaultOrdinal: 1,
                value: 9,
                mutationRevision: 4
            ),
            project: projectEntity,
            modifiedAt: Date(timeIntervalSince1970: 10),
            deviceID: "remote"
        )

        #expect(throws: SyncMergeError.processedWatchCommandWouldRegress(command.id)) {
            try SyncMergeEngine().merge(
                local: [stale],
                remote: [],
                pendingLocal: [],
                counterReminderContext: .init(
                    preparedCommands: [prepared],
                    processedLedger: ledger
                )
            )
        }

        let applied = atomicCounterRecord(
            ProjectCounter(
                id: counterID,
                defaultOrdinal: 1,
                value: 10,
                mutationRevision: 5
            ),
            project: projectEntity,
            modifiedAt: Date(timeIntervalSince1970: 3),
            deviceID: "local"
        )
        let accepted = try SyncMergeEngine().merge(
            local: [stale],
            remote: [applied],
            pendingLocal: [],
            counterReminderContext: .init(
                preparedCommands: [prepared],
                processedLedger: ledger
            )
        )
        #expect(accepted.records.single.atomicCounter?.value == 10)
    }

    @Test func newerRestoreClearsVersionedDeletionCascade() throws {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = SyncEntityID(kind: .projectCounter, uuid: UUID())
        let deleteStamp = stamp(revision: 2, device: "delete")
        let restoreStamp = stamp(revision: 3, device: "restore")
        var deleted = basicRecord(id: projectID, stamp: deleteStamp)
        deleted.deletedAt = .init(value: Date(timeIntervalSince1970: 2), stamp: deleteStamp)
        deleted.payload.deletionCascade = .init(value: [counterID], stamp: deleteStamp)
        var restored = basicRecord(id: projectID, stamp: restoreStamp)
        restored.deletedAt = .init(value: nil, stamp: restoreStamp)
        restored.payload.deletionCascade = .init(value: [], stamp: restoreStamp)
        let child = atomicCounterRecord(
            ProjectCounter(id: counterID.uuid, defaultOrdinal: 1),
            project: projectID,
            modifiedAt: Date(timeIntervalSince1970: 1),
            deviceID: "local"
        )

        let result = try SyncMergeEngine().merge(
            local: [deleted, child],
            remote: [restored],
            pendingLocal: []
        )

        let project = try #require(result.records.first { $0.id == projectID })
        #expect(project.deletedAt.value == nil)
        #expect(project.payload.deletionCascade?.value.isEmpty == true)
    }

    @Test func unrelatedCascadeTargetIsRejectedByOwnershipGraph() {
        let deletingProject = SyncEntityID(kind: .project, uuid: UUID())
        let otherProject = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = SyncEntityID(kind: .projectCounter, uuid: UUID())
        let deleteStamp = stamp(revision: 2, device: "delete")
        var deleted = basicRecord(id: deletingProject, stamp: deleteStamp)
        deleted.deletedAt = .init(value: Date(timeIntervalSince1970: 2), stamp: deleteStamp)
        deleted.payload.deletionCascade = .init(value: [counterID], stamp: deleteStamp)
        let unrelatedCounter = atomicCounterRecord(
            ProjectCounter(id: counterID.uuid, defaultOrdinal: 1),
            project: otherProject,
            modifiedAt: Date(timeIntervalSince1970: 1),
            deviceID: "remote"
        )

        #expect(throws: SyncRecordValidationError.unownedRelatedDeletion(
            deletingProject,
            counterID
        )) {
            try SyncRecordValidator().validate([deleted, unrelatedCounter])
        }
    }

    @Test func mergeRejectsDuplicateCascadeBeforeCanonicalOrdering() {
        let projectID = SyncEntityID(kind: .project, uuid: UUID())
        let counterID = SyncEntityID(kind: .projectCounter, uuid: UUID())
        let deleteStamp = stamp(revision: 2, device: "delete")
        var deleted = basicRecord(id: projectID, stamp: deleteStamp)
        deleted.deletedAt = .init(value: Date(timeIntervalSince1970: 2), stamp: deleteStamp)
        deleted.payload.deletionCascade = .init(
            value: [counterID, counterID],
            stamp: deleteStamp
        )
        let counter = atomicCounterRecord(
            ProjectCounter(id: counterID.uuid, defaultOrdinal: 1),
            project: projectID,
            modifiedAt: Date(timeIntervalSince1970: 1),
            deviceID: "local"
        )

        #expect(throws: SyncRecordValidationError.duplicateRelatedDeletion(
            projectID,
            counterID
        )) {
            try SyncMergeEngine().merge(
                local: [deleted, counter],
                remote: [],
                pendingLocal: []
            )
        }
    }

    @Test func pendingSaveAndDeleteIntentsSurviveMergeWithoutCurrentStateLookup() throws {
        let id = SyncEntityID(kind: .project, uuid: UUID())
        let first = basicRecord(id: id, stamp: stamp(revision: 1, device: "local"))
        var second = first
        second.entityRevision = 2
        second.payload.fields["name"] = .init(
            value: .string("Replacement"),
            stamp: stamp(revision: 2, device: "local")
        )
        let save = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: first),
            mutationID: UUID()
        )
        let replacement = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: second),
            mutationID: UUID()
        )
        let delete = SyncMutation.delete(id, mutationID: UUID())

        let result = try SyncMergeEngine().merge(
            local: [second],
            remote: [],
            pendingLocalMutations: [save, replacement, delete]
        )

        #expect(result.mutationsToUpload == [save, replacement, delete])
        #expect(result.mutationsToUpload.map(\.intent) == [.save, .save, .delete])
        #expect(result.mutationsToUpload.compactMap(\.savedRecordVersion) == [
            try SyncRecordVersion(record: first),
            try SyncRecordVersion(record: second)
        ])
    }
}

private func attachmentRecord(
    owner: SyncEntityID,
    slotID: String,
    bytes: Data,
    replaces: UUID? = nil,
    revision: UInt64? = nil,
    modifiedAt: TimeInterval? = nil,
    deviceID: String = "fixture",
    deleted: Bool = false
) throws -> SyncRecord {
    let slot = SyncAttachmentSlot(owner: owner, role: "yarn-label-photo", slotID: slotID)
    let attachment = try SyncAttachmentVersion.issuing(
        slot: slot,
        contentSHA256: Data(SHA256.hash(data: bytes)),
        byteCount: Int64(bytes.count),
        mediaType: "image/jpeg",
        displayFilename: "label.jpg",
        replacesVersionID: replaces
    )
    let resolvedRevision = revision ?? UInt64(bytes.count)
    let recordStamp = SyncMutationStamp(
        logicalRevision: resolvedRevision,
        modifiedAt: Date(timeIntervalSince1970: modifiedAt ?? TimeInterval(resolvedRevision)),
        deviceID: deviceID
    )
    return SyncRecord(
        schemaVersion: 1,
        id: .init(kind: .attachment, uuid: attachment.versionID),
        createdAt: Date(timeIntervalSince1970: 1),
        entityRevision: recordStamp.logicalRevision,
        payload: .init(fields: [:], attachment: attachment),
        relationships: [.init(role: "owner", target: owner)],
        deletedAt: .init(
            value: deleted ? Date(timeIntervalSince1970: modifiedAt ?? 1) : nil,
            stamp: recordStamp
        )
    )
}

private func atomicCounterRecord(
    _ counter: ProjectCounter,
    project: SyncEntityID,
    modifiedAt: Date,
    deviceID: String
) -> SyncRecord {
    let recordStamp = SyncMutationStamp(
        logicalRevision: counter.mutationRevision,
        modifiedAt: modifiedAt,
        deviceID: deviceID
    )
    return SyncRecord(
        schemaVersion: 1,
        id: .init(kind: .projectCounter, uuid: counter.id),
        createdAt: Date(timeIntervalSince1970: 0),
        entityRevision: counter.mutationRevision,
        payload: .init(
            fields: [:],
            atomicDomain: .init(
                value: .projectCounter(SyncCounterReminderState(
                    counter: counter,
                    reminder: nil,
                    preparedCommand: nil,
                    processedCommandIDs: [],
                    occurrence: nil
                )),
                stamp: recordStamp
            )
        ),
        relationships: [.init(role: "project", target: project)],
        deletedAt: .init(value: nil, stamp: recordStamp)
    )
}

private func atomicReminderRecord(
    _ reminder: KnittingReminder,
    project: SyncEntityID,
    modifiedAt: Date,
    deviceID: String
) -> SyncRecord {
    let recordStamp = SyncMutationStamp(
        logicalRevision: reminder.mutationRevision,
        modifiedAt: modifiedAt,
        deviceID: deviceID
    )
    return SyncRecord(
        schemaVersion: 1,
        id: .init(kind: .projectCounter, uuid: reminder.counterID),
        createdAt: reminder.createdAt,
        entityRevision: reminder.mutationRevision,
        payload: .init(
            fields: [:],
            atomicDomain: .init(
                value: .projectCounter(SyncCounterReminderState(
                    counter: ProjectCounter(
                        id: reminder.counterID,
                        defaultOrdinal: 1,
                        mutationRevision: 0
                    ),
                    reminder: reminder,
                    preparedCommand: nil,
                    processedCommandIDs: [],
                    occurrence: reminder.progress.nextOccurrenceIndex
                )),
                stamp: recordStamp
            )
        ),
        relationships: [.init(role: "project", target: project)],
        deletedAt: .init(value: nil, stamp: recordStamp)
    )
}

private func basicRecord(id: SyncEntityID, stamp: SyncMutationStamp) -> SyncRecord {
    SyncRecord(
        schemaVersion: 1,
        id: id,
        createdAt: Date(timeIntervalSince1970: 0),
        entityRevision: stamp.logicalRevision,
        payload: .init(fields: [
            "name": .init(value: .string("Project"), stamp: stamp)
        ]),
        relationships: [],
        deletedAt: .init(value: nil, stamp: stamp)
    )
}

private func stamp(revision: UInt64, device: String) -> SyncMutationStamp {
    SyncMutationStamp(
        logicalRevision: revision,
        modifiedAt: Date(timeIntervalSince1970: TimeInterval(revision)),
        deviceID: device
    )
}

private func entityLess(_ lhs: SyncEntityID, _ rhs: SyncEntityID) -> Bool {
    (lhs.kind.rawValue, lhs.uuid.uuidString) < (rhs.kind.rawValue, rhs.uuid.uuidString)
}

private extension SyncRecord {
    var atomicCounter: ProjectCounter? {
        guard case let .projectCounter(state)? = payload.atomicDomain?.value else { return nil }
        return state.counter
    }

    var atomicReminder: KnittingReminder? {
        guard case let .projectCounter(state)? = payload.atomicDomain?.value else { return nil }
        return state.reminder
    }
}

private extension Array where Element == SyncRecord {
    var single: SyncRecord {
        precondition(count == 1)
        return self[0]
    }
}
