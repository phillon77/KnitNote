import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

@Suite(.serialized) struct SyncPublicationEvidenceDurabilityTests {
    @Test func canonicalProjectorIsTheOnlyCompiledStructuralAndAttachmentAuthority() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/KnitNoteCore/Projects/JSONProjectStore.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("SyncCanonicalPublicationSnapshot("))
        #expect(source.contains("sole runtime authority"))
        #expect(source.contains("sole active attachment projection authority"))
        #expect(source.contains("#if false\nprivate struct SyncPublicationSnapshot"))
        #expect(source.contains("#if false\n    private func syncArchiveAttachmentMutations"))
    }

    @Test func sidecarOnlyRestartRetainsLineageAndDeletionAuthority() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = SyncAttachmentPublicationEvidenceFile(
            url: root.appendingPathComponent("attachment-versions.json")
        )
        let slot = SyncAttachmentSlot(
            owner: .init(kind: .project, uuid: UUID()),
            role: "project-photo",
            slotID: "primary"
        )
        let first = try version(slot: slot, bytes: Data("first".utf8))
        let second = try version(
            slot: slot,
            bytes: Data("second".utf8),
            replacing: first.versionID
        )
        let evidence = SyncAttachmentPublicationEvidence(
            versions: [first, second],
            deletedVersionIDs: [second.versionID]
        )

        try file.save(evidence)
        let restarted = try SyncAttachmentPublicationEvidenceFile(url: file.url).load()

        #expect(restarted.allVersions == [first, second])
        #expect(restarted.versionID(for: slot) == second.versionID)
        #expect(restarted.isDeleted(second.versionID))
    }

    @Test func sidecarRestartRetainsCanonicalIssuedAttachmentRecord() throws {
        // Production break caught: version-only sidecar evidence could not
        // reproduce an issued immutable snapshot after restart.
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = SyncAttachmentPublicationEvidenceFile(
            url: root.appendingPathComponent("attachment-versions.json")
        )
        let slot = SyncAttachmentSlot(
            owner: .init(kind: .project, uuid: UUID()),
            role: "project-photo",
            slotID: "primary"
        )
        let issued = try liveMutation(version(slot: slot, bytes: Data("photo".utf8)))
        let issuedRecord = try #require(issued.savedRecordVersion?.record)

        _ = try file.applying([issued])
        let restarted = try file.load()

        #expect(restarted.record(for: slot) == issuedRecord)
    }

    @Test func legacyVersionOnlySidecarLoadsButCannotAuthorizeBareDeletion() throws {
        // Production break caught: legacy metadata was sufficient to rebuild
        // new record fields for a delete that carried no immutable snapshot.
        struct LegacyEvidence: Encodable {
            let versions: [SyncAttachmentVersion]
            let deletedVersionIDs: [UUID] = []
            let watchCommandProofs: [SyncProcessedWatchCommandProof] = []
        }

        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("attachment-versions.json")
        let version = try version(
            slot: .init(
                owner: .init(kind: .project, uuid: UUID()),
                role: "project-photo",
                slotID: "primary"
            ),
            bytes: Data("legacy".utf8)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(LegacyEvidence(versions: [version])).write(to: url)
        let originalBytes = try Data(contentsOf: url)
        let file = SyncAttachmentPublicationEvidenceFile(url: url)

        #expect(try file.load().allVersions == [version])
        #expect(throws: SyncPublicationTransactionFileError.corrupt) {
            _ = try file.applying([.delete(
                .init(kind: .attachment, uuid: version.versionID),
                mutationID: UUID()
            )])
        }
        #expect(try Data(contentsOf: url) == originalBytes)
    }

    @Test func evidenceWritePropagatesEveryDurabilityBoundaryFailure() throws {
        for boundary in SyncDurableFileWriteBoundary.allCases {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("attachment-versions.json")
            let file = SyncAttachmentPublicationEvidenceFile(
                url: url,
                beforeDurabilityBoundary: { reached in
                    if reached == boundary { throw InjectedEvidenceFailure() }
                }
            )

            #expect(throws: InjectedEvidenceFailure.self) {
                try file.save(SyncAttachmentPublicationEvidence())
            }
        }
    }

    @Test func orphanProofEvidenceRenameFailurePreservesPriorAuthority() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("attachment-versions.json")
        let firstCommand = WatchCounterCommand(
            id: UUID(), projectID: UUID(), counterID: UUID(),
            operation: .increment, createdAt: Date(timeIntervalSince1970: 1)
        )
        let secondCommand = WatchCounterCommand(
            id: UUID(), projectID: UUID(), counterID: UUID(),
            operation: .increment, createdAt: Date(timeIntervalSince1970: 2)
        )
        let firstMutation = try orphanProofMutation(
            command: firstCommand,
            rejection: .projectMissing,
            processedAt: Date(timeIntervalSince1970: 3)
        )
        let secondMutation = try orphanProofMutation(
            command: secondCommand,
            rejection: .counterMissing,
            processedAt: Date(timeIntervalSince1970: 4)
        )
        _ = try SyncAttachmentPublicationEvidenceFile(url: url)
            .applying([firstMutation])
        let failingWriter = SyncAttachmentPublicationEvidenceFile(
            url: url,
            beforeDurabilityBoundary: { boundary in
                if boundary == .beforeRename { throw InjectedEvidenceFailure() }
            }
        )

        #expect(throws: InjectedEvidenceFailure.self) {
            _ = try failingWriter.applying([secondMutation])
        }

        let restarted = try SyncAttachmentPublicationEvidenceFile(url: url).load()
        #expect(restarted.watchCommandProofs.map(\.id) == [firstCommand.id])
        #expect(try restarted.watchCommandProof(for: firstCommand)?.rejection
            == .projectMissing)
        #expect(try restarted.watchCommandProof(for: secondCommand) == nil)
    }

    @Test func separatelyLoadedEvidenceWritersMergeUnderTheExclusiveLock() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("attachment-versions.json")
        let firstWriter = SyncAttachmentPublicationEvidenceFile(url: url)
        let secondWriter = SyncAttachmentPublicationEvidenceFile(url: url)
        let owner = SyncEntityID(kind: .yarn, uuid: UUID())
        let firstVersion = try version(
            slot: .init(owner: owner, role: "yarn-label-photo", slotID: "first"),
            bytes: Data("first".utf8)
        )
        let secondVersion = try version(
            slot: .init(owner: owner, role: "yarn-label-photo", slotID: "second"),
            bytes: Data("second".utf8)
        )

        _ = try firstWriter.applying([try tombstoneMutation(firstVersion)])
        _ = try secondWriter.applying([try tombstoneMutation(secondVersion)])
        let merged = try SyncAttachmentPublicationEvidenceFile(url: url).load()

        #expect(Set(merged.allVersions.map(\.versionID)) == [
            firstVersion.versionID, secondVersion.versionID
        ])
    }

    @Test func acknowledgedTombstoneRejectsStaleLiveResurrection() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = SyncAttachmentPublicationEvidenceFile(
            url: root.appendingPathComponent("attachment-versions.json")
        )
        let version = try version(
            slot: .init(
                owner: .init(kind: .project, uuid: UUID()),
                role: "project-photo",
                slotID: "primary"
            ),
            bytes: Data("photo".utf8)
        )
        _ = try file.applying([try liveMutation(version)])
        _ = try file.applying([try tombstoneMutation(version)])

        #expect(throws: SyncPublicationTransactionFileError.corrupt) {
            _ = try file.applying([try liveMutation(version)])
        }
        #expect(try file.load().isDeleted(version.versionID))
    }

    @Test func legacyBareAttachmentDeleteRequiresExactIssuedEvidence() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = SyncAttachmentPublicationEvidenceFile(
            url: root.appendingPathComponent("attachment-versions.json")
        )

        #expect(throws: SyncPublicationTransactionFileError.corrupt) {
            _ = try file.applying([.delete(
                .init(kind: .attachment, uuid: UUID()),
                mutationID: UUID()
            )])
        }
    }

    private func version(
        slot: SyncAttachmentSlot,
        bytes: Data,
        replacing: UUID? = nil
    ) throws -> SyncAttachmentVersion {
        try .issuing(
            slot: slot,
            contentSHA256: Data(SHA256.hash(data: bytes)),
            byteCount: Int64(bytes.count),
            mediaType: "image/jpeg",
            displayFilename: "photo.jpg",
            replacesVersionID: replacing
        )
    }

    private func tombstoneMutation(_ version: SyncAttachmentVersion) throws -> SyncMutation {
        let stamp = SyncMutationStamp(
            logicalRevision: 1,
            modifiedAt: Date(timeIntervalSince1970: 1),
            deviceID: "evidence-test"
        )
        let record = SyncRecord(
            schemaVersion: 1,
            id: .init(kind: .attachment, uuid: version.versionID),
            createdAt: stamp.modifiedAt,
            entityRevision: 1,
            payload: .init(fields: [:], attachment: version),
            relationships: [.init(role: "owner", target: version.slot.owner)],
            deletedAt: .init(value: stamp.modifiedAt, stamp: stamp)
        )
        return try .save(
            recordVersion: SyncRecordVersion(record: record),
            mutationID: UUID()
        )
    }

    private func liveMutation(_ version: SyncAttachmentVersion) throws -> SyncMutation {
        let stamp = SyncMutationStamp(
            logicalRevision: 1,
            modifiedAt: Date(timeIntervalSince1970: 1),
            deviceID: "evidence-test"
        )
        let record = SyncRecord(
            schemaVersion: 1,
            id: .init(kind: .attachment, uuid: version.versionID),
            createdAt: stamp.modifiedAt,
            entityRevision: 1,
            payload: .init(fields: [:], attachment: version),
            relationships: [.init(role: "owner", target: version.slot.owner)],
            deletedAt: .init(value: nil, stamp: stamp)
        )
        return try .save(
            recordVersion: SyncRecordVersion(record: record),
            attachmentSource: SyncAttachmentSource(
                fileURL: URL(fileURLWithPath: "/tmp/evidence-test-source"),
                contentSHA256: version.contentSHA256,
                byteCount: version.byteCount
            ),
            mutationID: UUID()
        )
    }

    private func orphanProofMutation(
        command: WatchCounterCommand,
        rejection: WatchCommandRejection,
        processedAt: Date
    ) throws -> SyncMutation {
        let processingStamp = SyncMutationStamp(
            logicalRevision: 0,
            modifiedAt: processedAt,
            deviceID: "evidence-test"
        )
        let proof = try SyncProcessedWatchCommandProof(
            id: command.id,
            rejection: rejection,
            commandIdentity: .init(command),
            preparedCommand: nil,
            effectProof: nil,
            processingStamp: processingStamp
        )
        let recordStamp = SyncMutationStamp(
            logicalRevision: 1,
            modifiedAt: processedAt,
            deviceID: "evidence-test"
        )
        let record = SyncRecord(
            schemaVersion: 1,
            id: .init(kind: .watchCommandProof, uuid: command.id),
            createdAt: command.createdAt,
            entityRevision: recordStamp.logicalRevision,
            payload: .init(
                fields: [:],
                atomicDomain: .init(
                    value: .orphanWatchCommandProof(
                        try SyncOrphanWatchCommandProof(proof: proof)
                    ),
                    stamp: recordStamp
                )
            ),
            relationships: [],
            deletedAt: .init(value: nil, stamp: recordStamp)
        )
        return try .save(
            recordVersion: SyncRecordVersion(record: record),
            mutationID: UUID()
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-publication-evidence-\(UUID().uuidString)",
            isDirectory: true
        )
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct InjectedEvidenceFailure: Error {}
