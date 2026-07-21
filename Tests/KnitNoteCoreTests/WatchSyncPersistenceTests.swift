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
}

private struct InjectedWatchSyncFailure: Error {}

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

    init() throws {
        directory = try WatchSyncTemporaryDirectory()
        archiveURL = directory.url.appendingPathComponent("projects-v1.json")
        ledgerURL = WatchSyncPaths.processedLedger(in: directory.url)
        preparedURL = WatchSyncPaths.preparedCommand(in: directory.url)
        let project = try StoredProject(name: "Watch project", now: now)
        projectID = project.id
        counterID = project.counters[0].id
        command = WatchCounterCommand(
            projectID: projectID,
            counterID: counterID,
            operation: .increment,
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
