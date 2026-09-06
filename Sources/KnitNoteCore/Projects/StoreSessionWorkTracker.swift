import Foundation

public enum StoreSessionDrainError: Error, Equatable, Sendable {
    case sessionStillActive
}

public enum BackupSessionDrainError: Error, Equatable, Sendable {
    case sessionStillActive
}

@MainActor final class StoreSessionWorkTracker {
    enum Kind: CaseIterable, Hashable, Sendable {
        case backup
        case pattern
        case journalPhoto
        case thumbnail
    }

    struct Token: Hashable {
        fileprivate let owner: UUID
        fileprivate let id: UUID
    }

    private let owner = UUID()
    private var closed = false
    private var operations: [Token: (kind: Kind, root: URL?)] = [:]
    private var waiters: [
        UUID: (kinds: Set<Kind>, continuation: AsyncStream<Void>.Continuation)
    ] = [:]

    func begin(kind: Kind, protecting root: URL? = nil) throws -> Token {
        guard !closed else { throw StoreSessionAccessError.revoked }
        let token = Token(owner: owner, id: UUID())
        operations[token] = (kind, root?.standardizedFileURL)
        return token
    }

    func close() { closed = true }

    private func hasWork(in kinds: Set<Kind>) -> Bool {
        operations.values.contains { kinds.contains($0.kind) }
    }

    func finish(_ token: Token) {
        guard token.owner == owner,
              operations.removeValue(forKey: token) != nil,
              closed else { return }
        let ready = waiters.filter { !hasWork(in: $0.value.kinds) }
        for (id, waiter) in ready {
            waiters.removeValue(forKey: id)
            waiter.continuation.yield(())
            waiter.continuation.finish()
        }
    }

    func protects(_ artifact: URL, kind: Kind) -> Bool {
        let path = artifact.standardizedFileURL.pathComponents
        return operations.values.contains { operation in
            guard operation.kind == kind, let root = operation.root else { return false }
            return path.starts(with: root.pathComponents)
        }
    }

    func waitUntilClosedAndIdle(for kinds: Set<Kind>) async throws {
        try Task.checkCancellation()
        guard closed else { throw StoreSessionDrainError.sessionStillActive }
        guard hasWork(in: kinds) else { return }

        let id = UUID()
        let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        waiters[id] = (kinds, signal.continuation)
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
