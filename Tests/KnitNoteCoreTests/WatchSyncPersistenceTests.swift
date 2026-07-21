import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct WatchSyncPersistenceTests {
    @Test func pendingQueueSurvivesRestart() throws {
        let root = try WatchSyncTemporaryDirectory()
        let file = AtomicWatchSyncFile<WatchSyncCache>(url: WatchSyncPaths.watchCache(in: root.url))
        let command = WatchCounterCommand(
            projectID: UUID(),
            counterID: UUID(),
            operation: .increment,
            createdAt: Date(timeIntervalSince1970: 100)
        )

        try file.save(WatchSyncCache(snapshot: nil, pendingCommands: [command]))

        #expect(try AtomicWatchSyncFile<WatchSyncCache>(url: file.url).load()?.pendingCommands == [command])
    }

    @Test func failedAtomicSavePreservesPreviousFile() throws {
        let root = try WatchSyncTemporaryDirectory()
        let url = WatchSyncPaths.watchCache(in: root.url)
        let original = WatchSyncCache(snapshot: nil, pendingCommands: [])
        try AtomicWatchSyncFile<WatchSyncCache>(url: url).save(original)
        let failing = AtomicWatchSyncFile<WatchSyncCache>(url: url) { _, _ in
            throw InjectedWatchSyncFailure()
        }

        #expect(throws: InjectedWatchSyncFailure.self) {
            try failing.save(WatchSyncCache(
                snapshot: nil,
                pendingCommands: [.init(projectID: UUID(), counterID: UUID(), operation: .reset)]
            ))
        }
        #expect(try AtomicWatchSyncFile<WatchSyncCache>(url: url).load() == original)
    }

    @Test func corruptWatchCacheIsQuarantinedAndRequestsSnapshot() throws {
        let root = try WatchSyncTemporaryDirectory()
        let url = WatchSyncPaths.watchCache(in: root.url)
        try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
        try Data("not JSON".utf8).write(to: url)

        let recovery = try WatchSyncCache.loadRecoveringCorruption(in: root.url)

        #expect(recovery.cache == .empty)
        #expect(recovery.requiresSnapshot)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.url.path)
        #expect(names.contains { $0.hasPrefix("watch-sync-cache.corrupt-") && $0.hasSuffix(".json") })
    }

    @Test func selectedIDsAreValidatedAgainstSnapshotOnLoad() throws {
        let root = try WatchSyncTemporaryDirectory()
        let snapshot = try makeSnapshot()
        let file = AtomicWatchSyncFile<WatchSyncCache>(url: WatchSyncPaths.watchCache(in: root.url))
        try file.save(WatchSyncCache(
            snapshot: snapshot,
            pendingCommands: [],
            selectedProjectID: UUID(),
            selectedCounterID: UUID()
        ))

        let loadedValue = try file.load()
        let loaded = try #require(loadedValue)

        #expect(loaded.selectedProjectID == snapshot.projects[0].id)
        #expect(loaded.selectedCounterID == snapshot.projects[0].selectedCounterID)
    }

    @Test @MainActor func corruptLedgerRequiresHandshakeAndRejectsCommands() throws {
        let fixture = try DurableWatchFixture()
        try Data("not JSON".utf8).write(to: fixture.ledgerURL, options: .atomic)
        let archiveBefore = try Data(contentsOf: fixture.archiveURL)
        let restarted = JSONProjectStore(url: fixture.archiveURL)

        let state = try restarted.recoverWatchCommandPersistence(
            ledgerURL: fixture.ledgerURL,
            preparedCommandURL: fixture.preparedURL,
            now: fixture.now
        )

        #expect(state == .requiresFreshHandshake)
        #expect(throws: WatchCommandPersistenceError.requiresFreshHandshake) {
            try restarted.applyWatchCommandDurably(
                fixture.command,
                ledgerURL: fixture.ledgerURL,
                preparedCommandURL: fixture.preparedURL,
                now: fixture.now
            )
        }
        #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)
        let loadedLedger = try AtomicWatchSyncFile<ProcessedWatchCommandLedger>(
            url: fixture.ledgerURL
        ).load()
        let ledger = try #require(loadedLedger)
        #expect(ledger.requiresFreshHandshake)
    }

    @Test @MainActor func handshakeSeedsLedgerBeforeAcceptingCommands() throws {
        let fixture = try DurableWatchFixture()
        try Data("not JSON".utf8).write(to: fixture.ledgerURL, options: .atomic)
        let store = JSONProjectStore(url: fixture.archiveURL)
        _ = try store.recoverWatchCommandPersistence(
            ledgerURL: fixture.ledgerURL,
            preparedCommandURL: fixture.preparedURL,
            now: fixture.now
        )

        try store.completeWatchQueueHandshake(
            queuedCommandIDs: [fixture.command.id],
            ledgerURL: fixture.ledgerURL,
            now: fixture.now
        )
        _ = try store.applyWatchCommandDurably(
            fixture.command,
            ledgerURL: fixture.ledgerURL,
            preparedCommandURL: fixture.preparedURL,
            now: fixture.now
        )

        #expect(store.project(id: fixture.projectID)?.counters[0].value == 0)
        let loadedLedger = try AtomicWatchSyncFile<ProcessedWatchCommandLedger>(
            url: fixture.ledgerURL
        ).load()
        let ledger = try #require(loadedLedger)
        #expect(!ledger.requiresFreshHandshake)
        #expect(ledger.contains(fixture.command.id))
    }

    @Test @MainActor func routineHandshakePreservesProcessedHistory() throws {
        let fixture = try DurableWatchFixture()
        let oldProcessedID = UUID()
        let queuedID = UUID()
        var ledger = ProcessedWatchCommandLedger()
        ledger.record(oldProcessedID, at: fixture.now.addingTimeInterval(-100 * 86_400))
        try AtomicWatchSyncFile<ProcessedWatchCommandLedger>(url: fixture.ledgerURL).save(ledger)
        let store = JSONProjectStore(url: fixture.archiveURL)

        try store.completeWatchQueueHandshake(
            queuedCommandIDs: [queuedID],
            ledgerURL: fixture.ledgerURL,
            now: fixture.now
        )

        let loaded = try AtomicWatchSyncFile<ProcessedWatchCommandLedger>(
            url: fixture.ledgerURL
        ).load()
        let persisted = try #require(loaded)
        #expect(persisted.contains(oldProcessedID))
        #expect(persisted.contains(queuedID))
        #expect(!persisted.requiresFreshHandshake)
    }

    @Test @MainActor func directHandshakeQuarantinesCorruptLedgerAndSeedsQueue() throws {
        let fixture = try DurableWatchFixture()
        let queuedID = UUID()
        try Data("not JSON".utf8).write(to: fixture.ledgerURL, options: .atomic)
        let store = JSONProjectStore(url: fixture.archiveURL)

        try store.completeWatchQueueHandshake(
            queuedCommandIDs: [queuedID],
            ledgerURL: fixture.ledgerURL,
            now: fixture.now
        )

        let loaded = try AtomicWatchSyncFile<ProcessedWatchCommandLedger>(
            url: fixture.ledgerURL
        ).load()
        let persisted = try #require(loaded)
        #expect(persisted.contains(queuedID))
        #expect(!persisted.requiresFreshHandshake)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.url.path)
        #expect(names.contains {
            $0.hasPrefix("processed-watch-commands.corrupt-") && $0.hasSuffix(".json")
        })
    }

    @Test func preparedReceiptRecordsExpectedCounterValue() {
        let command = WatchCounterCommand(
            projectID: UUID(),
            counterID: UUID(),
            operation: .reset
        )

        let prepared = PreparedWatchCommand(
            command: command,
            expectedCounterRevision: 7,
            expectedCounterValue: 0
        )

        #expect(prepared.expectedCounterValue == 0)
    }

    @Test(arguments: WatchCommandPersistenceBoundary.allCases)
    @MainActor func restartAfterEveryCrashBoundaryProducesOneMutation(
        boundary: WatchCommandPersistenceBoundary
    ) throws {
        let fixture = try DurableWatchFixture()
        let store = JSONProjectStore(url: fixture.archiveURL)

        #expect(throws: InjectedWatchSyncFailure.self) {
            try store.applyWatchCommandDurably(
                fixture.command,
                ledgerURL: fixture.ledgerURL,
                preparedCommandURL: fixture.preparedURL,
                now: fixture.now,
                failureInjector: { reached in
                    if reached == boundary { throw InjectedWatchSyncFailure() }
                }
            )
        }

        let restarted = JSONProjectStore(url: fixture.archiveURL)
        let state = try restarted.recoverWatchCommandPersistence(
            ledgerURL: fixture.ledgerURL,
            preparedCommandURL: fixture.preparedURL,
            now: fixture.now.addingTimeInterval(1)
        )
        _ = try restarted.applyWatchCommandDurably(
            fixture.command,
            ledgerURL: fixture.ledgerURL,
            preparedCommandURL: fixture.preparedURL,
            now: fixture.now.addingTimeInterval(2)
        )

        #expect(state == .ready)
        #expect(restarted.project(id: fixture.projectID)?.counters[0].value == 1)
        #expect(restarted.project(id: fixture.projectID)?.counters[0].mutationRevision == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.preparedURL.path))
        let loadedLedger = try AtomicWatchSyncFile<ProcessedWatchCommandLedger>(
            url: fixture.ledgerURL
        ).load()
        let ledger = try #require(loadedLedger)
        #expect(ledger.contains(fixture.command.id))
    }

    @Test(
        arguments: NoOpWatchCommandCase.allCases,
        WatchCommandPersistenceBoundary.allCases
    )
    @MainActor func restartAfterNoOpCrashRecordsWithoutChangingCounter(
        noOp: NoOpWatchCommandCase,
        boundary: WatchCommandPersistenceBoundary
    ) throws {
        let fixture = try DurableWatchFixture(operation: noOp.operation, value: noOp.value)
        let store = JSONProjectStore(url: fixture.archiveURL)

        #expect(throws: InjectedWatchSyncFailure.self) {
            try store.applyWatchCommandDurably(
                fixture.command,
                ledgerURL: fixture.ledgerURL,
                preparedCommandURL: fixture.preparedURL,
                now: fixture.now,
                failureInjector: { reached in
                    if reached == boundary { throw InjectedWatchSyncFailure() }
                }
            )
        }

        let restarted = JSONProjectStore(url: fixture.archiveURL)
        #expect(try restarted.recoverWatchCommandPersistence(
            ledgerURL: fixture.ledgerURL,
            preparedCommandURL: fixture.preparedURL,
            now: fixture.now.addingTimeInterval(1)
        ) == .ready)
        _ = try restarted.applyWatchCommandDurably(
            fixture.command,
            ledgerURL: fixture.ledgerURL,
            preparedCommandURL: fixture.preparedURL,
            now: fixture.now.addingTimeInterval(2)
        )

        let counter = try #require(restarted.project(id: fixture.projectID)?.counters[0])
        #expect(counter.value == noOp.value)
        #expect(counter.mutationRevision == 0)
        let loaded = try AtomicWatchSyncFile<ProcessedWatchCommandLedger>(
            url: fixture.ledgerURL
        ).load()
        #expect(try #require(loaded).contains(fixture.command.id))
    }

    @Test @MainActor func unverifiablePreparedRevisionRequiresHandshakeWithoutReplay() throws {
        let fixture = try DurableWatchFixture()
        let prepared = PreparedWatchCommand(command: fixture.command, expectedCounterRevision: 42)
        try AtomicWatchSyncFile<PreparedWatchCommand>(url: fixture.preparedURL).save(prepared)
        let archiveBefore = try Data(contentsOf: fixture.archiveURL)
        let restarted = JSONProjectStore(url: fixture.archiveURL)

        let state = try restarted.recoverWatchCommandPersistence(
            ledgerURL: fixture.ledgerURL,
            preparedCommandURL: fixture.preparedURL,
            now: fixture.now
        )

        #expect(state == .requiresFreshHandshake)
        #expect(restarted.project(id: fixture.projectID)?.counters[0].value == 0)
        #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)
    }

    @Test @MainActor func reconciliationDeduplicatesAnAmbiguousReceiptStillInWatchQueue() throws {
        let fixture = try DurableWatchFixture()
        let prepared = PreparedWatchCommand(command: fixture.command, expectedCounterRevision: 42)
        try AtomicWatchSyncFile<PreparedWatchCommand>(url: fixture.preparedURL).save(prepared)
        let store = JSONProjectStore(url: fixture.archiveURL)
        #expect(try store.recoverWatchCommandPersistence(
            ledgerURL: fixture.ledgerURL,
            preparedCommandURL: fixture.preparedURL,
            now: fixture.now
        ) == .requiresFreshHandshake)

        let state = try store.reconcileWatchQueueHandshakeDurably(
            queuedCommandIDs: [fixture.command.id],
            ledgerURL: fixture.ledgerURL,
            preparedCommandURL: fixture.preparedURL,
            now: fixture.now.addingTimeInterval(1)
        )
        _ = try store.applyWatchCommandDurably(
            fixture.command,
            ledgerURL: fixture.ledgerURL,
            preparedCommandURL: fixture.preparedURL,
            now: fixture.now.addingTimeInterval(2)
        )

        #expect(state == .ready)
        #expect(store.project(id: fixture.projectID)?.counters[0].value == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.preparedURL.path))
        let loaded = try AtomicWatchSyncFile<ProcessedWatchCommandLedger>(
            url: fixture.ledgerURL
        ).load()
        #expect(try #require(loaded).contains(fixture.command.id))
    }

    @Test @MainActor func reconciliationQuarantinesAnAmbiguousReceiptAbsentFromWatchQueue() throws {
        let fixture = try DurableWatchFixture()
        let prepared = PreparedWatchCommand(command: fixture.command, expectedCounterRevision: 42)
        try AtomicWatchSyncFile<PreparedWatchCommand>(url: fixture.preparedURL).save(prepared)
        let store = JSONProjectStore(url: fixture.archiveURL)
        #expect(try store.recoverWatchCommandPersistence(
            ledgerURL: fixture.ledgerURL,
            preparedCommandURL: fixture.preparedURL,
            now: fixture.now
        ) == .requiresFreshHandshake)

        let state = try store.reconcileWatchQueueHandshakeDurably(
            queuedCommandIDs: [],
            ledgerURL: fixture.ledgerURL,
            preparedCommandURL: fixture.preparedURL,
            now: fixture.now.addingTimeInterval(1)
        )

        #expect(state == .ready)
        #expect(store.project(id: fixture.projectID)?.counters[0].value == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.preparedURL.path))
        let loaded = try AtomicWatchSyncFile<ProcessedWatchCommandLedger>(
            url: fixture.ledgerURL
        ).load()
        let ledger = try #require(loaded)
        #expect(!ledger.requiresFreshHandshake)
        #expect(!ledger.contains(fixture.command.id))
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.url.path)
        #expect(names.contains {
            $0.hasPrefix("prepared-watch-command.corrupt-") && $0.hasSuffix(".json")
        })
    }

    @Test @MainActor func healthyHandshakeDoesNotSeedUnprocessedQueueIDs() throws {
        let fixture = try DurableWatchFixture()
        let store = JSONProjectStore(url: fixture.archiveURL)

        let state = try store.reconcileWatchQueueHandshakeDurably(
            queuedCommandIDs: [fixture.command.id],
            ledgerURL: fixture.ledgerURL,
            preparedCommandURL: fixture.preparedURL,
            now: fixture.now
        )
        _ = try store.applyWatchCommandDurably(
            fixture.command,
            ledgerURL: fixture.ledgerURL,
            preparedCommandURL: fixture.preparedURL,
            now: fixture.now.addingTimeInterval(1)
        )

        #expect(state == .ready)
        #expect(store.project(id: fixture.projectID)?.counters[0].value == 1)
    }

    @Test @MainActor func durableResetThenIncrementPreservesCommandOrder() throws {
        let fixture = try DurableWatchFixture(value: 7)
        let store = JSONProjectStore(url: fixture.archiveURL)
        let reset = WatchCounterCommand(
            projectID: fixture.projectID,
            counterID: fixture.counterID,
            operation: .reset
        )
        let increment = WatchCounterCommand(
            projectID: fixture.projectID,
            counterID: fixture.counterID,
            operation: .increment
        )

        _ = try store.applyWatchCommandDurably(
            reset,
            ledgerURL: fixture.ledgerURL,
            preparedCommandURL: fixture.preparedURL,
            now: fixture.now
        )
        _ = try store.applyWatchCommandDurably(
            increment,
            ledgerURL: fixture.ledgerURL,
            preparedCommandURL: fixture.preparedURL,
            now: fixture.now.addingTimeInterval(1)
        )

        #expect(store.project(id: fixture.projectID)?.counters[0].value == 1)
    }
}

private struct InjectedWatchSyncFailure: Error {}

enum NoOpWatchCommandCase: CaseIterable, Sendable {
    case decrementAtZero
    case resetAtZero
    case incrementAtMaximum

    var operation: WatchCounterOperation {
        switch self {
        case .decrementAtZero: .decrement
        case .resetAtZero: .reset
        case .incrementAtMaximum: .increment
        }
    }

    var value: Int {
        switch self {
        case .decrementAtZero, .resetAtZero: 0
        case .incrementAtMaximum: .max
        }
    }
}

private final class WatchSyncTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

@MainActor private final class DurableWatchFixture {
    let directory: WatchSyncTemporaryDirectory
    let archiveURL: URL
    let ledgerURL: URL
    let preparedURL: URL
    let projectID: UUID
    let counterID: UUID
    let command: WatchCounterCommand
    let now = Date(timeIntervalSince1970: 1_000)

    init(operation: WatchCounterOperation = .increment, value: Int = 0) throws {
        directory = try WatchSyncTemporaryDirectory()
        archiveURL = directory.url.appendingPathComponent("projects-v1.json")
        ledgerURL = WatchSyncPaths.processedLedger(in: directory.url)
        preparedURL = WatchSyncPaths.preparedCommand(in: directory.url)
        let project = try StoredProject(
            name: "Watch project",
            counters: [ProjectCounter(defaultOrdinal: 1, value: value)],
            now: now
        )
        projectID = project.id
        counterID = project.counters[0].id
        command = WatchCounterCommand(
            projectID: projectID,
            counterID: counterID,
            operation: operation,
            createdAt: now
        )
        try JSONEncoder().encode(ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: [project]
        )).write(to: archiveURL, options: .atomic)
    }
}

private func makeSnapshot() throws -> WatchSyncSnapshot {
    let projectID = UUID()
    let counters = (0..<6).map { WatchCounterSnapshot(id: UUID(), name: "Counter \($0 + 1)", value: 0) }
    return WatchSyncSnapshot(
        generatedAt: Date(timeIntervalSince1970: 100),
        projects: [try WatchProjectSnapshot(
            id: projectID,
            name: "Project",
            isCompleted: false,
            updatedAt: Date(timeIntervalSince1970: 100),
            counters: counters,
            selectedCounterID: counters[0].id
        )]
    )
}
