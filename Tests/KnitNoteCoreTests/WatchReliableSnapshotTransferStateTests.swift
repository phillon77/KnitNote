import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct WatchReliableSnapshotTransferStateTests {
    @Test func queuesInitialAndStructuralSnapshotsButNotValueOnlyChanges() throws {
        var state = WatchReliableSnapshotTransferState()
        let initial = try snapshot(value: 1, name: "Counter 1")
        let valueOnly = try snapshot(value: 2, name: "Counter 1")
        let renamed = try snapshot(value: 2, name: "Left neckline")

        let preparedInitial = state.prepareTransfer(of: initial)
        let preparedValueOnly = state.prepareTransfer(of: valueOnly)
        let preparedRenamed = state.prepareTransfer(of: renamed)
        let preparedRenamedAgain = state.prepareTransfer(of: renamed)
        #expect(preparedInitial)
        #expect(!preparedValueOnly)
        #expect(preparedRenamed)
        #expect(!preparedRenamedAgain)
    }

    @Test func failedLatestSnapshotBecomesRetryable() throws {
        var state = WatchReliableSnapshotTransferState()
        let snapshot = try snapshot(value: 1, name: "Counter 1")

        let prepared = state.prepareTransfer(of: snapshot)
        let failed = state.recordFailure(of: snapshot)
        let retried = state.prepareTransfer(of: snapshot)
        #expect(prepared)
        #expect(failed)
        #expect(retried)
    }

    @Test func failureOfSupersededSnapshotCannotInvalidateNewerTransfer() throws {
        var state = WatchReliableSnapshotTransferState()
        let old = try snapshot(value: 1, name: "Counter 1")
        let current = try snapshot(value: 1, name: "Left neckline")

        let preparedOld = state.prepareTransfer(of: old)
        let preparedCurrent = state.prepareTransfer(of: current)
        let failedOld = state.recordFailure(of: old)
        let duplicatedCurrent = state.prepareTransfer(of: current)
        #expect(preparedOld)
        #expect(preparedCurrent)
        #expect(!failedOld)
        #expect(!duplicatedCurrent)
    }

    @Test func staleFailureCannotInvalidateNewerSnapshotWithSameStructure() throws {
        var state = WatchReliableSnapshotTransferState()
        let firstA = try snapshot(value: 1, name: "Counter 1", generatedAt: 10)
        let middleB = try snapshot(value: 1, name: "Left neckline", generatedAt: 20)
        let latestA = try snapshot(value: 2, name: "Counter 1", generatedAt: 30)

        let preparedFirstA = state.prepareTransfer(of: firstA)
        let preparedMiddleB = state.prepareTransfer(of: middleB)
        let preparedLatestA = state.prepareTransfer(of: latestA)
        let failedFirstA = state.recordFailure(of: firstA)
        let duplicatedLatestA = state.prepareTransfer(of: latestA)

        #expect(preparedFirstA)
        #expect(preparedMiddleB)
        #expect(preparedLatestA)
        #expect(!failedFirstA)
        #expect(!duplicatedLatestA)
    }

    private func snapshot(
        value: Int,
        name: String,
        generatedAt: TimeInterval? = nil
    ) throws -> WatchSyncSnapshot {
        let counters = (1...6).map { ordinal in
            WatchCounterSnapshot(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", ordinal))!,
                name: ordinal == 1 ? name : "Counter \(ordinal)",
                value: ordinal == 1 ? value : 0
            )
        }
        return WatchSyncSnapshot(
            generatedAt: Date(timeIntervalSince1970: generatedAt ?? TimeInterval(value)),
            projects: [try WatchProjectSnapshot(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000100")!,
                name: "Sweater",
                isCompleted: false,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(value)),
                counters: counters,
                selectedCounterID: counters[0].id
            )]
        )
    }
}
