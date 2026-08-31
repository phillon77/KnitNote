import Combine
import Foundation

public struct KnittingReminderPresentation: Identifiable, Equatable, Sendable {
    public let occurrence: KnittingReminderOccurrence
    public let reminderRevision: UInt64
    public let currentIndex: Int
    public let totalCount: Int

    public var id: UUID { occurrence.id }
    public var phase: KnittingReminderOccurrencePhase { occurrence.phase }
}

public struct KnittingReminderPresentationCoordinator: Sendable {
    public private(set) var current: KnittingReminderPresentation?
    public private(set) var totalCount = 0
    private var presentedHapticOccurrenceIDs = Set<UUID>()

    public init() {
        current = nil
    }

    public mutating func update(project: StoredProject) {
        let reminders = project.knittingReminders.filter { $0.state == .active }
        let queue = reminders.flatMap { reminder -> [(occurrence: KnittingReminderOccurrence, reminder: KnittingReminder)] in
            guard let counter = project.counters.first(where: { $0.id == reminder.counterID }) else {
                return []
            }
            return reminder.visibleOccurrences(at: counter.value).map {
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

    public func shouldPlayHaptic(for occurrence: KnittingReminderOccurrence) -> Bool {
        !presentedHapticOccurrenceIDs.contains(occurrence.id)
    }

    public mutating func markHapticPresented(occurrenceID: UUID) {
        presentedHapticOccurrenceIDs.insert(occurrenceID)
    }
}

/// App-lifetime state shared by project detail and pattern-reader presentations.
/// Entries are keyed by project ID so navigation does not replay a reminder while
/// separate projects keep independent haptic ledgers.
public struct KnittingReminderPresentationLease: Hashable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public let surfaceID: UUID
    public let generation: UInt64

    fileprivate init(projectID: UUID, surfaceID: UUID, generation: UInt64) {
        id = UUID()
        self.projectID = projectID
        self.surfaceID = surfaceID
        self.generation = generation
    }
}

@MainActor
public final class KnittingReminderPresentationStore: ObservableObject {
    private var coordinators: [UUID: KnittingReminderPresentationCoordinator] = [:]
    private var activeLeasesByProject: [UUID: [KnittingReminderPresentationLease]] = [:]
    private var nextLeaseGeneration: UInt64 = 0

    public init() {}

    /// Adds a visible surface to the project lease stack. Repeated appearance
    /// callbacks for the same still-active surface are idempotent; a new lease
    /// is issued after the previous exact lease has been released.
    @discardableResult
    public func acquireSurface(
        projectID: UUID,
        surfaceID: UUID
    ) -> KnittingReminderPresentationLease {
        if let existing = activeLeasesByProject[projectID]?.last(where: {
            $0.surfaceID == surfaceID
        }) {
            return existing
        }
        nextLeaseGeneration &+= 1
        let lease = KnittingReminderPresentationLease(
            projectID: projectID,
            surfaceID: surfaceID,
            generation: nextLeaseGeneration
        )
        activeLeasesByProject[projectID, default: []].append(lease)
        return lease
    }

    /// Removes only the exact lease. Out-of-order releases preserve all other
    /// active surfaces, and releasing the top lease restores the prior one.
    public func releaseSurface(
        projectID: UUID,
        lease: KnittingReminderPresentationLease
    ) {
        guard var leases = activeLeasesByProject[projectID],
              let index = leases.firstIndex(of: lease) else { return }
        leases.remove(at: index)
        if leases.isEmpty {
            activeLeasesByProject.removeValue(forKey: projectID)
        } else {
            activeLeasesByProject[projectID] = leases
        }
    }

    public func isActive(_ lease: KnittingReminderPresentationLease) -> Bool {
        activeLeasesByProject[lease.projectID]?.contains(lease) == true
    }

    public func update(project: StoredProject) -> KnittingReminderPresentation? {
        var coordinator = coordinators[project.id] ?? KnittingReminderPresentationCoordinator()
        coordinator.update(project: project)
        coordinators[project.id] = coordinator
        return coordinator.current
    }

    public func shouldPlayHaptic(
        for occurrence: KnittingReminderOccurrence,
        projectID: UUID
    ) -> Bool {
        coordinators[projectID]?.shouldPlayHaptic(for: occurrence) ?? true
    }

    /// Atomically checks and records a haptic claim. A card that is mounted but
    /// no longer the active surface cannot consume the occurrence's claim.
    public func claimHaptic(
        for occurrence: KnittingReminderOccurrence,
        projectID: UUID,
        lease: KnittingReminderPresentationLease
    ) -> Bool {
        guard activeLeasesByProject[projectID]?.last == lease,
              var coordinator = coordinators[projectID],
              coordinator.shouldPlayHaptic(for: occurrence) else {
            return false
        }
        coordinator.markHapticPresented(occurrenceID: occurrence.id)
        coordinators[projectID] = coordinator
        return true
    }

    public func markHapticPresented(occurrenceID: UUID, projectID: UUID) {
        guard var coordinator = coordinators[projectID] else { return }
        coordinator.markHapticPresented(occurrenceID: occurrenceID)
        coordinators[projectID] = coordinator
    }

    /// Reconciles the presentation cache with the authoritative project list.
    /// Removed projects release both their coordinator and active surface lease.
    public func pruneProjects(keeping projectIDs: Set<UUID>) {
        coordinators = coordinators.filter { projectIDs.contains($0.key) }
        activeLeasesByProject = activeLeasesByProject.filter { projectIDs.contains($0.key) }
    }
}
