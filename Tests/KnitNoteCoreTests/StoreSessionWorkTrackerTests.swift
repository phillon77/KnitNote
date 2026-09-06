import Foundation
import Testing
@testable import KnitNoteCore

@Suite @MainActor struct StoreSessionWorkTrackerTests {
    @Test func openWaitIsRejectedAndCloseIsIrreversible() async throws {
        let tracker = StoreSessionWorkTracker()
        await #expect(throws: StoreSessionDrainError.sessionStillActive) {
            try await tracker.waitUntilClosedAndIdle(for: [.backup])
        }
        tracker.close()
        tracker.close()
        #expect(throws: StoreSessionAccessError.revoked) {
            _ = try tracker.begin(
                kind: .backup,
                protecting: URL(fileURLWithPath: "/tmp/unused-backup-root")
            )
        }
        try await tracker.waitUntilClosedAndIdle(for: [.backup])
    }

    @Test func backupWaitDoesNotWaitForUnrelatedCategory() async throws {
        let tracker = StoreSessionWorkTracker()
        let backup = try tracker.begin(kind: .backup)
        let pattern = try tracker.begin(kind: .pattern)
        tracker.close()
        tracker.finish(backup)
        try await tracker.waitUntilClosedAndIdle(for: [.backup])
        let ready = AsyncStream<Void>.makeStream()
        var ended = false
        let all = Task { @MainActor in
            ready.continuation.yield(())
            try await tracker.waitUntilClosedAndIdle(
                for: Set(StoreSessionWorkTracker.Kind.allCases)
            )
            ended = true
        }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(!ended)
        tracker.finish(pattern)
        try await all.value
        #expect(ended)
    }

    @Test func duplicateOrForeignFinishCannotReleaseAnotherOperation() async throws {
        let a = StoreSessionWorkTracker()
        let b = StoreSessionWorkTracker()
        let root = URL(fileURLWithPath: "/tmp/unused-backup-root")
        let first = try a.begin(kind: .backup, protecting: root)
        let second = try a.begin(kind: .backup, protecting: root)
        let foreign = try b.begin(kind: .backup, protecting: root)
        a.close()
        a.finish(first)
        a.finish(first)
        a.finish(foreign)
        #expect(a.protects(root.appendingPathComponent("Staged-owned"), kind: .backup))
        #expect(!a.protects(URL(fileURLWithPath: "/tmp/unused-backup-root-other"), kind: .backup))
        let ready = AsyncStream<Void>.makeStream()
        var completed = false
        let waiter = Task { @MainActor in
            ready.continuation.yield(())
            try await a.waitUntilClosedAndIdle(for: [.backup])
            completed = true
        }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(!completed)
        a.finish(second)
        try await waiter.value
        #expect(completed)
        #expect(!a.protects(root, kind: .backup))
        b.finish(foreign)
    }

    @Test func cancelledWaiterDoesNotDrainWorkOrCancelPeer() async throws {
        let tracker = StoreSessionWorkTracker()
        let root = URL(fileURLWithPath: "/tmp/unused-backup-root")
        let work = try tracker.begin(kind: .backup, protecting: root)
        tracker.close()
        let ready = AsyncStream<Int>.makeStream()
        let cancelled = Task { @MainActor in
            ready.continuation.yield(1)
            try await tracker.waitUntilClosedAndIdle(for: [.backup])
        }
        let peer = Task { @MainActor in
            ready.continuation.yield(2)
            try await tracker.waitUntilClosedAndIdle(for: [.backup, .pattern])
        }
        var iterator = ready.stream.makeAsyncIterator()
        let registered = Set([
            try #require(await iterator.next()),
            try #require(await iterator.next()),
        ])
        #expect(registered == [1, 2])
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(tracker.protects(root, kind: .backup))
        tracker.finish(work)
        try await peer.value
    }

    @Test func twoRegisteredUncancelledWaitersBothReceiveFinalCompletion() async throws {
        let tracker = StoreSessionWorkTracker()
        let work = try tracker.begin(
            kind: .backup,
            protecting: URL(fileURLWithPath: "/tmp/unused-backup-root")
        )
        tracker.close()
        let ready = AsyncStream<Int>.makeStream()
        let first = Task { @MainActor in
            ready.continuation.yield(1)
            try await tracker.waitUntilClosedAndIdle(for: [.backup])
        }
        let second = Task { @MainActor in
            ready.continuation.yield(2)
            try await tracker.waitUntilClosedAndIdle(for: [.backup])
        }

        do {
            var iterator = ready.stream.makeAsyncIterator()
            let registered = Set([
                try #require(await iterator.next()),
                try #require(await iterator.next()),
            ])
            #expect(registered == [1, 2])

            tracker.finish(work)

            try await first.value
            try await second.value
        } catch {
            tracker.finish(work)
            first.cancel()
            second.cancel()
            _ = await first.result
            _ = await second.result
            throw error
        }
    }

    @Test func overlappingWaitersCompleteOnlyWhenTheirScopesAreIdle() async throws {
        let tracker = StoreSessionWorkTracker()
        let backup = try tracker.begin(kind: .backup)
        let thumbnail = try tracker.begin(kind: .thumbnail)
        tracker.close()
        let ready = AsyncStream<Int>.makeStream()
        var backupEnded = false
        var allEnded = false
        let backupWaiter = Task { @MainActor in
            ready.continuation.yield(1)
            try await tracker.waitUntilClosedAndIdle(for: [.backup])
            backupEnded = true
        }
        let allWaiter = Task { @MainActor in
            ready.continuation.yield(2)
            try await tracker.waitUntilClosedAndIdle(for: [.backup, .thumbnail])
            allEnded = true
        }
        var iterator = ready.stream.makeAsyncIterator()
        let registered = Set([
            try #require(await iterator.next()),
            try #require(await iterator.next()),
        ])
        #expect(registered == [1, 2])

        tracker.finish(backup)
        try await backupWaiter.value
        #expect(backupEnded)
        #expect(!allEnded)
        tracker.finish(thumbnail)
        try await allWaiter.value
        #expect(allEnded)
    }

    @Test func cancellationBeforeEntryCannotReturnSuccess() async throws {
        let tracker = StoreSessionWorkTracker()
        tracker.close()
        let waiter = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await tracker.waitUntilClosedAndIdle(for: [.backup])
        }
        await #expect(throws: CancellationError.self) { try await waiter.value }
    }

    @Test func emptyScopeReturnsAfterClosureEvenWhenOtherWorkRemains() async throws {
        let tracker = StoreSessionWorkTracker()
        let pattern = try tracker.begin(kind: .pattern)
        tracker.close()
        try await tracker.waitUntilClosedAndIdle(for: [])
        #expect(tracker.protects(URL(fileURLWithPath: "/tmp/unused"), kind: .pattern) == false)
        tracker.finish(pattern)
    }

    @Test func protectionIsScopedToMatchingBackupRoots() throws {
        let tracker = StoreSessionWorkTracker()
        let backupRoot = URL(fileURLWithPath: "/tmp/unused-backup-root/../unused-backup-root")
        let patternRoot = URL(fileURLWithPath: "/tmp/unused-pattern-root")
        let backup = try tracker.begin(kind: .backup, protecting: backupRoot)
        let pattern = try tracker.begin(kind: .pattern, protecting: patternRoot)
        let rootlessBackup = try tracker.begin(kind: .backup)

        #expect(tracker.protects(backupRoot.appendingPathComponent("Staged-owned"), kind: .backup))
        #expect(!tracker.protects(backupRoot.appendingPathComponent("Staged-owned"), kind: .pattern))
        #expect(tracker.protects(patternRoot.appendingPathComponent("asset"), kind: .pattern))
        #expect(!tracker.protects(patternRoot.appendingPathComponent("asset"), kind: .backup))
        #expect(!tracker.protects(URL(fileURLWithPath: "/tmp/unused-backup-root-other"), kind: .backup))

        tracker.finish(backup)
        tracker.finish(pattern)
        tracker.finish(rootlessBackup)
    }
}
