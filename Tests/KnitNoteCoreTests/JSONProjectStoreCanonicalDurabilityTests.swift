import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

struct JSONProjectStoreCanonicalDurabilityTests {
    @Test @MainActor func recoveredCurrentOwnershipActivatesThenReopensCanonicalWithoutBootstrap() async throws {
        let f = try Fixture()
        var stores: [JSONProjectStore] = []
        func exercise() throws {
            let current = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
            var frozen = true
            let transaction = try SyncBootstrapTransaction(liveRoot: f.live, context: current, validateContext: { candidate in
                guard frozen, candidate == current else { throw SyncBootstrapError.contextChanged }
            })
            #expect(try f.checkpoints.load() == nil)
            let handoff = try #require(try transaction.recoverUnderCurrentContext())
            #expect(handoff.transactionID == f.handoff.transactionID)
            let store = f.store(); stores.append(store)
            try store.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: handoff, attachmentSources: [:])
            let initial = try #require(try f.checkpoints.load())
            #expect(initial.records == handoff.checkpoint.records)
            frozen = false
            #expect(throws: SyncBootstrapError.contextChanged) { try handoff.revalidate() }
            store.revokeSessionWrites()
            let reopened = f.store(journal: f.freshJournal()); stores.append(reopened)
            try reopened.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: nil, attachmentSources: [:])
            #expect(reopened.projects.first?.id == f.projectID)
            #expect(try f.checkpoints.load() == initial)
            try f.rename(reopened, "After restart")
            #expect(reopened.syncPublicationError == nil)
            let edited = try #require(try f.checkpoints.load())
            #expect(edited.commitID != initial.commitID)
            frozen = true
            #expect(throws: (any Error).self) { try transaction.recoverUnderCurrentContext() }
            #expect(try f.checkpoints.load() == edited)
        }
        let result = Result { try exercise() }
        for store in stores { store.revokeSessionWrites() }
        // Join independently of the test body's result before deleting its root.
        for store in stores { try await store.waitForTrackedBackgroundWritesAfterRevocation() }
        f.remove()
        try result.get()
    }

    @Test(arguments: SyncCanonicalPublicationBoundary.allCases)
    @MainActor func everyPublicationBoundaryReopensExactDurableAuthority(boundary: SyncCanonicalPublicationBoundary) throws {
        let f = try Fixture(); defer { f.remove() }
        var journal: FileSyncMutationJournal? = f.freshJournal()
        var fired = false
        var store: JSONProjectStore? = f.store(journal: journal!, boundary: { reached in
            if reached == boundary && !fired { fired = true; throw SyncPublicationError.pendingRepair }
        })
        try store!.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: f.handoff, attachmentSources: [:])
        let predecessor = try #require(try f.checkpoints.load())
        let previousPending = try journal!.pending()
        if boundary == .afterIntent {
            #expect(throws: SyncPublicationError.pendingRepair) { try f.rename(store!, "After") }
        } else { try f.rename(store!, "After") }
        #expect(fired)
        let marker = SyncPublicationTransactionFile(archiveURL: f.archiveURL)
        let transaction = try #require(try marker.load())
        let expected = boundary == .afterIntent ? predecessor : try #require(transaction.canonicalTransition?.candidate)
        let expectedPending = boundary == .afterIntent ? previousPending : previousPending + transaction.mutations
        store = nil; journal = nil
        for _ in 0..<2 {
            let journal = f.freshJournal()
            let reopened = f.store(journal: journal)
            try reopened.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: nil, attachmentSources: [:])
            let recovered = try #require(try f.checkpoints.load())
            #expect(recovered.records == expected.records)
            #expect(recovered.commitID == expected.commitID)
            #expect(try journal.pending() == expectedPending)
            #expect(Set(try journal.pending().map(\.identity)).count == (try journal.pending().count))
            #expect(reopened.projects.first?.name == (boundary == .afterIntent ? "Before" : "After"))
            #expect(try marker.load() == nil)
        }
    }

    @Test(arguments: [false, true]) @MainActor func committedCanonicalSurvivesAcknowledgementAndReopen(remoteRevisions: Bool) throws {
        let f = try Fixture(remoteRevisions: remoteRevisions); defer { f.remove() }
        let store = f.store()
        try store.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: f.handoff, attachmentSources: [:])
        let initial = try #require(try f.checkpoints.load())
        if remoteRevisions { #expect(initial.records.allSatisfy { $0.entityRevision == 99 }) }
        try f.rename(store, "After")
        let committed = try #require(try f.checkpoints.load())
        #expect(committed.commitID != initial.commitID)
        #expect(committed.records.count == initial.records.count)
        let unchanged = initial.records.filter { $0.id.kind == .projectCounter }
        #expect(committed.records.filter { $0.id.kind == .projectCounter } == unchanged)
        try f.journal.acknowledge(Set(try f.journal.pending().map(\.identity)))
        #expect(try f.journal.pending().isEmpty)
        let reopened = f.store()
        try reopened.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: nil, attachmentSources: [:])
        #expect(try f.checkpoints.load() == committed)
        try f.rename(reopened, "Again")
        let next = try #require(try f.checkpoints.load())
        #expect(next.commitID != committed.commitID)
        #expect(next.records.first { $0.id.uuid == f.projectID }!.entityRevision > committed.records.first { $0.id.uuid == f.projectID }!.entityRevision)
    }

    @Test @MainActor func localEditAfterRemoteCommitCarriesReceiptUnchanged() throws {
        let f = try Fixture(); defer { f.remove() }
        let store = f.store()
        try store.activateSyncCanonicalState(
            checkpointStore: f.checkpoints,
            bootstrap: f.handoff,
            attachmentSources: [:]
        )
        let receipt = try f.installRemoteReceipt()
        let reopened = f.store()
        try reopened.activateSyncCanonicalState(
            checkpointStore: f.checkpoints,
            bootstrap: nil,
            attachmentSources: [:]
        )

        try f.rename(reopened, "After remote")

        #expect(try f.checkpoints.load()?.remoteBatchReceipts == [receipt])
    }

    @Test @MainActor func localDeleteAndRestoreCarryRemoteReceiptUnchanged() throws {
        let f = try Fixture(); defer { f.remove() }
        let store = f.store()
        try store.activateSyncCanonicalState(
            checkpointStore: f.checkpoints,
            bootstrap: f.handoff,
            attachmentSources: [:]
        )
        let receipt = try f.installRemoteReceipt()
        let receiptStore = f.store()
        try receiptStore.activateSyncCanonicalState(
            checkpointStore: f.checkpoints,
            bootstrap: nil,
            attachmentSources: [:]
        )

        try receiptStore.delete(id: f.projectID)
        #expect(try f.checkpoints.load()?.remoteBatchReceipts == [receipt])
        let ledger = try SyncDeletionLedger(
            root: SyncDeletionLedger.root(archiveURL: f.archiveURL)
        )
        let entry = try #require(try ledger.recentlyDeleted().first)
        try f.journal.acknowledge(Set(try f.journal.pending().map(\.identity)))
        let reopened = f.store()
        try reopened.activateSyncCanonicalState(
            checkpointStore: f.checkpoints,
            bootstrap: nil,
            attachmentSources: [:]
        )

        try reopened.restoreRecentlyDeleted(
            id: entry.id,
            now: entry.deletedAt.addingTimeInterval(29 * 24 * 60 * 60)
        )

        #expect(try f.checkpoints.load()?.remoteBatchReceipts == [receipt])
    }

    @Test @MainActor func noOpDoesNotReplaceCanonicalOrRepublish() throws {
        let f = try Fixture(); defer { f.remove() }
        let store = f.store()
        try store.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: f.handoff, attachmentSources: [:])
        let prior = try f.checkpoints.load()
        let bytes = try Data(contentsOf: f.archiveURL)
        let pending = try f.journal.pending()
        try f.rename(store, "Before")
        #expect(try f.checkpoints.load() == prior)
        #expect(try Data(contentsOf: f.archiveURL) == bytes)
        #expect(try f.journal.pending() == pending)
    }

    @Test @MainActor func rawBootstrapCheckpointCannotAuthorizeDailyCreation() throws {
        let f = try Fixture(); defer { f.remove() }
        let store = f.store()
        try store.hydrateSyncBootstrap(f.handoff.checkpoint)
        #expect(throws: (any Error).self) {
            try store.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: nil, attachmentSources: [:])
        }
        #expect(try f.checkpoints.load() == nil)
        #expect(throws: (any Error).self) { try f.rename(store, "Unauthorized") }
    }

    @Test(arguments: ["archive", "receipt", "root"])
    @MainActor func staleHandoffCannotInstall(kind: String) throws {
        let f = try Fixture(); defer { f.remove() }
        if kind == "archive" {
            let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [try StoredProject(name: "Foreign")])
            try JSONEncoder().encode(archive).write(to: f.archiveURL)
        } else if kind == "receipt" {
            try Data("invalid".utf8).write(to: f.live.appendingPathComponent("SyncMetadata/bootstrap-receipt.json"))
        } else {
            let moved = f.root.appendingPathComponent("Moved")
            try FileManager.default.moveItem(at: f.live, to: moved)
            try FileManager.default.copyItem(at: moved, to: f.live)
        }
        let store = f.store()
        #expect(throws: (any Error).self) {
            try store.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: f.handoff, attachmentSources: [:])
        }
        #expect(!FileManager.default.fileExists(atPath: f.live.appendingPathComponent("SyncMetadata/canonical.json").path))
    }

    @Test(arguments: [SyncDurableFileWriteBoundary.beforeFileSync, .beforeRename, .beforeDirectorySync])
    @MainActor func committedFaultRecoversExactCandidate(boundary: SyncDurableFileWriteBoundary) throws {
        let f = try Fixture(); defer { f.remove() }
        let fault = Fault()
        let checkpoints = try f.checkpointStore { if fault.armed && $0 == boundary { throw SyncPublicationError.pendingRepair } }
        let store = f.store()
        try store.activateSyncCanonicalState(checkpointStore: checkpoints, bootstrap: f.handoff, attachmentSources: [:])
        fault.armed = true
        try f.rename(store, "After")
        #expect(store.projects.first?.name == "After")
        #expect(store.syncPublicationError == .pendingRepair)
        #expect(throws: SyncPublicationError.pendingRepair) { try f.rename(store, "Blocked") }
        let file = SyncPublicationTransactionFile(archiveURL: f.archiveURL)
        let transaction = try #require(try file.load())
        let candidate = try #require(transaction.canonicalTransition?.candidate)
        let pending = try f.journal.pending()
        // A second durability failure must retain the same marker and journal
        // identities, including when rename already installed the candidate.
        let failedRetry = f.store(journal: f.freshJournal())
        #expect(throws: (any Error).self) {
            try failedRetry.activateSyncCanonicalState(checkpointStore: checkpoints, bootstrap: nil, attachmentSources: [:])
        }
        #expect(try file.load() == transaction)
        #expect(try f.freshJournal().pending() == pending)
        fault.armed = false
        let reopened = f.store(journal: f.freshJournal())
        try reopened.activateSyncCanonicalState(checkpointStore: checkpoints, bootstrap: nil, attachmentSources: [:])
        #expect(try checkpoints.load() == candidate)
        #expect(try f.journal.pending() == pending)
        #expect(try file.load() == nil)
        let second = f.store(journal: f.freshJournal())
        try second.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: nil, attachmentSources: [:])
        #expect(try f.checkpoints.load()?.records == candidate.records)
        #expect(try f.checkpoints.load()?.commitID == candidate.commitID)
        #expect(Set(try f.freshJournal().pending().map(\.identity)).count == pending.count)
        try f.rename(reopened, "Again")
        #expect(try checkpoints.load()?.commitID != candidate.commitID)
    }

    @Test(arguments: ["missing", "corrupt", "foreign"])
    @MainActor func missingOrCorruptDailyWithTransitionCannotFallBackToBootstrap(kind: String) throws {
        let f = try Fixture(); defer { f.remove() }
        let fault = Fault()
        let checkpoints = try f.checkpointStore { if fault.armed && $0 == .beforeRename { throw SyncPublicationError.pendingRepair } }
        let store = f.store()
        try store.activateSyncCanonicalState(checkpointStore: checkpoints, bootstrap: f.handoff, attachmentSources: [:])
        fault.armed = true
        try f.rename(store, "After")
        let marker = SyncPublicationTransactionFile(archiveURL: f.archiveURL)
        let bytes = try Data(contentsOf: marker.url)
        let dailyURL = f.live.appendingPathComponent("SyncMetadata/canonical.json")
        if kind == "missing" { try FileManager.default.removeItem(at: dailyURL) }
        else if kind == "corrupt" { try Data("broken".utf8).write(to: dailyURL) }
        else {
            let prior = try #require(try checkpoints.load())
            let foreign = try SyncCanonicalCheckpoint(accountIDHash: prior.accountIDHash, commitID: UUID(),
                archiveSHA256: prior.archiveSHA256, records: prior.records, legacyRecordIDsToDelete: [])
            try foreign.encoded().write(to: dailyURL)
        }
        fault.armed = false
        let reopened = f.store()
        #expect(throws: (any Error).self) {
            try reopened.activateSyncCanonicalState(checkpointStore: checkpoints, bootstrap: f.handoff, attachmentSources: [:])
        }
        #expect(try Data(contentsOf: marker.url) == bytes)
        #expect(throws: (any Error).self) { try reopened.repairSyncPublication() }
        #expect(try Data(contentsOf: marker.url) == bytes)
    }

    @Test @MainActor func uncommittedTransitionWaitsForVerifiedPredecessorBeforeRemoval() throws {
        let f = try Fixture(); defer { f.remove() }
        let store = f.store()
        try store.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: f.handoff, attachmentSources: [:])
        let prior = try #require(try f.checkpoints.load())
        let candidate = try SyncCanonicalCheckpoint(accountIDHash: prior.accountIDHash, commitID: UUID(),
            archiveSHA256: Data(repeating: 4, count: 32), records: prior.records, legacyRecordIDsToDelete: [])
        let transaction = try SyncPublicationTransaction(expectedArchiveSHA256: candidate.archiveSHA256, mutations: [], revisionReceipts: [],
            canonicalTransition: .init(predecessorSHA256: Data(SHA256.hash(data: prior.encoded())), candidate: candidate))
        let file = SyncPublicationTransactionFile(archiveURL: f.archiveURL)
        try file.write(transaction)
        let reopened = f.store()
        #expect(try file.load() == transaction)
        #expect(throws: (any Error).self) { try reopened.repairSyncPublication() }
        #expect(try file.load() == transaction)
        try reopened.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: nil, attachmentSources: [:])
        #expect(try f.checkpoints.load() == prior)
        #expect(try file.load() == nil)
    }

    @Test @MainActor func disabledSyncKeepsLocalBehavior() throws {
        let f = try Fixture(); defer { f.remove() }
        let store = JSONProjectStore(url: f.archiveURL)
        try f.rename(store, "Offline")
        #expect(store.projects.first?.name == "Offline")
        #expect(try f.checkpoints.load() == nil)
        #expect(throws: SyncPublicationError.sinkUnavailable) {
            try store.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: f.handoff, attachmentSources: [:])
        }
    }

    private final class Fault { var armed = false }

    @Test(arguments: [false, true]) @MainActor func subsecondWatchProofsSurviveConsecutiveCommands(canonical: Bool) throws {
        let f = try Fixture(); defer { f.remove() }
        let store = f.store()
        if canonical { try store.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: f.handoff, attachmentSources: [:]) }
        else { try store.hydrateSyncBootstrap(f.handoff.checkpoint) }
        let counters = try #require(store.projects.first?.counters)
        for index in 0..<2 {
            let outgoing = WatchCounterCommand(projectID: f.projectID, counterID: counters[index].id, operation: .increment,
                createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000.000002 + Double(index)))
            let command = try WatchSyncCodec.decode(WatchCounterCommand.self, from: WatchSyncCodec.encode(outgoing))
            var decoded = command
            for _ in 0..<3 {
                decoded = try WatchSyncCodec.decode(WatchCounterCommand.self, from: WatchSyncCodec.encode(decoded))
                #expect(decoded == command)
            }
            let now = Date(timeIntervalSinceReferenceDate: 800_000_010.000002 + Double(index))
            _ = try store.applyWatchCommandDurably(command, ledgerURL: WatchSyncPaths.processedLedger(in: f.live),
                preparedCommandURL: WatchSyncPaths.preparedCommand(in: f.live), now: now)
            let ledger = try #require(try AtomicWatchSyncFile<ProcessedWatchCommandLedger>(url: WatchSyncPaths.processedLedger(in: f.live)).load())
            let diskProof = try #require(try ledger.entries.compactMap { try SyncProcessedWatchCommandProof(entry: $0) }.first { $0.id == command.id })
            let issued = try #require(try f.journal.pending().compactMap { mutation -> SyncCounterReminderState? in
                if case let .projectCounter(state)? = mutation.savedRecordVersion?.record.payload.atomicDomain?.value { return state }; return nil
            }
                .flatMap(\.processedCommandProofs).first { $0.id == command.id })
            #expect(issued == diskProof)
            #expect(issued.commandIdentity == ProcessedWatchCommandIdentity(command))
            let stamp = try #require(issued.processingStamp)
            #expect(stamp.logicalRevision == 0)
            #expect(!stamp.deviceID.isEmpty)
            var roundTrip = stamp
            for _ in 0..<3 {
                roundTrip = try WatchSyncCodec.decode(SyncMutationStamp.self, from: WatchSyncCodec.encode(roundTrip))
                #expect(roundTrip == stamp)
            }
            let pending = try f.journal.pending()
            _ = try store.applyWatchCommandDurably(command, ledgerURL: WatchSyncPaths.processedLedger(in: f.live),
                preparedCommandURL: WatchSyncPaths.preparedCommand(in: f.live), now: now.addingTimeInterval(0.5))
            #expect(try f.journal.pending() == pending)
        }
    }

    @Test @MainActor func allSixCounterWatchStatesKeepExactProofsAcrossTwoReopens() throws {
        let f = try Fixture(); defer { f.remove() }
        var store: JSONProjectStore? = f.store()
        try store!.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: f.handoff, attachmentSources: [:])
        let counters = try #require(store!.projects.first?.counters)
        #expect(counters.count == 6)
        let commands = try counters.enumerated().map {
            let outgoing = WatchCounterCommand(projectID: f.projectID, counterID: $0.element.id,
                operation: .increment, createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000.000002 + Double($0.offset) * 2))
            return try WatchSyncCodec.decode(WatchCounterCommand.self, from: WatchSyncCodec.encode(outgoing))
        }
        for (index, command) in commands.enumerated() {
            let acknowledgement = try store!.applyWatchCommandDurably(command,
                ledgerURL: WatchSyncPaths.processedLedger(in: f.live),
                preparedCommandURL: WatchSyncPaths.preparedCommand(in: f.live),
                now: Date(timeIntervalSinceReferenceDate: 800_000_001.000002 + Double(index) * 2))
            #expect(acknowledgement.rejection == nil)
        }
        let expected = try #require(try f.checkpoints.load())
        let states = expected.records.compactMap { record -> SyncCounterReminderState? in
            if case let .projectCounter(state)? = record.payload.atomicDomain?.value { return state }; return nil
        }
        #expect(states.count == 6)
        for command in commands {
            let state = try #require(states.first { $0.counter.id == command.counterID })
            #expect(state.counter.value == 1)
            #expect(state.processedCommandIDs == [command.id])
            #expect(state.processedCommandProofs.map(\.id) == [command.id])
        }
        try f.journal.acknowledge(Set(try f.journal.pending().map(\.identity)))
        store = nil
        for _ in 0..<2 {
            let journal = f.freshJournal()
            let reopened = f.store(journal: journal)
            try reopened.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: nil, attachmentSources: [:])
            let recovered = try #require(try f.checkpoints.load())
            #expect(recovered.records == expected.records)
            #expect(recovered.commitID == expected.commitID)
            #expect(reopened.projects.first?.counters.map(\.value) == [1, 1, 1, 1, 1, 1])
            #expect(try journal.pending().isEmpty)
            for command in commands {
                _ = try reopened.applyWatchCommandDurably(command, ledgerURL: WatchSyncPaths.processedLedger(in: f.live),
                    preparedCommandURL: WatchSyncPaths.preparedCommand(in: f.live), now: .now)
            }
            #expect(reopened.projects.first?.counters.map(\.value) == [1, 1, 1, 1, 1, 1])
            #expect(try f.checkpoints.load() == expected)
        }
    }

    @Test(arguments: [WatchCommandPersistenceBoundary.afterPreparedCommandSave, .afterProjectArchiveSave, .afterLedgerSave])
    @MainActor func interruptedSubsecondWatchCommandRecoversWithoutReissuingProof(boundary: WatchCommandPersistenceBoundary) throws {
        let f = try Fixture(); defer { f.remove() }
        var store: JSONProjectStore? = f.store()
        try store!.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: f.handoff, attachmentSources: [:])
        let counterID = try #require(store!.projects.first?.counters.first?.id)
        let outgoing = WatchCounterCommand(projectID: f.projectID, counterID: counterID, operation: .increment,
            createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000.000002))
        let command = try WatchSyncCodec.decode(WatchCounterCommand.self, from: WatchSyncCodec.encode(outgoing))
        #expect(throws: SyncPublicationError.pendingRepair) {
            try store!.applyWatchCommandDurably(command, ledgerURL: WatchSyncPaths.processedLedger(in: f.live),
                preparedCommandURL: WatchSyncPaths.preparedCommand(in: f.live),
                now: Date(timeIntervalSinceReferenceDate: 800_000_001.000002),
                failureInjector: { if $0 == boundary { throw SyncPublicationError.pendingRepair } })
        }
        store = nil
        let journal = f.freshJournal(), reopened = f.store(journal: f.freshJournal())
        try reopened.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: nil, attachmentSources: [:])
        #expect(try reopened.recoverWatchCommandPersistence(ledgerURL: WatchSyncPaths.processedLedger(in: f.live),
            preparedCommandURL: WatchSyncPaths.preparedCommand(in: f.live),
            now: Date(timeIntervalSinceReferenceDate: 800_000_002.000002)) == .ready)
        let expected = try #require(try f.checkpoints.load())
        #expect(reopened.projects.first?.counters.first?.value == 1)
        let states = expected.records.compactMap { record -> SyncCounterReminderState? in
            if case let .projectCounter(state)? = record.payload.atomicDomain?.value, state.counter.id == counterID { return state }; return nil
        }
        let state = try #require(states.first)
        #expect(state.processedCommandIDs == [command.id])
        #expect(state.processedCommandProofs.count == 1)
        #expect(state.processedCommandProofs[0].commandIdentity == ProcessedWatchCommandIdentity(command))
        let pending = try journal.pending()
        let second = f.store(journal: f.freshJournal())
        try second.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: nil, attachmentSources: [:])
        _ = try second.applyWatchCommandDurably(command, ledgerURL: WatchSyncPaths.processedLedger(in: f.live),
            preparedCommandURL: WatchSyncPaths.preparedCommand(in: f.live), now: .now)
        #expect(try f.checkpoints.load() == expected)
        #expect(try journal.pending() == pending)
        #expect(second.projects.first?.counters.first?.value == 1)
    }

    @Test @MainActor func watchMetadataAdvancesCanonicalWithIdenticalArchiveAndReopensExactly() throws {
        let f = try Fixture(); defer { f.remove() }
        let store = f.store()
        try store.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: f.handoff, attachmentSources: [:])
        let before = try #require(try f.checkpoints.load())
        let bytes = try Data(contentsOf: f.archiveURL)
        let command = WatchCounterCommand(projectID: f.projectID, counterID: UUID(), operation: .increment, createdAt: .now)
        let acknowledgement = try store.applyWatchCommandDurably(command,
            ledgerURL: WatchSyncPaths.processedLedger(in: f.live),
            preparedCommandURL: WatchSyncPaths.preparedCommand(in: f.live), now: .now)
        #expect(acknowledgement.rejection == .counterMissing)
        #expect(try Data(contentsOf: f.archiveURL) == bytes)
        let after = try #require(try f.checkpoints.load())
        #expect(after.archiveSHA256 == before.archiveSHA256)
        #expect(after.commitID != before.commitID)
        #expect(after.records.count == before.records.count + 1)
        #expect(after.records.contains { if case .orphanWatchCommandProof? = $0.payload.atomicDomain?.value { return true }; return false })
        try f.journal.acknowledge(Set(try f.journal.pending().map(\.identity)))
        let reopened = f.store()
        try reopened.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: nil, attachmentSources: [:])
        #expect(try f.checkpoints.load() == after)
        try f.rename(reopened, "After Watch")
        let final = try #require(try f.checkpoints.load())
        #expect(final.records.filter { $0.id.kind != .project } == after.records.filter { $0.id.kind != .project })
    }

    @Test(arguments: ["evidence", "media"])
    @MainActor func missingAttachmentEvidenceOrLiveMediaBlocksActivation(kind: String) throws {
        let f = try Fixture(media: true); defer { f.remove() }
        if kind == "evidence" {
            try FileManager.default.removeItem(at: f.live.appendingPathComponent("SyncMetadata/attachment-versions.json"))
            try FileManager.default.removeItem(at: f.live.appendingPathComponent("SyncMetadata/attachment-versions.attachment-records"))
        } else {
            let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: f.archiveURL))
            let photo = try #require(archive.projects[0].photoFilename)
            try FileManager.default.removeItem(at: f.live.appendingPathComponent("ProjectPhotos/" + photo))
        }
        let store = f.store()
        #expect(throws: (any Error).self) {
            try store.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: f.handoff, attachmentSources: [:])
        }
        #expect(try f.checkpoints.load() == nil)
    }

    @Test @MainActor func photoReplacementPreservesPredecessorRecordsAcrossAcknowledgement() throws {
        let f = try Fixture(media: true); defer { f.remove() }
        let store = f.store()
        try store.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: f.handoff, attachmentSources: [:])
        let original = try #require(try f.checkpoints.load())
        let oldAttachment = try #require(original.records.first { $0.id.kind == .attachment })
        try store.updateProject(id: f.projectID, name: "Before", toolType: nil, toolSize: nil, toolNotes: nil,
            photoChange: .replace(BackupFixture.jpegData(red: 0.9)))
        #expect(store.syncPublicationError == nil)
        let after = try #require(try f.checkpoints.load())
        #expect(after.records.contains(oldAttachment))
        let newAttachment = try #require(after.records.first { $0.id.kind == .attachment && $0.id != oldAttachment.id })
        #expect(newAttachment.payload.attachment?.replacesVersionID == oldAttachment.id.uuid)
        try f.rename(store, "Same instance")
        #expect(store.syncPublicationError == nil)
        try f.journal.acknowledge(Set(try f.journal.pending().map(\.identity)))
        let reopened = f.store()
        try reopened.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: nil, attachmentSources: [:])
        #expect(try f.checkpoints.load()?.records.filter { $0.id.kind == .attachment } == after.records.filter { $0.id.kind == .attachment })
        try f.rename(reopened, "Again")
        #expect(try f.checkpoints.load()?.records.filter { $0.id.kind == .attachment } == after.records.filter { $0.id.kind == .attachment })
    }

    @Test @MainActor func partialCheckpointTemporaryRemainsBlockedAndPreserved() throws {
        let f = try Fixture(); defer { f.remove() }
        let store = f.store()
        try store.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: f.handoff, attachmentSources: [:])
        let prior = try f.checkpoints.load()
        let temporary = f.live.appendingPathComponent("SyncMetadata/.canonical-next.json")
        let partial = Data("{\"formatVersion\":".utf8)
        try partial.write(to: temporary)
        let reopened = f.store()
        #expect(throws: (any Error).self) {
            try reopened.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: nil, attachmentSources: [:])
        }
        #expect(try Data(contentsOf: temporary) == partial)
        #expect(try f.checkpoints.load() == prior)
    }

    @Test @MainActor func missingPendingAttachmentBytesBlockDespiteValidDisplayedPhoto() throws {
        let f = try Fixture(media: true); defer { f.remove() }
        let store = f.store()
        try store.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: f.handoff, attachmentSources: [:])
        let prior = try f.checkpoints.load()
        let pending = try f.journal.pending()
        let source = try #require(pending.compactMap { mutation -> SyncAttachmentSource? in
            if case let .save(save) = mutation { return save.attachmentSource }; return nil
        }.first)
        #expect(source.isJournalStaged)
        try FileManager.default.removeItem(at: source.fileURL)
        let reopened = f.store()
        #expect(throws: (any Error).self) {
            try reopened.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: nil, attachmentSources: [:])
        }
        #expect(try f.checkpoints.load() == prior)
    }

    @Test @MainActor func unsupportedDailyArchiveRemainsUntouchedAndBlocked() throws {
        let f = try Fixture(); defer { f.remove() }
        let store = f.store()
        try store.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: f.handoff, attachmentSources: [:])
        let prior = try #require(try f.checkpoints.load())
        let archive = ProjectArchive(version: ProjectArchive.currentVersion + 1, projects: [try StoredProject(name: "Future")])
        let data = try JSONEncoder().encode(archive)
        try data.write(to: f.archiveURL)
        let incompatible = try SyncCanonicalCheckpoint(accountIDHash: prior.accountIDHash, commitID: UUID(),
            archiveSHA256: Data(SHA256.hash(data: data)), records: prior.records, legacyRecordIDsToDelete: [])
        try f.checkpoints.install(incompatible, replacing: Data(SHA256.hash(data: prior.encoded())))
        let reopened = f.store()
        #expect(throws: (any Error).self) {
            try reopened.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: f.handoff, attachmentSources: [:])
        }
        #expect(try Data(contentsOf: f.archiveURL) == data)
        #expect(try f.checkpoints.load() == incompatible)
    }

    @Test @MainActor func wrongAccountOrRootCheckpointStoreCannotActivate() throws {
        let f = try Fixture(); defer { f.remove() }
        let wrong = try SyncAccountIdentity(containerIdentifier: "test.container", userRecordName: "other")
        let wrongAccount = try SyncCanonicalCheckpointStore(liveRoot: f.live, account: wrong, validateOwnership: {})
        let otherRoot = f.root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let wrongRoot = try SyncCanonicalCheckpointStore(liveRoot: otherRoot, account: f.account, validateOwnership: {})
        for checkpoints in [wrongAccount, wrongRoot] {
            let store = f.store()
            #expect(throws: (any Error).self) {
                try store.activateSyncCanonicalState(checkpointStore: checkpoints, bootstrap: f.handoff, attachmentSources: [:])
            }
            #expect(try checkpoints.load() == nil)
        }
    }

    @Test @MainActor func missingUnselectedConflictHeadCannotUseDisplayedWinnerAsEvidence() throws {
        let f = try Fixture(media: true, conflict: true); defer { f.remove() }
        let lineage = try SyncAttachmentLineage(records: f.handoff.checkpoint.records)
        let selected = Set(lineage.resolvedLiveVersionIDs().values)
        let records = f.handoff.checkpoint.records.filter { $0.id.kind == .attachment }
        #expect(records.count == 2)
        let sources = try Dictionary(uniqueKeysWithValues: records.map { record in
            let version = try #require(record.payload.attachment)
            return (record.id.uuid, try SyncAttachmentSource(fileURL: f.live.appendingPathComponent("ProjectPhotos/" + version.displayFilename),
                contentSHA256: version.contentSHA256, byteCount: version.byteCount))
        })
        let incomplete = sources.filter { selected.contains($0.key) }
        let store = f.store()
        #expect(throws: (any Error).self) {
            try store.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: f.handoff, attachmentSources: incomplete)
        }
        #expect(try f.checkpoints.load() == nil)
        try store.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: f.handoff, attachmentSources: sources)
        #expect(try f.checkpoints.load()?.records.filter { $0.id.kind == .attachment }.count == 2)
    }

    @Test(arguments: [false, true]) @MainActor func bothMarkupFamiliesPreserveExactSourceAndReopenCheckpoint(usage: Bool) throws {
        let f = try Fixture(pattern: !usage, usage: usage); defer { f.remove() }
        let store = f.store()
        try store.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: f.handoff, attachmentSources: [:])
        let before = try #require(try f.checkpoints.load())
        let data = try Data(contentsOf: f.archiveURL)
        let patternID = try #require(usage ? store.patternUsages.first?.id : store.projects.first?.patterns.first?.id)
        let source = try #require(before.records.first { $0.payload.attachment != nil })
        let originalArchive = try JSONDecoder().decode(ProjectArchive.self, from: data)
        let sourceURL = usage
            ? f.live.appendingPathComponent("Patterns/Assets/" + originalArchive.patternAssets[0].storedFilename)
            : f.live.appendingPathComponent("Patterns/" + f.projectID.uuidString + "/" + originalArchive.projects[0].patterns[0].storedFilename)
        let sourceBytes = try Data(contentsOf: sourceURL)
        let markup = PatternMarkupDocument(strokes: [.init(points: [.init(x: 0.25, y: 0.75)], color: .green, width: 0.008)])
        func save() throws {
            if usage { try store.savePatternMarkup(markup, usageID: patternID, pageIndex: 0, expectedDataGeneration: store.dataGeneration) }
            else { try store.savePatternMarkup(markup, projectID: f.projectID, patternID: patternID, pageIndex: 0, expectedDataGeneration: store.dataGeneration) }
        }
        try save()
        #expect(store.syncPublicationError == nil)
        let after = try #require(try f.checkpoints.load())
        #expect(after.commitID != before.commitID)
        if usage {
            // Usage markup advances the archive's optimistic-lock revision.
            #expect(after.archiveSHA256 != before.archiveSHA256)
            #expect(after.archiveSHA256 == Data(SHA256.hash(data: try Data(contentsOf: f.archiveURL))))
        } else {
            #expect(after.archiveSHA256 == before.archiveSHA256)
            #expect(try Data(contentsOf: f.archiveURL) == data)
        }
        #expect(after.records.count == before.records.count + 1)
        #expect(after.records.contains(source))
        try save()
        #expect(try f.checkpoints.load() == after)
        try f.journal.acknowledge(Set(try f.journal.pending().map(\.identity)))
        for _ in 0..<2 {
            let reopened = f.store(journal: f.freshJournal())
            try reopened.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: nil, attachmentSources: [:])
            #expect(try f.checkpoints.load() == after)
            let loaded = try usage ? reopened.loadPatternMarkup(usageID: patternID, pageIndex: 0)
                : reopened.loadPatternMarkup(projectID: f.projectID, patternID: patternID, pageIndex: 0)
            #expect(loaded == markup)
            #expect(try Data(contentsOf: sourceURL) == sourceBytes)
        }
    }

    @Test @MainActor func committedTransitionCannotInventMetadataOutsideItsExactMutations() throws {
        let f = try Fixture(); defer { f.remove() }
        let store = f.store()
        try store.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: f.handoff, attachmentSources: [:])
        let prior = try #require(try f.checkpoints.load())
        var records = prior.records
        records[0].entityRevision += 1
        let candidate = try SyncCanonicalCheckpoint(accountIDHash: prior.accountIDHash, commitID: UUID(),
            archiveSHA256: prior.archiveSHA256, records: records, legacyRecordIDsToDelete: [])
        let transaction = try SyncPublicationTransaction(expectedArchiveSHA256: candidate.archiveSHA256, mutations: [], revisionReceipts: [],
            canonicalTransition: .init(predecessorSHA256: Data(SHA256.hash(data: prior.encoded())), candidate: candidate))
        let file = SyncPublicationTransactionFile(archiveURL: f.archiveURL)
        try file.write(transaction)
        let reopened = f.store()
        #expect(throws: (any Error).self) {
            try reopened.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: nil, attachmentSources: [:])
        }
        #expect(try file.load() == transaction)
        #expect(try f.checkpoints.load() == prior)
    }

    @Test @MainActor func legacyTransactionCannotBeConsumedByCanonicalRecovery() throws {
        let f = try Fixture(); defer { f.remove() }
        let store = f.store()
        try store.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: f.handoff, attachmentSources: [:])
        let bytes = try Data(contentsOf: f.archiveURL)
        let transaction = try SyncPublicationTransaction.legacy(expectedArchiveSHA256: Data(SHA256.hash(data: bytes)),
            mutations: [.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID())])
        let file = SyncPublicationTransactionFile(archiveURL: f.archiveURL)
        try file.write(transaction)
        let reopened = f.store()
        #expect(throws: (any Error).self) {
            try reopened.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: nil, attachmentSources: [:])
        }
        #expect(try file.load() == transaction)
    }

    @Test @MainActor func acknowledgedDeletionKeepsTombstonesAndRestoresThroughCanonicalPublication() throws {
        let f = try Fixture(media: true); defer { f.remove() }
        let store = f.store()
        try store.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: f.handoff, attachmentSources: [:])
        let photo = try #require(store.projects.first?.photoFilename)
        let photoBytes = try Data(contentsOf: f.live.appendingPathComponent("ProjectPhotos/" + photo))
        try store.delete(id: f.projectID)
        #expect(store.syncPublicationError == nil)
        let deleted = try #require(try f.checkpoints.load())
        #expect(deleted.records.count == 8)
        #expect(deleted.records.allSatisfy { $0.deletedAt.value != nil })
        let ledger = try SyncDeletionLedger(root: SyncDeletionLedger.root(archiveURL: f.archiveURL))
        let entry = try #require(try ledger.recentlyDeleted().first)
        try f.journal.acknowledge(Set(try f.journal.pending().map(\.identity)))
        let reopened = f.store()
        try reopened.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: nil, attachmentSources: [:])
        #expect(try f.checkpoints.load() == deleted)
        try reopened.restoreRecentlyDeleted(id: entry.id, now: entry.deletedAt.addingTimeInterval(29 * 24 * 60 * 60))
        #expect(reopened.syncPublicationError == nil)
        #expect(reopened.projects.first?.id == f.projectID)
        #expect(try f.checkpoints.load()?.commitID != deleted.commitID)
        let expected = try #require(try f.checkpoints.load())
        let second = f.store(journal: f.freshJournal())
        try second.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: nil, attachmentSources: [:])
        #expect(try f.checkpoints.load() == expected)
        #expect(expected.records.filter { $0.id.kind != .attachment }.allSatisfy { $0.deletedAt.value == nil })
        let restoredLineage = try SyncAttachmentLineage(records: expected.records)
        #expect(restoredLineage.resolvedLiveVersionIDs().count == 1)
        #expect(expected.records.contains { $0.id.kind == .attachment && $0.deletedAt.value != nil })
        let restoredPhoto = try #require(second.projects.first?.photoFilename)
        #expect(try Data(contentsOf: f.live.appendingPathComponent("ProjectPhotos/" + restoredPhoto)) == photoBytes)
    }

    @Test @MainActor func staleHandoffCannotEraseAcknowledgedMetadataWhenDailyFileIsLost() throws {
        let f = try Fixture(); defer { f.remove() }
        let store = f.store()
        try store.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: f.handoff, attachmentSources: [:])
        let data = try Data(contentsOf: f.archiveURL)
        let command = WatchCounterCommand(projectID: f.projectID, counterID: UUID(), operation: .increment, createdAt: .now)
        _ = try store.applyWatchCommandDurably(command, ledgerURL: WatchSyncPaths.processedLedger(in: f.live),
            preparedCommandURL: WatchSyncPaths.preparedCommand(in: f.live), now: .now)
        #expect(store.syncPublicationError == nil)
        // Cross the real journal's 256-frame compaction boundary, then ACK all
        // pending work. These transport deletes do not carry canonical records.
        let journalCheckpoint = f.live.appendingPathComponent("SyncMetadata/pending.json.checkpoint")
        let priorJournalCheckpoint = try? Data(contentsOf: journalCheckpoint)
        try f.journal.enqueue((0..<256).map { _ in .delete(.init(kind: .project, uuid: UUID()), mutationID: UUID()) })
        try f.journal.acknowledge(Set(try f.journal.pending().map(\.identity)))
        #expect(try Data(contentsOf: journalCheckpoint) != priorJournalCheckpoint)
        #expect(try f.journal.pending().isEmpty)
        #expect(try Data(contentsOf: f.archiveURL) == data)
        try FileManager.default.removeItem(at: f.live.appendingPathComponent("SyncMetadata/canonical.json"))
        let reopened = f.store()
        #expect(throws: (any Error).self) {
            try reopened.activateSyncCanonicalState(checkpointStore: f.checkpoints, bootstrap: f.handoff, attachmentSources: [:])
        }
        #expect(try f.checkpoints.load() == nil)
    }

    private struct Fixture {
        let root: URL
        let live: URL
        let archiveURL: URL
        let projectID: UUID
        let handoff: SyncCanonicalBootstrapHandoff
        let checkpoints: SyncCanonicalCheckpointStore
        let journal: FileSyncMutationJournal
        let account: SyncAccountIdentity

        init(media: Bool = false, conflict: Bool = false, pattern: Bool = false, usage: Bool = false, remoteRevisions: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
            live = root.appendingPathComponent("Live")
            try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
            archiveURL = live.appendingPathComponent("projects-v1.json")
            var project = try StoredProject(name: "Before")
            if media {
                let service = ProjectPhotoFileService(directory: live.appendingPathComponent("ProjectPhotos"))
                project.setPhotoFilename(try service.save(data: BackupFixture.jpegData(red: 0.2), projectID: project.id))
            }
            if pattern {
                let id = UUID()
                let filename = id.uuidString + ".pdf"
                project.addPattern(.init(id: id, displayName: "Pattern", kind: .pdf, storedFilename: filename))
                let location = live.appendingPathComponent("Patterns/" + project.id.uuidString + "/" + filename)
                try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
                try makeTestPatternPDF(at: location)
            }
            var archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [project])
            if usage {
                let id = UUID(), patternID = UUID()
                let filename = id.uuidString + ".pdf"
                let url = live.appendingPathComponent("Patterns/Assets/" + filename)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try makeTestPatternPDF(at: url)
                let bytes = try Data(contentsOf: url)
                archive.patternAssets = [.init(id: id, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                    kind: .pdf, storedFilename: filename, byteCount: Int64(bytes.count), pageCount: 1)]
                archive.patterns = [.init(id: patternID, assetID: id, displayName: "Usage Pattern")]
                archive.patternUsages = [.init(id: UUID(), patternID: patternID, projectID: project.id, sortOrder: 0)]
            }
            projectID = archive.projects[0].id
            try JSONEncoder().encode(archive).write(to: archiveURL)
            let local = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: live, deviceID: "test-device")
            let remote = conflict ? try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: live, deviceID: "zz-remote") : nil
            let remoteRecords = remoteRevisions ? local.records.map { original -> SyncRecord in
                var record = original
                let stamp = SyncMutationStamp(logicalRevision: 99, modifiedAt: .init(timeIntervalSinceReferenceDate: 999), deviceID: "cloud")
                record.entityRevision = 99
                record.payload.fields = record.payload.fields.mapValues { .init(value: $0.value, stamp: stamp) }
                record.payload.atomicDomain = record.payload.atomicDomain.map { .init(value: $0.value, stamp: stamp) }
                record.deletedAt = .init(value: nil, stamp: stamp)
                return record
            } : remote?.records ?? []
            account = try SyncAccountIdentity(containerIdentifier: "test.container", userRecordName: "canonical-test")
            let context = SyncBootstrapContext(accountIDHash: account.accountIDHash, epoch: UUID(), freezeID: UUID())
            let transaction = try SyncBootstrapTransaction(liveRoot: live, context: context, validateContext: { candidate in
                guard candidate == context else { throw SyncBootstrapError.contextChanged }
            })
            let prepared = try transaction.prepare(local: local, sourceArchive: archive,
                remote: .init(context: context, records: remoteRecords, attachments: remote?.attachments ?? [:], isComplete: true))
            try transaction.install(prepared)
            _ = try transaction.commit(prepared)
            handoff = try transaction.canonicalHandoff(prepared)
            checkpoints = try SyncCanonicalCheckpointStore(liveRoot: live, account: account, validateOwnership: {})
            journal = FileSyncMutationJournal(url: live.appendingPathComponent("SyncMetadata/pending.json"))
        }
        func freshJournal() -> FileSyncMutationJournal {
            FileSyncMutationJournal(url: live.appendingPathComponent("SyncMetadata/pending.json"))
        }
        @MainActor func store(journal supplied: FileSyncMutationJournal? = nil,
            boundary: @escaping (SyncCanonicalPublicationBoundary) throws -> Void = { _ in }) -> JSONProjectStore {
            JSONProjectStore(url: archiveURL,
                backupService: KnitNoteBackupService(liveRoot: live, workRoot: root.appendingPathComponent("BackupWork")),
                syncCanonicalPublicationBoundary: boundary,
                syncMutationSink: JournalSyncMutationSink(journal: supplied ?? journal))
        }
        @MainActor func rename(_ store: JSONProjectStore, _ name: String) throws {
            try store.updateProject(id: projectID, name: name, toolType: nil, toolSize: nil, toolNotes: nil, photoChange: .unchanged)
        }
        func installRemoteReceipt() throws -> SyncRemoteBatchReceipt {
            let predecessor = try #require(try checkpoints.load())
            let receipt = SyncRemoteBatchReceipt(
                identity: .init(
                    accountIDHash: predecessor.accountIDHash,
                    batchID: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
                    contentSHA256: Data(repeating: 3, count: 32)
                ),
                commitID: predecessor.commitID,
                domainChanged: true
            )
            let candidate = try predecessor.insertingRemoteReceipt(receipt)
            try checkpoints.install(
                candidate,
                replacing: Data(SHA256.hash(data: predecessor.encoded()))
            )
            return receipt
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func checkpointStore(_ boundary: @escaping (SyncDurableFileWriteBoundary) throws -> Void) throws -> SyncCanonicalCheckpointStore {
            try .init(liveRoot: live, account: account, validateOwnership: {}, beforeBoundary: boundary)
        }
    }
}
