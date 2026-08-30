import CryptoKit
import Foundation

extension ProjectArchive {
    public static let knittingRemindersIntroducedVersion = 14
}

public enum KnittingReminderMigrationError: Error, Equatable, Sendable {
    case unsupportedFutureVersion(Int)
    case invalidLegacyReminder
    case arithmeticOverflow
    case invalidMigratedArchive
}

public enum KnittingReminderMigrator {
    public static func migrate(_ archive: ProjectArchive) throws -> ProjectArchive {
        guard ProjectArchive.isSupported(version: archive.version) else {
            throw KnittingReminderMigrationError.unsupportedFutureVersion(archive.version)
        }
        guard needsMigration(archive) else {
            try validate(archive)
            return archive
        }

        let projects = try archive.projects.map(migrate)
        let migrated = ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: projects,
            yarns: archive.yarns,
            patternFolders: archive.patternFolders,
            patternAssets: archive.patternAssets,
            patterns: archive.patterns,
            patternUsages: archive.patternUsages
        )
        try validate(migrated)
        return migrated
    }

    public static func validate(_ archive: ProjectArchive) throws {
        guard archive.version == ProjectArchive.currentVersion,
              Set(archive.projects.map(\.id)).count == archive.projects.count,
              archive.projects.allSatisfy({ project in
                  Set(project.knittingReminders.map(\.id)).count == project.knittingReminders.count
                      && Set(project.counters.map(\.id)).count == project.counters.count
                      && project.knittingReminders.allSatisfy { reminder in
                          project.counters.contains(where: { $0.id == reminder.counterID })
                      }
                      && project.counters.allSatisfy({ $0.reminder == nil })
              })
        else {
            throw KnittingReminderMigrationError.invalidMigratedArchive
        }
    }

    public static func needsMigration(_ archive: ProjectArchive) -> Bool {
        archive.version < ProjectArchive.knittingRemindersIntroducedVersion
            || archive.projects.contains { project in project.counters.contains { $0.reminder != nil } }
    }

    private static func migrate(_ project: StoredProject) throws -> StoredProject {
        let legacyReminders = try project.counters.compactMap { counter in
            try counter.reminder.map { try migrate($0, counter: counter, createdAt: project.updatedAt) }
        }
        let reminders = project.knittingReminders + legacyReminders
        guard Set(reminders.map(\.id)).count == reminders.count else {
            throw KnittingReminderMigrationError.invalidMigratedArchive
        }
        let counters = project.counters.map { counter in
            ProjectCounter(
                id: counter.id,
                defaultOrdinal: counter.defaultOrdinal,
                customName: counter.customName,
                value: counter.value,
                mutationRevision: counter.mutationRevision,
                rowNotes: counter.rowNotes
            )
        }
        return try replacing(project, counters: counters, knittingReminders: reminders)
    }

    private static func migrate(
        _ legacy: CounterReminder,
        counter: ProjectCounter,
        createdAt: Date
    ) throws -> KnittingReminder {
        let rule: KnittingReminderRule
        let limit: Int?
        switch legacy.rule {
        case let .oneTime(target):
            guard target > legacy.anchorValue else {
                throw KnittingReminderMigrationError.invalidLegacyReminder
            }
            rule = .oneTime(target: target)
            limit = 1
        case let .repeating(interval, repeatingLimit):
            guard interval > 0, repeatingLimit.map({ $0 > 0 }) ?? true else {
                throw KnittingReminderMigrationError.invalidLegacyReminder
            }
            let (firstTarget, overflow) = legacy.anchorValue.addingReportingOverflow(interval)
            guard !overflow else { throw KnittingReminderMigrationError.arithmeticOverflow }
            rule = .repeating(firstTarget: firstTarget, interval: interval, limit: repeatingLimit)
            limit = repeatingLimit
        }

        let pendingCount = legacy.pending?.occurrenceCount ?? 0
        let (scheduledCount, scheduledOverflow) = legacy.acknowledgedCount.addingReportingOverflow(pendingCount)
        guard !scheduledOverflow,
              legacy.acknowledgedCount >= 0,
              pendingCount >= 0,
              limit.map({ scheduledCount <= $0 }) ?? true
        else { throw KnittingReminderMigrationError.invalidLegacyReminder }

        let (nextIndex, indexOverflow) = scheduledCount.addingReportingOverflow(1)
        guard !indexOverflow else { throw KnittingReminderMigrationError.arithmeticOverflow }
        let expectedNextTarget = try target(for: rule, occurrence: nextIndex)
        guard legacy.isActive
            ? legacy.nextTarget == expectedNextTarget
            : legacy.nextTarget == nil && legacy.pending == nil
        else {
            throw KnittingReminderMigrationError.invalidLegacyReminder
        }

        let pending: [KnittingReminderOccurrence]
        if let legacyPending = legacy.pending {
            pending = try migratePending(legacyPending, legacy: legacy, rule: rule)
        } else {
            pending = []
        }

        let state: KnittingReminderState
        if legacy.isActive {
            state = .active
        } else if limit.map({ legacy.acknowledgedCount >= $0 }) ?? false {
            state = .completed
        } else {
            state = .stopped
        }
        let progress = MigrationProgress(
            scheduledCount: scheduledCount,
            completedCount: legacy.acknowledgedCount,
            skippedCount: 0,
            nextTarget: legacy.nextTarget,
            nextOccurrenceIndex: nextIndex,
            lastObservedCounterValue: counter.value,
            pending: pending,
            latestHandled: nil
        )
        return try decode(MigrationRecord(
            id: legacy.id,
            counterID: counter.id,
            kind: .custom,
            text: legacy.message,
            rule: rule,
            progress: progress,
            state: state,
            mutationRevision: legacy.mutationRevision,
            createdAt: createdAt
        ))
    }

    private static func migratePending(
        _ pending: CounterReminderPending,
        legacy: CounterReminder,
        rule: KnittingReminderRule
    ) throws -> [KnittingReminderOccurrence] {
        guard pending.reminderID == legacy.id, pending.occurrenceCount > 0 else {
            throw KnittingReminderMigrationError.invalidLegacyReminder
        }
        return try (1...pending.occurrenceCount).map { offset -> KnittingReminderOccurrence in
            let (occurrenceIndex, overflow) = legacy.acknowledgedCount.addingReportingOverflow(offset)
            guard !overflow,
                  let target = try target(for: rule, occurrence: occurrenceIndex)
            else { throw KnittingReminderMigrationError.invalidLegacyReminder }
            guard (offset == 1 ? pending.firstTarget : target) == target,
                  (offset == pending.occurrenceCount ? pending.lastTarget : target) == target
            else { throw KnittingReminderMigrationError.invalidLegacyReminder }
            return KnittingReminderOccurrence(
                id: occurrenceID(reminderID: legacy.id, occurrence: occurrenceIndex),
                reminderID: legacy.id,
                kind: .custom,
                text: legacy.message,
                originalTarget: target,
                displayAt: target,
                phase: .initial,
                awaitsNextUpwardChange: false
            )
        }
    }

    private static func target(for rule: KnittingReminderRule, occurrence: Int) throws -> Int? {
        guard occurrence > 0 else { throw KnittingReminderMigrationError.invalidLegacyReminder }
        switch rule {
        case let .oneTime(target):
            return occurrence == 1 ? target : nil
        case let .repeating(firstTarget, interval, limit):
            guard limit.map({ occurrence <= $0 }) ?? true else { return nil }
            let (offset, multiplicationOverflow) = interval.multipliedReportingOverflow(by: occurrence - 1)
            guard !multiplicationOverflow else { throw KnittingReminderMigrationError.arithmeticOverflow }
            let (target, additionOverflow) = firstTarget.addingReportingOverflow(offset)
            guard !additionOverflow else { throw KnittingReminderMigrationError.arithmeticOverflow }
            return target
        }
    }

    private static func occurrenceID(reminderID: UUID, occurrence: Int) -> UUID {
        let digest = SHA256.hash(data: Data("\(reminderID.uuidString):\(occurrence)".utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func decode(_ record: MigrationRecord) throws -> KnittingReminder {
        do {
            return try JSONDecoder().decode(KnittingReminder.self, from: JSONEncoder().encode(record))
        } catch {
            throw KnittingReminderMigrationError.invalidLegacyReminder
        }
    }

    private static func replacing(
        _ project: StoredProject,
        counters: [ProjectCounter],
        knittingReminders: [KnittingReminder]
    ) throws -> StoredProject {
        do {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any]
            guard object != nil else { throw KnittingReminderMigrationError.invalidMigratedArchive }
            object!["counters"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(counters))
            object!["knittingReminders"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(knittingReminders))
            return try JSONDecoder().decode(
                StoredProject.self,
                from: JSONSerialization.data(withJSONObject: object!)
            )
        } catch let error as KnittingReminderMigrationError {
            throw error
        } catch {
            throw KnittingReminderMigrationError.invalidMigratedArchive
        }
    }
}

private struct MigrationProgress: Encodable {
    let scheduledCount: Int
    let completedCount: Int
    let skippedCount: Int
    let nextTarget: Int?
    let nextOccurrenceIndex: Int
    let lastObservedCounterValue: Int?
    let pending: [KnittingReminderOccurrence]
    let latestHandled: KnittingReminderOccurrence?
}

private struct MigrationRecord: Encodable {
    let id: UUID
    let counterID: UUID
    let kind: KnittingReminderKind
    let text: String?
    let rule: KnittingReminderRule
    let progress: MigrationProgress
    let state: KnittingReminderState
    let mutationRevision: UInt64
    let createdAt: Date
}
