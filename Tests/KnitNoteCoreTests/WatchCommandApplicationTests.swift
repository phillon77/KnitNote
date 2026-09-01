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
            entitlement: .legacyPaidOwner,
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

    @Test @MainActor func snapshotMapsProjectReminderStateWatchNeeds() throws {
        let fixture = try WatchStoreFixture()
        let project = try #require(fixture.store.projects.first)
        let counterID = project.counters[0].id
        let reminderID = try fixture.store.addKnittingReminder(
            projectID: project.id,
            draft: .oneTime(kind: .changeYarn, target: 2, text: "Change yarn"),
            now: fixture.now
        )
        try fixture.store.incrementCounter(projectID: project.id, counterID: counterID)
        try fixture.store.incrementCounter(projectID: project.id, counterID: counterID)

        let snapshot = try WatchSnapshotBuilder.make(
            projects: fixture.store.projects,
            entitlement: .permanentlyUnlocked,
            locale: Locale(identifier: "en"),
            generatedAt: fixture.now
        )
        let reminder = try #require(snapshot.projects[0].knittingReminders.first)

        #expect(reminder.id == reminderID)
        #expect(reminder.counterID == counterID)
        #expect(reminder.pending.map(\.originalTarget) == [2])
        #expect(reminder.pending.map(\.text) == ["Change yarn"])
        #expect(reminder.mutationRevision > 0)
        #expect(snapshot.projects[0].counters[0].reminder?.id == reminderID)
        #expect(snapshot.projects[0].counters[0].reminder?.legacyOccurrenceID == reminder.pending.first?.id)
        #expect(snapshot.projects[0].counters[0].reminder?.legacyObservedMutationRevision == reminder.mutationRevision)
    }

    @Test @MainActor func legacyCardProjectionHidesDeferredAndResetOccurrences() throws {
        let fixture = try WatchStoreFixture()
        let project = try #require(fixture.store.projects.first)
        let counterID = project.counters[0].id
        let reminderID = try fixture.store.addKnittingReminder(
            projectID: project.id,
            draft: .oneTime(kind: .custom, target: 1, text: nil),
            now: fixture.now
        )
        try fixture.store.incrementCounter(projectID: project.id, counterID: counterID)
        let pending = try #require(fixture.store.project(id: project.id)?.knittingReminders.first?.progress.pending.first)
        let revision = try #require(fixture.store.project(id: project.id)?.knittingReminders.first?.mutationRevision)
        try fixture.store.applyKnittingReminderAction(
            projectID: project.id, reminderID: reminderID, occurrenceID: pending.id,
            observedRevision: revision, action: .deferOnce, now: fixture.now
        )

        let deferred = try WatchSnapshotBuilder.make(
            projects: fixture.store.projects, entitlement: .permanentlyUnlocked,
            locale: Locale(identifier: "en"), generatedAt: fixture.now
        )
        #expect(deferred.projects[0].counters[0].reminder == nil)

        try fixture.store.resetCounter(projectID: project.id, counterID: counterID)
        let reset = try WatchSnapshotBuilder.make(
            projects: fixture.store.projects, entitlement: .permanentlyUnlocked,
            locale: Locale(identifier: "en"), generatedAt: fixture.now
        )
        #expect(reset.projects[0].counters[0].reminder == nil)
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

    @Test @MainActor func duplicateReminderAcknowledgementCannotCompleteTwice() throws {
        let fixture = try WatchStoreFixture()
        let project = try #require(fixture.store.projects.first)
        let counterID = project.counters[0].id
        try fixture.store.configureCounterReminder(projectID: project.id, counterID: counterID, draft: .oneTime(target: 1, message: nil))
        try fixture.store.incrementCounter(projectID: project.id, counterID: counterID)
        let reminder = try #require(fixture.store.project(id: project.id)?.knittingReminders.first)
        let occurrence = try #require(reminder.progress.pending.first)
        var ledger = ProcessedWatchCommandLedger()
        let command = try #require(WatchCounterCommand.legacyWatchUICommand(
            id: UUID(),
            projectID: project.id,
            counterID: counterID,
            operation: .completeReminder,
            reminderID: reminder.id,
            observedPendingCount: 1,
            occurrenceID: occurrence.id,
            observedMutationRevision: reminder.mutationRevision
        ))

        _ = try fixture.store.applyWatchCommand(command, ledger: &ledger, now: fixture.now)
        let afterFirst = fixture.store.project(id: project.id)?.knittingReminders.first?.progress.completedCount
        _ = try fixture.store.applyWatchCommand(command, ledger: &ledger, now: fixture.now)

        #expect(afterFirst == 1)
        #expect(fixture.store.project(id: project.id)?.knittingReminders.first?.progress.completedCount == afterFirst)
        #expect(ledger.entries.count == 1)
    }

    @Test @MainActor func staleReminderIDIsRejectedWithoutMutation() throws {
        let fixture = try WatchStoreFixture()
        let project = try #require(fixture.store.projects.first)
        let counterID = project.counters[0].id
        try fixture.store.configureCounterReminder(projectID: project.id, counterID: counterID, draft: .oneTime(target: 1, message: nil))
        try fixture.store.incrementCounter(projectID: project.id, counterID: counterID)
        var ledger = ProcessedWatchCommandLedger()
        let command = try #require(WatchCounterCommand.legacyWatchUICommand(
            projectID: project.id,
            counterID: counterID,
            operation: .completeReminder,
            reminderID: UUID(),
            observedPendingCount: 1,
            occurrenceID: UUID(),
            observedMutationRevision: 0
        ))

        let acknowledgement = try fixture.store.applyWatchCommand(
            command,
            ledger: &ledger,
            now: fixture.now
        )

        #expect(acknowledgement.rejection == .reminderMismatch)
        #expect(fixture.store.project(id: project.id)?.knittingReminders.first?.progress.pending.count == 1)
    }

    @Test @MainActor func legacyCardTokenRejectsSameCountRuleReplacement() throws {
        let fixture = try WatchStoreFixture()
        let project = try #require(fixture.store.projects.first)
        let counterID = project.counters[0].id
        try fixture.store.configureCounterReminder(
            projectID: project.id, counterID: counterID,
            draft: .oneTime(target: 1, message: nil)
        )
        try fixture.store.incrementCounter(projectID: project.id, counterID: counterID)
        let before = try #require(fixture.store.project(id: project.id)?.knittingReminders.first)
        let occurrence = try #require(before.progress.pending.first)
        let command = try #require(WatchCounterCommand.legacyWatchUICommand(
            projectID: project.id, counterID: counterID,
            operation: .completeReminder, reminderID: before.id,
            observedPendingCount: 1, occurrenceID: occurrence.id,
            observedMutationRevision: before.mutationRevision
        ))
        try fixture.store.updateKnittingReminder(
            projectID: project.id, reminderID: before.id,
            observedRevision: before.mutationRevision,
            draft: .oneTime(kind: .custom, target: 1, text: "replacement"),
            now: fixture.now
        )
        var ledger = ProcessedWatchCommandLedger()

        let acknowledgement = try fixture.store.applyWatchCommand(
            command, ledger: &ledger, now: fixture.now
        )

        #expect(acknowledgement.rejection == .reminderMismatch)
        #expect(fixture.store.project(id: project.id)?.knittingReminders.first?.progress.completedCount == 0)
    }

    @Test @MainActor func stopWinsOverStaleReminderCompletion() throws {
        let fixture = try WatchStoreFixture()
        let project = try #require(fixture.store.projects.first)
        let counterID = project.counters[0].id
        try fixture.store.configureCounterReminder(projectID: project.id, counterID: counterID, draft: .repeating(interval: 1, limit: nil, message: nil))
        try fixture.store.incrementCounter(projectID: project.id, counterID: counterID)
        let reminder = try #require(fixture.store.project(id: project.id)?.knittingReminders.first)
        let occurrence = try #require(reminder.progress.pending.first)
        var ledger = ProcessedWatchCommandLedger()

        let stop = try #require(WatchCounterCommand.legacyWatchUICommand(
            projectID: project.id,
            counterID: counterID,
            operation: .stopReminder,
            reminderID: reminder.id,
            occurrenceID: occurrence.id,
            observedMutationRevision: reminder.mutationRevision
        ))
        _ = try fixture.store.applyWatchCommand(stop, ledger: &ledger, now: fixture.now)
        let completion = try #require(WatchCounterCommand.legacyWatchUICommand(
            projectID: project.id,
            counterID: counterID,
            operation: .completeReminder,
            reminderID: reminder.id,
            observedPendingCount: 1,
            occurrenceID: occurrence.id,
            observedMutationRevision: reminder.mutationRevision
        ))
        let staleCompletion = try fixture.store.applyWatchCommand(completion, ledger: &ledger, now: fixture.now)

        #expect(staleCompletion.rejection == .reminderMismatch)
        #expect(fixture.store.project(id: project.id)?.knittingReminders.first?.state == .stopped)
        #expect(fixture.store.project(id: project.id)?.knittingReminders.first?.progress.completedCount == 0)
    }

    @Test @MainActor func exhaustedLegacyCompletionRejectsOnFirstAndDuplicateDelivery() throws {
        let fixture = try WatchStoreFixture(legacyReminder: .oneTime(target: 1, message: nil))
        let project = try #require(fixture.store.projects.first)
        let counterID = project.counters[0].id
        try fixture.store.incrementCounter(projectID: project.id, counterID: counterID)
        let reminder = try #require(fixture.store.project(id: project.id)?.knittingReminders.first)
        let occurrence = try #require(reminder.progress.pending.first)
        try fixture.setReminderRevision(.max, reminderID: reminder.id)
        let archiveBefore = try Data(contentsOf: fixture.archiveURL)
        let command = try #require(WatchCounterCommand.legacyWatchUICommand(
            projectID: project.id, counterID: counterID,
            operation: .completeReminder, reminderID: reminder.id,
            observedPendingCount: 1, occurrenceID: occurrence.id,
            observedMutationRevision: .max
        ))
        var ledger = ProcessedWatchCommandLedger()

        let first = try fixture.store.applyWatchCommand(
            command, ledger: &ledger, now: fixture.now
        )
        let duplicate = try fixture.store.applyWatchCommand(
            command, ledger: &ledger, now: fixture.now.addingTimeInterval(1)
        )

        #expect(first.rejection == .reminderMismatch)
        #expect(duplicate.rejection == .reminderMismatch)
        #expect(fixture.store.project(id: project.id)?.knittingReminders.first?.mutationRevision == .max)
        #expect(fixture.store.project(id: project.id)?.knittingReminders.first?.progress.completedCount == 0)
        #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)
        #expect(ledger.entries.count == 1)
    }

    @Test @MainActor func exhaustedLegacyStopRejectsOnFirstAndDuplicateDelivery() throws {
        let fixture = try WatchStoreFixture(legacyReminder: .oneTime(target: 1, message: nil))
        let project = try #require(fixture.store.projects.first)
        let counterID = project.counters[0].id
        try fixture.store.incrementCounter(projectID: project.id, counterID: counterID)
        let reminder = try #require(fixture.store.project(id: project.id)?.knittingReminders.first)
        let occurrence = try #require(reminder.progress.pending.first)
        try fixture.setReminderRevision(.max, reminderID: reminder.id)
        let archiveBefore = try Data(contentsOf: fixture.archiveURL)
        let command = try #require(WatchCounterCommand.legacyWatchUICommand(
            projectID: project.id, counterID: counterID,
            operation: .stopReminder, reminderID: reminder.id,
            occurrenceID: occurrence.id, observedMutationRevision: .max
        ))
        var ledger = ProcessedWatchCommandLedger()

        let first = try fixture.store.applyWatchCommand(
            command, ledger: &ledger, now: fixture.now
        )
        let duplicate = try fixture.store.applyWatchCommand(
            command, ledger: &ledger, now: fixture.now.addingTimeInterval(1)
        )

        #expect(first.rejection == .reminderMismatch)
        #expect(duplicate.rejection == .reminderMismatch)
        #expect(fixture.store.project(id: project.id)?.knittingReminders.first?.mutationRevision == .max)
        #expect(fixture.store.project(id: project.id)?.knittingReminders.first?.state == .active)
        #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)
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

    @Test @MainActor
    func expiredIPhoneEntitlementAcknowledgesWithoutMutationAndCannotReplayAfterUnlock() throws {
        let fixture = try WatchStoreFixture()
        let project = try #require(fixture.store.projects.first)
        let command = WatchCounterCommand(
            projectID: project.id,
            counterID: project.counters[0].id,
            operation: .increment
        )
        var ledger = ProcessedWatchCommandLedger()
        let expired = EntitlementSnapshot.trial(
            startedAt: fixture.now.addingTimeInterval(-100),
            expiresAt: fixture.now
        )

        let rejection = try fixture.store.applyWatchCommand(
            command,
            entitlement: expired,
            ledger: &ledger,
            now: fixture.now
        )

        #expect(rejection.rejection == .entitlementRequired)
        #expect(fixture.store.project(id: project.id)?.counters[0].value == 0)
        #expect(ledger.contains(command.id))

        let replay = try fixture.store.applyWatchCommand(
            command,
            entitlement: .permanentlyUnlocked,
            ledger: &ledger,
            now: fixture.now.addingTimeInterval(1)
        )

        #expect(replay.commandID == command.id)
        #expect(fixture.store.project(id: project.id)?.counters[0].value == 0)
        #expect(ledger.entries.count == 1)
    }

    @Test @MainActor func unreadableArchiveKeepsNewCommandRetryable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchCommandUnreadable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archiveURL = root.appendingPathComponent("projects.json")
        try Data("not JSON".utf8).write(to: archiveURL, options: .atomic)
        let store = JSONProjectStore(url: archiveURL)
        let command = WatchCounterCommand(
            projectID: UUID(),
            counterID: UUID(),
            operation: .increment
        )
        var ledger = ProcessedWatchCommandLedger()

        #expect(store.loadError == .unreadableArchive)
        #expect(throws: ProjectStoreError.archiveUnavailable) {
            try store.applyWatchCommand(command, ledger: &ledger, now: date(1_000))
        }
        #expect(store.projects.isEmpty)
        #expect(ledger.entries.isEmpty)
    }

    @Test @MainActor func unreadableArchiveIsCheckedBeforeDuplicateLookup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchCommandUnreadable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archiveURL = root.appendingPathComponent("projects.json")
        try Data("not JSON".utf8).write(to: archiveURL, options: .atomic)
        let store = JSONProjectStore(url: archiveURL)
        let command = WatchCounterCommand(
            projectID: UUID(),
            counterID: UUID(),
            operation: .increment
        )
        var ledger = ProcessedWatchCommandLedger()
        ledger.record(command.id, at: date(900))
        let unchangedLedger = ledger

        #expect(throws: ProjectStoreError.archiveUnavailable) {
            try store.applyWatchCommand(command, ledger: &ledger, now: date(1_000))
        }
        #expect(store.projects.isEmpty)
        #expect(ledger == unchangedLedger)
    }
}

private func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}

@MainActor private final class WatchStoreFixture {
    let now = date(1_000)
    let store: JSONProjectStore
    private let root: URL
    fileprivate let archiveURL: URL

    init(completed: Bool = false, legacyReminder: CounterReminderDraft? = nil) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        archiveURL = root.appendingPathComponent("projects.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var project = try StoredProject(name: "Watch project", now: now)
        if let legacyReminder {
            _ = project.configureCounterReminder(id: project.counters[0].id, draft: legacyReminder, now: now)
        }
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

    func setReminderRevision(_ revision: UInt64, reminderID: UUID) throws {
        var archive = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: archiveURL)) as? [String: Any]
        )
        var projects = try #require(archive["projects"] as? [[String: Any]])
        var project = try #require(projects.first)
        var reminders = try #require(project["knittingReminders"] as? [[String: Any]])
        let index = try #require(reminders.firstIndex {
            $0["id"] as? String == reminderID.uuidString
        })
        reminders[index]["mutationRevision"] = NSNumber(value: revision)
        project["knittingReminders"] = reminders
        projects[0] = project
        archive["projects"] = projects
        try JSONSerialization.data(withJSONObject: archive).write(to: archiveURL, options: .atomic)
        try store.reloadFromDisk()
    }
}
