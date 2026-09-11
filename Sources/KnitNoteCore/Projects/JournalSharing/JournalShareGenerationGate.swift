import Foundation

public struct JournalShareGenerationGate: Sendable {
    private var generation: UInt64 = 0

    public init() {}

    public mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    public func finish(_ candidate: UInt64) -> Bool {
        candidate == generation
    }

    public mutating func cancel() {
        generation &+= 1
    }
}
