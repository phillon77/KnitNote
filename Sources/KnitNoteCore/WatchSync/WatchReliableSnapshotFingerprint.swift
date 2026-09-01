import Foundation

struct WatchReliableSnapshotFingerprint: Equatable, Sendable {
    private struct Project: Equatable, Sendable {
        struct Reminder: Equatable, Sendable {
            struct Occurrence: Equatable, Sendable {
                let id: UUID
                let reminderID: UUID
                let kind: KnittingReminderKind
                let text: String?
                let originalTarget: Int
                let displayAt: Int
                let phase: KnittingReminderOccurrencePhase
                let awaitsNextUpwardChange: Bool
            }

            let id: UUID
            let counterID: UUID
            let kind: KnittingReminderKind
            let text: String?
            let rule: KnittingReminderRule
            let state: KnittingReminderState
            let mutationRevision: UInt64
            let createdAt: Date
            let scheduledCount: Int
            let completedCount: Int
            let skippedCount: Int
            let nextTarget: Int?
            let nextOccurrenceIndex: Int
            let lastObservedCounterValue: Int?
            let pending: [Occurrence]
            let latestHandled: Occurrence?
        }

        struct Counter: Equatable, Sendable {
            let id: UUID
            let name: String
        }

        let id: UUID
        let name: String
        let isCompleted: Bool
        let counters: [Counter]
        let selectedCounterID: UUID
        let reminders: [Reminder]
    }

    private let projects: [Project]
    private let entitlementKind: WatchEntitlementSnapshot.Kind
    private let entitlementExpiry: Date?
    private let entitlementAllowsMutation: Bool
    private let languageCode: String?

    init(snapshot: WatchSyncSnapshot) {
        entitlementKind = snapshot.entitlement.kind
        entitlementExpiry = snapshot.entitlement.expiresAt
        entitlementAllowsMutation = snapshot.entitlement.canMutate(
            now: snapshot.generatedAt
        )
        languageCode = snapshot.languageCode
        projects = snapshot.projects.map { project in
            Project(
                id: project.id,
                name: project.name,
                isCompleted: project.isCompleted,
                counters: project.counters.map { counter in
                    Project.Counter(id: counter.id, name: counter.name)
                }.sorted { $0.id.uuidString < $1.id.uuidString },
                selectedCounterID: project.selectedCounterID,
                reminders: project.knittingReminders.map { reminder in
                    Project.Reminder(
                        id: reminder.id,
                        counterID: reminder.counterID,
                        kind: reminder.kind,
                        text: reminder.text,
                        rule: reminder.rule,
                        state: reminder.state,
                        mutationRevision: reminder.mutationRevision,
                        createdAt: reminder.createdAt,
                        scheduledCount: reminder.scheduledCount,
                        completedCount: reminder.completedCount,
                        skippedCount: reminder.skippedCount,
                        nextTarget: reminder.nextTarget,
                        nextOccurrenceIndex: reminder.nextOccurrenceIndex,
                        lastObservedCounterValue: reminder.lastObservedCounterValue,
                        pending: reminder.pending.map {
                            Project.Reminder.Occurrence(
                                id: $0.id,
                                reminderID: $0.reminderID,
                                kind: $0.kind,
                                text: $0.text,
                                originalTarget: $0.originalTarget,
                                displayAt: $0.displayAt,
                                phase: $0.phase,
                                awaitsNextUpwardChange: $0.awaitsNextUpwardChange
                            )
                        }.sorted(by: Self.occurrenceOrdering),
                        latestHandled: reminder.latestHandled.map {
                            Project.Reminder.Occurrence(id: $0.id, reminderID: $0.reminderID, kind: $0.kind, text: $0.text, originalTarget: $0.originalTarget, displayAt: $0.displayAt, phase: $0.phase, awaitsNextUpwardChange: $0.awaitsNextUpwardChange)
                        }
                    )
                }.sorted {
                    if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
            )
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private static func occurrenceOrdering(_ lhs: Project.Reminder.Occurrence, _ rhs: Project.Reminder.Occurrence) -> Bool {
        if lhs.originalTarget != rhs.originalTarget { return lhs.originalTarget < rhs.originalTarget }
        if lhs.displayAt != rhs.displayAt { return lhs.displayAt < rhs.displayAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

struct WatchReliableSnapshotTransferState: Equatable, Sendable {
    private struct PreparedTransfer: Equatable, Sendable {
        let fingerprint: WatchReliableSnapshotFingerprint
        let generatedAt: Date
    }

    private var lastPreparedTransfer: PreparedTransfer?

    mutating func prepareTransfer(of snapshot: WatchSyncSnapshot) -> Bool {
        let fingerprint = WatchReliableSnapshotFingerprint(snapshot: snapshot)
        guard fingerprint != lastPreparedTransfer?.fingerprint else { return false }
        lastPreparedTransfer = PreparedTransfer(
            fingerprint: fingerprint,
            generatedAt: snapshot.generatedAt
        )
        return true
    }

    mutating func recordFailure(of snapshot: WatchSyncSnapshot) -> Bool {
        let failedTransfer = PreparedTransfer(
            fingerprint: WatchReliableSnapshotFingerprint(snapshot: snapshot),
            generatedAt: snapshot.generatedAt
        )
        guard failedTransfer == lastPreparedTransfer else { return false }
        lastPreparedTransfer = nil
        return true
    }
}
