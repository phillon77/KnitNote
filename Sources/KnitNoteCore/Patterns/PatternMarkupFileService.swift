import Foundation

public struct PatternMarkupFileService: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public static func live() -> PatternMarkupFileService { .init(root: PatternFileService.live().root) }

    public func load(projectID: UUID, patternID: UUID, pageIndex: Int) throws -> PatternMarkupDocument {
        let file = pageURL(projectID: projectID, patternID: patternID, pageIndex: pageIndex)
        guard FileManager.default.fileExists(atPath: file.path) else { return PatternMarkupDocument() }
        return try JSONDecoder().decode(PatternMarkupDocument.self, from: Data(contentsOf: file))
    }

    public func save(_ document: PatternMarkupDocument, projectID: UUID, patternID: UUID, pageIndex: Int) throws {
        let file = pageURL(projectID: projectID, patternID: patternID, pageIndex: pageIndex)
        if document.strokes.isEmpty {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: file, options: .atomic)
    }

    public func deletePatternMarkup(projectID: UUID, patternID: UUID) throws {
        let directory = patternDirectory(projectID: projectID, patternID: patternID)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private func patternDirectory(projectID: UUID, patternID: UUID) -> URL {
        root.appendingPathComponent(projectID.uuidString).appendingPathComponent("Markup").appendingPathComponent(patternID.uuidString)
    }
    private func pageURL(projectID: UUID, patternID: UUID, pageIndex: Int) -> URL {
        patternDirectory(projectID: projectID, patternID: patternID).appendingPathComponent("\(max(0, pageIndex)).json")
    }
}
