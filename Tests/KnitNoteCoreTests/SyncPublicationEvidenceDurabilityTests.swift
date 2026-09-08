import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

@Suite(.serialized) struct SyncPublicationEvidenceDurabilityTests {
    @Test func saveReadsFirstConflictingAuthorityBeforeEncodingLaterOversizedAuthority() throws {
        // Break caught: extracting codecs into a bulk pre-encode changes ordinary selected-read ordering.
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("attachment-versions.json")
        let slot = SyncAttachmentSlot(owner: .init(kind: .project, uuid: UUID()), role: "project-photo", slotID: "primary")
        let a = try version(slot: slot, bytes: Data("a".utf8))
        let b = try version(slot: slot, bytes: Data("b".utf8), replacing: a.versionID)
        let original = try #require(liveMutation(a).savedRecordVersion?.record)
        var conflict = original
        conflict.payload.fields["changed"] = .init(value: .string("immutable conflict"), stamp: original.deletedAt.stamp)
        var oversized = try #require(liveMutation(b).savedRecordVersion?.record)
        for index in 0..<65 {
            oversized.payload.fields["large-\(index)"] = .init(value: .string(String(repeating: "a", count: 256 * 1_024)), stamp: oversized.deletedAt.stamp)
        }
        _ = try SyncRecordValidator().validate(oversized)
        #expect(try JSONEncoder().encode(oversized).count > 16 * 1_024 * 1_024)
        try SyncAttachmentPublicationEvidenceFile(url: url).save(.init(versions: [a], attachmentRecords: [original]))
        let before = try Data(contentsOf: url)
        let reader = PublicationOutputRecordingReader()
        let file = SyncAttachmentPublicationEvidenceFile(url: url, reader: reader)
        #expect(throws: SyncPublicationTransactionFileError.corrupt) {
            try file.save(.init(versions: [a, b], attachmentRecords: [conflict, oversized]))
        }
        #expect(reader.paths.map { $0.lastPathComponent } == [a.versionID.uuidString.lowercased() + ".json"])
        #expect(file.counters.snapshot.headReads == 0)
        #expect(file.counters.snapshot.attachmentAuthorityLookups == 1)
        #expect(file.counters.snapshot.attachmentAuthorityWrites == 0)
        #expect(try Data(contentsOf: url) == before)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("attachment-versions.attachment-records/" + String(b.versionID.uuidString.lowercased().prefix(2)) + "/" + b.versionID.uuidString.lowercased() + ".json").path))
        var calls = 0
        #expect(throws: SyncPublicationTransactionFileError.corrupt) {
            try SyncAttachmentPublicationEvidenceFile.planSave(.init(versions: [a, b], attachmentRecords: [original, oversized]),
                initial: .init(directories: [""], files: []), temporaryID: { calls += 1; return UUID() })
        }
        #expect(calls == 0)
    }

    @Test func saveLeavesCreatedImmutableAuthorityWhenLaterHeadRenameFails() throws {
        // Break caught: ordinary save adopts pure preplanning or reverses the head/immutable install sequence.
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("attachment-versions.json")
        let attachment = try version(slot: .init(owner: .init(kind: .project, uuid: UUID()), role: "project-photo", slotID: "primary"), bytes: Data("a".utf8))
        var renames = 0
        let file = SyncAttachmentPublicationEvidenceFile(url: url, beforeDurabilityBoundary: { boundary in
            if boundary == .beforeRename {
                renames += 1
                if renames == 2 { throw InjectedEvidenceFailure() }
            }
        })
        #expect(throws: InjectedEvidenceFailure.self) { try file.save(.init(versions: [attachment])) }
        #expect(renames == 2)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let name = attachment.versionID.uuidString.lowercased()
        let authority = root.appendingPathComponent("attachment-versions.attachment-records/" + String(name.prefix(2)) + "/" + name + ".json")
        #expect(FileManager.default.fileExists(atPath: authority.path))
        #expect(file.counters.snapshot.attachmentAuthorityWrites == 1)
        #expect(file.counters.snapshot.headWrites == 0)
    }

    @Test func saveOverwritesMalformedHeadWithoutReadingItAndAcceptsExistingNonemptyLock() throws {
        // Break caught: applying planner-only tree/lock restrictions or load semantics to ordinary save.
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("attachment-versions.json")
        try Data("malformed old head".utf8).write(to: url)
        let lock = root.appendingPathComponent(".attachment-versions.json.lock")
        try Data([1, 2, 3]).write(to: lock)
        let reader = PublicationOutputRecordingReader()
        try SyncAttachmentPublicationEvidenceFile(url: url, reader: reader).save(.init())
        #expect(reader.paths.isEmpty)
        #expect(try JSONDecoder().decode(SyncAttachmentPublicationEvidence.self, from: Data(contentsOf: url)).allVersions.isEmpty)
        #expect(try Data(contentsOf: lock) == Data([1, 2, 3]))
    }

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

    @Test func noClobberRetryResynchronizesParentAfterPostRenameFailure() throws {
        // Production break caught: a retry that observed EEXIST returned
        // without making the already-renamed destination name directory-durable.
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("authority.json")
        let payload = Data("immutable-authority".utf8)
        var directorySyncAttempts = 0
        var retryDirectoryWasClean = false
        let boundary: (SyncDurableFileWriteBoundary) throws -> Void = { reached in
            guard reached == .beforeDirectorySync else { return }
            directorySyncAttempts += 1
            if directorySyncAttempts == 1 { throw InjectedEvidenceFailure() }
            let entries = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            )
            retryDirectoryWasClean = entries.allSatisfy {
                !$0.lastPathComponent.hasSuffix(".tmp")
            }
        }

        #expect(throws: InjectedEvidenceFailure.self) {
            _ = try SyncDurableFile.createNoClobber(
                payload,
                at: destination,
                beforeBoundary: boundary
            )
        }
        #expect(try Data(contentsOf: destination) == payload)

        #expect(try SyncDurableFile.createNoClobber(
            payload,
            at: destination,
            beforeBoundary: boundary
        ) == false)
        #expect(directorySyncAttempts == 2)
        #expect(retryDirectoryWasClean)
    }

    @Test func watchProofRetryResynchronizesExistingImmutableParentBeforeCompletion() throws {
        // Production break caught: the evidence-file preflight found the proof
        // created by the interrupted attempt and returned success without
        // repairing the proof shard's parent directory durability.
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("attachment-versions.json")
        try SyncAttachmentPublicationEvidenceFile(url: url)
            .save(SyncAttachmentPublicationEvidence())
        let command = WatchCounterCommand(
            id: UUID(), projectID: UUID(), counterID: UUID(),
            operation: .increment, createdAt: Date(timeIntervalSince1970: 1)
        )
        let mutation = try orphanProofMutation(
            command: command,
            rejection: .projectMissing,
            processedAt: Date(timeIntervalSince1970: 2)
        )
        var directorySyncAttempts = 0
        let writer = SyncAttachmentPublicationEvidenceFile(
            url: url,
            beforeDurabilityBoundary: { reached in
                guard reached == .beforeDirectorySync else { return }
                directorySyncAttempts += 1
                if directorySyncAttempts == 1 { throw InjectedEvidenceFailure() }
            }
        )

        #expect(throws: InjectedEvidenceFailure.self) {
            _ = try writer.applying([mutation])
        }
        _ = try writer.applying([mutation])

        #expect(directorySyncAttempts == 2)
        #expect(try SyncAttachmentPublicationEvidenceFile(url: url)
            .watchCommandProof(for: command)?.id == command.id)
    }

    @Test func attachmentAuthorityRetryRepairsParentBeforeCommittingHead() throws {
        // Production break caught: an existing immutable attachment authority
        // skipped parent repair and advanced the mutable head immediately.
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("attachment-versions.json")
        try SyncAttachmentPublicationEvidenceFile(url: url)
            .save(SyncAttachmentPublicationEvidence())
        let attachment = try version(
            slot: .init(
                owner: .init(kind: .project, uuid: UUID()),
                role: "project-photo",
                slotID: "parent-repair"
            ),
            bytes: Data("parent-repair".utf8)
        )
        let mutation = try liveMutation(attachment)
        var directorySyncAttempts = 0
        let writer = SyncAttachmentPublicationEvidenceFile(
            url: url,
            beforeDurabilityBoundary: { reached in
                guard reached == .beforeDirectorySync else { return }
                directorySyncAttempts += 1
                if directorySyncAttempts == 1 { throw InjectedEvidenceFailure() }
            }
        )

        #expect(throws: InjectedEvidenceFailure.self) {
            _ = try writer.applying([mutation])
        }
        _ = try writer.applying([mutation])

        #expect(directorySyncAttempts == 3)
        #expect(try SyncAttachmentPublicationEvidenceFile(url: url)
            .load().allVersions == [attachment])
    }

    @Test func highHistoryWatchProofWriteDoesNotRewriteAttachmentHeadFile() throws {
        // Production break caught: every new orphan proof re-encoded the
        // monolithic attachment/proof sidecar, making write work proportional
        // to all prior Watch proof history.
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("attachment-versions.json")
        let counters = SyncPublicationEvidenceIOCounters()
        let file = SyncAttachmentPublicationEvidenceFile(url: url, counters: counters)
        try file.save(SyncAttachmentPublicationEvidence())

        let history = try (0..<1_024).map { index in
            let command = WatchCounterCommand(
                id: performanceUUID(index),
                projectID: performanceUUID(index + 2_000),
                counterID: performanceUUID(index + 4_000),
                operation: .increment,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
            )
            return try orphanProofMutation(
                command: command,
                rejection: .projectMissing,
                processedAt: Date(timeIntervalSince1970: TimeInterval(index + 10_000))
            )
        }
        _ = try file.applying(history)
        let headBytesBefore = try Data(contentsOf: url)

        let historicalCommand = WatchCounterCommand(
            id: performanceUUID(777),
            projectID: performanceUUID(2_777),
            counterID: performanceUUID(4_777),
            operation: .increment,
            createdAt: Date(timeIntervalSince1970: 778)
        )
        counters.reset()
        #expect(try file.watchCommandProof(for: historicalCommand)?.id
            == historicalCommand.id)
        #expect(counters.snapshot == SyncPublicationEvidenceIOCountSnapshot(
            headReads: 1,
            headWrites: 0,
            watchProofLookups: 1,
            watchProofWrites: 0,
            watchProofDirectoryEnumerations: 0,
            attachmentAuthorityLookups: 0,
            attachmentAuthorityWrites: 0,
            attachmentAuthorityDirectoryEnumerations: 0
        ))

        let nextCommand = WatchCounterCommand(
            id: performanceUUID(10_000),
            projectID: performanceUUID(10_001),
            counterID: performanceUUID(10_002),
            operation: .increment,
            createdAt: Date(timeIntervalSince1970: 20_000)
        )
        counters.reset()
        _ = try file.applying([try orphanProofMutation(
            command: nextCommand,
            rejection: .counterMissing,
            processedAt: Date(timeIntervalSince1970: 20_001)
        )])

        #expect(try Data(contentsOf: url) == headBytesBefore)
        #expect(counters.snapshot == SyncPublicationEvidenceIOCountSnapshot(
            headReads: 1,
            headWrites: 0,
            watchProofLookups: 2,
            watchProofWrites: 1,
            watchProofDirectoryEnumerations: 0,
            attachmentAuthorityLookups: 0,
            attachmentAuthorityWrites: 0,
            attachmentAuthorityDirectoryEnumerations: 0
        ))
    }

    @Test func attachmentHeadFileRetainsOnlyBoundedActiveHeads() throws {
        // Production break caught: the mutable sidecar retained and rewrote
        // every full historical attachment record instead of moving immutable
        // versions to per-version authority files.
        struct EvidenceEnvelope: Decodable {
            let versions: [SyncAttachmentVersion]
            let attachmentRecords: [SyncRecord]
        }

        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("attachment-versions.json")
        let file = SyncAttachmentPublicationEvidenceFile(url: url)
        let slot = SyncAttachmentSlot(
            owner: .init(kind: .project, uuid: UUID()),
            role: "project-photo",
            slotID: "bounded-head"
        )
        var predecessor: UUID?
        var mutations: [SyncMutation] = []
        for index in 0..<128 {
            let attachment = try version(
                slot: slot,
                bytes: Data("version-\(index)".utf8),
                replacing: predecessor
            )
            mutations.append(try liveMutation(attachment))
            predecessor = attachment.versionID
        }

        _ = try file.applying(mutations)

        let persisted = try JSONDecoder().decode(
            EvidenceEnvelope.self,
            from: Data(contentsOf: url)
        )
        #expect(persisted.versions.count == 1)
        #expect(persisted.attachmentRecords.count == 1)
        #expect(persisted.versions.first?.versionID == predecessor)
        #expect(try file.load().allVersions.count == 128)
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

    @Test func tombstonedAncestorRemainsReservedAfterChildAndRestart() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = SyncAttachmentPublicationEvidenceFile(
            url: root.appendingPathComponent("attachment-versions.json")
        )
        let slot = SyncAttachmentSlot(
            owner: .init(kind: .project, uuid: UUID()),
            role: "project-photo",
            slotID: "replacement-after-delete"
        )
        let first = try version(slot: slot, bytes: Data("first".utf8))
        let child = try version(
            slot: slot,
            bytes: Data("child".utf8),
            replacing: first.versionID
        )
        _ = try file.applying([try liveMutation(first)])
        _ = try file.applying([try tombstoneMutation(first)])
        _ = try file.applying([try liveMutation(child)])

        let restartedFile = SyncAttachmentPublicationEvidenceFile(url: file.url)
        let restarted = try restartedFile.load()
        #expect(restarted.isDeleted(first.versionID))
        let bytesBefore = try Data(contentsOf: file.url)
        #expect(throws: SyncPublicationTransactionFileError.corrupt) {
            _ = try restartedFile.applying([try liveMutation(first)])
        }
        #expect(try Data(contentsOf: file.url) == bytesBefore)
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

    @Test func authorizedBareAttachmentDeleteInstallsRestartSafeTombstone() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = SyncAttachmentPublicationEvidenceFile(
            url: root.appendingPathComponent("attachment-versions.json")
        )
        let issued = try version(
            slot: .init(
                owner: .init(kind: .project, uuid: UUID()),
                role: "project-photo",
                slotID: "bare-delete"
            ),
            bytes: Data("bare-delete".utf8)
        )
        _ = try file.applying([try liveMutation(issued)])

        _ = try file.applying([.delete(
            .init(kind: .attachment, uuid: issued.versionID),
            mutationID: UUID()
        )])

        let restarted = try SyncAttachmentPublicationEvidenceFile(url: file.url).load()
        #expect(restarted.isDeleted(issued.versionID))
        #expect(restarted.record(for: issued.slot)?.payload.attachment == issued)
    }

    @Test func transactionFormatsTwoThreeAndFourRetainTheirValidatedBytesAndNoCanonicalClaim() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = SyncPublicationTransactionFile(
            archiveURL: root.appendingPathComponent("projects.json")
        )
        let deletionLedgerID = compatibilityUUID(30)
        let restorationWitness = SyncRestorationWitness(
            entryID: compatibilityUUID(31),
            attemptID: compatibilityUUID(32),
            beforeArchiveSHA256: Data(repeating: 3, count: 32)
        )
        let fixtures = [
            try compatibilityTransactionData(version: 2),
            try compatibilityTransactionData(version: 3),
            try compatibilityTransactionData(
                version: 4,
                candidateAttachmentManifest: [],
                deletionLedgerID: deletionLedgerID
            ),
            try compatibilityTransactionData(
                version: 4,
                candidateAttachmentManifest: [],
                restorationWitness: restorationWitness
            )
        ]

        var decoded: [SyncPublicationTransaction] = []
        for bytes in fixtures {
            try bytes.write(to: file.url)
            let loaded = try file.load()
            decoded.append(try #require(loaded))
        }

        #expect(decoded.map(\.version) == [2, 3, 4, 4])
        #expect(decoded.allSatisfy { $0.canonicalTransition == nil })
        #expect(decoded[2].candidateAttachmentManifest == [])
        #expect(decoded[2].deletionLedgerID == deletionLedgerID)
        #expect(decoded[3].candidateAttachmentManifest == [])
        #expect(decoded[3].restorationWitness == restorationWitness)
    }

    private func compatibilityTransactionData(
        version: Int,
        candidateAttachmentManifest: [SyncAttachmentManifestEntry]? = nil,
        deletionLedgerID: UUID? = nil,
        restorationWitness: SyncRestorationWitness? = nil
    ) throws -> Data {
        let entityID = SyncEntityID(kind: .project, uuid: compatibilityUUID(33))
        let mutationID = compatibilityUUID(34)
        let mutations: [SyncMutation] = version == 4
            ? []
            : [.delete(entityID, mutationID: mutationID)]
        let receipts = version == 2
            ? []
            : mutations.map {
                SyncRevisionReceipt(
                    entityID: $0.recordID,
                    mutationID: $0.mutationID,
                    logicalRevision: 1,
                    deviceID: "compatibility-device"
                )
            }
        let expectedArchiveSHA256 = Data(repeating: UInt8(version), count: 32)
        let integrity = try compatibilityIntegrity(
            version: version,
            expectedArchiveSHA256: expectedArchiveSHA256,
            mutations: mutations,
            revisionReceipts: receipts,
            candidateAttachmentManifest: candidateAttachmentManifest,
            deletionLedgerID: deletionLedgerID,
            restorationWitness: restorationWitness
        )
        let wire = PublicationTransactionCompatibilityWire(
            version: version,
            expectedArchiveSHA256: expectedArchiveSHA256,
            commitBoundary: .archive,
            artifactEvidence: [],
            mutations: mutations,
            revisionReceipts: receipts,
            candidateAttachmentManifest: candidateAttachmentManifest,
            deletionLedgerID: deletionLedgerID,
            restorationWitness: restorationWitness,
            integrity: integrity
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(wire)
    }

    private func compatibilityIntegrity(
        version: Int,
        expectedArchiveSHA256: Data,
        mutations: [SyncMutation],
        revisionReceipts: [SyncRevisionReceipt],
        candidateAttachmentManifest: [SyncAttachmentManifestEntry]?,
        deletionLedgerID: UUID?,
        restorationWitness: SyncRestorationWitness?
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes: Data
        switch version {
        case 2:
            bytes = try encoder.encode(PublicationTransactionV2IntegrityFixture(
                version: version,
                expectedArchiveSHA256: expectedArchiveSHA256,
                commitBoundary: .archive,
                artifactEvidence: [],
                mutations: mutations
            ))
        case 3:
            bytes = try encoder.encode(PublicationTransactionV3IntegrityFixture(
                version: version,
                expectedArchiveSHA256: expectedArchiveSHA256,
                commitBoundary: .archive,
                artifactEvidence: [],
                mutations: mutations,
                revisionReceipts: revisionReceipts
            ))
        default:
            bytes = try encoder.encode(PublicationTransactionV4IntegrityFixture(
                version: version,
                expectedArchiveSHA256: expectedArchiveSHA256,
                commitBoundary: .archive,
                artifactEvidence: [],
                mutations: mutations,
                revisionReceipts: revisionReceipts,
                candidateAttachmentManifest: candidateAttachmentManifest,
                deletionLedgerID: deletionLedgerID,
                restorationWitness: restorationWitness
            ))
        }
        return Data(SHA256.hash(data: bytes))
    }

    private func compatibilityUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(
            format: "00000000-0000-0000-0000-%012x",
            value
        ))!
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
            logicalRevision: 2,
            modifiedAt: Date(timeIntervalSince1970: 2),
            deviceID: "evidence-test"
        )
        let record = SyncRecord(
            schemaVersion: 1,
            id: .init(kind: .attachment, uuid: version.versionID),
            createdAt: Date(timeIntervalSince1970: 1),
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

    private func performanceUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(
            format: "00000000-0000-0000-0000-%012x",
            value + 1
        ))!
    }
}

private struct InjectedEvidenceFailure: Error {}

private final class PublicationOutputRecordingReader: SyncRegularFileReading, @unchecked Sendable {
    private let mutex = NSLock()
    private var recorded: [URL] = []
    var paths: [URL] { mutex.withLock { recorded } }
    func read(_ url: URL, maximumBytes: Int, expected: SyncRegularFileExpectation?) throws -> SyncRegularFileRead {
        mutex.withLock { recorded.append(url) }
        return try SyncRegularFileReader().read(url, maximumBytes: maximumBytes, expected: expected)
    }
    func observe(_ url: URL, declaredByteCount: Int64, maximumBytes: Int) throws -> SyncRegularFileObservation {
        try SyncRegularFileReader().observe(url, declaredByteCount: declaredByteCount, maximumBytes: maximumBytes)
    }
}

private struct PublicationTransactionCompatibilityWire: Codable {
    let version: Int
    let expectedArchiveSHA256: Data
    let commitBoundary: SyncPublicationCommitBoundary
    let artifactEvidence: [SyncPublicationArtifactEvidence]
    let mutations: [SyncMutation]
    let revisionReceipts: [SyncRevisionReceipt]
    let candidateAttachmentManifest: [SyncAttachmentManifestEntry]?
    let deletionLedgerID: UUID?
    let restorationWitness: SyncRestorationWitness?
    let integrity: Data
}

private struct PublicationTransactionV2IntegrityFixture: Codable {
    let version: Int
    let expectedArchiveSHA256: Data
    let commitBoundary: SyncPublicationCommitBoundary
    let artifactEvidence: [SyncPublicationArtifactEvidence]
    let mutations: [SyncMutation]
}

private struct PublicationTransactionV3IntegrityFixture: Codable {
    let version: Int
    let expectedArchiveSHA256: Data
    let commitBoundary: SyncPublicationCommitBoundary
    let artifactEvidence: [SyncPublicationArtifactEvidence]
    let mutations: [SyncMutation]
    let revisionReceipts: [SyncRevisionReceipt]
}

private struct PublicationTransactionV4IntegrityFixture: Codable {
    let version: Int
    let expectedArchiveSHA256: Data
    let commitBoundary: SyncPublicationCommitBoundary
    let artifactEvidence: [SyncPublicationArtifactEvidence]
    let mutations: [SyncMutation]
    let revisionReceipts: [SyncRevisionReceipt]
    let candidateAttachmentManifest: [SyncAttachmentManifestEntry]?
    let deletionLedgerID: UUID?
    let restorationWitness: SyncRestorationWitness?
}
