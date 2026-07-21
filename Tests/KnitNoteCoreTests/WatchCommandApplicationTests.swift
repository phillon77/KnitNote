import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct WatchCommandApplicationTests {
    @Test func snapshotMapsNamesValuesSelectionAndStableProjectOrder() throws {
        let oldActive = try StoredProject(name: "Old active", now: date(100))
        var completed = try StoredProject(name: "Completed", now: date(400))
        completed.markCompleted(at: date(500))
        var newActive = try StoredProject(name: "New active", now: date(300))
        let selectedID = newActive.counters[2].id
        newActive.selectCounter(id: selectedID, now: date(300))
        newActive.updateCounter(
            id: selectedID,
            name: "  Sleeve repeat  ",
            value: 7,
            now: date(300)
        )
        let sameDateFirst = try StoredProject(name: "Same date first", now: date(200))
        let sameDateSecond = try StoredProject(name: "Same date second", now: date(200))

        let snapshot = try WatchSnapshotBuilder.make(
            projects: [completed, oldActive, newActive, sameDateFirst, sameDateSecond],
            locale: Locale(identifier: "en"),
            generatedAt: date(900)
        )

        #expect(snapshot.generatedAt == date(900))
        #expect(snapshot.projects.map(\.name) == [
            "New active", "Same date first", "Same date second", "Old active", "Completed",
        ])
        let mapped = try #require(snapshot.projects.first)
        #expect(mapped.selectedCounterID == selectedID)
        #expect(mapped.counters.count == 6)
        #expect(mapped.counters[2].name == "Sleeve repeat")
        #expect(mapped.counters[2].value == 7)
        #expect(mapped.counters[0].name == "Counter 1")
    }

    @Test func counterDisplayNameUsesCustomNameOrLocalizedDefaultFormat() {
        let unnamed = ProjectCounter(defaultOrdinal: 4)
        let named = ProjectCounter(defaultOrdinal: 4, customName: "  Cuff  ")

        #expect(unnamed.displayName(locale: Locale(identifier: "en")) == "Counter 4")
        #expect(named.displayName(locale: Locale(identifier: "en")) == "Cuff")
    }

    @Test func mutationRevisionTracksOnlyValueChangesAndSurvivesCodable() throws {
        var project = try StoredProject(name: "Revision", now: date(10))
        let counterID = project.counters[0].id
        #expect(project.counters[0].mutationRevision == 0)

        project.renameCounter(id: counterID, to: "Named", now: date(20))
        #expect(project.counters[0].mutationRevision == 0)
        project.incrementCounter(id: counterID, now: date(30))
        project.decrementCounter(id: counterID, now: date(40))
        project.decrementCounter(id: counterID, now: date(50))
        project.resetCounter(id: counterID, now: date(60))
        #expect(project.counters[0].mutationRevision == 2)

        project.updateCounter(id: counterID, name: "Renamed", value: 9, now: date(70))
        #expect(project.counters[0].mutationRevision == 3)
        project.updateCounter(id: counterID, name: "Name only", value: 9, now: date(80))
        #expect(project.counters[0].mutationRevision == 3)
        project.resetCounter(id: counterID, now: date(90))
        #expect(project.counters[0].mutationRevision == 4)

        let decoded = try JSONDecoder().decode(
            StoredProject.self,
            from: JSONEncoder().encode(project)
        )
        #expect(decoded.counters[0].mutationRevision == 4)

        var counterObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(project.counters[0]))
                as? [String: Any]
        )
        counterObject.removeValue(forKey: "mutationRevision")
        let legacyCounter = try JSONDecoder().decode(
            ProjectCounter.self,
            from: JSONSerialization.data(withJSONObject: counterObject)
        )
        #expect(legacyCounter.mutationRevision == 0)
    }

    @Test func pruningKeepsRecentThousandAndAllNinetyDayEntries() {
        let now = date(10_000_000)
        var ledger = ProcessedWatchCommandLedger()
        for offset in 0..<1_100 {
            ledger.record(UUID(), at: now.addingTimeInterval(Double(-offset)))
        }
        let withinWindow = UUID()
        ledger.record(withinWindow, at: now.addingTimeInterval(-89 * 86_400))

        ledger.prune(now: now)

        #expect(ledger.contains(withinWindow))
        #expect(ledger.entries.count == 1_101)
    }

    @Test func pruningRetainsNewestThousandEvenPastNinetyDays() {
        let now = date(20_000_000)
        var ledger = ProcessedWatchCommandLedger()
        var ids: [UUID] = []
        for offset in 0..<1_100 {
            let id = UUID()
            ids.append(id)
            ledger.record(id, at: now.addingTimeInterval(Double(-100 * 86_400 - offset)))
        }

        ledger.prune(now: now)

        #expect(ledger.entries.count == 1_000)
        #expect(ledger.contains(ids[0]))
        #expect(!ledger.contains(ids[1_099]))
    }

    @Test func recordingDuplicateReplacesItsTimestampAndKeepsOneEntry() {
        let id = UUID()
        var ledger = ProcessedWatchCommandLedger()

        ledger.record(id, at: date(10))
        ledger.record(id, at: date(20))

        #expect(ledger.entries == [.init(id: id, processedAt: date(20))])
    }

    @Test @MainActor func duplicateDeliveryMutatesOnlyOnceAndReturnsFreshState() throws {
        let fixture = try WatchStoreFixture()
        let project = try #require(fixture.store.projects.first)
        let counter = project.counters[0]
        let command = WatchCounterCommand(
            id: UUID(),
            projectID: project.id,
            counterID: counter.id,
            operation: .increment,
            createdAt: fixture.now
        )
        var ledger = ProcessedWatchCommandLedger()

        _ = try fixture.store.applyWatchCommand(command, ledger: &ledger, now: fixture.now)
        try fixture.store.incrementCounter(projectID: project.id, counterID: counter.id)
        let duplicate = try fixture.store.applyWatchCommand(
            command,
            ledger: &ledger,
            now: fixture.now.addingTimeInterval(1)
        )

        #expect(fixture.store.project(id: project.id)?.counters[0].value == 2)
        #expect(fixture.store.project(id: project.id)?.counters[0].mutationRevision == 2)
        #expect(duplicate.rejection == nil)
        #expect(duplicate.snapshot.projects[0].counters[0].value == 2)
        #expect(ledger.entries.count == 1)
    }

    @Test @MainActor func incrementDecrementFloorAndResetUseAuthoritativeCurrentValue() throws {
        let fixture = try WatchStoreFixture()
        let project = try #require(fixture.store.projects.first)
        let counterID = project.counters[0].id
        var ledger = ProcessedWatchCommandLedger()

        try fixture.store.incrementCounter(projectID: project.id, counterID: counterID)
        _ = try fixture.store.applyWatchCommand(
            .init(projectID: project.id, counterID: counterID, operation: .increment),
            ledger: &ledger,
            now: fixture.now
        )
        _ = try fixture.store.applyWatchCommand(
            .init(projectID: project.id, counterID: counterID, operation: .decrement),
            ledger: &ledger,
            now: fixture.now
        )
        _ = try fixture.store.applyWatchCommand(
            .init(projectID: project.id, counterID: counterID, operation: .reset),
            ledger: &ledger,
            now: fixture.now
        )
        let floor = try fixture.store.applyWatchCommand(
            .init(projectID: project.id, counterID: counterID, operation: .decrement),
            ledger: &ledger,
            now: fixture.now
        )

        let storedCounter = try #require(fixture.store.project(id: project.id)?.counters[0])
        #expect(storedCounter.value == 0)
        #expect(storedCounter.mutationRevision == 4)
        #expect(floor.snapshot.projects[0].counters[0].value == 0)
        #expect(ledger.entries.count == 4)
    }

    @Test @MainActor func unsupportedSchemaRejectsAndRecordsWithoutMutation() throws {
        let fixture = try WatchStoreFixture()
        let project = try #require(fixture.store.projects.first)
        var ledger = ProcessedWatchCommandLedger()
        let command = WatchCounterCommand(
            schemaVersion: WatchCounterCommand.currentSchemaVersion + 1,
            projectID: project.id,
            counterID: project.counters[0].id,
            operation: .increment
        )

        let acknowledgement = try fixture.store.applyWatchCommand(
            command,
            ledger: &ledger,
            now: fixture.now
        )

        #expect(acknowledgement.rejection == .unsupportedSchema)
        #expect(fixture.store.project(id: project.id)?.counters[0].value == 0)
        #expect(ledger.contains(command.id))
    }

    @Test @MainActor func missingProjectRejectsAndRecordsWithoutMutation() throws {
        let fixture = try WatchStoreFixture()
        let project = try #require(fixture.store.projects.first)
        var ledger = ProcessedWatchCommandLedger()
        let command = WatchCounterCommand(
            projectID: UUID(),
            counterID: project.counters[0].id,
            operation: .increment
        )

        let acknowledgement = try fixture.store.applyWatchCommand(
            command,
            ledger: &ledger,
            now: fixture.now
        )

        #expect(acknowledgement.rejection == .projectMissing)
        #expect(ledger.contains(command.id))
    }

    @Test @MainActor func missingCounterRejectsAndRecordsWithoutMutation() throws {
        let fixture = try WatchStoreFixture()
        let project = try #require(fixture.store.projects.first)
        var ledger = ProcessedWatchCommandLedger()
        let command = WatchCounterCommand(
            projectID: project.id,
            counterID: UUID(),
            operation: .increment
        )

        let acknowledgement = try fixture.store.applyWatchCommand(
            command,
            ledger: &ledger,
            now: fixture.now
        )

        #expect(acknowledgement.rejection == .counterMissing)
        #expect(fixture.store.project(id: project.id)?.counters.allSatisfy { $0.value == 0 } == true)
        #expect(ledger.contains(command.id))
    }

    @Test @MainActor func completedProjectRejectsWithoutMutation() throws {
        let fixture = try WatchStoreFixture(completed: true)
        let project = try #require(fixture.store.projects.first)
        var ledger = ProcessedWatchCommandLedger()
        let command = WatchCounterCommand(
            projectID: project.id,
            counterID: project.counters[0].id,
            operation: .increment
        )

        let acknowledgement = try fixture.store.applyWatchCommand(
            command,
            ledger: &ledger,
            now: fixture.now
        )

        #expect(acknowledgement.rejection == .projectCompleted)
        #expect(fixture.store.project(id: project.id)?.counters[0].value == 0)
        #expect(ledger.contains(command.id))
    }

    @Test @MainActor func persistenceFailureDoesNotMutateOrRecordCommand() throws {
        let fixture = try WatchStoreFixture()
        let project = try #require(fixture.store.projects.first)
        let command = WatchCounterCommand(
            projectID: project.id,
            counterID: project.counters[0].id,
            operation: .increment
        )
        var ledger = ProcessedWatchCommandLedger()
        try fixture.breakArchiveParent()

        #expect(throws: ProjectStoreError.persistenceFailed) {
            try fixture.store.applyWatchCommand(command, ledger: &ledger, now: fixture.now)
        }
        #expect(fixture.store.project(id: project.id)?.counters[0].value == 0)
        #expect(!ledger.contains(command.id))
    }
}

private func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}

@MainActor private final class WatchStoreFixture {
    let now = date(1_000)
    let store: JSONProjectStore
    private let root: URL
    private let archiveURL: URL

    init(completed: Bool = false) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        archiveURL = root.appendingPathComponent("projects.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var project = try StoredProject(name: "Watch project", now: now)
        if completed {
            project.markCompleted(at: now)
        }
        try JSONEncoder().encode(ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: [project]
        )).write(to: archiveURL, options: .atomic)
        store = JSONProjectStore(url: archiveURL)
    }

    func breakArchiveParent() throws {
        try FileManager.default.removeItem(at: root)
        try Data("not a directory".utf8).write(to: root)
    }
}
