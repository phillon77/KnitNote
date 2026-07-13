import Foundation

public struct KnittingProject: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public private(set) var currentRow: Int

    public init(id: UUID = UUID(), name: String, currentRow: Int = 0) {
        self.id = id
        self.name = name
        self.currentRow = max(0, currentRow)
    }

    public mutating func completeRow() {
        currentRow += 1
    }

    public mutating func undoRow() {
        currentRow = max(0, currentRow - 1)
    }
}
