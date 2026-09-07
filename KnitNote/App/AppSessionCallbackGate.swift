import Foundation

final class AppSessionCallbackGate: @unchecked Sendable {
    struct State: Equatable, Sendable {
        let isClosed: Bool
        let activeTokenCount: Int
        let waiterCount: Int
    }

    private let lock = NSLock()
    private var isClosed = false
    private var tokens: Set<UUID> = []
    private var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    private let observeState: @Sendable (State) -> Void

    init(observeState: @escaping @Sendable (State) -> Void = { _ in }) {
        self.observeState = observeState
    }

    func state() -> State {
        lock.withLock {
            State(
                isClosed: isClosed,
                activeTokenCount: tokens.count,
                waiterCount: waiters.count
            )
        }
    }

    func begin() -> UUID? {
        let token: UUID? = lock.withLock {
            guard !isClosed else { return nil }
            let token = UUID()
            tokens.insert(token)
            return token
        }
        observeState(state())
        return token
    }

    func finish(_ token: UUID) {
        let ready: [AsyncStream<Void>.Continuation] = lock.withLock {
            guard tokens.remove(token) != nil, tokens.isEmpty else { return [] }
            let ready = Array(waiters.values)
            waiters.removeAll()
            return ready
        }
        ready.forEach {
            $0.yield(())
            $0.finish()
        }
        observeState(state())
    }

    func close() {
        lock.withLock { isClosed = true }
        observeState(state())
    }

    @MainActor
    func waitUntilClosedAndIdle() async throws {
        try Task.checkCancellation()
        let waiterID = UUID()
        let event = AsyncStream<Void>.makeStream()
        let shouldWait = try lock.withLock {
            guard isClosed else {
                throw AppSessionProducerDrainError.producerStillActive
            }
            guard !tokens.isEmpty else { return false }
            waiters[waiterID] = event.continuation
            return true
        }
        observeState(state())
        defer {
            _ = lock.withLock { waiters.removeValue(forKey: waiterID) }
            observeState(state())
        }
        if shouldWait {
            var iterator = event.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        try Task.checkCancellation()
    }
}
