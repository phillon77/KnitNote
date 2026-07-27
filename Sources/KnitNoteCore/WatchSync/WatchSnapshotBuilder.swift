import Foundation

public enum WatchSnapshotBuilder {
    public static func make(
        projects: [StoredProject],
        entitlement: EntitlementSnapshot,
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
            entitlement: watchEntitlement(from: entitlement, generatedAt: generatedAt),
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
}
