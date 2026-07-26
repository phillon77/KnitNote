import Foundation

public struct PatternAsset: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let sha256: String
    public let kind: PatternKind
    public let storedFilename: String
    public let byteCount: Int64
    public let pageCount: Int?

    public init(
        id: UUID = UUID(),
        sha256: String,
        kind: PatternKind,
        storedFilename: String,
        byteCount: Int64,
        pageCount: Int?
    ) {
        self.id = id
        self.sha256 = sha256
        self.kind = kind
        self.storedFilename = storedFilename
        self.byteCount = byteCount
        self.pageCount = pageCount
    }
}
