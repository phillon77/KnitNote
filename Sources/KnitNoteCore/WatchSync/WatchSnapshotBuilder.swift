import Foundation

public enum WatchSnapshotBuilder {
    public static func make(
        projects: [StoredProject],
        locale: Locale,
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
            projects: try orderedProjects.map { project in
                try WatchProjectSnapshot(
                    id: project.id,
                    name: project.name,
                    isCompleted: project.isCompleted,
                    updatedAt: project.updatedAt,
                    counters: project.counters.map { counter in
                        WatchCounterSnapshot(
                            id: counter.id,
                            name: counter.displayName(locale: locale),
                            value: counter.value
                        )
                    },
                    selectedCounterID: project.selectedCounterID
                )
            }
        )
    }
}
