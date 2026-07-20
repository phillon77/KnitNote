import Foundation

public struct ProjectJournalAsyncPublicationGate: Equatable, Sendable {
    public private(set) var isActive = false
    private var revision = UUID()

    public init() {}

    public mutating func begin() -> UUID {
        revision = UUID()
        isActive = true
        return revision
    }

    public mutating func cancel() {
        revision = UUID()
        isActive = false
    }

    @discardableResult
    public mutating func finish(_ candidateRevision: UUID) -> Bool {
        guard isActive, revision == candidateRevision else { return false }
        isActive = false
        return true
    }
}
