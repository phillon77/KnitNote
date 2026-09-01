import Foundation

public enum WatchSnapshotBuilder {
    public static func make(
        projects: [StoredProject],
        entitlement: EntitlementSnapshot,
        locale: Locale,
        languageCode: String? = nil,
        generatedAt: Date
    ) throws -> WatchSyncSnapshot {
        let orderedProjects = projects.enumerated().sorted { lhs, rhs in
            if lhs.element.isCompleted != rhs.element.isCompleted {
                return !lhs.element.isCompleted
            }
            if lhs.element.updatedAt != rhs.element.updatedAt {
                return lhs.element.updatedAt > rhs.element.updatedAt
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        return WatchSyncSnapshot(
            generatedAt: generatedAt,
            entitlement: watchEntitlement(from: entitlement, generatedAt: generatedAt),
            projects: try orderedProjects.map { project in
                let reminders = try project.knittingReminders
                    .sorted(by: Self.reminderOrdering)
                    .map(WatchKnittingReminderSnapshot.init)
                return try WatchProjectSnapshot(
                    id: project.id,
                    name: project.name,
                    isCompleted: project.isCompleted,
                    updatedAt: project.updatedAt,
                    counters: project.counters.map { counter in
                        WatchCounterSnapshot(
                            id: counter.id,
                            name: counter.displayName(locale: locale),
                            value: counter.value,
                            reminder: Self.legacyCardReminder(
                                for: counter.id,
                                reminders: reminders
                            )
                        )
                    },
                    selectedCounterID: project.selectedCounterID,
                    knittingReminders: reminders
                )
            },
            languageCode: languageCode
        )
    }

    private static func reminderOrdering(
        _ lhs: KnittingReminder,
        _ rhs: KnittingReminder
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func watchEntitlement(
        from entitlement: EntitlementSnapshot,
        generatedAt: Date
    ) -> WatchEntitlementSnapshot {
        switch entitlement {
        case .trialNotStarted:
            WatchEntitlementSnapshot(
                kind: .trialNotStarted,
                expiresAt: nil,
                generatedAt: generatedAt
            )
        case let .trial(_, expiresAt):
            WatchEntitlementSnapshot(
                kind: .trial,
                expiresAt: expiresAt,
                generatedAt: generatedAt
            )
        case .permanentlyUnlocked:
            WatchEntitlementSnapshot(
                kind: .permanentlyUnlocked,
                expiresAt: nil,
                generatedAt: generatedAt
            )
        case .legacyPaidOwner:
            WatchEntitlementSnapshot(
                kind: .legacyPaidOwner,
                expiresAt: nil,
                generatedAt: generatedAt
            )
        }
    }

    /// Transitional projection for the shipping card until Task 8 renders the
    /// project reminder queue directly. It is a read-only compatibility view,
    /// never a second stored reminder representation.
    private static func legacyCardReminder(
        for counterID: UUID,
        reminders: [WatchKnittingReminderSnapshot]
    ) -> WatchCounterReminderSnapshot? {
        guard let reminder = reminders.first(where: {
            $0.counterID == counterID && $0.state == .active
        }) else { return nil }
        let pending = reminder.pending
        let first = pending.map(\.originalTarget).min()
        let last = pending.map(\.originalTarget).max()
        return WatchCounterReminderSnapshot(
            id: reminder.id,
            nextTarget: reminder.nextTarget,
            pending: first.flatMap { first in
                last.map { CounterReminderPending(reminderID: reminder.id, occurrenceCount: pending.count, firstTarget: first, lastTarget: $0) }
            },
            message: reminder.text,
            isActive: true
        )
    }
}
