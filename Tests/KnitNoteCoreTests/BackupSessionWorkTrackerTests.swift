import Foundation
import Testing
@testable import KnitNoteCore

@Suite @MainActor struct BackupSessionWorkTrackerTests {
    @Test func openWaitIsRejectedAndCloseIsIrreversible() async throws {
        let tracker = BackupSessionWorkTracker()
        await #expect(throws: BackupSessionDrainError.sessionStillActive) {
            try await tracker.waitUntilClosedAndIdle()
        }
        tracker.close()
        tracker.close()
        #expect(throws: StoreSessionAccessError.revoked) {
            _ = try tracker.begin(protecting: URL(fileURLWithPath: "/tmp/unused-backup-root"))
        }
        try await tracker.waitUntilClosedAndIdle()
    }

    @Test func duplicateOrForeignFinishCannotReleaseAnotherOperation() async throws {
        let a = BackupSessionWorkTracker()
        let b = BackupSessionWorkTracker()
        let root = URL(fileURLWithPath: "/tmp/unused-backup-root")
        let first = try a.begin(protecting: root)
        let second = try a.begin(protecting: root)
        let foreign = try b.begin(protecting: root)
        a.close()
        a.finish(first)
        a.finish(first)
        a.finish(foreign)
        #expect(a.protects(root.appendingPathComponent("Staged-owned")))
        #expect(!a.protects(URL(fileURLWithPath: "/tmp/unused-backup-root-other")))
        let ready = AsyncStream<Void>.makeStream()
        var completed = false
        let waiter = Task { @MainActor in
            ready.continuation.yield(())
            try await a.waitUntilClosedAndIdle()
            completed = true
        }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(!completed)
        a.finish(second)
        try await waiter.value
        #expect(completed)
        #expect(!a.protects(root))
        b.finish(foreign)
    }

    @Test func cancelledWaiterDoesNotDrainWorkOrCancelPeer() async throws {
        let tracker = BackupSessionWorkTracker()
        let root = URL(fileURLWithPath: "/tmp/unused-backup-root")
        let work = try tracker.begin(protecting: root)
        tracker.close()
        let ready = AsyncStream<Void>.makeStream()
        let cancelled = Task { @MainActor in
            ready.continuation.yield(())
            try await tracker.waitUntilClosedAndIdle()
        }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(tracker.protects(root))
        let peer = Task { try await tracker.waitUntilClosedAndIdle() }
        tracker.finish(work)
        try await peer.value
    }

    @Test func cancellationBeforeEntryCannotReturnSuccess() async throws {
        let tracker = BackupSessionWorkTracker()
        tracker.close()
        let waiter = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await tracker.waitUntilClosedAndIdle()
        }
        await #expect(throws: CancellationError.self) { try await waiter.value }
    }
}
