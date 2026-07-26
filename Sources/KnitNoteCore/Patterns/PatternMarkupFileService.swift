import Foundation

public struct PatternMarkupFileService: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public static func live() throws -> PatternMarkupFileService { .init(root: try PatternFileService.live().root) }

    public func load(usageID: UUID, pageIndex: Int) throws -> PatternMarkupDocument {
        let file = pageURL(usageID: usageID, pageIndex: pageIndex)
        guard FileManager.default.fileExists(atPath: file.path) else { return PatternMarkupDocument() }
        return try JSONDecoder().decode(PatternMarkupDocument.self, from: Data(contentsOf: file))
    }

    public func save(_ document: PatternMarkupDocument, usageID: UUID, pageIndex: Int) throws {
        let file = pageURL(usageID: usageID, pageIndex: pageIndex)
        if document.strokes.isEmpty {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: file, options: .atomic)
    }

    public func deleteUsageMarkup(usageID: UUID) throws {
        let directory = usageMarkupDirectory(usageID: usageID)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    public func load(projectID: UUID, patternID: UUID, pageIndex: Int) throws -> PatternMarkupDocument {
        let file = legacyPageURL(projectID: projectID, patternID: patternID, pageIndex: pageIndex)
        guard FileManager.default.fileExists(atPath: file.path) else { return PatternMarkupDocument() }
        return try JSONDecoder().decode(PatternMarkupDocument.self, from: Data(contentsOf: file))
    }

    public func save(_ document: PatternMarkupDocument, projectID: UUID, patternID: UUID, pageIndex: Int) throws {
        let file = legacyPageURL(projectID: projectID, patternID: patternID, pageIndex: pageIndex)
        if document.strokes.isEmpty {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: file, options: .atomic)
    }

    // The pre-library file layout remains readable only while migration and
    // compatibility callers exist. New reads and writes are always usage-owned.
    func deleteLegacyMarkup(projectID: UUID, patternID: UUID) throws {
        let directory = legacyPatternDirectory(projectID: projectID, patternID: patternID)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func copyLegacyMarkup(
        from source: PatternMarkupFileService,
        projectID: UUID,
        patternID: UUID,
        usageID: UUID
    ) throws {
        let sourceDirectory = source.legacyPatternDirectory(projectID: projectID, patternID: patternID)
        guard FileManager.default.fileExists(atPath: sourceDirectory.path) else { return }
        let destinationDirectory = usageMarkupDirectory(usageID: usageID)
        try FileManager.default.createDirectory(
            at: destinationDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: sourceDirectory, to: destinationDirectory)
    }

    func usageMarkupDirectory(usageID: UUID) -> URL {
        root.appendingPathComponent("UsageMarkup", isDirectory: true).appendingPathComponent(usageID.uuidString, isDirectory: true)
    }

    private func legacyPatternDirectory(projectID: UUID, patternID: UUID) -> URL {
        root.appendingPathComponent(projectID.uuidString).appendingPathComponent("Markup").appendingPathComponent(patternID.uuidString)
    }
    private func legacyPageURL(projectID: UUID, patternID: UUID, pageIndex: Int) -> URL {
        legacyPatternDirectory(projectID: projectID, patternID: patternID)
            .appendingPathComponent("\(max(0, pageIndex)).json")
    }
    private func pageURL(usageID: UUID, pageIndex: Int) -> URL {
        usageMarkupDirectory(usageID: usageID).appendingPathComponent("\(max(0, pageIndex)).json")
    }
}
