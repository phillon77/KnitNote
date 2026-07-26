import Foundation

public struct PatternShareInboxEnqueuer: Sendable {
    public let inboxRoot: URL
    private let startAccessing: @Sendable (URL) -> Bool
    private let stopAccessing: @Sendable (URL) -> Void

    public init(inboxRoot: URL) {
        self.init(
            inboxRoot: inboxRoot,
            startAccessing: { $0.startAccessingSecurityScopedResource() },
            stopAccessing: { $0.stopAccessingSecurityScopedResource() }
        )
    }

    init(
        inboxRoot: URL,
        startAccessing: @escaping @Sendable (URL) -> Bool,
        stopAccessing: @escaping @Sendable (URL) -> Void
    ) {
        self.inboxRoot = inboxRoot
        self.startAccessing = startAccessing
        self.stopAccessing = stopAccessing
    }

    public func enqueue(
        source: URL,
        now: Date
    ) throws -> PatternInboxItem {
        let acquiredSecurityScope = startAccessing(source)
        defer {
            if acquiredSecurityScope {
                stopAccessing(source)
            }
        }
        return try PatternInboxFileService(root: inboxRoot).enqueue(
            source: source,
            origin: .shareExtension,
            targetProjectID: nil,
            now: now
        )
    }
}
