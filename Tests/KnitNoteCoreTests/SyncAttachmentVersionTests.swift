import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct SyncAttachmentVersionTests {
    @Test func sameBytesIssuedAgainReceiveDifferentVersionIDsAndPreserveLineage() throws {
        let slot = SyncAttachmentSlot(
            owner: .init(kind: .project, uuid: UUID()),
            role: "project-photo",
            slotID: "cover"
        )
        let digestA = Data(repeating: 0xA1, count: 32)
        let digestB = Data(repeating: 0xB2, count: 32)
        let a1 = try SyncAttachmentVersion.issuing(
            slot: slot,
            contentSHA256: digestA,
            byteCount: 1,
            mediaType: "image/jpeg",
            displayFilename: "a.jpg"
        )
        let b = try SyncAttachmentVersion.issuing(
            slot: slot,
            contentSHA256: digestB,
            byteCount: 1,
            mediaType: "image/jpeg",
            displayFilename: "b.jpg",
            replacesVersionID: a1.versionID
        )
        let a2 = try SyncAttachmentVersion.issuing(
            slot: slot,
            contentSHA256: digestA,
            byteCount: 1,
            mediaType: "image/jpeg",
            displayFilename: "a.jpg",
            replacesVersionID: b.versionID
        )

        #expect(a1.versionID != a2.versionID)
        #expect(a2.replacesVersionID == b.versionID)
        #expect(Set([a1.conflictGroupID, b.conflictGroupID, a2.conflictGroupID]).count == 1)
    }

    @Test func sameVersionIDWithDifferentLineageIsCorruption() throws {
        let slot = SyncAttachmentSlot(
            owner: .init(kind: .project, uuid: UUID()),
            role: "project-photo",
            slotID: "cover"
        )
        let versionID = UUID()
        let first = try attachmentRecord(
            slot: slot,
            versionID: versionID,
            content: Data(repeating: 0xA1, count: 32),
            replacesVersionID: nil
        )
        let second = try attachmentRecord(
            slot: slot,
            versionID: versionID,
            content: Data(repeating: 0xA1, count: 32),
            replacesVersionID: UUID()
        )

        #expect(throws: SyncMergeError.corruptAttachmentVersion(versionID)) {
            _ = try SyncMergeEngine().merge(local: [first], remote: [second], pendingLocal: [])
        }
    }

    @Test func batchValidationRejectsReusedVersionIDWithDifferentImmutableSnapshot() throws {
        let slot = SyncAttachmentSlot(
            owner: .init(kind: .project, uuid: UUID()),
            role: "project-photo",
            slotID: "cover"
        )
        let versionID = UUID()
        let first = try attachmentRecord(
            slot: slot,
            versionID: versionID,
            content: Data(repeating: 0xA1, count: 32),
            replacesVersionID: nil
        )
        let second = try attachmentRecord(
            slot: slot,
            versionID: versionID,
            content: Data(repeating: 0xB2, count: 32),
            replacesVersionID: nil
        )

        #expect(throws: SyncRecordValidationError.corruptAttachmentVersion(versionID)) {
            _ = try SyncRecordValidator().validate([first, second])
        }
    }

    @Test func batchValidationRejectsAttachmentReplacementCycles() throws {
        let slot = SyncAttachmentSlot(
            owner: .init(kind: .project, uuid: UUID()),
            role: "project-photo",
            slotID: "cover"
        )
        let firstID = UUID()
        let secondID = UUID()
        let first = try attachmentRecord(
            slot: slot,
            versionID: firstID,
            content: Data(repeating: 0xA1, count: 32),
            replacesVersionID: secondID
        )
        let second = try attachmentRecord(
            slot: slot,
            versionID: secondID,
            content: Data(repeating: 0xB2, count: 32),
            replacesVersionID: firstID
        )

        let expectedCycleID = [firstID, secondID].min { $0.uuidString < $1.uuidString }!
        #expect(throws: SyncRecordValidationError.cyclicAttachmentReplacement(expectedCycleID)) {
            _ = try SyncRecordValidator().validate([first, second])
        }
    }

    @Test func immutableSnapshotExcludesDeletionOverlay() throws {
        // Production break caught: attachment tombstones need to reuse the
        // issued immutable identity while advancing only deletion authority.
        let slot = SyncAttachmentSlot(
            owner: .init(kind: .project, uuid: UUID()),
            role: "project-photo",
            slotID: "cover"
        )
        let live = try attachmentRecord(
            slot: slot,
            versionID: UUID(),
            content: Data(repeating: 0xA1, count: 32),
            replacesVersionID: nil
        )
        var tombstone = live
        tombstone.deletedAt = .init(
            value: Date(timeIntervalSince1970: 10),
            stamp: SyncMutationStamp(
                logicalRevision: 2,
                modifiedAt: Date(timeIntervalSince1970: 10),
                deviceID: "attachment-delete-test"
            )
        )

        let liveDigest = try SyncAttachmentImmutableSnapshot(record: live).sha256
        let deletedDigest = try SyncAttachmentImmutableSnapshot(record: tombstone).sha256

        #expect(liveDigest == deletedDigest)
    }

    @Test func immutableSnapshotNormalizesRelationshipOrderAndIncludesOwner() throws {
        // Production break caught: lineage metadata alone omitted immutable
        // owner/relationship identity and could not normalize equivalent order.
        let slot = SyncAttachmentSlot(
            owner: .init(kind: .project, uuid: UUID()),
            role: "project-photo",
            slotID: "cover"
        )
        let record = try attachmentRecord(
            slot: slot,
            versionID: UUID(),
            content: Data(repeating: 0xA1, count: 32),
            replacesVersionID: nil
        )
        let additionalRelationship = SyncRelationship(
            role: "z-immutable-metadata",
            target: .init(kind: .yarn, uuid: UUID())
        )
        var firstOrder = record
        firstOrder.relationships = [additionalRelationship] + record.relationships
        var secondOrder = record
        secondOrder.relationships = record.relationships + [additionalRelationship]
        let firstSnapshot = try SyncAttachmentImmutableSnapshot(record: firstOrder)
        let secondSnapshot = try SyncAttachmentImmutableSnapshot(record: secondOrder)

        #expect(firstSnapshot.relationships == secondSnapshot.relationships)
        #expect(try firstSnapshot.sha256 == secondSnapshot.sha256)
        #expect(firstSnapshot.relationships.contains {
            $0.role == "owner" && $0.target == slot.owner
        })

        var differentOwner = record
        differentOwner.relationships = [
            .init(role: "owner", target: .init(kind: .project, uuid: UUID()))
        ]
        #expect(
            try SyncAttachmentImmutableSnapshot(record: record).sha256
                != SyncAttachmentImmutableSnapshot(record: differentOwner).sha256
        )
    }

    @Test func attachmentOwnerRelationshipMustMatchItsImmutableSlotOwner() throws {
        // Production break caught: an owner mismatch must fail public record
        // validation rather than become an invalid journal fixture.
        let slot = SyncAttachmentSlot(
            owner: .init(kind: .project, uuid: UUID()),
            role: "project-photo",
            slotID: "cover"
        )
        var record = try attachmentRecord(
            slot: slot,
            versionID: UUID(),
            content: Data(repeating: 0xA1, count: 32),
            replacesVersionID: nil
        )
        record.relationships = [
            .init(role: "owner", target: .init(kind: .project, uuid: UUID()))
        ]

        #expect(throws: SyncRecordValidationError.invalidAttachment(record.id)) {
            try SyncRecordValidator().validate(record)
        }
    }

    private func attachmentRecord(
        slot: SyncAttachmentSlot,
        versionID: UUID,
        content: Data,
        replacesVersionID: UUID?
    ) throws -> SyncRecord {
        let attachment = try SyncAttachmentVersion(
            slot: slot,
            versionID: versionID,
            conflictGroupID: try SyncAttachmentVersion.conflictGroupID(for: slot),
            contentSHA256: content,
            byteCount: 1,
            mediaType: "image/jpeg",
            displayFilename: "cover.jpg",
            replacesVersionID: replacesVersionID
        )
        let stamp = SyncMutationStamp(
            logicalRevision: 1,
            modifiedAt: Date(timeIntervalSince1970: 1),
            deviceID: "attachment-test"
        )
        return SyncRecord(
            schemaVersion: 1,
            id: .init(kind: .attachment, uuid: versionID),
            createdAt: Date(timeIntervalSince1970: 0),
            entityRevision: 1,
            payload: .init(fields: [:], attachment: attachment),
            relationships: [.init(role: "owner", target: slot.owner)],
            deletedAt: .init(value: nil, stamp: stamp)
        )
    }
}
