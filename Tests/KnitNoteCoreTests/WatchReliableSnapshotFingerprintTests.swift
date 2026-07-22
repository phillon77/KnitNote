import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct WatchReliableSnapshotFingerprintTests {
    @Test func ignoresCounterValuesAndTimestamps() throws {
        let first = try snapshot(value: 1, updatedAt: 10, generatedAt: 20)
        let second = try snapshot(value: 99, updatedAt: 30, generatedAt: 40)

        #expect(
            WatchReliableSnapshotFingerprint(snapshot: first)
                == WatchReliableSnapshotFingerprint(snapshot: second)
        )
    }

    @Test func detectsMetadataChangesThatMustReachWatchReliably() throws {
        let baseline = try snapshot()
        let completed = try snapshot(isCompleted: true)
        let renamedProject = try snapshot(projectName: "Renamed sweater")
        let renamedCounter = try snapshot(counterName: "Left neckline")
        let selectedCounter = try snapshot(selectedCounterOrdinal: 2)

        let fingerprint = WatchReliableSnapshotFingerprint(snapshot: baseline)
        #expect(fingerprint != WatchReliableSnapshotFingerprint(snapshot: completed))
        #expect(fingerprint != WatchReliableSnapshotFingerprint(snapshot: renamedProject))
        #expect(fingerprint != WatchReliableSnapshotFingerprint(snapshot: renamedCounter))
        #expect(fingerprint != WatchReliableSnapshotFingerprint(snapshot: selectedCounter))
    }

    @Test func ignoresProjectAndCounterReorderingCausedByValueUpdates() throws {
        let first = try multiProjectSnapshot(reverseProjects: false, reverseCounters: false)
        let reordered = try multiProjectSnapshot(reverseProjects: true, reverseCounters: true)

        #expect(
            WatchReliableSnapshotFingerprint(snapshot: first)
                == WatchReliableSnapshotFingerprint(snapshot: reordered)
        )
    }

    private func snapshot(
        value: Int = 1,
        updatedAt: TimeInterval = 10,
        generatedAt: TimeInterval = 20,
        isCompleted: Bool = false,
        projectName: String = "Sweater",
        counterName: String = "Counter 1",
        selectedCounterOrdinal: Int = 1
    ) throws -> WatchSyncSnapshot {
        let projectID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let counters = (1...6).map { ordinal in
            WatchCounterSnapshot(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", ordinal + 1))!,
                name: ordinal == 1 ? counterName : "Counter \(ordinal)",
                value: ordinal == 1 ? value : 0
            )
        }
        let project = try WatchProjectSnapshot(
            id: projectID,
            name: projectName,
            isCompleted: isCompleted,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            counters: counters,
            selectedCounterID: counters[selectedCounterOrdinal - 1].id
        )
        return WatchSyncSnapshot(
            generatedAt: Date(timeIntervalSince1970: generatedAt),
            projects: [project]
        )
    }

    private func multiProjectSnapshot(
        reverseProjects: Bool,
        reverseCounters: Bool
    ) throws -> WatchSyncSnapshot {
        var projects: [WatchProjectSnapshot] = []
        for projectOrdinal in 1...2 {
            var counters = (1...6).map { counterOrdinal in
                WatchCounterSnapshot(
                    id: UUID(uuidString: String(
                        format: "00000000-0000-0000-%04d-%012d",
                        projectOrdinal,
                        counterOrdinal
                    ))!,
                    name: "P\(projectOrdinal) Counter \(counterOrdinal)",
                    value: projectOrdinal * counterOrdinal
                )
            }
            if reverseCounters {
                counters.reverse()
            }
            projects.append(try WatchProjectSnapshot(
                id: UUID(uuidString: String(
                    format: "00000000-0000-0000-0000-%012d",
                    projectOrdinal
                ))!,
                name: "Project \(projectOrdinal)",
                isCompleted: false,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(projectOrdinal)),
                counters: counters,
                selectedCounterID: counters.first(where: {
                    $0.name == "P\(projectOrdinal) Counter 1"
                })!.id
            ))
        }
        if reverseProjects {
            projects.reverse()
        }
        return WatchSyncSnapshot(
            generatedAt: Date(timeIntervalSince1970: reverseProjects ? 99 : 10),
            projects: projects
        )
    }
}
