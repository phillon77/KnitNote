import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KnitNoteCore

@Suite(.serialized) @MainActor struct JSONProjectStoreSyncPublicationTests {
    @Test func reminderPublicationUsesOnlyItsCounterAggregateAuthority() throws {
        let fixture = try SyncPublicationFixture()
        let sink = RecordingSyncMutationSink()
        let store = fixture.store(sink: sink)
        let counterID = try #require(store.project(id: fixture.projectID)?.counters.first?.id)

        let reminderID = try store.addKnittingReminder(
            projectID: fixture.projectID,
            draft: .oneTime(kind: .changeYarn, target: 3, text: "Change yarn"),
            now: Date(timeIntervalSince1970: 3)
        )

        let saved = sink.mutations.compactMap(\.savedRecordVersion?.record)
        #expect(!saved.contains { $0.id.kind == .knittingReminder })
        let counterRecord = try #require(saved.last { record in
            record.id == SyncEntityID(kind: .projectCounter, uuid: counterID)
        })
        guard case let .projectCounter(state)? = counterRecord.payload.atomicDomain?.value else {
            Issue.record("Counter publication did not contain the aggregate state")
            return
        }
        #expect(state.counter.id == counterID)
        #expect(state.reminder?.id == reminderID)
    }

    @Test func multipleRemindersOnOneCounterPublishAndRestartWithoutLoss() throws {
        let fixture = try SyncPublicationFixture()
        let firstSink = RecordingSyncMutationSink()
        let firstStore = fixture.store(sink: firstSink)
        let counterID = try #require(
            firstStore.project(id: fixture.projectID)?.counters.first?.id
        )
        let firstID = try firstStore.addKnittingReminder(
            projectID: fixture.projectID,
            draft: .oneTime(kind: .cable, target: 4, text: "Cable"),
            now: Date(timeIntervalSince1970: 4)
        )
        let secondID = try firstStore.addKnittingReminder(
            projectID: fixture.projectID,
            draft: .oneTime(kind: .measure, target: 8, text: "Measure"),
            now: Date(timeIntervalSince1970: 5)
        )
        let firstRecord = try #require(firstSink.mutations.compactMap(
            \.savedRecordVersion?.record
        ).last { $0.id == .init(kind: .projectCounter, uuid: counterID) })
        guard case let .projectCounter(firstState)? = firstRecord.payload.atomicDomain?.value else {
            Issue.record("Missing counter aggregate")
            return
        }
        #expect(firstState.reminders.map(\.id) == [firstID, secondID].sorted {
            $0.uuidString < $1.uuidString
        })

        let restartedSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: restartedSink)
        let thirdID = try restarted.addKnittingReminder(
            projectID: fixture.projectID,
            draft: .oneTime(kind: .changeYarn, target: 12, text: "Yarn"),
            now: Date(timeIntervalSince1970: 6)
        )
        let restartedRecord = try #require(restartedSink.mutations.compactMap(
            \.savedRecordVersion?.record
        ).last { $0.id == .init(kind: .projectCounter, uuid: counterID) })
        guard case let .projectCounter(restartedState)? =
            restartedRecord.payload.atomicDomain?.value else {
            Issue.record("Missing restarted counter aggregate")
            return
        }
        #expect(Set(restartedState.reminders.map(\.id)) == [firstID, secondID, thirdID])
        #expect(restarted.project(id: fixture.projectID)?.knittingReminders.count == 3)
    }

    @Test func durableWatchCommandPublishesPreparedThenLedgerAndRestoresItAfterRestart() throws {
        let fixture = try SyncPublicationFixture()
        let sink = RecordingSyncMutationSink()
        let store = fixture.store(sink: sink)
        let counterID = try #require(store.project(id: fixture.projectID)?.counters.first?.id)
        let command = WatchCounterCommand(
            id: UUID(), projectID: fixture.projectID, counterID: counterID,
            operation: .increment, createdAt: Date(timeIntervalSince1970: 10)
        )
        let ledgerURL = WatchSyncPaths.processedLedger(in: fixture.liveRoot)
        let preparedURL = WatchSyncPaths.preparedCommand(in: fixture.liveRoot)

        _ = try store.applyWatchCommandDurably(
            command, ledgerURL: ledgerURL, preparedCommandURL: preparedURL,
            now: Date(timeIntervalSince1970: 11)
        )
        let secondCommand = WatchCounterCommand(
            id: UUID(), projectID: fixture.projectID, counterID: counterID,
            operation: .increment, createdAt: Date(timeIntervalSince1970: 12)
        )
        _ = try store.applyWatchCommandDurably(
            secondCommand, ledgerURL: ledgerURL, preparedCommandURL: preparedURL,
            now: Date(timeIntervalSince1970: 13)
        )
        let processedIDs: Set<UUID> = [command.id, secondCommand.id]

        let states = sink.mutations.compactMap(\.savedRecordVersion?.record)
            .filter { $0.id == .init(kind: .projectCounter, uuid: counterID) }
            .compactMap(\.counterReminderState)
        #expect(states.contains { $0.preparedCommand?.command.id == command.id })
        #expect(states.last?.preparedCommand == nil)
        #expect(states.last?.processedCommandIDs == processedIDs)
        #expect(Set(states.last?.processedCommandProofs.map(\.id) ?? []) == processedIDs)
        let ledger = try #require(try AtomicWatchSyncFile<ProcessedWatchCommandLedger>(
            url: ledgerURL
        ).load())
        #expect(ledger.entry(for: command.id)?.preparedCommand?.command == command)
        #expect(ledger.entry(for: command.id)?.effectProof?.counter.value == 1)
        #expect(ledger.entry(for: secondCommand.id)?.effectProof?.counter.value == 2)

        // The synchronized aggregate sidecar, rather than this prunable local
        // ledger, must remain sufficient to republish exactly-once evidence.
        try FileManager.default.removeItem(at: ledgerURL)

        let restartedSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: restartedSink)
        #expect(try restarted.recoverWatchCommandPersistence(
            ledgerURL: ledgerURL, preparedCommandURL: preparedURL,
            now: Date(timeIntervalSince1970: 14)
        ) == .ready)
        let restored = restartedSink.mutations.compactMap(\.savedRecordVersion?.record)
            .last { $0.id == .init(kind: .projectCounter, uuid: counterID) }?
            .counterReminderState
        #expect(restored?.processedCommandIDs == processedIDs)
        #expect(Set(restored?.processedCommandProofs.map(\.id) ?? []) == processedIDs)
        #expect(restored?.preparedCommand == nil)

        let counterPublicationCount = restartedSink.mutations.filter {
            $0.recordID == .init(kind: .projectCounter, uuid: counterID)
        }.count
        _ = try restarted.incrementCounter(
            projectID: fixture.projectID,
            counterID: counterID
        )
        let afterOrdinaryMutation = restartedSink.mutations.compactMap(
            \.savedRecordVersion?.record
        ).last { $0.id == .init(kind: .projectCounter, uuid: counterID) }?
            .counterReminderState
        #expect(restartedSink.mutations.filter {
            $0.recordID == .init(kind: .projectCounter, uuid: counterID)
        }.count > counterPublicationCount)
        #expect(afterOrdinaryMutation?.processedCommandIDs == processedIDs)
        #expect(afterOrdinaryMutation?.counter.value == 3)
    }

    @Test func durableWatchRejectionPublishesTransferableProofAndSurvivesLedgerDeletion() throws {
        let fixture = try SyncPublicationFixture()
        let sink = RecordingSyncMutationSink()
        let store = fixture.store(sink: sink)
        let counterID = try #require(store.project(id: fixture.projectID)?.counters.first?.id)
        let command = WatchCounterCommand(
            id: UUID(), projectID: fixture.projectID, counterID: counterID,
            operation: .increment, createdAt: Date(timeIntervalSince1970: 20)
        )
        let ledgerURL = WatchSyncPaths.processedLedger(in: fixture.liveRoot)

        let acknowledgement = try store.acknowledgeRejectedWatchCommandDurably(
            command,
            rejection: .entitlementRequired,
            entitlement: .trial(
                startedAt: Date(timeIntervalSince1970: 1),
                expiresAt: Date(timeIntervalSince1970: 2)
            ),
            ledgerURL: ledgerURL,
            now: Date(timeIntervalSince1970: 21)
        )

        #expect(acknowledgement.rejection == .entitlementRequired)
        let ledger = try #require(try AtomicWatchSyncFile<ProcessedWatchCommandLedger>(
            url: ledgerURL
        ).load())
        #expect(ledger.entry(for: command.id)?.commandIdentity == .init(command))
        let published = try #require(sink.mutations.compactMap(
            \.savedRecordVersion?.record
        ).last { $0.id == .init(kind: .projectCounter, uuid: counterID) }?
            .counterReminderState)
        let proof = try #require(published.processedCommandProofs.first {
            $0.id == command.id
        })
        #expect(proof.commandIdentity == .init(command))
        #expect(proof.rejection == .entitlementRequired)
        #expect(proof.effectProof == nil)

        try FileManager.default.removeItem(at: ledgerURL)
        let restartedSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: restartedSink)
        _ = try restarted.incrementCounter(
            projectID: fixture.projectID,
            counterID: counterID
        )
        let republished = try #require(restartedSink.mutations.compactMap(
            \.savedRecordVersion?.record
        ).last { $0.id == .init(kind: .projectCounter, uuid: counterID) }?
            .counterReminderState)
        #expect(republished.processedCommandIDs.contains(command.id))
        #expect(republished.processedCommandProofs.first {
            $0.id == command.id
        }?.commandIdentity == .init(command))
    }

    @Test func missingProjectWatchRejectionPublishesAStandaloneProof() throws {
        // Production break caught: a projector that only walks extant counters
        // drops a durable project-missing rejection, leaving a fresh device
        // unable to validate the exact acknowledgement after ledger pruning.
        let command = WatchCounterCommand(
            id: UUID(),
            projectID: UUID(),
            counterID: UUID(),
            operation: .increment,
            createdAt: Date(timeIntervalSince1970: 40)
        )
        let proof = try SyncProcessedWatchCommandProof(
            id: command.id,
            rejection: .projectMissing,
            commandIdentity: .init(command),
            preparedCommand: nil,
            effectProof: nil,
            processingStamp: .init(
                logicalRevision: 0,
                modifiedAt: Date(timeIntervalSince1970: 41),
                deviceID: "orphan-proof-test"
            )
        )
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [])
        let projector = SyncPublicationProjector(
            deviceID: "orphan-proof-test",
            processedWatchProofs: [proof],
            reusing: .init(archive: archive, records: [:]),
            attachmentReferences: { _ in [] },
            issuedAttachmentVersions: [:]
        )

        let projected = try projector.project(before: archive, after: archive, manifest: [:])

        let published = try #require(projected.mutations.compactMap(\.savedRecordVersion?.record)
            .first { $0.id == .init(kind: .watchCommandProof, uuid: command.id) })
        #expect(published.payload.atomicDomain?.value == .orphanWatchCommandProof(
            try SyncOrphanWatchCommandProof(proof: proof)
        ))
    }

    @Test func missingCounterWatchRejectionPublishesAStandaloneProof() throws {
        // Production break caught: a counter-missing acknowledgement otherwise
        // remains only in the prunable ledger because no counter aggregate
        // exists to carry it.
        let projectID = UUID()
        let command = WatchCounterCommand(
            id: UUID(),
            projectID: projectID,
            counterID: UUID(),
            operation: .increment,
            createdAt: Date(timeIntervalSince1970: 43)
        )
        let proof = try SyncProcessedWatchCommandProof(
            id: command.id,
            rejection: .counterMissing,
            commandIdentity: .init(command),
            preparedCommand: nil,
            effectProof: nil,
            processingStamp: .init(
                logicalRevision: 0,
                modifiedAt: Date(timeIntervalSince1970: 44),
                deviceID: "orphan-proof-test"
            )
        )
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [])
        let projector = SyncPublicationProjector(
            deviceID: "orphan-proof-test",
            processedWatchProofs: [proof],
            reusing: .init(archive: archive, records: [:]),
            attachmentReferences: { _ in [] },
            issuedAttachmentVersions: [:]
        )

        let projected = try projector.project(before: archive, after: archive, manifest: [:])
        let published = try #require(projected.mutations.compactMap(\.savedRecordVersion?.record)
            .first { $0.id == .init(kind: .watchCommandProof, uuid: command.id) })
        #expect(published.payload.atomicDomain?.value == .orphanWatchCommandProof(
            try SyncOrphanWatchCommandProof(proof: proof)
        ))
    }

    @Test func orphanProofReusesOriginatingProcessingStampAcrossProjectors() throws {
        // Production break caught: rebuilding an orphan record with the current
        // projector device rewrites immutable provenance after transfer.
        let command = WatchCounterCommand(
            id: UUID(),
            projectID: UUID(),
            counterID: UUID(),
            operation: .increment,
            createdAt: Date(timeIntervalSince1970: 44)
        )
        let processedAt = Date(timeIntervalSince1970: 45)
        var ledger = ProcessedWatchCommandLedger()
        ledger.record(
            command.id,
            rejection: .projectMissing,
            command: command,
            at: processedAt
        )
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [])
        let originProjection = try SyncPublicationProjector(
            deviceID: "originating-device",
            processedWatchLedger: ledger,
            reusing: .init(archive: archive, records: [:]),
            attachmentReferences: { _ in [] },
            issuedAttachmentVersions: [:]
        ).project(before: archive, after: archive, manifest: [:])
        let originRecord = try #require(originProjection.mutations
            .compactMap(\.savedRecordVersion?.record)
            .first { $0.id == .init(kind: .watchCommandProof, uuid: command.id) })
        guard case let .orphanWatchCommandProof(originAuthority)? =
                originRecord.payload.atomicDomain?.value else {
            Issue.record("Missing originating orphan proof")
            return
        }

        let freshProjection = try SyncPublicationProjector(
            deviceID: "fresh-device",
            processedWatchProofs: [originAuthority.proof],
            reusing: .init(archive: archive, records: [:]),
            attachmentReferences: { _ in [] },
            issuedAttachmentVersions: [:]
        ).project(before: archive, after: archive, manifest: [:])
        let freshRecord = try #require(freshProjection.mutations
            .compactMap(\.savedRecordVersion?.record)
            .first { $0.id == originRecord.id })

        #expect(originRecord.payload.atomicDomain?.stamp.modifiedAt == processedAt)
        #expect(originRecord.payload.atomicDomain?.stamp.deviceID == "originating-device")
        #expect(freshRecord.payload.atomicDomain?.stamp == originRecord.payload.atomicDomain?.stamp)
    }

    @Test func unchangedOrphanAuthorityReusesItsCausallyStampedCacheRecord() throws {
        // Production break caught: regenerating a canonical revision-zero
        // orphan over a causally stamped cache republishes unchanged metadata.
        let command = WatchCounterCommand(
            id: UUID(), projectID: UUID(), counterID: UUID(),
            operation: .increment, createdAt: Date(timeIntervalSince1970: 45)
        )
        let proof = try makeOrphanWatchProof(
            command: command,
            rejection: .projectMissing,
            processedAt: Date(timeIntervalSince1970: 46),
            deviceID: "originating-device"
        )
        let publicationStamp = SyncMutationStamp(
            logicalRevision: 7,
            modifiedAt: Date(timeIntervalSince1970: 46),
            deviceID: "publishing-device"
        )
        let recordID = SyncEntityID(kind: .watchCommandProof, uuid: command.id)
        let cachedRecord = SyncRecord(
            schemaVersion: 1,
            id: recordID,
            createdAt: command.createdAt,
            entityRevision: publicationStamp.logicalRevision,
            payload: .init(
                fields: [:],
                atomicDomain: .init(
                    value: .orphanWatchCommandProof(
                        try SyncOrphanWatchCommandProof(proof: proof)
                    ),
                    stamp: publicationStamp
                )
            ),
            relationships: [],
            deletedAt: .init(value: nil, stamp: publicationStamp)
        )
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [])

        let projected = try SyncPublicationProjector(
            deviceID: "fresh-device",
            processedWatchProofs: [proof],
            reusing: .init(archive: archive, records: [recordID: cachedRecord]),
            attachmentReferences: { _ in [] },
            issuedAttachmentVersions: [:]
        ).project(before: archive, after: archive, manifest: [:])

        #expect(projected.mutations.isEmpty)
        #expect(projected.cache.records[recordID] == cachedRecord)
    }

    @Test func legacyNonMissingProofWithoutProcessingStampSurvivesRestartedPublication() throws {
        // Production break caught: synthesizing a processing stamp for every
        // legacy ledger proof makes it diverge from the identical unstamped
        // non-missing proof in durable evidence and blocks the next publication.
        let fixture = try SyncPublicationFixture()
        let counter = try #require(try fixture.archive().projects.first?.counters.first)
        let legacyCommand = WatchCounterCommand(
            schemaVersion: 2,
            id: UUID(),
            projectID: fixture.projectID,
            counterID: counter.id,
            operation: .increment,
            createdAt: Date(timeIntervalSince1970: 45)
        )
        let legacyProof = try SyncProcessedWatchCommandProof(
            id: legacyCommand.id,
            rejection: .unsupportedSchema,
            commandIdentity: .init(legacyCommand),
            preparedCommand: nil,
            effectProof: nil
        )
        #expect(legacyProof.processingStamp == nil)

        let ledgerURL = WatchSyncPaths.processedLedger(in: fixture.liveRoot)
        var legacyLedger = ProcessedWatchCommandLedger()
        legacyLedger.record(
            legacyCommand.id,
            rejection: .unsupportedSchema,
            command: legacyCommand,
            at: Date(timeIntervalSince1970: 46)
        )
        try AtomicWatchSyncFile<ProcessedWatchCommandLedger>(url: ledgerURL)
            .save(legacyLedger)
        let evidenceURL = fixture.liveRoot
            .appendingPathComponent("SyncMetadata", isDirectory: true)
            .appendingPathComponent("attachment-versions.json")
        try SyncAttachmentPublicationEvidenceFile(url: evidenceURL).save(.init(
            watchCommandProofs: [legacyProof]
        ))
        #expect(try String(decoding: Data(contentsOf: ledgerURL), as: UTF8.self)
            .contains("processingStamp") == false)
        #expect(try String(decoding: Data(contentsOf: evidenceURL), as: UTF8.self)
            .contains("processingStamp") == false)

        let sink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: sink)
        let missingTargetCommand = WatchCounterCommand(
            id: UUID(),
            projectID: fixture.projectID,
            counterID: UUID(),
            operation: .increment,
            createdAt: Date(timeIntervalSince1970: 47)
        )
        let acknowledgement = try restarted.applyWatchCommandDurably(
            missingTargetCommand,
            ledgerURL: ledgerURL,
            preparedCommandURL: WatchSyncPaths.preparedCommand(in: fixture.liveRoot),
            now: Date(timeIntervalSince1970: 48)
        )

        #expect(acknowledgement.rejection == .counterMissing)
        let aggregate = try #require(sink.mutations.compactMap(\.savedRecordVersion?.record)
            .first { $0.id == .init(kind: .projectCounter, uuid: counter.id) }?
            .counterReminderState)
        #expect(aggregate.processedCommandProofs.first {
            $0.id == legacyCommand.id
        }?.processingStamp == nil)
        let durableEvidence = try SyncAttachmentPublicationEvidenceFile(url: evidenceURL).load()
        #expect(try durableEvidence.watchCommandProof(for: legacyCommand)?.processingStamp == nil)
        #expect(try durableEvidence.watchCommandProof(for: missingTargetCommand)?
            .processingStamp != nil)
    }

    @Test func missingTargetProofStillRequiresImmutableProcessingStamp() {
        let command = WatchCounterCommand(
            id: UUID(),
            projectID: UUID(),
            counterID: UUID(),
            operation: .increment,
            createdAt: Date(timeIntervalSince1970: 49)
        )

        #expect(throws: SyncRecordVersionError.corrupt) {
            _ = try SyncProcessedWatchCommandProof(
                id: command.id,
                rejection: .counterMissing,
                commandIdentity: .init(command),
                preparedCommand: nil,
                effectProof: nil
            )
        }
    }

    @Test func standaloneOrphanProofRemainsWhenItsCounterReappears() throws {
        // Production break caught: treating a reappeared counter as the new
        // owner deletes the standalone missing-target authority.
        let projectID = UUID()
        let counterID = UUID()
        let command = WatchCounterCommand(
            id: UUID(), projectID: projectID, counterID: counterID,
            operation: .increment, createdAt: Date(timeIntervalSince1970: 46)
        )
        let proof = try SyncProcessedWatchCommandProof(
            id: command.id,
            rejection: .counterMissing,
            commandIdentity: .init(command),
            preparedCommand: nil,
            effectProof: nil,
            processingStamp: .init(
                logicalRevision: 0,
                modifiedAt: Date(timeIntervalSince1970: 47),
                deviceID: "originating-device"
            )
        )
        let project = try StoredProject(
            id: projectID,
            name: "Reappeared",
            counters: [ProjectCounter(id: counterID, defaultOrdinal: 1)]
        )
        let archive = ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: [project]
        )
        let projection = try SyncPublicationProjector(
            deviceID: "fresh-device",
            processedWatchProofs: [proof],
            reusing: .init(archive: archive, records: [:]),
            attachmentReferences: { _ in [] },
            issuedAttachmentVersions: [:]
        ).project(before: archive, after: archive, manifest: [:])
        let saved = projection.mutations.compactMap(\.savedRecordVersion?.record)

        let orphan = try #require(saved.first {
            $0.id == .init(kind: .watchCommandProof, uuid: command.id)
        })
        let aggregate = try #require(saved.first {
            $0.id == .init(kind: .projectCounter, uuid: counterID)
        }?.counterReminderState)
        #expect(orphan.payload.atomicDomain?.value == .orphanWatchCommandProof(
            try SyncOrphanWatchCommandProof(proof: proof)
        ))
        #expect(aggregate.processedCommandProofs == [proof])
    }

    @Test func nonDurableWatchEvaluationHonorsFreshDeviceOrphanAuthority() throws {
        // Production break caught: the in-memory Watch entry point consults only
        // the prunable ledger and can execute after a durable orphan proof moves
        // to a fresh device where the target now exists.
        let fixture = try SyncPublicationFixture()
        let archive = try fixture.archive()
        let counterID = try #require(archive.projects.first?.counters.first?.id)
        let command = WatchCounterCommand(
            id: UUID(), projectID: fixture.projectID, counterID: counterID,
            operation: .increment, createdAt: Date(timeIntervalSince1970: 48)
        )
        let proof = try makeOrphanWatchProof(
            command: command,
            rejection: .counterMissing,
            processedAt: Date(timeIntervalSince1970: 49),
            deviceID: "originating-device"
        )
        try installOrphanWatchProof(proof, in: fixture.liveRoot)
        let store = fixture.store(sink: RecordingSyncMutationSink())
        var ledger = ProcessedWatchCommandLedger()

        let acknowledgement = try store.applyWatchCommand(
            command,
            ledger: &ledger,
            now: Date(timeIntervalSince1970: 50)
        )

        #expect(acknowledgement.rejection == .counterMissing)
        #expect(store.project(id: fixture.projectID)?.counters.first?.value == 0)
        #expect(ledger.entry(for: command.id)?.commandIdentity == .init(command))
    }

    @Test func alreadyLoadedStoreReloadsDurableOrphanAuthorityBeforeEvaluation() throws {
        // Production break caught: another synchronized writer can publish an
        // orphan after this store starts; a startup-only snapshot is stale.
        let fixture = try SyncPublicationFixture()
        let store = fixture.store(sink: RecordingSyncMutationSink())
        let counterID = try #require(store.project(id: fixture.projectID)?.counters.first?.id)
        let command = WatchCounterCommand(
            id: UUID(), projectID: fixture.projectID, counterID: counterID,
            operation: .increment, createdAt: Date(timeIntervalSince1970: 50)
        )
        let proof = try makeOrphanWatchProof(
            command: command,
            rejection: .counterMissing,
            processedAt: Date(timeIntervalSince1970: 51),
            deviceID: "originating-device"
        )
        try installOrphanWatchProof(proof, in: fixture.liveRoot)
        var ledger = ProcessedWatchCommandLedger()

        let acknowledgement = try store.applyWatchCommand(
            command,
            ledger: &ledger,
            now: Date(timeIntervalSince1970: 52)
        )

        #expect(acknowledgement.rejection == .counterMissing)
        #expect(store.project(id: fixture.projectID)?.counters.first?.value == 0)
        #expect(ledger.entry(for: command.id)?.processingStamp == proof.processingStamp)
    }

    @Test func everyWatchEntryPointRejectsOrphanIdentityOrOutcomeDivergence() throws {
        let fixture = try SyncPublicationFixture()
        let counterID = try #require(try fixture.archive().projects.first?.counters.first?.id)
        let command = WatchCounterCommand(
            id: UUID(), projectID: fixture.projectID, counterID: counterID,
            operation: .increment, createdAt: Date(timeIntervalSince1970: 50)
        )
        let proof = try makeOrphanWatchProof(
            command: command,
            rejection: .counterMissing,
            processedAt: Date(timeIntervalSince1970: 51),
            deviceID: "originating-device"
        )
        try installOrphanWatchProof(proof, in: fixture.liveRoot)
        let store = fixture.store(sink: RecordingSyncMutationSink())
        let divergentIdentity = WatchCounterCommand(
            id: command.id,
            projectID: command.projectID,
            counterID: UUID(),
            operation: command.operation,
            createdAt: command.createdAt
        )
        var emptyLedger = ProcessedWatchCommandLedger()

        #expect(throws: SyncPublicationTransactionFileError.corrupt) {
            _ = try store.applyWatchCommand(divergentIdentity, ledger: &emptyLedger)
        }

        var divergentLedger = ProcessedWatchCommandLedger()
        divergentLedger.record(
            command.id,
            rejection: .projectMissing,
            command: command,
            processingStamp: proof.processingStamp,
            at: try #require(proof.processingStamp?.modifiedAt)
        )
        #expect(throws: SyncPublicationTransactionFileError.corrupt) {
            _ = try store.applyWatchCommand(
                command,
                entitlement: .permanentlyUnlocked,
                ledger: &divergentLedger
            )
        }
        #expect(store.project(id: fixture.projectID)?.counters.first?.value == 0)
    }

    @Test func preparedCommandRecoveryConsultsOrphanAuthorityBeforeEvaluation() throws {
        // Production break caught: recovery is also a Watch evaluation path;
        // transferred authority must win over a locally prepared command.
        let fixture = try SyncPublicationFixture()
        let counter = try #require(try fixture.archive().projects.first?.counters.first)
        let command = WatchCounterCommand(
            id: UUID(), projectID: fixture.projectID, counterID: counter.id,
            operation: .increment, createdAt: Date(timeIntervalSince1970: 50)
        )
        let proof = try makeOrphanWatchProof(
            command: command,
            rejection: .counterMissing,
            processedAt: Date(timeIntervalSince1970: 51),
            deviceID: "originating-device"
        )
        try installOrphanWatchProof(proof, in: fixture.liveRoot)
        let ledgerURL = WatchSyncPaths.processedLedger(in: fixture.liveRoot)
        let preparedURL = WatchSyncPaths.preparedCommand(in: fixture.liveRoot)
        try AtomicWatchSyncFile<PreparedWatchCommand>(url: preparedURL).save(
            PreparedWatchCommand(
                command: command,
                expectedCounterRevision: counter.mutationRevision,
                expectedCounterValue: counter.value
            )
        )
        let store = fixture.store(sink: RecordingSyncMutationSink())

        let recovery = try store.recoverWatchCommandPersistence(
            ledgerURL: ledgerURL,
            preparedCommandURL: preparedURL,
            now: Date(timeIntervalSince1970: 52)
        )

        #expect(recovery == .ready)
        #expect(store.project(id: fixture.projectID)?.counters.first?.value == 0)
        #expect(try AtomicWatchSyncFile<PreparedWatchCommand>(url: preparedURL).load() == nil)
        let cached = try AtomicWatchSyncFile<ProcessedWatchCommandLedger>(url: ledgerURL)
            .load()?.entry(for: command.id)
        #expect(cached?.rejection == .counterMissing)
        #expect(cached?.processingStamp == proof.processingStamp)
    }

    @Test func missingProjectAuthoritySurvivesLedgerDeletionRestartAndProjectReappearance() throws {
        let fixture = try SyncPublicationFixture()
        let command = WatchCounterCommand(
            id: UUID(), projectID: UUID(), counterID: UUID(),
            operation: .increment, createdAt: Date(timeIntervalSince1970: 51)
        )
        let ledgerURL = WatchSyncPaths.processedLedger(in: fixture.liveRoot)
        let preparedURL = WatchSyncPaths.preparedCommand(in: fixture.liveRoot)
        let source = fixture.store(sink: RecordingSyncMutationSink())

        let first = try source.applyWatchCommandDurably(
            command,
            ledgerURL: ledgerURL,
            preparedCommandURL: preparedURL,
            now: Date(timeIntervalSince1970: 52)
        )
        #expect(first.rejection == .projectMissing)
        let originatingEntry = try #require(
            try AtomicWatchSyncFile<ProcessedWatchCommandLedger>(url: ledgerURL)
                .load()?.entry(for: command.id)
        )
        let originatingProof = try #require(
            try SyncAttachmentPublicationEvidenceFile(
                url: fixture.liveRoot
                    .appendingPathComponent("SyncMetadata", isDirectory: true)
                    .appendingPathComponent("attachment-versions.json")
            ).load().watchCommandProof(for: command)
        )
        #expect(originatingEntry.processingStamp == originatingProof.processingStamp)
        #expect(originatingEntry.processingStamp?.modifiedAt
            == Date(timeIntervalSince1970: 52))
        try FileManager.default.removeItem(at: ledgerURL)
        let reappeared = try StoredProject(
            id: command.projectID,
            name: "Reappeared",
            counters: [ProjectCounter(id: command.counterID, defaultOrdinal: 1)]
        )
        let existing = try fixture.archive()
        try JSONEncoder().encode(ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: [reappeared],
            yarns: existing.yarns
        )).write(to: fixture.archiveURL, options: .atomic)

        let restarted = fixture.store(sink: RecordingSyncMutationSink())
        let replay = try restarted.applyWatchCommandDurably(
            command,
            ledgerURL: ledgerURL,
            preparedCommandURL: preparedURL,
            now: Date(timeIntervalSince1970: 53)
        )

        #expect(replay.rejection == .projectMissing)
        #expect(restarted.project(id: command.projectID)?.counters.first?.value == 0)
        let repaired = try #require(try AtomicWatchSyncFile<ProcessedWatchCommandLedger>(
            url: ledgerURL
        ).load()?.entry(for: command.id))
        #expect(repaired.commandIdentity == .init(command))
        #expect(repaired.rejection == .projectMissing)
        #expect(repaired.processingStamp?.modifiedAt == Date(timeIntervalSince1970: 52))
    }

    @Test func missingCounterAuthoritySurvivesPruningRestartAndCounterReappearance() throws {
        let fixture = try SyncPublicationFixture()
        let command = WatchCounterCommand(
            id: UUID(), projectID: fixture.projectID, counterID: UUID(),
            operation: .increment, createdAt: Date(timeIntervalSince1970: 54)
        )
        let ledgerURL = WatchSyncPaths.processedLedger(in: fixture.liveRoot)
        let preparedURL = WatchSyncPaths.preparedCommand(in: fixture.liveRoot)
        let source = fixture.store(sink: RecordingSyncMutationSink())

        let first = try source.applyWatchCommandDurably(
            command,
            ledgerURL: ledgerURL,
            preparedCommandURL: preparedURL,
            now: Date(timeIntervalSince1970: 55)
        )
        #expect(first.rejection == .counterMissing)
        var pruned = try #require(try AtomicWatchSyncFile<ProcessedWatchCommandLedger>(
            url: ledgerURL
        ).load())
        for index in 0..<1_001 {
            pruned.record(
                UUID(),
                at: Date(timeIntervalSince1970: 200 * 86_400 + TimeInterval(index))
            )
        }
        try AtomicWatchSyncFile<ProcessedWatchCommandLedger>(url: ledgerURL).save(pruned)
        #expect(pruned.entry(for: command.id) == nil)
        let reappeared = try StoredProject(
            id: fixture.projectID,
            name: "Counter reappeared",
            counters: [ProjectCounter(id: command.counterID, defaultOrdinal: 1)]
        )
        let existing = try fixture.archive()
        try JSONEncoder().encode(ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: [reappeared],
            yarns: existing.yarns
        )).write(to: fixture.archiveURL, options: .atomic)

        let restarted = fixture.store(sink: RecordingSyncMutationSink())
        let replay = try restarted.applyWatchCommandDurably(
            command,
            ledgerURL: ledgerURL,
            preparedCommandURL: preparedURL,
            now: Date(timeIntervalSince1970: 201 * 86_400)
        )

        #expect(replay.rejection == .counterMissing)
        #expect(restarted.project(id: fixture.projectID)?.counters.first?.value == 0)
        let repaired = try #require(try AtomicWatchSyncFile<ProcessedWatchCommandLedger>(
            url: ledgerURL
        ).load()?.entry(for: command.id))
        #expect(repaired.commandIdentity == .init(command))
        #expect(repaired.rejection == .counterMissing)
        #expect(repaired.processingStamp?.modifiedAt == Date(timeIntervalSince1970: 55))
    }

    @Test func rejectedWatchMetadataPublicationDoesNotRewriteTheArchive() throws {
        // Production break caught: publishing proof-only Watch metadata through
        // the archive persistence path rewrites unchanged user archive bytes.
        let fixture = try SyncPublicationFixture()
        let store = fixture.store(sink: RecordingSyncMutationSink())
        let counterID = try #require(store.project(id: fixture.projectID)?.counters.first?.id)
        let command = WatchCounterCommand(
            schemaVersion: WatchCounterCommand.currentSchemaVersion + 1,
            id: UUID(),
            projectID: fixture.projectID,
            counterID: counterID,
            operation: .increment,
            createdAt: Date(timeIntervalSince1970: 41)
        )
        let archiveBefore = try Data(contentsOf: fixture.archiveURL)

        let acknowledgement = try store.applyWatchCommandDurably(
            command,
            ledgerURL: WatchSyncPaths.processedLedger(in: fixture.liveRoot),
            preparedCommandURL: WatchSyncPaths.preparedCommand(in: fixture.liveRoot),
            now: Date(timeIntervalSince1970: 42)
        )

        #expect(acknowledgement.rejection == .unsupportedSchema)
        #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)

        let missingTarget = WatchCounterCommand(
            id: UUID(),
            projectID: fixture.projectID,
            counterID: UUID(),
            operation: .increment,
            createdAt: Date(timeIntervalSince1970: 43)
        )
        let missingAcknowledgement = try store.applyWatchCommandDurably(
            missingTarget,
            ledgerURL: WatchSyncPaths.processedLedger(in: fixture.liveRoot),
            preparedCommandURL: WatchSyncPaths.preparedCommand(in: fixture.liveRoot),
            now: Date(timeIntervalSince1970: 44)
        )
        #expect(missingAcknowledgement.rejection == .counterMissing)
        #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)
    }

    @Test func duplicateRejectedWatchCommandRepairsInterruptedProofPublication() throws {
        let fixture = try SyncPublicationFixture()
        let sink = RecordingSyncMutationSink(failureAtAttempt: 1)
        let store = fixture.store(sink: sink)
        let counterID = try #require(store.project(id: fixture.projectID)?.counters.first?.id)
        let command = WatchCounterCommand(
            schemaVersion: WatchCounterCommand.currentSchemaVersion + 1,
            id: UUID(),
            projectID: fixture.projectID,
            counterID: counterID,
            operation: .increment,
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let ledgerURL = WatchSyncPaths.processedLedger(in: fixture.liveRoot)
        let preparedURL = WatchSyncPaths.preparedCommand(in: fixture.liveRoot)

        let first = try store.applyWatchCommandDurably(
            command,
            ledgerURL: ledgerURL,
            preparedCommandURL: preparedURL,
            now: Date(timeIntervalSince1970: 31)
        )
        #expect(first.rejection == .unsupportedSchema)
        #expect(store.syncPublicationError == .pendingRepair)
        #expect(try AtomicWatchSyncFile<ProcessedWatchCommandLedger>(
            url: ledgerURL
        ).load()?.entry(for: command.id)?.commandIdentity == .init(command))

        let duplicate = try store.applyWatchCommandDurably(
            command,
            ledgerURL: ledgerURL,
            preparedCommandURL: preparedURL,
            now: Date(timeIntervalSince1970: 32)
        )

        #expect(duplicate.rejection == .unsupportedSchema)
        #expect(sink.mutations.count == 2)
        let repaired = try #require(sink.mutations.last?.savedRecordVersion?.record
            .counterReminderState)
        #expect(repaired.processedCommandProofs.first {
            $0.id == command.id
        }?.commandIdentity == .init(command))
    }

    @Test func duplicateMissingTargetRepublishesAfterInitialMarkerCreationFailure() throws {
        // Production break caught: the ledger is saved before marker creation;
        // a retry must publish the missing proof instead of trusting that cache.
        let fixture = try SyncPublicationFixture()
        let command = WatchCounterCommand(
            id: UUID(), projectID: fixture.projectID, counterID: UUID(),
            operation: .increment, createdAt: Date(timeIntervalSince1970: 56)
        )
        let ledgerURL = WatchSyncPaths.processedLedger(in: fixture.liveRoot)
        let preparedURL = WatchSyncPaths.preparedCommand(in: fixture.liveRoot)
        let markerURL = SyncPublicationTransactionFile(archiveURL: fixture.archiveURL).url
        let first = fixture.store(sink: RecordingSyncMutationSink())
        try FileManager.default.createDirectory(at: markerURL, withIntermediateDirectories: true)

        #expect(throws: SyncPublicationError.self) {
            _ = try first.applyWatchCommandDurably(
                command,
                ledgerURL: ledgerURL,
                preparedCommandURL: preparedURL,
                now: Date(timeIntervalSince1970: 57)
            )
        }
        #expect(try AtomicWatchSyncFile<ProcessedWatchCommandLedger>(
            url: ledgerURL
        ).load()?.entry(for: command.id)?.rejection == .counterMissing)
        try FileManager.default.removeItem(at: markerURL)

        let repairedSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: repairedSink)
        let replay = try restarted.applyWatchCommandDurably(
            command,
            ledgerURL: ledgerURL,
            preparedCommandURL: preparedURL,
            now: Date(timeIntervalSince1970: 58)
        )

        #expect(replay.rejection == .counterMissing)
        let published = try #require(repairedSink.mutations
            .compactMap(\.savedRecordVersion?.record)
            .first { $0.id == .init(kind: .watchCommandProof, uuid: command.id) })
        #expect(published.payload.atomicDomain?.value == .orphanWatchCommandProof(
            try SyncOrphanWatchCommandProof(
                proof: try #require(
                    SyncAttachmentPublicationEvidenceFile(
                        url: fixture.liveRoot
                            .appendingPathComponent("SyncMetadata", isDirectory: true)
                            .appendingPathComponent("attachment-versions.json")
                    ).load().watchCommandProofs.first { $0.id == command.id }
                )
            )
        ))
    }

    @Test func missingTargetEvidenceWriteFailureRepairsBeforeAcknowledgement() throws {
        // Production break caught: publishing to the journal before durable
        // evidence can expose a proof that a restart cannot yet recognize.
        let fixture = try SyncPublicationFixture()
        let sink = RecordingSyncMutationSink()
        let store = fixture.store(
            sink: sink,
            evidenceBoundary: { boundary in
                if boundary == .beforeRename {
                    throw SyncPublicationInjectedFailure()
                }
            }
        )
        let command = WatchCounterCommand(
            id: UUID(), projectID: fixture.projectID, counterID: UUID(),
            operation: .increment, createdAt: Date(timeIntervalSince1970: 59)
        )
        let ledgerURL = WatchSyncPaths.processedLedger(in: fixture.liveRoot)
        let preparedURL = WatchSyncPaths.preparedCommand(in: fixture.liveRoot)
        let evidenceURL = fixture.liveRoot
            .appendingPathComponent("SyncMetadata", isDirectory: true)
            .appendingPathComponent("attachment-versions.json")
        #expect(throws: SyncPublicationError.pendingRepair) {
            _ = try store.applyWatchCommandDurably(
                command,
                ledgerURL: ledgerURL,
                preparedCommandURL: preparedURL,
                now: Date(timeIntervalSince1970: 60)
            )
        }
        #expect(sink.mutations.isEmpty)
        let transactionFile = SyncPublicationTransactionFile(archiveURL: fixture.archiveURL)
        let pending = try #require(try transactionFile.load())

        let repairedSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: repairedSink)
        let replay = try restarted.applyWatchCommandDurably(
            command,
            ledgerURL: ledgerURL,
            preparedCommandURL: preparedURL,
            now: Date(timeIntervalSince1970: 61)
        )

        #expect(replay.rejection == .counterMissing)
        #expect(restarted.project(id: fixture.projectID)?.counters.first?.value == 0)
        #expect(repairedSink.mutations == pending.mutations)
        #expect(try SyncAttachmentPublicationEvidenceFile(url: evidenceURL)
            .load().watchCommandProof(for: command)?.rejection == .counterMissing)
    }

    @Test func missingTargetJournalEnqueueFailureRepairsBeforeAcknowledgement() throws {
        // Production break caught: a missing-target acknowledgement must wait
        // for the durable evidence and replayable journal enqueue to complete.
        let fixture = try SyncPublicationFixture()
        let store = fixture.store(sink: RejectingSyncMutationSink())
        let command = WatchCounterCommand(
            id: UUID(), projectID: UUID(), counterID: UUID(),
            operation: .increment, createdAt: Date(timeIntervalSince1970: 62)
        )
        let ledgerURL = WatchSyncPaths.processedLedger(in: fixture.liveRoot)
        let preparedURL = WatchSyncPaths.preparedCommand(in: fixture.liveRoot)
        let evidenceURL = fixture.liveRoot
            .appendingPathComponent("SyncMetadata", isDirectory: true)
            .appendingPathComponent("attachment-versions.json")
        let transactionFile = SyncPublicationTransactionFile(archiveURL: fixture.archiveURL)

        #expect(throws: SyncPublicationError.pendingRepair) {
            _ = try store.applyWatchCommandDurably(
                command,
                ledgerURL: ledgerURL,
                preparedCommandURL: preparedURL,
                now: Date(timeIntervalSince1970: 63)
            )
        }
        let proofBeforeRepair = try SyncAttachmentPublicationEvidenceFile(url: evidenceURL)
            .load().watchCommandProof(for: command)
        #expect(proofBeforeRepair?.rejection == .projectMissing)
        #expect(proofBeforeRepair?.processingStamp?.modifiedAt
            == Date(timeIntervalSince1970: 63))
        let pending = try #require(try transactionFile.load())

        let repairedSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: repairedSink)
        let replay = try restarted.applyWatchCommandDurably(
            command,
            ledgerURL: ledgerURL,
            preparedCommandURL: preparedURL,
            now: Date(timeIntervalSince1970: 64)
        )

        #expect(replay.rejection == .projectMissing)
        #expect(repairedSink.mutations == pending.mutations)
        #expect(try transactionFile.load() == nil)
    }

    @Test func missingTargetMarkerRemovalFailureRepairsOneJournalMutation() throws {
        // Production break caught: marker removal is part of the success
        // boundary; a restart must replay the same mutation idempotently.
        let fixture = try SyncPublicationFixture()
        let journal = FileSyncMutationJournal(
            url: fixture.root.appendingPathComponent("watch-proof-journal.json")
        )
        let sink = MarkerRemovalFailingJournalSink(
            journal: journal,
            markerParent: fixture.liveRoot
        )
        defer { _ = Darwin.chmod(fixture.liveRoot.path, S_IRWXU) }
        let store = fixture.store(sink: sink)
        let command = WatchCounterCommand(
            id: UUID(), projectID: fixture.projectID, counterID: UUID(),
            operation: .increment, createdAt: Date(timeIntervalSince1970: 65)
        )
        let ledgerURL = WatchSyncPaths.processedLedger(in: fixture.liveRoot)
        let preparedURL = WatchSyncPaths.preparedCommand(in: fixture.liveRoot)
        let transactionFile = SyncPublicationTransactionFile(archiveURL: fixture.archiveURL)

        #expect(throws: SyncPublicationError.pendingRepair) {
            _ = try store.applyWatchCommandDurably(
                command,
                ledgerURL: ledgerURL,
                preparedCommandURL: preparedURL,
                now: Date(timeIntervalSince1970: 66)
            )
        }
        #expect(Darwin.chmod(fixture.liveRoot.path, S_IRWXU) == 0)
        let pending = try #require(try transactionFile.load())
        #expect(try journal.pending() == pending.mutations)

        let restarted = fixture.store(sink: JournalSyncMutationSink(journal: journal))
        let replay = try restarted.applyWatchCommandDurably(
            command,
            ledgerURL: ledgerURL,
            preparedCommandURL: preparedURL,
            now: Date(timeIntervalSince1970: 67)
        )

        #expect(replay.rejection == .counterMissing)
        #expect(try journal.pending() == pending.mutations)
        #expect(try transactionFile.load() == nil)
    }

    @Test func rebuiltLedgerUsesProjectedEntityRevisionAsItsCausalFloor() throws {
        let fixture = try SyncPublicationFixture()
        let sink = RecordingSyncMutationSink()
        let store = fixture.store(sink: sink)

        try store.rename(id: fixture.projectID, to: "First")
        let firstRevision = try #require(sink.mutations.last?.savedRecordVersion?.record.entityRevision)
        try FileManager.default.removeItem(
            at: fixture.liveRoot.appendingPathComponent("SyncMetadata/revision-ledger.json")
        )
        try store.rename(id: fixture.projectID, to: "Second")
        let secondRevision = try #require(sink.mutations.last?.savedRecordVersion?.record.entityRevision)

        #expect(firstRevision > 0)
        #expect(secondRevision == firstRevision + 1)
    }

    @Test func newPublicationTransactionRejectsMissingV3Receipts() throws {
        let fixture = try SyncPublicationFixture()
        let first = fixture.store(sink: RecordingSyncMutationSink(shouldFail: true))
        try first.rename(id: fixture.projectID, to: "Receipt source")
        let transaction = try #require(try SyncPublicationTransactionFile(
            archiveURL: fixture.archiveURL
        ).load())

        #expect(throws: SyncPublicationTransactionFileError.corrupt) {
            _ = try SyncPublicationTransaction(
                expectedArchiveSHA256: transaction.expectedArchiveSHA256,
                mutations: transaction.mutations,
                revisionReceipts: []
            )
        }
    }

    @Test func publicationTransactionRejectsTwoMutationsForOneEntity() throws {
        let fixture = try SyncPublicationFixture()
        let first = fixture.store(sink: RecordingSyncMutationSink(shouldFail: true))
        try first.rename(id: fixture.projectID, to: "Receipt source")
        let transaction = try #require(try SyncPublicationTransactionFile(
            archiveURL: fixture.archiveURL
        ).load())
        let originalMutation = try #require(transaction.mutations.first)
        let originalSave = try #require(originalMutation.savedRecordVersion)
        let originalReceipt = try #require(transaction.revisionReceipts.first)
        let secondID = UUID()
        let duplicateEntityMutation = try SyncMutation.save(
            recordVersion: originalSave,
            mutationID: secondID
        )
        let secondReceipt = SyncRevisionReceipt(
            entityID: originalReceipt.entityID,
            mutationID: secondID,
            logicalRevision: originalReceipt.logicalRevision + 1,
            deviceID: originalReceipt.deviceID
        )

        #expect(throws: SyncPublicationTransactionFileError.corrupt) {
            _ = try SyncPublicationTransaction(
                expectedArchiveSHA256: transaction.expectedArchiveSHA256,
                mutations: [originalMutation, duplicateEntityMutation],
                revisionReceipts: [originalReceipt, secondReceipt]
            )
        }
    }

    @Test func publicationMarkerPersistsCausalReceiptForRestartRecovery() throws {
        let fixture = try SyncPublicationFixture()
        let first = fixture.store(sink: RecordingSyncMutationSink(shouldFail: true))

        try first.rename(id: fixture.projectID, to: "Causal")

        let transaction = try #require(try SyncPublicationTransactionFile(
            archiveURL: fixture.archiveURL
        ).load())
        let saved = try #require(transaction.mutations.first?.savedRecordVersion?.record)
        let receipt = try #require(transaction.revisionReceipts.first)
        #expect(receipt.entityID == saved.id)
        #expect(receipt.logicalRevision == 1)
        #expect(saved.entityRevision == 1)
        #expect(receipt.deviceID == saved.deletedAt.stamp.deviceID)

        let repairSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: repairSink)
        try restarted.repairSyncPublication()
        #expect(repairSink.mutations == transaction.mutations)
    }

    @Test func successfulMutationPublishesOnlyAfterArchiveCommit() throws {
        let fixture = try SyncPublicationFixture()
        let sink = RecordingSyncMutationSink(archiveURL: fixture.archiveURL)
        let store = fixture.store(sink: sink)

        try store.rename(id: fixture.projectID, to: "Committed")

        #expect(sink.archiveProjectNamesAtPublication == ["Committed"])
        #expect(sink.mutations.map(\.recordKind) == [.project])
        #expect(store.syncPublicationError == nil)
    }

    @Test func archiveFailurePublishesNothingAndClearsPreparedTransaction() throws {
        let fixture = try SyncPublicationFixture()
        let sink = RecordingSyncMutationSink()
        let store = fixture.store(
            sink: sink,
            archiveWrite: { _, _ in throw SyncPublicationInjectedFailure() }
        )
        let archiveBefore = try Data(contentsOf: fixture.archiveURL)
        let filesBefore = try fixture.regularFiles()

        #expect(throws: ProjectStoreError.persistenceFailed) {
            try store.rename(id: fixture.projectID, to: "Rejected")
        }

        #expect(sink.mutations.isEmpty)
        #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)
        #expect(try fixture.regularFiles() == filesBefore)
        #expect(store.syncPublicationError == nil)
    }

    @Test func unlinkPublishesOnlyLinkDeletionAndNeverYarnDeletion() throws {
        let fixture = try SyncPublicationFixture(linkYarn: true)
        let sink = RecordingSyncMutationSink()
        let store = fixture.store(sink: sink)

        try store.setYarnProjects(yarnID: fixture.yarnID, projectIDs: [])

        #expect(sink.mutations.count == 1)
        #expect(sink.mutations.map(\.operation) == [.delete])
        #expect(sink.mutations.map(\.recordKind) == [.projectYarnLink])
        #expect(store.yarn(id: fixture.yarnID) != nil)
        #expect(store.yarn(id: fixture.yarnID)?.linkedProjectIDs.isEmpty == true)
    }

    @Test func publicationFailurePreservesCommittedPhotoAndBlocksUntilRestartRepair() throws {
        let fixture = try SyncPublicationFixture()
        let failingSink = RecordingSyncMutationSink(shouldFail: true)
        let store = fixture.store(sink: failingSink)
        let project = try #require(store.project(id: fixture.projectID))

        try store.updateProject(
            id: project.id,
            name: "Committed with photo",
            toolType: project.toolType,
            toolSize: project.toolSize,
            toolNotes: project.toolNotes,
            photoChange: .replace(try makeSyncPublicationJPEG(red: 0.3))
        )

        #expect(store.syncPublicationError == .pendingRepair)
        let committed = try #require(store.project(id: fixture.projectID))
        let committedPhotoURL = try #require(store.photoURL(for: committed))
        #expect(FileManager.default.fileExists(atPath: committedPhotoURL.path))
        let persisted = try fixture.archive()
        #expect(persisted.projects.first?.name == "Committed with photo")
        #expect(persisted.projects.first?.photoFilename == committed.photoFilename)

        let archiveBeforeRejectedMutation = try Data(contentsOf: fixture.archiveURL)
        let photoFilesBeforeRejectedMutation = try fixture.projectPhotoFiles()
        #expect(throws: SyncPublicationError.pendingRepair) {
            try store.updateProject(
                id: committed.id,
                name: "Must not commit",
                toolType: committed.toolType,
                toolSize: committed.toolSize,
                toolNotes: committed.toolNotes,
                photoChange: .replace(try makeSyncPublicationJPEG(red: 0.8))
            )
        }
        #expect(try Data(contentsOf: fixture.archiveURL) == archiveBeforeRejectedMutation)
        #expect(try fixture.projectPhotoFiles() == photoFilesBeforeRejectedMutation)

        let loadedTransaction = try SyncPublicationTransactionFile(
            archiveURL: fixture.archiveURL
        ).load()
        let transaction = try #require(loadedTransaction)
        let exactPendingMutations = transaction.mutations
        let candidateManifest = try #require(transaction.candidateAttachmentManifest)
        let manifestURL = fixture.liveRoot
            .appendingPathComponent("SyncMetadata", isDirectory: true)
            .appendingPathComponent("attachment-manifest.json")
        #expect(candidateManifest.count == 1)
        #expect(!FileManager.default.fileExists(atPath: manifestURL.path))
        let repairSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: repairSink)
        #expect(restarted.syncPublicationError == .pendingRepair)
        #expect(restarted.project(id: fixture.projectID)?.name == "Committed with photo")
        #expect(FileManager.default.fileExists(atPath: committedPhotoURL.path))

        try restarted.repairSyncPublication()

        #expect(repairSink.mutations == exactPendingMutations)
        #expect(restarted.syncPublicationError == nil)
        #expect(try Set(SyncAttachmentManifestStore(url: manifestURL).load().values.map(\.versionID))
            == Set(candidateManifest.map(\.versionID)))
        try restarted.rename(id: fixture.projectID, to: "Unblocked")
        #expect(restarted.project(id: fixture.projectID)?.name == "Unblocked")
        #expect(restarted.syncPublicationError == nil)
    }

    @Test func manifestCommitFailureAfterJournalEnqueueKeepsCandidateForIdempotentRepair() throws {
        let fixture = try SyncPublicationFixture()
        let sink = RecordingSyncMutationSink()
        let store = fixture.store(sink: sink)
        let project = try #require(store.project(id: fixture.projectID))
        let manifestURL = fixture.liveRoot
            .appendingPathComponent("SyncMetadata", isDirectory: true)
            .appendingPathComponent("attachment-manifest.json")
        try FileManager.default.createDirectory(
            at: manifestURL,
            withIntermediateDirectories: true
        )

        try store.updateProject(
            id: project.id,
            name: project.name,
            toolType: project.toolType,
            toolSize: project.toolSize,
            toolNotes: project.toolNotes,
            photoChange: .replace(try makeSyncPublicationJPEG(red: 0.42))
        )

        #expect(!sink.mutations.isEmpty)
        #expect(store.syncPublicationError == .pendingRepair)
        let transactionFile = SyncPublicationTransactionFile(archiveURL: fixture.archiveURL)
        let transaction = try #require(try transactionFile.load())
        let candidateManifest = try #require(transaction.candidateAttachmentManifest)
        #expect(candidateManifest.count == 1)
        #expect(FileManager.default.fileExists(atPath: transactionFile.url.path))

        try FileManager.default.removeItem(at: manifestURL)
        let repairSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: repairSink)
        try restarted.repairSyncPublication()

        #expect(repairSink.mutations == transaction.mutations)
        #expect(try Set(SyncAttachmentManifestStore(url: manifestURL).load().values.map(\.versionID))
            == Set(candidateManifest.map(\.versionID)))
        #expect(!FileManager.default.fileExists(atPath: transactionFile.url.path))
        #expect(restarted.syncPublicationError == nil)
    }

    @Test func pendingPublicationBlocksBackupRestoreBeforeItTouchesLiveData() async throws {
        let fixture = try SyncPublicationFixture()
        let store = fixture.store(sink: RecordingSyncMutationSink(shouldFail: true))
        try store.rename(id: fixture.projectID, to: "Committed before restore")
        let archiveBefore = try Data(contentsOf: fixture.archiveURL)
        let filesBefore = try fixture.regularFiles()
        let unavailableBackup = StagedKnitNoteBackup(
            root: fixture.root.appendingPathComponent("must-not-be-opened.knitnote-backup"),
            preview: KnitNoteBackupPreview(
                createdAt: .now,
                projectCount: 0,
                yarnCount: 0
            )
        )

        await #expect(throws: SyncPublicationError.pendingRepair) {
            try await store.restoreBackup(unavailableBackup)
        }

        #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)
        #expect(try fixture.regularFiles() == filesBefore)
        #expect(store.syncPublicationError == .pendingRepair)
    }

    @Test func restartFailsClosedWhenArchiveCommittedAttachmentEvidenceIsMissing() throws {
        let fixture = try SyncPublicationFixture()
        let first = fixture.store(sink: RecordingSyncMutationSink(shouldFail: true))
        let project = try #require(first.project(id: fixture.projectID))
        try first.updateProject(
            id: project.id,
            name: project.name,
            toolType: project.toolType,
            toolSize: project.toolSize,
            toolNotes: project.toolNotes,
            photoChange: .replace(try makeSyncPublicationJPEG(red: 0.35))
        )
        let committed = try #require(first.project(id: fixture.projectID))
        let photoURL = try #require(first.photoURL(for: committed))
        try FileManager.default.removeItem(at: photoURL)

        let restartedSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: restartedSink)

        #expect(restarted.syncPublicationError == .corruptTransaction)
        #expect(throws: SyncPublicationError.corruptTransaction) {
            try restarted.rename(id: fixture.projectID, to: "Blocked")
        }
        #expect(restartedSink.mutations.isEmpty)
    }

    @Test func projectPhotoPublishesStableAttachmentSaveAndDelete() throws {
        // Production break caught: a restarted store rebuilt the attachment
        // record instead of cloning its durably issued immutable snapshot.
        let fixture = try SyncPublicationFixture()
        let firstSink = RecordingSyncMutationSink()
        let first = fixture.store(sink: firstSink)
        let project = try #require(first.project(id: fixture.projectID))

        try first.updateProject(
            id: project.id,
            name: project.name,
            toolType: project.toolType,
            toolSize: project.toolSize,
            toolNotes: project.toolNotes,
            photoChange: .replace(try makeSyncPublicationJPEG(red: 0.2))
        )

        let firstAttachment = try #require(firstSink.mutations.first {
            $0.recordKind == .attachment
        })
        #expect(firstAttachment.operation == .save)

        let secondSink = RecordingSyncMutationSink()
        let second = fixture.store(sink: secondSink)
        let committed = try #require(second.project(id: fixture.projectID))
        try second.updateProject(
            id: committed.id,
            name: committed.name,
            toolType: committed.toolType,
            toolSize: committed.toolSize,
            toolNotes: committed.toolNotes,
            photoChange: .remove
        )

        let attachmentTombstones = secondSink.mutations.filter {
            $0.isAttachmentTombstone
        }
        let issuedRecord = try #require(firstAttachment.savedRecordVersion?.record)
        let tombstoneRecord = try #require(
            attachmentTombstones.first?.savedRecordVersion?.record
        )
        #expect(attachmentTombstones.count == 1)
        #expect(attachmentTombstones.first?.recordID == firstAttachment.recordID)
        #expect(attachmentTombstones.first?.attachmentSource == nil)
        #expect(
            try SyncAttachmentImmutableSnapshot(record: tombstoneRecord).sha256
                == SyncAttachmentImmutableSnapshot(record: issuedRecord).sha256
        )
    }

    @Test func sameStoreStructuralPersistKeepsAttachmentHeadForRestartedReplacement() throws {
        struct EvidenceEnvelope: Decodable {
            let versions: [SyncAttachmentVersion]
        }

        let fixture = try SyncPublicationFixture()
        let firstSink = RecordingSyncMutationSink()
        let first = fixture.store(sink: firstSink)
        let original = try #require(first.project(id: fixture.projectID))

        try first.updateProject(
            id: original.id,
            name: original.name,
            toolType: original.toolType,
            toolSize: original.toolSize,
            toolNotes: original.toolNotes,
            photoChange: .replace(try makeSyncPublicationJPEG(red: 0.2))
        )
        let firstSave = try #require(firstSink.mutations.last { mutation in
            mutation.recordKind == .attachment && mutation.operation == .save
        })
        let evidenceURL = fixture.liveRoot.appendingPathComponent(
            "SyncMetadata/attachment-versions.json"
        )
        let evidenceBeforeRename = try JSONDecoder().decode(
            EvidenceEnvelope.self,
            from: Data(contentsOf: evidenceURL)
        )
        let countBeforeRename = firstSink.mutations.count

        try first.rename(id: fixture.projectID, to: "Unrelated structural edit")
        let renameMutations = Array(firstSink.mutations.dropFirst(countBeforeRename))
        #expect(!renameMutations.contains {
            $0.recordKind == .attachment && $0.operation == .delete
        })
        #expect(try JSONDecoder().decode(
            EvidenceEnvelope.self,
            from: Data(contentsOf: evidenceURL)
        ).versions == evidenceBeforeRename.versions)

        let replacementSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: replacementSink)
        let withFirstPhoto = try #require(restarted.project(id: fixture.projectID))
        try restarted.updateProject(
            id: withFirstPhoto.id,
            name: withFirstPhoto.name,
            toolType: withFirstPhoto.toolType,
            toolSize: withFirstPhoto.toolSize,
            toolNotes: withFirstPhoto.toolNotes,
            photoChange: .replace(try makeSyncPublicationJPEG(red: 0.8))
        )
        let replacement = try #require(replacementSink.mutations.last { mutation in
            mutation.recordKind == .attachment && mutation.operation == .save
        })
        #expect(replacement.savedRecordVersion?.record.payload.attachment?.replacesVersionID
            == firstSave.recordID.uuid)
    }

    @Test func realJournalRetainsSaveReplaceDeleteVersionsAcrossStoreAndJournalRestarts() throws {
        let fixture = try SyncPublicationFixture()
        let journalURL = fixture.root.appendingPathComponent("sync-mutations.json")
        let firstBytes = try makeSyncPublicationJPEG(red: 0.15)
        let secondBytes = try makeSyncPublicationJPEG(red: 0.85)

        let firstJournal = FileSyncMutationJournal(url: journalURL)
        let firstStore = fixture.store(sink: JournalSyncMutationSink(journal: firstJournal))
        let original = try #require(firstStore.project(id: fixture.projectID))
        try firstStore.updateProject(
            id: original.id,
            name: original.name,
            toolType: original.toolType,
            toolSize: original.toolSize,
            toolNotes: original.toolNotes,
            photoChange: .replace(firstBytes)
        )
        let firstSave = try #require(try firstJournal.pending().first(where: {
            $0.attachmentSource != nil
                && $0.savedRecordVersion?.record.payload.attachment?.slot.role == "project-photo"
        }))
        let firstSource = try #require(firstSave.attachmentSource)
        let firstCommittedProject = try #require(firstStore.project(id: fixture.projectID))
        let firstCommittedURL = try #require(firstStore.photoURL(for: firstCommittedProject))
        let firstCommittedBytes = try Data(contentsOf: firstCommittedURL)
        #expect(firstSource.isJournalStaged)
        #expect(try Data(contentsOf: firstSource.fileURL) == firstCommittedBytes)

        let secondJournal = FileSyncMutationJournal(url: journalURL)
        let secondStore = fixture.store(sink: JournalSyncMutationSink(journal: secondJournal))
        let withFirstPhoto = try #require(secondStore.project(id: fixture.projectID))
        try secondStore.updateProject(
            id: withFirstPhoto.id,
            name: withFirstPhoto.name,
            toolType: withFirstPhoto.toolType,
            toolSize: withFirstPhoto.toolSize,
            toolNotes: withFirstPhoto.toolNotes,
            photoChange: .replace(secondBytes)
        )
        let photoSaves = try secondJournal.pending().filter {
            $0.savedRecordVersion?.record.payload.attachment?.slot.role == "project-photo"
        }
        #expect(photoSaves.count == 2)
        let replacement = try #require(photoSaves.last)
        #expect(replacement.recordID != firstSave.recordID)
        #expect(
            replacement.savedRecordVersion?.record.payload.attachment?.replacesVersionID
                == firstSave.recordID.uuid
        )
        let secondCommittedProject = try #require(secondStore.project(id: fixture.projectID))
        let secondCommittedURL = try #require(secondStore.photoURL(for: secondCommittedProject))
        let secondCommittedBytes = try Data(contentsOf: secondCommittedURL)
        let replacementSource = try #require(replacement.attachmentSource)
        #expect(try Data(contentsOf: firstSource.fileURL) == firstCommittedBytes)
        #expect(try Data(contentsOf: replacementSource.fileURL) == secondCommittedBytes)

        let thirdJournal = FileSyncMutationJournal(url: journalURL)
        let thirdStore = fixture.store(sink: JournalSyncMutationSink(journal: thirdJournal))
        let withReplacement = try #require(thirdStore.project(id: fixture.projectID))
        try thirdStore.updateProject(
            id: withReplacement.id,
            name: withReplacement.name,
            toolType: withReplacement.toolType,
            toolSize: withReplacement.toolSize,
            toolNotes: withReplacement.toolNotes,
            photoChange: .remove
        )

        let restartedJournal = FileSyncMutationJournal(url: journalURL)
        let restartedPending = try restartedJournal.pending()
        #expect(restartedPending.contains(firstSave))
        #expect(restartedPending.contains(replacement))
        #expect(restartedPending.contains {
            $0.isAttachmentTombstone && $0.recordID == replacement.recordID
        })
        #expect(!restartedPending.contains {
            $0.isAttachmentTombstone && $0.recordID == firstSave.recordID
        })
        #expect(try Data(contentsOf: firstSource.fileURL) == firstCommittedBytes)

        try restartedJournal.acknowledge([firstSave.identity])
        #expect(!FileManager.default.fileExists(atPath: firstSource.fileURL.path))
        #expect(try restartedJournal.pending().contains(replacement))
    }

    @Test func yarnPhotoAndLabelsPublishStableAttachmentSavesAndDeletes() throws {
        let fixture = try SyncPublicationFixture()
        let firstSink = RecordingSyncMutationSink()
        let first = fixture.store(sink: firstSink)
        let yarn = try #require(first.yarn(id: fixture.yarnID))

        try first.updateYarn(
            yarn,
            photoChange: .replace(try makeSyncPublicationJPEG(red: 0.2)),
            labelPhotoChange: .replace(
                first: try makeSyncPublicationJPEG(red: 0.4),
                second: try makeSyncPublicationJPEG(red: 0.6)
            )
        )

        let savedAttachmentIDs = Set(firstSink.mutations.compactMap {
            $0.recordKind == .attachment && $0.operation == .save ? $0.recordID : nil
        })
        #expect(savedAttachmentIDs.count == 3)

        let secondSink = RecordingSyncMutationSink()
        let second = fixture.store(sink: secondSink)
        let committed = try #require(second.yarn(id: fixture.yarnID))
        try second.updateYarn(
            committed,
            photoChange: .remove,
            labelPhotoChange: .removeAll
        )

        let deletedAttachmentIDs = Set(secondSink.mutations.compactMap {
            $0.isAttachmentTombstone ? $0.recordID : nil
        })
        #expect(deletedAttachmentIDs == savedAttachmentIDs)
    }

    @Test func removingFirstYarnLabelKeepsSecondSlotAndIssuedVersion() throws {
        let fixture = try SyncPublicationFixture()
        let firstSink = RecordingSyncMutationSink()
        let first = fixture.store(sink: firstSink)
        let yarn = try #require(first.yarn(id: fixture.yarnID))
        try first.updateYarn(
            yarn,
            photoChange: .unchanged,
            labelPhotoChange: .replace(
                first: try makeSyncPublicationJPEG(red: 0.3),
                second: try makeSyncPublicationJPEG(red: 0.7)
            )
        )
        let committed = try #require(first.yarn(id: fixture.yarnID))
        let firstSlotID = committed.labelPhotoSlotIDs[0]
        let secondSlotID = committed.labelPhotoSlotIDs[1]
        let versionsBySlot: [String: SyncAttachmentVersion] = Dictionary(
            uniqueKeysWithValues: firstSink.mutations.compactMap {
                guard let version = $0.savedRecordVersion?.record.payload.attachment,
                      version.slot.role == "yarn-label-photo" else { return nil }
                return (version.slot.slotID, version)
            }
        )
        let firstVersion = try #require(
            versionsBySlot["label:\(firstSlotID.uuidString.lowercased())"]
        )
        let secondVersion = try #require(
            versionsBySlot["label:\(secondSlotID.uuidString.lowercased())"]
        )

        let secondSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: secondSink)
        let restartedYarn = try #require(restarted.yarn(id: fixture.yarnID))
        try restarted.updateYarn(
            restartedYarn,
            photoChange: .unchanged,
            labelPhotoChange: .retainExisting([restartedYarn.labelPhotoFilenames[1]])
        )

        let attachmentMutations = secondSink.mutations.filter {
            $0.recordKind == .attachment
        }
        #expect(attachmentMutations.count == 1)
        #expect(attachmentMutations[0].isAttachmentTombstone)
        #expect(attachmentMutations[0].recordID.uuid == firstVersion.versionID)
        #expect(!attachmentMutations.contains {
            $0.recordID.uuid == secondVersion.versionID
        })
        #expect(restarted.yarn(id: fixture.yarnID)?.labelPhotoSlotIDs == [secondSlotID])
    }

    @Test func journalPhotoPairPublishesStableAttachmentSavesAndDeletes() async throws {
        let fixture = try SyncPublicationFixture()
        let firstSink = RecordingSyncMutationSink()
        let first = fixture.store(sink: firstSink)

        try await first.addJournalEntry(
            projectID: fixture.projectID,
            photoData: try makeSyncPublicationJPEG(red: 0.7),
            caption: "Committed"
        )

        let entry = try #require(first.project(id: fixture.projectID)?.journalEntries.first)
        let savedAttachmentIDs = Set(firstSink.mutations.compactMap {
            $0.recordKind == .attachment && $0.operation == .save ? $0.recordID : nil
        })
        #expect(savedAttachmentIDs.count == 2)

        let secondSink = RecordingSyncMutationSink()
        let second = fixture.store(sink: secondSink)
        try second.deleteJournalEntry(projectID: fixture.projectID, entryID: entry.id)

        let deletedAttachmentIDs = Set(secondSink.mutations.compactMap {
            $0.isAttachmentTombstone ? $0.recordID : nil
        })
        #expect(deletedAttachmentIDs == savedAttachmentIDs)
    }

    @Test func usageMarkupPublishesStableAttachmentSaveAndDelete() throws {
        // Production break caught: the artifact-only adapter rebuilt the
        // issued usage-markup attachment when publishing its tombstone.
        let fixture = try SyncPublicationFixture()
        let usageID = try fixture.installPatternUsage()
        let firstSink = RecordingSyncMutationSink()
        let first = fixture.store(sink: firstSink)
        let markup = syncPublicationMarkup(color: .blue)

        try first.savePatternMarkup(
            markup,
            usageID: usageID,
            pageIndex: 2,
            expectedDataGeneration: first.dataGeneration
        )

        let saved = try #require(firstSink.mutations.onlyAttachment)
        #expect(saved.operation == .save)
        #expect(try first.loadPatternMarkup(usageID: usageID, pageIndex: 2) == markup)

        let secondSink = RecordingSyncMutationSink()
        let second = fixture.store(sink: secondSink)
        try second.savePatternMarkup(
            PatternMarkupDocument(),
            usageID: usageID,
            pageIndex: 2,
            expectedDataGeneration: second.dataGeneration
        )

        let deleted = try #require(secondSink.mutations.onlyAttachment)
        let issuedRecord = try #require(saved.savedRecordVersion?.record)
        let tombstoneRecord = try #require(deleted.savedRecordVersion?.record)
        #expect(deleted.isAttachmentTombstone)
        #expect(deleted.recordID == saved.recordID)
        #expect(
            try SyncAttachmentImmutableSnapshot(record: tombstoneRecord).sha256
                == SyncAttachmentImmutableSnapshot(record: issuedRecord).sha256
        )
        #expect(try second.loadPatternMarkup(usageID: usageID, pageIndex: 2).strokes.isEmpty)
    }

    @Test func legacyMarkupPublishesStableAttachmentSaveAndDelete() throws {
        // Production break caught: the artifact-only adapter rebuilt the
        // issued legacy-markup attachment when publishing its tombstone.
        let fixture = try SyncPublicationFixture()
        let patternID = try fixture.installLegacyPattern()
        let firstSink = RecordingSyncMutationSink()
        let first = fixture.store(sink: firstSink)
        let markup = syncPublicationMarkup(color: .green)

        try first.savePatternMarkup(
            markup,
            projectID: fixture.projectID,
            patternID: patternID,
            pageIndex: 3,
            expectedDataGeneration: first.dataGeneration
        )

        let saved = try #require(firstSink.mutations.onlyAttachment)
        #expect(saved.operation == .save)
        #expect(try first.loadPatternMarkup(
            projectID: fixture.projectID,
            patternID: patternID,
            pageIndex: 3
        ) == markup)

        let secondSink = RecordingSyncMutationSink()
        let second = fixture.store(sink: secondSink)
        try second.savePatternMarkup(
            PatternMarkupDocument(),
            projectID: fixture.projectID,
            patternID: patternID,
            pageIndex: 3,
            expectedDataGeneration: second.dataGeneration
        )

        let deleted = try #require(secondSink.mutations.onlyAttachment)
        let issuedRecord = try #require(saved.savedRecordVersion?.record)
        let tombstoneRecord = try #require(deleted.savedRecordVersion?.record)
        #expect(deleted.isAttachmentTombstone)
        #expect(deleted.recordID == saved.recordID)
        #expect(
            try SyncAttachmentImmutableSnapshot(record: tombstoneRecord).sha256
                == SyncAttachmentImmutableSnapshot(record: issuedRecord).sha256
        )
    }

    @Test func usageMarkupSinkFailurePersistsAcrossRestartAndBlocksLaterFileWrites() throws {
        let fixture = try SyncPublicationFixture()
        let usageID = try fixture.installPatternUsage()
        let failingSink = RecordingSyncMutationSink(shouldFail: true)
        let first = fixture.store(sink: failingSink)
        let committedMarkup = syncPublicationMarkup(color: .red)

        try first.savePatternMarkup(
            committedMarkup,
            usageID: usageID,
            pageIndex: 4,
            expectedDataGeneration: first.dataGeneration
        )

        #expect(first.syncPublicationError == .pendingRepair)
        #expect(try first.loadPatternMarkup(usageID: usageID, pageIndex: 4) == committedMarkup)
        #expect(throws: SyncPublicationError.pendingRepair) {
            try first.savePatternMarkup(
                syncPublicationMarkup(color: .blue),
                usageID: usageID,
                pageIndex: 5,
                expectedDataGeneration: first.dataGeneration
            )
        }
        #expect(try first.loadPatternMarkup(usageID: usageID, pageIndex: 5).strokes.isEmpty)

        let repairSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: repairSink)
        #expect(restarted.syncPublicationError == .pendingRepair)
        #expect(try restarted.loadPatternMarkup(usageID: usageID, pageIndex: 4) == committedMarkup)

        try restarted.repairSyncPublication()

        #expect(repairSink.mutations == failingSink.mutations)
        #expect(restarted.syncPublicationError == nil)
    }

    @Test func usageMarkupArchiveFailureRestoresOriginalFileAndPublishesNothing() throws {
        let fixture = try SyncPublicationFixture()
        let usageID = try fixture.installPatternUsage()
        let setup = fixture.store(sink: RecordingSyncMutationSink())
        let original = syncPublicationMarkup(color: .green)
        try setup.savePatternMarkup(
            original,
            usageID: usageID,
            pageIndex: 6,
            expectedDataGeneration: setup.dataGeneration
        )
        let sink = RecordingSyncMutationSink()
        let failing = fixture.store(
            sink: sink,
            archiveWrite: { _, _ in throw SyncPublicationInjectedFailure() }
        )

        #expect(throws: ProjectStoreError.persistenceFailed) {
            try failing.savePatternMarkup(
                syncPublicationMarkup(color: .blue),
                usageID: usageID,
                pageIndex: 6,
                expectedDataGeneration: failing.dataGeneration
            )
        }

        #expect(try failing.loadPatternMarkup(usageID: usageID, pageIndex: 6) == original)
        #expect(sink.mutations.isEmpty)
        #expect(failing.syncPublicationError == nil)
        #expect(fixture.store(sink: RecordingSyncMutationSink()).syncPublicationError == nil)
    }

    @Test func legacyMarkupSinkFailureSurvivesRestartForExactRepair() throws {
        let fixture = try SyncPublicationFixture()
        let patternID = try fixture.installLegacyPattern()
        let failingSink = RecordingSyncMutationSink(shouldFail: true)
        let first = fixture.store(sink: failingSink)
        let markup = syncPublicationMarkup(color: .black)
        try first.savePatternMarkup(
            markup,
            projectID: fixture.projectID,
            patternID: patternID,
            pageIndex: 7,
            expectedDataGeneration: first.dataGeneration
        )
        #expect(first.syncPublicationError == .pendingRepair)

        let repairSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: repairSink)
        #expect(restarted.syncPublicationError == .pendingRepair)
        #expect(try restarted.loadPatternMarkup(
            projectID: fixture.projectID,
            patternID: patternID,
            pageIndex: 7
        ) == markup)

        try restarted.repairSyncPublication()

        #expect(repairSink.mutations == failingSink.mutations)
        #expect(restarted.syncPublicationError == nil)
    }

    @Test func deletingProjectPublishesDeletesForItsUsageMarkupPages() throws {
        let fixture = try SyncPublicationFixture()
        let usageID = try fixture.installPatternUsage()
        let setupSink = RecordingSyncMutationSink()
        let setup = fixture.store(sink: setupSink)
        try setup.savePatternMarkup(
            syncPublicationMarkup(color: .green),
            usageID: usageID,
            pageIndex: 8,
            expectedDataGeneration: setup.dataGeneration
        )
        let markupID = try #require(setupSink.mutations.onlyAttachment?.recordID)

        let deletionSink = RecordingSyncMutationSink()
        let deleting = fixture.store(sink: deletionSink)
        try deleting.delete(id: fixture.projectID)

        #expect(deletionSink.mutations.contains {
            $0.isAttachmentTombstone && $0.recordID == markupID
        })
        #expect(!FileManager.default.fileExists(
            atPath: fixture.usageMarkupURL(usageID: usageID, pageIndex: 8).path
        ))
    }

    @Test func deletingLegacyPatternDeletesIssuedMarkupWithoutInventingAnUnissuedSourceVersion() throws {
        let fixture = try SyncPublicationFixture()
        let patternID = try fixture.installLegacyPattern()
        let setupSink = RecordingSyncMutationSink()
        let setup = fixture.store(sink: setupSink)
        try setup.savePatternMarkup(
            syncPublicationMarkup(color: .red),
            projectID: fixture.projectID,
            patternID: patternID,
            pageIndex: 9,
            expectedDataGeneration: setup.dataGeneration
        )
        let markupID = try #require(setupSink.mutations.onlyAttachment?.recordID)

        let deletionSink = RecordingSyncMutationSink()
        let deleting = fixture.store(sink: deletionSink)
        try deleting.deletePattern(projectID: fixture.projectID, id: patternID)

        let attachmentDeletes = deletionSink.mutations.filter {
            $0.isAttachmentTombstone
        }
        #expect(attachmentDeletes.count == 1)
        #expect(attachmentDeletes.contains { $0.recordID == markupID })
        #expect(!FileManager.default.fileExists(
            atPath: fixture.legacyMarkupURL(
                projectID: fixture.projectID,
                patternID: patternID,
                pageIndex: 9
            ).path
        ))
    }

    @Test func restartDiscardsValidMarkerWhenArchiveDoesNotMatchExpectedCommit() throws {
        let fixture = try SyncPublicationFixture()
        let originalArchive = try Data(contentsOf: fixture.archiveURL)
        let failingSink = RecordingSyncMutationSink(shouldFail: true)
        let first = fixture.store(sink: failingSink)
        try first.rename(id: fixture.projectID, to: "Committed only in newer archive")
        #expect(first.syncPublicationError == .pendingRepair)

        try originalArchive.write(to: fixture.archiveURL, options: .atomic)
        let restartedSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: restartedSink)

        #expect(restarted.syncPublicationError == nil)
        #expect(restartedSink.mutations.isEmpty)
        #expect(restarted.project(id: fixture.projectID)?.name == "Original")
        try restarted.rename(id: fixture.projectID, to: "Fresh mutation")
        #expect(restartedSink.mutations.map(\.recordKind) == [.project])
    }

    @Test func startupReconcilesPendingMarkerBeforeArchiveMigrationCanRewriteIt() throws {
        let fixture = try SyncPublicationFixture()
        let current = try fixture.archive()
        let oldArchive = ProjectArchive(
            version: ProjectArchive.currentVersion - 1,
            projects: current.projects,
            yarns: current.yarns,
            patternFolders: current.patternFolders,
            patternAssets: current.patternAssets,
            patterns: current.patterns,
            patternUsages: current.patternUsages
        )
        let oldBytes = try JSONEncoder().encode(oldArchive)
        try oldBytes.write(to: fixture.archiveURL, options: .atomic)
        let mutation = SyncMutation.save(
            SyncEntityID(kind: .project, uuid: fixture.projectID),
            mutationID: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        )
        let transactionFile = SyncPublicationTransactionFile(archiveURL: fixture.archiveURL)
        try transactionFile.write(try SyncPublicationTransaction.legacy(
            expectedArchiveSHA256: SyncPublicationTransactionFile.fingerprint(of: oldBytes),
            mutations: [mutation]
        ))
        let sink = RecordingSyncMutationSink()

        let restarted = fixture.store(sink: sink)

        #expect(restarted.syncPublicationError == .pendingRepair)
        #expect(try Data(contentsOf: fixture.archiveURL) == oldBytes)
        #expect(throws: SyncPublicationError.pendingRepair) {
            try restarted.rename(id: fixture.projectID, to: "Blocked before migration")
        }
        #expect(sink.mutations.isEmpty)

        try restarted.repairSyncPublication()

        #expect(sink.mutations == [mutation])
        #expect(restarted.syncPublicationError == nil)
        #expect(try fixture.archive().version == ProjectArchive.currentVersion)
    }

    @Test func liveStartupDefersInterruptedBackupRecoveryWhilePublicationIsPending() throws {
        let fixture = try SyncPublicationFixture()
        let committedBytes = try Data(contentsOf: fixture.archiveURL)
        let mutation = SyncMutation.save(
            SyncEntityID(kind: .project, uuid: fixture.projectID),
            mutationID: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
        )
        let transactionFile = SyncPublicationTransactionFile(archiveURL: fixture.archiveURL)
        try transactionFile.write(try SyncPublicationTransaction.legacy(
            expectedArchiveSHA256: SyncPublicationTransactionFile.fingerprint(of: committedBytes),
            mutations: [mutation]
        ))
        let replacementJournalURL = try installInterruptedBackupRollback(
            baseDirectory: fixture.root,
            replacementProjectName: "Recovery must wait"
        )

        let restarted = JSONProjectStore.live(baseDirectory: fixture.root)

        #expect(restarted.syncPublicationError == .pendingRepair)
        #expect(restarted.project(id: fixture.projectID)?.name == "Original")
        #expect(try Data(contentsOf: fixture.archiveURL) == committedBytes)
        #expect(FileManager.default.fileExists(atPath: transactionFile.url.path))
        #expect(FileManager.default.fileExists(atPath: replacementJournalURL.path))
    }

    @Test func liveStartupRecoversBackupAfterDiscardingUncommittedPublication() throws {
        let fixture = try SyncPublicationFixture()
        let mutation = SyncMutation.save(
            SyncEntityID(kind: .project, uuid: fixture.projectID),
            mutationID: UUID(uuidString: "10000000-0000-0000-0000-000000000005")!
        )
        let transactionFile = SyncPublicationTransactionFile(archiveURL: fixture.archiveURL)
        try transactionFile.write(try SyncPublicationTransaction.legacy(
            expectedArchiveSHA256: SyncPublicationTransactionFile.fingerprint(
                of: Data("archive that never committed".utf8)
            ),
            mutations: [mutation]
        ))
        let replacementJournalURL = try installInterruptedBackupRollback(
            baseDirectory: fixture.root,
            replacementProjectName: "Recovered replacement"
        )

        let restarted = JSONProjectStore.live(baseDirectory: fixture.root)

        #expect(restarted.syncPublicationError == nil)
        #expect(restarted.project(id: fixture.projectID)?.name == "Recovered replacement")
        #expect(!FileManager.default.fileExists(atPath: transactionFile.url.path))
        #expect(!FileManager.default.fileExists(atPath: replacementJournalURL.path))
    }

    @Test func publicReloadReconcilesPendingMarkerBeforeMigration() throws {
        let fixture = try SyncPublicationFixture()
        let sink = RecordingSyncMutationSink()
        let store = fixture.store(sink: sink)
        let current = try fixture.archive()
        let oldArchive = ProjectArchive(
            version: ProjectArchive.currentVersion - 1,
            projects: current.projects,
            yarns: current.yarns,
            patternFolders: current.patternFolders,
            patternAssets: current.patternAssets,
            patterns: current.patterns,
            patternUsages: current.patternUsages
        )
        let oldBytes = try JSONEncoder().encode(oldArchive)
        try oldBytes.write(to: fixture.archiveURL, options: .atomic)
        let mutation = SyncMutation.save(
            SyncEntityID(kind: .project, uuid: fixture.projectID),
            mutationID: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        )
        try SyncPublicationTransactionFile(archiveURL: fixture.archiveURL).write(
            try SyncPublicationTransaction.legacy(
                expectedArchiveSHA256: SyncPublicationTransactionFile.fingerprint(of: oldBytes),
                mutations: [mutation]
            )
        )

        #expect(throws: SyncPublicationError.pendingRepair) {
            try store.reloadFromDisk()
        }

        #expect(store.syncPublicationError == .pendingRepair)
        #expect(try Data(contentsOf: fixture.archiveURL) == oldBytes)
        #expect(sink.mutations.isEmpty)
        try store.repairSyncPublication()
        #expect(sink.mutations == [mutation])
        #expect(try fixture.archive().version == ProjectArchive.currentVersion)
    }

    @Test func corruptPublicationTransactionSurvivesAndFailsClosed() throws {
        let fixture = try SyncPublicationFixture()
        let filesBefore = try fixture.regularFiles()
        let failingSink = RecordingSyncMutationSink(shouldFail: true)
        let first = fixture.store(sink: failingSink)
        try first.rename(id: fixture.projectID, to: "Committed")
        let newRegularFile = try fixture.newRegularFile(comparedWith: filesBefore)
        let transactionURL = try #require(newRegularFile)
        let corruptBytes = Data("not a publication transaction".utf8)
        try corruptBytes.write(to: transactionURL, options: .atomic)

        let restartedSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: restartedSink)

        #expect(restarted.syncPublicationError == .corruptTransaction)
        #expect(throws: SyncPublicationError.corruptTransaction) {
            try restarted.rename(id: fixture.projectID, to: "Blocked")
        }
        #expect(throws: SyncPublicationError.corruptTransaction) {
            try restarted.repairSyncPublication()
        }
        #expect(restartedSink.mutations.isEmpty)
        #expect(try Data(contentsOf: transactionURL) == corruptBytes)
    }

    @Test func corruptOrInvalidAttachmentIssuanceEvidenceFailsClosedWhileKeepingLocalReads() throws {
        for kind in 0..<4 {
            let fixture = try SyncPublicationFixture()
            let first = fixture.store(sink: RecordingSyncMutationSink())
            let project = try #require(first.project(id: fixture.projectID))
            try first.updateProject(
                id: project.id,
                name: project.name,
                toolType: project.toolType,
                toolSize: project.toolSize,
                toolNotes: project.toolNotes,
                photoChange: .replace(try makeSyncPublicationJPEG(red: 0.35))
            )
            let evidenceURL = fixture.liveRoot
                .appendingPathComponent("SyncMetadata", isDirectory: true)
                .appendingPathComponent("attachment-versions.json")
            let original = try Data(contentsOf: evidenceURL)
            let object = try #require(
                JSONSerialization.jsonObject(with: original) as? [String: Any]
            )
            let version = try #require(
                (object["versions"] as? [[String: Any]])?.first
            )
            let corruptBytes: Data
            switch kind {
            case 0:
                corruptBytes = Data("not attachment issuance evidence".utf8)
            case 1:
                var duplicateSlots = object
                duplicateSlots["versions"] = [version, version]
                corruptBytes = try JSONSerialization.data(withJSONObject: duplicateSlots)
            case 2:
                var invalidIdentity = object
                var invalidIdentityVersion = version
                invalidIdentityVersion["conflictGroupID"] = UUID().uuidString
                invalidIdentity["versions"] = [invalidIdentityVersion]
                corruptBytes = try JSONSerialization.data(withJSONObject: invalidIdentity)
            default:
                var invalidMetadata = object
                var invalidMetadataVersion = version
                invalidMetadataVersion["contentSHA256"] = Data([0]).base64EncodedString()
                invalidMetadata["versions"] = [invalidMetadataVersion]
                corruptBytes = try JSONSerialization.data(withJSONObject: invalidMetadata)
            }
            try corruptBytes.write(to: evidenceURL, options: .atomic)
            let sink = RecordingSyncMutationSink()
            let restarted = fixture.store(sink: sink)

            #expect(restarted.project(id: fixture.projectID)?.name == "Original")
            #expect(restarted.syncPublicationError == .corruptTransaction)
            #expect(throws: SyncPublicationError.corruptTransaction) {
                try restarted.rename(id: fixture.projectID, to: "Blocked")
            }
            #expect(sink.mutations.isEmpty)
        }
    }

    @Test func duplicateVersionOrCrossSlotLineageInAttachmentEvidenceFailsClosed() throws {
        struct EvidenceEnvelope: Decodable {
            let versions: [SyncAttachmentVersion]
        }

        for kind in 0..<2 {
            let fixture = try SyncPublicationFixture()
            let first = fixture.store(sink: RecordingSyncMutationSink())
            let project = try #require(first.project(id: fixture.projectID))
            try first.updateProject(
                id: project.id,
                name: project.name,
                toolType: project.toolType,
                toolSize: project.toolSize,
                toolNotes: project.toolNotes,
                photoChange: .replace(try makeSyncPublicationJPEG(red: 0.45))
            )
            let evidenceURL = fixture.liveRoot
                .appendingPathComponent("SyncMetadata", isDirectory: true)
                .appendingPathComponent("attachment-versions.json")
            let original = try Data(contentsOf: evidenceURL)
            let firstVersion = try #require(
                JSONDecoder().decode(EvidenceEnvelope.self, from: original).versions.first
            )
            let otherSlot = SyncAttachmentSlot(
                owner: firstVersion.slot.owner,
                role: firstVersion.slot.role,
                slotID: "secondary"
            )
            let secondVersion = try SyncAttachmentVersion.issuing(
                slot: otherSlot,
                contentSHA256: Data(repeating: 0xC3, count: 32),
                byteCount: 1,
                mediaType: "image/jpeg",
                displayFilename: "secondary.jpg",
                replacesVersionID: kind == 0 ? nil : firstVersion.versionID,
                versionID: kind == 0 ? firstVersion.versionID : UUID()
            )
            var object = try #require(
                JSONSerialization.jsonObject(with: original) as? [String: Any]
            )
            var versions = try #require(object["versions"] as? [Any])
            versions.append(try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(secondVersion)
            ))
            object["versions"] = versions
            try JSONSerialization.data(withJSONObject: object).write(
                to: evidenceURL,
                options: .atomic
            )

            let sink = RecordingSyncMutationSink()
            let restarted = fixture.store(sink: sink)

            #expect(restarted.project(id: fixture.projectID)?.name == "Original")
            #expect(restarted.syncPublicationError == .corruptTransaction)
            #expect(throws: SyncPublicationError.corruptTransaction) {
                try restarted.rename(id: fixture.projectID, to: "Blocked")
            }
            #expect(throws: SyncPublicationError.corruptTransaction) {
                try restarted.repairSyncPublication()
            }
            #expect(sink.mutations.isEmpty)
        }
    }

    @Test func fifoPublicationTransactionIsRejectedWithoutOpeningIt() throws {
        let fixture = try SyncPublicationFixture()
        let transactionURL = SyncPublicationTransactionFile(
            archiveURL: fixture.archiveURL
        ).url
        let created = transactionURL.path.withCString {
            Darwin.mkfifo($0, S_IRUSR | S_IWUSR)
        }
        #expect(created == 0)

        let restarted = fixture.store(sink: RecordingSyncMutationSink())

        #expect(restarted.syncPublicationError == .corruptTransaction)
        #expect(throws: SyncPublicationError.corruptTransaction) {
            try restarted.rename(id: fixture.projectID, to: "Blocked")
        }
    }

    @Test(.timeLimit(.minutes(1))) func restartRejectsFifoArchiveAttachmentWithoutBlocking() throws {
        let fixture = try SyncPublicationFixture()
        let failing = fixture.store(sink: RecordingSyncMutationSink(shouldFail: true))
        let project = try #require(failing.project(id: fixture.projectID))
        try failing.updateProject(
            id: project.id,
            name: project.name,
            toolType: project.toolType,
            toolSize: project.toolSize,
            toolNotes: project.toolNotes,
            photoChange: .replace(try makeSyncPublicationJPEG(red: 0.6))
        )
        #expect(failing.syncPublicationError == .pendingRepair)
        let archive = try fixture.archive()
        let photoFilename = try #require(archive.projects.first?.photoFilename)
        let photoURL = fixture.liveRoot
            .appendingPathComponent("ProjectPhotos", isDirectory: true)
            .appendingPathComponent(photoFilename)
        try FileManager.default.removeItem(at: photoURL)
        #expect(photoURL.path.withCString { Darwin.mkfifo($0, S_IRUSR | S_IWUSR) } == 0)

        let restarted = fixture.store(sink: RecordingSyncMutationSink())

        #expect(restarted.syncPublicationError == .corruptTransaction)
    }

    @Test func oversizedPublicationTransactionIsRejectedFailClosed() throws {
        let fixture = try SyncPublicationFixture()
        let transactionURL = SyncPublicationTransactionFile(
            archiveURL: fixture.archiveURL
        ).url
        try Data(repeating: 0x41, count: 1_024 * 1_024 + 1).write(
            to: transactionURL,
            options: .atomic
        )

        let restarted = fixture.store(sink: RecordingSyncMutationSink())

        #expect(restarted.syncPublicationError == .corruptTransaction)
        #expect(throws: SyncPublicationError.corruptTransaction) {
            try restarted.repairSyncPublication()
        }
    }

    @Test func archiveAndAttachmentFingerprintsUseTheirSemanticByteCaps() throws {
        let fixture = try SyncPublicationFixture()
        let oversizedArchive = fixture.liveRoot.appendingPathComponent("oversized-archive.json")
        let allowedAttachment = fixture.liveRoot.appendingPathComponent("allowed-attachment.bin")
        for url in [oversizedArchive, allowedAttachment] {
            #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(KnitNoteBackupLimits.maximumArchiveBytes + 1))
            try handle.close()
        }
        let transactionFile = SyncPublicationTransactionFile(archiveURL: oversizedArchive)

        #expect(throws: SyncPublicationTransactionFileError.corrupt) {
            _ = try transactionFile.liveArchiveFingerprint(archiveURL: oversizedArchive)
        }
        let evidence = try transactionFile.evidenceForExistingArtifact(
            relativePath: allowedAttachment.lastPathComponent,
            archiveURL: oversizedArchive
        )
        #expect(evidence.expectedSHA256?.count == 32)
    }

    @Test func partialPublicationRetainsWholeIdempotentBatchForLinearRepair() throws {
        let fixture = try SyncPublicationFixture()
        let partialSink = RecordingSyncMutationSink(failureAtAttempt: 2)
        let first = fixture.store(sink: partialSink)
        let project = try #require(first.project(id: fixture.projectID))

        try first.updateProject(
            id: project.id,
            name: "Two records",
            toolType: project.toolType,
            toolSize: project.toolSize,
            toolNotes: project.toolNotes,
            photoChange: .replace(try makeSyncPublicationJPEG(red: 0.45))
        )

        #expect(first.syncPublicationError == .pendingRepair)
        #expect(partialSink.mutations.count == 2)
        let loadedTransaction = try SyncPublicationTransactionFile(
            archiveURL: fixture.archiveURL
        ).load()
        let pending = try #require(loadedTransaction).mutations
        #expect(pending == partialSink.mutations)

        let repairSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: repairSink)
        try restarted.repairSyncPublication()

        #expect(repairSink.mutations == pending)
        #expect(restarted.syncPublicationError == nil)
    }

    @Test func writeThenThrowKeepsReceiptMarkerAndDoesNotPublish() throws {
        let fixture = try SyncPublicationFixture()
        let sink = RecordingSyncMutationSink()
        let store = fixture.store(
            sink: sink,
            archiveWrite: { data, url in
                try data.write(to: url, options: .atomic)
                throw SyncPublicationInjectedFailure()
            }
        )

        try store.rename(id: fixture.projectID, to: "Durable but uncertain")

        #expect(store.project(id: fixture.projectID)?.name == "Durable but uncertain")
        #expect(store.syncPublicationError == .pendingRepair)
        #expect(sink.mutations.isEmpty)
        let loaded = try SyncPublicationTransactionFile(
            archiveURL: fixture.archiveURL
        ).load()
        let pending = try #require(loaded).mutations
        #expect(!pending.isEmpty)

        let repairSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: repairSink)
        #expect(restarted.syncPublicationError == .pendingRepair)
        try restarted.repairSyncPublication()
        #expect(repairSink.mutations == pending)
        #expect(restarted.syncPublicationError == nil)
    }

    @Test func liveFactoryInjectsOneAtomicBatchWhileDefaultScreenshotStyleStoreIsDisabled() throws {
        let enabledFixture = try SyncPublicationFixture()
        let batchSink = BatchRecordingSyncMutationSink()
        let enabled = JSONProjectStore.live(
            baseDirectory: enabledFixture.root,
            syncMutationSink: batchSink
        )

        try enabled.rename(id: enabledFixture.projectID, to: "Enabled")

        #expect(batchSink.batchCount == 1)
        #expect(batchSink.mutations.contains { $0.recordKind == .project })

        let disabledFixture = try SyncPublicationFixture()
        let disabled = JSONProjectStore.live(baseDirectory: disabledFixture.root)
        try disabled.rename(id: disabledFixture.projectID, to: "Screenshot")
        #expect(try SyncPublicationTransactionFile(
            archiveURL: disabledFixture.archiveURL
        ).load() == nil)
    }

    @Test func largeDeletionUsesCachedProjectionAndOneBoundedBatch() throws {
        let fixture = try SyncPublicationFixture()
        let current = try fixture.archive()
        let yarns = try (0..<1_500).map { index in
            try StoredYarn(
                id: syncPerformanceUUID(index),
                name: "Performance yarn \(index)"
            )
        }
        try JSONEncoder().encode(ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: current.projects,
            yarns: yarns
        )).write(to: fixture.archiveURL, options: .atomic)
        let sink = BatchRecordingSyncMutationSink()
        let store = fixture.store(sink: sink)
        let clock = ContinuousClock()

        let firstStart = clock.now
        try store.deleteYarn(id: yarns[0].id)
        let firstDuration = firstStart.duration(to: clock.now)
        let secondStart = clock.now
        try store.deleteYarn(id: yarns[1].id)
        let secondDuration = secondStart.duration(to: clock.now)

        #expect(firstDuration < .seconds(3))
        #expect(secondDuration < .seconds(3))
        #expect(sink.batchCount == 2)
        #expect(sink.mutations.filter {
            $0.intent == .delete && $0.recordKind == .yarn
        }.count == 2)
    }

    @Test func journalSinkSynchronouslyEnqueuesExactMutation() throws {
        let fixture = try SyncPublicationFixture()
        let journal = FileSyncMutationJournal(
            url: fixture.root.appendingPathComponent("sync-mutations.json")
        )
        let sink = JournalSyncMutationSink(journal: journal)
        let mutation = SyncMutation.save(
            SyncEntityID(kind: .project, uuid: fixture.projectID),
            mutationID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        )

        try sink.publish(mutation)

        #expect(try journal.pending() == [mutation])
    }
}

private struct SyncPublicationInjectedFailure: Error {}

private struct RejectingSyncMutationSink: SyncMutationSink {
    func publish(_ mutation: SyncMutation) throws {
        throw SyncPublicationInjectedFailure()
    }

    func publish(_ mutations: [SyncMutation]) throws {
        throw SyncPublicationInjectedFailure()
    }
}

private final class MarkerRemovalFailingJournalSink: SyncMutationSink, @unchecked Sendable {
    private let journal: FileSyncMutationJournal
    private let markerParent: URL

    init(journal: FileSyncMutationJournal, markerParent: URL) {
        self.journal = journal
        self.markerParent = markerParent
    }

    func publish(_ mutation: SyncMutation) throws {
        try publish([mutation])
    }

    func publish(_ mutations: [SyncMutation]) throws {
        try journal.enqueue(mutations)
        guard Darwin.chmod(markerParent.path, S_IRUSR | S_IXUSR) == 0 else {
            throw SyncPublicationInjectedFailure()
        }
    }
}

private func makeOrphanWatchProof(
    command: WatchCounterCommand,
    rejection: WatchCommandRejection,
    processedAt: Date,
    deviceID: String
) throws -> SyncProcessedWatchCommandProof {
    try SyncProcessedWatchCommandProof(
        id: command.id,
        rejection: rejection,
        commandIdentity: .init(command),
        preparedCommand: nil,
        effectProof: nil,
        processingStamp: .init(
            logicalRevision: 0,
            modifiedAt: processedAt,
            deviceID: deviceID
        )
    )
}

private func installOrphanWatchProof(
    _ proof: SyncProcessedWatchCommandProof,
    in liveRoot: URL
) throws {
    let orphan = try SyncOrphanWatchCommandProof(proof: proof)
    let stamp = SyncMutationStamp(
        logicalRevision: 1,
        modifiedAt: proof.processingStamp?.modifiedAt ?? .distantPast,
        deviceID: proof.processingStamp?.deviceID ?? "invalid-orphan-proof"
    )
    let record = SyncRecord(
        schemaVersion: 1,
        id: .init(kind: .watchCommandProof, uuid: proof.id),
        createdAt: proof.commandIdentity?.createdAt ?? stamp.modifiedAt,
        entityRevision: stamp.logicalRevision,
        payload: .init(
            fields: [:],
            atomicDomain: .init(value: .orphanWatchCommandProof(orphan), stamp: stamp)
        ),
        relationships: [],
        deletedAt: .init(value: nil, stamp: stamp)
    )
    let mutation = try SyncMutation.save(
        recordVersion: SyncRecordVersion(record: record),
        mutationID: UUID()
    )
    _ = try SyncAttachmentPublicationEvidenceFile(
        url: liveRoot
            .appendingPathComponent("SyncMetadata", isDirectory: true)
            .appendingPathComponent("attachment-versions.json")
    ).applying([mutation])
}

private func syncPerformanceUUID(_ value: Int) -> UUID {
    UUID(uuidString: String(
        format: "00000000-0000-0000-0000-%012x",
        value + 1
    ))!
}

private final class RecordingSyncMutationSink: SyncMutationSink, @unchecked Sendable {
    private let lock = NSLock()
    private let archiveURL: URL?
    private let shouldFail: Bool
    private let failureAtAttempt: Int?
    private var recordedMutations: [SyncMutation] = []
    private var recordedArchiveProjectNames: [String] = []

    init(
        shouldFail: Bool = false,
        archiveURL: URL? = nil,
        failureAtAttempt: Int? = nil
    ) {
        self.shouldFail = shouldFail
        self.archiveURL = archiveURL
        self.failureAtAttempt = failureAtAttempt
    }

    func publish(_ mutation: SyncMutation) throws {
        let archiveName: String? = try archiveURL.map { url in
            let archive = try JSONDecoder().decode(
                ProjectArchive.self,
                from: Data(contentsOf: url)
            )
            return try #require(archive.projects.first?.name)
        }
        lock.lock()
        recordedMutations.append(mutation)
        if let archiveName {
            recordedArchiveProjectNames.append(archiveName)
        }
        let attempt = recordedMutations.count
        lock.unlock()
        if shouldFail || failureAtAttempt == attempt {
            throw SyncPublicationInjectedFailure()
        }
    }

    var mutations: [SyncMutation] {
        lock.withLock { recordedMutations }
    }

    var archiveProjectNamesAtPublication: [String] {
        lock.withLock { recordedArchiveProjectNames }
    }
}

private final class BatchRecordingSyncMutationSink: SyncMutationSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SyncMutation] = []
    private var batches = 0

    func publish(_ mutation: SyncMutation) throws {
        lock.withLock { recorded.append(mutation) }
    }

    func publish(_ mutations: [SyncMutation]) throws {
        lock.withLock {
            batches += 1
            recorded.append(contentsOf: mutations)
        }
    }

    var mutations: [SyncMutation] { lock.withLock { recorded } }
    var batchCount: Int { lock.withLock { batches } }
}

private extension SyncMutation {
    enum TestOperation: Equatable {
        case save
        case delete
    }

    var recordKind: SyncEntityKind {
        recordID.kind
    }

    var operation: TestOperation {
        switch self {
        case .save: .save
        case .delete: .delete
        }
    }

    var isAttachmentTombstone: Bool {
        recordKind == .attachment
            && savedRecordVersion?.record.deletedAt.value != nil
            && attachmentSource == nil
    }

}

private extension Array where Element == SyncMutation {
    var onlyAttachment: SyncMutation? {
        let attachments = filter { $0.recordKind == .attachment }
        return attachments.count == 1 ? attachments[0] : nil
    }
}

@MainActor private final class SyncPublicationFixture {
    let root: URL
    let liveRoot: URL
    let archiveURL: URL
    let projectID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    let yarnID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    let assetID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
    let patternID = UUID(uuidString: "00000000-0000-0000-0000-000000000104")!
    let usageID = UUID(uuidString: "00000000-0000-0000-0000-000000000105")!
    let legacyPatternID = UUID(uuidString: "00000000-0000-0000-0000-000000000106")!

    init(linkYarn: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "json-project-store-sync-publication-\(UUID().uuidString)",
            isDirectory: true
        )
        liveRoot = root.appendingPathComponent("KnitNote", isDirectory: true)
        archiveURL = liveRoot.appendingPathComponent("projects-v1.json")
        try FileManager.default.createDirectory(at: liveRoot, withIntermediateDirectories: true)
        let project = try StoredProject(id: projectID, name: "Original")
        var yarn = try StoredYarn(id: yarnID, name: "Merino")
        if linkYarn {
            yarn.setLinkedProjectIDs([projectID])
        }
        try JSONEncoder().encode(ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: [project],
            yarns: [yarn]
        )).write(to: archiveURL, options: .atomic)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func store(
        sink: any SyncMutationSink,
        archiveWrite: @escaping @Sendable (Data, URL) throws -> Void = {
            try $0.write(to: $1, options: .atomic)
        },
        evidenceBoundary: @escaping (SyncDurableFileWriteBoundary) throws -> Void = { _ in }
    ) -> JSONProjectStore {
        JSONProjectStore(
            url: archiveURL,
            backupService: KnitNoteBackupService(
                liveRoot: liveRoot,
                workRoot: root.appendingPathComponent("BackupWork", isDirectory: true)
            ),
            archiveWrite: archiveWrite,
            syncAttachmentEvidenceBeforeDurabilityBoundary: evidenceBoundary,
            syncMutationSink: sink
        )
    }

    func archive() throws -> ProjectArchive {
        try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: archiveURL))
    }

    func installPatternUsage() throws -> UUID {
        let patternsRoot = liveRoot.appendingPathComponent("Patterns", isDirectory: true)
        let assetsRoot = patternsRoot.appendingPathComponent("Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsRoot, withIntermediateDirectories: true)
        let filename = "\(assetID.uuidString).pdf"
        let assetURL = assetsRoot.appendingPathComponent(filename)
        try makeTestPatternPDF(at: assetURL)
        let bytes = try Data(contentsOf: assetURL)
        let asset = PatternAsset(
            id: assetID,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            kind: .pdf,
            storedFilename: filename,
            byteCount: Int64(bytes.count),
            pageCount: 1
        )
        let pattern = StoredPattern(
            id: patternID,
            assetID: assetID,
            displayName: "Fixture pattern"
        )
        let usage = PatternProjectUsage(
            id: usageID,
            patternID: patternID,
            projectID: projectID,
            sortOrder: 0
        )
        let current = try archive()
        try JSONEncoder().encode(ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: current.projects,
            yarns: current.yarns,
            patternAssets: [asset],
            patterns: [pattern],
            patternUsages: [usage]
        )).write(to: archiveURL, options: .atomic)
        return usageID
    }

    func installLegacyPattern() throws -> UUID {
        let current = try archive()
        var project = try #require(current.projects.first)
        project.addPattern(PatternDocument(
            id: legacyPatternID,
            displayName: "Legacy fixture",
            kind: .pdf,
            storedFilename: "\(legacyPatternID.uuidString).pdf"
        ))
        let sourceURL = liveRoot
            .appendingPathComponent("Patterns", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("\(legacyPatternID.uuidString).pdf")
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makeTestPatternPDF(at: sourceURL)
        try JSONEncoder().encode(ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: [project],
            yarns: current.yarns
        )).write(to: archiveURL, options: .atomic)
        return legacyPatternID
    }

    func usageMarkupURL(usageID: UUID, pageIndex: Int) -> URL {
        liveRoot.appendingPathComponent("Patterns/UsageMarkup/\(usageID.uuidString)/\(pageIndex).json")
    }

    func legacyMarkupURL(projectID: UUID, patternID: UUID, pageIndex: Int) -> URL {
        liveRoot.appendingPathComponent(
            "Patterns/\(projectID.uuidString)/Markup/\(patternID.uuidString)/\(pageIndex).json"
        )
    }

    func regularFiles() throws -> Set<URL> {
        let children = try FileManager.default.contentsOfDirectory(
            at: liveRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )
        return try Set(children.filter {
            try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        })
    }

    func newRegularFile(comparedWith original: Set<URL>) throws -> URL? {
        let candidates = try regularFiles().subtracting(original).filter { $0 != archiveURL }
        return candidates.count == 1 ? candidates.first : nil
    }

    func projectPhotoFiles() throws -> Set<String> {
        let directory = liveRoot.appendingPathComponent("ProjectPhotos", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }
}

private struct TestBackupReplacementPayload: Codable {
    let version: Int
    let transactionID: UUID
    let rollbackName: String
    let hadLiveRoot: Bool
    let phase: String
}

private extension SyncRecord {
    var counterReminderState: SyncCounterReminderState? {
        guard case let .projectCounter(state)? = payload.atomicDomain?.value else { return nil }
        return state
    }
}

private struct TestBackupReplacementJournal: Codable {
    let version: Int
    let transactionID: UUID
    let rollbackName: String
    let hadLiveRoot: Bool
    let phase: String
    let integrity: String
}

private func installInterruptedBackupRollback(
    baseDirectory: URL,
    replacementProjectName: String
) throws -> URL {
    let liveRoot = baseDirectory.appendingPathComponent("KnitNote", isDirectory: true)
    let archiveURL = liveRoot.appendingPathComponent("projects-v1.json")
    let current = try JSONDecoder().decode(
        ProjectArchive.self,
        from: Data(contentsOf: archiveURL)
    )
    let originalProject = try #require(current.projects.first)
    let replacementProject = try StoredProject(
        id: originalProject.id,
        name: replacementProjectName
    )
    let transactionID = UUID()
    let rollbackName = "Rollback-\(transactionID.uuidString)"
    let workRoot = baseDirectory.appendingPathComponent(
        ".KnitNote-BackupWork",
        isDirectory: true
    )
    let rollbackRoot = workRoot.appendingPathComponent(rollbackName, isDirectory: true)
    try FileManager.default.createDirectory(
        at: rollbackRoot,
        withIntermediateDirectories: true
    )
    try JSONEncoder().encode(ProjectArchive(
        version: ProjectArchive.currentVersion,
        projects: [replacementProject],
        yarns: current.yarns
    )).write(
        to: rollbackRoot.appendingPathComponent("projects-v1.json"),
        options: .atomic
    )

    let payload = TestBackupReplacementPayload(
        version: 1,
        transactionID: transactionID,
        rollbackName: rollbackName,
        hadLiveRoot: true,
        phase: "rollingBack"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let integrity = SHA256.hash(data: try encoder.encode(payload))
        .map { String(format: "%02x", $0) }
        .joined()
    let journal = TestBackupReplacementJournal(
        version: payload.version,
        transactionID: payload.transactionID,
        rollbackName: payload.rollbackName,
        hadLiveRoot: payload.hadLiveRoot,
        phase: payload.phase,
        integrity: integrity
    )
    let journalURL = workRoot.appendingPathComponent(".ReplacementJournal.json")
    try encoder.encode(journal).write(to: journalURL, options: .atomic)
    return journalURL
}

private func syncPublicationMarkup(color: MarkupColor) -> PatternMarkupDocument {
    PatternMarkupDocument(strokes: [.init(
        points: [.init(x: 0.25, y: 0.75)],
        color: color,
        width: 0.008
    )])
}

private func makeSyncPublicationJPEG(red: CGFloat) throws -> Data {
    let context = try #require(CGContext(
        data: nil,
        width: 16,
        height: 16,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: red, green: 0.4, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}
