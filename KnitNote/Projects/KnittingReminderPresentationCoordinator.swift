import Foundation

struct KnittingReminderPresentation: Identifiable, Equatable, Sendable {
    let occurrence: KnittingReminderOccurrence
    let reminderRevision: UInt64
    let currentIndex: Int
    let totalCount: Int

    var id: UUID { occurrence.id }
    var phase: KnittingReminderOccurrencePhase { occurrence.phase }
}

struct KnittingReminderPresentationCoordinator: Sendable {
    private(set) var current: KnittingReminderPresentation?
    private(set) var totalCount = 0
    private var presentedHapticOccurrenceIDs = Set<UUID>()

    init() {
        current = nil
    }

    mutating func update(project: StoredProject) {
        let mainCounterValue = project.counters.first(where: { $0.id == project.mainCounterID })?.value
            ?? project.counters[0].value
        let reminders = project.knittingReminders.filter { $0.state == .active }
        let queue = reminders.flatMap { reminder in
            reminder.visibleOccurrences(at: mainCounterValue).map {
                (occurrence: $0, reminder: reminder)
            }
        }.sorted { left, right in
            if left.occurrence.originalTarget != right.occurrence.originalTarget {
                return left.occurrence.originalTarget < right.occurrence.originalTarget
            }
            if left.reminder.createdAt != right.reminder.createdAt {
                return left.reminder.createdAt < right.reminder.createdAt
            }
            if left.reminder.id.uuidString != right.reminder.id.uuidString {
                return left.reminder.id.uuidString < right.reminder.id.uuidString
            }
            if left.occurrence.reminderID.uuidString != right.occurrence.reminderID.uuidString {
                return left.occurrence.reminderID.uuidString < right.occurrence.reminderID.uuidString
            }
            return left.occurrence.id.uuidString < right.occurrence.id.uuidString
        }

        let pendingIDs = Set(reminders.flatMap { $0.progress.pending.map(\.id) })
        presentedHapticOccurrenceIDs.formIntersection(pendingIDs)
        totalCount = queue.count
        current = queue.first.map {
            KnittingReminderPresentation(
                occurrence: $0.occurrence,
                reminderRevision: $0.reminder.mutationRevision,
                currentIndex: 1,
                totalCount: queue.count
            )
        }
    }

    func shouldPlayHaptic(for occurrence: KnittingReminderOccurrence) -> Bool {
        !presentedHapticOccurrenceIDs.contains(occurrence.id)
    }

    mutating func markHapticPresented(occurrenceID: UUID) {
        presentedHapticOccurrenceIDs.insert(occurrenceID)
    }
}
