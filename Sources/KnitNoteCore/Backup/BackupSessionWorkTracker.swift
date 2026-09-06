import Foundation

public enum BackupSessionDrainError: Error, Equatable, Sendable {
    case sessionStillActive
}

@MainActor final class BackupSessionWorkTracker {
    struct Token: Hashable {
        fileprivate let owner: UUID
        fileprivate let id: UUID
    }

    private let owner = UUID()
    private var closed = false
    private var operations: [Token: URL] = [:]
    private var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]

    func begin(protecting root: URL) throws -> Token {
        guard !closed else { throw StoreSessionAccessError.revoked }
        let token = Token(owner: owner, id: UUID())
        operations[token] = root.standardizedFileURL
        return token
    }

    func close() { closed = true }

    func finish(_ token: Token) {
        guard token.owner == owner,
              operations.removeValue(forKey: token) != nil,
              closed, operations.isEmpty else { return }
        let pending = Array(waiters.values)
        waiters.removeAll()
        for continuation in pending {
            continuation.yield(())
            continuation.finish()
        }
    }

    func protects(_ artifact: URL) -> Bool {
        let path = artifact.standardizedFileURL.pathComponents
        return operations.values.contains { path.starts(with: $0.pathComponents) }
    }

    func waitUntilClosedAndIdle() async throws {
        try Task.checkCancellation()
        guard closed else { throw BackupSessionDrainError.sessionStillActive }
        guard !operations.isEmpty else { return }

        let id = UUID()
        let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        waiters[id] = signal.continuation
        defer {
            waiters.removeValue(forKey: id)
            signal.continuation.finish()
        }

        for await _ in signal.stream {
            try Task.checkCancellation()
            return
        }
        throw CancellationError()
    }
}
