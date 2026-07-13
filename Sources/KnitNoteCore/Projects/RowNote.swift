import Foundation

public struct RowNote: Codable, Hashable, Sendable, Identifiable {
    public var id: Int { row }
    public let row: Int
    public var text: String
    public let createdAt: Date
    public var updatedAt: Date
}
