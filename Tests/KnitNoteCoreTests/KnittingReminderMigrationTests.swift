import Foundation
import Testing
@testable import KnitNoteCore

@Suite @MainActor struct KnittingReminderMigrationTests {
    @Test func version13MigratesEveryCounterReminderWithoutRebinding() throws {
        let projectID = UUID()
        let counters = try (1...6).map { ordinal in
            let counterID = UUID()
            let reminder = try #require(CounterReminder(
                draft: .oneTime(target: ordinal * 10, message: "Legacy \(ordinal)"),
                anchorValue: 0,
                id: UUID()
            ))
            return ProjectCounter(
                id: counterID,
                defaultOrdinal: ordinal,
                value: 0,
                reminder: reminder
            )
        }
        let project = try StoredProject(id: projectID, name: "Legacy", counters: counters)

        let migrated = try KnittingReminderMigrator.migrate(
            ProjectArchive(version: 13, projects: [project])
        )
        let migratedProject = try #require(migrated.projects.first)

        #expect(migrated.version == 14)
        #expect(migratedProject.knittingReminders.count == 6)
        #expect(migratedProject.knittingReminders.map(\.counterID) == migratedProject.counters.map(\.id))
        #expect(migratedProject.counters.allSatisfy { $0.reminder == nil })
    }

    @Test func migrationPreservesLegacyProgressMessageAndRevision() throws {
        let counterID = UUID()
        var legacy = try #require(CounterReminder(
            draft: .repeating(interval: 5, limit: 8, message: "Turn work"),
            anchorValue: 10,
            id: UUID()
        ))
        _ = legacy.applyUpwardChange(to: 25)
        let completed = legacy.completePending(id: legacy.id, observedCount: 3)
        #expect(completed)
        _ = legacy.applyUpwardChange(to: 40)
        let project = try StoredProject(
            name: "Sleeve",
            counters: [ProjectCounter(id: counterID, defaultOrdinal: 1, value: 40, reminder: legacy)]
        )

        let migrated = try KnittingReminderMigrator.migrate(ProjectArchive(version: 13, projects: [project]))
        let reminder = try #require(migrated.projects[0].knittingReminders.first)

        #expect(reminder.id == legacy.id)
        #expect(reminder.counterID == counterID)
        #expect(reminder.text == "Turn work")
        #expect(reminder.rule == .repeating(firstTarget: 15, interval: 5, limit: 8))
        #expect(reminder.progress.completedCount == 3)
        #expect(reminder.progress.scheduledCount == 6)
        #expect(reminder.progress.nextTarget == 45)
        #expect(reminder.progress.pending.map(\.originalTarget) == [30, 35, 40])
        #expect(reminder.mutationRevision == legacy.mutationRevision)
    }

    @Test func stoppedLegacyReminderStaysStoppedWithoutPendingOccurrences() throws {
        let counterID = UUID()
        var legacy = try #require(CounterReminder(
            draft: .repeating(interval: 2, limit: nil, message: nil),
            anchorValue: 4,
            id: UUID()
        ))
        let stopped = legacy.stop(id: legacy.id)
        #expect(stopped)
        let project = try StoredProject(
            name: "Hat",
            counters: [ProjectCounter(id: counterID, defaultOrdinal: 1, value: 4, reminder: legacy)]
        )

        let migrated = try KnittingReminderMigrator.migrate(ProjectArchive(version: 13, projects: [project]))
        let reminder = try #require(migrated.projects[0].knittingReminders.first)

        #expect(reminder.state == .stopped)
        #expect(reminder.progress.pending.isEmpty)
        #expect(reminder.progress.nextTarget == nil)
        #expect(reminder.mutationRevision == legacy.mutationRevision)
    }

    @Test func currentArchiveMigrationIsIdempotentAndFutureArchivesAreRejected() throws {
        let current = ProjectArchive(version: ProjectArchive.currentVersion, projects: [])
        let migrated = try KnittingReminderMigrator.migrate(current)

        #expect(migrated.version == ProjectArchive.currentVersion)
        #expect(!KnittingReminderMigrator.needsMigration(migrated))
        #expect(throws: KnittingReminderMigrationError.unsupportedFutureVersion(15)) {
            try KnittingReminderMigrator.migrate(ProjectArchive(version: 15, projects: []))
        }
    }

    @Test func startupMigratesVersionThirteenArchiveBeforePublishingProjects() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KnittingReminderStartupMigration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archiveURL = root.appendingPathComponent("projects-v1.json")
        let counterID = UUID()
        let legacy = try #require(CounterReminder(
            draft: .oneTime(target: 3, message: "Join yarn"),
            anchorValue: 0,
            id: UUID()
        ))
        let project = try StoredProject(
            name: "Body",
            counters: [ProjectCounter(id: counterID, defaultOrdinal: 1, reminder: legacy)]
        )
        try JSONEncoder().encode(ProjectArchive(version: 13, projects: [project])).write(
            to: archiveURL,
            options: .atomic
        )

        let store = JSONProjectStore(url: archiveURL)
        let installed = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: archiveURL))

        #expect(store.loadError == nil)
        #expect(installed.version == ProjectArchive.currentVersion)
        #expect(installed.projects == store.projects)
        #expect(installed.projects[0].counters[0].reminder == nil)
        #expect(installed.projects[0].knittingReminders[0].counterID == counterID)

        _ = try store.updateCounter(
            projectID: project.id,
            counterID: counterID,
            name: "Body",
            value: 1
        )
        let reloadedArchive = try JSONDecoder().decode(
            ProjectArchive.self,
            from: Data(contentsOf: archiveURL)
        )
        #expect(reloadedArchive.projects[0].counters.allSatisfy { $0.reminder == nil })
        #expect(JSONProjectStore(url: archiveURL).loadError == nil)
    }

    @Test func migratedSecondaryReminderTriggersOnlyFromItsOwningCounterAfterReload() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondaryReminderReload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archiveURL = root.appendingPathComponent("projects-v1.json")
        let mainID = UUID()
        let secondaryID = UUID()
        let unrelatedID = UUID()
        let legacy = try #require(CounterReminder(
            draft: .repeating(interval: 2, limit: nil, message: "Secondary"),
            anchorValue: 0,
            id: UUID()
        ))
        let project = try StoredProject(
            name: "Sleeve",
            counters: [
                ProjectCounter(id: mainID, defaultOrdinal: 1),
                ProjectCounter(id: secondaryID, defaultOrdinal: 2, reminder: legacy),
                ProjectCounter(id: unrelatedID, defaultOrdinal: 3),
            ]
        )
        try JSONEncoder().encode(ProjectArchive(version: 13, projects: [project]))
            .write(to: archiveURL, options: .atomic)

        var store = JSONProjectStore(url: archiveURL)
        #expect(store.loadError == nil)
        store = JSONProjectStore(url: archiveURL)
        let migrated = try #require(store.project(id: project.id)?.knittingReminders.first)
        #expect(migrated.counterID == secondaryID)

        _ = try store.incrementCounter(projectID: project.id, counterID: mainID)
        _ = try store.updateCounter(
            projectID: project.id,
            counterID: unrelatedID,
            name: nil,
            value: 20
        )
        #expect(store.project(id: project.id)?.knittingReminders.first?.progress.pending.isEmpty == true)

        _ = try store.incrementCounter(projectID: project.id, counterID: secondaryID)
        _ = try store.incrementCounter(projectID: project.id, counterID: secondaryID)
        #expect(store.project(id: project.id)?.knittingReminders.first?.progress.pending.map(\.originalTarget) == [2])

        _ = try store.updateCounter(
            projectID: project.id,
            counterID: secondaryID,
            name: nil,
            value: 7
        )
        let reloaded = JSONProjectStore(url: archiveURL)
        #expect(reloaded.project(id: project.id)?.knittingReminders.first?.progress.pending.map(\.originalTarget) == [2, 4, 6])
    }

    @Test func startupPersistenceFailureLeavesLegacyArchiveAndPublishedStateUnchanged() throws {
        enum WriteFailure: Error { case expected }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KnittingReminderStartupWriteFailure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archiveURL = root.appendingPathComponent("projects-v1.json")
        let legacy = try #require(CounterReminder(
            draft: .oneTime(target: 2, message: nil),
            anchorValue: 0,
            id: UUID()
        ))
        let project = try StoredProject(
            name: "Sleeve",
            counters: [ProjectCounter(defaultOrdinal: 1, reminder: legacy)]
        )
        try JSONEncoder().encode(ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: [project]
        )).write(to: archiveURL, options: .atomic)
        let bytesBefore = try Data(contentsOf: archiveURL)

        let store = JSONProjectStore(
            url: archiveURL,
            backupService: KnitNoteBackupService(
                liveRoot: root,
                workRoot: root.appendingPathComponent("BackupWork")
            ),
            archiveWrite: { _, _ in throw WriteFailure.expected }
        )

        #expect(store.loadError == .unreadableArchive)
        #expect(store.projects.isEmpty)
        #expect(try Data(contentsOf: archiveURL) == bytesBefore)
    }

    @Test func versionThirteenBackupStagesReminderMigrationWithoutChangingManifestSummary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KnittingReminderBackupMigration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("Live")
        let work = root.appendingPathComponent("Work")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        let projectID = UUID()
        let counterID = UUID()
        let baseline = try StoredProject(
            id: projectID,
            name: "Backup",
            counters: [ProjectCounter(id: counterID, defaultOrdinal: 1)]
        )
        let archiveURL = live.appendingPathComponent("projects-v1.json")
        try JSONEncoder().encode(ProjectArchive(version: 14, projects: [baseline])).write(
            to: archiveURL,
            options: .atomic
        )
        let service = KnitNoteBackupService(liveRoot: live, workRoot: work)
        let package = try service.createPackage(appVersion: "test")
        let legacy = try #require(CounterReminder(
            draft: .oneTime(target: 4, message: "Bind off"),
            anchorValue: 0,
            id: UUID()
        ))
        let legacyProject = try StoredProject(
            id: projectID,
            name: "Backup",
            counters: [ProjectCounter(id: counterID, defaultOrdinal: 1, reminder: legacy)]
        )
        try JSONEncoder().encode(ProjectArchive(version: 13, projects: [legacyProject])).write(
            to: package.appendingPathComponent("Data/projects-v1.json"),
            options: .atomic
        )
        let manifestURL = package.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(KnitNoteBackupManifest.self, from: Data(contentsOf: manifestURL))
        try JSONEncoder().encode(KnitNoteBackupManifest(
            formatVersion: 1,
            createdAt: manifest.createdAt,
            appVersion: manifest.appVersion,
            projectCount: manifest.projectCount,
            yarnCount: manifest.yarnCount
        )).write(to: manifestURL, options: .atomic)

        let restore = KnitNoteBackupService(
            liveRoot: root.appendingPathComponent("Restore"),
            workRoot: root.appendingPathComponent("RestoreWork")
        )
        let staged = try restore.stagePackage(at: package)
        let stagedArchive = try JSONDecoder().decode(
            ProjectArchive.self,
            from: Data(contentsOf: staged.root.appendingPathComponent("Data/projects-v1.json"))
        )

        #expect(staged.preview.projectCount == manifest.projectCount)
        #expect(staged.preview.yarnCount == manifest.yarnCount)
        #expect(stagedArchive.version == 14)
        #expect(stagedArchive.projects[0].counters[0].reminder == nil)
        #expect(stagedArchive.projects[0].knittingReminders[0].counterID == counterID)
    }

    @Test func compatibilityAdapterRejectsSecondaryCreationAndPreservesIndependentRules() throws {
        let projectID = UUID()
        let counters = (1...6).map { ProjectCounter(defaultOrdinal: $0) }
        var project = try StoredProject(id: projectID, name: "Adapter", counters: counters)
        let secondaryID = project.counters[1].id

        let secondaryConfigured = project.configureCounterReminderV14(
            id: secondaryID,
            draft: .oneTime(target: 2, message: "Secondary")
        )
        #expect(!secondaryConfigured)
        #expect(project.knittingReminders.isEmpty)

        let mainID = project.mainCounterID
        let first = try #require(KnittingReminder(
            counterID: mainID,
            draft: .oneTime(kind: .custom, target: 2, text: "First"),
            createdAt: .now
        ))
        let second = try #require(KnittingReminder(
            counterID: mainID,
            draft: .oneTime(kind: .measure, target: 3, text: "Second"),
            createdAt: .now
        ))
        project = try StoredProject(
            id: projectID,
            name: "Adapter",
            counters: project.counters,
            knittingReminders: [first, second]
        )

        #expect(project.manageCounter(
            id: mainID,
            name: nil,
            value: 0,
            reminder: .replace(.oneTime(target: 4, message: "Ambiguous"))
        ) == nil)
        #expect(project.knittingReminders.map(\.id) == [first.id, second.id])
    }

    @Test func brokenVersionThirteenBackupIsRejectedWithoutTouchingLiveTree() throws {
        let fixture = try legacyBackupFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let packageArchiveURL = fixture.package.appendingPathComponent("Data/projects-v1.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: packageArchiveURL)) as! [String: Any]
        var projects = object["projects"] as! [[String: Any]]
        var counters = projects[0]["counters"] as! [[String: Any]]
        counters[0]["id"] = UUID().uuidString
        projects[0]["counters"] = counters
        object["projects"] = projects
        try JSONSerialization.data(withJSONObject: object).write(to: packageArchiveURL, options: .atomic)

        #expect(throws: KnitNoteBackupError.invalidArchive) {
            _ = try fixture.restore.stagePackage(at: fixture.package)
        }
        #expect(try Data(contentsOf: fixture.liveArchiveURL) == fixture.liveArchiveBytes)
    }

    @Test func overflowingVersionThirteenBackupIsRejectedWithoutTouchingLiveTree() throws {
        let interval = Int.max / 2
        var legacy = try #require(CounterReminder(
            draft: .repeating(interval: interval, limit: nil, message: "Overflow"),
            anchorValue: 0,
            id: UUID()
        ))
        _ = legacy.applyUpwardChange(to: Int.max - 1)
        let fixture = try legacyBackupFixture(reminder: legacy)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(throws: KnitNoteBackupError.invalidArchive) {
            _ = try fixture.restore.stagePackage(at: fixture.package)
        }
        #expect(try Data(contentsOf: fixture.liveArchiveURL) == fixture.liveArchiveBytes)
    }
}

@MainActor
private func legacyBackupFixture(
    reminder: CounterReminder? = nil
) throws -> (root: URL, package: URL, restore: KnitNoteBackupService, liveArchiveURL: URL, liveArchiveBytes: Data) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("KnittingReminderBackupFailure-\(UUID().uuidString)")
    let sourceLive = root.appendingPathComponent("Source")
    let restoreLive = root.appendingPathComponent("Restore")
    try FileManager.default.createDirectory(at: sourceLive, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: restoreLive, withIntermediateDirectories: true)
    let projectID = UUID()
    let counterID = UUID()
    let baseline = try StoredProject(
        id: projectID,
        name: "Backup",
        counters: [ProjectCounter(id: counterID, defaultOrdinal: 1)]
    )
    let sourceArchiveURL = sourceLive.appendingPathComponent("projects-v1.json")
    try JSONEncoder().encode(ProjectArchive(version: 14, projects: [baseline])).write(
        to: sourceArchiveURL,
        options: .atomic
    )
    let source = KnitNoteBackupService(
        liveRoot: sourceLive,
        workRoot: root.appendingPathComponent("SourceWork")
    )
    let package = try source.createPackage(appVersion: "test")
    let legacy: CounterReminder
    if let reminder {
        legacy = reminder
    } else {
        legacy = try #require(CounterReminder(
            draft: .oneTime(target: 4, message: "Legacy"), anchorValue: 0, id: UUID()
        ))
    }
    let existingReminder = try #require(KnittingReminder(
        counterID: counterID,
        draft: .oneTime(kind: .measure, target: 6, text: "Existing"),
        createdAt: .now
    ))
    let legacyProject = try StoredProject(
        id: projectID,
        name: "Backup",
        counters: [ProjectCounter(id: counterID, defaultOrdinal: 1, reminder: legacy)],
        knittingReminders: [existingReminder]
    )
    try JSONEncoder().encode(ProjectArchive(version: 13, projects: [legacyProject])).write(
        to: package.appendingPathComponent("Data/projects-v1.json"), options: .atomic
    )
    let manifestURL = package.appendingPathComponent("manifest.json")
    let manifest = try JSONDecoder().decode(KnitNoteBackupManifest.self, from: Data(contentsOf: manifestURL))
    try JSONEncoder().encode(KnitNoteBackupManifest(
        formatVersion: 1, createdAt: manifest.createdAt, appVersion: manifest.appVersion,
        projectCount: manifest.projectCount, yarnCount: manifest.yarnCount
    )).write(to: manifestURL, options: .atomic)
    let liveArchiveURL = restoreLive.appendingPathComponent("projects-v1.json")
    let liveArchiveBytes = Data("original-live-archive".utf8)
    try liveArchiveBytes.write(to: liveArchiveURL, options: .atomic)
    return (root, package, KnitNoteBackupService(
        liveRoot: restoreLive, workRoot: root.appendingPathComponent("RestoreWork")
    ), liveArchiveURL, liveArchiveBytes)
}
