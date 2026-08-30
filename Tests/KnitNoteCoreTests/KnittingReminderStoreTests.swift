import Foundation
import Testing
@testable import KnitNoteCore

@Suite @MainActor struct KnittingReminderStoreTests {
    @Test func storePersistsReminderAddUpdateActionAndDelete() throws {
        let harness = try KnittingReminderStoreHarness()
        defer { harness.removeFiles() }
        let draft = KnittingReminderDraft.oneTime(kind: .changeYarn, target: 2, text: "Blue")

        let reminderID = try harness.store.addKnittingReminder(
            projectID: harness.projectID,
            draft: draft,
            now: Date(timeIntervalSince1970: 10)
        )
        var reminder = try #require(harness.store.project(id: harness.projectID)?.knittingReminders.first)
        #expect(reminder.id == reminderID)
        #expect(JSONProjectStore(url: harness.archiveURL).project(id: harness.projectID)?.knittingReminders == [reminder])

        try harness.store.updateKnittingReminder(
            projectID: harness.projectID,
            reminderID: reminderID,
            observedRevision: reminder.mutationRevision,
            draft: .oneTime(kind: .measure, target: 3, text: "Gauge"),
            now: Date(timeIntervalSince1970: 20)
        )
        _ = try harness.store.updateCounter(
            projectID: harness.projectID,
            counterID: harness.mainCounterID,
            name: nil,
            value: 3
        )
        reminder = try #require(harness.store.project(id: harness.projectID)?.knittingReminders.first)
        let occurrence = try #require(reminder.progress.pending.first)
        try harness.store.applyKnittingReminderAction(
            projectID: harness.projectID,
            reminderID: reminderID,
            occurrenceID: occurrence.id,
            observedRevision: reminder.mutationRevision,
            action: .complete,
            now: Date(timeIntervalSince1970: 30)
        )
        reminder = try #require(harness.store.project(id: harness.projectID)?.knittingReminders.first)
        try harness.store.deleteKnittingReminder(
            projectID: harness.projectID,
            reminderID: reminderID,
            observedRevision: reminder.mutationRevision
        )

        #expect(harness.store.project(id: harness.projectID)?.knittingReminders.isEmpty == true)
        #expect(JSONProjectStore(url: harness.archiveURL).project(id: harness.projectID)?.knittingReminders.isEmpty == true)
    }

    @Test func staleOccurrenceActionDoesNotPersistOrPublish() throws {
        let harness = try KnittingReminderStoreHarness(triggeredReminder: true)
        defer { harness.removeFiles() }
        let reminder = try #require(harness.store.project(id: harness.projectID)?.knittingReminders.first)
        let occurrence = try #require(reminder.progress.pending.first)
        let projectsBefore = harness.store.projects
        let archiveBefore = try Data(contentsOf: harness.archiveURL)

        #expect(throws: KnittingReminderMutationError.staleRevision) {
            try harness.store.applyKnittingReminderAction(
                projectID: harness.projectID,
                reminderID: reminder.id,
                occurrenceID: occurrence.id,
                observedRevision: reminder.mutationRevision &+ 1,
                action: .complete
            )
        }

        #expect(harness.store.projects == projectsBefore)
        #expect(try Data(contentsOf: harness.archiveURL) == archiveBefore)
    }

    @Test func updatedReminderRejectsDelayedStopAndDeleteAtThePreviousRevision() throws {
        let harness = try KnittingReminderStoreHarness()
        defer { harness.removeFiles() }
        let reminderID = try harness.store.addKnittingReminder(
            projectID: harness.projectID,
            draft: .oneTime(kind: .increase, target: 2, text: nil)
        )
        let original = try #require(
            harness.store.project(id: harness.projectID)?.knittingReminders.first
        )
        try harness.store.updateKnittingReminder(
            projectID: harness.projectID,
            reminderID: reminderID,
            observedRevision: original.mutationRevision,
            draft: .oneTime(kind: .measure, target: 3, text: nil)
        )
        let replacement = try #require(
            harness.store.project(id: harness.projectID)?.knittingReminders.first
        )
        let projectsBefore = harness.store.projects
        let archiveBefore = try Data(contentsOf: harness.archiveURL)

        #expect(replacement.mutationRevision > original.mutationRevision)
        #expect(throws: KnittingReminderMutationError.staleRevision) {
            try harness.store.applyKnittingReminderAction(
                projectID: harness.projectID,
                reminderID: reminderID,
                occurrenceID: nil,
                observedRevision: original.mutationRevision,
                action: .stop
            )
        }
        #expect(throws: KnittingReminderMutationError.staleRevision) {
            try harness.store.deleteKnittingReminder(
                projectID: harness.projectID,
                reminderID: reminderID,
                observedRevision: original.mutationRevision
            )
        }

        #expect(harness.store.projects == projectsBefore)
        #expect(try Data(contentsOf: harness.archiveURL) == archiveBefore)
    }

    @Test func managingCounterPersistsEveryCrossedProjectReminderOccurrence() throws {
        let harness = try KnittingReminderStoreHarness()
        defer { harness.removeFiles() }
        let firstReminder = try harness.store.addKnittingReminder(
            projectID: harness.projectID,
            draft: .repeating(
                kind: .increase,
                firstTarget: 4,
                interval: 4,
                limit: 3,
                text: nil
            ),
            now: Date(timeIntervalSince1970: 10)
        )
        let secondReminder = try harness.store.addKnittingReminder(
            projectID: harness.projectID,
            draft: .oneTime(kind: .changeYarn, target: 8, text: "Blue"),
            now: Date(timeIntervalSince1970: 20)
        )

        let mutation = try harness.store.manageCounter(
            projectID: harness.projectID,
            counterID: harness.mainCounterID,
            name: "Body",
            value: 12,
            reminder: .unchanged
        )
        let result = try #require(mutation)

        #expect(result.knittingReminderOccurrences.map(\.originalTarget) == [4, 8, 8, 12])
        #expect(result.knittingReminderOccurrences.map(\.reminderID) == [
            firstReminder,
            firstReminder,
            secondReminder,
            firstReminder,
        ])
        #expect(JSONProjectStore(url: harness.archiveURL)
            .project(id: harness.projectID)?
            .knittingReminders
            .flatMap(\.progress.pending)
            .map(\.originalTarget) == [4, 8, 12, 8])
    }

    @Test func exhaustedReminderEvaluationDoesNotPersistCounterMutation() throws {
        let harness = try KnittingReminderStoreHarness()
        defer { harness.removeFiles() }
        let reminderID = try harness.store.addKnittingReminder(
            projectID: harness.projectID,
            draft: .oneTime(kind: .increase, target: 1, text: nil)
        )
        try harness.setReminderRevision(.max, reminderID: reminderID)
        let projectsBefore = harness.store.projects
        let archiveBefore = try Data(contentsOf: harness.archiveURL)

        #expect(throws: StoredProjectCounterMutationError.reminderEvaluationRejected([reminderID])) {
            _ = try harness.store.incrementCounter(
                projectID: harness.projectID,
                counterID: harness.mainCounterID
            )
        }

        #expect(harness.store.projects == projectsBefore)
        #expect(try Data(contentsOf: harness.archiveURL) == archiveBefore)
    }

    @Test func exhaustedReminderRevisionDoesNotReplaceRuleOrPersist() throws {
        let harness = try KnittingReminderStoreHarness()
        defer { harness.removeFiles() }
        let reminderID = try harness.store.addKnittingReminder(
            projectID: harness.projectID,
            draft: .oneTime(kind: .increase, target: 1, text: nil)
        )
        try harness.setReminderRevision(.max, reminderID: reminderID)
        let projectsBefore = harness.store.projects
        let archiveBefore = try Data(contentsOf: harness.archiveURL)

        #expect(throws: KnittingReminderMutationError.revisionExhausted) {
            try harness.store.updateKnittingReminder(
                projectID: harness.projectID,
                reminderID: reminderID,
                observedRevision: .max,
                draft: .oneTime(kind: .measure, target: 2, text: nil)
            )
        }

        #expect(harness.store.projects == projectsBefore)
        #expect(try Data(contentsOf: harness.archiveURL) == archiveBefore)
    }

    @Test func deniedReminderMutationsDoNotPersistOrPublish() throws {
        let harness = try KnittingReminderStoreHarness(authorizeMutation: { _ in .requiresUnlock })
        defer { harness.removeFiles() }
        let projectsBefore = harness.store.projects
        let archiveBefore = try Data(contentsOf: harness.archiveURL)

        #expect(throws: ProjectStoreError.accessRestricted) {
            _ = try harness.store.addKnittingReminder(
                projectID: harness.projectID,
                draft: .oneTime(kind: .cable, target: 2, text: nil)
            )
        }

        #expect(harness.store.projects == projectsBefore)
        #expect(try Data(contentsOf: harness.archiveURL) == archiveBefore)
    }

    @Test func completedProjectDoesNotAcceptReminderMutations() throws {
        let harness = try KnittingReminderStoreHarness(completed: true)
        defer { harness.removeFiles() }
        let projectsBefore = harness.store.projects
        let archiveBefore = try Data(contentsOf: harness.archiveURL)

        #expect(throws: PatternLibraryMutationError.projectCompleted) {
            _ = try harness.store.addKnittingReminder(
                projectID: harness.projectID,
                draft: .oneTime(kind: .cable, target: 2, text: nil)
            )
        }

        #expect(harness.store.projects == projectsBefore)
        #expect(try Data(contentsOf: harness.archiveURL) == archiveBefore)
    }

    @Test func archiveWriteFailureDoesNotPublishReminderMutation() throws {
        enum WriteFailure: Error { case expected }
        let harness = try KnittingReminderStoreHarness(archiveWrite: { _, _ in throw WriteFailure.expected })
        defer { harness.removeFiles() }
        let projectsBefore = harness.store.projects

        #expect(throws: ProjectStoreError.persistenceFailed) {
            _ = try harness.store.addKnittingReminder(
                projectID: harness.projectID,
                draft: .oneTime(kind: .cable, target: 2, text: nil)
            )
        }

        #expect(harness.store.projects == projectsBefore)
    }
}

@MainActor private final class KnittingReminderStoreHarness {
    let root: URL
    let archiveURL: URL
    let projectID: UUID
    let mainCounterID: UUID
    let store: JSONProjectStore

    init(
        completed: Bool = false,
        triggeredReminder: Bool = false,
        archiveWrite: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        },
        authorizeMutation: @escaping MutationAuthorizer = { _ in .allow }
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KnittingReminderStore-\(UUID().uuidString)", isDirectory: true)
        archiveURL = root.appendingPathComponent("projects-v1.json")
        projectID = UUID()
        var project = try StoredProject(id: projectID, name: "Cardigan")
        mainCounterID = project.mainCounterID
        if completed { project.markCompleted() }
        if triggeredReminder {
            _ = try project.addKnittingReminder(
                counterID: mainCounterID,
                draft: .oneTime(kind: .increase, target: 1, text: nil),
                now: .now
            )
            _ = project.incrementCounter(id: mainCounterID)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: [project]
        )).write(to: archiveURL, options: .atomic)
        store = JSONProjectStore(
            url: archiveURL,
            backupService: KnitNoteBackupService(
                liveRoot: root,
                workRoot: root.appendingPathComponent("Work", isDirectory: true)
            ),
            archiveWrite: archiveWrite,
            authorizeMutation: authorizeMutation
        )
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: root)
    }

    func setReminderRevision(_ revision: UInt64, reminderID: UUID) throws {
        var archive = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: archiveURL)) as? [String: Any]
        )
        var projects = try #require(archive["projects"] as? [[String: Any]])
        var project = try #require(projects.first)
        var reminders = try #require(project["knittingReminders"] as? [[String: Any]])
        let reminderIndex = try #require(reminders.firstIndex { $0["id"] as? String == reminderID.uuidString })
        reminders[reminderIndex]["mutationRevision"] = NSNumber(value: revision)
        project["knittingReminders"] = reminders
        projects[0] = project
        archive["projects"] = projects
        try JSONSerialization.data(withJSONObject: archive).write(to: archiveURL, options: .atomic)
        try store.reloadFromDisk()
    }
}
