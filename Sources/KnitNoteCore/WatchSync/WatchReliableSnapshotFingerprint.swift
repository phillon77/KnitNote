import Foundation

struct WatchReliableSnapshotFingerprint: Equatable, Sendable {
    private struct Project: Equatable, Sendable {
        struct Counter: Equatable, Sendable {
            let id: UUID
            let name: String
        }

        let id: UUID
        let name: String
        let isCompleted: Bool
        let counters: [Counter]
        let selectedCounterID: UUID
    }

    private let projects: [Project]

    init(snapshot: WatchSyncSnapshot) {
        projects = snapshot.projects.map { project in
            Project(
                id: project.id,
                name: project.name,
                isCompleted: project.isCompleted,
                counters: project.counters.map { counter in
                    Project.Counter(id: counter.id, name: counter.name)
                }.sorted { $0.id.uuidString < $1.id.uuidString },
                selectedCounterID: project.selectedCounterID
            )
        }.sorted { $0.id.uuidString < $1.id.uuidString }
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
