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
